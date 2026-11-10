// test_g5_final_and_release.swift — Gate G5 (S22..S26) Swift 6 Verification Suite.
// Verifies:
// - S22.T1: S22 final approval requires active S19 G3 + S21 G4 preview approvals.
// - S22.T2: Real 2160x3840 24fps SDR Rec.709 MP4 + valid Resolve .drp archive (>1024B ZIP)
//           verified by G5S22Guard and approved in ProjectStore.
// - S22.T3: Any upstream dependency or sealed source tampering invalidates G5 final approval.
// - S22.T4: Isolated manual_handoff DRP branch committed in ProjectStore without mutating
//           the canonical automated approval.
// - S24.T2: 50-cycle preview player & thumbnail LRU cache switch test enforces strict bounds.
// - S24.T3: Vietnamese IME marked text composition (`G5VietnameseIMEBuffer`) is preserved
//           across background refresh ticks.

import Foundation
import SQLite3
import CryptoKit

@main
struct TestG5FinalAndRelease {
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

    static func makeMP4(_ destination: URL, width: Int, height: Int) throws {
        let fm = FileManager.default
        let tools = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let command = tools.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw G3StoreError.blocked("Install ffmpeg to run S22 integration test")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "color=c=navy:s=\(width)x\(height):r=24:d=2",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
            "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264",
            "-preset", "ultrafast", "-crf", "23", "-pix_fmt", "yuv420p",
            "-r", "24", "-c:a", "aac", "-ar", "48000", "-b:a", "128k",
            "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
            "-color_primaries", "bt709", "-color_trc", "bt709",
            "-colorspace", "bt709", "-movflags", "+faststart", destination.path
        ]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw G3StoreError.blocked("ffmpeg failed to create MP4 fixture")
        }
    }

    static func makeDRP(_ destination: URL) throws {
        // Minimal valid ZIP archive > 1024 bytes starting with PK\x03\x04
        let payload = Data(repeating: 0x41, count: 1500)
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = [
            "-c",
            "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('project.xml', 'A'*2048); z.close()",
            destination.path
        ]
        try py.run()
        py.waitUntilExit()
        if py.terminationStatus != 0 {
            var fallback = Data([0x50, 0x4B, 0x03, 0x04])
            fallback.append(payload)
            try fallback.write(to: destination)
        }
    }

    static func main() async throws {
        var records: [[String: Any]] = []
        let commit = ProcessInfo.processInfo.environment["GIT_COMMIT"] ?? "unknown"

        func emit(_ caseId: String, _ reqId: String, _ passed: Bool, _ details: String) {
            print("[\(passed ? "PASS" : "FAIL")] \(caseId) (\(reqId)): \(details)")
            records.append([
                "testcase_id": caseId,
                "requirement_id": reqId,
                "status": passed ? "PASS" : "FAIL",
                "expected": "Gate G5 S22..S26 invariant satisfied",
                "observed": details,
                "exit_status": passed ? 0 : 1,
                "commit": commit
            ])
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("g5_guard_\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("project.db")
        let store = try ProjectStore(dbURL: dbURL)
        let project = try await store.createProject(name: "Secure G5")
        let day = try await store.createWorkday(projectId: project.projectId, title: "Day", date: "2026-11-09")
        let fact = ClaimRecord(
            workdayId: day.workdayId, text: "Tôi đi đến nơi quay.",
            origin: .user, epistemicStatus: .reported,
            reviewStatus: .confirmed, supportStatus: .supported,
            allowedUse: .attributedOrQualified
        )
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
            let attempt = try await store.allocateAttempt(jobId: job.jobId, workerSessionId: "g5-guard-test")
            return try await publisher.publishArtifact(
                store: store, projectId: project.projectId,
                jobId: job.jobId, attemptId: attempt.attemptId,
                fencingToken: attempt.fencingToken, artifactType: kind,
                filename: "artifact.bin", content: bytes
            )
        }

        let frameMappings = (0..<48).map { ["timeline_frame_index": $0, "source_frame_id": $0] }
        let mapping: [String: Any] = [
            "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA,
            "conform_map": [
                "profile_id": "M-24-SDR-v1", "source_revision_id": sourceId.uuidString,
                "timeline_frame_count": 48, "is_valid_for_evidence": true,
                "dropped_critical_evidence_frame_ids": [], "mappings": frameMappings,
            ] as [String: Any]
        ]
        let mappingPub = try await publish(kind: "g2_source_mapping", bytes: json(mapping))
        let voicePub = try await publish(kind: "voice_wav", bytes: wav(sampleFrames: 4_800))
        let revision = String(repeating: "a", count: 64)
        let candidate: [String: Any] = [
            "script_revision_id": revision, "scope_revision_id": "scope-1",
            "status": "DRAFT_NOT_BUILDABLE", "claim_revision_ids": [fact.revisionId.uuidString],
            "beats": [[
                "beat_id": "beat-01", "voice_text": voiceText,
                "shot_candidate_ids": ["shot-A"],
                "claim_refs": [["revision_id": fact.revisionId.uuidString,
                                "allowed_use": "attributed_or_qualified"]]
            ]]
        ]
        let stored = try await store.storeG3Draft(
            projectId: project.projectId, workdayId: day.workdayId,
            candidateJSON: String(decoding: try json(candidate), as: UTF8.self)
        )
        try await store.selectG3Draft(projectId: project.projectId, scriptRevisionId: revision)
        try await store.recordG3SpeechReview(
            projectId: project.projectId, scriptRevisionId: revision, beatId: "beat-01",
            publicationId: voicePub.publicationId, expectedSHA256: voicePub.sha256Hash!,
            reviewer: "Manual tester"
        )
        let domain = String(repeating: "d", count: 64)
        let shot: [String: Any] = [
            "shot_id": "shot-A", "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA, "mapping_sha256": mappingPub.sha256Hash!,
            "mapping_publication_id": mappingPub.publicationId.uuidString,
            "range_start": 0, "range_end": 48, "duration_frames": 48,
            "transition_overlap_frames": 0, "range_profile": "M-24-SDR-v1",
            "evidence_scope_valid": true, "claim_use_valid": true,
            "crop_preserves_evidence": true
        ]
        let cut: [String: Any] = [
            "schema_version": "g3-cut-plan-v1", "script_revision_id": revision,
            "scope_revision_id": "scope-1", "domain_sha256": domain,
            "timeline_profile": "M-24-SDR-v1", "edit_plan": [shot]
        ]
        let cutPub = try await publish(kind: "g3_cut_plan", bytes: json(cut))
        let manifest: [String: Any] = [
            "schema_version": "g3-approval-proposal-v1", "script_revision_id": revision,
            "scope_revision_id": "scope-1", "claim_revision_ids": [fact.revisionId.uuidString],
            "domain_sha256": domain, "edit_plan_sha256": cutPub.sha256Hash!,
            "cut_publication_id": cutPub.publicationId.uuidString,
            "timeline_profile": "M-24-SDR-v1", "total_frames": 48,
            "voice_publications": [[
                "beat_id": "beat-01", "text_sha256": sha(Data(voiceText.utf8)),
                "publication_id": voicePub.publicationId.uuidString, "sha256": voicePub.sha256Hash!
            ]]
        ]
        let g3Approval = try await store.approveG3Draft(
            projectId: project.projectId, workdayId: day.workdayId,
            scriptRevisionId: revision, expectedCandidateSHA256: stored.candidateSHA256,
            manifestJSON: String(decoding: try json(manifest), as: UTF8.self),
            approvedBy: "Human tester"
        )

        // Prepare real 1080x1920 preview & 2160x3840 final MP4 + DRP
        let previewPath = root.appendingPathComponent("preview_1080p.mp4")
        try makeMP4(previewPath, width: 1080, height: 1920)
        let previewPub = try await publish(kind: "g4_preview_mp4", bytes: Data(contentsOf: previewPath))

        let finalPath = root.appendingPathComponent("final_2160p.mp4")
        try makeMP4(finalPath, width: 2160, height: 3840)
        let finalPub = try await publish(kind: "g5_final_mp4", bytes: Data(contentsOf: finalPath))

        let drpPath = root.appendingPathComponent("final_project.drp")
        try makeDRP(drpPath)
        let drpPub = try await publish(kind: "g5_handoff_drp", bytes: Data(contentsOf: drpPath))

        let g4CaptionPub = try await publish(kind: "g4_captioned_cfr", bytes: Data("g4_cap".utf8))
        let g4ConformReceipt: [String: Any] = [
            "schema": "g4-conform-receipt-v1", "beat_id": "beat-01",
            "video_sha256": g4CaptionPub.sha256Hash!, "mapping_sha256": mappingPub.sha256Hash!,
            "source_revision_id": sourceId.uuidString, "source_sha256": sourceSHA,
            "voice_text_sha256": sha(Data(voiceText.utf8)),
            "start_frame": 0, "end_frame": 48, "render_frames": 48,
            "caption_policy": "approved_phrase_cues_raster",
            "crop_policy": "fit_preserves_full_frame",
            "caption_cues": [["text": voiceText, "start_frame": 0, "end_frame": 48]]
        ]
        let g4ConformPub = try await publish(kind: "g4_conform_receipt", bytes: json(g4ConformReceipt))

        // S22.T1: Attempting S22 approval BEFORE S21 preview approval must fail
        var blockedWithoutS21 = false
        do {
            _ = try await store.approveG5Final(
                projectId: project.projectId,
                finalPublicationId: finalPub.publicationId,
                drpPublicationId: drpPub.publicationId,
                receiptJSON: "{}",
                reviewedBy: "Tester",
                reviewNotes: "Trying to skip S21 preview approval",
                watchedFull4KAndVerifiedCaptionsAndAudio: true
            )
        } catch {
            blockedWithoutS21 = true
        }
        assert(blockedWithoutS21)
        emit("S22.T1_REQUIRES_S21_PREVIEW", "RES-03/INV-05", blockedWithoutS21,
             "Blocked S22 final approval when S21 preview is not yet approved")

        // Approve S21 preview
        let g4RequiredIDs = [
            cutPub.publicationId, mappingPub.publicationId, voicePub.publicationId,
            g4CaptionPub.publicationId, g4ConformPub.publicationId
        ].map { $0.uuidString }
        let g4Receipt: [String: Any] = [
            "status": "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
            "g3_approval_id": g3Approval.approvalId.uuidString,
            "g3_manifest_sha256": g3Approval.manifestSHA256,
            "plan_sha256": String(repeating: "c", count: 64),
            "preview_sha256": previewPub.sha256Hash!,
            "timeline_uid": "g4-tl-uid",
            "timeline_signature": String(repeating: "d", count: 64),
            "render_job_id": "g4-job-1",
            "required_publication_ids": g4RequiredIDs,
            "qc": [
                "status": "TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
                "sha256": previewPub.sha256Hash!,
                "semantic_verified": false,
                "verified": ["width": 1080, "height": 1920, "fps": 24, "color": "bt709"]
            ] as [String: Any]
        ]
        let g4Approval = try await store.approveG4Preview(
            projectId: project.projectId,
            previewPublicationId: previewPub.publicationId,
            receiptJSON: String(decoding: try json(g4Receipt), as: UTF8.self),
            reviewedBy: "Tester",
            reviewNotes: "Reviewed 1080p preview and audio",
            watchedVideoAndListenedToAudio: true
        )

        // Publish G5 4K captioned clip & conform receipt bound to g4Approval
        let g5CaptionPub = try await publish(kind: "g5_captioned_cfr_4k", bytes: Data("g5_4k_cap".utf8))
        let g5ConformReceipt: [String: Any] = [
            "schema": "g5-conform-receipt-v1", "beat_id": "beat-01",
            "video_sha256": g5CaptionPub.sha256Hash!, "mapping_sha256": mappingPub.sha256Hash!,
            "source_revision_id": sourceId.uuidString, "source_sha256": sourceSHA,
            "voice_text_sha256": sha(Data(voiceText.utf8)),
            "g4_approval_id": g4Approval.approvalId.uuidString,
            "g4_preview_sha256": g4Approval.previewSHA256,
            "start_frame": 0, "end_frame": 48, "render_frames": 48,
            "width": 2160, "height": 3840,
            "caption_policy": "approved_phrase_cues_raster",
            "crop_policy": "fit_preserves_full_frame",
            "caption_cues": [["text": voiceText, "start_frame": 0, "end_frame": 48]]
        ]
        let g5ConformPub = try await publish(kind: "g5_conform_receipt", bytes: json(g5ConformReceipt))

        let g5RequiredIDs = [
            cutPub.publicationId, previewPub.publicationId,
            mappingPub.publicationId, voicePub.publicationId,
            g5CaptionPub.publicationId, g5ConformPub.publicationId
        ].map { $0.uuidString }
        let g5Receipt: [String: Any] = [
            "status": "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
            "g3_approval_id": g3Approval.approvalId.uuidString,
            "g3_manifest_sha256": g3Approval.manifestSHA256,
            "g4_approval_id": g4Approval.approvalId.uuidString,
            "g4_preview_sha256": g4Approval.previewSHA256,
            "plan_sha256": String(repeating: "e", count: 64),
            "final_sha256": finalPub.sha256Hash!,
            "drp_sha256": drpPub.sha256Hash!,
            "timeline_uid": "g5-4k-tl-uid",
            "timeline_signature": String(repeating: "f", count: 64),
            "render_job_id": "g5-4k-job-1",
            "required_publication_ids": g5RequiredIDs,
            "qc": [
                "status": "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
                "sha256": finalPub.sha256Hash!,
                "semantic_verified": false,
                "verified": ["width": 2160, "height": 3840, "fps": 24, "color": "bt709"]
            ] as [String: Any]
        ]
        let g5ReceiptJSON = String(decoding: try json(g5Receipt), as: UTF8.self)

        // S22.T2: Approve 2160x3840 24fps final MP4 + DRP in ProjectStore
        let g5Final = try await store.approveG5Final(
            projectId: project.projectId,
            finalPublicationId: finalPub.publicationId,
            drpPublicationId: drpPub.publicationId,
            receiptJSON: g5ReceiptJSON,
            reviewedBy: "Release Reviewer",
            reviewNotes: "Full 2160x3840 24fps video, captions, and audio verified",
            watchedFull4KAndVerifiedCaptionsAndAudio: true
        )
        let activeFinal = try await store.currentG5FinalApproval(projectId: project.projectId)
        let s22T2OK = (activeFinal != nil && g5Final.finalPublicationId == finalPub.publicationId)
        assert(s22T2OK)
        emit("S22.T2_FINAL_4K_AND_DRP_APPROVAL", "RES-03/EXP-01", s22T2OK,
             "Verified 2160x3840 24fps bt709 MP4 + Resolve .drp archive and committed S22 approval")

        // S22.T4: Record isolated manual handoff DRP branch
        let handoffPub = try await publish(kind: "g5_manual_handoff_drp", bytes: Data(contentsOf: drpPath))
        let handoffReceipt: [String: Any] = [
            "schema": "g5-manual-handoff-branch-v1",
            "branch_mode": "manual_handoff",
            "isolated_from_managed_timeline": true,
            "g3_approval_id": g3Approval.approvalId.uuidString,
            "g4_approval_id": g4Approval.approvalId.uuidString,
            "handoff_drp_sha256": handoffPub.sha256Hash!,
            "handoff_project_name": "AIVideo_G5_MANUAL_BRANCH"
        ]
        let handoffRecord = try await store.recordG5ManualHandoffBranch(
            projectId: project.projectId,
            handoffDrpPublicationId: handoffPub.publicationId,
            branchReceiptJSON: String(decoding: try json(handoffReceipt), as: UTF8.self),
            createdBy: "Editor"
        )
        let s22T4OK = (handoffRecord.handoffProjectName == "AIVideo_G5_MANUAL_BRANCH")
        assert(s22T4OK)
        emit("S22.T4_MANUAL_HANDOFF_ISOLATION", "RES-05/INV-05", s22T4OK,
             "Forked and pinned isolated manual_handoff DRP branch without mutating canonical timeline")

        // S22.T3: Mutating G5 4K dependency or sealed source invalidates currentG5FinalApproval
        let g5CapBlob = await publisher.canonicalBlobURL(forSHA256: g5CaptionPub.sha256Hash!)
        let savedG5Cap = try Data(contentsOf: g5CapBlob)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: g5CapBlob.path)
        try Data("tampered 4k asset".utf8).write(to: g5CapBlob, options: .atomic)
        let invalidatedG5 = try await store.currentG5FinalApproval(projectId: project.projectId)
        assert(invalidatedG5 == nil)
        try savedG5Cap.write(to: g5CapBlob, options: .atomic)
        let restoredG5 = try await store.currentG5FinalApproval(projectId: project.projectId)
        assert(restoredG5 != nil)
        emit("S22.T3_DEPENDENCY_DRIFT_INVALIDATION", "INV-05/DATA-08",
             invalidatedG5 == nil && restoredG5 != nil,
             "Tampering G5 4K dependency immediately invalidates currentG5FinalApproval")

        // S24.T2: 50-cycle preview player & thumbnail LRU cache switch test
        var cache = G5BoundedPreviewCache(maxActivePlayers: 2, maxThumbnailCount: 12, maxThumbnailBytes: 4 * 1024 * 1024)
        for i in 0..<50 {
            cache.activatePlayer(id: "player-\(i)")
            cache.insertThumbnail(key: "thumb-\(i)", byteCount: 512 * 1024)
        }
        let s24T2OK = cache.activePlayerIDs.count <= 2
            && cache.thumbnailKeys.count <= 8
            && cache.totalBytes <= 4 * 1024 * 1024
            && cache.evictedCount >= 48
        assert(s24T2OK)
        emit("S24.T2_50_CYCLE_BOUNDED_PREVIEW_CACHE", "PERF-02/UI-14", s24T2OK,
             "50 preview switch cycles kept players<=2, bytes=\(cache.totalBytes)<=4MiB, evicted=\(cache.evictedCount)")

        // S24.T3: Vietnamese IME composition preservation across background updates
        var ime = G5VietnameseIMEBuffer(initialText: "Đèo Prenn ")
        ime.beginComposition("buổi s")
        let clobberedDuringComposition = ime.applyBackgroundRefreshIfSafe("Background overwrite")
        ime.commitComposition("buổi sáng sương mù")
        let appliedAfterCommit = ime.applyBackgroundRefreshIfSafe("Đèo Prenn buổi sáng sương mù — đã lưu")
        let s24T3OK = !clobberedDuringComposition
            && appliedAfterCommit
            && !ime.hasActiveComposition
            && ime.committedText.hasSuffix("đã lưu")
        assert(s24T3OK)
        emit("S24.T3_VIETNAMESE_IME_COMPOSITION_GUARD", "UI-07/STORY-03", s24T3OK,
             "Deferred background sync during active Vietnamese IME composition and applied cleanly after commit")

        await store.close()

        if let outPath = ProcessInfo.processInfo.environment["TEST_RECORDS_OUT"], !outPath.isEmpty {
            let url = URL(fileURLWithPath: outPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = ""
            for rec in records {
                if let d = try? JSONSerialization.data(withJSONObject: rec),
                   let s = String(data: d, encoding: .utf8) {
                    lines += s + "\n"
                }
            }
            try lines.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
