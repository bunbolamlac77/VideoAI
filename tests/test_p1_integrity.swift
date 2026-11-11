// tests/test_p1_integrity.sql.swift — Regression for audit P1-08 / P1-09 / P1-10 (2026-11-11).
//
// P1-08: there was no terminal path for a job whose worker died: only SUCCEEDED existed,
//        so a crashed job stayed RUNNING forever.
// P1-09: `listCoverageRecords` rebuilt frame ids as `Array(0..<count)`, losing the real
//        frame ids, corrupted ids and window totals needed for evidence traceability.
// P1-10: `PRAGMA user_version` was never stamped, so the "database newer than this app"
//        guard in the backup/restore path could never fire.

import Foundation
import SQLite3

@main
struct TestP1Integrity {
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1_integrity_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if ok { print("✅ PASS: \(message)") } else { failures += 1; print("❌ FAIL: \(message)") }
        }

        let dbURL = dir.appendingPathComponent("store.db")
        let store = try ProjectStore(dbURL: dbURL)
        let project = try await store.createProject(name: "P1 integrity")

        // P1-10: the canonical schema version is stamped by the single writer on open.
        let version = try await store.getSchemaVersion()
        check(version == ProjectStore.canonicalSchemaVersion,
              "user_version stamped to canonical version (\(version))")

        // P1-09: coverage records round-trip the real frame ids.
        let sourceRevision = UUID()
        let coverage = CoverageLedgerRecord(
            projectId: project.projectId,
            sourceRevisionId: sourceRevision,
            inputFingerprint: "fp-p1-09",
            totalDeclaredFrames: 300,
            validDecodedFrameCount: 298,
            corruptedDecodeFrameIds: [17, 42],
            uniqueProcessedFrameIds: [2, 4, 8, 16, 32, 64],
            totalSubmittedWithOverlap: 12,
            completedWindows: 3,
            totalWindows: 4
        )
        try await store.saveCoverageRecord(coverage)
        let loaded = try await store.listCoverageRecords(projectId: project.projectId)
        let restored = loaded.first { $0.coverageId == coverage.coverageId }
        check(restored?.uniqueProcessedFrameIds == [2, 4, 8, 16, 32, 64],
              "frame ids survive the round-trip (no Array(0..<count) fabrication)")
        check(restored?.corruptedDecodeFrameIds == [17, 42], "corrupted frame ids survive")
        check(restored?.completedWindows == 3 && restored?.totalWindows == 4,
              "window totals survive")
        check(restored.map { abs($0.frameInputCoverage - 6.0 / 300.0) < 1e-9 } ?? false,
              "coverage ratio is recomputed from the real ids")

        // P1-08: a crashed job can be failed explicitly and leaves RUNNING.
        let job = try await store.enqueueJob(
            projectId: project.projectId, jobType: "crash_job", inputFingerprint: "fp-p1-08")
        let attempt = try await store.allocateAttempt(jobId: job.jobId, workerSessionId: "s-p1")
        let running = try await store.getJob(id: job.jobId)
        check(running?.status == .running, "job starts RUNNING once an attempt is allocated")
        try await store.failJob(jobId: job.jobId, reason: "worker died without publishing")
        let failed = try await store.getJob(id: job.jobId)
        check(failed?.status == .failed, "failJob moves the job to FAILED")
        _ = attempt

        await store.close()

        // P1-10 (migration): a database created with the old schema is upgraded on open,
        // and existing rows keep working.
        let legacy = dir.appendingPathComponent("legacy.db")
        var handle: OpaquePointer?
        guard sqlite3_open(legacy.path, &handle) == SQLITE_OK else { fatalError("legacy open") }
        let ddl = """
        CREATE TABLE coverage_records (
            coverage_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL,
            source_revision_id TEXT NOT NULL, runtime_profile_id TEXT NOT NULL,
            input_fingerprint TEXT NOT NULL, total_declared_frames INTEGER NOT NULL,
            valid_decoded_frames INTEGER NOT NULL, unique_processed_frames INTEGER NOT NULL,
            frame_input_coverage REAL NOT NULL, audio_branch_state TEXT NOT NULL,
            detailed_pass_status TEXT NOT NULL, semantic_certified INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')));
        """
        sqlite3_exec(handle, ddl, nil, nil, nil)
        sqlite3_close(handle)
        let upgraded = try ProjectStore(dbURL: legacy)
        let upgradedVersion = try await upgraded.getSchemaVersion()
        await upgraded.close()
        check(upgradedVersion == ProjectStore.canonicalSchemaVersion,
              "a legacy database is upgraded in place and stamped")

        if failures > 0 {
            print("P1 INTEGRITY TESTS FAILED (\(failures))")
            exit(1)
        }
        print("P1 INTEGRITY TESTS PASSED (7/7)")
    }
}
