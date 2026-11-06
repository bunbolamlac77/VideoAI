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

func recordResolveTestResult(
    testcaseId: String,
    requirementId: String,
    command: String = "./build/tests/test_resolve_spike",
    expected: String,
    observed: String,
    status: String,
    exitStatus: Int32,
    testType: String = "integration"
) {
    let reportDir = "build/reports"
    try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
    let record: [String: Any] = [
        "testcase_id": testcaseId,
        "requirement_id": requirementId,
        "suite": "resolve_spike",
        "command": command,
        "expected": expected,
        "observed": observed,
        "status": status,
        "test_type": testType,
        "exit_status": exitStatus,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/resolve_spike_records.jsonl"
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let lineData = (line + "\n").data(using: .utf8) {
                handle.write(lineData)
            }
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

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

        try? FileManager.default.removeItem(atPath: "build/reports/resolve_spike_records.jsonl")

        let client = WorkerClient()
        let workerScript = "workers/src/aivideo_workers/main.py"
        let pythonPath = "/opt/homebrew/bin/python3.12"

        do {
            _ = try await client.start(pythonPath: pythonPath, scriptPath: workerScript, timeoutSeconds: 5.0)
        } catch {
            recordResolveTestResult(
                testcaseId: "S03.T2",
                requirementId: "RES-05",
                expected: "Start worker and connect for Resolve status",
                observed: "Could not start worker: \(error)",
                status: "FAIL",
                exitStatus: 1
            )
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
                recordResolveTestResult(
                    testcaseId: "S03.T2",
                    requirementId: "RES-05",
                    expected: "Probe Resolve status and handle connected or disconnected state gracefully without crash",
                    observed: "Gracefully detected offline Resolve status without crash",
                    status: "PASS",
                    exitStatus: 0,
                    testType: "automated"
                )
            } else {
                print("   ✅ PASS: Connected to \(status.productName ?? "DaVinci Resolve") v\(status.version ?? "")")
                recordResolveTestResult(
                    testcaseId: "S03.T2",
                    requirementId: "RES-05",
                    expected: "Probe Resolve status and handle connected or disconnected state gracefully without crash",
                    observed: "Connected to \(status.productName ?? "DaVinci Resolve") v\(status.version ?? "") on macOS",
                    status: "PASS",
                    exitStatus: 0,
                    testType: "integration"
                )
            }
        } catch {
            recordResolveTestResult(
                testcaseId: "S03.T2",
                requirementId: "RES-05",
                expected: "Probe Resolve status and handle connected or disconnected state gracefully without crash",
                observed: "Status query threw error: \(error)",
                status: "FAIL",
                exitStatus: 1
            )
            print("   ❌ FAIL: Status query threw unexpected error: \(error)")
            exit(1)
        }

        // MARK: - Test 2: Attempt Spike on Resolve
        print("\n[Test 2] S03.T1/T2: Testing Resolve Spike Execution...")
        let status = try? await client.resolveStatus()
        if let st = status, st.connected {
            do {
                let spike = try await client.runResolveSpike(forceFreshRun: true)
                assertTrue(spike.success == true, "Spike execution must succeed")
                assertEqual(spike.timelineResolution, "2160x3840", "Timeline resolution must be 2160x3840")
                assertEqual(spike.timelineFps, 24.0, "Timeline FPS must be 24.0")
                assertEqual(spike.timelineTotalFrames, 240, "Timeline duration must be EXACTLY 240 frames for 10s @ 24fps (not 480!)")
                assertEqual(spike.videoItemDuration ?? 0, 240, "Video track item must be 240 frames")
                assertEqual(spike.audioItemDuration ?? 0, 240, "Audio track item must be 240 frames")
                assertTrue(spike.titleInserted, "Title item must be verified in timeline")
                assertTrue(spike.drpExported, "DRP must be exported successfully")
                assertTrue(spike.previewPath == nil, "previewPath must be nil when unrendered")

                recordResolveTestResult(
                    testcaseId: "S03.T1",
                    requirementId: "RES-01",
                    command: "Run 10s timeline spike in active DaVinci Resolve Studio instance",
                    expected: "Create timeline 2160x3840 @ 24.0fps with EXACTLY 240 frames, title item on V2, atomic DRP export",
                    observed: "Verified live in DaVinci Resolve Studio: 2160x3840 @ 24.0fps, exactly 240 frames, V2 title, DRP exported (preview_path=nil)",
                    status: "PASS",
                    exitStatus: 0,
                    testType: "integration"
                )
                print("   ✅ PASS: Real Resolve Spike executed successfully: \(spike.timelineResolution) @ \(spike.timelineFps)fps, Total Frames: \(spike.timelineTotalFrames) (preview_path=nil verified)")
            } catch {
                recordResolveTestResult(
                    testcaseId: "S03.T1",
                    requirementId: "RES-01",
                    command: "Run 10s timeline spike in active DaVinci Resolve Studio instance",
                    expected: "Create timeline 2160x3840 @ 24.0fps with EXACTLY 240 frames, title item on V2, atomic DRP export",
                    observed: "Resolve spike failed: \(error)",
                    status: "FAIL",
                    exitStatus: 1,
                    testType: "integration"
                )
                print("   ❌ FAIL: Resolve spike failed: \(error)")
                exit(1)
            }
        } else {
            print("   ℹ️ DaVinci Resolve is NOT running on this machine at the moment.")
            print("   Testing expected scoped error behavior when Resolve is offline (S03.T2):")
            do {
                _ = try await client.runResolveSpike()
                recordResolveTestResult(
                    testcaseId: "S03.T1",
                    requirementId: "RES-01",
                    command: "Run 10s timeline spike in active DaVinci Resolve Studio instance",
                    expected: "Fails cleanly when Resolve is offline",
                    observed: "Spike succeeded unexpectedly while offline",
                    status: "FAIL",
                    exitStatus: 1,
                    testType: "integration"
                )
                print("   ❌ FAIL: Expected error when Resolve is offline, but spike succeeded unexpectedly!")
                exit(1)
            } catch let WorkerError.rpcError(code, message, _) {
                assertTrue(message.contains("not running"), "Error should clearly report Resolve is not running")
                recordResolveTestResult(
                    testcaseId: "S03.T1",
                    requirementId: "RES-01",
                    command: "Run 10s timeline spike in active DaVinci Resolve Studio instance",
                    expected: "Create timeline 2160x3840 @ 24.0fps with EXACTLY 240 frames, title item, export DRP",
                    observed: "DaVinci Resolve Studio is not running during this run (Status: BLOCKED_BY_ENVIRONMENT)",
                    status: "BLOCKED",
                    exitStatus: 2,
                    testType: "integration"
                )
                print("   ✅ PASS: Correctly caught scoped RPC error (\(code)): \(message)")
            } catch {
                recordResolveTestResult(
                    testcaseId: "S03.T1",
                    requirementId: "RES-01",
                    command: "Run 10s timeline spike in active DaVinci Resolve Studio instance",
                    expected: "Create timeline 2160x3840 @ 24.0fps with EXACTLY 240 frames, title item, export DRP",
                    observed: "Caught unexpected error: \(error)",
                    status: "FAIL",
                    exitStatus: 1,
                    testType: "integration"
                )
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
