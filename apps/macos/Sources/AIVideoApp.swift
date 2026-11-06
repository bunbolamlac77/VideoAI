//
// AIVideoApp.swift — Native macOS Application for AIVideo v3.1
//

import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var isWorkerConnected: Bool = false
    @Published var workerPid: Int32 = 0
    @Published var pythonVersion: String = ""
    @Published var statusMessage: String = "Khởi tạo hệ thống..."

    @Published var selectedFilePath: String = ""
    @Published var probeResult: MediaProbeResult?
    @Published var isProbing: Bool = false

    @Published var briefInput: String = "Hôm nay tôi chạy xe máy lên đèo Prenn Đà Lạt lúc 6 giờ sáng, trời se lạnh và sương mù dày."
    @Published var inferResult: LocalInferResult?
    @Published var isInferring: Bool = false

    @Published var errorMessage: String?

    let worker = WorkerClient()

    func initializeWorker() async {
        statusMessage = "Đang kết nối Python worker..."
        let currentDir = FileManager.default.currentDirectoryPath
        let workerScript = (currentDir as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")

        do {
            try await worker.start(
                pythonPath: "/opt/homebrew/bin/python3.12",
                scriptPath: workerScript
            )
            self.isWorkerConnected = await worker.isConnected
            self.workerPid = await worker.workerPid
            self.pythonVersion = await worker.pythonVersion
            self.statusMessage = "Worker sẵn sàng (PID: \(self.workerPid))"
        } catch {
            self.isWorkerConnected = false
            self.errorMessage = "Không thể khởi động worker: \(error.localizedDescription)"
            self.statusMessage = "Lỗi kết nối worker"
        }
    }

    func selectFileAndProbe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .image, .jpeg, .png]

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            self.selectedFilePath = path
            Task {
                await self.probeFile(path: path)
            }
        }
    }

    func probeFile(path: String) async {
        self.isProbing = true
        self.errorMessage = nil
        do {
            let res = try await worker.probeMedia(filePath: path)
            self.probeResult = res
            self.statusMessage = "Phân tích file thành công: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            self.errorMessage = "Lỗi probe media: \(error.localizedDescription)"
            self.probeResult = nil
        }
        self.isProbing = false
    }

    func runLocalInference() async {
        guard !briefInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.isInferring = true
        self.errorMessage = nil
        do {
            let res = try await worker.localInferTest(text: briefInput)
            self.inferResult = res
            self.statusMessage = "Suy luận local hoàn tất (100% Offline, Zero Cloud)"
        } catch {
            self.errorMessage = "Lỗi suy luận: \(error.localizedDescription)"
            self.inferResult = nil
        }
        self.isInferring = false
    }

    func shutdown() {
        Task {
            await worker.terminate()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }
}

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
                    Text("Trợ lý phân tích & dựng video POV tiếng Việt (macOS Native)")
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

            // Main Content Area
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

                            if state.isProbing {
                                ProgressView("Đang phân tích qua ffprobe...")
                                    .padding(.vertical, 6)
                            } else if let probe = state.probeResult {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Định dạng: \(probe.formatName ?? "N/A") · Thời lượng: \(String(format: "%.2f", probe.durationSeconds))s · Kích thước: \(probe.sizeBytes / 1024 / 1024) MB")
                                        .font(.system(size: 12, weight: .semibold))

                                    if let video = probe.videoStreams.first {
                                        Text("Video: Codec \(video.codecName ?? "N/A"), \(video.width ?? 0)x\(video.height ?? 0), \(video.frameRate ?? "N/A") fps, Pixel format: \(video.pixelFormat ?? "N/A")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    if let audio = probe.audioStreams.first {
                                        Text("Audio: Codec \(audio.codecName ?? "N/A"), \(audio.sampleRate ?? "N/A") Hz, \(audio.channels ?? 0) kênh")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }

                    // Section 2: Local AI Inference Spike
                    GroupBox(label: Label("2. Kiểm tra suy luận Local AI (100% Offline)", systemImage: "cpu")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Dữ kiện ngày làm việc (Brief tiếng Việt):")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextEditor(text: $state.briefInput)
                                .frame(height: 60)
                                .font(.body)
                                .padding(4)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))

                            HStack {
                                Button("Chạy suy luận Local (Zero Cloud)") {
                                    Task {
                                        await state.runLocalInference()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(state.isInferring || !state.isWorkerConnected)

                                if state.isInferring {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                                Spacer()
                            }

                            if let infer = state.inferResult {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "checkmark.shield.fill")
                                            .foregroundColor(.green)
                                        Text("Chế độ: \(infer.mode) — Tuyệt đối không gọi Cloud AI")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.green)
                                    }
                                    Text("Số ký tự: \(infer.inputLength) · Số token: \(infer.tokenCount) · Số claims dự thảo: \(infer.summaryClaimsCount)")
                                        .font(.caption)
                                    Text("SHA-256: \(infer.contentSha256)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }

                    // Section 3: Hardware & Safety Guarantees
                    GroupBox(label: Label("3. Cam kết kiến trúc & Môi trường", systemImage: "lock.shield")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Nền tảng: Apple Silicon M1 Pro, 16 GB Unified Memory (APFS local)")
                            Text("• Quyền ghi chuẩn: Độc quyền qua Swift Core ProjectStore actor (SQLite WAL)")
                            Text("• Python Worker: Tiến trình con độc lập qua JSON-RPC stdio, tự thu hồi khi tắt ứng dụng")
                            Text("• DaVinci Resolve: Tích hợp scripting API nội bộ, operation journal chống lặp lệnh")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer Status
            HStack {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("AIVideo v3.1 Gate G0 Spike")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
