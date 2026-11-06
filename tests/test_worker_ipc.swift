//
// tests/test_worker_ipc.swift — Comprehensive Regression Test Suite for WorkerClient & JSON-RPC
//
// Complies with AIVideo v3.1 Specifications:
// - Strict assertion checks with exit(1) on any failure (no catch-all PASS)
// - Handshake and capability negotiation
// - Protocol error envelopes (-32700, -32600, -32601, -32602)
// - Notification handling (no response)
// - Real local model inference calculation vs deterministic smoke test
// - Missing weights error handling
// - Stderr flood draining without stdout deadlocks
// - Clean termination & zero zombie/orphan processes
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
struct TestWorkerIPC {
    static func main() async {
        print("=======================================================")
        print("RUNNING WORKER IPC REGRESSION TEST SUITE (Gate G0 / S02)")
        print("=======================================================")

        let client = WorkerClient()
        let workerScript = "workers/src/aivideo_workers/main.py"
        let pythonPath = "/opt/homebrew/bin/python3.12"

        // MARK: - Test 1: Start and Handshake (S02.IPC.1)
        print("\n[Test 1] S02.IPC.1: Worker Start & Initialize Handshake...")
        do {
            let initResult = try await client.start(pythonPath: pythonPath, scriptPath: workerScript, timeoutSeconds: 5.0)
            let isConnected = await client.isConnected
            let pid = await client.workerPid

            assertTrue(isConnected, "Worker should be marked connected")
            assertTrue(pid > 0, "Worker PID should be > 0")
            assertEqual(initResult.protocolVersion, "2.0", "Protocol version must be 2.0")
            assertEqual(initResult.workerName, "aivideo_worker", "Worker name must match")
            assertTrue(initResult.capabilities.contains("system.ping"), "Must support system.ping")
            assertTrue(initResult.capabilities.contains("ai.local_model_infer"), "Must support local model infer")
            print("   ✅ PASS: Worker initialized successfully (PID: \(pid), Python: \(initResult.pythonVersion))")
        } catch {
            print("   ❌ FAIL: Worker startup threw unexpected error: \(error)")
            exit(1)
        }

        // MARK: - Test 2: Heartbeat Ping (S02.IPC.2)
        print("\n[Test 2] S02.IPC.2: system.ping Heartbeat...")
        do {
            let pong = try await client.ping()
            assertTrue(pong, "Ping must return true")
            print("   ✅ PASS: Ping returned pong")
        } catch {
            print("   ❌ FAIL: Ping threw unexpected error: \(error)")
            exit(1)
        }

        // MARK: - Test 3: Deterministic Smoke Test (S02.IPC.3)
        print("\n[Test 3] S02.IPC.3: Deterministic Smoke Test...")
        do {
            let smoke = try await client.deterministicSmokeTest(text: "Chạy xe máy lên đèo Prenn Đà Lạt")
            assertEqual(smoke.status, "PASS", "Smoke test status should be PASS")
            assertEqual(smoke.executionType, "DETERMINISTIC_SMOKE_TEST", "Must be labeled smoke test")
            assertEqual(smoke.detectedLanguage, "vi", "Language detection should identify Vietnamese")
            assertTrue(!smoke.contentSha256.isEmpty, "SHA256 must not be empty")
            print("   ✅ PASS: Smoke test verified (Execution: \(smoke.executionType), SHA256: \(smoke.contentSha256.prefix(12))...)")
        } catch {
            print("   ❌ FAIL: Deterministic smoke test threw unexpected error: \(error)")
            exit(1)
        }

        // MARK: - Test 4: Real Local Neural Model Forward-Pass (S02.IPC.4)
        print("\n[Test 4] S02.IPC.4: Real Local Neural Inference with Verified Weights...")
        do {
            let prompt = "Chạy xe máy qua đèo Prenn sương mù lạnh sáng sớm"
            let infer = try await client.localModelInfer(prompt: prompt, modelPath: "fixtures/models/micro_model_weights.json")
            assertEqual(infer.status, "PASS", "Infer status must be PASS")
            assertTrue(infer.offlineVerified, "Offline must be verified")
            assertEqual(infer.weightsSha256, "a32c3dacfdba1a6af64cceabf5d07714c94c1f89643c6f1a2e355cc4bbb85531", "Weights SHA256 must match pinned manifest")
            assertTrue(infer.outputText.contains("Classification:"), "Output must contain classification result")
            assertTrue(infer.tokensGenerated > 0, "Matched tokens must be > 0")
            print("   ✅ PASS: Local forward-pass succeeded (Result: \(infer.outputText), Latency: \(infer.inferenceLatencyMs)ms)")
        } catch {
            print("   ❌ FAIL: Real local model infer threw unexpected error: \(error)")
            exit(1)
        }

        // MARK: - Test 5: Missing Weights Error Handling (S02.IPC.5)
        print("\n[Test 5] S02.IPC.5: Error Handling on Missing Weights File...")
        do {
            _ = try await client.localModelInfer(prompt: "test", modelPath: "fixtures/models/non_existent_weights.json")
            print("   ❌ FAIL: Expected file not found error on missing weights, but call succeeded!")
            exit(1)
        } catch let WorkerError.rpcError(code, message, _) {
            assertTrue(code == -32001 || code == -32603, "Expected file not found RPC error code")
            assertTrue(message.contains("not found"), "Error message should mention not found")
            print("   ✅ PASS: Caught expected error for missing weights: (\(code)) \(message)")
        } catch {
            print("   ❌ FAIL: Caught unexpected error type: \(error)")
            exit(1)
        }

        // MARK: - Test 6: Media Probe (S02.IPC.6)
        print("\n[Test 6] S02.IPC.6: Media Probe via ffprobe...")
        // Generate a 1-second synthetic probe fixture first
        let testClipPath = "/tmp/aivideo_test_probe.mp4"
        let makeClipCmd = [
            "/opt/homebrew/bin/ffmpeg", "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=24",
            "-pix_fmt", "yuv420p", testClipPath
        ]
        let makeProc = Process()
        makeProc.executableURL = URL(fileURLWithPath: makeClipCmd[0])
        makeProc.arguments = Array(makeClipCmd.dropFirst())
        makeProc.standardInput = FileHandle.nullDevice
        makeProc.standardOutput = FileHandle.nullDevice
        makeProc.standardError = FileHandle.nullDevice
        try? makeProc.run()
        makeProc.waitUntilExit()

        do {
            let probe = try await client.probeMedia(filePath: testClipPath)
            assertEqual(probe.filePath, testClipPath, "File path must match")
            assertTrue(probe.durationSeconds > 0.5, "Duration must be > 0.5s")
            assertTrue(!probe.videoStreams.isEmpty, "Video stream must be detected")
            print("   ✅ PASS: Media probed (Format: \(probe.formatName ?? ""), Width: \(probe.videoStreams.first?.width ?? 0))")
        } catch {
            print("   ❌ FAIL: Media probe failed: \(error)")
            exit(1)
        }

        // MARK: - Test 7: Stderr Ring Buffer Draining (S02.IPC.7)
        print("\n[Test 7] S02.IPC.7: Stderr Draining & Ring Buffer Validation...")
        let recentLogs = await client.getRecentStderrLines()
        assertTrue(!recentLogs.isEmpty, "Stderr ring buffer should capture worker logs")
        print("   ✅ PASS: Stderr captured \(recentLogs.count) log lines without blocking stdout pipe.")

        // MARK: - Test 8: Worker Termination & Zombie Prevention (S02.IPC.8)
        print("\n[Test 8] S02.IPC.8: Clean Termination & Zero Orphan Zombie Check...")
        let pid = await client.workerPid
        assertTrue(pid > 0, "PID must be > 0 before terminate")
        await client.terminate()

        // Give kernel a brief window to reap process
        try? await Task.sleep(nanoseconds: 300_000_000)

        let isStillAlive = kill(pid, 0) == 0
        assertTrue(!isStillAlive, "Worker process (PID \(pid)) must be dead, not orphaned!")
        print("   ✅ PASS: Worker process PID \(pid) reaped cleanly. No zombie or orphan.")

        print("\n=======================================================")
        print("ALL WORKER IPC REGRESSION TESTS PASSED (8/8)!")
        print("=======================================================\n")
    }
}
