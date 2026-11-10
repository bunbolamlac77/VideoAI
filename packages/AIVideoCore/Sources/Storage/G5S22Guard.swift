// G5S22Guard.swift — Independent Swift-side S22 Final 4K Render & Handoff Verification Gate.
// Verifies that the final 2160x3840 24fps SDR Rec.709 MP4, Resolve .drp archive, and all
// upstream G3/G4/G5 S08 publications are intact and decodable before committing S22 approval.

import Foundation
import SQLite3
import CryptoKit

enum G5S22Guard {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func reject(_ message: String) -> G3StoreError {
        G3StoreError.blocked("G5 S22: " + message)
    }

    private static func row(
        _ db: OpaquePointer, _ sql: String, _ args: [String]
    ) throws -> [String]? {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK,
              let stmt = raw else { throw reject("SQL prepare failed") }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in args.enumerated() {
            let ok = value.withCString {
                sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, transient)
            }
            guard ok == SQLITE_OK else { throw reject("SQL bind failed") }
        }
        let code = sqlite3_step(stmt)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw reject("SQL query failed") }
        return (0..<sqlite3_column_count(stmt)).map { col in
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }
    }

    private static func hex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func load(
        _ db: OpaquePointer, project: UUID, id: String, kind: String,
        expected: String? = nil, maxSize: Int = 8 * 1024 * 1024
    ) throws -> (String, [String: Any]?) {
        guard UUID(uuidString: id) != nil,
              let record = try row(db, """
                SELECT state, artifact_type, sha256_hash, canonical_path, byte_size
                FROM artifact_publications WHERE project_id=? AND publication_id=?
                """, [project.uuidString, id]),
              record[0] == "COMMITTED", record[1] == kind,
              hex(record[2]), expected == nil || expected == record[2],
              let count = Int(record[4]), count > 0, count <= maxSize else {
            throw reject("Missing or mismatched immutable publication " + kind)
        }
        let file = URL(fileURLWithPath: record[3])
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            throw reject("Published dependency missing on disk")
        }
        defer { try? handle.close() }
        var sha = SHA256()
        var measured = 0
        while true {
            let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            measured += bytes.count
            guard measured <= maxSize else { throw reject("Oversized published dependency") }
            sha.update(data: bytes)
        }
        let hash = sha.finalize().map { String(format: "%02x", $0) }.joined()
        guard measured == count, hash == record[2] else {
            throw reject("Published dependency tampered")
        }
        let object: [String: Any]?
        if kind == "g3_cut_plan" || kind == "g2_source_mapping" || kind == "g5_conform_receipt" {
            let data = try Data(contentsOf: file)
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            object = nil
        }
        return (hash, object)
    }

    private static func text(_ dict: [String: Any], _ key: String) throws -> String {
        guard let value = dict[key] as? String, !value.isEmpty else {
            throw reject("Missing " + key)
        }
        return value
    }

    private static func integer(_ dict: [String: Any], _ key: String) throws -> Int {
        guard let value = dict[key] as? Int, value >= 0 else {
            throw reject("Invalid " + key)
        }
        return value
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func verifyFinalBindings(
        db: OpaquePointer,
        project: UUID,
        g4Approval: G4PreviewApproval,
        candidate: [String: Any],
        manifest: [String: Any],
        dependencyIDs: [String]
    ) throws {
        guard let beats = candidate["beats"] as? [[String: Any]],
              let voices = manifest["voice_publications"] as? [[String: String]],
              beats.count == voices.count, !beats.isEmpty, beats.count <= 48,
              let cutID = manifest["cut_publication_id"] as? String,
              let cutSHA = manifest["edit_plan_sha256"] as? String else {
            throw reject("Invalid canonical G3 beat/cut manifest")
        }
        guard dependencyIDs.count == Set(dependencyIDs).count else {
            throw reject("Duplicate dependency IDs")
        }
        let declared = Set(dependencyIDs)
        let previewID = g4Approval.previewPublicationId.uuidString
        guard declared.contains(cutID), declared.contains(previewID) else {
            throw reject("G3 cut or S21 approved preview not pinned in G5 dependencies")
        }
        _ = try load(
            db, project: project, id: previewID,
            kind: "g4_preview_mp4", expected: g4Approval.previewSHA256,
            maxSize: 4 * 1024 * 1024 * 1024
        )
        let (_, possibleCut) = try load(
            db, project: project, id: cutID, kind: "g3_cut_plan", expected: cutSHA
        )
        guard let cut = possibleCut,
              cut["script_revision_id"] as? String == manifest["script_revision_id"] as? String,
              cut["scope_revision_id"] as? String == candidate["scope_revision_id"] as? String,
              cut["domain_sha256"] as? String == manifest["domain_sha256"] as? String,
              let shots = cut["edit_plan"] as? [[String: Any]], shots.count == beats.count else {
            throw reject("Cut content does not match G3 approval")
        }

        var expectedIDs = Set([cutID, previewID])
        var usedBeatIDs = Set<String>()
        var expectedVideoHashByBeat: [String: String] = [:]
        var expectedMappingByBeat: [String: String] = [:]
        var expectedSourceIDByBeat: [String: String] = [:]
        var expectedSourceHashByBeat: [String: String] = [:]
        var expectedStartByBeat: [String: Int] = [:]
        var expectedEndByBeat: [String: Int] = [:]
        var expectedDurationByBeat: [String: Int] = [:]
        var expectedTextHashByBeat: [String: String] = [:]

        for i in beats.indices {
            let beat = beats[i], shot = shots[i], voice = voices[i]
            let beatID = try text(beat, "beat_id")
            guard usedBeatIDs.insert(beatID).inserted, voice["beat_id"] == beatID,
                  let candidates = beat["shot_candidate_ids"] as? [String],
                  candidates.contains(try text(shot, "shot_id")) else {
                throw reject("Cut shot is not in approved beat domain")
            }
            let mappingID = try text(shot, "mapping_publication_id")
            let mappingSHA = try text(shot, "mapping_sha256")
            let voiceID = voice["publication_id"] ?? ""
            let voiceSHA = voice["sha256"] ?? ""
            guard declared.contains(mappingID), declared.contains(voiceID),
                  let voiceText = beat["voice_text"] as? String,
                  let textHash = voice["text_sha256"],
                  SHA256.hash(data: Data(voiceText.utf8)).map({ String(format: "%02x", $0) }).joined() == textHash else {
                throw reject("Missing mapping/WAV or narration altered")
            }
            _ = try load(db, project: project, id: mappingID, kind: "g2_source_mapping", expected: mappingSHA)
            _ = try load(db, project: project, id: voiceID, kind: "voice_wav", expected: voiceSHA,
                         maxSize: 128 * 1024 * 1024)
            expectedIDs.insert(mappingID)
            expectedIDs.insert(voiceID)
            expectedMappingByBeat[beatID] = mappingSHA
            expectedSourceIDByBeat[beatID] = try text(shot, "source_revision_id")
            expectedSourceHashByBeat[beatID] = try text(shot, "source_sha256")
            expectedStartByBeat[beatID] = try integer(shot, "range_start")
            expectedEndByBeat[beatID] = try integer(shot, "range_end")
            expectedDurationByBeat[beatID] = try integer(shot, "duration_frames")
            expectedTextHashByBeat[beatID] = textHash
        }

        var videoIDsByHash: [String: [String]] = [:]
        var receiptIDsByBeat: [String: String] = [:]
        for id in declared.subtracting(expectedIDs) {
            guard let metadata = try row(db, """
                SELECT artifact_type, sha256_hash FROM artifact_publications
                WHERE project_id=? AND publication_id=?
                """, [project.uuidString, id]) else {
                throw reject("Unknown G5 dependency")
            }
            if metadata[0] == "g5_captioned_cfr_4k" {
                videoIDsByHash[metadata[1], default: []].append(id)
            } else if metadata[0] == "g5_conform_receipt" {
                let (_, possibleReceipt) = try load(db, project: project, id: id, kind: "g5_conform_receipt")
                guard let receipt = possibleReceipt,
                      receipt["schema"] as? String == "g5-conform-receipt-v1" else {
                    throw reject("Invalid G5 conform receipt")
                }
                let beatID = try text(receipt, "beat_id")
                guard usedBeatIDs.contains(beatID), receiptIDsByBeat[beatID] == nil,
                      receipt["source_revision_id"] as? String == expectedSourceIDByBeat[beatID],
                      receipt["source_sha256"] as? String == expectedSourceHashByBeat[beatID],
                      receipt["mapping_sha256"] as? String == expectedMappingByBeat[beatID],
                      receipt["voice_text_sha256"] as? String == expectedTextHashByBeat[beatID],
                      receipt["g4_approval_id"] as? String == g4Approval.approvalId.uuidString,
                      receipt["g4_preview_sha256"] as? String == g4Approval.previewSHA256,
                      receipt["caption_policy"] as? String == "approved_phrase_cues_raster",
                      receipt["crop_policy"] as? String == "fit_preserves_full_frame",
                      try integer(receipt, "width") == 2160,
                      try integer(receipt, "height") == 3840,
                      try integer(receipt, "start_frame") == expectedStartByBeat[beatID],
                      try integer(receipt, "end_frame") == expectedEndByBeat[beatID],
                      try integer(receipt, "render_frames") == expectedDurationByBeat[beatID],
                      let cues = receipt["caption_cues"] as? [[String: Any]],
                      !cues.isEmpty, cues.count <= 64 else {
                    throw reject("G5 conform receipt not bound to approved G3/G4 beat")
                }
                let narration = beats.first(where: { $0["beat_id"] as? String == beatID })?["voice_text"] as? String ?? ""
                let phrases = try cues.map { try text($0, "text") }.joined(separator: " ")
                guard normalized(phrases) == normalized(narration) else {
                    throw reject("G5 caption phrases differ from approved narration")
                }
                receiptIDsByBeat[beatID] = id
                expectedVideoHashByBeat[beatID] = try text(receipt, "video_sha256")
            } else {
                throw reject("Unexpected G5 dependency type: " + metadata[0])
            }
        }
        guard receiptIDsByBeat.count == beats.count,
              videoIDsByHash.values.reduce(0, { $0 + $1.count }) == beats.count else {
            throw reject("Missing one G5 4K video and conform receipt per beat")
        }
        for (beatID, videoHash) in expectedVideoHashByBeat {
            guard var ids = videoIDsByHash[videoHash], !ids.isEmpty else {
                throw reject("G5 receipt has no published 4K captioned video")
            }
            let id = ids.removeFirst()
            videoIDsByHash[videoHash] = ids
            _ = try load(
                db, project: project, id: id,
                kind: "g5_captioned_cfr_4k", expected: videoHash,
                maxSize: 4 * 1024 * 1024 * 1024
            )
            expectedIDs.insert(id)
            expectedIDs.insert(receiptIDsByBeat[beatID]!)
        }
        guard expectedIDs == declared else {
            throw reject("Dependency IDs are not exactly the canonical G3/G4/G5 chain")
        }
    }

    private static func tool(_ basename: String) throws -> URL {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map {
            URL(fileURLWithPath: $0).appendingPathComponent(basename)
        }
        guard let path = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw reject("Install " + basename + " before S22 final approval") }
        return path
    }

    private static func run(_ tool: String, _ args: [String], timeout: Int) throws -> String {
        let proc = Process()
        proc.executableURL = try self.tool(tool)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let completed = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in completed.signal() }
        do { try proc.run() } catch {
            throw reject("Cannot launch local " + tool)
        }
        if completed.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            proc.terminate()
            throw reject(tool + " timed out")
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard proc.terminationStatus == 0 else {
            throw reject(tool + " rejected final MP4: " + String(errors.suffix(250)))
        }
        return output + "\n" + errors
    }

    private static func frameRate(_ raw: Any?) -> Double {
        guard let s = raw as? String else { return 0 }
        let parts = s.split(separator: "/")
        guard let n = Double(parts[0]), n.isFinite, n > 0 else { return 0 }
        if parts.count == 1 { return n }
        guard parts.count == 2, let d = Double(parts[1]), d.isFinite, d > 0 else { return 0 }
        return n / d
    }

    /// Independently inspect the exact S08 2160x3840 24fps final MP4 and .drp archive on disk.
    static func verifyFinalMP4AndDRP(mp4Path: String, drpPath: String, expectedFrames: Int) throws {
        guard (1...4319).contains(expectedFrames) else {
            throw reject("Invalid approved timeline duration (> 4319 frames)")
        }
        // Verify DRP is a non-empty ZIP archive (>1024 bytes, starts with PK\x03\x04)
        let drpURL = URL(fileURLWithPath: drpPath)
        guard let drpHandle = try? FileHandle(forReadingFrom: drpURL) else {
            throw reject("Published Resolve .drp archive missing on disk")
        }
        let drpHeader = (try? drpHandle.read(upToCount: 4)) ?? Data()
        try? drpHandle.close()
        let drpSize = (try? FileManager.default.attributesOfItem(atPath: drpPath)[.size] as? Int) ?? 0
        guard drpSize > 1024, drpHeader == Data([0x50, 0x4B, 0x03, 0x04]) else {
            throw reject("Published .drp is not a valid ZIP archive > 1024 bytes")
        }

        let probe = try run("ffprobe", [
            "-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", mp4Path
        ], timeout: 180)
        guard let json = try? JSONSerialization.jsonObject(with: Data(probe.utf8)) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let format = json["format"] as? [String: Any] else {
            throw reject("ffprobe output is invalid")
        }
        let videos = streams.filter { $0["codec_type"] as? String == "video" }
        let audios = streams.filter { $0["codec_type"] as? String == "audio" }
        guard videos.count == 1, audios.count == 1 else {
            throw reject("Final MP4 requires exactly one video and one audio stream")
        }
        let v = videos[0], a = audios[0]
        guard v["width"] as? Int == 2160, v["height"] as? Int == 3840,
              frameRate(v["avg_frame_rate"]) == 24, frameRate(v["r_frame_rate"]) == 24,
              v["color_primaries"] as? String == "bt709",
              v["color_transfer"] as? String == "bt709",
              v["color_space"] as? String == "bt709",
              v["pix_fmt"] as? String == "yuv420p" || v["pix_fmt"] as? String == "yuv420p10le",
              Int(v["nb_read_frames"] as? String ?? "") == expectedFrames,
              a["sample_rate"] as? String == "48000",
              let secondsText = format["duration"] as? String,
              let seconds = Double(secondsText),
              seconds < 180.0,
              abs(seconds - Double(expectedFrames) / 24.0) <= (1.0 / 24.0 + 0.03) else {
            throw reject("Final MP4 frame count/24fps/2160x3840/bt709/48kHz or duration mismatch")
        }
        let volume = try run("ffmpeg", [
            "-hide_banner", "-nostdin", "-nostats", "-i", mp4Path,
            "-vn", "-af", "volumedetect", "-f", "null", "-"
        ], timeout: 180)
        let pattern = #"max_volume:\s*([+-]?(?:\d+(?:\.\d+)?|inf))\s*dB"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(volume.startIndex..<volume.endIndex, in: volume)
        guard let match = regex.matches(in: volume, range: range).last,
              let valueRange = Range(match.range(at: 1), in: volume),
              let peak = Double(volume[valueRange]), peak < -0.01 else {
            throw reject("Final MP4 audio peaks at digital full-scale or is not measurable")
        }
    }
}
