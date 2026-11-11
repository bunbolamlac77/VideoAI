// tests/test_g5_receipt_binding.swift — Regression for audit P0-03 (2026-11-11).
//
// `G5S22Guard.verifyNativeReceipt` only checked the receipt's own shape: schema, 2160x3840,
// 24 fps, a frame total, 64-hex fields anywhere, and that `output.sha256` matched the MP4.
// It never asked *which* approved plan, G3 approval or G4 approval the render came from,
// and the renderer never wrote those ids into the receipt. Any MP4 of the right shape plus
// a hand-written receipt could therefore pass S22.
//
// The receipt now names `plan_sha256` / `g3_approval_id` / `g4_approval_id`, and each
// rendered beat cites its `video_publication_id` / `voice_publication_id` /
// `mapping_publication_id`. `verifyFinalProvenance(expectation:)` rejects any receipt whose
// chain does not match the approved script and preview.

import Foundation
import CryptoKit

@main
struct TestG5ReceiptBinding {
    static func fail(_ message: String) -> Never {
        print("❌ FAIL: \(message)")
        exit(1)
    }

    static func sha(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            fail("ffmpeg failed: \(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
    }

    static let plan = String(repeating: "e", count: 64)
    static let g3 = "11111111-1111-4111-8111-111111111111"
    static let g4 = "22222222-2222-4222-8222-222222222222"
    static let videoPub = "33333333-3333-4333-8333-333333333333"
    static let voicePub = "44444444-4444-4444-8444-444444444444"
    static let mappingPub = "55555555-5555-4555-8555-555555555555"

    static func writeReceipt(
        path: String,
        mp4: String,
        planSHA: String = plan,
        g3Id: String = g3,
        g4Id: String = g4,
        video: String = videoPub,
        voice: String = voicePub,
        mapping: String = mappingPub,
        frames: Int = 24
    ) throws {
        let receipt: [String: Any] = [
            "schema": "native-render-receipt-v1",
            "engine": "ffmpeg_native",
            "width": 2160,
            "height": 3840,
            "fps": 24,
            "total_frames": frames,
            "sum_beat_frames": frames,
            "transition_overlap_frames": 0,
            "plan_sha256": planSHA,
            "g3_approval_id": g3Id,
            "g4_approval_id": g4Id,
            "beats": [[
                "beat_id": "b1",
                "frames": frames,
                "video_sha256": String(repeating: "a", count: 64),
                "voice_sha256": String(repeating: "b", count: 64),
                "caption_text_sha256": String(repeating: "c", count: 64),
                "video_publication_id": video,
                "voice_publication_id": voice,
                "mapping_publication_id": mapping,
                "caption_mode": "preburned_in_segment"
            ]],
            "output": ["path": mp4, "sha256": try sha(mp4)]
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func mustReject(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            fail("\(label) was accepted")
        } catch {
            print("✅ PASS: \(label) rejected — \(error.localizedDescription)")
        }
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("g5_binding_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mp4 = root.appendingPathComponent("final_4k.mp4").path
        try runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=size=2160x3840:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=300:duration=1",
            "-vf", "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=yuv420p",
            "-c:v", "libx264", "-r", "24",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-c:a", "aac", "-ar", "48000", "-ac", "1", "-t", "1", mp4
        ])

        let expectation = G5S22Guard.NativeReceiptExpectation(
            planSHA256: plan,
            g3ApprovalId: g3,
            g4ApprovalId: g4,
            publicationIDs: ["55555555-5555-4555-8555-555555555555",
                             "33333333-3333-4333-8333-333333333333",
                             "44444444-4444-4444-8444-444444444444"]
        )

        // 1) A receipt that matches the approved chain is accepted.
        let good = root.appendingPathComponent("good.json").path
        try writeReceipt(path: good, mp4: mp4)
        try G5S22Guard.verifyFinalProvenance(
            mp4Path: mp4, provenancePath: good, expectedFrames: 24, expectation: expectation
        )
        print("✅ PASS: receipt bound to the approved plan/G3/G4 chain verified")

        // 2) A receipt rendered from a different plan is refused.
        let otherPlan = root.appendingPathComponent("other_plan.json").path
        try writeReceipt(path: otherPlan, mp4: mp4, planSHA: String(repeating: "f", count: 64))
        mustReject("receipt from another plan") {
            try G5S22Guard.verifyFinalProvenance(
                mp4Path: mp4, provenancePath: otherPlan, expectedFrames: 24, expectation: expectation
            )
        }

        // 3) A receipt citing an approval that is not the approved script is refused.
        let otherG3 = root.appendingPathComponent("other_g3.json").path
        try writeReceipt(path: otherG3, mp4: mp4, g3Id: "99999999-9999-4999-8999-999999999999")
        mustReject("receipt citing a foreign G3 approval") {
            try G5S22Guard.verifyFinalProvenance(
                mp4Path: mp4, provenancePath: otherG3, expectedFrames: 24, expectation: expectation
            )
        }

        // 4) A receipt citing an unapproved publication is refused.
        let strangerVideo = root.appendingPathComponent("stranger.json").path
        try writeReceipt(path: strangerVideo, mp4: mp4, video: "77777777-7777-4777-8777-777777777777")
        mustReject("receipt citing a publication outside the chain") {
            try G5S22Guard.verifyFinalProvenance(
                mp4Path: mp4, provenancePath: strangerVideo, expectedFrames: 24, expectation: expectation
            )
        }

        // 5) A receipt missing the chain entirely is refused even without an expectation.
        let bare = root.appendingPathComponent("bare.json").path
        let bareReceipt: [String: Any] = [
            "schema": "native-render-receipt-v1",
            "width": 2160, "height": 3840, "fps": 24,
            "total_frames": 24, "transition_overlap_frames": 0,
            "beats": [["beat_id": "b1", "frames": 24]],
            "output": ["sha256": try sha(mp4)]
        ]
        try JSONSerialization.data(withJSONObject: bareReceipt).write(to: URL(fileURLWithPath: bare))
        mustReject("receipt without plan/G3/G4 binding") {
            try G5S22Guard.verifyFinalProvenance(mp4Path: mp4, provenancePath: bare, expectedFrames: 24)
        }

        print("G5 RECEIPT BINDING TESTS PASSED (5/5)")
    }
}
