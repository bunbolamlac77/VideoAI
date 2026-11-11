// ArtifactPublisher.swift — S08 Artifact Publication Service, Fault Injection Hooks & Startup Reconciler
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Sections 6, 7 & 12 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S08).

import Foundation
import CryptoKit

public enum PublicationFaultHook: String, Sendable, Equatable {
    case afterPreparedBeforeMaterialized
    case afterMaterializedBeforeVerified
    case afterVerifiedBeforeRename
    case afterRenameBeforeDBCommit
    case afterDBCommitBeforeACK
}

public enum PublicationFaultError: Error, LocalizedError, Sendable, Equatable {
    case injectedCrash(PublicationFaultHook)

    public var errorDescription: String? {
        switch self {
        case .injectedCrash(let hook):
            return "Injected Fault / Simulated Crash at boundary: \(hook.rawValue)"
        }
    }
}

public struct ReconciliationFinding: Codable, Sendable, Equatable {
    public let publicationId: UUID?
    public let category: String
    public let actionTaken: String
    public let details: String

    public init(publicationId: UUID? = nil, category: String, actionTaken: String, details: String) {
        self.publicationId = publicationId
        self.category = category
        self.actionTaken = actionTaken
        self.details = details
    }
}

public struct StartupReconciliationReport: Codable, Sendable, Equatable {
    public let newSessionId: String
    public let revokedOldAttemptsCount: Int
    public let quarantinedTempsCount: Int
    public let recoveredOrphanBlobsCount: Int
    public let repairedJobCompletionsCount: Int
    public let corruptedCommittedBlobsCount: Int
    public let findings: [ReconciliationFinding]

    public var hasCorruptionBlockers: Bool {
        corruptedCommittedBlobsCount > 0
    }
}

public enum SHA256Helper {
    public static func hashFile(at url: URL) throws -> (sha256: String, byteSize: Int) {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, data.count)
    }

    public static func hashData(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// ArtifactPublicationService manages the 4-state publication protocol (`PREPARED` -> `MATERIALIZED` -> `VERIFIED` -> `COMMITTED`),
/// content-addressed immutable blob storage, atomic same-volume rename with fsync, and Startup Reconciler.
public actor ArtifactPublicationService {
    public let workspaceRoot: URL
    public let attemptsTempDir: URL
    public let blobsRootDir: URL

    public init(workspaceRoot: URL) throws {
        self.workspaceRoot = workspaceRoot
        self.attemptsTempDir = workspaceRoot.appendingPathComponent("attempts_temp", isDirectory: true)
        self.blobsRootDir = workspaceRoot.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: attemptsTempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobsRootDir, withIntermediateDirectories: true)
    }

    /// Computes content-addressed canonical path: `blobs/<sha256[0..<2]>/<sha256>`
    public func canonicalBlobURL(forSHA256 sha256: String) -> URL {
        let prefix = String(sha256.prefix(2))
        let shardDir = blobsRootDir.appendingPathComponent(prefix, isDirectory: true)
        return shardDir.appendingPathComponent(sha256, isDirectory: false)
    }

    /// Computes isolated attempt output directory so retries never overwrite previous attempts or committed blobs (S08.1).
    public func attemptTempFileURL(attemptId: UUID, filename: String) throws -> URL {
        let dir = attemptsTempDir.appendingPathComponent(attemptId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename, isDirectory: false)
    }

    private func fsyncFileAndParentDir(fileURL: URL) {
        let fd = open(fileURL.path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
        let parentPath = fileURL.deletingLastPathComponent().path
        let dirFd = open(parentPath, O_RDONLY)
        if dirFd >= 0 {
            _ = fsync(dirFd)
            close(dirFd)
        }
    }

    /// Executes the full 4-step publication lifecycle (`PREPARED` -> `MATERIALIZED` -> `VERIFIED` -> `COMMITTED`)
    /// with deterministic fault hooks at each boundary between DB and filesystem (S08.1 - S08.3).
    public func publishArtifact(
        store: ProjectStore,
        publicationId: UUID = UUID(),
        projectId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        artifactType: String,
        filename: String,
        content: Data,
        completeJob: Bool = true,
        // (P1-01) How many artifacts this job must publish before it may be SUCCEEDED.
        expectedPublicationCount: Int = 1,
        idempotencyKey: String? = nil,
        faultHook: PublicationFaultHook? = nil
    ) async throws -> ArtifactPublicationRecord {
        let tempURL = try attemptTempFileURL(attemptId: attemptId, filename: filename)

        // Step 1: Commit durable intent PREPARED before writing output
        _ = try await store.createPublicationIntent(
            publicationId: publicationId,
            projectId: projectId,
            jobId: jobId,
            attemptId: attemptId,
            fencingToken: fencingToken,
            artifactType: artifactType,
            tempPath: tempURL.path,
            expectedPublicationCount: expectedPublicationCount
        )

        // Worker writes output to attempt-isolated temp file
        try content.write(to: tempURL, options: .atomic)

        if faultHook == .afterPreparedBeforeMaterialized {
            throw PublicationFaultError.injectedCrash(.afterPreparedBeforeMaterialized)
        }

        // Step 2: Transition to MATERIALIZED
        _ = try await store.updatePublicationMaterialized(
            publicationId: publicationId,
            jobId: jobId,
            attemptId: attemptId,
            fencingToken: fencingToken,
            tempPath: tempURL.path
        )

        if faultHook == .afterMaterializedBeforeVerified {
            throw PublicationFaultError.injectedCrash(.afterMaterializedBeforeVerified)
        }

        // Step 3: Core independently verifies bytes, size & SHA-256 hash -> VERIFIED
        let (sha256, byteSize) = try SHA256Helper.hashFile(at: tempURL)
        _ = try await store.updatePublicationVerified(
            publicationId: publicationId,
            jobId: jobId,
            attemptId: attemptId,
            fencingToken: fencingToken,
            sha256: sha256,
            byteSize: byteSize
        )

        if faultHook == .afterVerifiedBeforeRename {
            throw PublicationFaultError.injectedCrash(.afterVerifiedBeforeRename)
        }

        // Step 4: Durable flush and atomic rename into immutable content-addressed store on same filesystem
        let finalURL = canonicalBlobURL(forSHA256: sha256)
        let shardDir = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: shardDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            // Content-addressed deduplication: verify existing immutable blob matches hash (never overwrite with different bytes)
            let (existingHash, _) = try SHA256Helper.hashFile(at: finalURL)
            guard existingHash == sha256 else {
                throw ProjectStoreError.integrityViolation("Existing immutable blob at \(finalURL.path) has corrupted hash \(existingHash) != \(sha256)")
            }
            try? FileManager.default.removeItem(at: tempURL)
        } else {
            fsyncFileAndParentDir(fileURL: tempURL)
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            // Seal immutable permissions (0444)
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: finalURL.path)
            fsyncFileAndParentDir(fileURL: finalURL)
        }

        if faultHook == .afterRenameBeforeDBCommit {
            throw PublicationFaultError.injectedCrash(.afterRenameBeforeDBCommit)
        }

        // Step 5: Canonical DB commit (re-verifies attempt fencing token, commits COMMITTED + job SUCCEEDED + idempotency in 1 tx)
        let committed = try await store.commitPublication(
            publicationId: publicationId,
            jobId: jobId,
            attemptId: attemptId,
            fencingToken: fencingToken,
            canonicalPath: finalURL.path,
            completeJob: completeJob,
            idempotencyKey: idempotencyKey
        )

        if faultHook == .afterDBCommitBeforeACK {
            throw PublicationFaultError.injectedCrash(.afterDBCommitBeforeACK)
        }

        return committed
    }

    /// Startup Reconciler (Section 7.1):
    /// 1. Revokes publish permissions for all old worker sessions.
    /// 2. Scans all `artifact_publications` for the project and reconciles each crash window:
    ///    - `PREPARED` / `MATERIALIZED` / `VERIFIED`: quarantines/cleans stale temp files; if rename already occurred before DB commit, detects orphan blob.
    ///    - `COMMITTED`: verifies canonical blob exists on disk and SHA-256 matches; if missing or corrupted, records blocker finding (S08.T3).
    /// 3. Repairs job completion records if all publications are `COMMITTED` (S08.T1).
    public func runStartupReconciliation(
        store: ProjectStore,
        projectId: UUID,
        newSessionId: String
    ) async throws -> StartupReconciliationReport {
        let revokedCount = try await store.revokeAllOldSessionAttempts(newSessionId: newSessionId)
        let publications = try await store.listPublications(projectId: projectId)

        var quarantinedTemps = 0
        var orphanBlobs = 0
        var repairedJobs = 0
        var corruptedCommitted = 0
        var findings: [ReconciliationFinding] = []
        var checkedJobIds = Set<UUID>()

        for pub in publications {
            checkedJobIds.insert(pub.jobId)

            switch pub.state {
            case .prepared, .materialized:
                if let tp = pub.tempPath, FileManager.default.fileExists(atPath: tp) {
                    let quarantinePath = tp + ".quarantined"
                    try? FileManager.default.moveItem(atPath: tp, toPath: quarantinePath)
                    quarantinedTemps += 1
                    findings.append(ReconciliationFinding(
                        publicationId: pub.publicationId,
                        category: "incomplete_temp_quarantined",
                        actionTaken: "quarantined_temp_and_revoked_attempt",
                        details: "Publication in \(pub.state.rawValue) had partial temp at \(tp); moved to \(quarantinePath)"
                    ))
                } else {
                    findings.append(ReconciliationFinding(
                        publicationId: pub.publicationId,
                        category: "stale_intent_revoked",
                        actionTaken: "revoked_old_attempt",
                        details: "Publication in \(pub.state.rawValue) interrupted before completion"
                    ))
                }

            case .verified:
                // Check if crash occurred before or after rename
                if let sha = pub.sha256Hash {
                    let expectedFinal = canonicalBlobURL(forSHA256: sha)
                    if let tp = pub.tempPath, FileManager.default.fileExists(atPath: tp) {
                        let quarantinePath = tp + ".quarantined"
                        try? FileManager.default.moveItem(atPath: tp, toPath: quarantinePath)
                        quarantinedTemps += 1
                        findings.append(ReconciliationFinding(
                            publicationId: pub.publicationId,
                            category: "verified_before_rename",
                            actionTaken: "quarantined_temp_awaiting_new_attempt",
                            details: "Crash after VERIFIED before rename; temp quarantined at \(quarantinePath)"
                        ))
                    } else if FileManager.default.fileExists(atPath: expectedFinal.path) {
                        orphanBlobs += 1
                        findings.append(ReconciliationFinding(
                            publicationId: pub.publicationId,
                            category: "rename_before_db_commit_orphan",
                            actionTaken: "Cataloged_orphan_blob",
                            details: "Crash after rename before DB commit; unreferenced blob at \(expectedFinal.path)"
                        ))
                    }
                }

            case .committed:
                // S08.T3: Verify COMMITTED artifact actually exists and matches SHA-256
                guard let canonPath = pub.canonicalPath,
                      FileManager.default.fileExists(atPath: canonPath) else {
                    corruptedCommitted += 1
                    findings.append(ReconciliationFinding(
                        publicationId: pub.publicationId,
                        category: "committed_blob_missing",
                        actionTaken: "blocked_dependents",
                        details: "COMMITTED publication \(pub.publicationId) missing file at \(pub.canonicalPath ?? "nil")"
                    ))
                    continue
                }
                if let expectedSha = pub.sha256Hash {
                    let (actualSha, _) = try SHA256Helper.hashFile(at: URL(fileURLWithPath: canonPath))
                    if actualSha != expectedSha {
                        corruptedCommitted += 1
                        findings.append(ReconciliationFinding(
                            publicationId: pub.publicationId,
                            category: "committed_blob_corrupted",
                            actionTaken: "blocked_dependents",
                            details: "COMMITTED publication \(pub.publicationId) hash mismatch: expected \(expectedSha), got \(actualSha)"
                        ))
                    }
                }
            }
        }

        // Repair job completion if publications are COMMITTED (S08.T1 requirement)
        for jId in checkedJobIds {
            if try await store.repairJobCompletionFromCommittedPublications(jobId: jId) {
                repairedJobs += 1
                findings.append(ReconciliationFinding(
                    publicationId: nil,
                    category: "job_completion_repaired",
                    actionTaken: "marked_job_succeeded",
                    details: "Job \(jId) had COMMITTED artifacts; reconciled status to SUCCEEDED without blind rerun"
                ))
            }
        }

        return StartupReconciliationReport(
            newSessionId: newSessionId,
            revokedOldAttemptsCount: revokedCount,
            quarantinedTempsCount: quarantinedTemps,
            recoveredOrphanBlobsCount: orphanBlobs,
            repairedJobCompletionsCount: repairedJobs,
            corruptedCommittedBlobsCount: corruptedCommitted,
            findings: findings
        )
    }

    /// Garbage Collection with Pin Protection (S08.5 & Section 12):
    /// Never deletes any blob referenced by a pinned publication (approved evidence/voice/graphics or backup pin).
    public func collectUnpinnedCacheAndOrphans(
        store: ProjectStore,
        projectId: UUID,
        candidatePublicationIds: [UUID]
    ) async throws -> (deletedCount: Int, preservedPinnedIds: [UUID]) {
        let pinnedIds = try await store.listPinnedPublicationIds(projectId: projectId)
        let publications = try await store.listPublications(projectId: projectId)
        let pubMap = Dictionary(uniqueKeysWithValues: publications.map { ($0.publicationId, $0) })

        var deleted = 0
        var preserved: [UUID] = []

        for candId in candidatePublicationIds {
            if pinnedIds.contains(candId) {
                preserved.append(candId)
                continue
            }
            if let pub = pubMap[candId], pub.state != .committed, let tp = pub.tempPath {
                if FileManager.default.fileExists(atPath: tp) {
                    try? FileManager.default.removeItem(atPath: tp)
                    deleted += 1
                }
            }
        }
        return (deleted, preserved)
    }
}
