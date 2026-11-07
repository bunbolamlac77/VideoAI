import Darwin
import Foundation

func recordHardeningResult(
    testcaseId: String,
    requirementId: String,
    expected: String,
    observed: String
) {
    let reportDir = "build/reports"
    try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
    let record: [String: Any] = [
        "testcase_id": testcaseId,
        "requirement_id": requirementId,
        "suite": "swift_g1_s05_hardening",
        "command": "./build/tests/test_s05_hardening",
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
struct S05HardeningTests {
    static func main() async throws {
        let fm = FileManager.default

        let fixture = URL(
            fileURLWithPath:
                "fixtures/g0_spike_assets/test_clip_10s_24fps.mp4"
        ).standardizedFileURL

        if !fm.fileExists(atPath: fixture.path) {
            try? fm.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-c", "import sys; sys.path.insert(0, 'workers/src'); from aivideo_workers.resolve_adapter import create_synthetic_test_assets; create_synthetic_test_assets('fixtures/g0_spike_assets')"]
            try? p.run()
            p.waitUntilExit()
        }

        precondition(
            fm.fileExists(atPath: fixture.path),
            "Missing checked-in MP4 fixture"
        )

        let base = fm.temporaryDirectory.appendingPathComponent(
            "aivideo_s05_hardening_\(UUID().uuidString)"
        )

        try fm.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )

        defer {
            try? fm.removeItem(at: base)
        }

        // TEST 1: Manifest write failure must not become success.
        do {
            let root = base.appendingPathComponent(
                "blocked_manifest"
            )

            try fm.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )

            let store = try SourceManifestStore(
                projectRoot: root
            )

            // Block the manifests directory using a regular file.
            try Data("block".utf8).write(
                to: root.appendingPathComponent("manifests")
            )

            let mediaID = UUID()

            let report = await SourceAcquisition.acquireBatch(
                sources: [
                    (
                        url: fixture,
                        mediaId: mediaID,
                        bookmark: nil
                    )
                ],
                projectRoot: root,
                manifestStore: store,
                preferredMethod: .fullCopy
            )

            precondition(
                report.succeededCount == 0 &&
                report.failedCount == 1,
                "Manifest write failure was swallowed"
            )

            let storedAsset = await store.getAsset(
                mediaId: mediaID
            )

            let storedRevisions = await store.getRevisions(
                for: mediaID
            )

            precondition(
                storedAsset == nil,
                "Failed write mutated in-memory manifest"
            )

            precondition(
                storedRevisions.isEmpty,
                "Failed write created a revision"
            )

            print("PASS S05.H1: manifest failure propagates")
            recordHardeningResult(
                testcaseId: "S05.H1",
                requirementId: "DATA-01",
                expected: "Manifest write failure must not become success",
                observed: "Manifest write failure propagates, failedCount=1, zero in-memory revision"
            )
        }

        // TEST 2: Real same-size mutation must invalidate identity.
        do {
            let clip = base.appendingPathComponent(
                "mutable_same_size.mp4"
            )

            try fm.copyItem(at: fixture, to: clip)

            let identity = try SourceInspector.inspect(
                url: clip
            ).fileIdentity

            let fd = open(clip.path, O_RDWR)
            precondition(fd >= 0, "Unable to open test source")
            defer { _ = close(fd) }

            var old: UInt8 = 0

            precondition(
                pread(fd, &old, 1, 64) == 1,
                "pread mutation byte failed"
            )

            var updated: UInt8 = old ^ 0xFF

            precondition(
                pwrite(fd, &updated, 1, 64) == 1,
                "same-size mutation failed"
            )

            precondition(
                fsync(fd) == 0,
                "mutation fsync failed"
            )

            var rejected = false

            do {
                try SourceAcquisition.verifySourceStability(
                    sourceFD: fd,
                    sourceURL: clip,
                    initialIdentity: identity
                )
            } catch SourceImportError.sourceMutatedDuringAcquisition {
                rejected = true
            }

            precondition(
                rejected,
                "Same-size source mutation was not detected"
            )

            print("PASS S05.H2: real mutation detected")
            recordHardeningResult(
                testcaseId: "S05.H2",
                requirementId: "DATA-01",
                expected: "Real same-size mutation must invalidate identity",
                observed: "Source mutation detected via mtime/ctime nanoseconds and fstat check"
            )
        }

        // TEST 3: Symlink parent must not escape project root.
        do {
            let root = base.appendingPathComponent(
                "symlink_project"
            )

            let outside = base.appendingPathComponent(
                "outside"
            )

            try fm.createDirectory(
                at: root.appendingPathComponent("blobs"),
                withIntermediateDirectories: true
            )

            try fm.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )

            try fm.createSymbolicLink(
                at: root.appendingPathComponent("blobs/aa"),
                withDestinationURL: outside
            )

            var rejected = false

            do {
                _ = try SnapshotVerifier.resolveSafePath(
                    relativePath: "blobs/aa/nonexistent.blob",
                    projectRoot: root
                )
            } catch SourceImportError.pathTraversalDetected {
                rejected = true
            }

            precondition(
                rejected,
                "Symlink parent escaped project root"
            )

            print("PASS S05.H3: symlink escape rejected")
            recordHardeningResult(
                testcaseId: "S05.H3",
                requirementId: "DATA-01",
                expected: "Symlink parent must not escape project root",
                observed: "Symlink parent escape rejected with pathTraversalDetected"
            )
        }

        // TEST 4: Read real MP4 in memory-bounded chunks.
        do {
            let root = base.appendingPathComponent(
                "stream_project"
            )

            try fm.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )

            let result = try SourceAcquisition.acquire(
                sourceURL: fixture,
                mediaId: UUID(),
                projectRoot: root,
                preferredMethod: .fullCopy
            )

            var total: Int64 = 0
            var maximumChunk = 0

            try AuthoritativeSourceReader.forEachVerifiedChunk(
                ref: result.sealedRef,
                projectRoot: root,
                chunkSize: 4096
            ) { bytes in
                total += Int64(bytes.count)
                maximumChunk = max(
                    maximumChunk,
                    bytes.count
                )
            }

            precondition(
                total == result.sealedRef.byteSize,
                "Streamed byte count mismatch"
            )

            precondition(
                maximumChunk <= 4096,
                "Reader exceeded chunk size"
            )

            print("PASS S05.H4: bounded video streaming")
            recordHardeningResult(
                testcaseId: "S05.H4",
                requirementId: "DATA-01",
                expected: "Read real MP4 in memory-bounded chunks",
                observed: "Streamed \(total) bytes with maximum chunk <= 4096 bytes"
            )
        }

        print("S05 hardening: 4/4 PASS")
    }
}
