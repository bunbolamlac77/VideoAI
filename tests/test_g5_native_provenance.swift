// test_g5_native_provenance.swift — S22 guard accepts the ffmpeg-native receipt.
//
// The Resolve path published a `.drp` archive as the provenance artifact. After
// Phase 1b the same slot may carry `native-render-receipt-v1`, so the guard must:
//   * accept a receipt whose frame accounting (sum - overlaps) and MP4 hash match;
//   * reject a receipt whose total frame count was altered;
//   * reject a receipt whose output hash does not match the MP4 bytes;
//   * keep rejecting a truncated/absent provenance file.
// The MP4 itself still has to pass the full 2160x3840 / 24fps / bt709 / 48 kHz
// technical contract, so the receipt can never paper over a bad export.

import Foundation
import SQLite3
import CryptoKit

@main
struct TestG5NativeProvenance {
    static func fail(_ message: String) -> Never {
        print("❌ FAIL: \(message)")
        exit(1)
    }

    static func sha(_ path: String) throws -> String {
        try G5S22Guard.fileSHA256(path)
    }

    static func runFFmpeg(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            fail("ffmpeg failed: \(String(decoding: data, as: UTF8.self))")
        }
    }

    static func writeReceipt(
        path: String, mp4: String, totalFrames: Int, sumFrames: Int, overlap: Int
    ) throws {
        let mp4Hash = try sha(mp4)
        let receipt: [String: Any] = [
            "schema": "native-render-receipt-v1",
            "engine": "ffmpeg_native",
            "width": 2160,
            "height": 3840,
            "fps": 24,
            "total_frames": totalFrames,
            "sum_beat_frames": sumFrames,
            "transition_overlap_frames": overlap,
            // (P0-03) a receipt names the approval chain it came from ...
            "plan_sha256": String(repeating: "e", count: 64),
            "g3_approval_id": "11111111-1111-4111-8111-111111111111",
            "g4_approval_id": "22222222-2222-4222-8222-222222222222",
            "beats": [
                // ... and every rendered beat cites its own published artifacts.
                ["beat_id": "b1", "frames": 24,
                 "video_sha256": String(repeating: "a", count: 64),
                 "voice_sha256": String(repeating: "b", count: 64),
                 "caption_text_sha256": String(repeating: "c", count: 64),
                 "video_publication_id": "33333333-3333-4333-8333-333333333333",
                 "voice_publication_id": "44444444-4444-4444-8444-444444444444",
                 "mapping_publication_id": "55555555-5555-4555-8555-555555555555",
                 "receipt_publication_id": "66666666-6666-4666-8666-666666666666",
                 "caption_mode": "preburned_in_segment"],
                // (P1-32) an inserted photo is published evidence: it cites the S08
                // publication the photo was committed under.
                ["beat_id": "b1__photo", "kind": "photo_insert", "frames": overlap,
                 "photo_sha256": String(repeating: "d", count: 64),
                 "photo_publication_id": "77777777-7777-4777-8777-777777777777",
                 "usage": "illustrative_only"],
            ],
            "output": ["path": mp4, "sha256": mp4Hash],
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g5_native_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mp4 = root.appendingPathComponent("final_4k.mp4").path
        try runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=size=2160x3840:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=300:duration=1",
            "-vf", "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=yuv420p",
            "-c:v", "libx264", "-r", "24",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
            "-c:a", "aac", "-ar", "48000", "-ac", "1", "-t", "1", mp4,
        ])

        // 1) Valid native receipt for a byte-identical MP4 is accepted.
        let receipt = root.appendingPathComponent("final.receipt.json").path
        try writeReceipt(path: receipt, mp4: mp4, totalFrames: 24, sumFrames: 30, overlap: 6)
        try G5S22Guard.verifyFinalProvenance(mp4Path: mp4, provenancePath: receipt, expectedFrames: 24)
        print("✅ PASS: native receipt + 4K MP4 verified")

        // 2) Altered frame accounting is refused.
        let badFrames = root.appendingPathComponent("bad_frames.json").path
        try writeReceipt(path: badFrames, mp4: mp4, totalFrames: 25, sumFrames: 30, overlap: 6)
        do {
            try G5S22Guard.verifyFinalProvenance(mp4Path: mp4, provenancePath: badFrames, expectedFrames: 24)
            fail("altered total_frames was accepted")
        } catch {
            print("✅ PASS: altered frame count rejected")
        }

        // 3) Receipt bound to different bytes is refused.
        let otherMp4 = root.appendingPathComponent("other.mp4").path
        try runFFmpeg([
            "-f", "lavfi", "-i", "smptebars=size=2160x3840:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=500:duration=1",
            "-vf", "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=yuv420p",
            "-c:v", "libx264", "-r", "24",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
            "-c:a", "aac", "-ar", "48000", "-ac", "1", "-t", "1", otherMp4,
        ])
        do {
            try G5S22Guard.verifyFinalProvenance(
                mp4Path: otherMp4, provenancePath: receipt, expectedFrames: 24
            )
            fail("receipt with mismatched MP4 hash was accepted")
        } catch {
            print("✅ PASS: receipt/MP4 hash mismatch rejected")
        }

        // 4) A truncated provenance file is refused before touching the MP4.
        let junk = root.appendingPathComponent("junk.bin").path
        try Data("not-a-receipt".utf8).write(to: URL(fileURLWithPath: junk))
        do {
            try G5S22Guard.verifyFinalProvenance(mp4Path: mp4, provenancePath: junk, expectedFrames: 24)
            fail("junk provenance was accepted")
        } catch {
            print("✅ PASS: unreadable provenance rejected")
        }

        print("G5 NATIVE PROVENANCE TESTS PASSED")
    }
}
