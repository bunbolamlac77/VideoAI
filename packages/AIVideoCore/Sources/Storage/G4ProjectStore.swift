// S21 canonical preview approval. No worker RPC is allowed to approve previews.
import Foundation
import SQLite3
import CryptoKit

public struct G4PreviewApproval: Codable, Sendable {
    public let approvalId: UUID
    public let projectId: UUID
    public let g3ApprovalId: UUID
    public let previewPublicationId: UUID
    public let previewSHA256: String
    public let planSHA256: String
    public let reviewedBy: String
}

private enum G4SQL {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw G3StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    static func row(_ db: OpaquePointer, _ sql: String, _ args: [String]) throws -> [String]? {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else {
            throw G3StoreError.database("G4 SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let status = arg.withCString { ptr in
                sqlite3_bind_text(stmt, Int32(i + 1), ptr, -1, transient)
            }
            guard status == SQLITE_OK else { throw G3StoreError.database("G4 bind failed") }
        }
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else {
            throw G3StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        return (0..<sqlite3_column_count(stmt)).map { column in
            sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
        }
    }

    static func run(_ db: OpaquePointer, _ sql: String, _ args: [String]) throws {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else {
            throw G3StoreError.database("G4 SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let status = arg.withCString { ptr in
                sqlite3_bind_text(stmt, Int32(i + 1), ptr, -1, transient)
            }
            guard status == SQLITE_OK else { throw G3StoreError.database("G4 bind failed") }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw G3StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    static func json(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw G3StoreError.invalidPayload("G4 receipt must be JSON object")
        }
        return object
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileSHA(_ filePath: String) throws -> (String, Int64) {
        let file = URL(fileURLWithPath: filePath)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var state = SHA256()
        var count: Int64 = 0
        while true {
            let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            count += Int64(bytes.count)
            guard count <= 4 * 1024 * 1024 * 1024 else {
                throw G3StoreError.blocked("Preview is too large")
            }
            state.update(data: bytes)
        }
        return (state.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}

extension ProjectStore {
    // Dedicated G4 transaction because G3's helper is intentionally private.
    private func g4Transaction<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        guard dbURL != nil else { throw G3StoreError.diskStoreRequired }
        return try withCanonicalTransaction(block)
    }

    public func approveG4Preview(
        projectId: UUID,
        previewPublicationId: UUID,
        receiptJSON: String,
        reviewedBy: String,
        reviewNotes: String,
        watchedVideoAndListenedToAudio: Bool
    ) throws -> G4PreviewApproval {
        guard watchedVideoAndListenedToAudio,
              !reviewedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else {
            throw G3StoreError.blocked("Explicit complete audiovisual/content QC and meaningful notes required")
        }
        // This actor verifies the current authoritative G3 approval, not a worker bool.
        guard let current = try currentG3Approval(projectId: projectId) else {
            throw G3StoreError.blocked("G3 approval invalid/stale; cannot approve G4")
        }
        let receipt = try G4SQL.json(receiptJSON)
        guard receipt["status"] as? String == "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
              // (P2-03) UUIDs cross the Python/Swift border in both cases; compare as UUIDs.
              ProvenanceValue.uuidsMatch(receipt["g3_approval_id"] as? String,
                                         current.approvalId.uuidString),
              receipt["g3_manifest_sha256"] as? String == current.manifestSHA256,
              let previewSHA = receipt["preview_sha256"] as? String,
              previewSHA.count == 64,
              let planSHA = receipt["plan_sha256"] as? String,
              planSHA.count == 64,
              let timelineUID = receipt["timeline_uid"] as? String,
              !timelineUID.isEmpty,
              let timelineSignature = receipt["timeline_signature"] as? String,
              timelineSignature.count == 64,
              let renderJob = receipt["render_job_id"] as? String,
              !renderJob.isEmpty,
              let dependencies = receipt["required_publication_ids"] as? [String],
              dependencies.count >= 5, dependencies.count <= 193,
              dependencies.count == Set(dependencies).count,
              dependencies.allSatisfy({ UUID(uuidString: $0) != nil }),
              let qc = receipt["qc"] as? [String: Any],
              qc["status"] as? String == "TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
              qc["sha256"] as? String == previewSHA,
              qc["semantic_verified"] as? Bool == false,
              let profile = qc["verified"] as? [String: Any],
              profile["width"] as? Int == 1080,
              profile["height"] as? Int == 1920,
              profile["fps"] as? Int == 24,
              profile["color"] as? String == "bt709" else {
            throw G3StoreError.blocked("G4 render/QC receipt is not tied to the current preview snapshot")
        }
        return try g4Transaction { db in
            guard let approval = try G4SQL.row(db, """
                SELECT a.manifest_sha256,a.script_revision_id,a.workday_id,a.manifest_json,
                       s.candidate_json
                FROM g3_approvals a JOIN g3_scripts s
                  ON s.script_revision_id=a.script_revision_id
                JOIN g3_selected chosen ON chosen.project_id=a.project_id
                  AND chosen.script_revision_id=a.script_revision_id
                WHERE a.project_id=? AND a.approval_id=?
                """, [projectId.uuidString, current.approvalId.uuidString]),
                approval[0] == current.manifestSHA256 else {
                throw G3StoreError.conflict("G3 approval changed during G4 transaction")
            }
            // Re-run the S19 independent cut/source/WAV verifier while holding the write lock.
            try G3ApprovalGuard.verify(
                db: db, projectId: projectId, scriptRevisionId: approval[1],
                candidate: try G4SQL.json(approval[4]),
                manifest: try G4SQL.json(approval[3])
            )
            // Pin every final dependency, not only the preview. Never trust an
            // RPC list without verifying all immutable S08 records and bytes.
            let script = try G4SQL.json(approval[4])
            guard let beats = script["beats"] as? [[String: Any]],
                  beats.count >= 1, beats.count <= 48,
                  dependencies.count >= 2 + 3 * beats.count,
                  dependencies.count <= 1 + 4 * beats.count else {
                throw G3StoreError.blocked("G4 S08 dependencies incomplete for approved beats")
            }
            var typeCounts: [String: Int] = [:]
            let requiredKinds = Set(["g3_cut_plan", "g2_source_mapping",
                                     "voice_wav", "g4_captioned_cfr", "g4_conform_receipt"])
            for depID in dependencies {
                guard let dep = try G4SQL.row(db, """
                    SELECT state,artifact_type,sha256_hash,canonical_path,byte_size
                    FROM artifact_publications WHERE publication_id=? AND project_id=?
                    """, [depID, projectId.uuidString]),
                    dep[0] == "COMMITTED", requiredKinds.contains(dep[1]),
                    let bytes = Int64(dep[4]), bytes > 0,
                    let checked = try? G4SQL.fileSHA(dep[3]),
                    checked.0 == dep[2], checked.1 == bytes else {
                    throw G3StoreError.blocked("G4 dependency is missing or was modified")
                }
                typeCounts[dep[1], default: 0] += 1
            }
            guard typeCounts["g3_cut_plan"] == 1,
                  (typeCounts["g2_source_mapping"] ?? 0) >= 1,
                  (typeCounts["g2_source_mapping"] ?? 0) <= beats.count,
                  typeCounts["voice_wav"] == beats.count,
                  typeCounts["g4_captioned_cfr"] == beats.count,
                  typeCounts["g4_conform_receipt"] == beats.count else {
                throw G3StoreError.blocked("G4 dependency types/counts invalid")
            }
            guard let pub = try G4SQL.row(db, """
                SELECT state,artifact_type,sha256_hash,canonical_path,byte_size
                FROM artifact_publications WHERE publication_id=? AND project_id=?
                """, [previewPublicationId.uuidString, projectId.uuidString]),
                pub[0] == "COMMITTED", pub[1] == "g4_preview_mp4",
                pub[2] == previewSHA,
                let expectedSize = Int64(pub[4]), expectedSize > 1024 else {
                throw G3StoreError.blocked("G4 preview is not a committed S08 MP4")
            }
            // Re-derive every dependency relationship before accepting a worker QC receipt.
            try G4S21Guard.verifyBindings(
                db: db, project: projectId,
                candidate: script, manifest: try G4SQL.json(approval[3]),
                dependencyIDs: dependencies
            )
            let previewFile = URL(fileURLWithPath: pub[3])
            let previewHandle = try FileHandle(forReadingFrom: previewFile)
            let header = try previewHandle.read(upToCount: 16) ?? Data()
            try previewHandle.close()
            guard header.count >= 12,
                  String(data: header[4..<8], encoding: .ascii) == "ftyp" else {
                throw G3StoreError.blocked("Published preview is not an MP4 container")
            }
            let measured = try G4SQL.fileSHA(pub[3])
            guard measured.0 == previewSHA && measured.1 == expectedSize else {
                throw G3StoreError.blocked("Published G4 preview bytes changed")
            }
            // No fabricated MP4 or forged technical-pass receipt may grant approval.
            guard let totalFrames = (try G4SQL.json(approval[3]))["total_frames"] as? Int else {
                throw G3StoreError.blocked("Approved G3 frame count missing")
            }
            try G4S21Guard.verifyPreview(path: pub[3], expectedFrames: totalFrames)
            if let existing = try G4SQL.row(db, """
                SELECT approval_id,reviewed_by,preview_publication_id FROM g4_preview_approvals
                WHERE project_id=? AND g3_approval_id=? AND preview_sha256=?
                """, [projectId.uuidString, current.approvalId.uuidString, previewSHA]),
               let existingId = UUID(uuidString: existing[0]) {
                guard existing[2].lowercased() == previewPublicationId.uuidString.lowercased() else {
                    throw G3StoreError.conflict("Same preview bytes already approved under another publication ID")
                }
                return G4PreviewApproval(
                    approvalId: existingId, projectId: projectId,
                    g3ApprovalId: current.approvalId, previewPublicationId: previewPublicationId,
                    previewSHA256: previewSHA, planSHA256: planSHA, reviewedBy: existing[1]
                )
            }
            let approvalId = UUID()
            try G4SQL.run(db, """
                INSERT INTO g4_preview_approvals(
                    approval_id,project_id,g3_approval_id,preview_publication_id,
                    preview_sha256,plan_sha256,qc_receipt_json,qc_receipt_sha256,
                    reviewed_by,review_notes
                ) VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [approvalId.uuidString, projectId.uuidString, current.approvalId.uuidString,
                       previewPublicationId.uuidString, previewSHA, planSHA, receiptJSON,
                       G4SQL.sha(Data(receiptJSON.utf8)), reviewedBy, reviewNotes])
            for depID in dependencies {
                try G4SQL.run(db, """
                    INSERT INTO artifact_pins(pin_id,project_id,publication_id,reason)
                    VALUES(?,?,?,?)
                    """, [UUID().uuidString, projectId.uuidString, depID,
                           "S21 final dependency \(approvalId.uuidString)"])
            }
            try G4SQL.run(db, """
                INSERT INTO artifact_pins(pin_id,project_id,publication_id,reason)
                VALUES(?,?,?,?)
                """, [UUID().uuidString, projectId.uuidString,
                       previewPublicationId.uuidString, "S21 approved preview \(approvalId.uuidString)"])
            return G4PreviewApproval(
                approvalId: approvalId, projectId: projectId,
                g3ApprovalId: current.approvalId, previewPublicationId: previewPublicationId,
                previewSHA256: previewSHA, planSHA256: planSHA, reviewedBy: reviewedBy
            )
        }
    }

    public func currentG4Preview(projectId: UUID) throws -> G4PreviewApproval? {
        guard let current = try currentG3Approval(projectId: projectId) else { return nil }
        // (P2-05) read-only; this path hashes the preview file inside the closure
        return try withCanonicalRead { db in
            guard let found = try G4SQL.row(db, """
                SELECT p.approval_id,p.preview_publication_id,p.preview_sha256,
                       p.plan_sha256,p.reviewed_by,p.qc_receipt_json,
                       a.sha256_hash,a.canonical_path,a.state
                FROM g4_preview_approvals p
                JOIN artifact_publications a ON a.publication_id=p.preview_publication_id
                WHERE p.project_id=? AND p.g3_approval_id=?
                ORDER BY p.approved_at DESC,p.rowid DESC LIMIT 1
                """, [projectId.uuidString, current.approvalId.uuidString]),
                found[2] == found[6], found[8] == "COMMITTED",
                let pubUUID = UUID(uuidString: found[1]),
                let approvalUUID = UUID(uuidString: found[0]),
                let measured = try? G4SQL.fileSHA(found[7]), measured.0 == found[2] else {
                return nil
            }
            guard let receipt = try? G4SQL.json(found[5]),
                  let dependencies = receipt["required_publication_ids"] as? [String],
                  dependencies.count >= 5,
                  dependencies.count == Set(dependencies).count else {
                return nil
            }
            for depID in dependencies {
                guard let dep = try G4SQL.row(db, """
                    SELECT state,sha256_hash,canonical_path,byte_size
                    FROM artifact_publications WHERE publication_id=? AND project_id=?
                    """, [depID, projectId.uuidString]),
                    dep[0] == "COMMITTED",
                    let size = Int64(dep[3]), size > 0,
                    let actual = try? G4SQL.fileSHA(dep[2]),
                    actual.0 == dep[1], actual.1 == size else { return nil }
            }
            // A G5 caller must get an actively revalidated, decodable preview.
            guard let manifestRow = try G4SQL.row(db, """
                SELECT a.manifest_json, s.candidate_json
                FROM g3_approvals a JOIN g3_scripts s
                  ON s.script_revision_id=a.script_revision_id
                WHERE a.project_id=? AND a.approval_id=?
                """, [projectId.uuidString, current.approvalId.uuidString]),
                  let receipt = try? G4SQL.json(found[5]),
                  let dependencyIDs = receipt["required_publication_ids"] as? [String] else {
                return nil
            }
            do {
                try G4S21Guard.verifyBindings(
                    db: db, project: projectId,
                    candidate: try G4SQL.json(manifestRow[1]),
                    manifest: try G4SQL.json(manifestRow[0]),
                    dependencyIDs: dependencyIDs
                )
                let canonical = try G4SQL.json(manifestRow[0])
                guard let total = canonical["total_frames"] as? Int else { return nil }
                try G4S21Guard.verifyPreview(path: found[7], expectedFrames: total)
            } catch { return nil }
            return G4PreviewApproval(
                approvalId: approvalUUID, projectId: projectId,
                g3ApprovalId: current.approvalId, previewPublicationId: pubUUID,
                previewSHA256: found[2], planSHA256: found[3], reviewedBy: found[4]
            )
        }
    }
}
