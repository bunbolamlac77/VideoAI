// test_s08_publication_reconciler.swift — Swift Unit Tests for Gate G1 S08 Artifact Publication & Startup Reconciler
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Sections 6 & 7 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S08).

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

            await store.close()
            print("\n=======================================================")
            print("ALL SWIFT G1 S08 PUBLICATION & RECONCILER TESTS PASSED (3/3)!")
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
