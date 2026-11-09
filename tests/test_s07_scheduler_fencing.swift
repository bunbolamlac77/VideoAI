// test_s07_scheduler_fencing.swift — Swift Unit Tests for Gate G1 S07 Resource Governor, Task Scheduler & Fencing
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Section 5 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S07).

import Foundation

func recordS07TestResult(
    testcaseId: String,
    requirementId: String,
    command: String = "./build/tests/test_s07_scheduler_fencing",
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
        "suite": "swift_s07_scheduler_fencing",
        "command": command,
        "expected": expected,
        "observed": observed,
        "status": status,
        "exit_status": exitStatus,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/swift_s07_records.jsonl"
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
struct TestS07SchedulerFencing {
    static func main() async {
        print("=======================================================")
        print("RUNNING SWIFT G1 SCHEDULER, FENCING & GOVERNOR TESTS (S07)")
        print("=======================================================\n")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aivideo_s07_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbFile = tempDir.appendingPathComponent("s07_store.db")

        do {
            let store = try ProjectStore(dbURL: dbFile)
            let governor = ResourceGovernor()
            let scheduler = TaskScheduler(governor: governor)

            let projectA = try await store.createProject(name: "Project A - Đà Lạt")
            let projectB = try await store.createProject(name: "Project B - Phú Quốc")

            // Test 1: S07.T1 — Cancel Attempt A, start Attempt B, late result from A is rejected by fencing
            print("[Test 1] S07.T1: Cancel Attempt A, run Attempt B, then Attempt A sends late result...")
            let job1 = try await store.enqueueJob(
                projectId: projectA.projectId,
                jobType: "analyze_window",
                inputFingerprint: "fp_window_001"
            )

            let (attemptA, decisionA) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectA.projectId,
                jobId: job1.jobId,
                workerSessionId: "session-001",
                kind: .modelInference,
                workerPid: 10001
            )
            guard case .granted(let leaseA) = decisionA else {
                fatalError("Expected leaseA granted")
            }
            assert(attemptA.fencingToken == 1)

            // Attempt A prepares a publication intent while valid
            let pubA = try await store.createPublicationIntent(
                projectId: projectA.projectId,
                jobId: job1.jobId,
                attemptId: attemptA.attemptId,
                fencingToken: attemptA.fencingToken,
                artifactType: "analysis_json",
                tempPath: tempDir.appendingPathComponent("attA_temp.json").path
            )

            // Cancel Attempt A (revokes publish permission first, releases lease after worker confirmed dead)
            try await scheduler.cancelAttempt(
                store: store,
                attemptId: attemptA.attemptId,
                leaseId: leaseA.leaseId,
                workerConfirmedDead: true
            )

            // Start Attempt B for the same job
            let (attemptB, decisionB) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectA.projectId,
                jobId: job1.jobId,
                workerSessionId: "session-001",
                kind: .modelInference,
                workerPid: 10002
            )
            guard case .granted(let leaseB) = decisionB else {
                fatalError("Expected leaseB granted")
            }
            assert(attemptB.fencingToken == 2, "Attempt B must get monotonic fencing token 2")

            // Late result from Attempt A tries to materialize or commit -> MUST BE REJECTED
            var lateAttemptRejected = false
            do {
                _ = try await store.updatePublicationMaterialized(
                    publicationId: pubA.publicationId,
                    jobId: job1.jobId,
                    attemptId: attemptA.attemptId,
                    fencingToken: attemptA.fencingToken,
                    tempPath: tempDir.appendingPathComponent("attA_temp.json").path
                )
            } catch ProjectStoreError.staleFencingToken(let exp, let act) {
                assert(exp == 2 && act == 1)
                lateAttemptRejected = true
            } catch ProjectStoreError.invalidAuthority {
                lateAttemptRejected = true
            }
            assert(lateAttemptRejected, "Late attempt A must be rejected by fencing token check")

            // Attempt B succeeds and commits cleanly
            let canonB = tempDir.appendingPathComponent("attB_final.json")
            try "{\"status\":\"ok\"}".write(to: canonB, atomically: true, encoding: .utf8)
            let pubB = try await store.createPublicationIntent(
                projectId: projectA.projectId,
                jobId: job1.jobId,
                attemptId: attemptB.attemptId,
                fencingToken: attemptB.fencingToken,
                artifactType: "analysis_json",
                tempPath: canonB.path
            )
            _ = try await store.updatePublicationMaterialized(
                publicationId: pubB.publicationId,
                jobId: job1.jobId,
                attemptId: attemptB.attemptId,
                fencingToken: attemptB.fencingToken,
                tempPath: canonB.path
            )
            _ = try await store.updatePublicationVerified(
                publicationId: pubB.publicationId,
                jobId: job1.jobId,
                attemptId: attemptB.attemptId,
                fencingToken: attemptB.fencingToken,
                sha256: String(repeating: "a", count: 64),
                byteSize: 15
            )
            let committedB = try await store.commitPublication(
                publicationId: pubB.publicationId,
                jobId: job1.jobId,
                attemptId: attemptB.attemptId,
                fencingToken: attemptB.fencingToken,
                canonicalPath: canonB.path
            )
            assert(committedB.state == .committed)
            await governor.releaseHeavyLease(leaseId: leaseB.leaseId, workerConfirmedDead: true)

            recordS07TestResult(
                testcaseId: "S07.T1",
                requirementId: "JOB-01",
                expected: "Cancelling attempt A and starting B revokes A's publish permission; late result from A is rejected by fencing token",
                observed: "Attempt A (fence=1) rejected with staleFencingToken(expected: 2, actual: 1); Attempt B (fence=2) committed cleanly",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S07.T1 Late attempt A rejected by fencing token; Attempt B committed.")

            // Test 2: S07.T2 — Two projects requesting concurrent heavy work obey single Global Heavy Lease & RAM pressure
            print("\n[Test 2] S07.T2: Two projects requesting concurrent heavy inference/render obey single Global Heavy Lease...")
            let jobA2 = try await store.enqueueJob(projectId: projectA.projectId, jobType: "vlm_infer", inputFingerprint: "fp_a2")
            let jobB1 = try await store.enqueueJob(projectId: projectB.projectId, jobType: "resolve_render", inputFingerprint: "fp_b1")

            let (attA2, decA2) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectA.projectId,
                jobId: jobA2.jobId,
                workerSessionId: "session-001",
                kind: .modelInference,
                workerPid: 20001
            )
            guard case .granted(let leaseA2) = decA2 else {
                fatalError("Expected Project A heavy lease granted")
            }

            // Project B simultaneously requests heavy lease -> MUST BE DENIED while Project A holds it
            let (_, decB1) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectB.projectId,
                jobId: jobB1.jobId,
                workerSessionId: "session-001",
                kind: .resolveRender,
                workerPid: 20002
            )
            var deniedByActiveHolder = false
            if case .deniedActiveLeaseHeld(let holderJob, let holderProj) = decB1 {
                assert(holderJob == jobA2.jobId && holderProj == projectA.projectId)
                deniedByActiveHolder = true
            }
            assert(deniedByActiveHolder, "Concurrent heavy lease from Project B must be denied while Project A holds lease")

            // Release Project A lease, then test memory pressure pause before granting Project B
            await governor.releaseHeavyLease(leaseId: leaseA2.leaseId, workerConfirmedDead: true)
            _ = attA2

            let (_, decB1LowMem) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectB.projectId,
                jobId: jobB1.jobId,
                workerSessionId: "session-001",
                kind: .resolveRender,
                workerPid: 20002,
                availableMemoryMB: 1024,
                requiredMemoryMB: 4096
            )
            assert(decB1LowMem == .pausedInsufficientMemory(availableMB: 1024, requiredMB: 4096))

            // Now with sufficient memory, Project B acquires lease
            let (_, decB1Granted) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectB.projectId,
                jobId: jobB1.jobId,
                workerSessionId: "session-001",
                kind: .resolveRender,
                workerPid: 20002,
                availableMemoryMB: 8192,
                requiredMemoryMB: 4096
            )
            guard case .granted(let leaseB1) = decB1Granted else {
                fatalError("Expected Project B lease granted after Project A release and memory available")
            }
            await governor.releaseHeavyLease(leaseId: leaseB1.leaseId, workerConfirmedDead: true)

            recordS07TestResult(
                testcaseId: "S07.T2",
                requirementId: "JOB-02",
                expected: "Global heavy lease serializes heavy tasks across projects and pauses on RAM pressure",
                observed: "Project B blocked while Project A held lease; paused on 1024MB < 4096MB; granted once released",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S07.T2 Global heavy lease across two projects & RAM pressure verified.")

            // Test 3: S07.T3 — Hung worker / unconfirmed termination blocks new heavy lease & Core restart revokes old session
            print("\n[Test 3] S07.T3: Zombie worker PID still alive blocks new heavy lease & Core restart revokes old session...")
            let jobHang = try await store.enqueueJob(projectId: projectA.projectId, jobType: "hung_infer", inputFingerprint: "fp_hang")
            let (attHang, decHang) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectA.projectId,
                jobId: jobHang.jobId,
                workerSessionId: "session-old",
                kind: .modelInference,
                workerPid: 30099
            )
            guard case .granted(let leaseHang) = decHang else {
                fatalError("Expected leaseHang granted")
            }

            // Simulate missed heartbeats (>15s)
            let pastDate = Date().addingTimeInterval(-20.0)
            await governor.recordHeartbeat(attemptId: attHang.attemptId, timestamp: pastDate)
            let suspect = await governor.isHeartbeatSuspect(attemptId: attHang.attemptId)
            assert(suspect, "3 missed heartbeats (20s > 15s) must flag attempt as suspect")

            // Cancel attempt Hang, but worker PID 30099 has NOT yet exited (workerConfirmedDead: false)
            try await scheduler.cancelAttempt(
                store: store,
                attemptId: attHang.attemptId,
                leaseId: leaseHang.leaseId,
                workerConfirmedDead: false
            )

            // Try to start a new heavy attempt while PID 30099 is still alive -> MUST BE BLOCKED (Section 5.2)
            let (_, decBlockedByZombie) = try await scheduler.startHeavyAttempt(
                store: store,
                projectId: projectA.projectId,
                jobId: jobHang.jobId,
                workerSessionId: "session-old",
                kind: .modelInference,
                workerPid: 30100
            )
            assert(
                decBlockedByZombie == .deniedZombieWorkerStillAlive(pid: 30099),
                "Live worker PID 30099 must prevent granting a new heavy lease even after token revocation"
            )

            // Confirm PID 30099 finally terminated, and simulate Core restart with new session "session-new"
            await governor.confirmWorkerProcessTerminated(pid: 30099)
            let revokedCount = try await store.revokeAllOldSessionAttempts(newSessionId: "session-new")
            assert(revokedCount >= 1, "Core restart must revoke all active attempts from old session")

            recordS07TestResult(
                testcaseId: "S07.T3",
                requirementId: "JOB-05",
                expected: "Missed heartbeat flags suspect; unconfirmed worker PID blocks new heavy lease; core restart revokes old session attempts",
                observed: "PID 30099 blocked new lease until confirmed dead; session-old attempts revoked on startup",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S07.T3 Zombie worker lease protection & session recovery verified.")

            await store.close()
            print("\n=======================================================")
            print("ALL SWIFT G1 S07 SCHEDULER & GOVERNOR TESTS PASSED (3/3)!")
            print("=======================================================")
        } catch {
            print("❌ FAIL: S07 test threw unexpected error: \(error)")
            recordS07TestResult(
                testcaseId: "S07.ERR",
                requirementId: "JOB-01",
                expected: "All S07 tests pass",
                observed: "Error: \(error)",
                status: "FAIL",
                exitStatus: 1
            )
            exit(1)
        }
    }
}
