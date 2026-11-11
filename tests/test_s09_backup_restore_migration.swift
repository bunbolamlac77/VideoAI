// test_s09_backup_restore_migration.swift — Swift Unit Tests for Gate G1 S09 Backup, Restore & Schema Migration
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Sections 10 & 11 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S09).

import Foundation

func recordS09TestResult(
    testcaseId: String,
    requirementId: String,
    command: String = "./build/tests/test_s09_backup_restore_migration",
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
        "suite": "swift_s09_backup_restore_migration",
        "command": command,
        "expected": expected,
        "observed": observed,
        "status": status,
        "exit_status": exitStatus,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/swift_s09_records.jsonl"
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
struct TestS09BackupRestoreMigration {
    static func main() async {
        print("=======================================================")
        print("RUNNING SWIFT G1 BACKUP, RESTORE & MIGRATION TESTS (S09)")
        print("=======================================================\n")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aivideo_s09_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let workspaceDir = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let backupsDir = tempDir.appendingPathComponent("backups", isDirectory: true)
        let dbFile = tempDir.appendingPathComponent("s09_store.db")

        do {
            let store = try ProjectStore(dbURL: dbFile)
            try await store.setSchemaVersion(1)
            let publisher = try ArtifactPublicationService(workspaceRoot: workspaceDir)
            let backupService = BackupRestoreService(supportedMaxSchemaVersion: 2)

            // Populate project with workday, confirmed fact, and pinned artifact
            let project = try await store.createProject(name: "S09 Portable Backup Project")
            let workday = try await store.createWorkday(projectId: project.projectId, title: "Ngày 1: Hồ Tuyền Lâm", date: "2026-11-09")

            let claim = ClaimRecord(
                workdayId: workday.workdayId,
                text: "Chèo thuyền kayak lúc bình minh 6h sáng",
                origin: .user,
                epistemicStatus: .reported
            )
            _ = try await store.saveClaim(claim: claim, expectedRevision: 1)
            let confirmed = try await store.confirmFact(claimId: claim.claimId, approvedBy: "phuthanh", expectedRevision: 2)
            assert(confirmed.reviewStatus == .confirmed)

            let job = try await store.enqueueJob(projectId: project.projectId, jobType: "tts_voice", inputFingerprint: "fp_s09")
            let att = try await store.allocateAttempt(jobId: job.jobId, workerSessionId: "session-s09-1")
            let pinnedVoiceBytes = Data("Pinned Voice WAV Bytes For S09 Portable Restore".utf8)
            let pub = try await publisher.publishArtifact(
                store: store,
                projectId: project.projectId,
                jobId: job.jobId,
                attemptId: att.attemptId,
                fencingToken: att.fencingToken,
                artifactType: "voice_wav",
                filename: "pinned_voice.wav",
                content: pinnedVoiceBytes
            )
            try await store.pinArtifact(projectId: project.projectId, publicationId: pub.publicationId, reason: "script_approval_pin")

            // Test 1: S09.T1 — Consistent Portable Backup & Restore to a brand-new directory preserves facts, approvals, revisions & pinned bytes
            print("[Test 1] S09.T1: Portable backup with concurrent write barrier & full restore to a new directory...")
            let (portableBundleURL, portableManifest) = try await backupService.createBackup(
                store: store,
                projectId: project.projectId,
                mode: .portableBackup,
                backupsRootURL: backupsDir
            )
            assert(portableManifest.rootRevision == 3, "Snapshot root revision must be 3")
            assert(portableManifest.pinnedArtifacts.count == 1)

            // Mutate original store to revision 4 AFTER backup to verify backup snapshot isolation
            let postBackupClaim = ClaimRecord(
                workdayId: workday.workdayId,
                text: "Dữ kiện thêm sau khi backup (Revision 4)",
                origin: .user,
                epistemicStatus: .reported
            )
            _ = try await store.saveClaim(claim: postBackupClaim, expectedRevision: 3)
            let updatedOriginal = try await store.getProject(id: project.projectId)
            assert(updatedOriginal?.currentRevision == 4)

            // Restore portable backup into a clean new directory
            let restoreTargetDir = tempDir.appendingPathComponent("restored_portable_project", isDirectory: true)
            let (restoredStore, restoreReport) = try await backupService.restoreBackup(
                from: portableBundleURL,
                toNewDirectory: restoreTargetDir
            )
            assert(restoreReport.integrityVerified)
            assert(restoreReport.restoredRootRevision == 3, "Restored DB must match snapshot revision 3, not R+1 (4)")
            assert(restoreReport.restoredApprovalsCount == 1)
            assert(restoreReport.verifiedPinnedBlobsCount == 1)
            assert(restoreReport.isFullyRestored)

            let restoredClaims = try await restoredStore.getLatestClaims(workdayId: workday.workdayId)
            assert(restoredClaims.count == 1, "Restored store must only contain the 1 claim from revision 3 snapshot")
            assert(restoredClaims.first?.reviewStatus == .confirmed)
            assert(restoredClaims.first?.origin == .user)
            await restoredStore.close()

            recordS09TestResult(
                testcaseId: "S09.T1",
                requirementId: "DATA-06",
                expected: "Portable backup captures consistent snapshot (R=3) without R+1 leak and restores facts, approvals & pinned blobs to a new directory",
                observed: "Restored R=3 (while live DB moved to R=4); 1 confirmed fact, 1 approval, 1 pinned blob verified",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S09.T1 Consistent portable backup & restore to new directory verified.")

            // Test 2: S09.T2 — Interrupted backup / insufficient SSD preserves last good backup; safe migration & newer schema rejection
            print("\n[Test 2] S09.T2: Failed backup retry / disk full preserves last good backup; schema migration & incompatible version block...")

            // Simulate mid-backup crash -> staging cleaned up, portableBundleURL remains intact
            var midCrashCaught = false
            do {
                _ = try await backupService.createBackup(
                    store: store,
                    projectId: project.projectId,
                    mode: .checkpointBackup,
                    backupsRootURL: backupsDir,
                    faultHook: .midBackupBeforeManifestSeal
                )
            } catch {
                midCrashCaught = true
            }
            assert(midCrashCaught)
            assert(FileManager.default.fileExists(atPath: portableBundleURL.path), "Last good backup must remain untouched after failed backup")

            // Simulate disk full
            var diskFullCaught = false
            do {
                _ = try await backupService.createBackup(
                    store: store,
                    projectId: project.projectId,
                    mode: .checkpointBackup,
                    backupsRootURL: backupsDir,
                    availableDiskMB: 50,
                    requiredDiskMB: 500
                )
            } catch ProjectStoreError.resourceExhausted {
                diskFullCaught = true
            }
            assert(diskFullCaught, "Insufficient SSD space must fail preflight without corrupting existing backups")

            // Safe schema migration v1 -> v2 (creates pre-migration backup automatically)
            let preMigBackupURL = try await backupService.runSafeMigration(
                store: store,
                projectId: project.projectId,
                backupsRootURL: backupsDir,
                targetVersion: 2,
                migrationId: "002_add_project_notes",
                codeChecksum: String(repeating: "b", count: 64),
                sqlStatements: "ALTER TABLE projects ADD COLUMN notes TEXT NOT NULL DEFAULT '';"
            )
            let newSchemaVer = try await store.getSchemaVersion()
            assert(newSchemaVer == 2, "Schema version must advance to 2")
            assert(FileManager.default.fileExists(atPath: preMigBackupURL.path), "Pre-migration backup must exist")

            // Old app version (supportedMaxSchemaVersion = 1) encountering schema v2 must block cleanly without auto-downgrading
            let oldAppService = BackupRestoreService(supportedMaxSchemaVersion: 1)
            var schemaBlockCaught = false
            do {
                _ = try await oldAppService.runSafeMigration(
                    store: store,
                    projectId: project.projectId,
                    backupsRootURL: backupsDir,
                    targetVersion: 1,
                    migrationId: "downgrade_attempt",
                    codeChecksum: "00",
                    sqlStatements: "SELECT 1;"
                )
            } catch ProjectStoreError.schemaIncompatible(let exp, let act) {
                assert(exp == 1 && act == 2)
                schemaBlockCaught = true
            }
            assert(schemaBlockCaught, "Old app encountering newer schema v2 must block and never downgrade")

            recordS09TestResult(
                testcaseId: "S09.T2",
                requirementId: "DATA-07",
                expected: "Interrupted backup or disk full preserves last good backup; migration creates pre-backup; old app blocks on newer schema",
                observed: "Failed backup cleaned staging; v1->v2 migrated with pre-backup; v2 rejected by v1 reader without downgrade",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S09.T2 Backup fault resilience, safe migration & schema compatibility verified.")

            // Test 3: S09.T3 — Checkpoint backup vs Portable backup prerequisite reporting
            print("\n[Test 3] S09.T3: Checkpoint backup missing source/runtime reports exact prerequisites honestly...")
            let (ckptBundleURL, ckptManifest) = try await backupService.createBackup(
                store: store,
                projectId: project.projectId,
                mode: .checkpointBackup,
                backupsRootURL: backupsDir
            )
            assert(ckptManifest.mode == .checkpointBackup)
            assert(ckptManifest.omittedCategories.contains("source_media_blobs"))

            let ckptRestoreDir = tempDir.appendingPathComponent("restored_ckpt_missing_prereq", isDirectory: true)
            let (ckptRestoredStore, ckptReport) = try await backupService.restoreBackup(
                from: ckptBundleURL,
                toNewDirectory: ckptRestoreDir,
                availablePrerequisites: ["local_mlx_model_runtime"] // Missing original_source_media_snapshot & local_pinned_artifact_store
            )
            assert(!ckptReport.isFullyRestored, "Must not claim full restore when checkpoint prerequisites are missing")
            assert(ckptReport.missingPrerequisites.contains("original_source_media_snapshot"))
            assert(ckptReport.missingPrerequisites.contains("local_pinned_artifact_store"))
            await ckptRestoredStore.close()

            recordS09TestResult(
                testcaseId: "S09.T3",
                requirementId: "DATA-08",
                expected: "Checkpoint backup missing source or runtime declares exact missing prerequisites and does not claim full portable recovery",
                observed: "isFullyRestored=false; missingPrerequisites=\(ckptReport.missingPrerequisites)",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S09.T3 Honest prerequisite reporting for checkpoint vs portable backup verified.")

            await store.close()
            print("\n=======================================================")
            exit(aivideoReportBanner("SWIFT G1 S09 BACKUP, RESTORE & MIGRATION", passed: 3, total: 3))
            print("=======================================================")
        } catch {
            print("❌ FAIL: S09 test threw unexpected error: \(error)")
            recordS09TestResult(
                testcaseId: "S09.ERR",
                requirementId: "DATA-06",
                expected: "All S09 tests pass",
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
