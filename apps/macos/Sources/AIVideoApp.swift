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

// MARK: - Media Models

enum MediaItemKind: String, Codable, Sendable {
    case video
    case image

    var symbol: String {
        switch self {
        case .video: return "film.fill"
        case .image: return "photo.fill"
        }
    }
}

struct MediaSourceItem: Identifiable, Hashable, Sendable {
    let id: String // Absolute path
    let url: URL
    let name: String
    let kind: MediaItemKind
    let fileSize: Int64
    let modifiedDate: Date?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case videos = "Video"
    case images = "Ảnh"
    var id: String { rawValue }
}

enum WorkflowStep: String, CaseIterable, Identifiable {
    case assets = "media"
    case story = "story"
    case preview = "preview"
    case export = "final"

    var id: String { rawValue }

    var stepNumber: Int {
        switch self {
        case .assets: return 1
        case .story: return 2
        case .preview: return 3
        case .export: return 4
        }
    }

    var title: String {
        switch self {
        case .assets: return "1. Tư liệu"
        case .story: return "2. Kịch bản & Thoại"
        case .preview: return "3. Xem trước (Preview)"
        case .export: return "4. Xuất bản Final"
        }
    }

    var shortDescription: String {
        switch self {
        case .assets: return "Nạp & Quét AI"
        case .story: return "Cốt truyện & Voice"
        case .preview: return "Khớp video 9:16 & Sub"
        case .export: return "Render 4K & Resolve"
        }
    }

    var symbol: String {
        switch self {
        case .assets: return "film.stack"
        case .story: return "text.book.closed"
        case .preview: return "play.rectangle"
        case .export: return "checkmark.seal"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // Worker Status
    @Published var isWorkerConnected: Bool = false
    @Published var workerPid: Int32 = 0
    @Published var pythonVersion: String = ""
    @Published var workerVersion: String = ""
    @Published var capabilities: [String] = []
    @Published var statusMessage: String = "Đang khởi tạo hệ thống..."

    // Media Source Inspector, Directory Workspace & Security-Scoped Bookmark
    @Published var selectedDirectoryPath: String = ""
    @Published var mediaItems: [MediaSourceItem] = []
    @Published var selectedFilePath: String = ""
    @Published var isSecurityScoped: Bool = false
    @Published var isBookmarkStale: Bool = false
    @Published var probeResult: MediaProbeResult?
    @Published var isProbing: Bool = false
    @Published var mediaFilter: MediaFilter = .all
    private var currentlyAccessedSecurityScopedURL: URL? = nil

    var videoCount: Int { mediaItems.filter { $0.kind == .video }.count }
    var imageCount: Int { mediaItems.filter { $0.kind == .image }.count }
    var totalFolderBytes: Int64 { mediaItems.reduce(0) { $0 + $1.fileSize } }
    var filteredMediaItems: [MediaSourceItem] {
        switch mediaFilter {
        case .all: return mediaItems
        case .videos: return mediaItems.filter { $0.kind == .video }
        case .images: return mediaItems.filter { $0.kind == .image }
        }
    }

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

    // Gate G1: ProjectStore, Brief/Fact Editor & ACK Save Status (S06.5)
    @Published var g1Project: ProjectRecord?
    @Published var g1Workday: WorkdayRecord?
    @Published var g1DraftFactText: String = "Đoạn quay cảnh sương mù đèo Prenn lúc 6h sáng"
    @Published var g1SaveStatus: String = "Chưa lưu" // Đang lưu / Đã lưu / Lưu lỗi
    @Published var g1Claims: [ClaimRecord] = []
    @Published var g1ReconciliationSummary: String = ""
    @Published var g1LastBackupInfo: String = ""
    @Published var g2ReviewItems: [TargetedReviewRecord] = []
    @Published var g2ScopeSummary: String = "Chưa có lượt phân tích G2 nào trong SQLite (Coverage: N/A)"
    @Published var isRunningG2Analysis: Bool = false

    // Batch G2 Analysis (Analyze All Videos in Folder)
    @Published var isBatchAnalysisRunning: Bool = false
    @Published var batchTotalCount: Int = 0
    @Published var batchCurrentIndex: Int = 0
    @Published var batchCurrentFilename: String = ""
    @Published var batchCompletedCount: Int = 0
    @Published var batchFailedCount: Int = 0
    private var batchCancelRequested: Bool = false
    // Linear Workflow & Auto-Wiring State
    @Published var activeWorkflowStep: WorkflowStep = .assets
    @Published var requestedSection: AppSection? = nil
    @Published var latestG3PublicationId: String = ""
    @Published var latestG4PublicationId: String = ""
    @Published var latestG5PublicationId: String = ""
    @Published var cachedStoryBeats: [G3BeatItem] = []
    @Published var cachedCaptionCues: [G4CaptionCue] = []
    @Published var isStep2StoryApproved: Bool = false
    @Published var isStep3PreviewReady: Bool = false

    func navigateToSection(_ section: AppSection) {
        self.requestedSection = section
    }

    func syncApprovedStoryToBeatsAndCues(beats: [G3BeatItem], publicationId: String) {
        self.cachedStoryBeats = beats
        self.latestG3PublicationId = publicationId
        self.isStep2StoryApproved = true

        // Generate default sequential 24fps caption cues from beats
        var generatedCues: [G4CaptionCue] = []
        var currentFrame = 0
        for b in beats {
            let wordCount = max(1, b.voiceText.split(separator: " ").count)
            let durationSeconds = max(2.0, Double(wordCount) * 0.45)
            let frameSpan = Int(durationSeconds * 24.0)
            generatedCues.append(G4CaptionCue(
                text: b.voiceText,
                startFrame: currentFrame,
                endFrame: currentFrame + frameSpan
            ))
            currentFrame += frameSpan
        }
        self.cachedCaptionCues = generatedCues
    }

    var projectStore: ProjectStore? // actor remains single canonical writer; exposed to G3 UI only
    var publicationService: ArtifactPublicationService? // shared S08 actor for G4
    private let backupService = BackupRestoreService(supportedMaxSchemaVersion: 2)

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

        // 3. Check workspace roots (cwd is "/" when launched from Finder/Spotlight,
        //    so also consult the repo root stamped into Info.plist at build time)
        for root in Self.workspaceRoots() {
            let relativeWorker = (root as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")
            if fm.fileExists(atPath: relativeWorker) {
                return relativeWorker
            }
        }

        return nil
    }

    /// Candidate repository roots: dynamic discovery, env override, user defaults, build-time stamped root, ancestor traversal, cwd.
    static func workspaceRoots() -> [String] {
        var roots: [String] = []
        let fm = FileManager.default

        // 1. Explicit environment variable override
        if let env = ProcessInfo.processInfo.environment["AIVIDEO_REPO_ROOT"], !env.isEmpty, fm.fileExists(atPath: env) {
            roots.append(env)
        }

        // 2. User defaults preference (if user selected repo or saved path)
        if let userPref = UserDefaults.standard.string(forKey: "AIVideoRepoRoot"), !userPref.isEmpty, fm.fileExists(atPath: userPref) {
            roots.append(userPref)
        }

        // 3. Stamped root from build-time Info.plist (if path actually exists on this machine)
        if let stamped = Bundle.main.object(forInfoDictionaryKey: "AIVideoRepoRoot") as? String, !stamped.isEmpty, fm.fileExists(atPath: stamped) {
            roots.append(stamped)
        }

        // 4. Current working directory (if inside repo or root containing workers)
        let cwd = fm.currentDirectoryPath
        if cwd != "/" {
            let workerInCwd = (cwd as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")
            if fm.fileExists(atPath: workerInCwd) {
                roots.append(cwd)
            }
        }

        // 5. Dynamic Bundle ancestor traversal (when running from apps/macos/build/AIVideo.app or project tree)
        var ancestor = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = ancestor.path
            let checkPath = (candidate as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")
            if fm.fileExists(atPath: checkPath) {
                roots.append(candidate)
                break
            }
            ancestor = ancestor.deletingLastPathComponent()
        }

        // 6. Common project directory conventions in user home
        let home = fm.homeDirectoryForCurrentUser.path
        let commonConventions = [
            (home as NSString).appendingPathComponent("APP_CaNhan/AIVideo"),
            (home as NSString).appendingPathComponent("Developer/AIVideo"),
            (home as NSString).appendingPathComponent("Projects/AIVideo"),
            (home as NSString).appendingPathComponent("AIVideo")
        ]
        for p in commonConventions {
            if fm.fileExists(atPath: (p as NSString).appendingPathComponent("workers/src/aivideo_workers/main.py")) {
                roots.append(p)
            }
        }

        return Array(NSOrderedSet(array: roots)) as? [String] ?? roots
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
        for root in Self.workspaceRoots() {
            let localVenvPy = (root as NSString).appendingPathComponent("workers/.venv/bin/python3")
            if fm.fileExists(atPath: localVenvPy) && fm.isExecutableFile(atPath: localVenvPy) {
                return localVenvPy
            }
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

    @Published var isStartingWorker: Bool = false
    private var didBootstrap = false

    /// One-shot startup. Guarded so view re-appearance never double-spawns the worker.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await initializeG1ProjectStore()
        await initializeWorker()
        restoreSavedBookmark()
    }

    func restartWorker() async {
        guard !isStartingWorker else { return }
        await worker.terminate()
        isWorkerConnected = false
        modelStatus = nil
        await initializeWorker()
    }

    func initializeWorker() async {
        isStartingWorker = true
        defer { isStartingWorker = false }
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

    // MARK: - Folder & Media Selection (Directory Workspace with Video & Optional Photos)

    nonisolated static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm"
    ]
    nonisolated static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp"
    ]

    static func mediaKind(for url: URL) -> MediaItemKind? {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) { return .video }
        if supportedImageExtensions.contains(ext) { return .image }
        return nil
    }

    /// Recursive enumeration can take seconds on large/external volumes — never run it on the main actor.
    func scanDirectoryAsync(at dirURL: URL) async -> [MediaSourceItem] {
        await Task.detached(priority: .userInitiated) {
            Self.scanDirectory(at: dirURL)
        }.value
    }

    nonisolated static let skippedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "CVS", ".venv", "venv", "node_modules",
        "DerivedData", ".build", "build", "__pycache__", "Pods", "Carthage"
    ]

    nonisolated static func scanDirectory(at dirURL: URL) -> [MediaSourceItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var items: [MediaSourceItem] = []
        let maxItems = 5000

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)) else {
                continue
            }

            if resourceValues.isDirectory ?? false {
                if Self.skippedDirectoryNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            let kind: MediaItemKind?
            if Self.supportedVideoExtensions.contains(ext) {
                kind = .video
            } else if Self.supportedImageExtensions.contains(ext) {
                kind = .image
            } else {
                kind = nil
            }

            if let kind = kind {
                let size = Int64(resourceValues.fileSize ?? 0)
                let date = resourceValues.contentModificationDate
                items.append(MediaSourceItem(
                    id: fileURL.path,
                    url: fileURL,
                    name: fileURL.lastPathComponent,
                    kind: kind,
                    fileSize: size,
                    modifiedDate: date
                ))
                if items.count >= maxItems {
                    break
                }
            }
        }

        return items.sorted {
            if $0.kind != $1.kind {
                return $0.kind == .video // Videos first
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func selectSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Chọn thư mục"
        panel.message = "Chọn thư mục chứa toàn bộ video và ảnh tư liệu nguồn"

        if panel.runModal() == .OK, let url = panel.url {
            handleSelectedURL(url)
        }
    }

    func selectFileAndProbe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Mở tư liệu"
        panel.message = "Chọn thư mục hoặc file video/ảnh nguồn"

        if panel.runModal() == .OK {
            if let first = panel.urls.first {
                if panel.urls.count == 1 && (first.hasDirectoryPath || (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) {
                    handleSelectedURL(first)
                } else {
                    handleSelectedURLs(panel.urls)
                }
            }
        }
    }

    func handleSelectedURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1 && (first.hasDirectoryPath || (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) {
            handleSelectedURL(first)
            return
        }

        stopAccessingCurrentSecurityScopedResource()
        let fm = FileManager.default
        var items: [MediaSourceItem] = []

        for url in urls {
            let ext = url.pathExtension.lowercased()
            let kind: MediaItemKind?
            if Self.supportedVideoExtensions.contains(ext) {
                kind = .video
            } else if Self.supportedImageExtensions.contains(ext) {
                kind = .image
            } else {
                kind = nil
            }

            if let kind = kind {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let date = attrs?[.modificationDate] as? Date
                items.append(MediaSourceItem(
                    id: url.path,
                    url: url,
                    name: url.lastPathComponent,
                    kind: kind,
                    fileSize: size,
                    modifiedDate: date
                ))
            }
        }

        self.mediaItems = items.sorted {
            if $0.kind != $1.kind { return $0.kind == .video }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        self.selectedDirectoryPath = first.deletingLastPathComponent().path
        if let target = items.first(where: { $0.kind == .video }) ?? items.first {
            selectItemForInspection(target)
        }
    }

    func populateSingleFile(url: URL) {
        guard let kind = Self.mediaKind(for: url) else {
            self.errorMessage = "Định dạng không được hỗ trợ: .\(url.pathExtension)"
            return
        }
        self.selectedDirectoryPath = url.deletingLastPathComponent().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = attrs?[.modificationDate] as? Date
        let singleItem = MediaSourceItem(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            kind: kind,
            fileSize: size,
            modifiedDate: date
        )
        self.mediaItems = [singleItem]
        selectItemForInspection(singleItem)
    }

    func handleSelectedURL(_ url: URL) {
        stopAccessingCurrentSecurityScopedResource()
        self.isBookmarkStale = false

        let isDir = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

        // Create Security-Scoped Bookmark for persistent access across app launches
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "LastSelectedSourceFolderBookmark")
            self.isSecurityScoped = true
        } catch {
            self.isSecurityScoped = false
        }

        if isDir {
            let success = url.startAccessingSecurityScopedResource()
            if success {
                self.currentlyAccessedSecurityScopedURL = url
            }
            self.selectedDirectoryPath = url.path
            self.mediaItems = []
            self.statusMessage = "Đang quét thư mục: \(url.lastPathComponent)…"
            Task { await self.loadDirectory(url) }
        } else {
            // Single file selection
            populateSingleFile(url: url)
        }
    }

    /// Scans off-main, then applies results only if the user hasn't switched folders meanwhile.
    func loadDirectory(_ url: URL, keepSelection: Bool = false) async {
        let scanned = await scanDirectoryAsync(at: url)
        guard selectedDirectoryPath == url.path else { return }
        self.mediaItems = scanned
        self.statusMessage = "Đã nạp thư mục: \(url.lastPathComponent) (\(videoCount) video, \(imageCount) ảnh)"
        if keepSelection, scanned.contains(where: { $0.id == selectedFilePath }) { return }
        if let target = scanned.first(where: { $0.kind == .video }) ?? scanned.first {
            selectItemForInspection(target)
        } else {
            self.selectedFilePath = ""
            self.probeResult = nil
        }
    }

    func selectItemForInspection(_ item: MediaSourceItem) {
        self.selectedFilePath = item.id
        if item.kind == .video {
            Task {
                await self.probeFile(path: item.id)
            }
        } else {
            self.probeResult = nil
            self.isProbing = false
            self.statusMessage = "Đang xem ảnh đính kèm: \(item.name) (\(item.formattedSize))"
        }
    }

    func refreshCurrentDirectory() {
        guard !selectedDirectoryPath.isEmpty else { return }
        let url = URL(fileURLWithPath: selectedDirectoryPath)
        self.statusMessage = "Đang quét lại thư mục…"
        Task { await self.loadDirectory(url, keepSelection: true) }
    }

    func restoreSavedBookmark() {
        stopAccessingCurrentSecurityScopedResource()
        var isStale = false

        if let data = UserDefaults.standard.data(forKey: "LastSelectedSourceFolderBookmark") {
            do {
                let restoredURL = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                self.isBookmarkStale = isStale
                // A stale bookmark still resolves; Apple's guidance is to access it and re-mint the bookmark.
                let success = restoredURL.startAccessingSecurityScopedResource()
                if success {
                    self.currentlyAccessedSecurityScopedURL = restoredURL
                    if isStale,
                       let fresh = try? restoredURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        UserDefaults.standard.set(fresh, forKey: "LastSelectedSourceFolderBookmark")
                        self.isBookmarkStale = false
                    }
                    let isDir = restoredURL.hasDirectoryPath || (try? restoredURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    if isDir {
                        self.selectedDirectoryPath = restoredURL.path
                        Task { await self.loadDirectory(restoredURL) }
                    } else {
                        populateSingleFile(url: restoredURL)
                    }
                } else if isStale {
                    self.errorMessage = "Quyền truy cập thư mục đã cũ (stale bookmark). Vui lòng chọn lại thư mục để tái cấp quyền."
                } else {
                    self.errorMessage = "Không thể cấp quyền truy cập security-scoped cho thư mục đã lưu."
                }
                return
            } catch {
                // Fallback to legacy single file bookmark
            }
        }

        // Legacy file bookmark fallback
        if let data = UserDefaults.standard.data(forKey: "LastSelectedSourceBookmark") {
            do {
                let restoredURL = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                self.isBookmarkStale = isStale
                if isStale {
                    self.errorMessage = "Quyền truy cập file đã cũ. Vui lòng chọn lại file."
                } else {
                    let success = restoredURL.startAccessingSecurityScopedResource()
                    if success {
                        self.currentlyAccessedSecurityScopedURL = restoredURL
                        populateSingleFile(url: restoredURL)
                    }
                }
            } catch {
                self.errorMessage = "Không thể khôi phục bookmark: \(error.localizedDescription)"
            }
        }
    }

    func probeFile(path: String) async {
        self.isProbing = true
        self.errorMessage = nil
        defer { if selectedFilePath == path || selectedFilePath.isEmpty { isProbing = false } }
        do {
            let res = try await worker.probeMedia(filePath: path)
            // Drop stale results: user may have clicked another item while ffprobe ran.
            guard selectedFilePath == path else { return }
            self.probeResult = res
            self.statusMessage = "Phân tích media thành công: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            guard selectedFilePath == path else { return }
            self.errorMessage = "Lỗi probe media: \(error.localizedDescription)"
            self.probeResult = nil
        }
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
        defer { self.isRunningResolveSpike = false }

        let governor = ResourceGovernor.shared
        let leaseDecision = await governor.acquireHeavyLease(
            projectId: g1Project?.projectId ?? UUID(),
            jobId: UUID(),
            attemptId: UUID(),
            fencingToken: g1Project?.currentRevision ?? 1,
            kind: .resolveRender,
            workerPid: nil
        )
        let leaseToken: HeavyLeaseToken?
        switch leaseDecision {
        case .granted(let token):
            leaseToken = token
        case .deniedActiveLeaseHeld(let holderJob, _):
            self.errorMessage = "Tài nguyên đang bận bởi tác vụ nặng khác (\(holderJob.uuidString.prefix(8)))."
            return
        case .deniedZombieWorkerStillAlive(let pid):
            self.errorMessage = "Tiến trình worker (PID \(pid)) đang giải phóng bộ nhớ. Vui lòng thử lại sau."
            return
        case .deniedExternalResolveBusy(let reason):
            self.errorMessage = "DaVinci Resolve đang bận: \(reason)"
            return
        case .pausedInsufficientMemory(let avail, let req):
            self.errorMessage = "Bộ nhớ RAM khả dụng không đủ: \(avail) MB < yêu cầu \(req) MB."
            return
        case .pausedInsufficientDisk(let avail, let req):
            self.errorMessage = "Dung lượng đĩa không đủ: \(avail) MB < yêu cầu \(req) MB."
            return
        }
        defer {
            if let token = leaseToken {
                Task { await governor.releaseHeavyLease(leaseId: token.leaseId) }
            }
        }

        do {
            let res = try await worker.runResolveSpike(forceFreshRun: true)
            self.resolveSpikeResult = res
            self.statusMessage = "Resolve Spike hoàn thành: \(res.timelineResolution) @ \(res.timelineFps)fps"
        } catch {
            self.errorMessage = "Resolve Spike thất bại: \(error.localizedDescription)"
            self.resolveSpikeResult = nil
        }
    }

    func shutdownAsync() async {
        if let store = projectStore {
            try? await store.checkpointWAL()
            await store.close()
        }
        await worker.terminate()
    }

    // MARK: - Gate G1 Store Initialization, ACK-based Save/Confirm & Backup (S06.5 - S09)

    func initializeG1ProjectStore() async {
        do {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            let g1Dir = appSupport.appendingPathComponent("AIVideo/Projects/DefaultG1Project", isDirectory: true)
            try fm.createDirectory(at: g1Dir, withIntermediateDirectories: true)
            let dbURL = g1Dir.appendingPathComponent("project_store.db")

            let store = try ProjectStore(dbURL: dbURL)
            let pubService = try ArtifactPublicationService(workspaceRoot: g1Dir)
            self.projectStore = store
            self.publicationService = pubService

            let fixedProjId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            let fixedWorkdayId = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

            let proj: ProjectRecord
            if let existing = try await store.getProject(id: fixedProjId) {
                proj = existing
            } else {
                proj = try await store.createProject(id: fixedProjId, name: "Dự án mặc định (Gate G1)")
                _ = try await store.createWorkday(id: fixedWorkdayId, projectId: fixedProjId, title: "Ngày 1: Tư liệu thực địa", date: "2026-11-09")
            }
            self.g1Project = proj
            self.g1Workday = WorkdayRecord(workdayId: fixedWorkdayId, projectId: fixedProjId, title: "Ngày 1: Tư liệu thực địa", date: "2026-11-09")

            let report = try await pubService.runStartupReconciliation(
                store: store,
                projectId: fixedProjId,
                newSessionId: "app-session-\(UUID().uuidString)"
            )
            self.g1ReconciliationSummary = "Reconciled: revoked=\(report.revokedOldAttemptsCount), quarantined=\(report.quarantinedTempsCount), corrupted=\(report.corruptedCommittedBlobsCount)"
            self.g1Claims = try await store.getLatestClaims(workdayId: fixedWorkdayId)
            self.g2ReviewItems = try await store.listReviewItems(workdayId: fixedWorkdayId)
            let covRecords = try await store.listCoverageRecords(projectId: fixedProjId)
            if let latestCov = covRecords.first {
                let pct = String(format: "%.1f", latestCov.frameInputCoverage * 100.0)
                self.g2ScopeSummary = "Status: \(latestCov.detailedPassStatus) · Coverage: \(pct)% (\(latestCov.uniqueProcessedFrameIds.count)/\(latestCov.totalDeclaredFrames) frames) · Semantic: Chưa chứng nhận"
            } else {
                self.g2ScopeSummary = "Chưa có bản ghi Coverage G2 trong SQLite · Review items: \(self.g2ReviewItems.count)"
            }
            self.g1SaveStatus = "Đã lưu (Rev \(proj.currentRevision))"
        } catch {
            self.g1SaveStatus = "Lưu lỗi: \(error.localizedDescription)"
        }
    }

    func resolveG2ReviewItemInStore(item: TargetedReviewRecord, action: ReviewResolutionAction) async {
        guard let store = projectStore, let wd = g1Workday else { return }
        do {
            let (updated, blocked, viable) = try S14ReviewCoordinator.resolveReviewItem(item: item, action: action)
            try await store.saveReviewItem(updated)
            self.g2ReviewItems = try await store.listReviewItems(workdayId: wd.workdayId)
            self.g2ScopeSummary = "Đã xử lý Review (\(action.rawValue)) -> AllowedUse: \(updated.resultingAllowedUse?.rawValue ?? "exclude") · Nhánh chặn: \(blocked) · Nhánh khả thi: \(viable)"
        } catch {
            self.errorMessage = "Lỗi lưu review resolution: \(error.localizedDescription)"
        }
    }

    private static func deterministicUUID(from seed: String) -> UUID {
        var h1: UInt64 = 14695981039346656037
        var h2: UInt64 = 1099511628211
        for b in seed.utf8 {
            h1 ^= UInt64(b)
            h1 = h1 &* 1099511628211
            h2 ^= UInt64(b) &+ 0x9e3779b97f4a7c15
            h2 = h2 &* 14695981039346656037
        }
        let hex = String(format: "%016llx%016llx", h1, h2)
        let chars = Array(hex)
        let s1 = String(chars[0..<8])
        let s2 = String(chars[8..<12])
        let s3 = "4" + String(chars[13..<16])
        let s4 = "8" + String(chars[17..<20])
        let s5 = String(chars[20..<32])
        return UUID(uuidString: "\(s1)-\(s2)-\(s3)-\(s4)-\(s5)") ?? UUID()
    }

    private func analyzeSingleSource(
        filePath: String,
        store: ProjectStore,
        proj: ProjectRecord,
        wd: WorkdayRecord
    ) async throws -> CoverageLedgerRecord {
        // Enforce Core Invariant 4: Resource Governor Heavy Lease
        let governor = ResourceGovernor.shared
        let leaseDecision = await governor.acquireHeavyLease(
            projectId: proj.projectId,
            jobId: UUID(),
            attemptId: UUID(),
            fencingToken: proj.currentRevision,
            kind: .modelInference,
            workerPid: nil
        )
        let leaseToken: HeavyLeaseToken
        switch leaseDecision {
        case .granted(let token):
            leaseToken = token
        case .deniedActiveLeaseHeld(let holderJob, _):
            throw NSError(domain: "AIVideoGovernor", code: 429, userInfo: [NSLocalizedDescriptionKey: "Tài nguyên hệ thống đang bận bởi tác vụ nặng khác (\(holderJob.uuidString.prefix(8)))."])
        case .deniedZombieWorkerStillAlive(let pid):
            throw NSError(domain: "AIVideoGovernor", code: 429, userInfo: [NSLocalizedDescriptionKey: "Tiến trình worker cũ (PID \(pid)) vẫn đang chiếm bộ nhớ. Đang đợi giải phóng..."])
        case .deniedExternalResolveBusy(let reason):
            throw NSError(domain: "AIVideoGovernor", code: 429, userInfo: [NSLocalizedDescriptionKey: "DaVinci Resolve đang bận: \(reason)"])
        case .pausedInsufficientMemory(let avail, let req):
            throw NSError(domain: "AIVideoGovernor", code: 507, userInfo: [NSLocalizedDescriptionKey: "Bộ nhớ RAM khả dụng không đủ: \(avail) MB < yêu cầu \(req) MB."])
        case .pausedInsufficientDisk(let avail, let req):
            throw NSError(domain: "AIVideoGovernor", code: 507, userInfo: [NSLocalizedDescriptionKey: "Dung lượng đĩa không đủ: \(avail) MB < yêu cầu \(req) MB."])
        }
        defer {
            Task {
                await governor.releaseHeavyLease(leaseId: leaseToken.leaseId)
            }
        }

        // Compute SHA-256 fingerprint in detached background task off MainActor to ensure UI responsiveness on large 4K files
        let fingerprint = try await Task.detached(priority: .userInitiated) {
            try SourceRevisionIdentity.fingerprint(filePath: filePath)
        }.value

        let srcRevUUID = Self.deterministicUUID(from: "src-rev:\(fingerprint.sha256)")

        let res = try await worker.analyzeG2Source(
            filePath: fingerprint.canonicalPath,
            sourceRevisionId: srcRevUUID.uuidString,
            workdayId: wd.workdayId.uuidString,
            briefText: g1DraftFactText
        )

        // Verify SHA-256 returned by Python worker matches computed fingerprint
        if res.sourceSha256 != fingerprint.sha256 {
            throw SourceRevisionIdentityError.sourceChangedDuringRead
        }
        let dto = res.coverageLedger
        let covRec = CoverageLedgerRecord(
            coverageId: Self.deterministicUUID(from: "cov:\(srcRevUUID.uuidString)"),
            projectId: proj.projectId,
            sourceRevisionId: srcRevUUID,
            runtimeProfileId: dto.runtimeProfileId,
            inputFingerprint: dto.inputFingerprint,
            totalDeclaredFrames: dto.totalDeclaredSourceFrames,
            validDecodedFrameCount: dto.validDecodedFrameIds.count,
            corruptedDecodeFrameIds: dto.corruptedDecodeFrameIds,
            uniqueProcessedFrameIds: dto.uniquePostProcessorFrameIds,
            totalSubmittedWithOverlap: dto.totalSubmittedFramesWithOverlap,
            audioBranchState: AudioBranchState(rawValue: res.audioBranchState) ?? .speechDetected,
            completedWindows: dto.uniquePostProcessorFrameIds.isEmpty ? 0 : 1,
            totalWindows: 1,
            detailedPassStatus: dto.detailedPassStatus
        )
        try await store.saveCoverageRecord(covRec)

        for rawDto in res.rawObservations {
            let role = ObservationPassRole(rawValue: rawDto.passRole) ?? .rawIndependent
            let orig = Origin(rawValue: rawDto.origin) ?? .visualModel
            let ep = EpistemicStatus(rawValue: rawDto.epistemicStatus) ?? .observed
            let obsArt = try RawObservationArtifact(
                observationId: rawDto.observationId,
                sourceRevisionId: srcRevUUID,
                windowIndex: rawDto.windowIndex,
                passRole: role,
                origin: orig,
                epistemicStatus: ep,
                frameIds: rawDto.frameIds,
                startPts: rawDto.startPtsTicks,
                endPts: rawDto.endPtsTicks,
                observationText: rawDto.observationText,
                ocrRawTokens: rawDto.ocrRawTokens,
                ocrIsUncertain: rawDto.ocrIsUncertain
            )
            try await store.saveRawObservation(obsArt)
        }

        for cDto in res.claims {
            let cId = Self.deterministicUUID(from: "claim:\(srcRevUUID.uuidString):\(cDto.claimId)")
            let orig = Origin(rawValue: cDto.origin) ?? .user
            let ep = EpistemicStatus(rawValue: cDto.epistemicStatus) ?? .reported
            let revSt = ReviewStatus(rawValue: cDto.reviewStatus) ?? .unreviewed
            let supSt = SupportStatus(rawValue: cDto.supportStatus) ?? .insufficient
            let allUse = AllowedUse(rawValue: cDto.allowedUse) ?? .exclude
            let claimRec = ClaimRecord(
                claimId: cId,
                workdayId: wd.workdayId,
                text: cDto.text,
                origin: orig,
                epistemicStatus: ep,
                reviewStatus: revSt,
                supportStatus: supSt,
                allowedUse: allUse
            )
            _ = try await store.saveClaim(
                claim: claimRec,
                idempotencyKey: "g2-claim-\(srcRevUUID.uuidString)-\(cDto.claimId)"
            )
        }

        for (idx, rItem) in res.reviewItems.enumerated() {
            let kind = ReviewEvidenceKind(rawValue: rItem.evidenceKind) ?? .briefSpan
            let rUUID = Self.deterministicUUID(from: "rev-item:\(srcRevUUID.uuidString):\(idx):\(rItem.questionText)")
            let rec = try TargetedReviewRecord(
                reviewItemId: rUUID,
                projectId: proj.projectId,
                workdayId: wd.workdayId,
                evidenceScopeRevisionId: rItem.evidenceScopeRevisionId,
                evidenceKind: kind,
                isCritical: rItem.isCritical,
                questionText: rItem.questionText
            )
            try await store.saveReviewItem(rec)
        }

        return covRec
    }

    func runG2AnalysisOnSelectedSource() async {
        if projectStore == nil || g1Project == nil || g1Workday == nil {
            await initializeG1ProjectStore()
        }
        guard let store = projectStore, let proj = g1Project, let wd = g1Workday else {
            self.errorMessage = "Không thể khởi tạo cơ sở dữ liệu dự án."
            return
        }
        guard !selectedFilePath.isEmpty else {
            self.errorMessage = "Vui lòng chọn file video nguồn trước khi chạy phân tích G2."
            return
        }
        self.isRunningG2Analysis = true
        self.errorMessage = nil
        defer { self.isRunningG2Analysis = false }

        do {
            let covRec = try await analyzeSingleSource(filePath: selectedFilePath, store: store, proj: proj, wd: wd)
            await refreshG2State(wdId: wd.workdayId, lastCov: covRec)
            self.statusMessage = "Phân tích media thành công: \(URL(fileURLWithPath: selectedFilePath).lastPathComponent)"
        } catch {
            self.errorMessage = "Phân tích G2 thất bại: \(error.localizedDescription)"
        }
    }

    func runG2AnalysisOnAllVideos() async {
        if projectStore == nil || g1Project == nil || g1Workday == nil {
            await initializeG1ProjectStore()
        }
        guard let store = projectStore, let proj = g1Project, let wd = g1Workday else {
            self.errorMessage = "Không thể khởi tạo cơ sở dữ liệu dự án."
            return
        }

        let videoItems = mediaItems.filter { $0.kind == .video }
        guard !videoItems.isEmpty else {
            self.errorMessage = "Không tìm thấy video nào trong thư mục tư liệu nguồn."
            return
        }

        self.isRunningG2Analysis = true
        self.isBatchAnalysisRunning = true
        self.batchCancelRequested = false
        self.batchTotalCount = videoItems.count
        self.batchCurrentIndex = 0
        self.batchCompletedCount = 0
        self.batchFailedCount = 0
        self.errorMessage = nil
        defer {
            self.isRunningG2Analysis = false
            self.isBatchAnalysisRunning = false
            self.batchCurrentFilename = ""
        }

        var lastCov: CoverageLedgerRecord? = nil

        for (idx, item) in videoItems.enumerated() {
            if batchCancelRequested {
                self.statusMessage = "Đã dừng phân tích toàn bộ (\(batchCompletedCount)/\(videoItems.count) video hoàn tất)."
                break
            }

            self.batchCurrentIndex = idx + 1
            self.batchCurrentFilename = item.name
            self.selectedFilePath = item.id

            do {
                let cov = try await analyzeSingleSource(filePath: item.id, store: store, proj: proj, wd: wd)
                lastCov = cov
                self.batchCompletedCount += 1
            } catch {
                self.batchFailedCount += 1
                self.statusMessage = "Video \(item.name) lỗi: \(error.localizedDescription)"
            }

            await refreshG2State(wdId: wd.workdayId, lastCov: lastCov)
        }

        if !batchCancelRequested {
            self.statusMessage = "Hoàn tất phân tích toàn bộ: \(batchCompletedCount)/\(videoItems.count) video thành công\(batchFailedCount > 0 ? " (\(batchFailedCount) lỗi)" : "")."
        }
    }

    func cancelBatchAnalysis() {
        self.batchCancelRequested = true
    }

    private func refreshG2State(wdId: UUID, lastCov: CoverageLedgerRecord?) async {
        guard let store = projectStore else { return }
        self.g1Claims = (try? await store.getLatestClaims(workdayId: wdId)) ?? self.g1Claims
        self.g2ReviewItems = (try? await store.listReviewItems(workdayId: wdId)) ?? self.g2ReviewItems
        let countObs = (try? await store.listRawObservations(sourceRevisionId: lastCov?.sourceRevisionId ?? UUID()))?.count ?? 0
        if let covRec = lastCov {
            let pct = String(format: "%.1f", covRec.frameInputCoverage * 100.0)
            self.g2ScopeSummary = "Status: \(covRec.detailedPassStatus) · Coverage: \(pct)% (\(covRec.uniqueProcessedFrameIds.count)/\(covRec.totalDeclaredFrames) frames) · Obs: \(countObs) · Claims: \(self.g1Claims.count) · Review: \(self.g2ReviewItems.count)"
        }
    }

    func saveDraftFactToStore() async {
        guard let store = projectStore, let proj = g1Project, let wd = g1Workday else { return }
        let trimmed = g1DraftFactText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.g1SaveStatus = "Đang lưu..."
        do {
            let claim = ClaimRecord(
                workdayId: wd.workdayId,
                text: trimmed,
                origin: .user,
                epistemicStatus: .reported,
                reviewStatus: .unreviewed
            )
            _ = try await store.saveClaim(claim: claim, expectedRevision: proj.currentRevision)
            if let updated = try await store.getProject(id: proj.projectId) {
                self.g1Project = updated
                self.g1SaveStatus = "Đã lưu (ACK Rev \(updated.currentRevision))"
            }
            self.g1Claims = try await store.getLatestClaims(workdayId: wd.workdayId)
        } catch {
            // S06.5: Keep buffer on error and display Lưu lỗi based on real ACK failure
            self.g1SaveStatus = "Lưu lỗi: \(error.localizedDescription)"
        }
    }

    func confirmFactInStore(claimId: UUID) async {
        guard let store = projectStore, let proj = g1Project, let wd = g1Workday else { return }
        self.g1SaveStatus = "Đang lưu..."
        do {
            _ = try await store.confirmFact(
                claimId: claimId,
                approvedBy: NSUserName(),
                expectedRevision: proj.currentRevision
            )
            if let updated = try await store.getProject(id: proj.projectId) {
                self.g1Project = updated
                self.g1SaveStatus = "Đã lưu & Xác nhận Fact (ACK Rev \(updated.currentRevision))"
            }
            self.g1Claims = try await store.getLatestClaims(workdayId: wd.workdayId)
        } catch {
            self.g1SaveStatus = "Lưu lỗi: \(error.localizedDescription)"
        }
    }

    func createPortableBackupFromUI() async {
        guard let store = projectStore, let proj = g1Project else { return }
        do {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            let backupsDir = appSupport.appendingPathComponent("AIVideo/Backups", isDirectory: true)
            let (bundleURL, manifest) = try await backupService.createBackup(
                store: store,
                projectId: proj.projectId,
                mode: .portableBackup,
                backupsRootURL: backupsDir
            )
            self.g1LastBackupInfo = "Portable Backup thành công (Rev \(manifest.rootRevision)): \(bundleURL.lastPathComponent)"
        } catch {
            self.g1LastBackupInfo = "Backup lỗi: \(error.localizedDescription)"
        }
    }
}

// MARK: - App Delegate with AppKit Quit Barrier

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            appState?.handleSelectedURLs(urls)
            sender.reply(toOpenOrPrint: .success)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState else { return .terminateNow }

        // Bounded quit barrier: a hung worker/DB checkpoint must never block quitting forever.
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await state.shutdownAsync() }
                group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

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

    var isWorkflowStep: Bool {
        self == .media || self == .story || self == .preview || self == .final
    }

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
        case .story: return "Tạo câu chuyện POV, sinh giọng đọc VieNeu-TTS & duyệt S19"
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

    static let groups: [(String, [AppSection])] = [
        ("Quy trình dựng (POV Workflow)", [.media, .story, .preview, .final]),
        ("Dữ liệu & Kiểm chứng", [.review, .data]),
        ("Hệ thống & Chẩn đoán", [.model, .resolve, .capabilities]),
    ]
}

struct WorkflowStepperView: View {
    let currentSection: AppSection
    let onSelect: (AppSection) -> Void
    @EnvironmentObject var state: AppState

    private let steps: [(AppSection, String, String)] = [
        (.media, "1. Tư liệu", "film.stack"),
        (.story, "2. Kịch bản", "text.book.closed"),
        (.preview, "3. Xem trước", "play.rectangle"),
        (.final, "4. Xuất bản", "checkmark.seal")
    ]

    private var currentStepIndex: Int? {
        steps.firstIndex(where: { $0.0 == currentSection })
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let (section, title, icon) = step
                let isCurrent = section == currentSection
                let isPast = (currentStepIndex ?? 0) > index
                let isComplete = stepIsComplete(section)

                Button {
                    onSelect(section)
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? Color.brandTeal : (isComplete ? Color.brandTeal.opacity(0.18) : Color.primary.opacity(0.06)))
                                .frame(width: 28, height: 28)
                            if isComplete && !isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.brandTeal)
                            } else {
                                Image(systemName: icon)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isCurrent ? Color.white : (isPast ? Color.brandTeal : Color.secondary))
                            }
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.caption.weight(isCurrent ? .bold : .medium))
                                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isCurrent ? Color.brandTeal.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)

                if index < steps.count - 1 {
                    Rectangle()
                        .fill(isPast ? Color.brandTeal : Color.primary.opacity(0.1))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4)
                }
            }

            Spacer(minLength: 12)

            // Next step button
            if let curIdx = currentStepIndex, curIdx < steps.count - 1 {
                let nextStep = steps[curIdx + 1]
                Button {
                    onSelect(nextStep.0)
                } label: {
                    HStack(spacing: 4) {
                        Text("Tiếp tục: \(nextStep.1)")
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    private func stepIsComplete(_ section: AppSection) -> Bool {
        switch section {
        case .media: return !state.mediaItems.isEmpty
        case .story: return state.isStep2StoryApproved
        case .preview: return state.isStep3PreviewReady
        case .final: return !state.latestG5PublicationId.isEmpty
        default: return false
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @SceneStorage("selectedSection") private var selectionRaw: String = AppSection.media.rawValue

    private var selection: Binding<AppSection?> {
        Binding(
            get: { AppSection(rawValue: selectionRaw) ?? .media },
            set: { selectionRaw = ($0 ?? .media).rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(AppSection.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { section in
                            Label(section.title, systemImage: section.symbol)
                                .badge(badge(for: section))
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            .safeAreaInset(edge: .bottom) { WorkerStatusCard().padding(12) }
        } detail: {
            let current = AppSection(rawValue: selectionRaw) ?? .media
            VStack(spacing: 0) {
                if let err = state.errorMessage {
                    ErrorBanner(message: err) { state.errorMessage = nil }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if current.isWorkflowStep {
                            WorkflowStepperView(currentSection: current) { target in
                                selectionRaw = target.rawValue
                            }
                        }
                        SectionHeader(section: current)
                        detailView(for: current)
                    }
                    .padding(24)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                StatusBar()
            }
            .navigationTitle(current.title)
            .navigationSubtitle(state.g1Project?.name ?? "AIVideo v3.1")
            .onChange(of: state.requestedSection) { _, newSec in
                if let s = newSec {
                    selectionRaw = s.rawValue
                    state.requestedSection = nil
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button {
                            state.selectSourceFolder()
                        } label: {
                            Label("Chọn thư mục tư liệu…", systemImage: "folder.badge.plus")
                        }
                        Button {
                            state.selectFileAndProbe()
                        } label: {
                            Label("Chọn file riêng lẻ…", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Label("Mở tư liệu", systemImage: "folder.badge.plus")
                    } primaryAction: {
                        state.selectSourceFolder()
                    }
                    .help("Chọn thư mục chứa video và ảnh (⌘O) hoặc file riêng lẻ (⇧⌘O)")

                    if !state.selectedDirectoryPath.isEmpty {
                        Button {
                            state.refreshCurrentDirectory()
                        } label: {
                            Label("Làm mới", systemImage: "arrow.clockwise")
                        }
                        .help("Quét lại các file trong thư mục hiện tại")
                    }

                    Button { Task { await state.restartWorker() } } label: {
                        Label("Khởi động lại worker", systemImage: "arrow.clockwise")
                    }
                    .help("Khởi động lại Python worker (⇧⌘R)")
                    .disabled(state.isStartingWorker)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
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

// MARK: - Reusable Chrome

struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "square")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(value).monospacedDigit().textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct SectionHeader: View {
    let section: AppSection
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.brandTeal)
                .frame(width: 44, height: 44)
                .background(Color.brandTeal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.title2.weight(.semibold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
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
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
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
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
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
        } else if let probe = state.probeResult, probe.filePath == item.id || state.selectedFilePath == item.id {
            VStack(alignment: .leading, spacing: 8) {
                KeyValueRow(key: "Định dạng", value: probe.formatName ?? "Unknown")
                KeyValueRow(key: "Thời lượng", value: String(format: "%.2f s", probe.durationSeconds))
                KeyValueRow(key: "Dung lượng", value: ByteCountFormatter.string(fromByteCount: Int64(probe.sizeBytes), countStyle: .file))

                ForEach(probe.videoStreams, id: \.index) { v in
                    let w = v.width.map { "\($0)" } ?? "0"
                    let h = v.height.map { "\($0)" } ?? "0"
                    let idx = v.index.map { "\($0)" } ?? "0"
                    let fps = v.frameRate ?? "Unknown"
                    KeyValueRow(key: "Video stream #\(idx)", value: "\(v.codecName ?? "Unknown") · \(w)×\(h) @ \(fps) fps · \(v.pixelFormat ?? "Unknown")")
                }

                ForEach(probe.audioStreams, id: \.index) { a in
                    let idx = a.index.map { "\($0)" } ?? "0"
                    let sr = a.sampleRate.map { "\($0) Hz" } ?? "N/A"
                    let ch = a.channels.map { "\($0) kênh" } ?? "N/A"
                    KeyValueRow(key: "Audio stream #\(idx)", value: "\(a.codecName ?? "Unknown") · \(sr) · \(ch)")
                }

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
                        HStack(spacing: 8) {
                            Button {
                                Task { await state.runG2AnalysisOnSelectedSource() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles.tv")
                                    Text("Phân tích video này")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(!state.isWorkerConnected || state.isRunningG2Analysis || state.isBatchAnalysisRunning)

                            if state.videoCount > 1 {
                                Button {
                                    Task { await state.runG2AnalysisOnAllVideos() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.rectangle.on.rectangle.fill")
                                        Text("Phân tích toàn bộ (\(state.videoCount))")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                .disabled(!state.isWorkerConnected || state.isRunningG2Analysis || state.isBatchAnalysisRunning)
                            }
                        }

                        Text("Trích xuất frame offline, suy luận VLM Qwen3-VL 4B tuần tự (RAM < 4 GB) để đối chiếu fact claim và sinh Coverage Ledger.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if !state.mediaItems.isEmpty {
                            Button {
                                state.navigateToSection(.story)
                            } label: {
                                HStack {
                                    Text("Tiếp tục: Sang Bước 2 (Kịch bản & Thoại)")
                                    Image(systemName: "arrow.right")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .padding(.top, 4)
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

                        if state.isSecurityScoped {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                                Text("Security-Scoped Sandbox Active").font(.caption2).foregroundStyle(.secondary)
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
                HStack(spacing: 12) {
                    Button("Chọn thư mục tư liệu…") { state.selectSourceFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Chọn file riêng lẻ…") { state.selectFileAndProbe() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
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
                    TextField("Nhập dữ kiện ngày làm việc (Brief/Fact)…", text: $state.g1DraftFactText)
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
