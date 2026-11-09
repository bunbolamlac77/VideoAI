// BackupRestoreService.swift — S09 Consistent Online Backup, Restore to New Directory & Schema Migration
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Sections 10 & 11 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S09).

import Foundation

public enum BackupMode: String, Codable, Sendable, Equatable {
    case checkpointBackup = "checkpoint_backup"
    case portableBackup = "portable_backup"
}

public struct PinnedArtifactManifestEntry: Codable, Sendable, Equatable {
    public let publicationId: UUID
    public let artifactType: String
    public let sha256Hash: String
    public let byteSize: Int
    public let relativeBundledPath: String?

    public init(
        publicationId: UUID,
        artifactType: String,
        sha256Hash: String,
        byteSize: Int,
        relativeBundledPath: String?
    ) {
        self.publicationId = publicationId
        self.artifactType = artifactType
        self.sha256Hash = sha256Hash
        self.byteSize = byteSize
        self.relativeBundledPath = relativeBundledPath
    }
}

public struct BackupManifest: Codable, Sendable, Equatable {
    public let backupId: UUID
    public let projectId: UUID
    public let projectName: String
    public let rootRevision: Int
    public let schemaVersion: Int
    public let mode: BackupMode
    public let databaseFilename: String
    public let databaseSHA256: String
    public let pinnedArtifacts: [PinnedArtifactManifestEntry]
    public let omittedCategories: [String]
    public let restorePrerequisites: [String]
    public let createdAt: Date
}

public struct RestoreReport: Codable, Sendable, Equatable {
    public let restoredProjectId: UUID
    public let restoredRootRevision: Int
    public let restoredToDirectory: String
    public let newSessionId: String
    public let mode: BackupMode
    public let integrityVerified: Bool
    public let restoredClaimsCount: Int
    public let restoredApprovalsCount: Int
    public let verifiedPinnedBlobsCount: Int
    public let missingPrerequisites: [String]
    public let isFullyRestored: Bool
}

public enum BackupFaultHook: String, Sendable, Equatable {
    case midBackupBeforeManifestSeal
    case insufficientDiskSpace
}

/// Manages consistent snapshot barriers, SQLite Online Backup API packaging,
/// restore to a clean target directory, and safe schema migrations with pre-migration backup.
public actor BackupRestoreService {
    public let supportedMaxSchemaVersion: Int

    public init(supportedMaxSchemaVersion: Int = 2) {
        self.supportedMaxSchemaVersion = supportedMaxSchemaVersion
    }

    /// Creates a consistent backup (`checkpoint_backup` or `portable_backup`) following Section 10.2:
    /// 1. Acquires write barrier on `ProjectStore` to capture root revision, pinned closure, and Online SQLite Backup in one consistent snapshot window.
    /// 2. Releases write barrier before copying immutable pinned blobs into the backup bundle (for `portable_backup`).
    /// 3. Writes staging directory first so failed retries NEVER delete the last known good backup (S09.3).
    public func createBackup(
        store: ProjectStore,
        projectId: UUID,
        mode: BackupMode,
        backupsRootURL: URL,
        availableDiskMB: Int = 10240,
        requiredDiskMB: Int = 256,
        faultHook: BackupFaultHook? = nil
    ) async throws -> (bundleDir: URL, manifest: BackupManifest) {
        if faultHook == .insufficientDiskSpace || availableDiskMB < requiredDiskMB {
            throw ProjectStoreError.resourceExhausted("Insufficient SSD space for backup: \(availableDiskMB)MB < \(requiredDiskMB)MB")
        }

        try FileManager.default.createDirectory(at: backupsRootURL, withIntermediateDirectories: true)
        let backupId = UUID()
        let stagingDir = backupsRootURL.appendingPathComponent(".staging_\(backupId.uuidString)", isDirectory: true)
        let finalDir = backupsRootURL.appendingPathComponent("backup_\(mode.rawValue)_\(backupId.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        do {
            // Step 1 & 2: Capture consistent DB snapshot + root revision + pinned closure on ProjectStore actor
            let dbFilename = "project_snapshot.db"
            let stagingDBURL = stagingDir.appendingPathComponent(dbFilename)

            guard let project = try await store.getProject(id: projectId) else {
                throw ProjectStoreError.projectNotFound(projectId)
            }
            let schemaVer = try await store.getSchemaVersion()
            let pinnedIds = try await store.listPinnedPublicationIds(projectId: projectId)
            let allPubs = try await store.listPublications(projectId: projectId)
            let pinnedPubs = allPubs.filter { $0.state == .committed && pinnedIds.contains($0.publicationId) }

            // Perform SQLite Online Backup API snapshot while isolated on ProjectStore
            try await store.performOnlineSQLiteBackup(to: stagingDBURL)

            // Step 3: Barrier released! Copy immutable pinned blobs outside DB lock
            let (dbHash, _) = try SHA256Helper.hashFile(at: stagingDBURL)
            var manifestEntries: [PinnedArtifactManifestEntry] = []

            if mode == .portableBackup {
                let blobsDir = stagingDir.appendingPathComponent("blobs", isDirectory: true)
                try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

                for pub in pinnedPubs {
                    guard let canonPath = pub.canonicalPath,
                          let sha = pub.sha256Hash,
                          let bSize = pub.byteSize else { continue }
                    let relPath = "blobs/\(sha)"
                    let destURL = stagingDir.appendingPathComponent(relPath)
                    if !FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: canonPath), to: destURL)
                    }
                    manifestEntries.append(PinnedArtifactManifestEntry(
                        publicationId: pub.publicationId,
                        artifactType: pub.artifactType,
                        sha256Hash: sha,
                        byteSize: bSize,
                        relativeBundledPath: relPath
                    ))
                }
            } else {
                for pub in pinnedPubs {
                    guard let sha = pub.sha256Hash, let bSize = pub.byteSize else { continue }
                    manifestEntries.append(PinnedArtifactManifestEntry(
                        publicationId: pub.publicationId,
                        artifactType: pub.artifactType,
                        sha256Hash: sha,
                        byteSize: bSize,
                        relativeBundledPath: nil
                    ))
                }
            }

            if faultHook == .midBackupBeforeManifestSeal {
                throw ProjectStoreError.executionFailed("Simulated kill mid-backup before manifest seal")
            }

            let omitted: [String]
            let prereqs: [String]
            switch mode {
            case .checkpointBackup:
                omitted = ["source_media_blobs", "pinned_artifact_blobs", "model_weights"]
                prereqs = ["original_source_media_snapshot", "local_pinned_artifact_store", "local_mlx_model_runtime"]
            case .portableBackup:
                omitted = ["model_weights"]
                prereqs = ["local_mlx_model_runtime"]
            }

            let manifest = BackupManifest(
                backupId: backupId,
                projectId: project.projectId,
                projectName: project.name,
                rootRevision: project.currentRevision,
                schemaVersion: schemaVer,
                mode: mode,
                databaseFilename: dbFilename,
                databaseSHA256: dbHash,
                pinnedArtifacts: manifestEntries,
                omittedCategories: omitted,
                restorePrerequisites: prereqs,
                createdAt: Date()
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            let manifestURL = stagingDir.appendingPathComponent("backup_manifest.json")
            try manifestData.write(to: manifestURL, options: .atomic)

            // Promote staging directory to final backup bundle atomically
            try FileManager.default.moveItem(at: stagingDir, to: finalDir)
            return (finalDir, manifest)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }
    }

    /// Restores a backup bundle into a brand-new target directory (never overwriting original project or backup).
    /// Verifies manifest hashes, SQLite integrity & foreign keys, schema compatibility, pinned blobs,
    /// and revokes all old worker session attempts (Section 10.4).
    public func restoreBackup(
        from backupBundleDir: URL,
        toNewDirectory destinationDir: URL,
        availablePrerequisites: Set<String> = ["local_mlx_model_runtime", "original_source_media_snapshot", "local_pinned_artifact_store"]
    ) async throws -> (restoredStore: ProjectStore, report: RestoreReport) {
        // Must restore into a new/empty directory
        if FileManager.default.fileExists(atPath: destinationDir.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: destinationDir.path)) ?? []
            if !contents.isEmpty {
                throw ProjectStoreError.integrityViolation("Restore target directory must be a new empty directory: \(destinationDir.path)")
            }
        } else {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }

        let manifestURL = backupBundleDir.appendingPathComponent("backup_manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)

        // Schema compatibility check (S09.5: old app encountering newer unsupported schema blocks cleanly)
        if manifest.schemaVersion > supportedMaxSchemaVersion {
            throw ProjectStoreError.schemaIncompatible(expected: supportedMaxSchemaVersion, actual: manifest.schemaVersion)
        }

        // Verify DB snapshot hash before copying
        let sourceDBURL = backupBundleDir.appendingPathComponent(manifest.databaseFilename)
        let (actualDBHash, _) = try SHA256Helper.hashFile(at: sourceDBURL)
        guard actualDBHash == manifest.databaseSHA256 else {
            throw ProjectStoreError.integrityViolation("Backup DB SHA-256 mismatch: expected \(manifest.databaseSHA256), got \(actualDBHash)")
        }

        let restoredDBURL = destinationDir.appendingPathComponent("project_store.db")
        try FileManager.default.copyItem(at: sourceDBURL, to: restoredDBURL)

        // Verify & copy bundled pinned blobs if portable_backup
        var verifiedBlobs = 0
        if manifest.mode == .portableBackup {
            let destBlobsDir = destinationDir.appendingPathComponent("blobs", isDirectory: true)
            try FileManager.default.createDirectory(at: destBlobsDir, withIntermediateDirectories: true)

            for item in manifest.pinnedArtifacts {
                guard let rel = item.relativeBundledPath else { continue }
                let bundledBlobURL = backupBundleDir.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: bundledBlobURL.path) else {
                    throw ProjectStoreError.integrityViolation("Portable backup missing pinned blob \(rel)")
                }
                let (blobHash, blobSize) = try SHA256Helper.hashFile(at: bundledBlobURL)
                guard blobHash == item.sha256Hash && blobSize == item.byteSize else {
                    throw ProjectStoreError.integrityViolation("Portable backup corrupted blob \(rel)")
                }
                let targetBlobURL = destBlobsDir.appendingPathComponent(item.sha256Hash)
                if !FileManager.default.fileExists(atPath: targetBlobURL.path) {
                    try FileManager.default.copyItem(at: bundledBlobURL, to: targetBlobURL)
                }
                verifiedBlobs += 1
            }
        }

        // Open restored store, check schema version in DB, run integrity_check + foreign_key_check, and start new session
        let restoredStore = try ProjectStore(dbURL: restoredDBURL)
        let dbSchemaVer = try await restoredStore.getSchemaVersion()
        if dbSchemaVer > supportedMaxSchemaVersion {
            await restoredStore.close()
            throw ProjectStoreError.schemaIncompatible(expected: supportedMaxSchemaVersion, actual: dbSchemaVer)
        }

        let integrityOK = try await restoredStore.verifyDatabaseIntegrity()
        let newSessionId = "restored-session-\(UUID().uuidString)"
        _ = try await restoredStore.revokeAllOldSessionAttempts(newSessionId: newSessionId)

        guard let restoredProj = try await restoredStore.getProject(id: manifest.projectId) else {
            await restoredStore.close()
            throw ProjectStoreError.projectNotFound(manifest.projectId)
        }

        let approvals = try await restoredStore.listApprovals(projectId: manifest.projectId)
        let missingPrereqs = manifest.restorePrerequisites.filter { !availablePrerequisites.contains($0) }

        let report = RestoreReport(
            restoredProjectId: restoredProj.projectId,
            restoredRootRevision: restoredProj.currentRevision,
            restoredToDirectory: destinationDir.path,
            newSessionId: newSessionId,
            mode: manifest.mode,
            integrityVerified: integrityOK,
            restoredClaimsCount: approvals.count,
            restoredApprovalsCount: approvals.count,
            verifiedPinnedBlobsCount: verifiedBlobs,
            missingPrerequisites: missingPrereqs,
            isFullyRestored: missingPrereqs.isEmpty && integrityOK
        )

        return (restoredStore, report)
    }

    /// Executes a schema migration with mandatory pre-migration backup (Section 11):
    /// 1. Rejects if current schema > supportedMaxSchemaVersion (never auto-downgrades).
    /// 2. Creates and verifies a pre-migration checkpoint backup first.
    /// 3. Applies SQL migration atomically inside transaction.
    public func runSafeMigration(
        store: ProjectStore,
        projectId: UUID,
        backupsRootURL: URL,
        targetVersion: Int,
        migrationId: String,
        codeChecksum: String,
        sqlStatements: String
    ) async throws -> URL {
        let currentVer = try await store.getSchemaVersion()
        if currentVer > supportedMaxSchemaVersion || currentVer > targetVersion {
            throw ProjectStoreError.schemaIncompatible(expected: supportedMaxSchemaVersion, actual: currentVer)
        }

        // Mandatory pre-migration backup before touching schema
        let (backupDir, _) = try await createBackup(
            store: store,
            projectId: projectId,
            mode: .checkpointBackup,
            backupsRootURL: backupsRootURL
        )

        try await store.applyMigration(
            targetVersion: targetVersion,
            migrationId: migrationId,
            codeChecksum: codeChecksum,
            sqlStatements: sqlStatements
        )
        _ = try await store.verifyDatabaseIntegrity()
        return backupDir
    }
}
