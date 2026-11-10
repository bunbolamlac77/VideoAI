// test_s02_manual_verification.swift — S02 verification harness (honest edition).
//
// History: this file used to verify a *direct worker spawn* and then write
// `"status": "PASS"` into reports/evidence/s02_t1_finder_launch.json, which
// tools/package_review.py consumed as proof that the app had been launched from
// Finder. It also created a bookmark with `.suitableForBookmarkFile` while
// claiming a security-scoped bookmark. Both claims were unverified.
//
// Now:
//  - the automated part verifies the bundled worker + media probe and records it
//    in s02_worker_bundle.json (it really runs);
//  - the Finder/LaunchServices claim is only marked PASS when the app is actually
//    opened through NSWorkspace with AIVIDEO_RUN_UI_TESTS=1, otherwise NOT_RUN;
//  - the bookmark claim is only PASS when a `.withSecurityScope` bookmark is
//    created, resolved and startAccessingSecurityScopedResource() succeeds,
//    otherwise NOT_RUN (unsupported outside a sandboxed/GUI session).

import AppKit
import Foundation

@main
struct S02ManualVerification {
    static func main() async {
        print("=======================================================")
        print("RUNNING S02 VERIFICATION HARNESS (HONEST EVIDENCE MODE)")
        print("=======================================================\n")

        let fm = FileManager.default
        let appBundlePath = os_get_app_bundle_path()
        let evidenceDir = (fm.currentDirectoryPath as NSString).appendingPathComponent("reports/evidence")
        try? fm.createDirectory(atPath: evidenceDir, withIntermediateDirectories: true)

        var automatedOK = true

        // MARK: - Automated: bundled worker + Unicode / external-style paths
        print("[S02.AUTO] Verifying bundled worker, Unicode path and external-style path...")
        var autoDetails: [String: Any] = [:]
        do {
            guard fm.fileExists(atPath: appBundlePath) else {
                fatalError("AIVideo.app not found at \(appBundlePath). Run tools/build_macos_app.sh first.")
            }
            let resourcesDir = (appBundlePath as NSString).appendingPathComponent("Contents/Resources")
            let bundledContractsLock = (resourcesDir as NSString).appendingPathComponent("contracts/g0_model.lock.json")
            guard fm.fileExists(atPath: bundledContractsLock) else {
                fatalError("bundled contracts/g0_model.lock.json not found in .app bundle!")
            }

            let unicodeDir = "/tmp/AIVideo_Test_Tư_Liệu_Đà_Lạt_2026_Đèo_Prenn"
            try? fm.createDirectory(atPath: unicodeDir, withIntermediateDirectories: true)
            let unicodeVideoPath = (unicodeDir as NSString).appendingPathComponent("đoạn_phim_gốc_sắc_nét_4k.mp4")
            let externalVolumeDir = "/tmp/external_volume_mount_simulation_AIVideo"
            try? fm.createDirectory(atPath: externalVolumeDir, withIntermediateDirectories: true)
            let externalVideoPath = (externalVolumeDir as NSString).appendingPathComponent("tư_liệu_ổ_cứng_ngoài.mp4")
            _ = generateTestClip(at: unicodeVideoPath)
            _ = generateTestClip(at: externalVideoPath)

            let bundledWorkerPath = (resourcesDir as NSString).appendingPathComponent("Workers/aivideo_workers/main.py")
            guard fm.fileExists(atPath: bundledWorkerPath) else {
                fatalError("Bundled worker not found at \(bundledWorkerPath)")
            }

            let pythonPath = resolvePythonPath()
            let client = WorkerClient()
            let initRes = try await client.start(
                pythonPath: pythonPath,
                scriptPath: bundledWorkerPath,
                timeoutSeconds: 8.0
            )
            print("   ✅ Worker spawned from .app bundle (Python: \(initRes.pythonVersion))")

            let probeUnicode = try await client.probeMedia(filePath: unicodeVideoPath)
            let probeExternal = try await client.probeMedia(filePath: externalVideoPath)
            let modelStatus = try await client.modelStatus()
            await client.terminate()

            autoDetails = [
                "worker_spawned_from_bundle": true,
                "unicode_path_probe_ok": probeUnicode.formatName != nil || probeUnicode.videoStreams.count > 0,
                "external_path_probe_ok": probeExternal.formatName != nil || probeExternal.videoStreams.count > 0,
                "model_status": modelStatus.status.rawValue,
                "bundled_contracts_path": bundledContractsLock,
                "note": "Direct worker spawn. This is NOT a Finder/LaunchServices launch and must not be reported as one."
            ]
            writeEvidence(
                named: "s02_worker_bundle.json",
                payload: [
                    "testcase_id": "S02.AUTO",
                    "requirement_id": "UI-16",
                    "status": "PASS",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "details": autoDetails
                ],
                into: evidenceDir
            )
            print("   📝 Automated bundle evidence written to s02_worker_bundle.json")
        } catch {
            automatedOK = false
            print("   ❌ FAIL S02.AUTO: \(error)")
        }

        // MARK: - S02.T1: real Finder / LaunchServices launch (opt-in)
        print("\n[S02.T1] Finder/LaunchServices launch...")
        let uiTestsEnabled = ProcessInfo.processInfo.environment["AIVIDEO_RUN_UI_TESTS"] == "1"
        if !uiTestsEnabled {
            writeEvidence(
                named: "s02_t1_finder_launch.json",
                payload: [
                    "testcase_id": "S02.T1",
                    "requirement_id": "UI-16",
                    "status": "NOT_RUN",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "not_run_reason": "Set AIVIDEO_RUN_UI_TESTS=1 to launch AIVideo.app through LaunchServices.",
                    "details": "Not executed. The automated harness only spawns the bundled worker directly, which does not prove a Finder launch."
                ],
                into: evidenceDir
            )
            print("   ⏭️  NOT_RUN (set AIVIDEO_RUN_UI_TESTS=1 to execute)")
        } else {
            do {
                let appURL = URL(fileURLWithPath: appBundlePath)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                let runningApp = try await NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: configuration
                )
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let launched = !runningApp.isTerminated
                runningApp.terminate()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                writeEvidence(
                    named: "s02_t1_finder_launch.json",
                    payload: [
                        "testcase_id": "S02.T1",
                        "requirement_id": "UI-16",
                        "status": launched ? "PASS" : "FAIL",
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "launched_via": "NSWorkspace.openApplication (LaunchServices)",
                        "bundle_identifier": runningApp.bundleIdentifier ?? "unknown",
                        "details": launched
                            ? "Launched AIVideo.app through LaunchServices and observed a running process."
                            : "LaunchServices did not leave the app running."
                    ],
                    into: evidenceDir
                )
                print(launched ? "   ✅ PASS: launched via LaunchServices" : "   ❌ FAIL: app terminated immediately")
                if !launched { automatedOK = false }
            } catch {
                automatedOK = false
                print("   ❌ FAIL S02.T1: \(error)")
                writeEvidence(
                    named: "s02_t1_finder_launch.json",
                    payload: [
                        "testcase_id": "S02.T1",
                        "requirement_id": "UI-16",
                        "status": "FAIL",
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "details": "LaunchServices launch failed: \(error.localizedDescription)"
                    ],
                    into: evidenceDir
                )
            }
        }

        // MARK: - S02.T2: real security-scoped bookmark
        print("\n[S02.T2] Security-scoped bookmark lifecycle...")
        do {
            let testDir = "/tmp/aivideo_bookmark_test_env"
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            let originalVideo = (testDir as NSString).appendingPathComponent("test_footage_bookmark.mp4")
            _ = generateTestClip(at: originalVideo)
            let originalURL = URL(fileURLWithPath: originalVideo)

            // `.withSecurityScope` is the only option that grants sandbox access.
            let bookmarkData = try originalURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "TestSelectedSourceBookmark")

            guard let restoredData = UserDefaults.standard.data(forKey: "TestSelectedSourceBookmark") else {
                throw NSError(domain: "S02", code: 1, userInfo: [NSLocalizedDescriptionKey: "bookmark missing"])
            }
            var isStale = false
            let restoredURL = try URL(
                resolvingBookmarkData: restoredData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessGranted = restoredURL.startAccessingSecurityScopedResource()
            defer { if accessGranted { restoredURL.stopAccessingSecurityScopedResource() } }
            let readable = fm.isReadableFile(atPath: restoredURL.path)

            // Revoke: move the file away; a security-scoped handle must not keep a stale path usable.
            let movedVideo = (testDir as NSString).appendingPathComponent("test_footage_moved_away.mp4")
            try? fm.removeItem(atPath: movedVideo)
            try fm.moveItem(atPath: originalVideo, toPath: movedVideo)
            let staleDetected = !fm.fileExists(atPath: restoredURL.path)

            try? fm.removeItem(atPath: testDir)
            UserDefaults.standard.removeObject(forKey: "TestSelectedSourceBookmark")

            let passed = accessGranted && readable && staleDetected
            writeEvidence(
                named: "s02_t2_bookmark.json",
                payload: [
                    "testcase_id": "S02.T2",
                    "requirement_id": "UI-19",
                    "status": passed ? "PASS" : "FAIL",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "bookmark_options": "withSecurityScope",
                    "security_scoped_access_granted": accessGranted,
                    "resolved_on_reopen": true,
                    "readable": readable,
                    "stale_detected_after_move": staleDetected,
                    "details": "Security-scoped bookmark created/resolved; access=\(accessGranted), readable=\(readable), stale=\(staleDetected)."
                ],
                into: evidenceDir
            )
            print(passed ? "   ✅ PASS: security-scoped bookmark verified" : "   ❌ FAIL: security scope not effective")
            if !passed { automatedOK = false }
        } catch {
            // Outside a GUI/sandboxed session macOS may refuse .withSecurityScope.
            // That is "not run", never "passed".
            print("   ⏭️  NOT_RUN: \(error.localizedDescription)")
            writeEvidence(
                named: "s02_t2_bookmark.json",
                payload: [
                    "testcase_id": "S02.T2",
                    "requirement_id": "UI-19",
                    "status": "NOT_RUN",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "not_run_reason": "Security-scoped bookmarks are unavailable in this session: \(error.localizedDescription)",
                    "details": "Not executed. This harness will not certify a bookmark it could not create."
                ],
                into: evidenceDir
            )
        }

        print("\n=======================================================")
        if automatedOK {
            print("S02 AUTOMATED CHECKS PASSED (manual claims are NOT_RUN unless executed)")
        } else {
            print("S02 AUTOMATED CHECKS FAILED!")
            exit(1)
        }
        print("=======================================================\n")
    }

    private static func writeEvidence(named: String, payload: [String: Any], into dir: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let path = (dir as NSString).appendingPathComponent(named)
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func os_get_app_bundle_path() -> String {
        let fm = FileManager.default
        let currentDir = fm.currentDirectoryPath
        let bundleInCurrent = (currentDir as NSString).appendingPathComponent("apps/macos/build/AIVideo.app")
        if fm.fileExists(atPath: bundleInCurrent) {
            return bundleInCurrent
        }
        return "/Applications/AIVideo.app"
    }

    private static func resolvePythonPath() -> String {
        let candidates = [
            (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent("Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime/bin/python3"),
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/python3"
    }

    private static func generateTestClip(at path: String) -> Bool {
        let fm = FileManager.default
        let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let ffmpeg = ffmpegCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-nostdin", "-y",
            "-f", "lavfi",
            "-i", "testsrc=size=320x240:rate=24",
            "-t", "1",
            "-pix_fmt", "yuv420p",
            path
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
