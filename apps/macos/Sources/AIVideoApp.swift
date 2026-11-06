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
    private var currentlyAccessedSecurityScopedURL: URL? = nil

    func stopAccessingCurrentSecurityScopedResource() {
        if let url = currentlyAccessedSecurityScopedURL {
            url.stopAccessingSecurityScopedResource()
            currentlyAccessedSecurityScopedURL = nil
        }
    }

    // Local Neural Model Status & Inference (Gate G0)
    @Published var modelStatus: ModelStatusResult?
    @Published var modelPrompt: String = "Tóm tắt brief cảnh quay xe máy đèo Prenn buổi sáng sớm."
    @Published var lastRunPrompt: String?
    @Published var modelInferResult: LocalInferResult?
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

        // 1. Check Bundle Resources (Workers/aivideo_workers/main.py or workers/src/aivideo_workers/main.py)
        if let bundleRes = Bundle.main.resourceURL {
            let bundledWorker1 = bundleRes.appendingPathComponent("Workers/aivideo_workers/main.py").path
            if fm.fileExists(atPath: bundledWorker1) {
                return bundledWorker1
            }
            let bundledWorker2 = bundleRes.appendingPathComponent("workers/src/aivideo_workers/main.py").path
            if fm.fileExists(atPath: bundledWorker2) {
                return bundledWorker2
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
        let fm = FileManager.default

        // 1. Check installation registry in Application Support
        if let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let regFile = appSupportURL.appendingPathComponent("AIVideo/Installations/g0-text-smoke-v1.json")
            if let data = try? Data(contentsOf: regFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pyPath = json["python_path"] as? String,
               fm.fileExists(atPath: pyPath) && fm.isExecutableFile(atPath: pyPath) {
                return pyPath
            }

            // 2. Check dedicated Application Support runtime
            let dedicatedRuntime = appSupportURL.appendingPathComponent("AIVideo/Runtimes/g0-mlx-runtime/bin/python3").path
            if fm.fileExists(atPath: dedicatedRuntime) && fm.isExecutableFile(atPath: dedicatedRuntime) {
                return dedicatedRuntime
            }
        }

        // 3. Check repo virtualenv
        let currentDir = fm.currentDirectoryPath
        let localVenvPy = (currentDir as NSString).appendingPathComponent("workers/.venv/bin/python3")
        if fm.fileExists(atPath: localVenvPy) && fm.isExecutableFile(atPath: localVenvPy) {
            return localVenvPy
        }

        // 4. Fallback system/homebrew candidates
        let candidates = [
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
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
            self.errorMessage = "Không tìm thấy Python runtime hợp lệ. Vui lòng chạy setup: tools/setup_g0_model.py --install."
            self.statusMessage = "Lỗi preflight: Thiếu Python runtime"
            return
        }

        guard let scriptPath = resolveWorkerScriptPath() else {
            self.errorMessage = "Không tìm thấy worker script trong Bundle Resources hoặc Workspace."
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

            // Check model status
            await refreshModelStatus()

            // Check Resolve status silently in background
            await checkResolveStatus()
        } catch {
            self.isWorkerConnected = false
            self.errorMessage = "Khởi động worker thất bại: \(error.localizedDescription)"
            self.statusMessage = "Lỗi kết nối worker"
        }
    }

    func refreshModelStatus() async {
        guard isWorkerConnected else { return }
        do {
            let res = try await worker.modelStatus()
            self.modelStatus = res
            switch res.status {
            case .notConfigured, .notInstalled:
                self.statusMessage = "Chưa cài model kiểm thử"
            case .invalidAssets:
                self.statusMessage = "Model thiếu hoặc hỏng file"
            case .runtimeUnavailable:
                self.statusMessage = "Runtime chưa sẵn sàng"
            case .availableUnloaded:
                self.statusMessage = "Đã kiểm tra file — chưa chạy suy luận"
            }
        } catch {
            self.errorMessage = "Kiểm tra model status thất bại: \(error.localizedDescription)"
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
        stopAccessingCurrentSecurityScopedResource()
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
        stopAccessingCurrentSecurityScopedResource()
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
                let success = restoredURL.startAccessingSecurityScopedResource()
                if success {
                    self.currentlyAccessedSecurityScopedURL = restoredURL
                    Task {
                        await self.probeFile(path: restoredURL.path)
                    }
                } else {
                    self.errorMessage = "Không thể cấp quyền truy cập security-scoped cho file đã lưu."
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

    // MARK: - Real Local Model Inference (G0 Text Smoke)

    func runModelInference() async {
        let promptSnapshot = modelPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptSnapshot.isEmpty else { return }
        self.isRunningModelInfer = true
        self.errorMessage = nil
        defer { self.isRunningModelInfer = false }

        do {
            let res = try await worker.localInferTest(prompt: promptSnapshot)
            self.modelInferResult = res
            self.lastRunPrompt = promptSnapshot
            self.statusMessage = "Đã nhận kết quả từ model local (\(res.outputTokenCount) tokens, finish: \(res.finishReason))"
        } catch {
            self.errorMessage = "Lỗi suy luận model local: \(error.localizedDescription)"
            self.modelInferResult = nil
        }
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

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            let url = URL(fileURLWithPath: first)
            appState?.handleSelectedURL(url)
        }
    }

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
                .onOpenURL { url in
                    state.handleSelectedURL(url)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var statusColor: Color {
        if state.isRunningModelInfer {
            return .blue
        }
        if state.modelInferResult != nil {
            return .green
        }
        guard let status = state.modelStatus else {
            return .gray
        }
        switch status.status {
        case .availableUnloaded:
            return .purple
        case .invalidAssets, .runtimeUnavailable:
            return .red
        case .notConfigured, .notInstalled:
            return .orange
        }
    }

    var statusLabel: String {
        if state.isRunningModelInfer {
            return "Đang chạy model"
        }
        if state.modelInferResult != nil {
            return "Đã nhận kết quả từ model local"
        }
        guard let status = state.modelStatus else {
            return "Chưa cài model kiểm thử"
        }
        switch status.status {
        case .availableUnloaded:
            return "Đã kiểm tra file — chưa chạy suy luận"
        case .invalidAssets:
            return "Model thiếu hoặc hỏng file"
        case .runtimeUnavailable:
            return "Runtime chưa sẵn sàng"
        case .notConfigured, .notInstalled:
            return "Chưa cài model kiểm thử"
        }
    }

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

                    // Section 2: Kiểm tra model local (Gate G0 Text Smoke)
                    GroupBox(label: Label("Kiểm tra Worker Model Fixture (G0 Smoke Test Only)", systemImage: "cpu")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Lưu ý: Model sản phẩm (Qwen-VL, Whisper, VieNeu-TTS, DINOv2) chưa được tải (NOT_INSTALLED). Profile này chỉ dùng làm fixture kiểm tra IPC và Apple Metal.")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            // Status Banner
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 10, height: 10)
                                Text(statusLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Button("Kiểm tra lại model") {
                                    Task {
                                        await state.refreshModelStatus()
                                    }
                                }
                                .disabled(!state.isWorkerConnected || state.isRunningModelInfer)
                            }
                            .padding(8)
                            .background(statusColor.opacity(0.1))
                            .cornerRadius(6)

                            if let status = state.modelStatus, let details = status.details, !details.isEmpty {
                                Text(details)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            TextField("Prompt brief thử nghiệm...", text: $state.modelPrompt)
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button("Chạy kiểm thử model") {
                                    Task {
                                        await state.runModelInference()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!state.isWorkerConnected || state.modelStatus?.status != .availableUnloaded || state.isRunningModelInfer)

                                if state.isRunningModelInfer {
                                    ProgressView("Đang nạp và chạy model local...")
                                        .progressViewStyle(.linear)
                                }
                            }

                            // Model Inference Result
                            if let res = state.modelInferResult {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let promptUsed = state.lastRunPrompt {
                                        Text("Brief đã chạy: \"\(promptUsed)\"")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("Kết quả từ model:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(res.outputText)
                                        .font(.system(size: 12))
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(4)

                                    HStack(spacing: 12) {
                                        Text("Model: \(res.modelId) (\(res.profileId))")
                                        Text("Tokens: \(res.inputTokenCount) in / \(res.outputTokenCount) out")
                                        Text("Finish: \(res.finishReason)")
                                    }
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)

                                    if let loadMs = res.loadTimeMs, let genMs = res.generationTimeMs {
                                        Text("Nạp: \(String(format: "%.1f", loadMs)) ms · Sinh: \(String(format: "%.1f", genMs)) ms")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color.accentColor.opacity(0.08))
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }

                    // Section 3: DaVinci Resolve Status & Spike
                    GroupBox(label: Label("3. Tích hợp DaVinci Resolve Studio (Gate G0)", systemImage: "film.stack")) {
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
                                    Text("Spike: \(spike.success == true ? "Hoàn tất" : "Đạt") · Timeline: \(spike.timelineResolution) @ \(String(format: "%.1f", spike.timelineFps))fps")
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

                    // Gate G1 - Real canonical SQLite editor
                    ProjectStoreDemoHost()

                    // Section 4: Future Capabilities (Gate G1 Matrix)
                    GroupBox(label: Label("4. Bản đồ năng lực hệ thống (Capabilities Matrix)", systemImage: "checklist")) {
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
