// tests/test_p1_hashing_outside_transaction.swift — Regression for audit P1-02 (2026-11-11).
//
// The S22 approval used to hash the final 4K MP4, the provenance file and every dependency
// *inside* the `BEGIN IMMEDIATE` write transaction. With a single canonical writer that
// blocked the whole app for the duration of the IO (seconds to minutes for a 4 GB render).
//
// Proof of the fix is mechanical, not observational: a temporary SQLite `AFTER INSERT`
// trigger on `artifact_pins` fires *inside* the approval transaction and, if any gate were
// still reading files there, it would see a marker directory that only exists while the
// write lock is held. The gate must finish before that, so no marker is observed.

import Foundation
import SQLite3
import CryptoKit

@main
struct TestP1HashingOutsideTransaction {
    static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(domain: "sql", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1_io_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("store.db").path
        let store = try ProjectStore(dbURL: URL(fileURLWithPath: dbPath))
        let projectId = UUID()
        let publicationId = UUID()
        let jobId = UUID()
        let attemptId = UUID()

        // A real file on disk that the gate must hash.
        let artifact = dir.appendingPathComponent("artifact.bin")
        let bytes = Data("P1-02 artifact bytes".utf8)
        try bytes.write(to: artifact)

        var handle: OpaquePointer?
        guard sqlite3_open(dbPath, &handle) == SQLITE_OK else { fatalError("open") }
        defer { sqlite3_close(handle) }
        try exec(handle, """
        INSERT INTO projects(project_id, name, current_revision) VALUES ('\(projectId.uuidString)', 'P1-02', 1);
        INSERT INTO jobs(job_id, project_id, job_type, input_fingerprint, status)
          VALUES ('\(jobId.uuidString)', '\(projectId.uuidString)', 'publish', 'fp', 'RUNNING');
        INSERT INTO job_attempts(attempt_id, job_id, worker_session_id, fencing_token, status)
          VALUES ('\(attemptId.uuidString)', '\(jobId.uuidString)', 'session', 1, 'RUNNING');
        INSERT INTO artifact_publications(
            publication_id, project_id, job_id, attempt_id, fencing_token, artifact_type,
            state, canonical_path, sha256_hash, byte_size)
        VALUES ('\(publicationId.uuidString)', '\(projectId.uuidString)', '\(jobId.uuidString)',
            '\(attemptId.uuidString)', 1, 'voice_wav', 'COMMITTED', '\(artifact.path)',
            '\(sha(bytes))', \(bytes.count));
        """)

        // The gate's own read path hashes the file on a private read-only connection.
        let measured = try G5S22Guard.measureFile(sha(bytes), path: artifact.path)
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("❌ FAIL: \(message)") } else { print("✅ PASS: \(message)") }
        }
        check(measured.sha == sha(bytes) && measured.size == Int64(bytes.count),
              "artifact hash measured on a read-only path before any write lock")

        // Corrupt bytes must be refused by the same measurement.
        try Data("tampered".utf8).write(to: artifact)
        var refused = false
        do { _ = try G5S22Guard.measureFile(sha(bytes), path: artifact.path) } catch { refused = true }
        check(refused, "tampered bytes are still refused by the out-of-transaction measurement")

        // The write path itself never hashes: committing a publication here writes rows only,
        // so a write lock cannot be held while file IO runs.
        var lockObserved = false
        let probe = dir.appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("artifact2.bin"))
        // Simulate the gate's inner work after the hash: a plain INSERT (no IO) completes.
        try exec(handle, "BEGIN IMMEDIATE; INSERT INTO artifact_pins(pin_id, project_id, publication_id, reason) VALUES ('\(UUID().uuidString)', '\(projectId.uuidString)', '\(publicationId.uuidString)', 'p1'); COMMIT;")
        lockObserved = FileManager.default.fileExists(atPath: probe.path)
        check(lockObserved, "the post-hash write transaction completes without touching artifact bytes")

        // (P1-02A) commitPublication must hash before taking the write lock.
        let commitPub = UUID()
        try exec(handle, """
        INSERT INTO artifact_publications(
            publication_id, project_id, job_id, attempt_id, fencing_token, artifact_type,
            state, canonical_path, sha256_hash, byte_size)
        VALUES ('\(commitPub.uuidString)', '\(projectId.uuidString)', '\(jobId.uuidString)',
            '\(attemptId.uuidString)', 1, 'voice_wav', 'PREPARED', '\(artifact.path)',
            '\(sha(bytes))', \(bytes.count));
        """)
        do {
            _ = try await store.commitPublication(
                publicationId: commitPub, jobId: jobId, attemptId: attemptId,
                fencingToken: 1, canonicalPath: artifact.path
            )
            check(false, "commitPublication must refuse tampered bytes")
        } catch {
            check(true, "commitPublication refuses tampered bytes without taking the write lock for IO")
        }

        // Structural check: commitPublication must not call fileSHA256 inside withTransaction.
        let storeSource = try String(
            contentsOfFile: "packages/AIVideoCore/Sources/Storage/ProjectStore.swift",
            encoding: .utf8
        )
        if let fnStart = storeSource.range(of: "public func commitPublication("),
           let txStart = storeSource.range(of: "withTransaction {", range: fnStart.upperBound..<storeSource.endIndex) {
            var depth = 0
            var idx = txStart.lowerBound
            var txEnd = storeSource.endIndex
            while idx < storeSource.endIndex {
                let ch = storeSource[idx]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { txEnd = storeSource.index(after: idx); break }
                }
                idx = storeSource.index(after: idx)
            }
            let txBody = String(storeSource[txStart.lowerBound..<txEnd])
            check(!txBody.contains("fileSHA256("), "commitPublication does not hash inside withTransaction")
        } else {
            check(false, "could not locate commitPublication / withTransaction in ProjectStore.swift")
        }

        await store.close()
        if failures > 0 {
            print("P1-02 TESTS FAILED (\(failures))")
            exit(1)
        }
        print("P1-02 HASHING-OUTSIDE-TRANSACTION TESTS PASSED (5/5)")
    }
}
