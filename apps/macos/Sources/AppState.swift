//
// AppState.swift — observable application state for AIVideo v3.1.
//
// Extracted from AIVideoApp.swift (Wave E). Worker lifecycle, bookmarks, media
// scanning, G1/G2 store access and the opt-in motion prefilter live here; the
// SwiftUI shell stays in AIVideoApp.swift.
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
    /// (P2-01) internal, not private: the media extension in AppState+Media.swift needs it.
    var currentlyAccessedSecurityScopedURL: URL? = nil

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
    /// (P2-09) Empty by default: a prefilled demo prompt was indistinguishable from the
    /// user's own input and ended up in inference requests.
    @Published var modelPrompt: String = ""
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
    @Published var g1DraftFactText: String = ""
    @Published var g1SaveStatus: String = "Chưa lưu" // display only, never parsed
    /// (P2-07) The authoritative save state; the message above is for humans.
    @Published var g1Persistence: PersistenceState = .idle

    // MARK: - Brief cho người viết kịch bản (Bước 1)
    // Nguồn ngữ cảnh duy nhất do người dùng viết: MỘT ô text. Thứ bắt buộc là
    // khoảnh khắc đẹp nhất cần có ("Cảnh bắt buộc: …"); các dòng khác là tuỳ
    // chọn và được ScriptBriefRecord.parseBox tách ra. Persist bởi ProjectStore
    // (single writer) trong AppState+ScriptBrief.swift và gửi cho G2 dưới dạng
    // `brief_text`; G3 đọc lại để prefill chủ đề / giọng điệu.
    @Published var briefRawText: String = ""
    @Published var briefSaveStatus: String = "Chưa lưu"
    /// (P2-07) Authoritative save state for the brief card.
    @Published var briefPersistence: PersistenceState = .idle
    @Published var latestScriptBrief: ScriptBriefRecord?
    @Published var g1Claims: [ClaimRecord] = []
    @Published var g1ReconciliationSummary: String = ""
    @Published var g1LastBackupInfo: String = ""
    @Published var g2ReviewItems: [TargetedReviewRecord] = []
    @Published var g2ScopeSummary: String = "Chưa có lượt phân tích G2 nào trong SQLite (Coverage: N/A)"
    @Published var isRunningG2Analysis: Bool = false
    /// Opt-in motion prefilter (skips static windows). Off by default.
    @Published var prefilterEnabled: Bool = false

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

        // (P1-49) Cue timing is only trustworthy when it comes from the measured WAV.
        // The old word-count x 0.45 s heuristic produced captions that drifted from the voice
        // and were then shown as approved. Without per-phrase sample offsets the editor
        // starts empty and the caption is taken from the beat's own audio length.
        var generatedCues: [G4CaptionCue] = []
        var currentFrame = 0
        for b in beats {
            guard let samples = b.voiceSamples, samples > 0 else { continue }
            let frameSpan = max(1, Int((Double(samples) / 48_000.0 * 24.0).rounded(.down)))
            generatedCues.append(G4CaptionCue(
                text: b.voiceText,
                startFrame: currentFrame,
                endFrame: currentFrame + frameSpan
            ))
            currentFrame += frameSpan
        }
        self.cachedCaptionCues = generatedCues
        self.captionTimingSource = generatedCues.isEmpty
            ? "unknown_waiting_for_measured_wav"
            : "measured_wav_samples"
    }

    /// (P1-47) The analysis currently running, so "Dừng" can cancel it.
    var currentBatchTask: Task<CoverageLedgerRecord, Error>?
    /// (P1-54) The most recent `g2_source_mapping` publication for this project.
    @Published var latestG2MappingPublicationId: String = ""
    /// (P1-49) Where the current caption timing came from; the UI must show it.
    @Published var captionTimingSource: String = "none"
    var projectStore: ProjectStore? // actor remains single canonical writer; exposed to G3 UI only
    var publicationService: ArtifactPublicationService? // shared S08 actor for G4
    /// Debounce handle for auto-saving the scriptwriter brief while typing.
    var briefAutosaveTask: Task<Void, Never>?
    private let backupService = BackupRestoreService(supportedMaxSchemaVersion: 2)

    @Published var errorMessage: String?

    let worker = WorkerClient()

    // MARK: - Worker Initialization & Preflight Discovery

    func resolveWorkerScriptPath() -> String? {
        let fm = FileManager.default

        // 1. Bundle Resources. There is exactly one bundled location (P2-02); the former
        //    `workers/src/...` duplicate was never used and only doubled the payload.
        if let bundleRes = Bundle.main.resourceURL {
            let bundledWorker = bundleRes.appendingPathComponent("Workers/aivideo_workers/main.py").path
            if fm.fileExists(atPath: bundledWorker) {
                return bundledWorker
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
        // No personal folder name here: users can point AIVIDEO_REPO_ROOT at their checkout.
        let commonConventions = [
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

        // 0. Explicit override (CI, custom installs)
        if let override = ProcessInfo.processInfo.environment["AIVIDEO_PYTHON"],
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return override
        }

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
        // (P1-48) The guard used to be checked before `await terminate()` and only set inside
        // `initializeWorker`, so two quick invocations could both pass and spawn two workers.
        guard !isStartingWorker else { return }
        isStartingWorker = true
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

            // (P2-10) The default project/workday used to be hard-coded UUIDs, so every
            // install shared one identity and a stray receipt from another machine could
            // match it. The id is now stable per install, stored in UserDefaults.
            let fixedProjId = Self.installProjectId()
            let fixedWorkdayId = Self.installWorkdayId(for: fixedProjId)

            let proj: ProjectRecord
            let workday: WorkdayRecord
            if let existing = try await store.getProject(id: fixedProjId) {
                proj = existing
                if let found = try await store.getWorkday(id: fixedWorkdayId, projectId: fixedProjId) {
                    workday = found
                } else {
                    workday = try await store.createWorkday(
                        id: fixedWorkdayId, projectId: fixedProjId,
                        title: "Ngày 1: Tư liệu thực địa", date: Self.todayDateString()
                    )
                }
            } else {
                proj = try await store.createProject(id: fixedProjId, name: "Dự án của tôi")
                workday = try await store.createWorkday(
                    id: fixedWorkdayId, projectId: fixedProjId,
                    title: "Ngày 1: Tư liệu thực địa", date: Self.todayDateString()
                )
            }
            self.g1Project = proj
            self.g1Workday = workday

            let report = try await pubService.runStartupReconciliation(
                store: store,
                projectId: proj.projectId,
                newSessionId: "app-session-\(UUID().uuidString)"
            )
            self.g1ReconciliationSummary = "Reconciled: revoked=\(report.revokedOldAttemptsCount), quarantined=\(report.quarantinedTempsCount), corrupted=\(report.corruptedCommittedBlobsCount)"
            self.g1Claims = try await store.getLatestClaims(workdayId: workday.workdayId)
            self.g2ReviewItems = try await store.listReviewItems(workdayId: workday.workdayId)
            await loadScriptBrief()
            let covRecords = try await store.listCoverageRecords(projectId: proj.projectId)
            if let latestCov = covRecords.first {
                let pct = String(format: "%.1f", latestCov.frameInputCoverage * 100.0)
                self.g2ScopeSummary = "Status: \(latestCov.detailedPassStatus) · Coverage: \(pct)% (\(latestCov.uniqueProcessedFrameIds.count)/\(latestCov.totalDeclaredFrames) frames) · Semantic: Chưa chứng nhận"
            } else {
                self.g2ScopeSummary = "Chưa có bản ghi Coverage G2 trong SQLite · Review items: \(self.g2ReviewItems.count)"
            }
            // (P2-08) Opening the store is not a save. The status says what actually
            // happened, so it cannot read "saved" while the user has typed nothing.
            if proj.currentRevision > 1 {
                self.g1SaveStatus = "Đã lưu (Rev \(proj.currentRevision))"
                self.g1Persistence = .saved
            } else {
                self.g1SaveStatus = "Cơ sở dữ liệu đã mở · chưa có thay đổi nào được lưu"
                self.g1Persistence = .idle
            }
        } catch {
            self.g1SaveStatus = "Lưu lỗi: \(error.localizedDescription)"
            self.g1Persistence = .failed
        }
    }

    // MARK: - Install identity (P2-10)

    private static let installProjectIdKey = "AIVideoInstallProjectId"
    private static let installWorkdayIdKey = "AIVideoInstallWorkdayId"

    static func installProjectId() -> UUID {
        if let raw = UserDefaults.standard.string(forKey: installProjectIdKey),
           let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: installProjectIdKey)
        return id
    }

    /// Derived from the project id so the pairing is stable and impossible to collide with
    /// a hard-coded fixture id.
    static func installWorkdayId(for projectId: UUID) -> UUID {
        if let raw = UserDefaults.standard.string(forKey: installWorkdayIdKey),
           let id = UUID(uuidString: raw) {
            return id
        }
        var bytes = withUnsafeBytes(of: projectId.uuid) { Array($0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                             bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                             bytes[12], bytes[13], bytes[14], bytes[15]))
        UserDefaults.standard.set(id.uuidString, forKey: installWorkdayIdKey)
        return id
    }

    static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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
            briefText: composedBriefText(),
            prefilterEnabled: prefilterEnabled
        )

        // Verify SHA-256 returned by Python worker matches computed fingerprint
        if res.sourceSha256 != fingerprint.sha256 {
            throw SourceRevisionIdentityError.sourceChangedDuringRead
        }
        let dto = res.coverageLedger
        let resolvedUniqueIds = dto.resolvedUniquePostProcessorFrameIds
        let covRec = CoverageLedgerRecord(
            coverageId: Self.deterministicUUID(from: "cov:\(srcRevUUID.uuidString)"),
            projectId: proj.projectId,
            sourceRevisionId: srcRevUUID,
            runtimeProfileId: dto.runtimeProfileId,
            inputFingerprint: dto.inputFingerprint,
            totalDeclaredFrames: dto.totalDeclaredSourceFrames,
            validDecodedFrameCount: dto.resolvedValidDecodedFrameIds.count,
            corruptedDecodeFrameIds: dto.corruptedDecodeFrameIds,
            uniqueProcessedFrameIds: resolvedUniqueIds,
            totalSubmittedWithOverlap: dto.totalSubmittedFramesWithOverlap,
            audioBranchState: AudioBranchState(rawValue: res.audioBranchState) ?? .speechDetected,
            completedWindows: resolvedUniqueIds.isEmpty ? 0 : 1,
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
        // The brief is user-authored context: persist it before it is cited by
        // any claim/question, so the evidence trail points at a stored revision.
        await persistBriefIfNeeded()
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

        await persistBriefIfNeeded()
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
                // (P1-47) The in-flight analysis is a cancellable task: "Dừng" must stop the
                // current video, not wait for it to finish (which could take minutes).
                let task = Task { try await analyzeSingleSource(filePath: item.id, store: store, proj: proj, wd: wd) }
                self.currentBatchTask = task
                let cov = try await task.value
                self.currentBatchTask = nil
                lastCov = cov
                self.batchCompletedCount += 1
            } catch is CancellationError {
                self.currentBatchTask = nil
                self.statusMessage = "Đã dừng phân tích (đang phân tích dở video \(item.name))."
                await refreshG2State(wdId: wd.workdayId, lastCov: lastCov)
                return
            } catch {
                self.currentBatchTask = nil
                self.batchFailedCount += 1
                self.statusMessage = "Video \(item.name) lỗi: \(error.localizedDescription)"
            }

            await refreshG2State(wdId: wd.workdayId, lastCov: lastCov)
        }

        if !batchCancelRequested {
            self.statusMessage = "Hoàn tất phân tích toàn bộ: \(batchCompletedCount)/\(videoItems.count) video thành công\(batchFailedCount > 0 ? " (\(batchFailedCount) lỗi)" : "")."
        }
    }

    /// (P1-51) "Làm video mới" must clear every approval, cue and publication reference so the
    /// next video cannot inherit the previous one's "đã duyệt" state.
    func resetWorkflowForNewVideo() {
        currentBatchTask?.cancel()
        currentBatchTask = nil
        batchCancelRequested = true
        cachedStoryBeats = []
        cachedCaptionCues = []
        captionTimingSource = "none"
        latestG3PublicationId = ""
        latestG4PublicationId = ""
        latestG5PublicationId = ""
        latestG2MappingPublicationId = ""
        latestScriptBrief = nil
        g1Claims = []
        g2ReviewItems = []
        g2ScopeSummary = ""
        probeResult = nil
        mediaItems = []
        selectedFilePath = ""
        isStep2StoryApproved = false
        isStep3PreviewReady = false
        statusMessage = "Đã làm mới quy trình: hãy chọn thư mục tư liệu cho video mới."
        navigateToSection(.media)
    }

    func cancelBatchAnalysis() {
        self.batchCancelRequested = true
        // (P1-47) cancel the RPC in flight as well as the loop condition
        self.currentBatchTask?.cancel()
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
        self.g1Persistence = .saving
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
                self.g1Persistence = .saved
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
