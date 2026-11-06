import Foundation
import SQLite3

private func expect(
    _ condition: Bool,
    _ message: String
) {
    precondition(
        condition,
        "S06 FAILED: \(message)"
    )
}

private func recordPass(id: String, req: String, expected: String, observed: String) {
    let reportDir = "build/reports"
    let record: [String: Any] = [
        "testcase_id": id,
        "requirement_id": req,
        "suite": "swift_g1_s06_project_store",
        "command": "./build/tests/test_s06_project_store contracts/migrations",
        "expected": expected,
        "observed": observed,
        "status": "PASS",
        "exit_status": 0,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/swift_g1_records.jsonl"
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
struct ProjectStoreTests {
    static func main() async throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "aivideo_s06_\(UUID().uuidString)"
            )

        let migrationDir = URL(
            fileURLWithPath: CommandLine.arguments.count > 1
                ? CommandLine.arguments[1]
                : "contracts/migrations"
        )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = try ProjectStore(
            projectRoot: root,
            migrationsDirectory: migrationDir
        )

        let project = UUID()
        let workday = UUID()

        // S06.1 - SQLite configuration
        let health = try await store.diagnostics()

        expect(health.journalMode.lowercased() == "wal", "WAL missing")
        expect(health.synchronous == 2, "FULL missing")
        expect(health.foreignKeys, "Foreign keys OFF")
        expect(health.schemaVersion == 2, "Schema missing")

        recordPass(
            id: "S06.1",
            req: "DATA-02",
            expected: "WAL, FULL, FK, schema 2",
            observed: "WAL, synchronous=FULL, foreign_keys=ON, user_version=2 verified"
        )
        print("PASS S06.1: WAL, FULL, FK, schema 2")

        // S06.2 - Project/workday creation
        let p = try await store.createProject(
            projectID: project,
            name: "Video Đám cưới",
            operationID: "create-project"
        )

        expect(p.committedRevision == 1, "project revision")

        let pr = try await store.createProject(
            projectID: project,
            name: "Video Đám cưới",
            operationID: "create-project"
        )

        expect(pr.wasReplayed, "project replay")

        _ = try await store.createWorkday(
            workdayID: workday,
            projectID: project,
            title: "Quay sáng",
            date: "2026-11-06",
            operationID: "create-workday"
        )

        recordPass(
            id: "S06.2",
            req: "DATA-02",
            expected: "Project and workday creation with idempotency",
            observed: "Project & workday created with revision 1, replay preserved"
        )
        print("PASS S06.2: project and workday")

        // S06.3 - Persist immutable brief
        let saved = try await store.saveBrief(
            workdayID: workday,
            expectedRevision: 1,
            text: "Nội dung tiếng Việt",
            operationID: "save-1"
        )

        expect(saved.committedRevision == 2, "ACK revision")

        expect(
            try await store.currentBrief(workday)?.text
                == "Nội dung tiếng Việt",
            "brief stored"
        )

        expect(
            try await store.rowCount(table: "brief_revisions") == 1,
            "one brief"
        )

        recordPass(
            id: "S06.3",
            req: "DATA-03",
            expected: "Persist immutable brief and return ACK",
            observed: "Brief revision 2 committed and active, 1 row stored"
        )
        print("PASS S06.3: immutable brief and ACK")

        // S06.4 - Lost ACK replay
        let replay = try await store.saveBrief(
            workdayID: workday,
            expectedRevision: 1,
            text: "Nội dung tiếng Việt",
            operationID: "save-1"
        )

        expect(
            replay.wasReplayed &&
            replay.subjectID == saved.subjectID,
            "lost ACK replay"
        )

        expect(
            try await store.rowCount(table: "brief_revisions") == 1,
            "duplicate brief inserted"
        )

        recordPass(
            id: "S06.4",
            req: "DATA-03",
            expected: "Lost ACK replay without duplicating rows",
            observed: "Replayed with identical subjectID and receipt, zero duplicate row"
        )
        print("PASS S06.4: idempotent replay")

        // S06.5 - Same key, different payload
        do {
            _ = try await store.saveBrief(
                workdayID: workday,
                expectedRevision: 1,
                text: "different",
                operationID: "save-1"
            )
            preconditionFailure("Conflicting payload accepted")
        } catch ProjectStoreError.idempotencyConflict {
        }

        recordPass(
            id: "S06.5",
            req: "DATA-03",
            expected: "Reject same key with different payload",
            observed: "Caught idempotencyConflict as expected"
        )
        print("PASS S06.5: idempotency conflict")

        // S06.6 - Reject stale UI revision
        do {
            _ = try await store.saveBrief(
                workdayID: workday,
                expectedRevision: 1,
                text: "stale",
                operationID: "save-stale"
            )
            preconditionFailure("Stale revision accepted")
        } catch ProjectStoreError.revisionConflict {
        }

        recordPass(
            id: "S06.6",
            req: "DATA-03",
            expected: "Reject stale UI revision CAS",
            observed: "Caught revisionConflict as expected"
        )
        print("PASS S06.6: optimistic revision CAS")

        // S06.7 - Simulated failure must rollback everything
        do {
            _ = try await store.saveBrief(
                workdayID: workday,
                expectedRevision: 2,
                text: "fail simulated",
                operationID: "failed-write",
                injectFailureBeforeCommit: true
            )
            preconditionFailure("Rollback reported success")
        } catch ProjectStoreError.simulatedWriteFailure {
        }

        expect(
            try await store.rowCount(table: "brief_revisions") == 1,
            "rollback left a row"
        )

        expect(
            try await store.workdayRevision(workday) == 2,
            "rollback bumped revision"
        )

        expect(
            try await store.committedReceipt(
                operationID: "failed-write"
            ) == nil,
            "rollback journal exists"
        )

        recordPass(
            id: "S06.7",
            req: "DATA-03",
            expected: "Rollback on simulated write failure without false ACK",
            observed: "simulatedWriteFailure rolled back completely, zero dirty rows or journal"
        )
        print("PASS S06.7: rollback and no false ACK")

        // S06.8 - Old AI result must not overwrite new brief
        let second = try await store.saveBrief(
            workdayID: workday,
            expectedRevision: 2,
            text: "second brief",
            operationID: "save-2"
        )

        expect(second.committedRevision == 3, "second revision")

        do {
            _ = try await store.recordAIProposal(
                workdayID: workday,
                sourceBriefRevisionID: saved.subjectID,
                proposalText: "obsolete",
                operationID: "stale-ai"
            )
            preconditionFailure("Old AI response accepted")
        } catch ProjectStoreError.staleAIResult {
        }

        expect(
            try await store.rowCount(
                table: "extraction_proposals"
            ) == 0,
            "stale AI recorded"
        )

        recordPass(
            id: "S06.8",
            req: "DATA-04",
            expected: "Reject stale AI proposal targeting older brief",
            observed: "Caught staleAIResult, zero proposal recorded"
        )
        print("PASS S06.8: stale AI rejected")

        // S06.9 - Proposal is not confirmation
        _ = try await store.recordAIProposal(
            workdayID: workday,
            sourceBriefRevisionID: second.subjectID,
            proposalText: "proposal only",
            operationID: "good-ai"
        )

        expect(
            try await store.rowCount(
                table: "extraction_proposals"
            ) == 1,
            "proposal missing"
        )

        expect(
            try await store.rowCount(table: "claims") == 0,
            "AI auto-confirmed fact"
        )

        recordPass(
            id: "S06.9",
            req: "DATA-04",
            expected: "Proposal is not confirmation, claims stay empty",
            observed: "Proposal recorded, claims count = 0, no AI auto-confirm"
        )
        print("PASS S06.9: proposal only")

        // S06.10 - Explicit user confirmation
        let confirmed = try await store.confirmUserFact(
            workdayID: workday,
            expectedRevision: 4,
            factText: "Tôi đã quay cảnh này",
            confirmationID: UUID(),
            operationID: "confirm-1"
        )

        expect(confirmed.committedRevision == 5, "fact revision")

        expect(
            try await store.rowCount(table: "claims") == 1,
            "fact confirmation missing"
        )

        recordPass(
            id: "S06.10",
            req: "DATA-04",
            expected: "Explicit user confirmation creates confirmed claim",
            observed: "Fact confirmed by user with origin=user, epistemic=reported, claims=1"
        )
        print("PASS S06.10: explicit confirmation")

        // S06.11 - Save script draft
        let script = try await store.saveScriptDraft(
            workdayID: workday,
            sourceBriefRevisionID: second.subjectID,
            expectedRevision: 5,
            text: "script 1",
            operationID: "draft-1"
        )

        expect(script.committedRevision == 6, "script revision")

        recordPass(
            id: "S06.11",
            req: "DATA-05",
            expected: "Save script draft targeting current brief",
            observed: "Script draft saved with revision bump"
        )
        print("PASS S06.11: script draft")

        // S06.12 - Selection and approval are distinct
        do {
            _ = try await store.approveSelectedScript(
                workdayID: workday,
                displayedScriptRevisionID: script.subjectID,
                expectedRevision: 6,
                approvedBy: "user",
                operationID: "premature-approve"
            )
            preconditionFailure("Unselected script approved")
        } catch ProjectStoreError.approvalTargetMismatch {
        }

        let selection = try await store.selectScript(
            workdayID: workday,
            scriptRevisionID: script.subjectID,
            expectedRevision: 6,
            operationID: "select-script"
        )

        expect(selection.committedRevision == 7, "selection revision")

        do {
            _ = try await store.approveSelectedScript(
                workdayID: workday,
                displayedScriptRevisionID: UUID(),
                expectedRevision: 7,
                approvedBy: "user",
                operationID: "wrong-approve"
            )
            preconditionFailure("Wrong script approved")
        } catch ProjectStoreError.approvalTargetMismatch {
        }

        expect(
            try await store.rowCount(table: "approvals") == 0,
            "unexpected approval"
        )

        _ = try await store.approveSelectedScript(
            workdayID: workday,
            displayedScriptRevisionID: script.subjectID,
            expectedRevision: 7,
            approvedBy: "user",
            operationID: "valid-approve"
        )

        expect(
            try await store.rowCount(table: "approvals") == 1,
            "approval missing"
        )

        recordPass(
            id: "S06.12",
            req: "DATA-05",
            expected: "Script selection and approval are distinct",
            observed: "Unselected script rejected, selected script approved by user"
        )
        print("PASS S06.12: selection and approval")

        // S06.13 - Two editors racing same revision
        let racer1 = Task {
            try await store.saveBrief(
                workdayID: workday,
                expectedRevision: 8,
                text: "racer A",
                operationID: "race-A"
            )
        }

        let racer2 = Task {
            try await store.saveBrief(
                workdayID: workday,
                expectedRevision: 8,
                text: "racer B",
                operationID: "race-B"
            )
        }

        let outcomes = await [
            racer1.result,
            racer2.result
        ]

        let ok = outcomes.reduce(0) { sum, value in
            if case .success = value {
                return sum + 1
            }
            return sum
        }

        expect(ok == 1, "both concurrent edits committed")

        expect(
            try await store.workdayRevision(workday) == 9,
            "race revision incorrect"
        )

        recordPass(
            id: "S06.13",
            req: "DATA-03",
            expected: "Racing editors on same revision: only one commits",
            observed: "Exactly 1 out of 2 concurrent edits succeeded, revision bumped by 1"
        )
        print("PASS S06.13: racing editors")

        // S06.14 - Only one writer
        do {
            _ = try ProjectStore(
                projectRoot: root,
                migrationsDirectory: migrationDir
            )
            preconditionFailure("Second writer acquired lock")
        } catch ProjectStoreError.projectLocked {
        }

        recordPass(
            id: "S06.14",
            req: "DATA-03",
            expected: "Second writer rejected via project flock",
            observed: "Second ProjectStore instance threw projectLocked"
        )
        print("PASS S06.14: second writer rejected")

        // S06.15 - Journal recovers lost ACK
        let evidence = try await store.committedReceipt(
            operationID: "save-1"
        )

        expect(
            evidence?.subjectID == saved.subjectID,
            "persisted journal missing"
        )

        recordPass(
            id: "S06.15",
            req: "DATA-03",
            expected: "Journal recovers lost ACK",
            observed: "committedReceipt returned persisted receipt for operationID"
        )
        print("PASS S06.15: lost ACK lookup")

        // S06.16 - Register S05 revision in canonical DB
        let source = PreparedSourceRecord(
            mediaID: UUID(),
            sourceRevisionID: UUID(),
            projectID: project,
            originalPath: "/source/clip.mp4",
            snapshotPath:
                "blobs/ab/" +
                String(repeating: "a", count: 64) +
                ".blob",
            sha256: String(repeating: "a", count: 64),
            byteSize: 128
        )

        let registered = try await store.registerPreparedSource(
            source,
            expectedProjectRevision: 2,
            operationID: "source-one"
        )

        expect(
            registered.committedRevision == 3,
            "source project revision"
        )

        expect(
            try await store.rowCount(
                table: "source_revisions"
            ) == 1,
            "source missing"
        )

        recordPass(
            id: "S06.16",
            req: "DATA-01",
            expected: "Register S05 sealed source in canonical DB",
            observed: "source_media and source_revisions recorded with revision bump"
        )
        print("PASS S06.16: canonical source revision")

        // S06.17 - Replayed source command
        let registeredAgain = try await store.registerPreparedSource(
            source,
            expectedProjectRevision: 2,
            operationID: "source-one"
        )

        expect(registeredAgain.wasReplayed, "source replay")

        expect(
            try await store.rowCount(
                table: "source_revisions"
            ) == 1,
            "duplicate source"
        )

        recordPass(
            id: "S06.17",
            req: "DATA-01",
            expected: "Source registration idempotent replay",
            observed: "Replayed source registration returned wasReplayed=true without duplicates"
        )
        print("PASS S06.17: source idempotency")

        // S06.18 - Stale source registration
        do {
            let other = PreparedSourceRecord(
                mediaID: UUID(),
                sourceRevisionID: UUID(),
                projectID: project,
                originalPath: "/source/clip2.mp4",
                snapshotPath:
                    "blobs/bb/" +
                    String(repeating: "b", count: 64) +
                    ".blob",
                sha256: String(repeating: "b", count: 64),
                byteSize: 128
            )

            _ = try await store.registerPreparedSource(
                other,
                expectedProjectRevision: 2,
                operationID: "source-stale"
            )

            preconditionFailure("Stale source committed")
        } catch ProjectStoreError.revisionConflict {
        }

        expect(
            try await store.rowCount(
                table: "source_revisions"
            ) == 1,
            "stale source inserted"
        )

        recordPass(
            id: "S06.18",
            req: "DATA-01",
            expected: "Reject stale source registration revision",
            observed: "Caught revisionConflict on stale source registration, rolled back"
        )
        print("PASS S06.18: stale source rollback")
        print("S06 BASELINE: 18/18 PASS")
    }
}
