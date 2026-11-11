// G4ConsoleView.swift — Gate G4 (S20/S21) Dedicated Form Console.
// S20/S21 human-centered UI: G3-approved inputs -> S08 assets -> Resolve -> QC -> human approval.
// Uses the G3JSONValue type from G3ConsoleView.swift.

import SwiftUI
import Foundation
import AppKit

struct G4CaptionCue: Identifiable, Hashable {
    var id = UUID()
    var text: String
    var startFrame: Int
    var endFrame: Int
}

struct G4PublishedAsset: Identifiable, Hashable {
    var id: String { beatId }
    var beatId: String
    var publicationId: String
    var receiptPublicationId: String
}

@MainActor
struct G4ConsoleView: View {
    @ObservedObject var state: AppState

    // Form State
    @State private var beatId: String = "beat-01"
    @State private var mappingPublicationId: String = ""
    @State private var fontPath: String = ""
    // (P1-53) No placeholder caption: an empty editor forces the cues to come from the
    // approved G3 beats instead of burning a placeholder sentence into the video.
    @State private var cues: [G4CaptionCue] = []

    // Raw JSON bindings maintained for full backward compatibility
    @State private var stageJSON = """
    {"beat_id":"beat-01","mapping_publication_id":"","font_path":"",
     "cues":[]}
    """
    @State private var assetJSON = "[]"
    @State private var resultText = "Chưa chạy G4"
    @State private var receiptJSON = ""
    @State private var previewPath = ""
    @State private var previewSHA = ""
    @State private var previewPubID: UUID?
    @State private var publishedPreviewPath = ""
    @State private var reviewed = false
    @State private var reviewNotes = ""
    @State private var isBusy = false
    @State private var showRawJSON = false

    var publishedAssets: [G4PublishedAsset] {
        guard let elements = (try? G3JSONValue.parse(assetJSON))?.elements else { return [] }
        return elements.compactMap { el in
            guard let bId = el.fields?["beat_id"]?.string,
                  let pubId = el.fields?["publication_id"]?.string,
                  let recId = el.fields?["receipt_publication_id"]?.string else { return nil }
            return G4PublishedAsset(beatId: bId, publicationId: pubId, receiptPublicationId: recId)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Scope rule, one line (the page header already carries the title).
            Label(
                "Cần kịch bản đã duyệt canonical G3; assets và preview bắt buộc commit qua S08.",
                systemImage: "checkmark.shield"
            )
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)

            // Form 1: Beat Caption Staging & S08 Publish
            Card(title: "1. Soạn và Stage phụ đề CFR24 cho từng Beat", symbol: "character.bubble") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Beat ID").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("beat-01", text: $beatId)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: 160)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mapping Publication UUID (từ G3)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("UUID từ S08 mapping", text: $mappingPublicationId)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Font (tuỳ chọn)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("Đường dẫn file .ttf / .otf", text: $fontPath)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: 200)
                    }

                    // Cues list editor
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Danh sách Cues phụ đề").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                cues.append(G4CaptionCue(text: "", startFrame: (cues.last?.endFrame ?? 0), endFrame: (cues.last?.endFrame ?? 0) + 24))
                                syncFormToStageJSON()
                            } label: {
                                Label("Thêm Cue", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }

                        ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                            HStack(spacing: 8) {
                                Text("#\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                                TextField("Nội dung phụ đề", text: Binding(
                                    get: { cue.text },
                                    set: { cues[index].text = $0; syncFormToStageJSON() }
                                ))
                                .textFieldStyle(.roundedBorder)

                                HStack(spacing: 4) {
                                    Text("Từ frame:").font(.caption2).foregroundStyle(.secondary)
                                    TextField("0", value: Binding(
                                        get: { cue.startFrame },
                                        set: { cues[index].startFrame = $0; syncFormToStageJSON() }
                                    ), formatter: NumberFormatter())
                                    .frame(width: 55)
                                    .textFieldStyle(.roundedBorder)
                                }

                                HStack(spacing: 4) {
                                    Text("Đến frame:").font(.caption2).foregroundStyle(.secondary)
                                    TextField("24", value: Binding(
                                        get: { cue.endFrame },
                                        set: { cues[index].endFrame = $0; syncFormToStageJSON() }
                                    ), formatter: NumberFormatter())
                                    .frame(width: 55)
                                    .textFieldStyle(.roundedBorder)
                                }

                                if cues.count > 1 {
                                    Button {
                                        cues.remove(at: index)
                                        syncFormToStageJSON()
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack {
                        Button {
                            syncFormToStageJSON()
                            Task { await stageAndPublish() }
                        } label: {
                            HStack(spacing: 6) {
                                if isBusy { ProgressView().controlSize(.small) }
                                Text("Stage + S08 Publish Beat này")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !state.isWorkerConnected || beatId.isEmpty)

                        Spacer()
                    }
                }
            }

            // Form 2: Published Assets Management
            Card(title: "2. Danh sách Assets đã publish qua S08 (\(publishedAssets.count))", symbol: "archivebox") {
                if publishedAssets.isEmpty {
                    Text("Chưa có beat asset nào được stage/publish qua S08.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(publishedAssets) { asset in
                            HStack {
                                StatusPill(text: asset.beatId, color: .brandTeal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Video Pub: \(asset.publicationId)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    Text("Receipt Pub: \(asset.receiptPublicationId)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    removeAsset(beatId: asset.beatId)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Xoá khỏi danh sách")
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }

            // Form 3: DaVinci Resolve Pipeline & Technical QC
            Card(title: "3. Dựng Timeline Resolve & Render Preview", symbol: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await runFullPreviewPipeline() }
                        } label: {
                            HStack(spacing: 6) {
                                if isBusy { ProgressView().controlSize(.small) }
                                Image(systemName: "wand.and.stars")
                                Text("Dựng & render tự động")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !state.isWorkerConnected || publishedAssets.isEmpty)

                        Button {
                            Task { await runNativePreview() }
                        } label: {
                            Label("Render native 1080p", systemImage: "bolt.horizontal.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected || publishedAssets.isEmpty)

                        Button {
                            Task { await rpc("g4.timeline.build") }
                        } label: {
                            Label("1. Dựng Timeline", systemImage: "film")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected || publishedAssets.isEmpty)

                        Button {
                            Task { await rpc("g4.render.start") }
                        } label: {
                            Label("2. Render", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected)

                        Button {
                            Task { await rpc("g4.render.inspect") }
                        } label: {
                            Label("3. QC Kỹ thuật", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected)
                    }

                    Text("Lưu ý: Render thành công không đảm bảo nội dung hoặc âm thanh chính xác. Phải thực hiện Human QC.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Divider()

                    // Inspected Preview
                    HStack(spacing: 12) {
                        Button {
                            Task { await publishPreview() }
                        } label: {
                            Label("S08 Publish Preview MP4", systemImage: "arrow.up.doc")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || previewPath.isEmpty || previewSHA.isEmpty)

                        if !publishedPreviewPath.isEmpty {
                            Button {
                                let url = URL(fileURLWithPath: publishedPreviewPath)
                                guard FileManager.default.fileExists(atPath: url.path) else { return }
                                _ = NSWorkspace.shared.open(url)
                            } label: {
                                Label("Mở xem Preview đã commit", systemImage: "play.rectangle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if let pubId = previewPubID {
                        Text("Preview Publication UUID: \(pubId.uuidString)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    }
                }
            }

            // Form 4: Human QC & S21 Approval
            Card(title: "4. Human QC & Phê duyệt S21 Canonical", symbol: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Tôi đã trực tiếp xem toàn bộ video preview và nghe trọn vẹn âm thanh; phụ đề tiếng Việt, tư liệu nguồn, crop dọc 9:16 và giọng đọc đều chính xác", isOn: $reviewed)
                        .font(.callout)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ghi chú phê duyệt (ít nhất 12 ký tự)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("Nhập nhận xét kiểm duyệt chất lượng preview...", text: $reviewNotes)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        Task { await approve() }
                    } label: {
                        HStack(spacing: 8) {
                            if isBusy { ProgressView().controlSize(.small) }
                            Image(systemName: "checkmark.circle.fill")
                            Text("S21: Phê duyệt Preview trong ProjectStore")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy || !reviewed || reviewNotes.trimmingCharacters(in: .whitespaces).count < 12 || previewPubID == nil || receiptJSON.isEmpty)
                }
            }

            if state.isStep3PreviewReady {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preview đã được phê duyệt đạt chuẩn QC!")
                                .font(.headline)
                            Text("Đã sẵn sàng chuyển sang Bước 4 để Render Final 4K hoặc mở trong DaVinci Resolve Studio.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            state.navigateToSection(.final)
                        } label: {
                            HStack {
                                Text("Tiếp tục sang Bước 4: Xuất bản Final 4K")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(4)
                }
            }

            // Collapsible Developer Section for Raw JSON
            DisclosureGroup(isExpanded: $showRawJSON) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stage JSON (đồng bộ với form):").font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $stageJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.secondary.opacity(0.2))

                    Text("Published Assets JSON:").font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $assetJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.secondary.opacity(0.2))
                }
                .padding(.top, 4)
            } label: {
                Text("Nâng cao: Xem & Chỉnh sửa JSON thô (Developer / Debug)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Log Console
            Card(title: "Nhật ký thực thi G4", symbol: "terminal") {
                ScrollView {
                    Text(resultText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 60, maxHeight: 120)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            autoPopulateFromStateAndStore()
            syncFormToStageJSON()
        }
    }

    private func autoPopulateFromStateAndStore() {
        if mappingPublicationId.isEmpty {
            if !state.latestG3PublicationId.isEmpty {
                mappingPublicationId = state.latestG3PublicationId
            }
            Task {
                if let store = state.projectStore, let proj = state.g1Project {
                    let pubs = try? await store.listPublications(projectId: proj.projectId)
                    if let mapPub = pubs?.last(where: { $0.artifactType == "g2_source_mapping" && $0.state == .committed }) ?? pubs?.last(where: { $0.artifactType == "g2_source_mapping" }) {
                        await MainActor.run {
                            self.mappingPublicationId = mapPub.publicationId.uuidString
                            self.syncFormToStageJSON()
                        }
                    }
                }
            }
        }
        // (P1-53) Fill only from the approved script, and only while the editor is empty.
        if !state.cachedCaptionCues.isEmpty && cues.isEmpty {
            cues = state.cachedCaptionCues
        }
        if let firstBeat = state.cachedStoryBeats.first {
            beatId = firstBeat.beatId
        }
    }

    /// Phase 1b/1c: render the approved 1080x1920 preview with ffmpeg.
    private func runNativePreview() async {
        isBusy = true
        defer { isBusy = false }
        do {
            var params = try requestParams()
            var voiceTexts: [String: G3JSONValue] = [:]
            for beat in state.cachedStoryBeats {
                voiceTexts[beat.beatId] = .string(beat.voiceText)
            }
            if var fields = params.fields {
                fields["voice_texts"] = .object(voiceTexts)
                fields["write_srt"] = .bool(true)
                params = .object(fields)
            }
            let renderParams = params
            // (P1-11) The native ffmpeg render is heavy work: take the S07 global lease for
            // its duration so it cannot run alongside a Resolve render or model inference.
            let response: G3JSONValue = try await ResourceGovernor.shared.withHeavyLease(
                projectId: (try? environment().2) ?? UUID(),
                kind: .heavyMediaConform,
                workerPid: state.worker.workerPid == 0 ? nil : state.worker.workerPid
            ) {
                try await state.worker.sendRequest(
                    method: "g4.render.native", params: renderParams, timeoutSeconds: 1800
                )
            }
            resultText = response.json
            if response.fields?["status"]?.string == "NATIVE_PREVIEW_VERIFIED" {
                // `approveG4Preview` validates the receipt object itself.
                receiptJSON = response.fields?["receipt"]?.json ?? ""
                previewPath = response.fields?["preview_path"]?.string ?? ""
                previewSHA = response.fields?["preview_sha256"]?.string ?? ""
                previewPubID = nil
                publishedPreviewPath = ""
                reviewed = false
            } else {
                receiptJSON = ""
                previewPath = ""
                previewSHA = ""
                previewPubID = nil
                publishedPreviewPath = ""
                reviewed = false
            }
        } catch {
            receiptJSON = ""
            previewPath = ""
            previewSHA = ""
            previewPubID = nil
            publishedPreviewPath = ""
            reviewed = false
            resultText = "Native preview blocked: \(error.localizedDescription)"
        }
    }

    /// Phase 1c: 1-click preview now renders with ffmpeg. The numbered Resolve
    /// buttons stay available for the legacy managed timeline.
    private func runFullPreviewPipeline() async {
        await runNativePreview()
    }

    private func syncFormToStageJSON() {
        let cuesArray = cues.map { [
            "text": G3JSONValue.string($0.text),
            "start_frame": G3JSONValue.integer($0.startFrame),
            "end_frame": G3JSONValue.integer($0.endFrame)
        ] }
        let obj: [String: G3JSONValue] = [
            "beat_id": .string(beatId),
            "mapping_publication_id": .string(mappingPublicationId),
            "font_path": .string(fontPath),
            "cues": .array(cuesArray.map { .object($0) })
        ]
        stageJSON = G3JSONValue.object(obj).json
    }

    private func removeAsset(beatId: String) {
        var assetItems = (try? G3JSONValue.parse(assetJSON))?.elements ?? []
        assetItems.removeAll { $0.fields?["beat_id"]?.string == beatId }
        assetJSON = G3JSONValue.array(assetItems).json
    }

    private func environment() throws -> (ProjectStore, ArtifactPublicationService, UUID, String) {
        guard let store = state.projectStore,
              let publisher = state.publicationService,
              let project = state.g1Project,
              let dbPath = store.dbURL?.path else {
            throw G3StoreError.blocked("Mở canonical G1 project trước khi sử dụng G4")
        }
        return (store, publisher, project.projectId, dbPath)
    }

    private func requestParams(_ stage: Bool = false) throws -> G3JSONValue {
        let (_, _, projectId, dbPath) = try environment()
        let value = try G3JSONValue.parse(stage ? stageJSON : assetJSON)
        var fields: [String: G3JSONValue] = [
            "db_path": .string(dbPath),
            "project_id": .string(projectId.uuidString),
        ]
        if stage {
            guard let payload = value.fields else {
                throw G3StoreError.invalidPayload("Staging request must be a JSON object")
            }
            for (k, v) in payload where k != "db_path" && k != "project_id" {
                fields[k] = v
            }
        } else {
            guard value.elements != nil else {
                throw G3StoreError.invalidPayload("G4 published assets must be a JSON array")
            }
            fields["assets"] = value
        }
        return .object(fields)
    }

    private func rpc(_ method: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            if method == "g4.render.start",
               await ResourceGovernor.shared.currentActiveLease() != nil {
                throw G3StoreError.blocked(
                    "Giải phóng lease S07 AI/heavy-media trước khi chạy Resolve render"
                )
            }
            let params = try requestParams()
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: method, params: params, timeoutSeconds: 900
            )
            resultText = response.json
            if method == "g4.render.inspect",
               response.fields?["status"]?.string == "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED" {
                receiptJSON = response.json
                previewPath = response.fields?["preview_path"]?.string ?? ""
                previewSHA = response.fields?["preview_sha256"]?.string ?? ""
                previewPubID = nil
                publishedPreviewPath = ""
                reviewed = false
            } else {
                receiptJSON = ""
                previewPath = ""
                previewSHA = ""
                previewPubID = nil
                publishedPreviewPath = ""
                reviewed = false
            }
        } catch {
            receiptJSON = ""
            previewPath = ""
            previewSHA = ""
            previewPubID = nil
            publishedPreviewPath = ""
            reviewed = false
            resultText = "\(method) blocked: \(error.localizedDescription)"
        }
    }

    private func stageAndPublish() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if await ResourceGovernor.shared.currentActiveLease() != nil {
                throw G3StoreError.blocked(
                    "Hoàn tất tác vụ nặng S07 trước khi conform caption S21"
                )
            }
            let (store, publisher, projectID, _) = try environment()
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: "g4.caption.stage", params: try requestParams(true), timeoutSeconds: 900
            )
            guard response.fields?["status"]?.string == "STAGED_REQUIRES_S08_COMMIT",
                  let video = response.fields?["video_path"]?.string,
                  let videoSHA = response.fields?["video_sha256"]?.string,
                  let receipt = response.fields?["receipt_path"]?.string,
                  let receiptSHA = response.fields?["receipt_sha256"]?.string,
                  let beatID = response.fields?["beat_id"]?.string else {
                throw G3StoreError.blocked("S21 staging thất bại")
            }
            let videoPub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: video),
                artifactType: "g4_captioned_cfr", expectedSHA256: videoSHA,
                // (P1-01) video + conform receipt = the job is only done after both.
                expectedPublicationCount: 2
            )
            let receiptPub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: receipt),
                artifactType: "g4_conform_receipt", expectedSHA256: receiptSHA
            )
            var assetItems = try G3JSONValue.parse(assetJSON).elements ?? []
            assetItems.removeAll { $0.fields?["beat_id"]?.string == beatID }
            assetItems.append(.object([
                "beat_id": .string(beatID),
                "publication_id": .string(videoPub.publicationId.uuidString),
                "receipt_publication_id": .string(receiptPub.publicationId.uuidString),
            ]))
            assetJSON = G3JSONValue.array(assetItems).json
            // (P1-54) remember the mapping publication the worker validated, so the final
            // stage fields can only ever be filled with a real `g2_source_mapping` id.
            if let mappingField = (try? G3JSONValue.parse(stageJSON))?.fields?["mapping_publication_id"]?.string,
               mappingField.count == 36 {
                state.latestG2MappingPublicationId = mappingField
            }
            receiptJSON = ""
            previewPubID = nil
            publishedPreviewPath = ""
            reviewed = false
            resultText = "S08 đã commit cả 2 artifact cho beat: \(beatID)"
        } catch {
            resultText = "G4 stage/S08 thất bại: \(error.localizedDescription)"
        }
    }

    private func publishPreview() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let (store, publisher, projectID, _) = try environment()
            guard !receiptJSON.isEmpty else {
                throw G3StoreError.blocked("Chạy render inspect trước khi publish")
            }
            let pub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: previewPath),
                artifactType: "g4_preview_mp4", expectedSHA256: previewSHA
            )
            guard let canonical = pub.canonicalPath,
                  !canonical.isEmpty,
                  FileManager.default.fileExists(atPath: canonical),
                  let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                  ).first else {
                throw G3StoreError.blocked("Canonical preview không tồn tại sau khi S08 commit")
            }
            let reviewDir = support.appendingPathComponent(
                "AIVideo/G4/review", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: reviewDir, withIntermediateDirectories: true
            )
            let link = reviewDir.appendingPathComponent(
                "preview-\(pub.publicationId.uuidString).mp4"
            )
            if FileManager.default.fileExists(atPath: link.path) {
                guard link.resolvingSymlinksInPath().path == canonical else {
                    throw G3StoreError.blocked("Review link đã trỏ tới vị trí khác")
                }
            } else {
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: URL(fileURLWithPath: canonical)
                )
            }
            previewPubID = pub.publicationId
            publishedPreviewPath = link.path
            resultText = "S08 preview đã commit; link .mp4 trỏ chính xác tới canonical blob"
        } catch {
            resultText = "Preview publication blocked: \(error.localizedDescription)"
        }
    }

    private func approve() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let (store, _, projectID, _) = try environment()
            guard let pubID = previewPubID else {
                throw G3StoreError.blocked("Preview chưa được publish qua S08")
            }
            let approved = try await store.approveG4Preview(
                projectId: projectID, previewPublicationId: pubID,
                receiptJSON: receiptJSON, reviewedBy: NSUserName(),
                reviewNotes: reviewNotes,
                watchedVideoAndListenedToAudio: reviewed
            )
            state.isStep3PreviewReady = true
            state.latestG4PublicationId = pubID.uuidString
            reviewed = false
            resultText = "Canonical preview approval: \(approved.approvalId.uuidString)\nSHA: \(approved.previewSHA256)"
        } catch {
            resultText = "G4 approval blocked: \(error.localizedDescription)"
        }
    }
}
