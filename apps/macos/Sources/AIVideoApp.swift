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

// MARK: - SwiftUI UI Views

extension Color {
    /// Brand teal: #0F766E (light) / #5EEAD4 (dark), per 10-UI-UX-MACOS.md.
    static let brandTeal = Color(nsColor: NSColor(name: "AIVideoBrandTeal") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x5E / 255, green: 0xEA / 255, blue: 0xD4 / 255, alpha: 1)
            : NSColor(srgbRed: 0x0F / 255, green: 0x76 / 255, blue: 0x6E / 255, alpha: 1)
    })
}

@main

struct AIVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        // Single-window app: a WindowGroup would spawn duplicate windows
        // (each re-running bootstrap) on ⌘N or Dock reopen.
        Window("AIVideo", id: "main") {
            ContentView()
                .environmentObject(state)
                .tint(.brandTeal)
                .task {
                    appDelegate.appState = state
                    await state.bootstrap()
                }
                .onOpenURL { url in
                    state.handleSelectedURL(url)
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Mở thư mục tư liệu…") { state.selectSourceFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Mở file riêng lẻ…") { state.selectFileAndProbe() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Worker") {
                Button("Khởi động lại worker") {
                    Task { await state.restartWorker() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Kiểm tra lại model") {
                    Task { await state.refreshModelStatus() }
                }
                Button("Làm mới DaVinci Resolve") {
                    Task { await state.checkResolveStatus() }
                }
            }
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case media, story, preview, final, review, data, model, resolve, capabilities
    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: return "1. Tư liệu nguồn"
        case .story: return "2. Kịch bản & Thoại"
        case .preview: return "3. Xem trước (Preview)"
        case .final: return "4. Xuất bản Final 4K"
        case .review: return "Kiểm chứng G2"
        case .data: return "Dữ liệu & Backup"
        case .model: return "Model local"
        case .resolve: return "DaVinci Resolve"
        case .capabilities: return "Năng lực hệ thống"
        }
    }

    var subtitle: String {
        switch self {
        case .media: return "Quét AI nhận diện clip, ffprobe và quản lý tư liệu"
        case .story: return "Tạo câu chuyện POV, sinh giọng đọc Kokoro-Vietnamese & duyệt S19"
        case .preview: return "Khớp video dọc 1080×1920, raster phụ đề & kiểm tra QC"
        case .final: return "Render 2160×3840 24fps & mở timeline DaVinci Resolve Studio"
        case .review: return "Coverage, claim, review có truy vết nguồn"
        case .data: return "ProjectStore SQLite WAL, fact ACK, portable backup"
        case .model: return "Smoke test model offline trên Apple Silicon"
        case .resolve: return "Kết nối Resolve Studio, timeline spike 24 fps"
        case .capabilities: return "Năng lực worker công bố thực tế"
        }
    }

    var symbol: String {
        switch self {
        case .media: return "film.stack"
        case .story: return "text.book.closed"
        case .preview: return "play.rectangle"
        case .final: return "checkmark.seal"
        case .review: return "magnifyingglass.circle"
        case .data: return "externaldrive.badge.checkmark"
        case .model: return "cpu"
        case .resolve: return "film"
        case .capabilities: return "checklist"
        }
    }

    /// 1...4 for the workflow steps, nil for diagnostics screens.
    var stepNumber: Int? {
        switch self {
        case .media: return 1
        case .story: return 2
        case .preview: return 3
        case .final: return 4
        default: return nil
        }
    }

    /// The four steps a creator actually walks through, in order.
    static let workflowSteps: [AppSection] = [.media, .story, .preview, .final]
    /// Diagnostics/back-office screens: reachable but out of the daily path.
    static let advancedSections: [AppSection] = [.review, .data, .model, .resolve, .capabilities]
    var isAdvanced: Bool { Self.advancedSections.contains(self) }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @SceneStorage("selectedSection") private var selectionRaw: String = AppSection.media.rawValue
    /// Diagnostics stay collapsed until someone asks for them.
    @State private var showAdvanced = false

    private var currentSection: AppSection { AppSection(rawValue: selectionRaw) ?? .media }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 1080, minHeight: 700)
        .onAppear {
            showAdvanced = showAdvanced || currentSection.isAdvanced
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    sidebarCaption("Quy trình dựng")

                    ForEach(Array(AppSection.workflowSteps.enumerated()), id: \.element) { index, section in
                        SidebarRow(
                            section: section,
                            step: index + 1,
                            isSelected: currentSection == section,
                            badge: badge(for: section)
                        ) {
                            selectionRaw = section.rawValue
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { showAdvanced.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("NÂNG CAO & CHẨN ĐOÁN")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .tracking(1.1)
                            Spacer()
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        ForEach(AppSection.advancedSections) { section in
                            SidebarRow(
                                section: section,
                                step: nil,
                                isSelected: currentSection == section,
                                badge: badge(for: section)
                            ) {
                                selectionRaw = section.rawValue
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }

            Divider().opacity(0.5)
            WorkerStatusCard()
                .padding(12)
        }
        .background(.thinMaterial)
        .navigationSplitViewColumnWidth(min: 224, ideal: 248, max: 300)
    }

    private func sidebarCaption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    // MARK: Detail

    private var detail: some View {
        ZStack {
            AppCanvas()

            VStack(spacing: 0) {
                if let err = state.errorMessage {
                    ErrorBanner(message: err) { state.errorMessage = nil }
                        .padding(.horizontal, Theme.space24)
                        .padding(.top, Theme.space12)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space24) {
                        SectionHeader(section: currentSection)
                        detailView(for: currentSection)
                    }
                    .padding(.horizontal, Theme.space32)
                    .padding(.vertical, Theme.space24)
                    .frame(maxWidth: Theme.pageWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)

                StatusBar()
            }
        }
        .navigationTitle("AIVideo")
        .navigationSubtitle(state.g1Project?.name ?? "AIVideo v3.1")
        .onChange(of: state.requestedSection) { _, newSec in
            if let s = newSec {
                selectionRaw = s.rawValue
                if s.isAdvanced { showAdvanced = true }
                state.requestedSection = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.selectSourceFolder()
                } label: {
                    Label("Mở thư mục tư liệu", systemImage: "folder.badge.plus")
                }
                .help("Chọn thư mục chứa video và ảnh (⌘O)")

                if !state.selectedDirectoryPath.isEmpty {
                    Button {
                        state.refreshCurrentDirectory()
                    } label: {
                        Label("Quét lại", systemImage: "arrow.clockwise")
                    }
                    .help("Quét lại các file trong thư mục hiện tại")
                }

                if !state.isWorkerConnected {
                    Button {
                        Task { await state.restartWorker() }
                    } label: {
                        Label("Kết nối lại worker", systemImage: "bolt.horizontal.circle")
                    }
                    .help("Python worker chưa sẵn sàng — bấm để khởi động lại")
                    .disabled(state.isStartingWorker)
                }
            }
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .review: return state.g2ReviewItems.filter { $0.status != "resolved" }.count
        case .data: return state.g1Claims.filter { $0.reviewStatus != .confirmed }.count
        default: return 0
        }
    }

    @ViewBuilder
    private func detailView(for section: AppSection) -> some View {
        switch section {
        case .media: MediaSectionView()
        case .model: ModelSectionView()
        case .resolve: ResolveSectionView()
        case .data: DataSectionView()
        case .review: G2ReviewSectionView(state: state)
        case .story: G3ConsoleView(state: state)
        case .preview: G4ConsoleView(state: state)
        case .final: G5ConsoleView(state: state)
        case .capabilities: CapabilitiesSectionView()
        }
    }
}

/// Sidebar row: numbered tile for workflow steps, icon tile for diagnostics.
struct SidebarRow: View {
    let section: AppSection
    let step: Int?
    let isSelected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.brandTeal : Color.primary.opacity(0.07))
                    if let step {
                        Text("\(step)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? Color.black.opacity(0.78) : Color.secondary)
                    } else {
                        Image(systemName: section.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.black.opacity(0.78) : Color.secondary)
                    }
                }
                .frame(width: 24, height: 24)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.85))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.brandTeal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.brandTeal.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.brandTeal.opacity(0.14) : Color.clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.brandTeal)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reusable Chrome

struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space12) {
            if let title {
                HStack(spacing: 8) {
                    Image(systemName: symbol ?? "square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brandTeal)
                        .frame(width: 22, height: 22)
                        .background(Color.brandTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.7), radius: 3)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22)))
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct SectionHeader: View {
    let section: AppSection
    var body: some View {
        HStack(alignment: .center, spacing: Theme.space16) {
            VStack(alignment: .leading, spacing: 6) {
                if let step = section.stepNumber {
                    StepChip(text: "Bước \(step) / 4")
                }
                Text(section.title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(section.subtitle)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.brandTeal.opacity(0.12))
                Image(systemName: section.symbol)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.brandTeal)
            }
            .frame(width: 58, height: 58)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.brandTeal.opacity(0.18))
            )
        }
        .padding(.bottom, 2)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Đóng thông báo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25))
        )
    }
}

struct WorkerStatusCard: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if state.isStartingWorker {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(state.isWorkerConnected ? Color.green : Color.red).frame(width: 8, height: 8)
                }
                Text(state.isStartingWorker ? "Đang khởi động…" : (state.isWorkerConnected ? "Worker sẵn sàng" : "Worker ngắt kết nối"))
                    .font(.caption.weight(.semibold))
            }
            if state.isWorkerConnected {
                Text("PID \(state.workerPid) · Python \(state.pythonVersion)")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 12) {
            Text(state.statusMessage).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("100% local · 24 fps · 9:16").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.space24)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }
}

// MARK: - Sections

struct LocalImagePreview: View {
    let path: String
    @State private var image: NSImage?
    @State private var isLoading: Bool = false

    var body: some View {
        Group {
            if let image = image {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1))
                        )
                    HStack {
                        Text("\(Int(image.size.width)) × \(Int(image.size.height)) pt")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Đang nạp ảnh...")
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 30)
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Không thể mở bản xem trước")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        }
        .task(id: path) {
            isLoading = true
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: path)
            }.value
            self.image = loaded
            self.isLoading = false
        }
    }
}

struct MediaRowView: View {
    let item: MediaSourceItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(item.kind == .video ? Color.brandTeal.opacity(0.15) : Color.indigo.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(item.kind == .video ? Color.brandTeal : Color.indigo)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(item.formattedSize)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let date = item.modifiedDate {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                if isSelected {
                    Text("Đang xem")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.brandTeal.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.brandTeal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.brandTeal.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.brandTeal.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Mở bằng ứng dụng mặc định") {
                NSWorkspace.shared.open(item.url)
            }
            Button("Hiện trong Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button("Sao chép đường dẫn") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.id, forType: .string)
            }
        }
    }
}

struct MediaInspectorView: View {
    @EnvironmentObject var state: AppState
    let item: MediaSourceItem

    var body: some View {
        Card(title: item.kind == .video ? "Thông số kỹ thuật video" : "Thông tin ảnh tư liệu",
             symbol: item.kind.symbol) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(item.id)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(item.url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Mở file bằng ứng dụng mặc định")
                }

                Divider()

                if item.kind == .video {
                    videoInspectorContent
                } else {
                    imageInspectorContent
                }
            }
        }
    }

    @ViewBuilder
    private var videoInspectorContent: some View {
        if state.isProbing {
            VStack(spacing: 10) {
                ProgressView("Đang phân tích media qua ffprobe…")
                    .progressViewStyle(.linear)
            }
            .padding(.vertical, 16)
        } else if let probe = state.probeResult, probe.filePath == item.id {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusPill(text: String(format: "%.1f s", probe.durationSeconds), color: .brandTeal)
                    StatusPill(text: (probe.formatName ?? "video").uppercased(), color: .secondary)
                    StatusPill(
                        text: ByteCountFormatter.string(fromByteCount: Int64(probe.sizeBytes), countStyle: .file),
                        color: .secondary
                    )
                }

                DisclosureGroup("Thông số kỹ thuật (ffprobe)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(probe.videoStreams, id: \.index) { v in
                            let w = v.width.map { "\($0)" } ?? "0"
                            let h = v.height.map { "\($0)" } ?? "0"
                            let idx = v.index.map { "\($0)" } ?? "0"
                            let fps = v.frameRate ?? "Unknown"
                            KeyValueRow(key: "Video #\(idx)", value: "\(v.codecName ?? "Unknown") · \(w)×\(h) @ \(fps) fps · \(v.pixelFormat ?? "Unknown")")
                        }

                        ForEach(probe.audioStreams, id: \.index) { a in
                            let idx = a.index.map { "\($0)" } ?? "0"
                            let sr = a.sampleRate.map { "\($0) Hz" } ?? "N/A"
                            let ch = a.channels.map { "\($0) kênh" } ?? "N/A"
                            KeyValueRow(key: "Audio #\(idx)", value: "\(a.codecName ?? "Unknown") · \(sr) · \(ch)")
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    if state.isBatchAnalysisRunning {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Đang phân tích hàng đợi (\(state.batchCurrentIndex)/\(state.batchTotalCount))")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("Dừng", role: .destructive) {
                                    state.cancelBatchAnalysis()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            ProgressView(value: Double(state.batchCompletedCount), total: Double(max(1, state.batchTotalCount)))
                                .progressViewStyle(.linear)

                            Text("Hiện tại: \(state.batchCurrentFilename)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(10)
                        .background(Color.brandTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else if state.isRunningG2Analysis {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Đang phân tích G2 (Qwen3-VL 4B local)…")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                    } else {
                        Button {
                            Task { await state.runG2AnalysisOnSelectedSource() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles.tv")
                                Text("Phân tích video này")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!state.isWorkerConnected || state.isRunningG2Analysis || state.isBatchAnalysisRunning)

                        Text("Phân tích offline bằng Qwen3-VL 4B để tạo fact có bằng chứng. Brief ở trên được ghi kèm làm ngữ cảnh.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !state.mediaItems.isEmpty {
                            Button {
                                state.navigateToSection(.story)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Sang Bước 2 — Kịch bản & Thoại")
                                    Image(systemName: "arrow.right")
                                }
                                .font(.callout.weight(.medium))
                            }
                            .buttonStyle(.link)
                            .padding(.top, 2)
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                Text("Chưa có thông số probe cho video này")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Phân tích video ngay") {
                    Task { await state.probeFile(path: item.id) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private var imageInspectorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalImagePreview(path: item.id)

            KeyValueRow(key: "Định dạng", value: item.url.pathExtension.uppercased())
            KeyValueRow(key: "Dung lượng", value: item.formattedSize)
            if let date = item.modifiedDate {
                KeyValueRow(key: "Ngày sửa", value: date.formatted(date: .numeric, time: .standard))
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(Color.brandTeal)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ảnh tư liệu đính kèm")
                        .font(.subheadline.weight(.semibold))
                    Text("Ảnh tĩnh được lưu giữ cùng thư mục phục vụ tham chiếu bối cảnh, đạo cụ hoặc địa điểm cho kịch bản POV (G3).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.brandTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct MediaSectionView: View {
    @EnvironmentObject var state: AppState
    @State private var isDropTargeted = false
    @State private var searchText = ""

    var displayedItems: [MediaSourceItem] {
        let base = state.filteredMediaItems
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return base
        }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var selectedItem: MediaSourceItem? {
        state.mediaItems.first(where: { $0.id == state.selectedFilePath })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            folderBannerCard

            ScriptBriefCard()

            if state.isBookmarkStale {
                Label("Quyền truy cập thư mục/file đã cũ. Vui lòng chọn lại thư mục để tái cấp quyền.", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if state.mediaItems.isEmpty {
                emptyMediaPlaceholder
            } else {
                mediaBrowserAndInspector
            }
        }
    }

    private var folderBannerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.brandTeal.opacity(0.12))
                            .frame(width: 50, height: 50)
                        Image(systemName: state.mediaItems.isEmpty ? "folder.badge.plus" : "folder.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color.brandTeal)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(folderTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if !state.selectedDirectoryPath.isEmpty {
                            Text(state.selectedDirectoryPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        } else {
                            Text("Chưa chọn thư mục tư liệu nguồn (hỗ trợ nhiều video và ảnh đính kèm)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            state.selectSourceFolder()
                        } label: {
                            Label("Chọn thư mục…", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .help("Chọn toàn bộ thư mục chứa video và ảnh (⌘O)")

                        Button {
                            state.selectFileAndProbe()
                        } label: {
                            Label("Chọn file…", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help("Chọn file video hoặc ảnh đơn lẻ (⇧⌘O)")

                        if !state.selectedDirectoryPath.isEmpty {
                            Button {
                                state.refreshCurrentDirectory()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .help("Quét lại thư mục")

                            Button {
                                let dirURL = URL(fileURLWithPath: state.selectedDirectoryPath)
                                if !NSWorkspace.shared.open(dirURL) {
                                    NSWorkspace.shared.activateFileViewerSelecting([dirURL])
                                }
                            } label: {
                                Image(systemName: "macwindow")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .help("Mở thư mục trong Finder")
                        }
                    }
                }

                DisclosureGroup("Tuỳ chọn nâng cao") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $state.prefilterEnabled) {
                            Text("Bỏ qua cảnh tĩnh (prefilter chuyển động)")
                                .font(.caption.weight(.medium))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Text("Chỉ gửi các cửa sổ có chuyển động vào Qwen3-VL. Cửa sổ bị bỏ được ghi rõ trong coverage và không tính là đã phân tích. Mặc định tắt.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if state.isSecurityScoped {
                            Label("Security-Scoped Sandbox đang bật", systemImage: "lock.shield.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                if !state.mediaItems.isEmpty {
                    Divider()
                    HStack(spacing: 10) {
                        StatusPill(text: "\(state.videoCount) video", color: .brandTeal)
                        StatusPill(text: "\(state.imageCount) ảnh đính kèm", color: state.imageCount > 0 ? .indigo : .secondary)
                        StatusPill(text: "Tổng: \(ByteCountFormatter.string(fromByteCount: state.totalFolderBytes, countStyle: .file))", color: .secondary)
                        Spacer()

                        if state.videoCount > 0 {
                            if state.isBatchAnalysisRunning {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Đang phân tích \(state.batchCurrentIndex)/\(state.batchTotalCount): \(state.batchCurrentFilename)")
                                        .font(.caption.monospacedDigit())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 240)
                                    Button("Dừng", role: .destructive) {
                                        state.cancelBatchAnalysis()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.brandTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            } else {
                                Button {
                                    Task { await state.runG2AnalysisOnAllVideos() }
                                } label: {
                                    Label("Phân tích toàn bộ (\(state.videoCount) video)", systemImage: "sparkles.tv")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(state.isRunningG2Analysis || !state.isWorkerConnected)
                                .help("Phân tích tuần tự toàn bộ video trong thư mục bằng Qwen3-VL 4B local")
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.brandTeal : Color.secondary.opacity(0.2),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [6, 3] : [])
                    )
            )
            .dropDestination(for: URL.self) { urls, _ in
                let validURLs = urls.filter { $0.isFileURL }
                guard !validURLs.isEmpty else { return false }
                if validURLs.count == 1 {
                    state.handleSelectedURL(validURLs[0])
                } else {
                    state.handleSelectedURLs(validURLs)
                }
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
    }

    private var folderTitle: String {
        if !state.selectedDirectoryPath.isEmpty {
            return URL(fileURLWithPath: state.selectedDirectoryPath).lastPathComponent
        }
        return "Thư mục tư liệu nguồn"
    }

    private var emptyMediaPlaceholder: some View {
        Card {
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 42, weight: .thin))
                    .foregroundStyle(Color.brandTeal.opacity(0.7))
                VStack(spacing: 6) {
                    Text("Kéo thả thư mục hoặc file tư liệu vào đây")
                        .font(.headline)
                    Text("Hệ thống sẽ tự động quét toàn bộ video (.mp4, .mov, .m4v, .mkv, .avi, .webm) và ảnh đính kèm (.jpg, .png, .heic, .webp...)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                HStack(spacing: 6) {
                    Text("Kéo thả vào thẻ phía trên, hoặc bấm")
                        .foregroundStyle(.secondary)
                    Text("Mở thư mục tư liệu").fontWeight(.semibold)
                    Text("ở góc trên phải.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        }
    }

    private var mediaBrowserAndInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Lọc", selection: $state.mediaFilter) {
                    ForEach(MediaFilter.allCases) { filter in
                        Text(filterLabel(for: filter)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Tìm theo tên file…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: 240)
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "Danh sách tư liệu (\(displayedItems.count))", symbol: "folder.fill") {
                    if displayedItems.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("Không tìm thấy file phù hợp")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(displayedItems) { item in
                                    MediaRowView(
                                        item: item,
                                        isSelected: item.id == state.selectedFilePath,
                                        onSelect: {
                                            state.selectItemForInspection(item)
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(minHeight: 280, maxHeight: 420)
                    }
                }
                .frame(minWidth: 320, maxWidth: 440)

                if let item = selectedItem {
                    MediaInspectorView(item: item)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    Card(title: "Chi tiết tư liệu", symbol: "info.circle") {
                        VStack(spacing: 12) {
                            Image(systemName: "hand.tap")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Chọn một video hoặc ảnh trong danh sách để xem thông số chi tiết")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func filterLabel(for filter: MediaFilter) -> String {
        switch filter {
        case .all: return "Tất cả (\(state.mediaItems.count))"
        case .videos: return "Video (\(state.videoCount))"
        case .images: return "Ảnh (\(state.imageCount))"
        }
    }
}

struct ModelSectionView: View {
    @EnvironmentObject var state: AppState

    private var statusColor: Color {
        if state.isRunningModelInfer { return .blue }
        if state.modelInferResult != nil { return .green }
        guard let status = state.modelStatus else { return .gray }
        switch status.status {
        case .availableUnloaded: return .brandTeal
        case .invalidAssets, .runtimeUnavailable: return .red
        case .notConfigured, .notInstalled: return .orange
        }
    }

    private var statusLabel: String {
        if state.isRunningModelInfer { return "Đang chạy model" }
        if state.modelInferResult != nil { return "Đã nhận kết quả từ model local" }
        guard let status = state.modelStatus else {
            return state.isWorkerConnected ? "Đang kiểm tra model…" : "Chưa kết nối worker"
        }
        switch status.status {
        case .availableUnloaded: return "Đã kiểm tra file — chưa chạy suy luận"
        case .invalidAssets: return "Model thiếu hoặc hỏng file"
        case .runtimeUnavailable: return "Runtime chưa sẵn sàng"
        case .notConfigured, .notInstalled: return "Chưa cài model kiểm thử"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Trạng thái", symbol: "gauge.with.dots.needle.33percent") {
                HStack {
                    StatusPill(text: statusLabel, color: statusColor)
                    Spacer()
                    Button("Kiểm tra lại") { Task { await state.refreshModelStatus() } }
                        .disabled(!state.isWorkerConnected || state.isRunningModelInfer)
                }
                if let details = state.modelStatus?.details, !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Profile G0 chỉ là fixture kiểm tra IPC và Apple Metal; không thay thế model sản phẩm.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Card(title: "Chạy thử", symbol: "play.circle") {
                TextField("Prompt brief thử nghiệm…", text: $state.modelPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                HStack {
                    Button("Chạy kiểm thử model") { Task { await state.runModelInference() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!state.isWorkerConnected || state.modelStatus?.status != .availableUnloaded || state.isRunningModelInfer)
                    if state.isRunningModelInfer {
                        ProgressView().controlSize(.small)
                        Text("Đang nạp và chạy model local…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let res = state.modelInferResult {
                Card(title: "Kết quả", symbol: "text.bubble") {
                    if let promptUsed = state.lastRunPrompt {
                        Text("Brief: “\(promptUsed)”").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(res.outputText)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    KeyValueRow(key: "Model", value: "\(res.modelId) (\(res.profileId))")
                    KeyValueRow(key: "Tokens", value: "\(res.inputTokenCount) vào / \(res.outputTokenCount) ra · \(res.finishReason)")
                    if let loadMs = res.loadTimeMs, let genMs = res.generationTimeMs {
                        KeyValueRow(key: "Thời gian", value: String(format: "Nạp %.0f ms · Sinh %.0f ms", loadMs, genMs))
                    }
                }
            }
        }
    }
}

struct ResolveSectionView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Kết nối", symbol: "link") {
                HStack {
                    if let resolve = state.resolveStatus {
                        StatusPill(
                            text: resolve.connected ? "\(resolve.productName ?? "DaVinci Resolve") \(resolve.version ?? "")" : (resolve.error ?? "DaVinci Resolve chưa mở"),
                            color: resolve.connected ? .green : .orange
                        )
                    } else {
                        StatusPill(text: "Chưa kiểm tra", color: .gray)
                    }
                    Spacer()
                    Button("Làm mới") { Task { await state.checkResolveStatus() } }
                        .disabled(!state.isWorkerConnected)
                }
            }
            Card(title: "G0 Timeline Spike (10 s @ 24 fps)", symbol: "timeline.selection") {
                Button("Chạy spike") { Task { await state.runResolveSpike() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isRunningResolveSpike || !(state.resolveStatus?.connected ?? false))
                if state.isRunningResolveSpike {
                    ProgressView("Đang thiết lập timeline 2160×3840 24 fps trong Resolve…").progressViewStyle(.linear)
                } else if let spike = state.resolveSpikeResult {
                    StatusPill(text: spike.success == true ? "Hoàn tất" : "Thất bại", color: spike.success == true ? .green : .red)
                    KeyValueRow(key: "Timeline", value: "\(spike.timelineResolution) @ \(String(format: "%.0f", spike.timelineFps)) fps")
                    KeyValueRow(key: "Frames", value: "\(spike.timelineStartFrame)…\(spike.timelineEndFrame) (\(spike.timelineTotalFrames))")
                    KeyValueRow(key: "DRP", value: spike.drpExported ? spike.drpPath : "Xuất lỗi")
                }
            }
        }
    }
}

struct DataSectionView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Dự án", symbol: "folder") {
                KeyValueRow(key: "Tên", value: state.g1Project?.name ?? "Đang mở…")
                KeyValueRow(key: "Revision", value: state.g1Project.map { "\($0.currentRevision)" } ?? "—")
                HStack {
                    Text("Trạng thái lưu").foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                    StatusPill(
                        text: state.g1SaveStatus,
                        color: state.g1SaveStatus.hasPrefix("Lưu lỗi") ? .red : (state.g1SaveStatus.hasPrefix("Đang lưu") ? .blue : .green)
                    )
                }.font(.callout)
                if !state.g1ReconciliationSummary.isEmpty {
                    KeyValueRow(key: "Reconciler S08", value: state.g1ReconciliationSummary)
                }
            }

            Card(title: "Ghi chú / Fact", symbol: "square.and.pencil") {
                HStack {
                    TextField("Nhập fact bổ sung cho ngày làm việc…", text: $state.g1DraftFactText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await state.saveDraftFactToStore() } }
                    Button("Lưu (ACK)") { Task { await state.saveDraftFactToStore() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.projectStore == nil || state.g1DraftFactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if state.g1Claims.isEmpty {
                    Text("Chưa có claim nào.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.g1Claims) { c in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.text).font(.callout)
                                    Text("\(c.origin.rawValue) · \(c.epistemicStatus.rawValue)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusPill(text: c.reviewStatus.rawValue.uppercased(), color: c.reviewStatus == .confirmed ? .green : .orange)
                                if c.reviewStatus != .confirmed {
                                    Button("Xác nhận") { Task { await state.confirmFactInStore(claimId: c.claimId) } }
                                        .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 8)
                            if c.id != state.g1Claims.last?.id { Divider() }
                        }
                    }
                }
            }

            Card(title: "Backup", symbol: "externaldrive") {
                HStack {
                    Button("Tạo Portable Backup (S09)") { Task { await state.createPortableBackupFromUI() } }
                        .disabled(state.projectStore == nil)
                    if !state.g1LastBackupInfo.isEmpty {
                        Text(state.g1LastBackupInfo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct CapabilitiesSectionView: View {
    @EnvironmentObject var state: AppState

    private static let groups: [(String, String)] = [
        ("G0 · Hệ thống & media probe", "media."),
        ("G0 · Model local", "ai."),
        ("G0 · DaVinci Resolve", "resolve."),
        ("G2 · Phân tích full-frame & review", "g2."),
        ("G3 · Kịch bản, TTS trial, SEARCH-v1, duyệt", "g3."),
        ("G4 · Preview 1080×1920 & QC", "g4."),
        ("G5 · Final 4K, handoff & release audit", "g5."),
    ]

    var body: some View {
        Card(title: "Năng lực worker công bố (initialize)", symbol: "checklist") {
            if state.capabilities.isEmpty {
                Text(state.isWorkerConnected ? "Worker không công bố năng lực nào." : "Chưa kết nối worker — không thể xác minh năng lực.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Self.groups, id: \.1) { title, prefix in
                let caps = state.capabilities.filter { $0.hasPrefix(prefix) }
                HStack {
                    Text(title)
                    Spacer()
                    StatusPill(text: caps.isEmpty ? "KHÔNG CÓ" : "\(caps.count) RPC", color: caps.isEmpty ? .gray : .green)
                }
                .font(.callout)
            }
            if !state.capabilities.isEmpty {
                DisclosureGroup("Chi tiết (\(state.capabilities.count))") {
                    Text(state.capabilities.sorted().joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Ma trận này phản ánh RPC mà worker thực sự đăng ký, không phải tuyên bố tĩnh.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct G2ReviewSectionView: View {
    @ObservedObject var state: AppState

    var body: some View {
        GroupBox(label: Label("6. Cần làm rõ & Kiểm chứng Bằng chứng (Gate G2 — S12..S15)", systemImage: "magnifyingglass.circle")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(state.g2ScopeSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    if state.isBatchAnalysisRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Đang phân tích \(state.batchCurrentIndex)/\(state.batchTotalCount): \(state.batchCurrentFilename)")
                                .font(.caption.monospacedDigit())
                            Button("Dừng", role: .destructive) {
                                state.cancelBatchAnalysis()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Button("Phân tích video đã chọn") {
                            Task {
                                await state.runG2AnalysisOnSelectedSource()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!state.isWorkerConnected || state.selectedFilePath.isEmpty || state.isRunningG2Analysis || state.isBatchAnalysisRunning)

                        if state.videoCount > 1 {
                            Button("Phân tích toàn bộ (\(state.videoCount) video)") {
                                Task {
                                    await state.runG2AnalysisOnAllVideos()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!state.isWorkerConnected || state.isRunningG2Analysis || state.isBatchAnalysisRunning)
                        }
                    }
                }

                ForEach(state.g2ReviewItems) { item in
                    G2ReviewItemRowView(state: state, item: item)
                }
            }
            .padding(8)
        }
    }
}

struct G2ReviewItemRowView: View {
    @ObservedObject var state: AppState
    let item: TargetedReviewRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("[\(item.evidenceKind.rawValue.uppercased()) · \(item.evidenceScopeRevisionId)] \(item.questionText)")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(item.status.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(item.status == "resolved" ? .green : .orange)
            }
            if let act = item.resolutionAction, let use = item.resultingAllowedUse {
                Text("Quyết định: \(act.rawValue) → Quyền dùng: \(use.rawValue)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.blue)
            } else {
                HStack(spacing: 6) {
                    Button("1. Xác nhận") {
                        Task { await state.resolveG2ReviewItemInStore(item: item, action: .confirmUserFact) }
                    }
                    Button("2. Sửa & nguồn") {
                        Task { await state.resolveG2ReviewItemInStore(item: item, action: .editFactOrClaim) }
                    }
                    Button("3. Chưa biết") {
                        Task { await state.resolveG2ReviewItemInStore(item: item, action: .answerUnknown) }
                    }
                    Button("4. Bác bỏ") {
                        Task { await state.resolveG2ReviewItemInStore(item: item, action: .rejectAiObservation) }
                    }
                    Button("5. Bỏ chi tiết") {
                        Task { await state.resolveG2ReviewItemInStore(item: item, action: .dropClaimOrDetail) }
                    }
                    Button("6. Loại tư liệu") {
                        Task { await state.resolveG2ReviewItemInStore(item: item, action: .excludeAssetFromEdit) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}
