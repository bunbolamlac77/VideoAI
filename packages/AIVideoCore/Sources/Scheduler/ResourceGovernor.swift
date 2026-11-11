// ResourceGovernor.swift — S07 Global Heavy Lease Governor & Durable Task Scheduler
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Section 5 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S07).

import Foundation

public enum HeavyWorkKind: String, Codable, Sendable {
    case modelInference = "model_inference"
    case resolveRender = "resolve_render"
    case heavyMediaConform = "heavy_media_conform"
}

public struct HeavyLeaseToken: Codable, Sendable, Equatable {
    public let leaseId: UUID
    public let projectId: UUID
    public let jobId: UUID
    public let attemptId: UUID
    public let fencingToken: Int
    public let kind: HeavyWorkKind
    public let workerPid: Int32?
    public let grantedAt: Date

    public init(
        leaseId: UUID = UUID(),
        projectId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        kind: HeavyWorkKind,
        workerPid: Int32? = nil,
        grantedAt: Date = Date()
    ) {
        self.leaseId = leaseId
        self.projectId = projectId
        self.jobId = jobId
        self.attemptId = attemptId
        self.fencingToken = fencingToken
        self.kind = kind
        self.workerPid = workerPid
        self.grantedAt = grantedAt
    }
}

public enum GovernorDecision: Sendable, Equatable {
    case granted(HeavyLeaseToken)
    case deniedActiveLeaseHeld(holderJobId: UUID, holderProjectId: UUID)
    case deniedZombieWorkerStillAlive(pid: Int32)
    case deniedExternalResolveBusy(reason: String)
    case pausedInsufficientMemory(availableMB: Int, requiredMB: Int)
    case pausedInsufficientDisk(availableMB: Int, requiredMB: Int)
}

/// Global Heavy Lease Resource Governor shared across all windows/projects in the app.
/// Enforces at most 1 heavy task at a time and blocks new leases if a previous heavy worker
/// process is still alive (even if its fencing token was revoked).
/// (P1-11) Raised when a heavy operation cannot obtain the global lease.
public enum GovernorError: Error, CustomStringConvertible {
    case leaseDenied(GovernorDecision)

    public var description: String {
        switch self {
        case .leaseDenied(let decision): return "S07 heavy lease denied: \(decision)"
        }
    }
}

public actor ResourceGovernor {
    public static let shared = ResourceGovernor()

    private var activeLease: HeavyLeaseToken?
    private var trackedAliveWorkerPids: Set<Int32> = []
    private var lastHeartbeatByAttempt: [UUID: Date] = [:]
    private var externalResolveBusyReason: String?
    /// (P1-03) A lease whose holder stopped heartbeating for this long is reclaimable.
    private let leaseHeartbeatTimeout: TimeInterval
    /// The last time a tracked PID actually proved it was alive. Used to recognise PIDs the
    /// OS recycled after the worker died (a recycled PID is not a zombie worker).
    private var workerPidSeenAt: [Int32: Date] = [:]

    public init(leaseHeartbeatTimeout: TimeInterval = 900.0) {
        self.leaseHeartbeatTimeout = leaseHeartbeatTimeout
    }

    /// True when the OS says the PID currently exists. `kill(pid, 0)` only probes; it never
    /// signals the process (`ESRCH` = gone, `EPERM` = exists but not ours).
    nonisolated static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func setExternalResolveBusy(reason: String?) {
        self.externalResolveBusyReason = reason
    }

    public func registerWorkerProcess(pid: Int32, now: Date = Date()) {
        trackedAliveWorkerPids.insert(pid)
        workerPidSeenAt[pid] = now
    }

    public func confirmWorkerProcessTerminated(pid: Int32) {
        trackedAliveWorkerPids.remove(pid)
        workerPidSeenAt.removeValue(forKey: pid)
    }

    public func recordHeartbeat(attemptId: UUID, timestamp: Date = Date()) {
        lastHeartbeatByAttempt[attemptId] = timestamp
        if let lease = activeLease, lease.attemptId == attemptId, let pid = lease.workerPid {
            // A live heartbeat also proves the worker PID was ours at this moment.
            workerPidSeenAt[pid] = timestamp
        }
    }

    /// Section 5.3: Missing 3 heartbeats (15s) raises suspicion of lost contact,
    /// but does NOT prove process termination or memory release.
    public func isHeartbeatSuspect(attemptId: UUID, now: Date = Date(), thresholdSeconds: TimeInterval = 15.0) -> Bool {
        guard let last = lastHeartbeatByAttempt[attemptId] else {
            return true
        }
        return now.timeIntervalSince(last) > thresholdSeconds
    }

    public func currentActiveLease() -> HeavyLeaseToken? {
        return activeLease
    }

    /// Requests the global heavy lease.
    /// Denies if:
    /// 1) External Resolve is busy with an unmanaged project (`blocked_resource`)
    /// 2) An existing heavy lease is still active
    /// 3) Any previously spawned heavy worker PID is still alive (Section 5.2: live zombie worker blocks new heavy lease)
    /// 4) RAM or SSD budget is below required threshold
    public func acquireHeavyLease(
        projectId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        kind: HeavyWorkKind,
        workerPid: Int32? = nil,
        availableMemoryMB: Int = 8192,
        requiredMemoryMB: Int = 2048,
        availableDiskMB: Int = 10240,
        requiredDiskMB: Int = 1024,
        now: Date = Date()
    ) -> GovernorDecision {
        if let busyReason = externalResolveBusyReason {
            return .deniedExternalResolveBusy(reason: busyReason)
        }

        if let current = activeLease {
            // (P1-03) A dead holder may not brick the app forever: reclaim only when the
            // worker is provably gone AND the holder stopped heartbeating.
            let lastBeat = lastHeartbeatByAttempt[current.attemptId] ?? current.grantedAt
            let pidGone = current.workerPid.map { !Self.processExists($0) } ?? true
            let stale = now.timeIntervalSince(lastBeat) > leaseHeartbeatTimeout
            if pidGone && stale {
                if let pid = current.workerPid {
                    trackedAliveWorkerPids.remove(pid)
                }
                lastHeartbeatByAttempt.removeValue(forKey: current.attemptId)
                activeLease = nil
            } else {
                return .deniedActiveLeaseHeld(holderJobId: current.jobId, holderProjectId: current.projectId)
            }
        }

        // (P1-03) Reap zombie PIDs: drop entries whose process no longer exists, and entries
        // whose PID was recycled by another process long after we last saw the worker.
        for pid in trackedAliveWorkerPids {
            if !Self.processExists(pid) {
                trackedAliveWorkerPids.remove(pid)
                workerPidSeenAt.removeValue(forKey: pid)
                continue
            }
            if let seen = workerPidSeenAt[pid], now.timeIntervalSince(seen) > leaseHeartbeatTimeout {
                trackedAliveWorkerPids.remove(pid)
                workerPidSeenAt.removeValue(forKey: pid)
            }
        }
        if let alivePid = trackedAliveWorkerPids.first {
            return .deniedZombieWorkerStillAlive(pid: alivePid)
        }

        if availableMemoryMB < requiredMemoryMB {
            return .pausedInsufficientMemory(availableMB: availableMemoryMB, requiredMB: requiredMemoryMB)
        }

        if availableDiskMB < requiredDiskMB {
            return .pausedInsufficientDisk(availableMB: availableDiskMB, requiredMB: requiredDiskMB)
        }

        let token = HeavyLeaseToken(
            projectId: projectId,
            jobId: jobId,
            attemptId: attemptId,
            fencingToken: fencingToken,
            kind: kind,
            workerPid: workerPid
        )
        activeLease = token
        if let pid = workerPid {
            trackedAliveWorkerPids.insert(pid)
            workerPidSeenAt[pid] = now
        }
        lastHeartbeatByAttempt[attemptId] = now
        return .granted(token)
    }

    /// (P1-04) A reserved lease holds the single heavy slot without an attempt yet. It is
    /// bound to a real attempt with `bind`, or released if the attempt cannot be created.
    public struct LeaseReservation: Sendable, Equatable {
        public let leaseId: UUID
        public let jobId: UUID
    }

    public enum LeaseReservationOutcome: Sendable {
        case reserved(LeaseReservation)
        case denied(GovernorDecision)
    }

    public func reserveHeavyLease(
        projectId: UUID,
        jobId: UUID,
        kind: HeavyWorkKind,
        workerPid: Int32? = nil,
        availableMemoryMB: Int = 8192,
        requiredMemoryMB: Int = 2048,
        availableDiskMB: Int = 10240,
        requiredDiskMB: Int = 1024,
        now: Date = Date()
    ) -> LeaseReservationOutcome {
        let placeholder = UUID()
        let decision = acquireHeavyLease(
            projectId: projectId,
            jobId: jobId,
            attemptId: placeholder,
            fencingToken: 0,
            kind: kind,
            workerPid: workerPid,
            availableMemoryMB: availableMemoryMB,
            requiredMemoryMB: requiredMemoryMB,
            availableDiskMB: availableDiskMB,
            requiredDiskMB: requiredDiskMB,
            now: now
        )
        switch decision {
        case .granted(let token):
            return .reserved(LeaseReservation(leaseId: token.leaseId, jobId: jobId))
        default:
            return .denied(decision)
        }
    }

    /// (P1-11) Run one heavy operation under the global lease.
    ///
    /// The native ffmpeg renderers never took a lease, so a preview/4K render could run
    /// while a Resolve render or a model inference held the machine. Callers that have no
    /// durable job/attempt of their own (the UI-driven render path publishes its artifacts
    /// through S08 later) still need to *contend* for the machine, so the lease is reserved
    /// around the operation and released in every exit path.
    public func withHeavyLease<T>(
        projectId: UUID,
        kind: HeavyWorkKind,
        workerPid: Int32? = nil,
        availableMemoryMB: Int = 8192,
        requiredMemoryMB: Int = 2048,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = reserveHeavyLease(
            projectId: projectId,
            jobId: UUID(),
            kind: kind,
            workerPid: workerPid,
            availableMemoryMB: availableMemoryMB,
            requiredMemoryMB: requiredMemoryMB
        )
        switch outcome {
        case .denied(let decision):
            throw GovernorError.leaseDenied(decision)
        case .reserved(let reservation):
            do {
                let value = try await operation()
                releaseHeavyLease(leaseId: reservation.leaseId, workerConfirmedDead: false)
                return value
            } catch {
                releaseHeavyLease(leaseId: reservation.leaseId, workerConfirmedDead: false)
                throw error
            }
        }
    }

    /// Bind a reservation to the attempt it was made for and restart its heartbeat clock.
    /// The lease keeps its identity; only the attempt/fencing identity is attached.
    public func bind(_ leaseId: UUID, to attempt: JobAttemptRecord, now: Date = Date()) -> GovernorDecision {
        guard let current = activeLease, current.leaseId == leaseId else {
            return .deniedActiveLeaseHeld(holderJobId: attempt.jobId, holderProjectId: UUID())
        }
        let bound = HeavyLeaseToken(
            leaseId: current.leaseId,
            projectId: current.projectId,
            jobId: attempt.jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            kind: current.kind,
            workerPid: current.workerPid,
            grantedAt: current.grantedAt
        )
        activeLease = bound
        lastHeartbeatByAttempt.removeValue(forKey: current.attemptId)
        lastHeartbeatByAttempt[attempt.attemptId] = now
        return .granted(bound)
    }

    /// Releases the heavy lease ONLY after verifying the worker process is terminated.
    /// If `workerConfirmedDead` is false while a worker PID is tracked, the lease is cleared
    /// from active status but the PID stays in `trackedAliveWorkerPids`, blocking any subsequent heavy lease!
    public func releaseHeavyLease(leaseId: UUID, workerConfirmedDead: Bool = true) {
        guard let current = activeLease, current.leaseId == leaseId else { return }
        if workerConfirmedDead, let pid = current.workerPid {
            trackedAliveWorkerPids.remove(pid)
        }
        activeLease = nil
    }
}

/// Durable Task Scheduler coordinating ProjectStore attempt fencing and ResourceGovernor heavy leases.
public actor TaskScheduler {
    private let governor: ResourceGovernor

    public init(governor: ResourceGovernor = .shared) {
        self.governor = governor
    }

    /// Schedules a new attempt for a logical job:
    /// 1. Allocates monotonic fencing token in `ProjectStore` (revoking any older attempt for that job).
    /// 2. Acquires global heavy lease from `ResourceGovernor`.
    public func startHeavyAttempt(
        store: ProjectStore,
        projectId: UUID,
        jobId: UUID,
        workerSessionId: String,
        kind: HeavyWorkKind,
        workerPid: Int32? = nil,
        availableMemoryMB: Int = 8192,
        requiredMemoryMB: Int = 2048
    ) async throws -> (attempt: JobAttemptRecord?, leaseDecision: GovernorDecision) {
        // (P1-04) Reserve the heavy lease BEFORE `allocateAttempt` revokes the previous
        // attempt. A denied lease used to leave the job with a freshly revoked old attempt
        // and a new attempt that could never publish. Now a denial leaves the previous
        // attempt untouched and returns `attempt == nil`.
        let reservation = await governor.reserveHeavyLease(
            projectId: projectId,
            jobId: jobId,
            kind: kind,
            workerPid: workerPid,
            availableMemoryMB: availableMemoryMB,
            requiredMemoryMB: requiredMemoryMB
        )
        switch reservation {
        case .reserved(let reserved):
            do {
                let attempt = try await store.allocateAttempt(
                    jobId: jobId, workerSessionId: workerSessionId
                )
                let decision = await governor.bind(reserved.leaseId, to: attempt)
                if case .granted(let token) = decision {
                    return (attempt, .granted(token))
                }
                return (attempt, decision)
            } catch {
                // Nothing was published under this reservation; never leak the slot.
                await governor.releaseHeavyLease(leaseId: reserved.leaseId)
                throw error
            }
        case .denied(let decision):
            return (nil, decision)
        }
    }

    /// Cancels an attempt following Section 5.1 Rule 5:
    /// FIRST revokes publish permission in canonical store, THEN releases/signals worker termination.
    public func cancelAttempt(
        store: ProjectStore,
        attemptId: UUID,
        leaseId: UUID?,
        workerConfirmedDead: Bool
    ) async throws {
        try await store.revokeAttemptPublishPermission(attemptId: attemptId, markCancelled: true)
        if let lid = leaseId {
            await governor.releaseHeavyLease(leaseId: lid, workerConfirmedDead: workerConfirmedDead)
        }
    }
}
