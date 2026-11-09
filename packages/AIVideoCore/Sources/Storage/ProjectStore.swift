// ProjectStore.swift — Canonical Single-Writer SQLite WAL Actor for Gate G1 (S06)
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md.

import Foundation
import SQLite3

public enum ProjectStoreError: Error, LocalizedError, Sendable, Equatable {
    case databaseOpenFailed(String)
    case queryFailed(String)
    case executionFailed(String)
    case projectNotFound(UUID)
    case workdayNotFound(UUID)
    case claimNotFound(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case busyTimeout
    case integrityViolation(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let m): return "Database Open Failed: \(m)"
        case .queryFailed(let m): return "Query Failed: \(m)"
        case .executionFailed(let m): return "Execution Failed: \(m)"
        case .projectNotFound(let id): return "Project Not Found: \(id)"
        case .workdayNotFound(let id): return "Workday Not Found: \(id)"
        case .claimNotFound(let id): return "Claim Not Found: \(id)"
        case .revisionConflict(let exp, let act): return "Revision Conflict: expected \(exp), got \(act)"
        case .busyTimeout: return "Database Busy Timeout"
        case .integrityViolation(let m): return "Integrity Violation: \(m)"
        }
    }
}

public struct ProjectRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { projectId }
    public let projectId: UUID
    public let name: String
    public let currentRevision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case name
        case currentRevision = "current_revision"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(projectId: UUID, name: String, currentRevision: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.projectId = projectId
        self.name = name
        self.currentRevision = currentRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WorkdayRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { workdayId }
    public let workdayId: UUID
    public let projectId: UUID
    public let title: String
    public let date: String
    public let revision: Int
    public let createdAt: Date

    public enum CodingKeys: String, CodingKey {
        case workdayId = "workday_id"
        case projectId = "project_id"
        case title
        case date
        case revision
        case createdAt = "created_at"
    }

    public init(workdayId: UUID, projectId: UUID, title: String, date: String, revision: Int = 1, createdAt: Date = Date()) {
        self.workdayId = workdayId
        self.projectId = projectId
        self.title = title
        self.date = date
        self.revision = revision
        self.createdAt = createdAt
    }
}

public struct ApprovalRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { approvalId }
    public let approvalId: UUID
    public let projectId: UUID
    public let approvalType: String
    public let targetRevisionId: UUID
    public let isSuperseded: Bool
    public let approvedBy: String
    public let approvedAt: Date

    public enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case projectId = "project_id"
        case approvalType = "approval_type"
        case targetRevisionId = "target_revision_id"
        case isSuperseded = "is_superseded"
        case approvedBy = "approved_by"
        case approvedAt = "approved_at"
    }

    public init(
        approvalId: UUID = UUID(),
        projectId: UUID,
        approvalType: String,
        targetRevisionId: UUID,
        isSuperseded: Bool = false,
        approvedBy: String,
        approvedAt: Date = Date()
    ) {
        self.approvalId = approvalId
        self.projectId = projectId
        self.approvalType = approvalType
        self.targetRevisionId = targetRevisionId
        self.isSuperseded = isSuperseded
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt
    }
}

final class SQLiteDatabaseHandle: @unchecked Sendable {
    var raw: OpaquePointer?

    init(_ raw: OpaquePointer?) {
        self.raw = raw
    }

    func close() {
        if let raw = raw {
            sqlite3_close_v2(raw)
            self.raw = nil
        }
    }

    deinit {
        close()
    }
}

/// ProjectStore actor: Canonical single-writer SQLite WAL actor.
/// Swift Core holds exclusive commit rights. Workers NEVER receive a write connection.
public actor ProjectStore {
    private let handle: SQLiteDatabaseHandle
    public let dbURL: URL?

    private var db: OpaquePointer? {
        handle.raw
    }

    public init(dbURL: URL? = nil) throws {
        self.dbURL = dbURL
        let path = dbURL?.path ?? ":memory:"
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &connection, flags, nil) != SQLITE_OK {
            let msg = connection != nil ? String(cString: sqlite3_errmsg(connection)) : "Unknown"
            sqlite3_close_v2(connection)
            throw ProjectStoreError.databaseOpenFailed(msg)
        }
        self.handle = SQLiteDatabaseHandle(connection)

        // Apply mandatory pragmas
        try Self.execute(db: connection, sql: "PRAGMA foreign_keys = ON;")
        if dbURL != nil {
            try Self.execute(db: connection, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(db: connection, sql: "PRAGMA synchronous = NORMAL;")
        }
        try Self.execute(db: connection, sql: "PRAGMA busy_timeout = 3000;")

        // Initialize DDL Schema
        try Self.initializeSchema(db: connection)
    }

    public func close() {
        handle.close()
    }

    // MARK: - Direct SQL Execution Helpers

    private static func execute(db: OpaquePointer?, sql: String) throws {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "Unknown error"
            sqlite3_free(err)
            throw ProjectStoreError.executionFailed(msg)
        }
    }

    private func execute(sql: String) throws {
        try Self.execute(db: self.db, sql: sql)
    }

    private static func initializeSchema(db: OpaquePointer?) throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS projects (
            project_id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            current_revision INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS workdays (
            workday_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            title TEXT NOT NULL,
            date TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS source_media (
            media_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            original_path TEXT NOT NULL,
            content_sha256 TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS source_revisions (
            source_revision_id TEXT PRIMARY KEY NOT NULL,
            media_id TEXT NOT NULL REFERENCES source_media(media_id) ON DELETE RESTRICT,
            snapshot_path TEXT NOT NULL,
            snapshot_sha256 TEXT NOT NULL,
            is_stable INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS claims (
            revision_id TEXT PRIMARY KEY NOT NULL,
            claim_id TEXT NOT NULL,
            workday_id TEXT NOT NULL REFERENCES workdays(workday_id) ON DELETE RESTRICT,
            text TEXT NOT NULL,
            origin TEXT NOT NULL CHECK(origin IN ('user', 'visual_model', 'asr', 'audio_detector', 'ocr', 'metadata', 'derived')),
            epistemic_status TEXT NOT NULL CHECK(epistemic_status IN ('observed', 'reported', 'inferred', 'unknown')),
            review_status TEXT NOT NULL CHECK(review_status IN ('unreviewed', 'auto_checked', 'needs_review', 'confirmed', 'rejected', 'superseded')),
            support_status TEXT NOT NULL CHECK(support_status IN ('supported', 'contradicted', 'insufficient', 'disputed')),
            allowed_use TEXT NOT NULL CHECK(allowed_use IN ('direct_claim', 'attributed_or_qualified', 'illustrative_only', 'exclude')),
            source_revision_id TEXT REFERENCES source_revisions(source_revision_id) ON DELETE RESTRICT,
            start_frame INTEGER,
            end_frame INTEGER,
            time_base_num INTEGER,
            time_base_den INTEGER,
            confirmation_id TEXT,
            confidence_raw REAL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS approvals (
            approval_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            approval_type TEXT NOT NULL CHECK(approval_type IN ('fact_confirmation', 'script_approval', 'preview_approval')),
            target_revision_id TEXT NOT NULL,
            is_superseded INTEGER NOT NULL DEFAULT 0,
            approved_by TEXT NOT NULL,
            approved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS idempotency_journal (
            operation_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            fencing_token INTEGER NOT NULL,
            result_payload TEXT NOT NULL,
            committed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_claims_workday ON claims(workday_id);
        CREATE INDEX IF NOT EXISTS idx_claims_claim_id ON claims(claim_id);
        CREATE INDEX IF NOT EXISTS idx_approvals_target ON approvals(target_revision_id);
        """
        try Self.execute(db: db, sql: schema)
    }

    // MARK: - Transaction Wrapper

    private func withTransaction<T>(_ block: () throws -> T) throws -> T {
        try execute(sql: "BEGIN IMMEDIATE;")
        do {
            let result = try block()
            try execute(sql: "COMMIT;")
            return result
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    // MARK: - Projects & Workdays

    public func createProject(id: UUID = UUID(), name: String) throws -> ProjectRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "INSERT INTO projects (project_id, name, current_revision) VALUES (?, ?, 1);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, name, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            return ProjectRecord(projectId: id, name: name, currentRevision: 1)
        }
    }

    public func getProject(id: UUID) throws -> ProjectRecord? {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = "SELECT project_id, name, current_revision, created_at, updated_at FROM projects WHERE project_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let pidStr = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let rev = Int(sqlite3_column_int(stmt, 2))
            let createdStr = String(cString: sqlite3_column_text(stmt, 3))
            let updatedStr = String(cString: sqlite3_column_text(stmt, 4))

            let created = DataContractDateFormatters.date(from: createdStr) ?? Date()
            let updated = DataContractDateFormatters.date(from: updatedStr) ?? Date()
            return ProjectRecord(projectId: UUID(uuidString: pidStr)!, name: name, currentRevision: rev, createdAt: created, updatedAt: updated)
        }
        return nil
    }

    public func createWorkday(id: UUID = UUID(), projectId: UUID, title: String, date: String) throws -> WorkdayRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "INSERT INTO workdays (workday_id, project_id, title, date, revision) VALUES (?, ?, ?, ?, 1);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, date, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                let err = String(cString: sqlite3_errmsg(db))
                if err.contains("FOREIGN KEY") {
                    throw ProjectStoreError.projectNotFound(projectId)
                }
                throw ProjectStoreError.executionFailed(err)
            }
            return WorkdayRecord(workdayId: id, projectId: projectId, title: title, date: date, revision: 1)
        }
    }

    // MARK: - Claims and Revisions

    public func saveClaim(
        claim: ClaimRecord,
        expectedRevision: Int? = nil,
        idempotencyKey: String? = nil
    ) throws -> ClaimRecord {
        return try withTransaction {
            try self.saveClaimInternal(claim: claim, expectedRevision: expectedRevision, idempotencyKey: idempotencyKey)
        }
    }

    private func saveClaimInternal(
        claim: ClaimRecord,
        expectedRevision: Int? = nil,
        idempotencyKey: String? = nil
    ) throws -> ClaimRecord {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

            // 1. Idempotency Check
            if let ikey = idempotencyKey {
                let checkSql = "SELECT result_payload FROM idempotency_journal WHERE operation_id = ?;"
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(checkStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(checkStmt) == SQLITE_ROW {
                        let payload = String(cString: sqlite3_column_text(checkStmt, 0))
                        sqlite3_finalize(checkStmt)
                        if let data = payload.data(using: .utf8),
                           let cached = try? JSONDecoder().decode(ClaimRecord.self, from: data) {
                            return cached
                        }
                    }
                    sqlite3_finalize(checkStmt)
                }
            }

            // 2. Fetch Project and check expected revision
            let getProjSql = "SELECT p.project_id, p.current_revision FROM projects p JOIN workdays w ON p.project_id = w.project_id WHERE w.workday_id = ?;"
            var projStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, getProjSql, -1, &projStmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(projStmt) }
            sqlite3_bind_text(projStmt, 1, claim.workdayId.uuidString, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(projStmt) == SQLITE_ROW else {
                throw ProjectStoreError.workdayNotFound(claim.workdayId)
            }
            let projectIdStr = String(cString: sqlite3_column_text(projStmt, 0))
            let currentRev = Int(sqlite3_column_int(projStmt, 1))
            let projectId = UUID(uuidString: projectIdStr)!

            if let expected = expectedRevision, expected != currentRev {
                throw ProjectStoreError.revisionConflict(expected: expected, actual: currentRev)
            }

            // 3. Insert claim revision
            let insertSql = """
            INSERT INTO claims (
                revision_id, claim_id, workday_id, text, origin, epistemic_status,
                review_status, support_status, allowed_use, source_revision_id,
                start_frame, end_frame, time_base_num, time_base_den, confirmation_id,
                confidence_raw, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var insStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSql, -1, &insStmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(insStmt) }

            sqlite3_bind_text(insStmt, 1, claim.revisionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 2, claim.claimId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 3, claim.workdayId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 4, claim.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 5, claim.origin.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 6, claim.epistemicStatus.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 7, claim.reviewStatus.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 8, claim.supportStatus.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 9, claim.allowedUse.rawValue, -1, SQLITE_TRANSIENT)

            if let srev = claim.sourceRevisionId {
                sqlite3_bind_text(insStmt, 10, srev.uuidString, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insStmt, 10)
            }

            if let tr = claim.timeRange {
                sqlite3_bind_int(insStmt, 11, Int32(tr.startFrame))
                sqlite3_bind_int(insStmt, 12, Int32(tr.endFrame))
                sqlite3_bind_int(insStmt, 13, Int32(tr.timeBaseNum))
                sqlite3_bind_int(insStmt, 14, Int32(tr.timeBaseDen))
            } else {
                sqlite3_bind_null(insStmt, 11)
                sqlite3_bind_null(insStmt, 12)
                sqlite3_bind_null(insStmt, 13)
                sqlite3_bind_null(insStmt, 14)
            }

            if let cid = claim.confirmationId {
                sqlite3_bind_text(insStmt, 15, cid.uuidString, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insStmt, 15)
            }

            if let conf = claim.confidenceRaw {
                sqlite3_bind_double(insStmt, 16, conf)
            } else {
                sqlite3_bind_null(insStmt, 16)
            }

            let dateStr = DataContractDateFormatters.string(from: claim.createdAt)
            sqlite3_bind_text(insStmt, 17, dateStr, -1, SQLITE_TRANSIENT)

            if sqlite3_step(insStmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }

            // 4. Increment Project Revision
            let nextRev = currentRev + 1
            let updateRevSql = "UPDATE projects SET current_revision = ?, updated_at = (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) WHERE project_id = ?;"
            var upStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateRevSql, -1, &upStmt, nil) == SQLITE_OK {
                sqlite3_bind_int(upStmt, 1, Int32(nextRev))
                sqlite3_bind_text(upStmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(upStmt)
                sqlite3_finalize(upStmt)
            }

            // 5. Save to Idempotency Journal
            if let ikey = idempotencyKey {
                let idempSql = "INSERT INTO idempotency_journal (operation_id, project_id, fencing_token, result_payload) VALUES (?, ?, ?, ?);"
                var idempStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, idempSql, -1, &idempStmt, nil) == SQLITE_OK {
                    let encoder = JSONEncoder()
                    if let encoded = try? encoder.encode(claim),
                       let payloadStr = String(data: encoded, encoding: .utf8) {
                        sqlite3_bind_text(idempStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(idempStmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_int(idempStmt, 3, Int32(nextRev))
                        sqlite3_bind_text(idempStmt, 4, payloadStr, -1, SQLITE_TRANSIENT)
                        _ = sqlite3_step(idempStmt)
                    }
                    sqlite3_finalize(idempStmt)
                }
            }

            return claim
    }

    public func confirmFact(
        claimId: UUID,
        confirmationId: UUID = UUID(),
        approvedBy: String,
        expectedRevision: Int? = nil,
        idempotencyKey: String? = nil
    ) throws -> ClaimRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

            // 1. Idempotency Check
            if let ikey = idempotencyKey {
                let checkSql = "SELECT result_payload FROM idempotency_journal WHERE operation_id = ?;"
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(checkStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(checkStmt) == SQLITE_ROW {
                        let payload = String(cString: sqlite3_column_text(checkStmt, 0))
                        sqlite3_finalize(checkStmt)
                        if let data = payload.data(using: .utf8),
                           let cached = try? JSONDecoder().decode(ClaimRecord.self, from: data) {
                            return cached
                        }
                    }
                    sqlite3_finalize(checkStmt)
                }
            }

            // 2. Fetch latest claim revision
            let querySql = """
            SELECT revision_id, claim_id, workday_id, text, origin, epistemic_status,
                   review_status, support_status, allowed_use, source_revision_id,
                   start_frame, end_frame, time_base_num, time_base_den, confirmation_id,
                   confidence_raw, created_at
            FROM claims
            WHERE claim_id = ?
            ORDER BY rowid DESC LIMIT 1;
            """
            var qStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, querySql, -1, &qStmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(qStmt) }
            sqlite3_bind_text(qStmt, 1, claimId.uuidString, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(qStmt) == SQLITE_ROW else {
                throw ProjectStoreError.claimNotFound(claimId)
            }

            let revId = UUID(uuidString: String(cString: sqlite3_column_text(qStmt, 0)))!
            let cId = UUID(uuidString: String(cString: sqlite3_column_text(qStmt, 1)))!
            let wId = UUID(uuidString: String(cString: sqlite3_column_text(qStmt, 2)))!
            let text = String(cString: sqlite3_column_text(qStmt, 3))
            let origin = Origin(rawValue: String(cString: sqlite3_column_text(qStmt, 4)))!
            let epistemic = EpistemicStatus(rawValue: String(cString: sqlite3_column_text(qStmt, 5)))!
            let review = ReviewStatus(rawValue: String(cString: sqlite3_column_text(qStmt, 6)))!
            let support = SupportStatus(rawValue: String(cString: sqlite3_column_text(qStmt, 7)))!
            let allowed = AllowedUse(rawValue: String(cString: sqlite3_column_text(qStmt, 8)))!

            var sourceRev: UUID? = nil
            if sqlite3_column_type(qStmt, 9) != SQLITE_NULL {
                sourceRev = UUID(uuidString: String(cString: sqlite3_column_text(qStmt, 9)))
            }

            var tr: TimeRange? = nil
            if sqlite3_column_type(qStmt, 10) != SQLITE_NULL {
                let start = Int(sqlite3_column_int(qStmt, 10))
                let end = Int(sqlite3_column_int(qStmt, 11))
                let num = Int(sqlite3_column_int(qStmt, 12))
                let den = Int(sqlite3_column_int(qStmt, 13))
                tr = TimeRange(startFrame: start, endFrame: end, timeBaseNum: num, timeBaseDen: den)
            }

            let latestClaim = ClaimRecord(
                claimId: cId,
                revisionId: revId,
                workdayId: wId,
                text: text,
                origin: origin,
                epistemicStatus: epistemic,
                reviewStatus: review,
                supportStatus: support,
                allowedUse: allowed,
                sourceRevisionId: sourceRev,
                timeRange: tr
            )

            // 3. Create fresh revision with review_status = .confirmed
            // Core Invariant S04.T2: Preserves origin (never becomes visualModel or observed)
            let confirmed = latestClaim.confirmingUserFact(confirmationId: confirmationId)

            // Save new claim revision (handles revision increment and journal)
            let saved = try self.saveClaimInternal(claim: confirmed, expectedRevision: expectedRevision, idempotencyKey: nil)

            // Fetch projectId
            let getProjSql = "SELECT project_id FROM workdays WHERE workday_id = ?;"
            var projStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, getProjSql, -1, &projStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(projStmt, 1, wId.uuidString, -1, SQLITE_TRANSIENT)
                if sqlite3_step(projStmt) == SQLITE_ROW {
                    let pId = UUID(uuidString: String(cString: sqlite3_column_text(projStmt, 0)))!

                    // 4. Record in Approvals Table
                    let appSql = "INSERT INTO approvals (approval_id, project_id, approval_type, target_revision_id, approved_by) VALUES (?, ?, 'fact_confirmation', ?, ?);"
                    var appStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, appSql, -1, &appStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(appStmt, 1, confirmationId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(appStmt, 2, pId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(appStmt, 3, saved.revisionId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(appStmt, 4, approvedBy, -1, SQLITE_TRANSIENT)
                        _ = sqlite3_step(appStmt)
                        sqlite3_finalize(appStmt)
                    }

                    // 5. Record Idempotency Journal
                    if let ikey = idempotencyKey {
                        let idempSql = "INSERT INTO idempotency_journal (operation_id, project_id, fencing_token, result_payload) VALUES (?, ?, 0, ?);"
                        var idempStmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, idempSql, -1, &idempStmt, nil) == SQLITE_OK {
                            if let encoded = try? JSONEncoder().encode(saved),
                               let payloadStr = String(data: encoded, encoding: .utf8) {
                                sqlite3_bind_text(idempStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                                sqlite3_bind_text(idempStmt, 2, pId.uuidString, -1, SQLITE_TRANSIENT)
                                sqlite3_bind_text(idempStmt, 3, payloadStr, -1, SQLITE_TRANSIENT)
                                _ = sqlite3_step(idempStmt)
                            }
                            sqlite3_finalize(idempStmt)
                        }
                    }
                }
                sqlite3_finalize(projStmt)
            }

            return saved
        }
    }

    public func getLatestClaims(workdayId: UUID) throws -> [ClaimRecord] {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        // Select latest revision for each claim_id
        let sql = """
        SELECT c.revision_id, c.claim_id, c.workday_id, c.text, c.origin, c.epistemic_status,
               c.review_status, c.support_status, c.allowed_use, c.source_revision_id,
               c.start_frame, c.end_frame, c.time_base_num, c.time_base_den, c.confirmation_id,
               c.confidence_raw, c.created_at
        FROM claims c
        INNER JOIN (
            SELECT claim_id, MAX(rowid) as max_rowid
            FROM claims
            WHERE workday_id = ?
            GROUP BY claim_id
        ) latest ON c.rowid = latest.max_rowid;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, workdayId.uuidString, -1, SQLITE_TRANSIENT)

        var list: [ClaimRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let revId = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0)))!
            let cId = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1)))!
            let wId = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 2)))!
            let text = String(cString: sqlite3_column_text(stmt, 3))
            let origin = Origin(rawValue: String(cString: sqlite3_column_text(stmt, 4)))!
            let epistemic = EpistemicStatus(rawValue: String(cString: sqlite3_column_text(stmt, 5)))!
            let review = ReviewStatus(rawValue: String(cString: sqlite3_column_text(stmt, 6)))!
            let support = SupportStatus(rawValue: String(cString: sqlite3_column_text(stmt, 7)))!
            let allowed = AllowedUse(rawValue: String(cString: sqlite3_column_text(stmt, 8)))!

            var sourceRev: UUID? = nil
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                sourceRev = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 9)))
            }

            var tr: TimeRange? = nil
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let start = Int(sqlite3_column_int(stmt, 10))
                let end = Int(sqlite3_column_int(stmt, 11))
                let num = Int(sqlite3_column_int(stmt, 12))
                let den = Int(sqlite3_column_int(stmt, 13))
                tr = TimeRange(startFrame: start, endFrame: end, timeBaseNum: num, timeBaseDen: den)
            }

            var confId: UUID? = nil
            if sqlite3_column_type(stmt, 14) != SQLITE_NULL {
                confId = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 14)))
            }

            var confRaw: Double? = nil
            if sqlite3_column_type(stmt, 15) != SQLITE_NULL {
                confRaw = sqlite3_column_double(stmt, 15)
            }

            let dateStr = String(cString: sqlite3_column_text(stmt, 16))
            let created = DataContractDateFormatters.date(from: dateStr) ?? Date()

            list.append(ClaimRecord(
                claimId: cId,
                revisionId: revId,
                workdayId: wId,
                text: text,
                origin: origin,
                epistemicStatus: epistemic,
                reviewStatus: review,
                supportStatus: support,
                allowedUse: allowed,
                sourceRevisionId: sourceRev,
                timeRange: tr,
                confirmationId: confId,
                confidenceRaw: confRaw,
                createdAt: created
            ))
        }
        return list
    }

    public func checkpointWAL() throws {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        var log = Int32(0)
        var ckpt = Int32(0)
        if sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, &log, &ckpt) != SQLITE_OK {
            throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}

// SQLITE_TRANSIENT helper:
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
