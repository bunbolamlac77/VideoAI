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
        dependencyIDs: [String],
        // (P1-02) When supplied, artifacts are read and hashed through this closure instead
        // of inside the caller's write transaction.
        fileReader: ((_ publicationID: String, _ kind: String, _ expectedSHA: String?, _ maxSize: Int) throws -> (String, [String: Any]?))? = nil
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
        let read: (_ id: String, _ kind: String, _ expected: String?, _ maxSize: Int) throws -> (String, [String: Any]?)
        if let fileReader {
            read = fileReader
        } else {
            read = { id, kind, expected, maxSize in
                try load(db, project: project, id: id, kind: kind, expected: expected, maxSize: maxSize)
            }
        }
        _ = try read(previewID, "g4_preview_mp4", g4Approval.previewSHA256, 4 * 1024 * 1024 * 1024)
        let (_, possibleCut) = try read(cutID, "g3_cut_plan", cutSHA, 8 * 1024 * 1024)
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
            _ = try read(mappingID, "g2_source_mapping", mappingSHA, 8 * 1024 * 1024)
            _ = try read(voiceID, "voice_wav", voiceSHA, 128 * 1024 * 1024)
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
                let (_, possibleReceipt) = try read(id, "g5_conform_receipt", nil, 8 * 1024 * 1024)
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
            _ = try read(id, "g5_captioned_cfr_4k", videoHash, 4 * 1024 * 1024 * 1024)
            expectedIDs.insert(id)
            expectedIDs.insert(receiptIDsByBeat[beatID]!)
        }
        guard expectedIDs == declared else {
            throw reject("Dependency IDs are not exactly the canonical G3/G4/G5 chain")
        }
    }

    /// (P1-02) Measure a file's SHA-256 and size on disk (used outside write transactions).
    static func measureFile(_ expectedSHA: String, path: String) throws -> (sha: String, size: Int64) {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw reject("Cannot open \(url.lastPathComponent) for hashing")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let data = (try? handle.read(upToCount: 1024 * 1024)) ?? nil
            guard let chunk = data, !chunk.isEmpty else { break }
            total += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA.lowercased() else {
            throw reject("Published artifact bytes changed on disk (\u{1F512})".replacingOccurrences(of: "\u{1F512}", with: url.lastPathComponent))
        }
        return (digest, total)
    }

    /// (P1-02) Hash and parse one committed publication on a private READ-ONLY connection.
    ///
    /// Hashing a multi-gigabyte artifact used to happen inside the caller's `BEGIN IMMEDIATE`
    /// transaction, holding the single writer (and every other writer in the app) hostage for
    /// the duration of the IO. The gates may gather their evidence first and then open the
    /// write transaction, passing these digests through `verifyFinalBindings(fileReader:)`.
    static func readPublishedArtifact(
        databasePath: String,
        project: UUID,
        id: String,
        kind: String,
        expectedSHA: String? = nil,
        maxSize: Int = 8 * 1024 * 1024
    ) throws -> (String, [String: Any]?) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            throw reject("Cannot open the canonical database read-only to hash an artifact")
        }
        defer { sqlite3_close(db) }
        return try load(db, project: project, id: id, kind: kind, expected: expectedSHA, maxSize: maxSize)
    }

    /// (P1-02) Read the approved script/manifest rows on a private read-only connection,
    /// before any write transaction is opened.
    private static func jsonObject(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw reject("Published artifact is not a JSON object")
        }
        return object
    }

    static func readApprovedCandidate(
        databasePath: String, projectId: UUID, g3ApprovalId: UUID, expectedManifestSHA: String
    ) throws -> (manifest: [String: Any], script: [String: Any], scriptRevisionId: String)? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return nil }
        defer { sqlite3_close(db) }
        guard let row = try row(db, """
            SELECT a.manifest_sha256, a.script_revision_id, a.manifest_json, s.candidate_json
            FROM g3_approvals a JOIN g3_scripts s
              ON s.script_revision_id = a.script_revision_id
            WHERE a.project_id = ? AND a.approval_id = ?
            """, [projectId.uuidString, g3ApprovalId.uuidString]),
              row[0] == expectedManifestSHA else { return nil }
        return (try jsonObject(row[2]), try jsonObject(row[3]), row[1])
    }

    /// (P1-02) Locate a committed publication's canonical bytes read-only.
    static func publicationLocation(
        databasePath: String, projectId: UUID, id: String, expected: String, expectedTypes: [String]
    ) -> (path: String, sha: String)? {
        // Only the canonical database (written by ProjectStore) is read here, read-only.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return nil }
        defer { sqlite3_close(db) }
        guard let row = try? row(db, """
            SELECT state, artifact_type, sha256_hash, canonical_path
            FROM artifact_publications WHERE publication_id = ? AND project_id = ?
            """, [id, projectId.uuidString]),
              row[0] == "COMMITTED", expectedTypes.contains(row[1]), row[2] == expected else {
            return nil
        }
        return (row[3], row[2])
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
    // MARK: - (P0-03) ffmpeg-native receipt provenance

    /// What the approved script + preview say a native receipt must contain.
    struct NativeReceiptExpectation: Sendable {
        var planSHA256: String?
        var g3ApprovalId: String?
        var g4ApprovalId: String?
        var publicationIDs: Set<String>?

        init(
            planSHA256: String? = nil,
            g3ApprovalId: String? = nil,
            g4ApprovalId: String? = nil,
            publicationIDs: Set<String>? = nil
        ) {
            self.planSHA256 = planSHA256
            self.g3ApprovalId = g3ApprovalId
            self.g4ApprovalId = g4ApprovalId
            self.publicationIDs = publicationIDs
        }
    }

    /// Stream a file through SHA-256 without loading it into memory.
    static func fileSHA256(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw reject("Cannot open \(url.lastPathComponent) for hashing")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 8 * 1024 * 1024)) ?? nil
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Independently inspect the exact S08 2160x3840 24fps final MP4 on disk.
    static func verifyFinalMP4(mp4Path: String, expectedFrames: Int) throws {
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
            throw reject("Final MP4 audio peaks at digital-full-scale or is not measurable")
        }
    }

    /// Shape + provenance + approval-chain binding of an ffmpeg-native render receipt.
    static func verifyNativeReceipt(
        receipt: [String: Any],
        mp4Path: String,
        expectedFrames: Int,
        expectation: NativeReceiptExpectation?
    ) throws {
        guard receipt["schema"] as? String == "native-render-receipt-v1" else {
            throw reject("Unknown provenance schema; expected native-render-receipt-v1")
        }
        guard receipt["width"] as? Int == 2160, receipt["height"] as? Int == 3840,
              receipt["fps"] as? Int == 24,
              receipt["total_frames"] as? Int == expectedFrames else {
            throw reject("Native receipt resolution/fps/frame count does not match the approved timeline")
        }
        guard let beats = receipt["beats"] as? [[String: Any]], !beats.isEmpty else {
            throw reject("Native receipt carries no beat evidence")
        }
        var sum = 0
        for beat in beats {
            guard let frames = beat["frames"] as? Int, frames > 0 else {
                throw reject("Native receipt beat without a frame length")
            }
            sum += frames
            if beat["kind"] as? String == "photo_insert" {
                // (P1-32) An inserted photo is published evidence: it must be committed
                // through S08 and cited here, not merely marked "illustrative_only".
                guard beat["usage"] as? String == "illustrative_only",
                      let photoHash = beat["photo_sha256"] as? String, hex(photoHash),
                      let photoPub = beat["photo_publication_id"] as? String,
                      UUID(uuidString: photoPub) != nil else {
                    throw reject("Photo insert must be illustrative_only, hashed and published")
                }
            } else {
                for key in ["video_sha256", "voice_sha256", "caption_text_sha256"] {
                    guard let value = beat[key] as? String, hex(value) else {
                        throw reject("Native receipt beat field \(key) is not a valid hash")
                    }
                }
            }
        }
        guard let overlap = receipt["transition_overlap_frames"] as? Int, overlap >= 0,
              sum - overlap == expectedFrames else {
            throw reject("Native receipt frame accounting (sum - overlaps) is inconsistent")
        }
        guard let output = receipt["output"] as? [String: Any],
              let declared = output["sha256"] as? String, hex(declared) else {
            throw reject("Native receipt is missing the output hash")
        }
        guard try fileSHA256(mp4Path) == declared.lowercased() else {
            throw reject("Final MP4 bytes do not match the native render receipt")
        }

        // (P0-03) The receipt must name the approval chain it was rendered from.
        guard let planSHA = receipt["plan_sha256"] as? String, hex(planSHA) else {
            throw reject("Native receipt does not name the approved plan it was rendered from")
        }
        if let expected = expectation?.planSHA256, planSHA.lowercased() != expected.lowercased() {
            throw reject("Native receipt was rendered from a different approved plan")
        }
        if let expected = expectation?.g3ApprovalId,
           (try text(receipt, "g3_approval_id")).lowercased() != expected.lowercased() {
            throw reject("Native receipt G3 approval differs from the approved script")
        }
        if let expected = expectation?.g4ApprovalId,
           (try text(receipt, "g4_approval_id")).lowercased() != expected.lowercased() {
            throw reject("Native receipt G4 approval differs from the approved preview")
        }
        if let allowed = expectation?.publicationIDs {
            let normalised = Set(allowed.map { $0.lowercased() })
            for beat in beats where (beat["kind"] as? String) != "photo_insert" {
                let videoID = try text(beat, "video_publication_id").lowercased()
                let voiceID = try text(beat, "voice_publication_id").lowercased()
                let mappingID = try text(beat, "mapping_publication_id").lowercased()
                guard normalised.contains(videoID), normalised.contains(voiceID),
                      normalised.contains(mappingID) else {
                    throw reject("Native receipt cites a publication outside the approved chain")
                }
            }
            for beat in beats where (beat["kind"] as? String) == "photo_insert" {
                let photoID = try text(beat, "photo_publication_id").lowercased()
                guard normalised.contains(photoID) else {
                    throw reject("Native receipt cites a photo publication outside the approved chain")
                }
            }
        }
    }

    /// Accept a Resolve `.drp` archive or an ffmpeg-native receipt for the same MP4.
    static func verifyFinalProvenance(
        mp4Path: String,
        provenancePath: String,
        expectedFrames: Int,
        expectation: NativeReceiptExpectation? = nil
    ) throws {
        guard (1...4319).contains(expectedFrames) else {
            throw reject("Invalid approved timeline duration (> 4319 frames)")
        }
        let url = URL(fileURLWithPath: provenancePath)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw reject("Published provenance artifact missing on disk")
        }
        let header = (try? handle.read(upToCount: 4)) ?? Data()
        try? handle.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: provenancePath)[.size] as? Int) ?? 0
        if header == Data([0x50, 0x4B, 0x03, 0x04]) {
            guard size > 1024 else {
                throw reject("Published .drp is not a valid ZIP archive > 1024 bytes")
            }
        } else {
            guard let data = try? Data(contentsOf: url),
                  let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw reject("Published provenance is neither a .drp ZIP nor a readable native receipt")
            }
            try verifyNativeReceipt(
                receipt: receipt, mp4Path: mp4Path,
                expectedFrames: expectedFrames, expectation: expectation
            )
        }
        try verifyFinalMP4(mp4Path: mp4Path, expectedFrames: expectedFrames)
    }
}
