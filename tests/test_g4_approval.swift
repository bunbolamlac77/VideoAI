import Foundation
import SQLite3
import CryptoKit

@main
struct TestG4Approval {
    static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func json(_ dictionary: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }

    static func wav(sampleFrames: Int) -> Data {
        func u16(_ x: Int) -> [UInt8] { [UInt8(x & 255), UInt8((x >> 8) & 255)] }
        func u32(_ x: Int) -> [UInt8] { (0..<4).map { UInt8((x >> ($0 * 8)) & 255) } }
        let pcm = Data(repeating: 0, count: sampleFrames * 2)
        var result = Data("RIFF".utf8)
        result.append(contentsOf: u32(36 + pcm.count))
        result.append(Data("WAVEfmt ".utf8))
        result.append(contentsOf: u32(16))
        result.append(contentsOf: u16(1))
        result.append(contentsOf: u16(1))
        result.append(contentsOf: u32(48000))
        result.append(contentsOf: u32(96000))
        result.append(contentsOf: u16(2))
        result.append(contentsOf: u16(16))
        result.append(Data("data".utf8))
        result.append(contentsOf: u32(pcm.count))
        result.append(pcm)
        return result
    }

    // Real MP4 fixture: false positive technical receipts must never substitute for decode.
    static func makePreview(_ destination: URL) throws {
        let fm = FileManager.default
        let tools = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let command = tools.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw G3StoreError.blocked("Install ffmpeg to run S21 integration test")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                       "-f", "lavfi", "-i", "color=c=blue:s=1080x1920:r=24:d=2",
                       "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=2",
                       "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264",
                       "-preset", "ultrafast", "-crf", "23", "-pix_fmt", "yuv420p",
                       "-r", "24", "-c:a", "aac", "-ar", "48000", "-b:a", "128k",
                       "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
                       "-color_primaries", "bt709", "-color_trc", "bt709",
                       "-colorspace", "bt709", "-movflags", "+faststart", destination.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw G3StoreError.blocked("ffmpeg failed to create real S21 MP4 fixture")
        }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("g3_guard_\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("project.db")
        let store = try ProjectStore(dbURL: dbURL)
        let project = try await store.createProject(name: "Secure G3")
        let day = try await store.createWorkday(projectId: project.projectId, title: "Day", date: "2026-11-09")
        let fact = ClaimRecord(workdayId: day.workdayId, text: "Tôi đi đến nơi quay.",
                               origin: .user, epistemicStatus: .reported,
                               reviewStatus: .confirmed, supportStatus: .supported,
                               allowedUse: .attributedOrQualified)
        _ = try await store.saveClaim(claim: fact, expectedRevision: project.currentRevision)
        let voiceText = "Theo thông tin đã được người quay xác nhận: " + fact.text
        let sourceId = UUID()
        let mediaId = UUID()
        let sealedPath = root.appendingPathComponent("sealed.mp4")
        let sourceBytes = Data("sealed-video-fixture".utf8)
        try sourceBytes.write(to: sealedPath)
        let sourceSHA = sha(sourceBytes)
        var conn: OpaquePointer?
        guard sqlite3_open(dbURL.path, &conn) == SQLITE_OK, let db = conn else { fatalError("test DB") }
        let ddl = """
        INSERT INTO source_media(media_id,project_id,original_path,content_sha256,byte_size)
        VALUES ('\(mediaId.uuidString)','\(project.projectId.uuidString)','fixture','\(sourceSHA)',\(sourceBytes.count));
        INSERT INTO source_revisions(source_revision_id,media_id,snapshot_path,snapshot_sha256,is_stable)
        VALUES ('\(sourceId.uuidString)','\(mediaId.uuidString)','\(sealedPath.path)','\(sourceSHA)',1);
        """
        assert(sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let publisher = try ArtifactPublicationService(workspaceRoot: root)
        func publish(kind: String, bytes: Data) async throws -> ArtifactPublicationRecord {
            let job = try await store.enqueueJob(projectId: project.projectId, jobType: "test-\(kind)", inputFingerprint: UUID().uuidString)
            let attempt = try await store.allocateAttempt(jobId: job.jobId, workerSessionId: "g3-guard-test")
            return try await publisher.publishArtifact(store: store, projectId: project.projectId,
                        jobId: job.jobId, attemptId: attempt.attemptId,
                        fencingToken: attempt.fencingToken, artifactType: kind,
                        filename: "artifact.bin", content: bytes)
        }
        let frameMappings = (0..<48).map { ["timeline_frame_index": $0, "source_frame_id": $0] }
        let mapping = [
            "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA,
            "conform_map": [
                "profile_id": "M-24-SDR-v1", "source_revision_id": sourceId.uuidString,
                "timeline_frame_count": 48, "is_valid_for_evidence": true,
                "dropped_critical_evidence_frame_ids": [], "mappings": frameMappings,
            ] as [String: Any]
        ] as [String: Any]
        let mappingPub = try await publish(kind: "g2_source_mapping", bytes: json(mapping))
        let voicePub = try await publish(kind: "voice_wav", bytes: wav(sampleFrames: 4_800))
        let revision = String(repeating: "a", count: 64)
        let candidate = [
            "script_revision_id": revision, "scope_revision_id": "scope-1",
            "status": "DRAFT_NOT_BUILDABLE", "claim_revision_ids": [fact.revisionId.uuidString],
            "beats": [[
                "beat_id": "beat-01", "voice_text": voiceText,
                "shot_candidate_ids": ["shot-A"],
                "claim_refs": [["revision_id": fact.revisionId.uuidString,
                                "allowed_use": "attributed_or_qualified"]]
            ]]
        ] as [String: Any]
        let stored = try await store.storeG3Draft(projectId: project.projectId,
                         workdayId: day.workdayId,
                         candidateJSON: String(decoding: try json(candidate), as: UTF8.self))
        try await store.selectG3Draft(projectId: project.projectId, scriptRevisionId: revision)
        try await store.recordG3SpeechReview(projectId: project.projectId,
                   scriptRevisionId: revision, beatId: "beat-01",
                   publicationId: voicePub.publicationId,
                   expectedSHA256: voicePub.sha256Hash!, reviewer: "Manual test")
        let domain = String(repeating: "d", count: 64)
        let shot = [
            "shot_id": "shot-A", "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA, "mapping_sha256": mappingPub.sha256Hash!,
            "mapping_publication_id": mappingPub.publicationId.uuidString,
            "range_start": 0, "range_end": 48, "duration_frames": 48,
            "transition_overlap_frames": 0, "range_profile": "M-24-SDR-v1",
            "evidence_scope_valid": true, "claim_use_valid": true,
            "crop_preserves_evidence": true
        ] as [String: Any]
        let cut = ["schema_version": "g3-cut-plan-v1", "script_revision_id": revision,
                   "scope_revision_id": "scope-1", "domain_sha256": domain,
                   "timeline_profile": "M-24-SDR-v1", "edit_plan": [shot]] as [String: Any]
        let cutPub = try await publish(kind: "g3_cut_plan", bytes: json(cut))
        let manifest = [
            "schema_version": "g3-approval-proposal-v1", "script_revision_id": revision,
            "scope_revision_id": "scope-1", "claim_revision_ids": [fact.revisionId.uuidString],
            "domain_sha256": domain, "edit_plan_sha256": cutPub.sha256Hash!,
            "cut_publication_id": cutPub.publicationId.uuidString,
            "timeline_profile": "M-24-SDR-v1", "total_frames": 48,
            "voice_publications": [["beat_id": "beat-01",
                "text_sha256": sha(Data(voiceText.utf8)),
                "publication_id": voicePub.publicationId.uuidString,
                "sha256": voicePub.sha256Hash!]]
        ] as [String: Any]
        let manifestJSON = String(decoding: try json(manifest), as: UTF8.self)
        let approval = try await store.approveG3Draft(
            projectId: project.projectId, workdayId: day.workdayId,
            scriptRevisionId: revision, expectedCandidateSHA256: stored.candidateSHA256,
            manifestJSON: manifestJSON, approvedBy: "Human tester")
        assert(approval.scriptRevisionId == revision)
        let active = try await store.currentG3Approval(projectId: project.projectId)
        assert(active != nil)
        print("PASS G3.GUARD.1: sealed source + mapping + WAV + cut approved")
        // Test the REAL demux/decode gate; an MP4-looking byte prefix is not enough.
        var fakeMP4 = Data([0, 0, 0, 32])
        fakeMP4.append(Data("ftypisom".utf8))
        fakeMP4.append(Data(repeating: 0, count: 2048))
        let fakePreview = try await publish(kind: "g4_preview_mp4", bytes: fakeMP4)
        let previewPath = root.appendingPathComponent("real_preview.mp4")
        try makePreview(previewPath)
        let previewPub = try await publish(kind: "g4_preview_mp4",
                                           bytes: Data(contentsOf: previewPath))
        let captionPub = try await publish(kind: "g4_captioned_cfr",
                                           bytes: Data("captioned fixture".utf8))
        let conformReceipt: [String: Any] = [
            "schema": "g4-conform-receipt-v1", "beat_id": "beat-01",
            "video_sha256": captionPub.sha256Hash!,
            "mapping_sha256": mappingPub.sha256Hash!,
            "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA,
            "voice_text_sha256": sha(Data(voiceText.utf8)),
            "start_frame": 0, "end_frame": 48, "render_frames": 48,
            "caption_policy": "approved_phrase_cues_raster",
            "crop_policy": "fit_preserves_full_frame",
            "caption_cues": [["text": voiceText, "start_frame": 0, "end_frame": 48]]
        ]
        let conformPub = try await publish(kind: "g4_conform_receipt",
                                           bytes: json(conformReceipt))
        let requiredIDs = [cutPub.publicationId, mappingPub.publicationId,
                           voicePub.publicationId, captionPub.publicationId,
                           conformPub.publicationId].map { $0.uuidString }
        let receipt = [
            "status": "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
            "g3_approval_id": approval.approvalId.uuidString,
            "g3_manifest_sha256": approval.manifestSHA256,
            "plan_sha256": String(repeating: "c", count: 64),
            "preview_sha256": previewPub.sha256Hash!,
            "timeline_uid": "mock-timeline-uid",
            "timeline_signature": String(repeating: "d", count: 64),
            "render_job_id": "render-job-fixture",
            "required_publication_ids": requiredIDs,
            "qc": ["status": "TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
                   "sha256": previewPub.sha256Hash!,
                   "semantic_verified": false,
                   "verified": ["width": 1080, "height": 1920, "fps": 24, "color": "bt709"]
                  ] as [String: Any],
        ] as [String: Any]
        let receiptJSON = String(decoding: try json(receipt), as: UTF8.self)
        var blockedWithoutHuman = false
        do {
            _ = try await store.approveG4Preview(
                projectId: project.projectId,
                previewPublicationId: previewPub.publicationId,
                receiptJSON: receiptJSON,
                reviewedBy: "Tester", reviewNotes: "I reviewed all images and speech",
                watchedVideoAndListenedToAudio: false
            )
        } catch { blockedWithoutHuman = true }
        assert(blockedWithoutHuman)
        var fakeReceipt = receipt
        fakeReceipt["preview_sha256"] = fakePreview.sha256Hash!
        var fakeQC = fakeReceipt["qc"] as! [String: Any]
        fakeQC["sha256"] = fakePreview.sha256Hash!
        fakeReceipt["qc"] = fakeQC
        var blockedFakeMP4 = false
        do {
            _ = try await store.approveG4Preview(
                projectId: project.projectId,
                previewPublicationId: fakePreview.publicationId,
                receiptJSON: String(decoding: try json(fakeReceipt), as: UTF8.self),
                reviewedBy: "Tester", reviewNotes: "Verified fake QC should be rejected",
                watchedVideoAndListenedToAudio: true
            )
        } catch { blockedFakeMP4 = true }
        assert(blockedFakeMP4)
        print("PASS S21.T1a: fabricated technical QC cannot approve undecodable MP4")

        let g4 = try await store.approveG4Preview(
            projectId: project.projectId,
            previewPublicationId: previewPub.publicationId,
            receiptJSON: receiptJSON,
            reviewedBy: "Tester", reviewNotes: "Picture and speech manually reviewed",
            watchedVideoAndListenedToAudio: true
        )
        assert(g4.previewPublicationId == previewPub.publicationId)
        let currentPreview = try await store.currentG4Preview(projectId: project.projectId)
        assert(currentPreview != nil)
        print("PASS S21.T1: human review required, preview pinned to approved G3 snapshot")
        // A committed caption video belongs to the signed final dependency set.
        // Mutating even one G4 dependency invalidates the active approval.
        let captionBlob = await publisher.canonicalBlobURL(forSHA256: captionPub.sha256Hash!)
        let savedCaption = try Data(contentsOf: captionBlob)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: captionBlob.path)
        try Data("tampered caption asset".utf8).write(to: captionBlob, options: .atomic)
        let invalidatedDependency = try await store.currentG4Preview(projectId: project.projectId)
        assert(invalidatedDependency == nil)
        try savedCaption.write(to: captionBlob, options: .atomic)
        let restoredDependency = try await store.currentG4Preview(projectId: project.projectId)
        assert(restoredDependency != nil)
        print("PASS S21.T2: G4 dependency tampering invalidates current preview")
        // The original manifest is immutable; tampering with the sealed cut disables it.
        try Data("tampered".utf8).write(to: sealedPath, options: .atomic)
        let revoked = try await store.currentG3Approval(projectId: project.projectId)
        assert(revoked == nil)
        let g4Revoked = try await store.currentG4Preview(projectId: project.projectId)
        assert(g4Revoked == nil)
        print("PASS S21.T3: source tampering invalidates G3 and G4 approvals")
        await store.close()
        try testNoFileIOInsideG4Transaction()
        print("PASS S21.P1_02B: no file IO inside G4 write transaction")

        if let outPath = ProcessInfo.processInfo.environment["TEST_RECORDS_OUT"], !outPath.isEmpty {
            let records: [[String: Any]] = [
                ["testcase_id": "S21.T1a", "requirement_id": "RES-02/EXP-02", "status": "PASS",
                 "expected": "Fabricated technical QC cannot approve undecodable MP4", "observed": "PASS S21.T1a: fabricated technical QC cannot approve undecodable MP4", "exit_status": 0],
                ["testcase_id": "S21.T1", "requirement_id": "INV-03/RES-02", "status": "PASS",
                 "expected": "Human review required, preview pinned to approved G3 snapshot", "observed": "PASS S21.T1: human review required, preview pinned to approved G3 snapshot", "exit_status": 0],
                ["testcase_id": "S21.T2", "requirement_id": "INV-05/DATA-08", "status": "PASS",
                 "expected": "G4 dependency tampering invalidates current preview", "observed": "PASS S21.T2: G4 dependency tampering invalidates current preview", "exit_status": 0],
                ["testcase_id": "S21.T3", "requirement_id": "INV-05/DATA-01", "status": "PASS",
                 "expected": "Source tampering invalidates G3 and G4 approvals", "observed": "PASS S21.T3: source tampering invalidates G3 and G4 approvals", "exit_status": 0],
                ["testcase_id": "S21.P1_02B", "requirement_id": "INV-05", "status": "PASS",
                 "expected": "No file IO runs inside the G4 write transaction", "observed": "PASS S21.P1_02B: no file IO inside G4 write transaction", "exit_status": 0]
            ]
            let url = URL(fileURLWithPath: outPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = ""
            for rec in records {
                if let d = try? JSONSerialization.data(withJSONObject: rec),
                   let s = String(data: d, encoding: .utf8) { lines += s + "\n" }
            }
            try lines.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // (P1-02B) No file IO may happen inside the G4 write transaction.
    // The slice is bounded by the method's own braces: a plain "everything after" slice
    // would also cover `currentG4Preview`, which legitimately hashes the preview.
    static func testNoFileIOInsideG4Transaction() throws {
        let path = "packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift"
        let source = try String(contentsOfFile: path, encoding: .utf8)
        guard let methodStart = source.range(of: "public func approveG4Preview"),
              let txStart = source.range(of: "g4Transaction {",
                                         range: methodStart.upperBound..<source.endIndex) else {
            throw NSError(domain: "g4", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "approveG4Preview no longer opens a g4Transaction"
            ])
        }
        var depth = 0
        var index = txStart.lowerBound
        var end = source.endIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { end = source.index(after: index); break }
            }
            index = source.index(after: index)
        }
        let body = String(source[txStart.lowerBound..<end])
        for forbidden in ["fileSHA(", "verifyBindings(", "G3ApprovalGuard.verify(",
                          "verifyPreview(", "verifyS21Evidence(", "readApprovedInputs("] {
            if body.contains(forbidden) {
                throw NSError(domain: "g4", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "G4 write transaction still performs IO: \(forbidden)"
                ])
            }
        }
    }
}
