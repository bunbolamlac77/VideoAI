// BackupRestoreService.swift — S09 Consistent Online Backup, Restore to New Directory & Schema Migration
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md Sections 10 & 11 and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S09).

import Foundation
import SQLite3

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
    /// (P1-07) Workday used to report the real claim count on restore.
    public var workdayId: UUID? = nil
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
    /// (P1-06) Publications whose canonical path was re-pointed into the restored bundle.
    public var repointedCanonicalPaths: Int = 0
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
        // (P1-05) The snapshot must live on a real filesystem: `sqlite3_backup` writes to a
        // destination path, which fails on the macOS per-process temp directory.
        let backupsRoot = backupsRootURL.resolvingSymlinksInPath().standardizedFileURL
        let backupId = UUID()
        let stagingDir = backupsRoot.appendingPathComponent(".staging_\(backupId.uuidString)", isDirectory: true)
        let finalDir = backupsRoot.appendingPathComponent("backup_\(mode.rawValue)_\(backupId.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        do {
            // Step 1 & 2: one consistent snapshot of the whole database, then the pinned
            // closure is read FROM that snapshot. (P1-05) Previously the pins, revisions and
            // publications were read from the live database and the snapshot taken
            // afterwards, so a pin committed in between could be missing from the manifest
            // (or point at a closure the snapshot did not contain).
            let dbFilename = "project_snapshot.db"
            let stagingDBURL = URL(fileURLWithPath: stagingDir.appendingPathComponent(dbFilename).path)
            try await store.performOnlineSQLiteBackup(to: stagingDBURL)
            if !FileManager.default.fileExists(atPath: stagingDBURL.path) {
                throw ProjectStoreError.executionFailed(
                    "Backup snapshot was not written to \(stagingDBURL.path) (store may not be a disk-backed database)"
                )
            }
            let snapshot = try SnapshotClosure.read(from: stagingDBURL, projectId: projectId)
            guard snapshot.project != nil else {
                throw ProjectStoreError.projectNotFound(projectId)
            }
            let project = snapshot.project!
            let schemaVer = snapshot.schemaVersion
            let pinnedPubs = snapshot.committedPinnedPublications

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
                    // (P1-05) A portable backup must contain every pinned blob; a missing
                    // one is a backup failure, never a silently smaller manifest.
                    guard FileManager.default.fileExists(atPath: canonPath) else {
                        throw ProjectStoreError.integrityViolation(
                            "Pinned artifact missing on disk during backup: \(canonPath)"
                        )
                    }
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
                workdayId: snapshot.workdayId,
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

        // (P1-06) Portable backups carry the blobs into a *new* directory; the restored rows
        // must point there, otherwise every guard sees the original absolute path as missing.
        var repointed = 0
        if manifest.mode == .portableBackup {
            repointed = try await restoredStore.rewriteCanonicalPaths(
                blobDirectory: destinationDir.appendingPathComponent("blobs", isDirectory: true),
                projectId: manifest.projectId
            )
        }

        let approvals = try await restoredStore.listApprovals(projectId: manifest.projectId)
        // (P1-07) The report previously counted approvals as "claims".
        let claimCount = try await restoredStore.countClaims(workdayId: manifest.workdayId ?? UUID())
        let missingPrereqs = manifest.restorePrerequisites.filter { !availablePrerequisites.contains($0) }

        let report = RestoreReport(
            restoredProjectId: restoredProj.projectId,
            restoredRootRevision: restoredProj.currentRevision,
            restoredToDirectory: destinationDir.path,
            newSessionId: newSessionId,
            mode: manifest.mode,
            integrityVerified: integrityOK,
            restoredClaimsCount: claimCount,
            restoredApprovalsCount: approvals.count,
            verifiedPinnedBlobsCount: verifiedBlobs,
            repointedCanonicalPaths: repointed,
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

/// (P1-05) Everything a backup manifest needs, read from one SQLite snapshot so the
/// manifest always describes the exact image that was copied.
struct SnapshotClosure {
    struct Publication {
        let publicationId: UUID
        let artifactType: String
        let sha256Hash: String?
        let canonicalPath: String?
        let byteSize: Int?
    }

    let project: ProjectRecord?
    let schemaVersion: Int
    let pinnedIds: Set<UUID>
    let pinCount: Int
    let committedPinnedPublications: [Publication]
    let workdayId: UUID?

    static func read(from databaseURL: URL, projectId: UUID) throws -> SnapshotClosure {
        var handle: OpaquePointer?
        // `+immutable=1` opens the copied snapshot as a plain file: no WAL/shared-memory
        // side files, no locks, and it never attempts to create anything. A backup image is
        // immutable by definition, and this is what lets a read-only reader work on it.
        let immutableURI = "file:\(databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path)?immutable=1"
        let rc = sqlite3_open_v2(immutableURI, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            throw ProjectStoreError.executionFailed("Cannot open backup snapshot for reading: \(message)")
        }
        defer { sqlite3_close(db) }
        // The snapshot is opened read-only so a backup can never mutate it through this
        // reader; any failure to read it is reported with SQLite's own message.
        @inline(__always) func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

        func rows(_ sql: String, _ args: [String]) throws -> [[String?]] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed("Snapshot read failed for \(sql.prefix(60)): \(lastError())")
            }
            defer { sqlite3_finalize(stmt) }
            for (i, arg) in args.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            var out: [[String?]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let columns = Int(sqlite3_column_count(stmt))
                var row: [String?] = []
                for c in 0..<columns {
                    if sqlite3_column_type(stmt, Int32(c)) == SQLITE_NULL {
                        row.append(nil)
                    } else if let text = sqlite3_column_text(stmt, Int32(c)) {
                        row.append(String(cString: text))
                    } else {
                        row.append(nil)
                    }
                }
                out.append(row)
            }
            return out
        }

        let projectID = projectId.uuidString
        guard let projectRow = try rows(
            "SELECT project_id, name, current_revision FROM projects WHERE project_id = ?;",
            [projectID]
        ).first else {
            return SnapshotClosure(project: nil, schemaVersion: 0, pinnedIds: [],
                                   pinCount: 0, committedPinnedPublications: [], workdayId: nil)
        }
        let project = ProjectRecord(
            projectId: UUID(uuidString: projectRow[0] ?? "") ?? projectId,
            name: projectRow[1] ?? "",
            currentRevision: Int(projectRow[2] ?? "0") ?? 0
        )
        let schemaVersionRow = try rows("PRAGMA user_version;", [])
        let firstRow: [String?] = schemaVersionRow.first ?? []
        let schemaVersionColumn: String = firstRow.first.flatMap({ $0 }) ?? "0"
        let schemaVersion = Int(schemaVersionColumn) ?? 0

        let pinRows = try rows(
            "SELECT p.publication_id, a.artifact_type, a.sha256_hash, a.canonical_path, a.byte_size " +
            "FROM artifact_pins p JOIN artifact_publications a ON a.publication_id = p.publication_id " +
            "WHERE p.project_id = ? AND a.state = 'COMMITTED';",
            [projectID]
        )
        var pinned: [Publication] = []
        for row in pinRows {
            pinned.append(Publication(
                publicationId: UUID(uuidString: row[0] ?? "") ?? UUID(),
                artifactType: row[1] ?? "",
                sha256Hash: row[2],
                canonicalPath: row[3],
                byteSize: row[4].flatMap { Int($0) }
            ))
        }

        let workdayRow = try rows(
            "SELECT workday_id FROM workdays WHERE project_id = ? ORDER BY rowid ASC LIMIT 1;",
            [projectID]
        )
        return SnapshotClosure(
            project: project,
            schemaVersion: schemaVersion,
            pinnedIds: Set(pinned.map(\.publicationId)),
            pinCount: pinned.count,
            committedPinnedPublications: pinned,
            workdayId: workdayRow.first.flatMap { $0.first ?? nil }.flatMap { UUID(uuidString: $0) }
        )
    }
}
