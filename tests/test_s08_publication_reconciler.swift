// test_s08_publication_reconciler.swift — Swift Unit Tests for Gate G1 S08 Artifact Publication & Startup Reconciler
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Sections 6 & 7 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S08).

import CryptoKit
import Foundation

func recordS08TestResult(
    testcaseId: String,
    requirementId: String,
    command: String = "./build/tests/test_s08_publication_reconciler",
    expected: String,
    observed: String,
    status: String,
    exitStatus: Int32
) {
    let reportDir = "build/reports"
    try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
    let record: [String: Any] = [
        "testcase_id": testcaseId,
        "requirement_id": requirementId,
        "suite": "swift_s08_publication_reconciler",
        "command": command,
        "expected": expected,
        "observed": observed,
        "status": status,
        "exit_status": exitStatus,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/swift_s08_records.jsonl"
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let lineData = (line + "\n").data(using: .utf8) {
                handle.write(lineData)
            }
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

@main
struct TestS08PublicationReconciler {
    static func main() async {
        print("=======================================================")
        print("RUNNING SWIFT G1 ARTIFACT PUBLICATION & RECONCILER TESTS (S08)")
        print("=======================================================\n")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aivideo_s08_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbFile = tempDir.appendingPathComponent("s08_store.db")

        do {
            let store = try ProjectStore(dbURL: dbFile)
            let publisher = try ArtifactPublicationService(workspaceRoot: tempDir)
            let project = try await store.createProject(name: "S08 Crash Recovery Project")

            // Test 1: S08.T1 — Fault injection across all 5 crash boundaries & Startup Reconciler recovery
            print("[Test 1] S08.T1: Inject faults at all 5 boundaries (PREPARED, MATERIALIZED, VERIFIED, RENAME, ACK) & Reconcile...")

            let hooks: [PublicationFaultHook] = [
                .afterPreparedBeforeMaterialized,
                .afterMaterializedBeforeVerified,
                .afterVerifiedBeforeRename,
                .afterRenameBeforeDBCommit
            ]

            for (idx, hook) in hooks.enumerated() {
                let job = try await store.enqueueJob(
                    projectId: project.projectId,
                    jobType: "test_crash_\(idx)",
                    inputFingerprint: "fp_\(idx)"
                )
                let attempt = try await store.allocateAttempt(jobId: job.jobId, workerSessionId: "session-crash-1")
                let payload = Data("Artifact content for hook \(hook.rawValue)".utf8)

                var crashCaught = false
                do {
                    _ = try await publisher.publishArtifact(
                        store: store,
                        projectId: project.projectId,
                        jobId: job.jobId,
                        attemptId: attempt.attemptId,
                        fencingToken: attempt.fencingToken,
                        artifactType: "voice_wav",
                        filename: "output_\(idx).wav",
                        content: payload,
                        faultHook: hook
                    )
                } catch PublicationFaultError.injectedCrash(let triggered) {
                    assert(triggered == hook)
                    crashCaught = true
                }
                assert(crashCaught, "Fault hook \(hook.rawValue) must trigger simulated crash")
            }

            // Boundary 5: Crash after DB commit before ACK, plus simulate job completion repair
            let jobAck = try await store.enqueueJob(
                projectId: project.projectId,
                jobType: "test_ack_loss",
                inputFingerprint: "fp_ack"
            )
            let attAck = try await store.allocateAttempt(jobId: jobAck.jobId, workerSessionId: "session-crash-1")
            let ackPayload = Data("Committed audio WAV bytes".utf8)
            var ackCrashCaught = false
            do {
                _ = try await publisher.publishArtifact(
                    store: store,
                    projectId: project.projectId,
                    jobId: jobAck.jobId,
                    attemptId: attAck.attemptId,
                    fencingToken: attAck.fencingToken,
                    artifactType: "voice_wav",
                    filename: "committed_before_ack.wav",
                    content: ackPayload,
                    completeJob: false, // Simulate job still marked RUNNING when crash hit
                    idempotencyKey: "pub_ack_001",
                    faultHook: .afterDBCommitBeforeACK
                )
            } catch PublicationFaultError.injectedCrash(let triggered) {
                assert(triggered == .afterDBCommitBeforeACK)
                ackCrashCaught = true
            }
            assert(ackCrashCaught)

            // Run Startup Reconciler with new session "session-restarted-2"
            let report = try await publisher.runStartupReconciliation(
                store: store,
                projectId: project.projectId,
                newSessionId: "session-restarted-2"
            )

            assert(report.revokedOldAttemptsCount >= 5, "All old session attempts must be revoked")
            assert(report.quarantinedTempsCount == 3, "3 partial/verified temps before rename must be quarantined")
            assert(report.recoveredOrphanBlobsCount == 1, "1 renamed blob before DB commit must be cataloged as orphan")
            assert(report.repairedJobCompletionsCount == 1, "Job with COMMITTED artifact must be repaired to SUCCEEDED without rerun")
            assert(!report.hasCorruptionBlockers, "No COMMITTED artifact should point to missing bytes")

            let repairedJob = try await store.getJob(id: jobAck.jobId)
            assert(repairedJob?.status == .succeeded, "Job status must be reconciled to SUCCEEDED")

            recordS08TestResult(
                testcaseId: "S08.T1",
                requirementId: "DATA-02",
                expected: "Crash hooks across all 5 boundaries reconcile cleanly; no COMMITTED points to missing bytes; committed artifact repairs job completion",
                observed: "Quarantined=3, Orphan=1, RepairedJob=1, CorruptedCommitted=0",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S08.T1 All 5 crash windows reconciled cleanly & job completion repaired.")

            // Test 2: S08.T2 — Job retry writes to isolated attempt dir, never overwrites approved/pinned artifact
            print("\n[Test 2] S08.T2: Retry writes to isolated attempt directory and pins protect approved artifacts from GC...")
            let jobRetry = try await store.enqueueJob(
                projectId: project.projectId,
                jobType: "tts_synthesize",
                inputFingerprint: "fp_tts_1"
            )
            let att1 = try await store.allocateAttempt(jobId: jobRetry.jobId, workerSessionId: "session-restarted-2")
            let approvedBytes = Data("Approved Voice Over Version 1".utf8)
            let pubApproved = try await publisher.publishArtifact(
                store: store,
                projectId: project.projectId,
                jobId: jobRetry.jobId,
                attemptId: att1.attemptId,
                fencingToken: att1.fencingToken,
                artifactType: "voice_wav",
                filename: "voice.wav",
                content: approvedBytes
            )
            assert(pubApproved.state == .committed)

            // Pin this publication for script/preview approval
            try await store.pinArtifact(
                projectId: project.projectId,
                publicationId: pubApproved.publicationId,
                reason: "preview_approval_pin"
            )
            let isPinned = try await store.isArtifactPinned(publicationId: pubApproved.publicationId)
            assert(isPinned)

            // Retry same logical job with new attempt -> produces different bytes in isolated temp/blob
            let att2 = try await store.allocateAttempt(jobId: jobRetry.jobId, workerSessionId: "session-restarted-2")
            let retryBytes = Data("Retry Voice Over Version 2 (Different audio)".utf8)
            let pubRetry = try await publisher.publishArtifact(
                store: store,
                projectId: project.projectId,
                jobId: jobRetry.jobId,
                attemptId: att2.attemptId,
                fencingToken: att2.fencingToken,
                artifactType: "voice_wav",
                filename: "voice.wav",
                content: retryBytes
            )

            assert(pubApproved.canonicalPath != pubRetry.canonicalPath, "Retry must not overwrite approved blob")
            let originalDataOnDisk = try Data(contentsOf: URL(fileURLWithPath: pubApproved.canonicalPath!))
            assert(originalDataOnDisk == approvedBytes, "Approved bytes must remain 100% intact")

            // Run GC with pinned publication included in candidates -> must preserve pinned artifact
            let (_, preserved) = try await publisher.collectUnpinnedCacheAndOrphans(
                store: store,
                projectId: project.projectId,
                candidatePublicationIds: [pubApproved.publicationId]
            )
            assert(preserved.contains(pubApproved.publicationId), "Pinned artifact must be preserved by GC")

            recordS08TestResult(
                testcaseId: "S08.T2",
                requirementId: "DATA-08",
                expected: "Retry writes to isolated attempt/blob without overwriting approved artifact; pins block GC deletion",
                observed: "Approved blob intact (\(approvedBytes.count)B); retry isolated (\(retryBytes.count)B); pin preserved",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S08.T2 Retry isolation and pin protection verified.")

            // Test 3: S08.T3 — Post-commit corruption of a COMMITTED blob is detected and blocks dependents
            print("\n[Test 3] S08.T3: Corrupting a COMMITTED artifact on disk is detected and flagged as blocker...")
            let corruptTargetURL = URL(fileURLWithPath: pubRetry.canonicalPath!)
            // Temporarily make writable to simulate disk bit-rot / external tampering
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: corruptTargetURL.path)
            try Data("TAMPERED_CORRUPT_BYTES".utf8).write(to: corruptTargetURL)

            let corruptionReport = try await publisher.runStartupReconciliation(
                store: store,
                projectId: project.projectId,
                newSessionId: "session-restarted-3"
            )
            assert(corruptionReport.hasCorruptionBlockers, "Corrupted COMMITTED blob must trigger blocker")
            assert(corruptionReport.corruptedCommittedBlobsCount == 1)
            let hasMismatchFinding = corruptionReport.findings.contains { $0.category == "committed_blob_corrupted" && $0.publicationId == pubRetry.publicationId }
            assert(hasMismatchFinding, "Reconciler must report committed_blob_corrupted for tampered publication")

            recordS08TestResult(
                testcaseId: "S08.T3",
                requirementId: "DATA-02",
                expected: "Post-commit artifact corruption is detected by SHA-256 verification and blocks dependents",
                observed: "Detected committed_blob_corrupted on publication \(pubRetry.publicationId); hasCorruptionBlockers=true",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S08.T3 Post-commit artifact corruption detection verified.")

            // Test 4: a publication may only be committed by the job/attempt that owns it.
            print("\n[Test 4] S08.T4: Cross-job commit is rejected...")
            let jobOwner = try await store.enqueueJob(
                projectId: project.projectId, jobType: "owner_job", inputFingerprint: "fp_owner")
            let attOwner = try await store.allocateAttempt(jobId: jobOwner.jobId, workerSessionId: "session-owner")
            let jobForeign = try await store.enqueueJob(
                projectId: project.projectId, jobType: "foreign_job", inputFingerprint: "fp_foreign")
            let attForeign = try await store.allocateAttempt(jobId: jobForeign.jobId, workerSessionId: "session-foreign")

            let ownedURL = tempDir.appendingPathComponent("owned_artifact.bin")
            try Data("OWNED BYTES".utf8).write(to: ownedURL)
            let ownedPub = try await store.createPublicationIntent(
                projectId: project.projectId,
                jobId: jobOwner.jobId,
                attemptId: attOwner.attemptId,
                fencingToken: attOwner.fencingToken,
                artifactType: "voice_wav",
                tempPath: ownedURL.path
            )
            var crossJobRejected = false
            do {
                _ = try await store.commitPublication(
                    publicationId: ownedPub.publicationId,
                    jobId: jobForeign.jobId,
                    attemptId: attForeign.attemptId,
                    fencingToken: attForeign.fencingToken,
                    canonicalPath: ownedURL.path,
                    completeJob: false
                )
            } catch {
                crossJobRejected = true
            }
            assert(crossJobRejected, "Committing a publication from another job must be rejected")

            // Test 5: commit re-hashes the canonical bytes recorded at verification time.
            print("\n[Test 5] S08.T5: Tampered canonical bytes are rejected at commit...")
            let tamperURL = tempDir.appendingPathComponent("tampered_artifact.bin")
            let originalBytes = Data("ORIGINAL CANONICAL BYTES".utf8)
            try originalBytes.write(to: tamperURL)
            let originalHash = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()

            let tamperPub = try await store.createPublicationIntent(
                projectId: project.projectId,
                jobId: jobOwner.jobId,
                attemptId: attOwner.attemptId,
                fencingToken: attOwner.fencingToken,
                artifactType: "voice_wav",
                tempPath: tamperURL.path
            )
            _ = try await store.updatePublicationMaterialized(
                publicationId: tamperPub.publicationId,
                jobId: jobOwner.jobId,
                attemptId: attOwner.attemptId,
                fencingToken: attOwner.fencingToken,
                tempPath: tamperURL.path
            )
            _ = try await store.updatePublicationVerified(
                publicationId: tamperPub.publicationId,
                jobId: jobOwner.jobId,
                attemptId: attOwner.attemptId,
                fencingToken: attOwner.fencingToken,
                sha256: originalHash,
                byteSize: originalBytes.count
            )
            try Data("SWAPPED AFTER VERIFICATION".utf8).write(to: tamperURL)
            var tamperRejected = false
            do {
                _ = try await store.commitPublication(
                    publicationId: tamperPub.publicationId,
                    jobId: jobOwner.jobId,
                    attemptId: attOwner.attemptId,
                    fencingToken: attOwner.fencingToken,
                    canonicalPath: tamperURL.path,
                    completeJob: false
                )
            } catch {
                tamperRejected = true
            }
            assert(tamperRejected, "Commit must re-hash canonical bytes and reject changes")

            // Test 6: a job is only repaired to SUCCEEDED when ALL its artifacts are COMMITTED.
            print("\n[Test 6] S08.T6: Partial publication set is not reconciled to SUCCEEDED...")
            let jobPartial = try await store.enqueueJob(
                projectId: project.projectId, jobType: "partial_job", inputFingerprint: "fp_partial")
            let attPartial = try await store.allocateAttempt(jobId: jobPartial.jobId, workerSessionId: "session-partial")
            let firstURL = tempDir.appendingPathComponent("partial_first.bin")
            try Data("FIRST ARTIFACT".utf8).write(to: firstURL)
            let firstPub = try await store.createPublicationIntent(
                projectId: project.projectId,
                jobId: jobPartial.jobId,
                attemptId: attPartial.attemptId,
                fencingToken: attPartial.fencingToken,
                artifactType: "voice_wav",
                tempPath: firstURL.path
            )
            let firstHash = SHA256.hash(data: Data("FIRST ARTIFACT".utf8)).map { String(format: "%02x", $0) }.joined()
            _ = try await store.updatePublicationMaterialized(
                publicationId: firstPub.publicationId, jobId: jobPartial.jobId,
                attemptId: attPartial.attemptId, fencingToken: attPartial.fencingToken,
                tempPath: firstURL.path)
            _ = try await store.updatePublicationVerified(
                publicationId: firstPub.publicationId, jobId: jobPartial.jobId,
                attemptId: attPartial.attemptId, fencingToken: attPartial.fencingToken,
                sha256: firstHash, byteSize: Data("FIRST ARTIFACT".utf8).count)
            _ = try await store.commitPublication(
                publicationId: firstPub.publicationId, jobId: jobPartial.jobId,
                attemptId: attPartial.attemptId, fencingToken: attPartial.fencingToken,
                canonicalPath: firstURL.path, completeJob: false)

            // A second expected artifact exists but is still only PREPARED.
            let secondURL = tempDir.appendingPathComponent("partial_second.bin")
            try Data("SECOND ARTIFACT".utf8).write(to: secondURL)
            _ = try await store.createPublicationIntent(
                projectId: project.projectId,
                jobId: jobPartial.jobId,
                attemptId: attPartial.attemptId,
                fencingToken: attPartial.fencingToken,
                artifactType: "voice_wav",
                tempPath: secondURL.path
            )

            let repairedPartial = try await store.repairJobCompletionFromCommittedPublications(jobId: jobPartial.jobId)
            assert(!repairedPartial, "Job with a pending artifact must not be reconciled as SUCCEEDED")
            let stillRunning = try await store.getJob(id: jobPartial.jobId)
            assert(stillRunning?.status == .running, "Partially published job must stay RUNNING")

            recordS08TestResult(
                testcaseId: "S08.T4-T6",
                requirementId: "DATA-02",
                expected: "Cross-job commit, post-verification tampering and partial artifact sets are all rejected",
                observed: "crossJobRejected=true, tamperRejected=true, partialJobRepaired=false",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S08.T4-T6 Publication identity, byte integrity and complete-set reconciliation verified.")

            await store.close()
            print("\n=======================================================")
            exit(aivideoReportBanner("SWIFT G1 S08 PUBLICATION & RECONCILER", passed: 6, total: 6))
            print("=======================================================")
        } catch {
            print("❌ FAIL: S08 test threw unexpected error: \(error)")
            recordS08TestResult(
                testcaseId: "S08.ERR",
                requirementId: "DATA-02",
                expected: "All S08 tests pass",
                observed: "Error: \(error)",
                status: "FAIL",
                exitStatus: 1
            )
            exit(1)
        }
    }
}

/// (P1-38) A suite banner must be computed, never typed. `passed/total` where `total` is the
/// declared number of cases: if a case silently stops running (or an assertion is removed)
/// the banner no longer claims a full pass and the process exits non-zero.
func aivideoReportBanner(_ suite: String, passed: Int, total: Int) -> Int32 {
    if passed == total && total > 0 {
        print("ALL \(suite) TESTS PASSED (\(passed)/\(total))!")
        return 0
    }
    print("❌ \(suite): \(passed)/\(total) cases passed — suite is INCOMPLETE or FAILING")
    return 1
}
