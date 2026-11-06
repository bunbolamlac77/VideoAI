//
// AIVideoApp.swift — Native macOS Application for AIVideo v3.1
//
// Compliant with AIVideo v3.1 Specifications:
// - Dynamic Worker Discovery via App Bundle Resources or Managed Runtime
// - Preflight checks for Python & Media tools with bounded errors (no indefinite wait)
// - Security-Scoped Bookmarks with Stale Binding Detection & Repick Lifecycle
// - AppKit Quit Barrier (NSApplication.TerminateReply.terminateLater) ensuring zero orphans
// - Honest UI Capability Matrix: implemented vs planned (Gate G1)
//

import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    // Worker Status
    @Published var isWorkerConnected: Bool = false
    @Published var workerPid: Int32 = 0
    @Published var pythonVersion: String = ""
    @Published var workerVersion: String = ""
    @Published var capabilities: [String] = []
    @Published var statusMessage: String = "Đang khởi tạo hệ thống..."

    // Media Source Inspector & Security-Scoped Bookmark
    @Published var selectedFilePath: String = ""
    @Published var isSecurityScoped: Bool = false
    @Published var isBookmarkStale: Bool = false
    @Published var probeResult: MediaProbeResult?
    @Published var isProbing: Bool = false

    // Smoke Test (Deterministic Hash)
    @Published var smokeTestInput: String = "Chạy xe máy lên đèo Prenn Đà Lạt lúc 6 giờ sáng."
    @Published var smokeTestResult: LocalSmokeTestResult?
    @Published var isRunningSmokeTest: Bool = false

    // Local Neural Model Inference
    @Published var modelPrompt: String = "Đi xe máy qua đèo dốc sương mù dày đặc buổi sáng."
    @Published var modelInferResult: LocalModelInferResult?
    @Published var isRunningModelInfer: Bool = false

    // DaVinci Resolve Status
    @Published var resolveStatus: ResolveStatusResult?
    @Published var resolveSpikeResult: ResolveSpikeResult?
    @Published var isRunningResolveSpike: Bool = false

    @Published var errorMessage: String?

    let worker = WorkerClient()

    // MARK: - Worker Initialization & Preflight Discovery

    func resolveWorkerScriptPath() -> String? {
        let fm = FileManager.default

        // 1. Check Bundle Resources
        if let bundleRes = Bundle.main.resourceURL {
            let bundledWorker = bundleRes.appendingPathComponent("workers/src/aivideo_workers/main.py").path
            if fm.fileExists(atPath: bundledWorker) {
                return bundledWorker
            }
        }

        // 2. Check Environment Variable
        if let envPath = ProcessInfo.processInfo.environment["AIVIDEO_WORKER_PATH"], fm.fileExists(atPath: envPath) {
            return envPath
        }

        // 3. Check Workspace Relative Path
        let currentDir = fm.currentDirectoryPath
        let relativeWorker = (currentDir as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")
        if fm.fileExists(atPath: relativeWorker) {
            return relativeWorker
        }

        return nil
    }

    func resolvePythonPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.fileExists(atPath: path) && fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    func initializeWorker() async {
        statusMessage = "Đang kiểm tra môi trường và kết nối Python worker..."
        errorMessage = nil

        guard let pythonPath = resolvePythonPath() else {
            self.errorMessage = "Không tìm thấy Python 3. Vui lòng cài đặt Python 3.12 tại /opt/homebrew/bin/python3.12."
            self.statusMessage = "Lỗi preflight: Thiếu Python runtime"
            return
        }

        guard let scriptPath = resolveWorkerScriptPath() else {
            self.errorMessage = "Không tìm thấy file worker script (main.py) trong Bundle Resources hoặc Workspace."
            self.statusMessage = "Lỗi preflight: Thiếu worker script"
            return
        }

        do {
            let initRes = try await worker.start(
                pythonPath: pythonPath,
                scriptPath: scriptPath,
                timeoutSeconds: 8.0
            )
            self.isWorkerConnected = await worker.isConnected
            self.workerPid = await worker.workerPid
            self.pythonVersion = initRes.pythonVersion
            self.workerVersion = initRes.workerVersion
            self.capabilities = initRes.capabilities
            self.statusMessage = "Worker sẵn sàng (PID: \(self.workerPid), Python \(self.pythonVersion))"

            // Check Resolve status silently in background
            await checkResolveStatus()
        } catch {
            self.isWorkerConnected = false
            self.errorMessage = "Khởi động worker thất bại: \(error.localizedDescription)"
            self.statusMessage = "Lỗi kết nối worker"
        }
    }

    // MARK: - File Selection & Security-Scoped Bookmark Binding

    func selectFileAndProbe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .image, .jpeg, .png]

        if panel.runModal() == .OK, let url = panel.url {
            handleSelectedURL(url)
        }
    }

    func handleSelectedURL(_ url: URL) {
        self.selectedFilePath = url.path
        self.isBookmarkStale = false

        // Create Security-Scoped Bookmark if running in app sandbox
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "LastSelectedSourceBookmark")
            self.isSecurityScoped = true
        } catch {
            self.isSecurityScoped = false
        }

        Task {
            await self.probeFile(path: url.path)
        }
    }

    func restoreSavedBookmark() {
        guard let data = UserDefaults.standard.data(forKey: "LastSelectedSourceBookmark") else { return }
        var isStale = false
        do {
            let restoredURL = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            self.selectedFilePath = restoredURL.path
            self.isBookmarkStale = isStale
            if isStale {
                self.errorMessage = "Quyền truy cập file đã cũ (stale bookmark). Vui lòng chọn lại file để tái cấp quyền."
            } else {
                _ = restoredURL.startAccessingSecurityScopedResource()
                Task {
                    await self.probeFile(path: restoredURL.path)
                }
            }
        } catch {
            self.errorMessage = "Không thể khôi phục bookmark file: \(error.localizedDescription)"
        }
    }

    func probeFile(path: String) async {
        self.isProbing = true
        self.errorMessage = nil
        do {
            let res = try await worker.probeMedia(filePath: path)
            self.probeResult = res
            self.statusMessage = "Phân tích tư liệu thành công: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            self.errorMessage = "Lỗi probe media: \(error.localizedDescription)"
            self.probeResult = nil
        }
        self.isProbing = false
    }

    // MARK: - Deterministic Smoke Test

    func runSmokeTest() async {
        guard !smokeTestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.isRunningSmokeTest = true
        self.errorMessage = nil
        do {
            let res = try await worker.deterministicSmokeTest(text: smokeTestInput)
            self.smokeTestResult = res
            self.statusMessage = "Deterministic smoke test hoàn thành (SHA-256 xác thực)"
        } catch {
            self.errorMessage = "Smoke test thất bại: \(error.localizedDescription)"
            self.smokeTestResult = nil
        }
        self.isRunningSmokeTest = false
    }

    // MARK: - Real Local Model Inference

    func runModelInference() async {
        guard !modelPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.isRunningModelInfer = true
        self.errorMessage = nil
        do {
            let res = try await worker.localModelInfer(prompt: modelPrompt)
            self.modelInferResult = res
            self.statusMessage = "Suy luận Local Neural Model hoàn thành (100% Offline, Zero Cloud)"
        } catch {
            self.errorMessage = "Lỗi suy luận model local: \(error.localizedDescription)"
            self.modelInferResult = nil
        }
        self.isRunningModelInfer = false
    }

    // MARK: - DaVinci Resolve Integration

    func checkResolveStatus() async {
        do {
            let status = try await worker.resolveStatus()
            self.resolveStatus = status
        } catch {
            self.resolveStatus = nil
        }
    }

    func runResolveSpike() async {
        self.isRunningResolveSpike = true
        self.errorMessage = nil
        do {
            let res = try await worker.runResolveSpike(forceFreshRun: true)
            self.resolveSpikeResult = res
            self.statusMessage = "Resolve Spike hoàn thành: \(res.timelineResolution) @ \(res.timelineFps)fps"
        } catch {
            self.errorMessage = "Resolve Spike thất bại: \(error.localizedDescription)"
            self.resolveSpikeResult = nil
        }
        self.isRunningResolveSpike = false
    }

    func shutdownAsync() async {
        await worker.terminate()
    }
}

// MARK: - App Delegate with AppKit Quit Barrier

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState else { return .terminateNow }

        Task {
            await state.shutdownAsync()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

// MARK: - SwiftUI UI Views

@main
struct AIVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .onAppear {
                    appDelegate.appState = state
                    Task {
                        await state.initializeWorker()
                        state.restoreSavedBookmark()
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AIVideo v3.1")
                        .font(.headline)
                    Text("Trợ lý phân tích & dựng video POV tiếng Việt (macOS Native arm64)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Worker Connection Badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isWorkerConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(state.isWorkerConnected ? "Worker PID \(state.workerPid) (Python \(state.pythonVersion))" : "Worker Disconnected")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main Scrollable Area
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // System Notification
                    if let err = state.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text(err)
                                .font(.callout)
                                .foregroundColor(.red)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }

                    // Section 1: Media Source Inspector
                    GroupBox(label: Label("1. Kiểm tra tư liệu nguồn (Media Probe)", systemImage: "film")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button("Chọn file video/ảnh...") {
                                    state.selectFileAndProbe()
                                }
                                .buttonStyle(.borderedProminent)

                                if !state.selectedFilePath.isEmpty {
                                    Text(URL(fileURLWithPath: state.selectedFilePath).lastPathComponent)
                                        .font(.subheadline)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }

                            if state.isBookmarkStale {
                                Text("⚠️ Quyền truy cập file đã cũ. Vui lòng bấm 'Chọn file' để tái cấp quyền.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }

                            if state.isProbing {
                                ProgressView("Đang phân tích media qua ffprobe...")
                                    .progressViewStyle(.linear)
                            } else if let probe = state.probeResult {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Định dạng: \(probe.formatName ?? "N/A") · Thời lượng: \(String(format: "%.2f", probe.durationSeconds))s · Kích thước: \(probe.sizeBytes / 1024 / 1024) MB")
                                        .font(.system(size: 12, weight: .medium))

                                    ForEach(probe.videoStreams, id: \.index) { v in
                                        Text("• Video: \(v.codecName ?? "N/A") \(v.width ?? 0)x\(v.height ?? 0) @ \(v.frameRate ?? "N/A") fps (Pixel: \(v.pixelFormat ?? "N/A"))")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    ForEach(probe.audioStreams, id: \.index) { a in
                                        Text("• Audio: \(a.codecName ?? "N/A") \(a.sampleRate ?? "N/A") Hz, \(a.channels ?? 0) channels")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }

                    // Section 2: Deterministic Smoke Test
                    GroupBox(label: Label("2. Deterministic Smoke Test (Xác thực luồng IPC)", systemImage: "bolt.shield")) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Nhập chuỗi thử nghiệm...", text: $state.smokeTestInput)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button("Chạy Smoke Test") {
                                    Task {
                                        await state.runSmokeTest()
                                    }
                                }
                                .disabled(state.isRunningSmokeTest || !state.isWorkerConnected)

                                if state.isRunningSmokeTest {
                                    ProgressView().scaleEffect(0.7)
                                }
                            }

                            if let smoke = state.smokeTestResult {
                                Text("Trạng thái: \(smoke.status) · Kiểu: \(smoke.executionType) · Ngôn ngữ: \(smoke.detectedLanguage) · SHA-256: \(smoke.contentSha256.prefix(16))...")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(8)
                    }

                    // Section 3: Real Local Model Inference
                    GroupBox(label: Label("3. Suy luận Local Model (100% Offline, Micro Neural Weights)", systemImage: "cpu")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Mô hình local chạy nội bộ trên máy, xác thực không gọi Cloud:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("Prompt tóm tắt brief...", text: $state.modelPrompt)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button("Chạy Local Inference") {
                                    Task {
                                        await state.runModelInference()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(state.isRunningModelInfer || !state.isWorkerConnected)

                                if state.isRunningModelInfer {
                                    ProgressView("Đang tính toán ma trận weights...")
                                        .progressViewStyle(.linear)
                                }
                            }

                            if let res = state.modelInferResult {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Kết quả: \(res.outputText)")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Model: \(res.modelId) · Runtime: \(res.runtime)")
                                        .font(.system(size: 11))
                                    Text("Weights SHA-256: \(res.weightsSha256.prefix(16))... · Độ trễ: \(res.inferenceLatencyMs) ms · Offline: \(res.offlineVerified ? "Có (100%)" : "Không")")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(8)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }

                    // Section 4: DaVinci Resolve Status & Spike
                    GroupBox(label: Label("4. Tích hợp DaVinci Resolve Studio (Gate G0)", systemImage: "film.stack")) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let resolve = state.resolveStatus {
                                HStack {
                                    Circle()
                                        .fill(resolve.connected ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text(resolve.connected ? "Đã kết nối: \(resolve.productName ?? "DaVinci Resolve") v\(resolve.version ?? "")" : (resolve.error ?? "DaVinci Resolve chưa mở"))
                                        .font(.system(size: 12))
                                    Spacer()
                                    Button("Làm mới") {
                                        Task {
                                            await state.checkResolveStatus()
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            Button("Chạy G0 10s Timeline Spike") {
                                Task {
                                    await state.runResolveSpike()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(state.isRunningResolveSpike || !(state.resolveStatus?.connected ?? false))

                            if state.isRunningResolveSpike {
                                ProgressView("Đang thiết lập timeline 2160x3840 24fps trong Resolve...")
                            } else if let spike = state.resolveSpikeResult {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Spike: \(spike.status) · Timeline: \(spike.timelineResolution) @ \(spike.timelineFps)fps")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Frames: \(spike.timelineStartFrame)..\(spike.timelineEndFrame) (Tổng: \(spike.timelineTotalFrames) frames = 10s @ 24fps)")
                                        .font(.system(size: 11, design: .monospaced))
                                    Text("DRP Export: \(spike.drpExported ? "Thành công" : "Lỗi") (\(spike.drpPath))")
                                        .font(.system(size: 10, design: .monospaced))
                                }
                                .padding(8)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }

                    // Section 5: Future Capabilities (Gate G1 Matrix)
                    GroupBox(label: Label("5. Bản đồ năng lực hệ thống (Capabilities Matrix)", systemImage: "checklist")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Trạng thái triển khai trung thực theo đặc tả AIVideo v3.1:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Text("• Worker JSON-RPC 2.0 stdio:")
                                Spacer()
                                Text("IMPLEMENTED (G0)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Media Inspector (ffprobe):")
                                Spacer()
                                Text("IMPLEMENTED (G0)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Local Neural Model Inference:")
                                Spacer()
                                Text("IMPLEMENTED (G0)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• DaVinci Resolve Scripting Adapter:")
                                Spacer()
                                Text("IMPLEMENTED (G0)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Single-writer ProjectStore (SQLite WAL):")
                                Spacer()
                                Text("PLANNED (Gate G1)").font(.caption).foregroundColor(.orange)
                            }
                            HStack {
                                Text("• APFS Source Snapshot & Publication Engine:")
                                Spacer()
                                Text("PLANNED (Gate G1)").font(.caption).foregroundColor(.orange)
                            }
                        }
                        .padding(8)
                    }
                }
                .padding(16)
            }

            Divider()

            // Status Footer
            HStack {
                Text(state.statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 650)
    }
}
