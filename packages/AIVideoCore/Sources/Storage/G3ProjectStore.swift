// G3ProjectStore.swift
// G3 S19: canonical script selection, speech review and approval.
// Only the ProjectStore actor may commit an approval.
// A separate SQLite handle is opened synchronously inside this actor.

import Foundation
import SQLite3
import CryptoKit

public enum G3StoreError: Error, LocalizedError, Sendable {
    case diskStoreRequired
    case invalidPayload(String)
    case conflict(String)
    case blocked(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .diskStoreRequired:
            return "G3 requires canonical on-disk ProjectStore"
        case .invalidPayload(let s):
            return "G3 invalid payload: \(s)"
        case .conflict(let s):
            return "G3 stale revision: \(s)"
        case .blocked(let s):
            return "G3 approval blocked: \(s)"
        case .database(let s):
            return "G3 SQLite error: \(s)"
        }
    }
}

public struct G3StoredDraft: Codable, Sendable {
    public let scriptRevisionId: String
    public let workdayId: UUID
    public let candidateJSON: String
    public let candidateSHA256: String
}

public struct G3ApprovedManifest: Codable, Sendable {
    public let approvalId: UUID
    public let scriptRevisionId: String
    public let manifestJSON: String
    public let manifestSHA256: String
}

private enum G3SQL {
    static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    static func exec(
        _ db: OpaquePointer,
        _ sql: String
    ) throws {
        var error: UnsafeMutablePointer<CChar>?

        guard sqlite3_exec(
            db, sql, nil, nil, &error
        ) == SQLITE_OK else {
            let message = error.map {
                String(cString: $0)
            } ?? String(
                cString: sqlite3_errmsg(db)
            )
            sqlite3_free(error)
            throw G3StoreError.database(message)
        }
    }

    static func prepare(
        _ db: OpaquePointer,
        _ sql: String
    ) throws -> OpaquePointer {
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(
            db, sql, -1, &stmt, nil
        ) == SQLITE_OK,
        let prepared = stmt else {
            throw G3StoreError.database(
                String(cString: sqlite3_errmsg(db))
            )
        }
        return prepared
    }

    static func bind(
        _ stmt: OpaquePointer,
        _ arguments: [String]
    ) throws {
        for (index, text) in arguments.enumerated() {
            guard sqlite3_bind_text(
                stmt,
                Int32(index + 1),
                text,
                -1,
                transient
            ) == SQLITE_OK else {
                throw G3StoreError.database(
                    "Failed to bind SQLite text"
                )
            }
        }
    }

    static func row(
        _ db: OpaquePointer,
        _ sql: String,
        _ args: [String]
    ) throws -> [String]? {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }

        try bind(stmt, args)
        let status = sqlite3_step(stmt)

        if status == SQLITE_DONE {
            return nil
        }

        guard status == SQLITE_ROW else {
            throw G3StoreError.database(
                String(cString: sqlite3_errmsg(db))
            )
        }

        return (
            0..<sqlite3_column_count(stmt)
        ).map { column in
            sqlite3_column_text(
                stmt, column
            ).map {
                String(cString: $0)
            } ?? ""
        }
    }

    static func run(
        _ db: OpaquePointer,
        _ sql: String,
        _ args: [String]
    ) throws {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, args)

        guard sqlite3_step(
            stmt
        ) == SQLITE_DONE else {
            throw G3StoreError.database(
                String(cString: sqlite3_errmsg(db))
            )
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func dictionary(
        _ json: String
    ) throws -> [String: Any] {
        guard let data = json.data(
            using: .utf8
        ),
        let object = try JSONSerialization
            .jsonObject(with: data)
            as? [String: Any] else {
            throw G3StoreError.invalidPayload(
                "Expected JSON object"
            )
        }
        return object
    }

    static func strings(
        _ object: [String: Any],
        _ key: String
    ) throws -> [String] {
        guard let values = object[key]
            as? [String] else {
            throw G3StoreError.invalidPayload(
                "Missing \(key)"
            )
        }
        return values
    }
}

extension ProjectStore {
    private func withG3Transaction<T>(
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let url = dbURL else {
            throw G3StoreError.diskStoreRequired
        }

        var raw: OpaquePointer?

        let flags = (
            SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX
        )

        guard sqlite3_open_v2(
            url.path,
            &raw,
            flags,
            nil
        ) == SQLITE_OK,
        let db = raw else {
            let error = raw.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "cannot open DB"

            if let raw {
                sqlite3_close_v2(raw)
            }

            throw G3StoreError.database(error)
        }

        defer {
            sqlite3_close_v2(db)
        }

        try G3SQL.exec(
            db,
            "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;"
        )
        try G3SQL.exec(db, "BEGIN IMMEDIATE")

        do {
            try G3SQL.exec(db, """
                CREATE TABLE IF NOT EXISTS g3_scripts (
                    script_revision_id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(project_id),
                    workday_id TEXT NOT NULL REFERENCES workdays(workday_id),
                    candidate_json TEXT NOT NULL,
                    candidate_sha256 TEXT NOT NULL,
                    scope_revision_id TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                );

                CREATE TABLE IF NOT EXISTS g3_selected (
                    project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(project_id),
                    script_revision_id TEXT NOT NULL REFERENCES g3_scripts(script_revision_id)
                );

                CREATE TABLE IF NOT EXISTS g3_voice_reviews (
                    script_revision_id TEXT NOT NULL REFERENCES g3_scripts(script_revision_id),
                    beat_id TEXT NOT NULL,
                    publication_id TEXT NOT NULL REFERENCES artifact_publications(publication_id),
                    wav_sha256 TEXT NOT NULL,
                    text_sha256 TEXT NOT NULL,
                    reviewed_by TEXT NOT NULL,
                    reviewed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                    PRIMARY KEY(script_revision_id, beat_id),
                    UNIQUE(script_revision_id, publication_id)
                );

                CREATE TABLE IF NOT EXISTS g3_approvals (
                    approval_id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL REFERENCES projects(project_id),
                    workday_id TEXT NOT NULL REFERENCES workdays(workday_id),
                    script_revision_id TEXT NOT NULL UNIQUE REFERENCES g3_scripts(script_revision_id),
                    candidate_sha256 TEXT NOT NULL,
                    manifest_json TEXT NOT NULL,
                    manifest_sha256 TEXT NOT NULL,
                    approved_by TEXT NOT NULL,
                    approved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                );
                """)

            let result = try body(db)
            try G3SQL.exec(db, "COMMIT")
            return result
        } catch {
            try? G3SQL.exec(db, "ROLLBACK")
            throw error
        }
    }

    public func storeG3Draft(
        projectId: UUID,
        workdayId: UUID,
        candidateJSON: String
    ) throws -> G3StoredDraft {
        let json = try G3SQL.dictionary(
            candidateJSON
        )

        guard
            let rev = json[
                "script_revision_id"
            ] as? String,
            rev.count == 64,
            let scope = json[
                "scope_revision_id"
            ] as? String,
            !scope.isEmpty,
            let beats = json["beats"]
                as? [[String: Any]],
            !beats.isEmpty,
            (
                json["status"] as? String
                    == "DRAFT_NOT_BUILDABLE"
                || json["status"] as? String
                    == "BLOCKED_PENDING_CLAIM_REVALIDATION"
            )
        else {
            throw G3StoreError.invalidPayload(
                "Unrecognized script revision, beat schema or status"
            )
        }

        let hash = G3SQL.sha256(
            Data(candidateJSON.utf8)
        )

        try withG3Transaction { db in
            guard let wd = try G3SQL.row(
                db,
                """
                SELECT project_id FROM workdays
                WHERE workday_id=?
                """,
                [workdayId.uuidString]
            ),
            wd[0].lowercased()
                == projectId.uuidString.lowercased()
            else {
                throw G3StoreError.blocked(
                    "Workday is not in selected project"
                )
            }

            if let existing = try G3SQL.row(
                db,
                """
                SELECT candidate_sha256 FROM g3_scripts
                WHERE script_revision_id=?
                """,
                [rev]
            ) {
                guard existing[0] == hash else {
                    throw G3StoreError.conflict(
                        "Revision already exists with different content"
                    )
                }
            } else {
                try G3SQL.run(
                    db,
                    """
                    INSERT INTO g3_scripts(
                        script_revision_id,
                        project_id,
                        workday_id,
                        candidate_json,
                        candidate_sha256,
                        scope_revision_id
                    ) VALUES(?,?,?,?,?,?)
                    """,
                    [
                        rev,
                        projectId.uuidString,
                        workdayId.uuidString,
                        candidateJSON,
                        hash,
                        scope,
                    ]
                )
            }
        }

        return G3StoredDraft(
            scriptRevisionId: rev,
            workdayId: workdayId,
            candidateJSON: candidateJSON,
            candidateSHA256: hash
        )
    }

    public func selectG3Draft(
        projectId: UUID,
        scriptRevisionId: String
    ) throws {
        try withG3Transaction { db in
            guard let existing = try G3SQL.row(
                db,
                """
                SELECT project_id FROM g3_scripts
                WHERE script_revision_id=?
                """,
                [scriptRevisionId]
            ),
            existing[0].lowercased()
                == projectId.uuidString.lowercased()
            else {
                throw G3StoreError.blocked(
                    "Select an existing script in this project"
                )
            }

            try G3SQL.run(
                db,
                """
                INSERT INTO g3_selected(
                    project_id,script_revision_id
                ) VALUES(?,?)
                ON CONFLICT(project_id) DO UPDATE
                SET script_revision_id=excluded.script_revision_id
                """,
                [
                    projectId.uuidString,
                    scriptRevisionId,
                ]
            )
        }
    }

    public func recordG3SpeechReview(
        projectId: UUID,
        scriptRevisionId: String,
        beatId: String,
        publicationId: UUID,
        expectedSHA256: String,
        reviewer: String
    ) throws {
        guard !reviewer.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw G3StoreError.invalidPayload(
                "Human reviewer is required"
            )
        }

        try withG3Transaction { db in
            guard let script = try G3SQL.row(
                db,
                """
                SELECT project_id,candidate_json
                FROM g3_scripts
                WHERE script_revision_id=?
                """,
                [scriptRevisionId]
            ),
            script[0].lowercased()
                == projectId.uuidString.lowercased()
            else {
                throw G3StoreError.blocked(
                    "Unknown script revision"
                )
            }

            let candidate = try G3SQL.dictionary(
                script[1]
            )
            guard let beats = candidate[
                "beats"
            ] as? [[String: Any]],
            let beat = beats.first(where: {
                $0["beat_id"] as? String == beatId
            }),
            let text = beat["voice_text"]
                as? String else {
                throw G3StoreError.blocked(
                    "Unknown beat or voice text"
                )
            }

            let textSHA256 = G3SQL.sha256(
                Data(text.utf8)
            )

            guard let publication = try G3SQL.row(
                db,
                """
                SELECT state,sha256_hash,canonical_path,artifact_type
                FROM artifact_publications
                WHERE project_id=? AND publication_id=?
                """,
                [
                    projectId.uuidString,
                    publicationId.uuidString,
                ]
            ),
            publication[0] == "COMMITTED",
            publication[1] == expectedSHA256,
            publication[3] == "voice_wav"
            else {
                throw G3StoreError.blocked(
                    "WAV artifact not committed or mismatched"
                )
            }

            let file = URL(
                fileURLWithPath: publication[2]
            )

            guard let bytes = try? Data(
                contentsOf: file
            ),
            G3SQL.sha256(bytes) == expectedSHA256,
            bytes.count >= 44,
            String(
                data: bytes.prefix(4),
                encoding: .ascii
            ) == "RIFF",
            String(
                data: bytes[8..<12],
                encoding: .ascii
            ) == "WAVE"
            else {
                throw G3StoreError.blocked(
                    "WAV missing, tampered or not a RIFF/WAVE file"
                )
            }

            try G3SQL.run(
                db,
                """
                INSERT INTO g3_voice_reviews(
                    script_revision_id,
                    beat_id,
                    publication_id,
                    wav_sha256,
                    text_sha256,
                    reviewed_by
                ) VALUES(?,?,?,?,?,?)
                ON CONFLICT(script_revision_id,beat_id)
                DO UPDATE SET
                    publication_id=excluded.publication_id,
                    wav_sha256=excluded.wav_sha256,
                    text_sha256=excluded.text_sha256,
                    reviewed_by=excluded.reviewed_by,
                    reviewed_at=strftime(
                        '%Y-%m-%dT%H:%M:%SZ','now'
                    )
                """,
                [
                    scriptRevisionId,
                    beatId,
                    publicationId.uuidString,
                    expectedSHA256,
                    textSHA256,
                    reviewer,
                ]
            )
        }
    }

    private func checkG3ClaimRevisions(
        _ db: OpaquePointer,
        _ revisions: [String],
        workdayId: UUID
    ) throws {
        guard
            !revisions.isEmpty,
            revisions.count == Set(revisions).count
        else {
            throw G3StoreError.blocked(
                "No valid/unique claim revision set"
            )
        }

        for rev in revisions {
            guard let claim = try G3SQL.row(
                db,
                """
                SELECT
                    claim_id,origin,review_status,
                    support_status,allowed_use
                FROM claims
                WHERE revision_id=? AND workday_id=?
                """,
                [
                    rev,
                    workdayId.uuidString,
                ]
            ) else {
                throw G3StoreError.conflict(
                    "Claim revision missing: \(rev)"
                )
            }

            guard let latest = try G3SQL.row(
                db,
                """
                SELECT revision_id FROM claims
                WHERE claim_id=?
                ORDER BY rowid DESC LIMIT 1
                """,
                [claim[0]]
            ),
            latest[0] == rev else {
                throw G3StoreError.conflict(
                    "Claim was modified after candidate creation: \(claim[0])"
                )
            }

            guard
                claim[3] == "supported",
                [
                    "direct_claim",
                    "attributed_or_qualified",
                ].contains(claim[4]),
                ![
                    "rejected",
                    "superseded",
                    "needs_review",
                    "unreviewed",
                ].contains(claim[2]),
                claim[1] != "user"
                    || (claim[2] == "confirmed" && claim[4] == "attributed_or_qualified")
            else {
                throw G3StoreError.blocked(
                    "Claim not eligible for narration: \(claim[0])"
                )
            }
        }
    }

    public func approveG3Draft(
        projectId: UUID,
        workdayId: UUID,
        scriptRevisionId: String,
        expectedCandidateSHA256: String,
        manifestJSON: String,
        approvedBy: String
    ) throws -> G3ApprovedManifest {
        guard !approvedBy.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw G3StoreError.invalidPayload(
                "approver is required"
            )
        }

        let manifest = try G3SQL.dictionary(
            manifestJSON
        )

        guard
            manifest["schema_version"] as? String
                == "g3-approval-proposal-v1",
            manifest["script_revision_id"] as? String
                == scriptRevisionId,
            let planSHA = manifest[
                "edit_plan_sha256"
            ] as? String,
            planSHA.count == 64,
            let frames = manifest[
                "total_frames"
            ] as? Int,
            frames > 0,
            frames <= 4319,
            manifest["timeline_profile"] as? String
                == "M-24-SDR-v1",
            let scope = manifest[
                "scope_revision_id"
            ] as? String,
            !scope.isEmpty,
            let pubs = manifest[
                "voice_publications"
            ] as? [[String: String]],
            !pubs.isEmpty
        else {
            throw G3StoreError.invalidPayload(
                "Manifest missing G3 gate fields"
            )
        }

        let manifestSHA = G3SQL.sha256(
            Data(manifestJSON.utf8)
        )

        return try withG3Transaction { db in
            guard let record = try G3SQL.row(
                db,
                """
                SELECT
                    project_id,workday_id,candidate_json,
                    candidate_sha256,scope_revision_id
                FROM g3_scripts
                WHERE script_revision_id=?
                """,
                [scriptRevisionId]
            ),
            record[0].lowercased()
                == projectId.uuidString.lowercased(),
            record[1].lowercased()
                == workdayId.uuidString.lowercased(),
            record[4] == scope
            else {
                throw G3StoreError.conflict(
                    "Selected script or scope changed"
                )
            }

            guard record[3] == expectedCandidateSHA256 else {
                throw G3StoreError.conflict(
                    "Candidate content differs from displayed snapshot"
                )
            }

            guard let selected = try G3SQL.row(
                db,
                """
                SELECT script_revision_id
                FROM g3_selected
                WHERE project_id=?
                """,
                [projectId.uuidString]
            ),
            selected[0] == scriptRevisionId else {
                throw G3StoreError.conflict(
                    "Selecting a script is distinct from approving it"
                )
            }

            let candidate = try G3SQL.dictionary(
                record[2]
            )

            guard candidate["status"] as? String
                == "DRAFT_NOT_BUILDABLE"
            else {
                throw G3StoreError.blocked(
                    "Script edits require revalidation"
                )
            }

            guard let scriptBeats = candidate[
                "beats"
            ] as? [[String: Any]],
            scriptBeats.count == pubs.count
            else {
                throw G3StoreError.blocked(
                    "Voice publication count does not match script beats"
                )
            }

            let scriptRevisions = try G3SQL.strings(
                candidate,
                "claim_revision_ids"
            )
            let manifestRevisions = try G3SQL.strings(
                manifest,
                "claim_revision_ids"
            )

            guard Set(scriptRevisions)
                == Set(manifestRevisions) else {
                throw G3StoreError.conflict(
                    "Manifest claim dependencies differ from script"
                )
            }

            try checkG3ClaimRevisions(
                db,
                scriptRevisions,
                workdayId: workdayId
            )

            // Check the exact canonical text and its provenance.
            var referencedRevisions = Set<String>()

            for beat in scriptBeats {
                guard
                    let refs = beat["claim_refs"]
                        as? [[String: Any]],
                    refs.count == 1,
                    let refRevision = refs[0][
                        "revision_id"
                    ] as? String,
                    let declaredUse = refs[0][
                        "allowed_use"
                    ] as? String,
                    scriptRevisions.contains(
                        refRevision
                    ),
                    let row = try G3SQL.row(
                        db,
                        """
                        SELECT
                            text,allowed_use,epistemic_status
                        FROM claims
                        WHERE revision_id=? AND workday_id=?
                        """,
                        [
                            refRevision,
                            workdayId.uuidString,
                        ]
                    ),
                    declaredUse == row[1],
                    let narration = beat[
                        "voice_text"
                    ] as? String
                else {
                    throw G3StoreError.blocked(
                        "Beat has no exact canonical claim reference"
                    )
                }

                let mustAttribute = (
                    row[1] == "attributed_or_qualified"
                    || row[2] == "reported"
                )
                let expected = (
                    mustAttribute
                    ? "Theo thông tin đã được người quay xác nhận: "
                    : ""
                ) + row[0]

                guard narration == expected else {
                    throw G3StoreError.blocked(
                        "Narration differs from validated claim; revise and revalidate claim first"
                    )
                }

                referencedRevisions.insert(
                    refRevision
                )
            }

            guard referencedRevisions
                == Set(scriptRevisions) else {
                throw G3StoreError.blocked(
                    "Beat/claim revision dependencies are incomplete"
                )
            }

            let pending = try G3SQL.row(
                db,
                """
                SELECT COUNT(*) FROM review_items
                WHERE workday_id=?
                  AND evidence_scope_revision_id=?
                  AND is_critical=1
                  AND status!='resolved'
                """,
                [
                    workdayId.uuidString,
                    scope,
                ]
            )

            guard pending?.first == "0" else {
                throw G3StoreError.blocked(
                    "Critical evidence review is pending"
                )
            }

            for (beat, publication) in zip(
                scriptBeats, pubs
            ) {
                guard
                    let pubId = publication[
                        "publication_id"
                    ],
                    let sha = publication["sha256"],
                    let beatID = beat[
                        "beat_id"
                    ] as? String,
                    let text = beat[
                        "voice_text"
                    ] as? String,
                    publication["beat_id"] == beatID,
                    publication["text_sha256"]
                        == G3SQL.sha256(
                            Data(text.utf8)
                        ),
                    let row = try G3SQL.row(
                        db,
                        """
                        SELECT
                            state,sha256_hash,
                            canonical_path,artifact_type
                        FROM artifact_publications
                        WHERE publication_id=?
                          AND project_id=?
                        """,
                        [
                            pubId,
                            projectId.uuidString,
                        ]
                    ),
                    row[0] == "COMMITTED",
                    row[1] == sha,
                    row[3] == "voice_wav",
                    let reviewed = try G3SQL.row(
                        db,
                        """
                        SELECT wav_sha256,text_sha256
                        FROM g3_voice_reviews
                        WHERE script_revision_id=?
                          AND beat_id=?
                          AND publication_id=?
                        """,
                        [
                            scriptRevisionId,
                            beatID,
                            pubId,
                        ]
                    ),
                    reviewed[0] == sha,
                    reviewed[1] == publication[
                        "text_sha256"
                    ],
                    let bytes = try? Data(
                        contentsOf: URL(
                            fileURLWithPath: row[2]
                        )
                    ),
                    G3SQL.sha256(bytes) == sha
                else {
                    throw G3StoreError.blocked(
                        "WAV must be committed, identical on disk and human-reviewed"
                    )
                }
            }

            // Never approve a hash-only plan: verify a COMMITTED S18 cut,
            // its G2 source/mapping chain and measured WAV durations independently.
            try G3ApprovalGuard.verify(
                db: db, projectId: projectId,
                scriptRevisionId: scriptRevisionId,
                candidate: candidate, manifest: manifest
            )

            if let prior = try G3SQL.row(
                db,
                """
                SELECT
                    approval_id,manifest_sha256,
                    manifest_json
                FROM g3_approvals
                WHERE script_revision_id=?
                """,
                [scriptRevisionId]
            ) {
                guard prior[1] == manifestSHA else {
                    throw G3StoreError.conflict(
                        "Approval exists for a different manifest"
                    )
                }

                return G3ApprovedManifest(
                    approvalId: try requireUUID(prior[0]),
                    scriptRevisionId: scriptRevisionId,
                    manifestJSON: prior[2],
                    manifestSHA256: prior[1]
                )
            }

            let approvalId = UUID()

            try G3SQL.run(
                db,
                """
                INSERT INTO g3_approvals(
                    approval_id,
                    project_id,
                    workday_id,
                    script_revision_id,
                    candidate_sha256,
                    manifest_json,
                    manifest_sha256,
                    approved_by
                ) VALUES(?,?,?,?,?,?,?,?)
                """,
                [
                    approvalId.uuidString,
                    projectId.uuidString,
                    workdayId.uuidString,
                    scriptRevisionId,
                    record[3],
                    manifestJSON,
                    manifestSHA,
                    approvedBy,
                ]
            )

            for publication in pubs {
                try G3SQL.run(
                    db,
                    """
                    INSERT INTO artifact_pins(
                        pin_id,project_id,
                        publication_id,reason
                    ) VALUES(?,?,?,?)
                    """,
                    [
                        UUID().uuidString,
                        projectId.uuidString,
                        publication["publication_id"]!,
                        "G3 script approval \(approvalId.uuidString)",
                    ]
                )
            }

            return G3ApprovedManifest(
                approvalId: approvalId,
                scriptRevisionId: scriptRevisionId,
                manifestJSON: manifestJSON,
                manifestSHA256: manifestSHA
            )
        }
    }

    public func currentG3Approval(
        projectId: UUID
    ) throws -> G3ApprovedManifest? {
        try withG3Transaction { db in
            guard let row = try G3SQL.row(
                db,
                """
                SELECT
                    a.approval_id,
                    a.script_revision_id,
                    a.manifest_json,
                    a.manifest_sha256,
                    a.workday_id,
                    a.candidate_sha256,
                    t.candidate_json,
                    t.candidate_sha256
                FROM g3_approvals a
                JOIN g3_selected s
                  ON s.project_id=a.project_id
                 AND s.script_revision_id=a.script_revision_id
                JOIN g3_scripts t
                  ON t.script_revision_id=a.script_revision_id
                WHERE a.project_id=?
                ORDER BY a.approved_at DESC
                LIMIT 1
                """,
                [projectId.uuidString]
            ) else {
                return nil
            }

            guard row[5] == row[7] else {
                return nil
            }

            let candidate = try G3SQL.dictionary(
                row[6]
            )
            let manifest = try G3SQL.dictionary(
                row[2]
            )

            guard let revisions = candidate[
                "claim_revision_ids"
            ] as? [String],
            let workdayId = UUID(
                uuidString: row[4]
            ),
            let scope = manifest[
                "scope_revision_id"
            ] as? String
            else {
                return nil
            }

            do {
                try checkG3ClaimRevisions(
                    db,
                    revisions,
                    workdayId: workdayId
                )
            } catch {
                return nil
            }

            let pending = try G3SQL.row(
                db,
                """
                SELECT COUNT(*) FROM review_items
                WHERE workday_id=?
                  AND evidence_scope_revision_id=?
                  AND is_critical=1
                  AND status!='resolved'
                """,
                [
                    workdayId.uuidString,
                    scope,
                ]
            )

            guard pending?.first == "0" else {
                return nil
            }

            // Legacy approvals lacking a sealed cut receipt are invalid for G4.
            do {
                try G3ApprovalGuard.verify(
                    db: db, projectId: projectId,
                    scriptRevisionId: row[1],
                    candidate: candidate, manifest: manifest
                )
            } catch {
                return nil
            }

            if let pubs = manifest[
                "voice_publications"
            ] as? [[String: String]],
            let beats = candidate[
                "beats"
            ] as? [[String: Any]],
            pubs.count == beats.count {
                for (beat, pub) in zip(
                    beats, pubs
                ) {
                    guard
                        let pid = pub["publication_id"],
                        let sha = pub["sha256"],
                        let beatID = beat[
                            "beat_id"
                        ] as? String,
                        let text = beat[
                            "voice_text"
                        ] as? String,
                        pub["beat_id"] == beatID,
                        pub["text_sha256"]
                            == G3SQL.sha256(
                                Data(text.utf8)
                            ),
                        let verified = try G3SQL.row(
                            db,
                            """
                            SELECT
                                state,sha256_hash,
                                canonical_path
                            FROM artifact_publications
                            WHERE publication_id=?
                              AND project_id=?
                            """,
                            [
                                pid,
                                projectId.uuidString,
                            ]
                        ),
                        verified[0] == "COMMITTED",
                        verified[1] == sha,
                        let reviewed = try G3SQL.row(
                            db,
                            """
                            SELECT
                                wav_sha256,text_sha256
                            FROM g3_voice_reviews
                            WHERE script_revision_id=?
                              AND beat_id=?
                              AND publication_id=?
                            """,
                            [
                                row[1],
                                beatID,
                                pid,
                            ]
                        ),
                        reviewed[0] == sha,
                        reviewed[1] == pub[
                            "text_sha256"
                        ],
                        let bytes = try? Data(
                            contentsOf: URL(
                                fileURLWithPath: verified[2]
                            )
                        ),
                        G3SQL.sha256(bytes) == sha
                    else {
                        return nil
                    }
                }
            } else {
                return nil
            }

            guard let uuid = UUID(
                uuidString: row[0]
            ) else {
                return nil
            }

            return G3ApprovedManifest(
                approvalId: uuid,
                scriptRevisionId: row[1],
                manifestJSON: row[2],
                manifestSHA256: row[3]
            )
        }
    }
}
