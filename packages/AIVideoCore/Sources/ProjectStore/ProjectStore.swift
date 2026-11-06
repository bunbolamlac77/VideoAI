import Foundation

private struct JournalRecord: Codable {
    let request: String
    let receipt: StoreReceipt
}

/// Sole writer for one canonical project database.
/// No awaits between BEGIN IMMEDIATE and COMMIT.
public actor ProjectStore {
    private let database: SQLiteStoreDatabase

    public init(
        projectRoot: URL,
        migrationsDirectory: URL
    ) throws {
        database = try SQLiteStoreDatabase(
            projectRoot: projectRoot,
            migrationsDirectory: migrationsDirectory
        )
    }

    public func diagnostics() throws -> StoreDiagnostics {
        try database.diagnostics()
    }

    private func payload(
        _ fields: [String: String]
    ) throws -> String {
        let bytes = try JSONSerialization.data(
            withJSONObject: fields,
            options: [.sortedKeys]
        )

        guard let str = String(
            data: bytes,
            encoding: .utf8
        ) else {
            throw ProjectStoreError.invalidInput(
                "Cannot encode command"
            )
        }

        return str
    }

    private func command(
        projectID: UUID,
        operationID: String,
        request: [String: String],
        body: () throws -> StoreReceipt
    ) throws -> StoreReceipt {
        guard !operationID.isEmpty else {
            throw ProjectStoreError.invalidInput(
                "operationID empty"
            )
        }

        let requestString = try payload(request)

        return try database.transaction {
            let previous = try database.rows(
                """
                SELECT result_payload
                FROM idempotency_journal
                WHERE operation_id=?
                """,
                [.text(operationID)]
            ).first

            if let encoded = previous?["result_payload"],
               let bytes = encoded.data(using: .utf8) {
                let journal = try JSONDecoder().decode(
                    JournalRecord.self,
                    from: bytes
                )

                guard journal.request == requestString else {
                    throw ProjectStoreError.idempotencyConflict(
                        operationID: operationID
                    )
                }

                var replay = journal.receipt
                replay.wasReplayed = true
                return replay
            }

            let receipt = try body()

            let record = JournalRecord(
                request: requestString,
                receipt: receipt
            )

            let json = try JSONEncoder().encode(record)

            guard let resultJSON = String(
                data: json,
                encoding: .utf8
            ) else {
                throw ProjectStoreError.invalidInput(
                    "Cannot encode receipt"
                )
            }

            try database.execute(
                """
                INSERT INTO idempotency_journal(
                    operation_id,
                    project_id,
                    fencing_token,
                    result_payload
                ) VALUES(?,?,0,?)
                """,
                [
                    .text(operationID),
                    .text(projectID.uuidString),
                    .text(resultJSON)
                ]
            )

            return receipt
        }
    }

    private func rowForWorkday(
        _ workdayID: UUID
    ) throws -> (project: UUID, revision: Int) {
        guard let row = try database.rows(
            """
            SELECT project_id, revision
            FROM workdays
            WHERE workday_id=?
            """,
            [.text(workdayID.uuidString)]
        ).first,
        let project = row["project_id"].flatMap(
            UUID.init(uuidString:)
        ),
        let revision = row["revision"].flatMap(
            Int.init
        ) else {
            throw ProjectStoreError.notFound("workday")
        }

        return (project, revision)
    }

    private func verifyRevision(
        workdayID: UUID,
        expected: Int
    ) throws -> UUID {
        let current = try rowForWorkday(workdayID)

        guard current.revision == expected else {
            throw ProjectStoreError.revisionConflict(
                expected: expected,
                actual: current.revision
            )
        }

        return current.project
    }

    @discardableResult
    private func bumpWorkday(
        _ workdayID: UUID,
        expected: Int
    ) throws -> Int {
        try database.execute(
            """
            UPDATE workdays
            SET revision=revision+1
            WHERE workday_id=? AND revision=?
            """,
            [
                .text(workdayID.uuidString),
                .integer(Int64(expected))
            ]
        )

        guard database.changes() == 1 else {
            let current = try rowForWorkday(
                workdayID
            ).revision

            throw ProjectStoreError.revisionConflict(
                expected: expected,
                actual: current
            )
        }

        return expected + 1
    }

    public func createProject(
        projectID: UUID,
        name: String,
        operationID: String
    ) throws -> StoreReceipt {
        guard !name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ProjectStoreError.invalidInput(
                "Project name empty"
            )
        }

        return try command(
            projectID: projectID,
            operationID: operationID,
            request: [
                "type": "create_project",
                "project": projectID.uuidString,
                "name": name
            ]
        ) {
            try database.execute(
                """
                INSERT INTO projects(
                    project_id, name, current_revision
                ) VALUES(?,?,1)
                """,
                [
                    .text(projectID.uuidString),
                    .text(name)
                ]
            )

            return StoreReceipt(
                operationID: operationID,
                projectID: projectID,
                workdayID: nil,
                subjectID: projectID,
                committedRevision: 1
            )
        }
    }

    public func createWorkday(
        workdayID: UUID,
        projectID: UUID,
        title: String,
        date: String,
        operationID: String
    ) throws -> StoreReceipt {
        guard !title.isEmpty, date.count == 10 else {
            throw ProjectStoreError.invalidInput(
                "Invalid title or YYYY-MM-DD date"
            )
        }

        return try command(
            projectID: projectID,
            operationID: operationID,
            request: [
                "type": "create_workday",
                "workday": workdayID.uuidString,
                "project": projectID.uuidString,
                "title": title,
                "date": date
            ]
        ) {
            try database.execute(
                """
                INSERT INTO workdays(
                    workday_id, project_id, title, date, revision
                ) VALUES(?,?,?,?,1)
                """,
                [
                    .text(workdayID.uuidString),
                    .text(projectID.uuidString),
                    .text(title),
                    .text(date)
                ]
            )

            try database.execute(
                """
                UPDATE projects
                SET current_revision=current_revision+1,
                    updated_at=strftime(
                        '%Y-%m-%dT%H:%M:%SZ','now'
                    )
                WHERE project_id=?
                """,
                [.text(projectID.uuidString)]
            )

            return StoreReceipt(
                operationID: operationID,
                projectID: projectID,
                workdayID: workdayID,
                subjectID: workdayID,
                committedRevision: 1
            )
        }
    }

    public func workdayRevision(
        _ workdayID: UUID
    ) throws -> Int {
        try rowForWorkday(workdayID).revision
    }

    public func currentBrief(
        _ workdayID: UUID
    ) throws -> BriefSnapshot? {
        guard let row = try database.rows(
            """
            SELECT
                b.brief_revision_id,
                b.content,
                w.revision
            FROM workdays w
            JOIN workday_active_briefs a
                ON a.workday_id=w.workday_id
            JOIN brief_revisions b
                ON b.brief_revision_id=a.brief_revision_id
            WHERE w.workday_id=?
            """,
            [.text(workdayID.uuidString)]
        ).first,
        let id = row["brief_revision_id"].flatMap(
            UUID.init(uuidString:)
        ),
        let content = row["content"],
        let revision = row["revision"].flatMap(
            Int.init
        ) else {
            return nil
        }

        return BriefSnapshot(
            briefRevisionID: id,
            workdayID: workdayID,
            text: content,
            workdayRevision: revision
        )
    }

    public func saveBrief(
        workdayID: UUID,
        expectedRevision: Int,
        text: String,
        operationID: String,
        injectFailureBeforeCommit: Bool = false
    ) throws -> StoreReceipt {
        let project = try rowForWorkday(
            workdayID
        ).project

        return try command(
            projectID: project,
            operationID: operationID,
            request: [
                "type": "save_brief",
                "workday": workdayID.uuidString,
                "expected": "\(expectedRevision)",
                "text": text
            ]
        ) {
            _ = try verifyRevision(
                workdayID: workdayID,
                expected: expectedRevision
            )

            let id = UUID()

            try database.execute(
                """
                INSERT INTO brief_revisions(
                    brief_revision_id,
                    workday_id,
                    base_workday_revision,
                    content
                ) VALUES(?,?,?,?)
                """,
                [
                    .text(id.uuidString),
                    .text(workdayID.uuidString),
                    .integer(Int64(expectedRevision)),
                    .text(text)
                ]
            )

            try database.execute(
                """
                INSERT INTO workday_active_briefs(
                    workday_id,
                    brief_revision_id
                ) VALUES(?,?)
                ON CONFLICT(workday_id)
                DO UPDATE SET
                    brief_revision_id=excluded.brief_revision_id
                """,
                [
                    .text(workdayID.uuidString),
                    .text(id.uuidString)
                ]
            )

            let newRevision = try bumpWorkday(
                workdayID,
                expected: expectedRevision
            )

            if injectFailureBeforeCommit {
                throw ProjectStoreError.simulatedWriteFailure
            }

            return StoreReceipt(
                operationID: operationID,
                projectID: project,
                workdayID: workdayID,
                subjectID: id,
                committedRevision: newRevision
            )
        }
    }

    /// AI can only save proposals targeting the current brief.
    /// It cannot confirm claims or replace user text.
    public func recordAIProposal(
        workdayID: UUID,
        sourceBriefRevisionID: UUID,
        proposalText: String,
        operationID: String
    ) throws -> StoreReceipt {
        let project = try rowForWorkday(
            workdayID
        ).project

        return try command(
            projectID: project,
            operationID: operationID,
            request: [
                "type": "ai_proposal",
                "workday": workdayID.uuidString,
                "brief": sourceBriefRevisionID.uuidString,
                "text": proposalText
            ]
        ) {
            guard try currentBrief(
                workdayID
            )?.briefRevisionID == sourceBriefRevisionID else {
                throw ProjectStoreError.staleAIResult
            }

            let id = UUID()

            try database.execute(
                """
                INSERT INTO extraction_proposals(
                    proposal_id,
                    workday_id,
                    brief_revision_id,
                    proposal_text
                ) VALUES(?,?,?,?)
                """,
                [
                    .text(id.uuidString),
                    .text(workdayID.uuidString),
                    .text(sourceBriefRevisionID.uuidString),
                    .text(proposalText)
                ]
            )

            let revision = try rowForWorkday(
                workdayID
            ).revision

            let next = try bumpWorkday(
                workdayID,
                expected: revision
            )

            return StoreReceipt(
                operationID: operationID,
                projectID: project,
                workdayID: workdayID,
                subjectID: id,
                committedRevision: next
            )
        }
    }

    /// Explicit user confirmation. Does not alter an AI proposal.
    public func confirmUserFact(
        workdayID: UUID,
        expectedRevision: Int,
        factText: String,
        confirmationID: UUID,
        operationID: String
    ) throws -> StoreReceipt {
        guard !factText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ProjectStoreError.invalidInput(
                "Fact text empty"
            )
        }

        let project = try rowForWorkday(
            workdayID
        ).project

        return try command(
            projectID: project,
            operationID: operationID,
            request: [
                "type": "confirm_fact",
                "workday": workdayID.uuidString,
                "expected": "\(expectedRevision)",
                "text": factText,
                "confirmation": confirmationID.uuidString
            ]
        ) {
            _ = try verifyRevision(
                workdayID: workdayID,
                expected: expectedRevision
            )

            let claimID = UUID()
            let revisionID = UUID()

            try database.execute(
                """
                INSERT INTO claims(
                    revision_id,
                    claim_id,
                    workday_id,
                    text,
                    origin,
                    epistemic_status,
                    review_status,
                    support_status,
                    allowed_use,
                    confirmation_id
                ) VALUES(
                    ?,?,?,?,
                    'user',
                    'reported',
                    'confirmed',
                    'insufficient',
                    'attributed_or_qualified',
                    ?
                )
                """,
                [
                    .text(revisionID.uuidString),
                    .text(claimID.uuidString),
                    .text(workdayID.uuidString),
                    .text(factText),
                    .text(confirmationID.uuidString)
                ]
            )

            let next = try bumpWorkday(
                workdayID,
                expected: expectedRevision
            )

            return StoreReceipt(
                operationID: operationID,
                projectID: project,
                workdayID: workdayID,
                subjectID: revisionID,
                committedRevision: next
            )
        }
    }

    public func saveScriptDraft(
        workdayID: UUID,
        sourceBriefRevisionID: UUID,
        expectedRevision: Int,
        text: String,
        operationID: String
    ) throws -> StoreReceipt {
        let project = try rowForWorkday(
            workdayID
        ).project

        return try command(
            projectID: project,
            operationID: operationID,
            request: [
                "type": "draft_script",
                "workday": workdayID.uuidString,
                "brief": sourceBriefRevisionID.uuidString,
                "expected": "\(expectedRevision)",
                "text": text
            ]
        ) {
            _ = try verifyRevision(
                workdayID: workdayID,
                expected: expectedRevision
            )

            guard try currentBrief(
                workdayID
            )?.briefRevisionID == sourceBriefRevisionID else {
                throw ProjectStoreError.staleAIResult
            }

            let id = UUID()

            try database.execute(
                """
                INSERT INTO script_revisions(
                    script_revision_id,
                    workday_id,
                    brief_revision_id,
                    content
                ) VALUES(?,?,?,?)
                """,
                [
                    .text(id.uuidString),
                    .text(workdayID.uuidString),
                    .text(sourceBriefRevisionID.uuidString),
                    .text(text)
                ]
            )

            let next = try bumpWorkday(
                workdayID,
                expected: expectedRevision
            )

            return StoreReceipt(
                operationID: operationID,
                projectID: project,
                workdayID: workdayID,
                subjectID: id,
                committedRevision: next
            )
        }
    }

    public func selectScript(
        workdayID: UUID,
        scriptRevisionID: UUID,
        expectedRevision: Int,
        operationID: String
    ) throws -> StoreReceipt {
        let project = try rowForWorkday(
            workdayID
        ).project

        return try command(
            projectID: project,
            operationID: operationID,
            request: [
                "type": "select_script",
                "workday": workdayID.uuidString,
                "script": scriptRevisionID.uuidString,
                "expected": "\(expectedRevision)"
            ]
        ) {
            _ = try verifyRevision(
                workdayID: workdayID,
                expected: expectedRevision
            )

            let rows = try database.rows(
                """
                SELECT script_revision_id
                FROM script_revisions
                WHERE script_revision_id=?
                  AND workday_id=?
                """,
                [
                    .text(scriptRevisionID.uuidString),
                    .text(workdayID.uuidString)
                ]
            )

            guard !rows.isEmpty else {
                throw ProjectStoreError.notFound(
                    "script revision"
                )
            }

            let selectionID = UUID()

            try database.execute(
                """
                INSERT INTO script_selections(
                    selection_id,
                    workday_id,
                    script_revision_id
                ) VALUES(?,?,?)
                """,
                [
                    .text(selectionID.uuidString),
                    .text(workdayID.uuidString),
                    .text(scriptRevisionID.uuidString)
                ]
            )

            try database.execute(
                """
                INSERT INTO workday_active_scripts(
                    workday_id,
                    selection_id
                ) VALUES(?,?)
                ON CONFLICT(workday_id)
                DO UPDATE SET
                    selection_id=excluded.selection_id
                """,
                [
                    .text(workdayID.uuidString),
                    .text(selectionID.uuidString)
                ]
            )

            let next = try bumpWorkday(
                workdayID,
                expected: expectedRevision
            )

            return StoreReceipt(
                operationID: operationID,
                projectID: project,
                workdayID: workdayID,
                subjectID: selectionID,
                committedRevision: next
            )
        }
    }

    public func approveSelectedScript(
        workdayID: UUID,
        displayedScriptRevisionID: UUID,
        expectedRevision: Int,
        approvedBy: String,
        operationID: String
    ) throws -> StoreReceipt {
        guard !approvedBy.isEmpty else {
            throw ProjectStoreError.invalidInput(
                "approver empty"
            )
        }

        let project = try rowForWorkday(
            workdayID
        ).project

        return try command(
            projectID: project,
            operationID: operationID,
            request: [
                "type": "approve_script",
                "workday": workdayID.uuidString,
                "displayed": displayedScriptRevisionID.uuidString,
                "expected": "\(expectedRevision)",
                "by": approvedBy
            ]
        ) {
            _ = try verifyRevision(
                workdayID: workdayID,
                expected: expectedRevision
            )

            let selected = try database.rows(
                """
                SELECT s.script_revision_id
                FROM workday_active_scripts a
                JOIN script_selections s
                    ON s.selection_id=a.selection_id
                WHERE a.workday_id=?
                """,
                [.text(workdayID.uuidString)]
            ).first?["script_revision_id"]

            guard selected == displayedScriptRevisionID.uuidString else {
                throw ProjectStoreError.approvalTargetMismatch
            }

            let id = UUID()

            try database.execute(
                """
                INSERT INTO approvals(
                    approval_id,
                    project_id,
                    approval_type,
                    target_revision_id,
                    approved_by
                ) VALUES(
                    ?,?,
                    'script_approval',
                    ?,?
                )
                """,
                [
                    .text(id.uuidString),
                    .text(project.uuidString),
                    .text(displayedScriptRevisionID.uuidString),
                    .text(approvedBy)
                ]
            )

            let next = try bumpWorkday(
                workdayID,
                expected: expectedRevision
            )

            return StoreReceipt(
                operationID: operationID,
                projectID: project,
                workdayID: workdayID,
                subjectID: id,
                committedRevision: next
            )
        }
    }

    public func projectRevision(
        _ projectID: UUID
    ) throws -> Int {
        guard let value = try database.scalarInt(
            """
            SELECT current_revision
            FROM projects
            WHERE project_id=?
            """,
            [.text(projectID.uuidString)]
        ) else {
            throw ProjectStoreError.notFound(
                "project"
            )
        }

        return Int(value)
    }

    public func registerPreparedSource(
        _ source: PreparedSourceRecord,
        expectedProjectRevision: Int,
        operationID: String
    ) throws -> StoreReceipt {
        guard source.byteSize > 0,
              source.sha256.count == 64,
              source.sha256.allSatisfy({
                  $0.isHexDigit
              }),
              !source.snapshotPath.contains(".."),
              !source.snapshotPath.hasPrefix("/") else {
            throw ProjectStoreError.invalidInput(
                "Invalid sealed source metadata"
            )
        }

        return try command(
            projectID: source.projectID,
            operationID: operationID,
            request: [
                "type": "register_source",
                "project": source.projectID.uuidString,
                "media": source.mediaID.uuidString,
                "source_revision": source.sourceRevisionID.uuidString,
                "sha256": source.sha256,
                "bytes": "\(source.byteSize)",
                "original": source.originalPath,
                "snapshot": source.snapshotPath,
                "expected": "\(expectedProjectRevision)"
            ]
        ) {
            let current = try projectRevision(
                source.projectID
            )

            guard current == expectedProjectRevision else {
                throw ProjectStoreError.revisionConflict(
                    expected: expectedProjectRevision,
                    actual: current
                )
            }

            let existing = try database.rows(
                """
                SELECT project_id
                FROM source_media
                WHERE media_id=?
                """,
                [.text(source.mediaID.uuidString)]
            ).first

            if let owner = existing?["project_id"] {
                guard owner == source.projectID.uuidString else {
                    throw ProjectStoreError.invalidInput(
                        "Cross-project media reuse"
                    )
                }

                try database.execute(
                    """
                    UPDATE source_media
                    SET original_path=?,
                        content_sha256=?,
                        byte_size=?
                    WHERE media_id=?
                      AND project_id=?
                    """,
                    [
                        .text(source.originalPath),
                        .text(source.sha256),
                        .integer(source.byteSize),
                        .text(source.mediaID.uuidString),
                        .text(source.projectID.uuidString)
                    ]
                )
            } else {
                try database.execute(
                    """
                    INSERT INTO source_media(
                        media_id,
                        project_id,
                        original_path,
                        content_sha256,
                        byte_size
                    ) VALUES(?,?,?,?,?)
                    """,
                    [
                        .text(source.mediaID.uuidString),
                        .text(source.projectID.uuidString),
                        .text(source.originalPath),
                        .text(source.sha256),
                        .integer(source.byteSize)
                    ]
                )
            }

            try database.execute(
                """
                INSERT INTO source_revisions(
                    source_revision_id,
                    media_id,
                    snapshot_path,
                    snapshot_sha256,
                    is_stable
                ) VALUES(?,?,?,?,1)
                """,
                [
                    .text(source.sourceRevisionID.uuidString),
                    .text(source.mediaID.uuidString),
                    .text(source.snapshotPath),
                    .text(source.sha256)
                ]
            )

            try database.execute(
                """
                UPDATE projects
                SET current_revision=current_revision+1,
                    updated_at=strftime(
                        '%Y-%m-%dT%H:%M:%SZ','now'
                    )
                WHERE project_id=?
                  AND current_revision=?
                """,
                [
                    .text(source.projectID.uuidString),
                    .integer(Int64(expectedProjectRevision))
                ]
            )

            guard database.changes() == 1 else {
                throw ProjectStoreError.revisionConflict(
                    expected: expectedProjectRevision,
                    actual: try projectRevision(source.projectID)
                )
            }

            return StoreReceipt(
                operationID: operationID,
                projectID: source.projectID,
                workdayID: nil,
                subjectID: source.sourceRevisionID,
                committedRevision: expectedProjectRevision + 1
            )
        }
    }

    // Used for test diagnostics. Table names are whitelisted.
    public func rowCount(
        table: String
    ) throws -> Int {
        let allowed: Set<String> = [
            "brief_revisions",
            "extraction_proposals",
            "claims",
            "script_revisions",
            "script_selections",
            "approvals",
            "idempotency_journal",
            "source_media",
            "source_revisions"
        ]

        guard allowed.contains(table) else {
            throw ProjectStoreError.invalidInput(
                "unknown table"
            )
        }

        return Int(
            try database.scalarInt(
                "SELECT COUNT(*) FROM \(table)"
            ) ?? 0
        )
    }

    public func committedReceipt(
        operationID: String
    ) throws -> StoreReceipt? {
        guard let str = try database.rows(
            """
            SELECT result_payload
            FROM idempotency_journal
            WHERE operation_id=?
            """,
            [.text(operationID)]
        ).first?["result_payload"],
        let data = str.data(using: .utf8) else {
            return nil
        }

        var receipt = try JSONDecoder().decode(
            JournalRecord.self,
            from: data
        ).receipt

        receipt.wasReplayed = true
        return receipt
    }
}
