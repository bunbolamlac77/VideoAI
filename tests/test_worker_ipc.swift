//
// test_worker_ipc.swift — Test suite for WorkerClient and JSON-RPC IPC
//

import Foundation

@main
struct TestWorkerIPC {
    static func main() async {
        print("=== RUNNING WORKER IPC TEST SUITE (S02) ===")
        let client = WorkerClient()

        let currentDir = FileManager.default.currentDirectoryPath
        let workerScript = (currentDir as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")

        // 1. Test startup & handshake
        do {
            print("1. Testing worker start & initialize handshake...")
            try await client.start(pythonPath: "/opt/homebrew/bin/python3.12", scriptPath: workerScript)
            let isConnected = await client.isConnected
            let pid = await client.workerPid
            let pyVer = await client.pythonVersion
            assert(isConnected, "Worker should be connected")
            assert(pid > 0, "Worker PID should be > 0")
            print("   PASS: Worker connected with PID \(pid), Python \(pyVer)")
        } catch {
            print("   FAIL: Worker start failed: \(error)")
            exit(1)
        }

        // 2. Test ping
        do {
            print("2. Testing system.ping heartbeat...")
            let pong = try await client.ping()
            assert(pong, "Ping should return pong")
            print("   PASS: system.ping successful")
        } catch {
            print("   FAIL: Ping failed: \(error)")
            exit(1)
        }

        // 3. Test local infer
        do {
            print("3. Testing local infer (100% offline)...")
            let text = "Hôm nay tôi chạy xe máy lên đèo Prenn Đà Lạt lúc 6 giờ sáng."
            let infer = try await client.localInferTest(text: text)
            assert(infer.status == "success", "Infer status should be success")
            assert(infer.mode == "100%_LOCAL_OFFLINE", "Mode must be 100%_LOCAL_OFFLINE")
            assert(infer.offlineVerified == true, "Must be verified offline")
            assert(!infer.contentSha256.isEmpty, "SHA256 must not be empty")
            print("   PASS: Local infer test passed (SHA-256: \(infer.contentSha256.prefix(12))..., Mode: \(infer.mode))")
        } catch {
            print("   FAIL: Local infer failed: \(error)")
            exit(1)
        }

        // 4. Test media probe on missing file (error handling check)
        do {
            print("4. Testing error handling on missing file...")
            _ = try await client.probeMedia(filePath: "/non/existent/file.mp4")
            print("   FAIL: Should have thrown file not found error")
            exit(1)
        } catch let WorkerError.rpcError(code, message) {
            assert(code == -32001, "Error code should be -32001 (FILE_NOT_FOUND)")
            print("   PASS: Correctly caught RPC error (\(code)): \(message)")
        } catch {
            print("   PASS: Caught expected error: \(error)")
        }

        // 5. Test clean shutdown & zombie check
        do {
            print("5. Testing worker termination and orphan prevention...")
            let pid = await client.workerPid
            await client.terminate()

            // Sleep briefly to ensure process exit
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Check if PID is still alive using kill(pid, 0)
            let isAlive = kill(pid, 0) == 0
            assert(!isAlive, "Worker process with PID \(pid) should be terminated, not orphaned!")
            print("   PASS: Worker process PID \(pid) successfully terminated without orphans.")
        }

        print("=== ALL S02 TESTS PASSED SUCCESSFULLY! ===")
    }
}
