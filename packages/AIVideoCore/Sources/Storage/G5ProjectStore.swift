// G5ProjectStore.swift — Gate G5 S22 Canonical Final Render Approval & Manual Handoff Branch.
// Only the Swift ProjectStore actor may commit canonical S22 final approvals or manual handoff
// branches. Any upstream mutation (sealed source, claim, G3 script, S21 preview, or G5 asset)
// invalidates the active final approval (`INV-05`, `RES-03`, `RES-05`).

import Foundation
import SQLite3
import CryptoKit

public struct G5FinalApproval: Codable, Sendable {
    public let approvalId: UUID
    public let projectId: UUID
    public let g3ApprovalId: UUID
    public let g4ApprovalId: UUID
    public let finalPublicationId: UUID
    public let drpPublicationId: UUID
    public let finalSHA256: String
    public let drpSHA256: String
    public let planSHA256: String
    public let reviewedBy: String
}

public struct G5ManualHandoffRecord: Codable, Sendable {
    public let branchId: UUID
    public let projectId: UUID
    public let g4ApprovalId: UUID
    public let handoffDrpPublicationId: UUID
    public let handoffDrpSHA256: String
    public let handoffProjectName: String
    public let createdBy: String
}

/// S24.2 & S24.T3: Preserves active Vietnamese IME marked text composition (`markedRange`)
/// so background worker updates or autosave ticks never clobber uncommitted diacritics.
public struct G5VietnameseIMEBuffer: Sendable {
    public private(set) var committedText: String
    public private(set) var markedComposition: String?

    public init(initialText: String = "") {
        self.committedText = initialText
        self.markedComposition = nil
    }

    public var hasActiveComposition: Bool {
        guard let marked = markedComposition else { return false }
        return !marked.isEmpty
    }

    public mutating func beginComposition(_ marked: String) {
        self.markedComposition = marked
    }

    public mutating func commitComposition(_ finalSegment: String) {
        self.committedText += finalSegment
        self.markedComposition = nil
    }

    /// Background state sync is deferred while `hasActiveComposition == true`.
    public mutating func applyBackgroundRefreshIfSafe(_ externalText: String) -> Bool {
        guard !hasActiveComposition else { return false }
        self.committedText = externalText
        return true
    }
}

/// S24.3 & S24.T2: Strictly bounded LRU cache for preview player items, thumbnails, and logs.
/// Prevents memory growth across 50+ preview switch cycles on 16 GB Apple Silicon.
public struct G5BoundedPreviewCache: Sendable {
    public let maxActivePlayers: Int
    public let maxThumbnailCount: Int
    public let maxThumbnailBytes: Int
    public private(set) var activePlayerIDs: [String] = []
    public private(set) var thumbnailKeys: [String] = []
    public private(set) var thumbnailSizes: [String: Int] = [:]
    public private(set) var totalBytes: Int = 0
    public private(set) var evictedCount: Int = 0

    public init(
        maxActivePlayers: Int = 2,
        maxThumbnailCount: Int = 24,
        maxThumbnailBytes: Int = 32 * 1024 * 1024
    ) {
        self.maxActivePlayers = max(1, maxActivePlayers)
        self.maxThumbnailCount = max(4, maxThumbnailCount)
        self.maxThumbnailBytes = max(1024 * 1024, maxThumbnailBytes)
    }

    public mutating func activatePlayer(id: String) {
        activePlayerIDs.removeAll { $0 == id }
        activePlayerIDs.append(id)
        while activePlayerIDs.count > maxActivePlayers {
            _ = activePlayerIDs.removeFirst()
            evictedCount += 1
        }
    }

    public mutating func insertThumbnail(key: String, byteCount: Int) {
        let clamped = max(1, min(byteCount, maxThumbnailBytes))
        if let old = thumbnailSizes.removeValue(forKey: key) {
            totalBytes -= old
            thumbnailKeys.removeAll { $0 == key }
        }
        thumbnailKeys.append(key)
        thumbnailSizes[key] = clamped
        totalBytes += clamped
        while thumbnailKeys.count > maxThumbnailCount || totalBytes > maxThumbnailBytes {
            let oldest = thumbnailKeys.removeFirst()
            if let removedBytes = thumbnailSizes.removeValue(forKey: oldest) {
                totalBytes -= removedBytes
            }
            evictedCount += 1
        }
    }
}

private enum G5SQL {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw G3StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    static func row(_ db: OpaquePointer, _ sql: String, _ args: [String]) throws -> [String]? {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else {
            throw G3StoreError.database("G5 SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let status = arg.withCString { ptr in
                sqlite3_bind_text(stmt, Int32(i + 1), ptr, -1, transient)
            }
            guard status == SQLITE_OK else { throw G3StoreError.database("G5 bind failed") }
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
            throw G3StoreError.database("G5 SQLite prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let status = arg.withCString { ptr in
                sqlite3_bind_text(stmt, Int32(i + 1), ptr, -1, transient)
            }
            guard status == SQLITE_OK else { throw G3StoreError.database("G5 bind failed") }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw G3StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    static func json(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw G3StoreError.invalidPayload("G5 receipt must be JSON object")
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
                throw G3StoreError.blocked("G5 artifact is too large")
            }
            state.update(data: bytes)
        }
        return (state.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}

extension ProjectStore {
    private func g5Transaction<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        guard dbURL != nil else { throw G3StoreError.diskStoreRequired }
        return try withCanonicalTransaction(block)
    }

    public func approveG5Final(
        projectId: UUID,
        finalPublicationId: UUID,
        drpPublicationId: UUID,
        receiptJSON: String,
        reviewedBy: String,
        reviewNotes: String,
        watchedFull4KAndVerifiedCaptionsAndAudio: Bool
    ) throws -> G5FinalApproval {
        guard watchedFull4KAndVerifiedCaptionsAndAudio,
              !reviewedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else {
            throw G3StoreError.blocked("Explicit 4K audiovisual/caption QC confirmation and meaningful notes required")
        }
        guard let currentG3 = try currentG3Approval(projectId: projectId),
              let currentG4 = try currentG4Preview(projectId: projectId),
              currentG4.g3ApprovalId == currentG3.approvalId else {
            throw G3StoreError.blocked("Active S19 G3 and S21 G4 preview approvals required before S22 final approval")
        }
        let receipt = try G5SQL.json(receiptJSON)
        guard receipt["status"] as? String == "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
              receipt["g3_approval_id"] as? String == currentG3.approvalId.uuidString,
              receipt["g3_manifest_sha256"] as? String == currentG3.manifestSHA256,
              receipt["g4_approval_id"] as? String == currentG4.approvalId.uuidString,
              receipt["g4_preview_sha256"] as? String == currentG4.previewSHA256,
              let finalSHA = receipt["final_sha256"] as? String, finalSHA.count == 64,
              let drpSHA = receipt["drp_sha256"] as? String, drpSHA.count == 64,
              let planSHA = receipt["plan_sha256"] as? String, planSHA.count == 64,
              let timelineUID = receipt["timeline_uid"] as? String, !timelineUID.isEmpty,
              let timelineSignature = receipt["timeline_signature"] as? String, timelineSignature.count == 64,
              let renderJob = receipt["render_job_id"] as? String, !renderJob.isEmpty,
              let dependencies = receipt["required_publication_ids"] as? [String],
              dependencies.count >= 6, dependencies.count <= 194,
              dependencies.count == Set(dependencies).count,
              dependencies.allSatisfy({ UUID(uuidString: $0) != nil }),
              let qc = receipt["qc"] as? [String: Any],
              qc["status"] as? String == "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
              qc["sha256"] as? String == finalSHA,
              qc["semantic_verified"] as? Bool == false,
              let profile = qc["verified"] as? [String: Any],
              profile["width"] as? Int == 2160,
              profile["height"] as? Int == 3840,
              profile["fps"] as? Int == 24,
              profile["color"] as? String == "bt709" else {
            throw G3StoreError.blocked("G5 final render/QC receipt is not tied to the current S19/S21 snapshot")
        }

        return try g5Transaction { db in
            guard let approval = try G5SQL.row(db, """
                SELECT a.manifest_sha256,a.script_revision_id,a.workday_id,a.manifest_json,
                       s.candidate_json
                FROM g3_approvals a JOIN g3_scripts s
                  ON s.script_revision_id=a.script_revision_id
                JOIN g3_selected chosen ON chosen.project_id=a.project_id
                  AND chosen.script_revision_id=a.script_revision_id
                WHERE a.project_id=? AND a.approval_id=?
                """, [projectId.uuidString, currentG3.approvalId.uuidString]),
                approval[0] == currentG3.manifestSHA256 else {
                throw G3StoreError.conflict("G3 approval changed during G5 transaction")
            }
            try G3ApprovalGuard.verify(
                db: db, projectId: projectId, scriptRevisionId: approval[1],
                candidate: try G5SQL.json(approval[4]),
                manifest: try G5SQL.json(approval[3])
            )
            let script = try G5SQL.json(approval[4])
            let manifestObj = try G5SQL.json(approval[3])
            try G5S22Guard.verifyFinalBindings(
                db: db, project: projectId, g4Approval: currentG4,
                candidate: script, manifest: manifestObj,
                dependencyIDs: dependencies
            )
            guard let finalPub = try G5SQL.row(db, """
                SELECT state,artifact_type,sha256_hash,canonical_path,byte_size
                FROM artifact_publications WHERE publication_id=? AND project_id=?
                """, [finalPublicationId.uuidString, projectId.uuidString]),
                finalPub[0] == "COMMITTED", finalPub[1] == "g5_final_mp4",
                finalPub[2] == finalSHA,
                let expectedFinalSize = Int64(finalPub[4]), expectedFinalSize > 1024 else {
                throw G3StoreError.blocked("G5 final MP4 is not a committed S08 publication")
            }
            guard let drpPub = try G5SQL.row(db, """
                SELECT state,artifact_type,sha256_hash,canonical_path,byte_size
                FROM artifact_publications WHERE publication_id=? AND project_id=?
                """, [drpPublicationId.uuidString, projectId.uuidString]),
                drpPub[0] == "COMMITTED", drpPub[1] == "g5_handoff_drp",
                drpPub[2] == drpSHA,
                let expectedDrpSize = Int64(drpPub[4]), expectedDrpSize > 1024 else {
                throw G3StoreError.blocked("G5 Resolve .drp archive is not a committed S08 publication")
            }
            let measuredFinal = try G5SQL.fileSHA(finalPub[3])
            let measuredDrp = try G5SQL.fileSHA(drpPub[3])
            guard measuredFinal.0 == finalSHA, measuredFinal.1 == expectedFinalSize,
                  measuredDrp.0 == drpSHA, measuredDrp.1 == expectedDrpSize else {
                throw G3StoreError.blocked("Published G5 final MP4 or DRP bytes changed on disk")
            }
            guard let totalFrames = manifestObj["total_frames"] as? Int else {
                throw G3StoreError.blocked("Approved G3 frame count missing")
            }
            try G5S22Guard.verifyFinalMP4AndDRP(
                mp4Path: finalPub[3], drpPath: drpPub[3], expectedFrames: totalFrames
            )
            if let existing = try G5SQL.row(db, """
                SELECT approval_id,reviewed_by,final_publication_id,drp_publication_id
                FROM g5_final_approvals
                WHERE project_id=? AND g4_approval_id=? AND final_sha256=?
                """, [projectId.uuidString, currentG4.approvalId.uuidString, finalSHA]),
               let existingId = UUID(uuidString: existing[0]) {
                guard existing[2].lowercased() == finalPublicationId.uuidString.lowercased(),
                      existing[3].lowercased() == drpPublicationId.uuidString.lowercased() else {
                    throw G3StoreError.conflict("Same final MP4 already approved under different publication IDs")
                }
                return G5FinalApproval(
                    approvalId: existingId, projectId: projectId,
                    g3ApprovalId: currentG3.approvalId, g4ApprovalId: currentG4.approvalId,
                    finalPublicationId: finalPublicationId, drpPublicationId: drpPublicationId,
                    finalSHA256: finalSHA, drpSHA256: drpSHA, planSHA256: planSHA,
                    reviewedBy: existing[1]
                )
            }
            let approvalId = UUID()
            try G5SQL.run(db, """
                INSERT INTO g5_final_approvals(
                    approval_id,project_id,g3_approval_id,g4_approval_id,
                    final_publication_id,drp_publication_id,final_sha256,drp_sha256,
                    plan_sha256,qc_receipt_json,qc_receipt_sha256,reviewed_by,review_notes
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                    approvalId.uuidString, projectId.uuidString,
                    currentG3.approvalId.uuidString, currentG4.approvalId.uuidString,
                    finalPublicationId.uuidString, drpPublicationId.uuidString,
                    finalSHA, drpSHA, planSHA, receiptJSON,
                    G5SQL.sha(Data(receiptJSON.utf8)), reviewedBy, reviewNotes
                ])
            for depID in dependencies {
                try G5SQL.run(db, """
                    INSERT INTO artifact_pins(pin_id,project_id,publication_id,reason)
                    VALUES(?,?,?,?)
                    """, [UUID().uuidString, projectId.uuidString, depID,
                          "S22 final dependency \(approvalId.uuidString)"])
            }
            for (pubID, label) in [(finalPublicationId.uuidString, "S22 approved 4K final MP4"),
                                   (drpPublicationId.uuidString, "S22 approved Resolve DRP")] {
                try G5SQL.run(db, """
                    INSERT INTO artifact_pins(pin_id,project_id,publication_id,reason)
                    VALUES(?,?,?,?)
                    """, [UUID().uuidString, projectId.uuidString, pubID,
                          "\(label) \(approvalId.uuidString)"])
            }
            return G5FinalApproval(
                approvalId: approvalId, projectId: projectId,
                g3ApprovalId: currentG3.approvalId, g4ApprovalId: currentG4.approvalId,
                finalPublicationId: finalPublicationId, drpPublicationId: drpPublicationId,
                finalSHA256: finalSHA, drpSHA256: drpSHA, planSHA256: planSHA,
                reviewedBy: reviewedBy
            )
        }
    }

    public func currentG5FinalApproval(projectId: UUID) throws -> G5FinalApproval? {
        guard let currentG3 = try currentG3Approval(projectId: projectId),
              let currentG4 = try currentG4Preview(projectId: projectId),
              currentG4.g3ApprovalId == currentG3.approvalId else {
            return nil
        }
        return try g5Transaction { db in
            guard let found = try G5SQL.row(db, """
                SELECT f.approval_id,f.final_publication_id,f.drp_publication_id,
                       f.final_sha256,f.drp_sha256,f.plan_sha256,f.reviewed_by,f.qc_receipt_json,
                       mp4.sha256_hash,mp4.canonical_path,mp4.state,
                       drp.sha256_hash,drp.canonical_path,drp.state
                FROM g5_final_approvals f
                JOIN artifact_publications mp4 ON mp4.publication_id=f.final_publication_id
                JOIN artifact_publications drp ON drp.publication_id=f.drp_publication_id
                WHERE f.project_id=? AND f.g3_approval_id=? AND f.g4_approval_id=?
                ORDER BY f.approved_at DESC, f.rowid DESC LIMIT 1
                """, [projectId.uuidString, currentG3.approvalId.uuidString, currentG4.approvalId.uuidString]),
                found[3] == found[8], found[10] == "COMMITTED",
                found[4] == found[11], found[13] == "COMMITTED",
                let approvalUUID = UUID(uuidString: found[0]),
                let finalPubUUID = UUID(uuidString: found[1]),
                let drpPubUUID = UUID(uuidString: found[2]),
                let measuredFinal = try? G5SQL.fileSHA(found[9]), measuredFinal.0 == found[3],
                let measuredDrp = try? G5SQL.fileSHA(found[12]), measuredDrp.0 == found[4] else {
                return nil
            }
            guard let manifestRow = try G5SQL.row(db, """
                SELECT a.manifest_json, s.candidate_json
                FROM g3_approvals a JOIN g3_scripts s
                  ON s.script_revision_id=a.script_revision_id
                WHERE a.project_id=? AND a.approval_id=?
                """, [projectId.uuidString, currentG3.approvalId.uuidString]),
                  let receipt = try? G5SQL.json(found[7]),
                  let dependencyIDs = receipt["required_publication_ids"] as? [String] else {
                return nil
            }
            do {
                let candidateObj = try G5SQL.json(manifestRow[1])
                let manifestObj = try G5SQL.json(manifestRow[0])
                try G5S22Guard.verifyFinalBindings(
                    db: db, project: projectId, g4Approval: currentG4,
                    candidate: candidateObj, manifest: manifestObj,
                    dependencyIDs: dependencyIDs
                )
                guard let totalFrames = manifestObj["total_frames"] as? Int else { return nil }
                try G5S22Guard.verifyFinalMP4AndDRP(
                    mp4Path: found[9], drpPath: found[12], expectedFrames: totalFrames
                )
            } catch {
                return nil
            }
            return G5FinalApproval(
                approvalId: approvalUUID, projectId: projectId,
                g3ApprovalId: currentG3.approvalId, g4ApprovalId: currentG4.approvalId,
                finalPublicationId: finalPubUUID, drpPublicationId: drpPubUUID,
                finalSHA256: found[3], drpSHA256: found[4], planSHA256: found[5],
                reviewedBy: found[6]
            )
        }
    }

    public func recordG5ManualHandoffBranch(
        projectId: UUID,
        handoffDrpPublicationId: UUID,
        branchReceiptJSON: String,
        createdBy: String
    ) throws -> G5ManualHandoffRecord {
        guard !createdBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw G3StoreError.blocked("Manual handoff requires creator attribution")
        }
        guard let currentG3 = try currentG3Approval(projectId: projectId),
              let currentG4 = try currentG4Preview(projectId: projectId) else {
            throw G3StoreError.blocked("Active G3 and G4 approvals required before forking manual handoff branch")
        }
        let receipt = try G5SQL.json(branchReceiptJSON)
        guard receipt["schema"] as? String == "g5-manual-handoff-branch-v1",
              receipt["branch_mode"] as? String == "manual_handoff",
              receipt["isolated_from_managed_timeline"] as? Bool == true,
              receipt["g3_approval_id"] as? String == currentG3.approvalId.uuidString,
              receipt["g4_approval_id"] as? String == currentG4.approvalId.uuidString,
              let handoffSHA = receipt["handoff_drp_sha256"] as? String, handoffSHA.count == 64,
              let handoffName = receipt["handoff_project_name"] as? String, !handoffName.isEmpty else {
            throw G3StoreError.blocked("Invalid manual handoff branch receipt")
        }
        return try g5Transaction { db in
            guard let drpPub = try G5SQL.row(db, """
                SELECT state,artifact_type,sha256_hash,canonical_path,byte_size
                FROM artifact_publications WHERE publication_id=? AND project_id=?
                """, [handoffDrpPublicationId.uuidString, projectId.uuidString]),
                drpPub[0] == "COMMITTED", drpPub[1] == "g5_manual_handoff_drp",
                drpPub[2] == handoffSHA,
                let size = Int64(drpPub[4]), size > 1024,
                let measured = try? G5SQL.fileSHA(drpPub[3]),
                measured.0 == handoffSHA, measured.1 == size else {
                throw G3StoreError.blocked("Manual handoff DRP is not a committed S08 archive")
            }
            let branchId = UUID()
            try G5SQL.run(db, """
                INSERT INTO g5_manual_handoff_branches(
                    branch_id,project_id,g3_approval_id,g4_approval_id,
                    handoff_drp_publication_id,handoff_drp_sha256,handoff_project_name,
                    branch_receipt_json,created_by
                ) VALUES(?,?,?,?,?,?,?,?,?)
                """, [
                    branchId.uuidString, projectId.uuidString,
                    currentG3.approvalId.uuidString, currentG4.approvalId.uuidString,
                    handoffDrpPublicationId.uuidString, handoffSHA, handoffName,
                    branchReceiptJSON, createdBy
                ])
            try G5SQL.run(db, """
                INSERT INTO artifact_pins(pin_id,project_id,publication_id,reason)
                VALUES(?,?,?,?)
                """, [UUID().uuidString, projectId.uuidString, handoffDrpPublicationId.uuidString,
                      "S22 manual handoff DRP \(branchId.uuidString)"])
            return G5ManualHandoffRecord(
                branchId: branchId, projectId: projectId,
                g4ApprovalId: currentG4.approvalId,
                handoffDrpPublicationId: handoffDrpPublicationId,
                handoffDrpSHA256: handoffSHA,
                handoffProjectName: handoffName,
                createdBy: createdBy
            )
        }
    }
}
