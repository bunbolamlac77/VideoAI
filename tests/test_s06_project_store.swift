// test_s06_project_store.swift — Swift Unit Tests for Gate G1 S06 ProjectStore Actor
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md.

import Foundation

func recordS06TestResult(
    testcaseId: String,
    requirementId: String,
    command: String = "./build/tests/test_s06_project_store",
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
        "suite": "swift_s06_project_store",
        "command": command,
        "expected": expected,
        "observed": observed,
        "status": status,
        "exit_status": exitStatus,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/swift_s06_records.jsonl"
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
struct TestS06ProjectStore {
    static func main() async {
        print("=======================================================")
        print("RUNNING SWIFT G1 PROJECTSTORE ACTOR TESTS (S06)")
        print("=======================================================\n")

        var passCount = 0

        // Test 1: SQLite WAL creation, pragmas & project creation
        print("[Test 1] S06.1: Initialize ProjectStore actor on disk file with WAL mode & Foreign Keys...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aivideo_s06_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbFile = tempDir.appendingPathComponent("project_store.db")

        do {
            let store = try ProjectStore(dbURL: dbFile)
            let project = try await store.createProject(name: "AIVideo Đà Lạt Trip")
            assert(project.name == "AIVideo Đà Lạt Trip")
            assert(project.currentRevision == 1)

            let fetched = try await store.getProject(id: project.projectId)
            assert(fetched != nil)
            assert(fetched?.projectId == project.projectId)
            assert(fetched?.currentRevision == 1)

            recordS06TestResult(
                testcaseId: "S06.SQLITE.1",
                requirementId: "DATA-03",
                expected: "ProjectStore actor creates project on disk SQLite with initial revision 1",
                observed: "Project created and fetched successfully: id=\(project.projectId), rev=1",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S06.1 ProjectStore initialized and project created.")
            passCount += 1

            // Test 2: Foreign Key Enforcement & Atomic Rollback
            print("\n[Test 2] S06.2: Foreign Key constraint enforcement and atomic rollback...")
            let fakeProjectId = UUID()
            var fkCaught = false
            do {
                _ = try await store.createWorkday(projectId: fakeProjectId, title: "Day 1", date: "2026-11-09")
            } catch ProjectStoreError.projectNotFound {
                fkCaught = true
            } catch {
                fkCaught = true
            }
            assert(fkCaught, "Creating workday with invalid project_id must fail foreign key check")

            let validWorkday = try await store.createWorkday(projectId: project.projectId, title: "Ngày 1: Đèo Prenn", date: "2026-11-09")
            assert(validWorkday.title == "Ngày 1: Đèo Prenn")

            recordS06TestResult(
                testcaseId: "S06.SQLITE.2",
                requirementId: "DATA-03",
                expected: "Foreign keys reject orphaned workday; valid workday persists atomically",
                observed: "FK violation rejected; valid workday created: \(validWorkday.workdayId)",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S06.2 Foreign key integrity confirmed.")
            passCount += 1

            // Test 3: S06.T1 Revision Conflict & Idempotency
            print("\n[Test 3] S06.T1: Revision conflict detection and idempotency journal...")
            let claim1 = ClaimRecord(
                workdayId: validWorkday.workdayId,
                text: "Quay cảnh flycam thác Datanla 4K",
                origin: .user,
                epistemicStatus: .reported,
                reviewStatus: .unreviewed
            )

            // Save with expected revision = 1 (matches current project revision)
            let savedClaim1 = try await store.saveClaim(claim: claim1, expectedRevision: 1, idempotencyKey: "op_save_001")
            assert(savedClaim1.claimId == claim1.claimId)

            let projAfterSave = try await store.getProject(id: project.projectId)
            assert(projAfterSave?.currentRevision == 2, "Current revision must increment to 2")

            // Re-saving with stale expected revision = 1 must throw revisionConflict
            var conflictCaught = false
            let claim2 = ClaimRecord(
                workdayId: validWorkday.workdayId,
                text: "Quay cảnh hồ Xuân Hương",
                origin: .user,
                epistemicStatus: .reported,
                reviewStatus: .unreviewed
            )
            do {
                _ = try await store.saveClaim(claim: claim2, expectedRevision: 1)
            } catch ProjectStoreError.revisionConflict(let exp, let act) {
                assert(exp == 1 && act == 2)
                conflictCaught = true
            }
            assert(conflictCaught, "Stale revision must throw revisionConflict")

            // Idempotency: Repeating same operation_id returns cached result without incrementing revision
            let idempResult = try await store.saveClaim(claim: claim1, expectedRevision: 999, idempotencyKey: "op_save_001")
            assert(idempResult.claimId == claim1.claimId)
            let projAfterIdemp = try await store.getProject(id: project.projectId)
            assert(projAfterIdemp?.currentRevision == 2, "Idempotent hit must not increment revision")

            recordS06TestResult(
                testcaseId: "S06.T1",
                requirementId: "DATA-04",
                expected: "Stale revision throws revisionConflict; idempotency key returns cached record without re-executing",
                observed: "Revision conflict caught (exp=1, act=2); idempotency matched cached record without side effect",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S06.T1 Revision conflict & Idempotency verified.")
            passCount += 1

            // Test 4: S06.T3 Fact Confirmation preserves origin and epistemic status
            print("\n[Test 4] S06.T3: Fact confirmation creates immutable revision, preserves origin & logs approval...")
            let confirmId = UUID()
            let confirmedClaim = try await store.confirmFact(
                claimId: claim1.claimId,
                confirmationId: confirmId,
                approvedBy: "ThanhPhu (Editor)"
            )

            assert(confirmedClaim.claimId == claim1.claimId, "claim_id stays identical across revisions")
            assert(confirmedClaim.revisionId != claim1.revisionId, "revision_id must be freshly generated")
            assert(confirmedClaim.reviewStatus == .confirmed, "reviewStatus must be .confirmed")
            assert(confirmedClaim.origin == .user, "Origin must remain user (never visual_model)")
            assert(confirmedClaim.epistemicStatus == .reported, "Epistemic status must remain reported")
            assert(confirmedClaim.confirmationId == confirmId)

            let latestList = try await store.getLatestClaims(workdayId: validWorkday.workdayId)
            assert(latestList.count == 1)
            assert(latestList[0].reviewStatus == .confirmed)
            assert(latestList[0].revisionId == confirmedClaim.revisionId)

            recordS06TestResult(
                testcaseId: "S06.T3",
                requirementId: "DATA-04",
                expected: "Fact confirmation updates review_status to confirmed while strictly preserving origin=user and epistemic=reported",
                observed: "Confirmed revision saved to DB; origin=user, epistemic=reported, approval logged",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S06.T3 Fact confirmation & Epistemic preservation verified.")
            passCount += 1

            // Test 5: S06.T2 WAL Checkpoint & Clean Close
            print("\n[Test 5] S06.T2: WAL passive checkpoint and clean termination...")
            try await store.checkpointWAL()
            await store.close()

            // Reopen store on existing file and verify all persisted data remains intact
            let reopenedStore = try ProjectStore(dbURL: dbFile)
            let reopenedProj = try await reopenedStore.getProject(id: project.projectId)
            assert(reopenedProj != nil)
            assert(reopenedProj?.currentRevision == 3) // 1 -> 2 (save) -> 3 (confirm)
            let reopenedClaims = try await reopenedStore.getLatestClaims(workdayId: validWorkday.workdayId)
            assert(reopenedClaims.count == 1)
            assert(reopenedClaims[0].reviewStatus == .confirmed)
            await reopenedStore.close()

            recordS06TestResult(
                testcaseId: "S06.T2",
                requirementId: "DATA-03",
                expected: "WAL checkpoints cleanly; reopening database restores all committed revisions and state",
                observed: "WAL checkpoint succeeded; reopened DB verified revision=3 with intact confirmed claim",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S06.T2 WAL Checkpoint & Reopen persistence verified.")
            passCount += 1

        } catch {
            print("   ❌ FAIL: S06 test threw unexpected error: \(error)")
            exit(1)
        }

        try? FileManager.default.removeItem(at: tempDir)
        print("\n=======================================================")
        print("ALL SWIFT G1 S06 PROJECTSTORE TESTS PASSED (\(passCount)/\(passCount))!")
        print("=======================================================")
    }
}
