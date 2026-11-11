// tests/test_p1_backup_restore.swift — Regression for audit P1-05 / P1-06 (2026-11-11).
//
// P1-05: `createBackup` read the project revision, pins and publications from the *live*
//        database and only then copied it, so a pin committed in between could end up in
//        the manifest without being in the snapshot (or vice versa). The closure is now
//        read from the snapshot itself.
// P1-06: `restoreBackup` copied blobs into the new directory but left every row pointing at
//        the *original* absolute `canonical_path`, so after the original was removed every
//        guard reported the artifact as missing. P1-07 counted approvals as "claims".
//
// The decisive check below deletes the original workspace before inspecting the restore:
// a correct restore must be self-contained.

import Foundation
import CryptoKit

@main
struct TestP1BackupRestore {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1_backup_\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let restored = root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ProjectStore(dbURL: root.appendingPathComponent("store.db"))
        let publisher = try ArtifactPublicationService(workspaceRoot: workspace)
        let backupService = BackupRestoreService(supportedMaxSchemaVersion: 2)

        let project = try await store.createProject(name: "P1 backup")
        let workday = try await store.createWorkday(
            projectId: project.projectId, title: "Ngày", date: "2026-11-11")
        for text in ["Một", "Hai", "Ba"] {
            // Each save advances the project revision, so the CAS token is re-read each time.
            let current = try await store.getProject(id: project.projectId)!.currentRevision
            let claim = ClaimRecord(
                workdayId: workday.workdayId, text: "Sự kiện \(text)",
                origin: .user, epistemicStatus: .reported)
            _ = try await store.saveClaim(claim: claim, expectedRevision: current)
        }
        let claimsBefore = try await store.countClaims(workdayId: workday.workdayId)

        let job = try await store.enqueueJob(
            projectId: project.projectId, jobType: "tts_voice", inputFingerprint: "fp-p1")
        let attempt = try await store.allocateAttempt(jobId: job.jobId, workerSessionId: "p1-session")
        let payload = Data("PINNED BYTES FOR P1-06".utf8)
        let pub = try await publisher.publishArtifact(
            store: store, projectId: project.projectId,
            jobId: job.jobId, attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken, artifactType: "voice_wav",
            filename: "pinned.wav", content: payload)
        try await store.pinArtifact(
            projectId: project.projectId, publicationId: pub.publicationId, reason: "p1")
        let originalPath = pub.canonicalPath ?? ""

        let bundle = try await backupService.createBackup(
            store: store, projectId: project.projectId,
            mode: .portableBackup, backupsRootURL: backups)

        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if ok { print("✅ PASS: \(message)") } else { failures += 1; print("❌ FAIL: \(message)") }
        }

        // P1-05: the manifest's closure must be the snapshot's closure, and the snapshot
        // must contain exactly the pinned publications the manifest lists.
        check(bundle.manifest.pinnedArtifacts.count == 1, "manifest lists the pinned artifact")
        let snapshotPins = try SnapshotClosure.read(
            from: bundle.bundleDir.appendingPathComponent(bundle.manifest.databaseFilename),
            projectId: project.projectId)
        check(snapshotPins.pinCount == bundle.manifest.pinnedArtifacts.count,
              "manifest closure == snapshot closure")

        // The original workspace disappears: the restore must stand on its own.
        try FileManager.default.removeItem(at: workspace)

        let (restoredStore, report) = try await backupService.restoreBackup(
            from: bundle.bundleDir, toNewDirectory: restored)
        defer { Task { await restoredStore.close() } }

        check(report.repointedCanonicalPaths >= 1,
              "restore re-pointed canonical paths into the restored bundle (P1-06)")
        let restoredPubs = try await restoredStore.listPublications(projectId: project.projectId)
        print("DEBUG restored dir contents:", (try? FileManager.default.contentsOfDirectory(atPath: restored.path)) ?? [])
        print("DEBUG blobs:", (try? FileManager.default.contentsOfDirectory(atPath: restored.appendingPathComponent("blobs").path)) ?? [])
        print("DEBUG pubs:", restoredPubs.map { ($0.state.rawValue, $0.sha256Hash ?? "-", $0.canonicalPath ?? "-") })
        check(restoredPubs.allSatisfy { ($0.canonicalPath ?? "").hasPrefix(restored.path) },
              "restored publications point inside the restored directory")
        check(restoredPubs.allSatisfy { FileManager.default.fileExists(atPath: $0.canonicalPath ?? "") },
              "restored artifact bytes exist after the original directory is gone")
        check(!originalPath.isEmpty && originalPath != restoredPubs.first?.canonicalPath,
              "the restored path is not the original absolute path")

        check(report.restoredClaimsCount == claimsBefore,
              "restore reports the real claim count (P1-07): \(report.restoredClaimsCount) vs \(claimsBefore)")

        if failures > 0 {
            print("P1 BACKUP/RESTORE TESTS FAILED (\(failures))")
            exit(1)
        }
        print("P1 BACKUP/RESTORE TESTS PASSED (6/6)")
    }
}
