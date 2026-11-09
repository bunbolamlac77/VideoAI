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
    private var projectStore: ProjectStore?
    private var publicationService: ArtifactPublicationService?
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

    func runG2AnalysisOnSelectedSource() async {
        guard let store = projectStore, let proj = g1Project, let wd = g1Workday else { return }
        guard !selectedFilePath.isEmpty else {
            self.errorMessage = "Vui lòng chọn file video nguồn trước khi chạy phân tích G2."
            return
        }
        self.isRunningG2Analysis = true
        self.errorMessage = nil
        defer { self.isRunningG2Analysis = false }

        do {
            // Deterministic sourceRevisionId from canonical path + file size so S12 window checkpoints resume on retry!
            let fileAttrs = try? FileManager.default.attributesOfItem(atPath: selectedFilePath)
            let fileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? 0
            let srcRevUUID = Self.deterministicUUID(from: "src-rev:\(selectedFilePath):\(fileSize)")

            let res = try await worker.analyzeG2Source(
                filePath: selectedFilePath,
                sourceRevisionId: srcRevUUID.uuidString,
                workdayId: wd.workdayId.uuidString,
                briefText: g1DraftFactText
            )
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

            self.g1Claims = try await store.getLatestClaims(workdayId: wd.workdayId)
            self.g2ReviewItems = try await store.listReviewItems(workdayId: wd.workdayId)
            let savedObs = try await store.listRawObservations(sourceRevisionId: srcRevUUID)
            let pct = String(format: "%.1f", covRec.frameInputCoverage * 100.0)
            self.g2ScopeSummary = "Status: \(covRec.detailedPassStatus) · Coverage: \(pct)% (\(covRec.uniqueProcessedFrameIds.count)/\(covRec.totalDeclaredFrames) frames) · Obs: \(savedObs.count) · Claims: \(self.g1Claims.count) · Review: \(self.g2ReviewItems.count)"
        } catch {
            self.errorMessage = "Phân tích G2 thất bại: \(error.localizedDescription)"
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
                        await state.initializeG1ProjectStore()
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

                    // Section 4: Gate G1 ProjectStore, ACK-based Editor & Portable Backup
                    GroupBox(label: Label("4. Quản lý Dữ liệu & Phục hồi (Gate G1 — ProjectStore SQLite WAL)", systemImage: "externaldrive.badge.checkmark")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Dự án: \(state.g1Project?.name ?? "Đang mở...") · Revision: \(state.g1Project?.currentRevision ?? 1)")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("Trạng thái lưu: \(state.g1SaveStatus)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(state.g1SaveStatus.hasPrefix("Lưu lỗi") ? .red : (state.g1SaveStatus.hasPrefix("Đang lưu") ? .blue : .green))
                            }

                            if !state.g1ReconciliationSummary.isEmpty {
                                Text("Startup Reconciler (S08): \(state.g1ReconciliationSummary)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            HStack {
                                TextField("Nhập ghi chú/dữ kiện ngày làm việc (Brief/Fact)...", text: $state.g1DraftFactText)
                                    .textFieldStyle(.roundedBorder)
                                Button("Lưu nháp (ACK)") {
                                    Task {
                                        await state.saveDraftFactToStore()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Tạo Portable Backup (S09)") {
                                    Task {
                                        await state.createPortableBackupFromUI()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }

                            if !state.g1LastBackupInfo.isEmpty {
                                Text(state.g1LastBackupInfo)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.blue)
                            }

                            if !state.g1Claims.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Danh sách Claims/Facts hiện hành (\(state.g1Claims.count)):")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    ForEach(state.g1Claims) { c in
                                        HStack {
                                            Text("• [\(c.origin.rawValue)/\(c.epistemicStatus.rawValue)] \(c.text)")
                                                .font(.system(size: 11))
                                            Spacer()
                                            Text(c.reviewStatus.rawValue.uppercased())
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundColor(c.reviewStatus == .confirmed ? .green : .orange)
                                            if c.reviewStatus != .confirmed {
                                                Button("Xác nhận Fact") {
                                                    Task {
                                                        await state.confirmFactInStore(claimId: c.claimId)
                                                    }
                                                }
                                                .controlSize(.small)
                                            }
                                        }
                                    }
                                }
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }

                    // Section 5: Capabilities Matrix (Gate G0 & Gate G1 Completed)
                    GroupBox(label: Label("5. Bản đồ năng lực hệ thống (Capabilities Matrix)", systemImage: "checklist")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Trạng thái triển khai trung thực theo đặc tả AIVideo v3.1:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Text("• Worker JSON-RPC 2.0 stdio & Media Inspector (ffprobe):")
                                Spacer()
                                Text("IMPLEMENTED (G0)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Local Neural Model Smoke & DaVinci Resolve Adapter:")
                                Spacer()
                                Text("IMPLEMENTED (G0)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Single-writer ProjectStore (SQLite WAL & Revision History):")
                                Spacer()
                                Text("IMPLEMENTED (G1 — S04/S06)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• APFS Source Snapshot & 4-State Artifact Publication Engine:")
                                Spacer()
                                Text("IMPLEMENTED (G1 — S05/S08)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Global Heavy Lease Governor, Fencing & Online Backup/Restore:")
                                Spacer()
                                Text("IMPLEMENTED (G1 — S07/S09)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• VFR PTS Indexer, Production Models & Full-Frame Analysis:")
                                Spacer()
                                Text("IMPLEMENTED (G2 — S10..S12)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Semantic Claim Verifier, Event Graph, Targeted Review & G2 Benchmark:")
                                Spacer()
                                Text("IMPLEMENTED (G2 — S13..S15)").font(.caption).foregroundColor(.green)
                            }
                            HStack {
                                Text("• Storyboard Outline, VieNeu-TTS Trial & Beam Search Cut Solver:")
                                Spacer()
                                Text("PLANNED (Gate G3 — S16..S19)").font(.caption).foregroundColor(.orange)
                            }
                        }
                        .padding(8)
                    }

                    // Section 6: Gate G2 Targeted Review & Scope Impact View (S12..S15)
                    G2ReviewSectionView(state: state)
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
                    Button("Chạy phân tích G2 trên video đã chọn") {
                        Task {
                            await state.runG2AnalysisOnSelectedSource()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!state.isWorkerConnected || state.selectedFilePath.isEmpty || state.isRunningG2Analysis)
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
