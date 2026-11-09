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
public actor ResourceGovernor {
    public static let shared = ResourceGovernor()

    private var activeLease: HeavyLeaseToken?
    private var trackedAliveWorkerPids: Set<Int32> = []
    private var lastHeartbeatByAttempt: [UUID: Date] = [:]
    private var externalResolveBusyReason: String?

    public init() {}

    public func setExternalResolveBusy(reason: String?) {
        self.externalResolveBusyReason = reason
    }

    public func registerWorkerProcess(pid: Int32) {
        trackedAliveWorkerPids.insert(pid)
    }

    public func confirmWorkerProcessTerminated(pid: Int32) {
        trackedAliveWorkerPids.remove(pid)
    }

    public func recordHeartbeat(attemptId: UUID, timestamp: Date = Date()) {
        lastHeartbeatByAttempt[attemptId] = timestamp
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
        requiredDiskMB: Int = 1024
    ) -> GovernorDecision {
        if let busyReason = externalResolveBusyReason {
            return .deniedExternalResolveBusy(reason: busyReason)
        }

        if let current = activeLease {
            return .deniedActiveLeaseHeld(holderJobId: current.jobId, holderProjectId: current.projectId)
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
        }
        lastHeartbeatByAttempt[attemptId] = Date()
        return .granted(token)
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
    ) async throws -> (attempt: JobAttemptRecord, leaseDecision: GovernorDecision) {
        let attempt = try await store.allocateAttempt(jobId: jobId, workerSessionId: workerSessionId)
        let decision = await governor.acquireHeavyLease(
            projectId: projectId,
            jobId: jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            kind: kind,
            workerPid: workerPid,
            availableMemoryMB: availableMemoryMB,
            requiredMemoryMB: requiredMemoryMB
        )
        return (attempt, decision)
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
