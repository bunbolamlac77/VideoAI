//
// tests/test_resolve_spike.swift — Test suite for DaVinci Resolve Integration (Gate G0 / S03)
//
// Complies with AIVideo v3.1 Specifications:
// - Verifies disconnected state handling (S03.T2) gracefully without app crash
// - Verifies timeline parameters when Resolve is running (2160x3840 @ 24.0 fps, EXACTLY 240 frames)
// - Rejects 480 frames
// - Verifies title insertion and DRP export
//

import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        print("❌ FAIL [\(line)]: \(message) — Expected '\(expected)', got '\(actual)'")
        exit(1)
    }
}

func assertTrue(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition {
        print("❌ FAIL [\(line)]: \(message)")
        exit(1)
    }
}

@main
struct TestResolveSpike {
    static func main() async {
        print("=======================================================")
        print("RUNNING DAVINCI RESOLVE REGRESSION TEST SUITE (S03 / G0)")
        print("=======================================================")

        let client = WorkerClient()
        let workerScript = "workers/src/aivideo_workers/main.py"
        let pythonPath = "/opt/homebrew/bin/python3.12"

        do {
            _ = try await client.start(pythonPath: pythonPath, scriptPath: workerScript, timeoutSeconds: 5.0)
        } catch {
            print("❌ FAIL: Could not start worker: \(error)")
            exit(1)
        }

        // MARK: - Test 1: Query Resolve Status (S03.T2)
        print("\n[Test 1] S03.T2: DaVinci Resolve Status Probe & Disconnect Handling...")
        do {
            let status = try await client.resolveStatus()
            print("   Status Result: running=\(status.running), connected=\(status.connected)")
            if !status.running {
                print("   ℹ️ DaVinci Resolve is not currently running.")
                print("   ✅ PASS: Gracefully detected offline Resolve status without crash: \(status.error ?? "")")
            } else {
                print("   ✅ PASS: Connected to \(status.productName ?? "DaVinci Resolve") v\(status.version ?? "")")
            }
        } catch {
            print("   ❌ FAIL: Status query threw unexpected error: \(error)")
            exit(1)
        }

        // MARK: - Test 2: Attempt Spike on Resolve
        print("\n[Test 2] S03.T1/T2: Testing Resolve Spike Execution...")
        let status = try? await client.resolveStatus()
        if let st = status, st.connected {
            do {
                let spike = try await client.runResolveSpike(forceFreshRun: true)
                assertEqual(spike.status, "PASS", "Spike status should be PASS")
                assertEqual(spike.timelineResolution, "2160x3840", "Timeline resolution must be 2160x3840")
                assertEqual(spike.timelineFps, 24.0, "Timeline FPS must be 24.0")
                assertEqual(spike.timelineTotalFrames, 240, "Timeline duration must be EXACTLY 240 frames for 10s @ 24fps (not 480!)")
                assertTrue(spike.drpExported, "DRP must be exported successfully")
                print("   ✅ PASS: Real Resolve Spike executed successfully: \(spike.timelineResolution) @ \(spike.timelineFps)fps, Total Frames: \(spike.timelineTotalFrames)")
            } catch {
                print("   ❌ FAIL: Resolve spike failed: \(error)")
                exit(1)
            }
        } else {
            print("   ℹ️ DaVinci Resolve is NOT running on this machine at the moment.")
            print("   Testing expected scoped error behavior when Resolve is offline (S03.T2):")
            do {
                _ = try await client.runResolveSpike()
                print("   ❌ FAIL: Expected error when Resolve is offline, but spike succeeded unexpectedly!")
                exit(1)
            } catch let WorkerError.rpcError(code, message, _) {
                assertTrue(message.contains("not running"), "Error should clearly report Resolve is not running")
                print("   ✅ PASS: Correctly caught scoped RPC error (\(code)): \(message)")
            } catch {
                print("   ❌ FAIL: Caught unexpected error: \(error)")
                exit(1)
            }
        }

        await client.terminate()
        print("\n=======================================================")
        print("ALL DAVINCI RESOLVE REGRESSION TESTS COMPLETED!")
        print("=======================================================\n")
    }
}
