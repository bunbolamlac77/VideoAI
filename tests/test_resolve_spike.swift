//
// test_resolve_spike.swift — Test suite for DaVinci Resolve G0 Spike (S03)
//

import Foundation

@main
struct TestResolveSpike {
    static func main() async {
        print("=== RUNNING DAVINCI RESOLVE G0 SPIKE TEST SUITE (S03) ===")
        let client = WorkerClient()

        let currentDir = FileManager.default.currentDirectoryPath
        let workerScript = (currentDir as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")

        // 1. Start worker
        do {
            print("1. Starting worker...")
            try await client.start(pythonPath: "/opt/homebrew/bin/python3.12", scriptPath: workerScript)
            let pid = await client.workerPid
            print("   PASS: Worker started with PID \(pid)")
        } catch {
            print("   FAIL: Worker startup failed: \(error)")
            exit(1)
        }

        // 2. Query Resolve status
        do {
            print("2. Checking DaVinci Resolve status via JSON-RPC...")
            let status = try await client.resolveStatus()
            let running = status["running"] as? Bool ?? false
            let product = status["product_name"] as? String ?? "N/A"
            let version = status["version"] as? String ?? "N/A"
            assert(running, "DaVinci Resolve should be running")
            print("   PASS: DaVinci Resolve is running (\(product) v\(version))")
        } catch {
            print("   FAIL: Resolve status check failed: \(error)")
            exit(1)
        }

        // 3. Run G0 Timeline Spike (10s vertical 2160x3840 24fps)
        do {
            print("3. Executing G0 Timeline Spike (10s Vertical 2160x3840 @ 24fps)...")
            let drpDestination = (currentDir as NSString).appendingPathComponent("fixtures/AIVideo_G0_Spike.drp")
            let spikeResult = try await client.runResolveSpike(drpPath: drpDestination)

            let status = spikeResult["status"] as? String
            let res = spikeResult["timeline_resolution"] as? String
            let fps = spikeResult["timeline_fps"] as? Double
            let drpExported = spikeResult["drp_exported"] as? Bool
            let vTracks = spikeResult["video_track_count"] as? Int
            let aTracks = spikeResult["audio_track_count"] as? Int
            let startFrame = spikeResult["timeline_start_frame"] as? Int
            let endFrame = spikeResult["timeline_end_frame"] as? Int

            assert(status == "PASS", "Spike status must be PASS")
            assert(res == "2160x3840", "Resolution must be 2160x3840 vertical")
            assert(fps == 24.0, "Timeline FPS must be 24.0")
            assert(drpExported == true, "DRP project archive must be exported")
            assert(FileManager.default.fileExists(atPath: drpDestination), "DRP file must exist on disk")

            print("   PASS: G0 Timeline Spike Completed Successfully!")
            print("         - Timeline Resolution: \(res ?? "")")
            print("         - Timeline FPS: \(fps ?? 0.0)")
            print("         - Frames: \(startFrame ?? 0) to \(endFrame ?? 0) (Total: \((endFrame ?? 0) - (startFrame ?? 0)))")
            print("         - Tracks: Video: \(vTracks ?? 0), Audio: \(aTracks ?? 0)")
            print("         - DRP Archive: \(drpDestination)")
        } catch {
            print("   FAIL: G0 Timeline Spike failed: \(error)")
            exit(1)
        }

        // 4. Terminate worker
        await client.terminate()
        print("=== ALL S03 TESTS PASSED AND GATE G0 IS READY TO CLOSE! ===")
    }
}
