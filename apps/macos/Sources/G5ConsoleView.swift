// G5ConsoleView.swift — Gate G5 (S22–S26) Dedicated Form Console.
// Covers:
// - S22: 2160x3840 24fps Final Conform, Resolve Build/Render/Inspect, S08 Publish,
//        Canonical ProjectStore Final Approval, and Isolated Manual Handoff Branch.
// - S23: Capability Registry Gate Inspector, Local Preference Profile (View/Edit/Reset),
//        Photo Match / Event Graph / Source Re-Audit / Comedy Cue Alignment.
// - S24: Vietnamese IME Composition Guard (`G5VietnameseIMEBuffer`), Bounded Player &
//        Thumbnail LRU Quota (`G5BoundedPreviewCache`), Keyboard & VoiceOver Accessibility.
// - S25/S26: Fault Injection Suite, E0/E1 Accounting & Release Handover Manifest.

import SwiftUI
import Foundation
import AppKit

struct G5CaptionCue: Identifiable, Hashable {
    var id = UUID()
    var text: String
    var startFrame: Int
    var endFrame: Int
}

struct G5PublishedAsset: Identifiable, Hashable {
    var id: String { beatId }
    var beatId: String
    var publicationId: String
    var receiptPublicationId: String
}

@MainActor
struct G5ConsoleView: View {
    @ObservedObject var state: AppState

    // Form State
    @State private var beatId: String = "beat-01"
    @State private var mappingPublicationId: String = ""
    @State private var fontPath: String = ""
    // (P1-53) no placeholder; cues come from the approved G3 beats
    @State private var cues: [G5CaptionCue] = []
    @State private var pacingStyle: String = "balanced"
    @State private var reviewed4K = false
    @State private var reviewNotes = ""
    @State private var showRawJSON = false

    // Raw JSON bindings maintained for full backward compatibility
    @State private var stage4KJSON = """
    {"beat_id":"beat-01","mapping_publication_id":"","font_path":"",
     "cues":[]}
    """
    @State private var asset4KJSON = "[]"
    @State private var resultText = "Chưa chạy G5"
    @State private var finalReceiptJSON = ""
    @State private var finalPath = ""
    @State private var finalSHA = ""
    @State private var drpPath = ""
    @State private var drpSHA = ""
    @State private var finalPubID: UUID?
    @State private var drpPubID: UUID?
    @State private var isBusy = false

    var publishedAssets: [G5PublishedAsset] {
        guard let elements = (try? G3JSONValue.parse(asset4KJSON))?.elements else { return [] }
        return elements.compactMap { el in
            guard let bId = el.fields?["beat_id"]?.string,
                  let pubId = el.fields?["publication_id"]?.string,
                  let recId = el.fields?["receipt_publication_id"]?.string else { return nil }
            return G5PublishedAsset(beatId: bId, publicationId: pubId, receiptPublicationId: recId)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Scope rule, one line (the page header already carries the title).
            Label(
                "S22 cần phê duyệt S19 (G3) và S21 (G4) đang hiệu lực; bản 4K và .drp commit qua S08.",
                systemImage: "checkmark.shield"
            )
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)

            // Form 1: 4K Beat Staging & S08 Publish
            Card(title: "1. Soạn và Stage 4K Captioned Beat (2160×3840 24fps)", symbol: "tv.and.mediabox") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Beat ID").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("beat-01", text: $beatId)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: 160)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mapping Publication UUID (từ G4/G3)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
                            Text("Danh sách Cues phụ đề 4K").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                cues.append(G5CaptionCue(text: "", startFrame: (cues.last?.endFrame ?? 0), endFrame: (cues.last?.endFrame ?? 0) + 24))
                                syncFormToStageJSON()
                            } label: {
                                Label("Thêm Cue", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }

                        ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                            HStack(spacing: 8) {
                                Text("#\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                                TextField("Nội dung phụ đề 4K", text: Binding(
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
                            Task { await stageAndPublish4K() }
                        } label: {
                            HStack(spacing: 6) {
                                if isBusy { ProgressView().controlSize(.small) }
                                Text("Stage 4K + S08 Publish Beat")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !state.isWorkerConnected || beatId.isEmpty)

                        Spacer()
                    }
                }
            }

            // Form 2: Published 4K Assets Management
            Card(title: "2. Danh sách 4K Assets đã publish qua S08 (\(publishedAssets.count))", symbol: "archivebox") {
                if publishedAssets.isEmpty {
                    Text("Chưa có beat 4K asset nào được stage/publish qua S08.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(publishedAssets) { asset in
                            HStack {
                                StatusPill(text: asset.beatId, color: .brandTeal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("4K Video Pub: \(asset.publicationId)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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

            // Form 3: 4K Resolve Pipeline & S08 Final Publish
            Card(title: "3. Dựng Timeline 4K, Render & S08 Publish", symbol: "4k.tv") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await runFullFinalPipeline() }
                        } label: {
                            HStack(spacing: 6) {
                                if isBusy { ProgressView().controlSize(.small) }
                                Image(systemName: "wand.and.stars")
                                Text("Dựng & render 4K")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !state.isWorkerConnected || publishedAssets.isEmpty)

                        Button {
                            Task { await runNativeFinal() }
                        } label: {
                            Label("Render native 4K", systemImage: "bolt.horizontal.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected || publishedAssets.isEmpty)

                        Button {
                            Task { await rpc("g5.timeline.build_4k") }
                        } label: {
                            Label("1. Dựng Timeline", systemImage: "film")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected || publishedAssets.isEmpty)

                        Button {
                            Task { await rpc("g5.render.start_4k") }
                        } label: {
                            Label("2. Render", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected)

                        Button {
                            Task { await rpc("g5.render.inspect_4k") }
                        } label: {
                            Label("3. QC Kỹ thuật", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected)

                        Button {
                            Task { await forkManualHandoff() }
                        } label: {
                            Label("Phân nhánh DRP", systemImage: "arrow.triangle.branch")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected)
                    }

                    Divider()

                    Button {
                        Task { await publishFinalAndDRP() }
                    } label: {
                        Label("S08 Publish Final 4K MP4 + Resolve DRP", systemImage: "arrow.up.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || finalPath.isEmpty || drpPath.isEmpty)

                    if let fPub = finalPubID, let dPub = drpPubID {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Final MP4 Pub: \(fPub.uuidString)").font(.caption2.monospacedDigit()).foregroundStyle(.green).textSelection(.enabled)
                            Text("Final DRP Pub: \(dPub.uuidString)").font(.caption2.monospacedDigit()).foregroundStyle(.green).textSelection(.enabled)
                        }
                    }
                }
            }

            // Form 4: Human Release Review & S22 Approval
            Card(title: "4. Human Release Review & Phê duyệt S22 Canonical", symbol: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Text("Nhịp điệu tổng thể (Pacing):").font(.callout)
                        Picker("", selection: $pacingStyle) {
                            Text("Cân bằng (Balanced)").tag("balanced")
                            Text("Nhanh / Sôi nổi (Dynamic)").tag("dynamic")
                            Text("Trầm tĩnh / Cinematic").tag("relaxed")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }

                    Toggle("Tôi đã trực tiếp xem và nghe toàn bộ bản dựng 4K 2160×3840 24fps; phụ đề, bối cảnh, nguồn gốc tư liệu và lời thoại đều hoàn chỉnh, đạt chuẩn phát hành", isOn: $reviewed4K)
                        .font(.callout)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ghi chú phê duyệt phát hành (ít nhất 12 ký tự)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("Nhập đánh giá và xác nhận bản phát hành 4K...", text: $reviewNotes)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        Task { await approveFinal() }
                    } label: {
                        HStack(spacing: 8) {
                            if isBusy { ProgressView().controlSize(.small) }
                            Image(systemName: "checkmark.seal.fill")
                            Text("S22: Phê duyệt Final 4K trong ProjectStore")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy || !reviewed4K || reviewNotes.trimmingCharacters(in: .whitespaces).count < 12 || finalPubID == nil || drpPubID == nil || finalReceiptJSON.isEmpty)
                }
            }

            if !state.latestG5PublicationId.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Chúc mừng! Video POV Final 4K đã sẵn sàng!")
                                    .font(.title3.weight(.bold))
                                // (P1-50) Only a Resolve handoff has a .drp; the ffmpeg-native
                                // branch publishes a render receipt instead.
                                Text(
                                    drpPath.hasSuffix(".drp")
                                        ? "Bản xuất 2160×3840 @ 24fps chuẩn Rec.709 và timeline .drp đã được niêm phong."
                                        : "Bản xuất 2160×3840 @ 24fps chuẩn Rec.709 đã hoàn tất kèm receipt render native (không có timeline .drp)."
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        HStack(spacing: 12) {
                            if !finalPath.isEmpty {
                                Button {
                                    let url = URL(fileURLWithPath: finalPath)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } label: {
                                    Label("Hiện MP4 4K trong Finder", systemImage: "folder")
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    let url = URL(fileURLWithPath: finalPath)
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Phát video 4K", systemImage: "play.fill")
                                }
                                .buttonStyle(.bordered)
                            }

                            if !drpPath.isEmpty {
                                Button {
                                    let url = URL(fileURLWithPath: drpPath)
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Mở trong DaVinci Resolve", systemImage: "arrow.up.forward.app")
                                }
                                .buttonStyle(.bordered)
                            }

                            Spacer()

                            Button("Làm video mới (Về Bước 1)") {
                                // (P1-51) Resetting navigation alone let the next video inherit
                                // the previous approvals, cues and publication ids.
                                state.resetWorkflowForNewVideo()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(6)
                }
            }

            // Form 5: Hệ thống & Audit (S23 - S26)
            Card(title: "5. Kiểm toán & Năng lực phát hành (S23..S26)", symbol: "shield.lefthalf.filled") {
                HStack(spacing: 10) {
                    Button {
                        Task { await managePreferences(action: "reset") }
                    } label: {
                        Label("S23: Đặt lại Tùy chọn", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !state.isWorkerConnected)

                    Button {
                        Task { await runSimpleRPC("g5.fault.run_suite") }
                    } label: {
                        Label("S25: Chạy self-test tiêm lỗi", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !state.isWorkerConnected)
                    .help(
                        "Self-test chạy trong thư mục tạm — KHÔNG phải bằng chứng S25 và không "
                        + "bao giờ đánh dấu S25 đã đạt."
                    )

                    Button {
                        Task { await sendReleaseManifest() }
                    } label: {
                        Label("S26: Xuất Release Manifest", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !state.isWorkerConnected)
                }
            }

            // Collapsible Developer Section for Raw JSON
            DisclosureGroup(isExpanded: $showRawJSON) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("4K Stage JSON (đồng bộ với form):").font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $stage4KJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.secondary.opacity(0.2))

                    Text("Published 4K Assets JSON:").font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $asset4KJSON)
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
            Card(title: "Nhật ký thực thi G5", symbol: "terminal") {
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
            // (P1-54) Only a `g2_source_mapping` publication may fill this field. The old
            // fallbacks put a G3 or G4 id there, which the guard can only reject later.
            if !state.latestG2MappingPublicationId.isEmpty {
                mappingPublicationId = state.latestG2MappingPublicationId
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
            cues = state.cachedCaptionCues.map { G5CaptionCue(text: $0.text, startFrame: $0.startFrame, endFrame: $0.endFrame) }
        }
        if let firstBeat = state.cachedStoryBeats.first {
            beatId = firstBeat.beatId
        }
    }

    /// Phase 1b: render the approved 4K plan with ffmpeg instead of Resolve.
    /// Captions stay as approved (either re-burned from cues or kept from the
    /// pre-burned 1080p segments); the receipt replaces the `.drp` as the
    /// provenance artifact the S22 guard verifies.
    private func runNativeFinal() async {
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
                kind: .resolveRender,
                workerPid: state.worker.workerPid == 0 ? nil : state.worker.workerPid
            ) {
                try await state.worker.sendRequest(
                    method: "g5.render.native_4k", params: renderParams, timeoutSeconds: 1800
                )
            }
            resultText = response.json
            guard response.fields?["status"]?.string == "NATIVE_FINAL_VERIFIED" else {
                finalReceiptJSON = ""
                finalPath = ""
                finalSHA = ""
                drpPath = ""
                drpSHA = ""
                return
            }
            // `approveG5Final` validates the receipt object itself, not the RPC envelope.
            finalReceiptJSON = response.fields?["receipt"]?.json ?? ""
            finalPath = response.fields?["final_path"]?.string ?? ""
            finalSHA = response.fields?["final_sha256"]?.string ?? ""
            drpPath = response.fields?["drp_path"]?.string ?? ""
            drpSHA = response.fields?["drp_sha256"]?.string ?? ""
            finalPubID = nil
            drpPubID = nil
            reviewed4K = false
        } catch {
            resultText = "Native 4K render blocked: \(error.localizedDescription)"
        }
    }

    /// Phase 1c: the 1-click pipeline now renders with ffmpeg. The numbered
    /// Resolve buttons below stay available for the legacy managed timeline.
    private func runFullFinalPipeline() async {
        await runNativeFinal()
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
        stage4KJSON = G3JSONValue.object(obj).json
    }

    private func removeAsset(beatId: String) {
        var items = (try? G3JSONValue.parse(asset4KJSON))?.elements ?? []
        items.removeAll { $0.fields?["beat_id"]?.string == beatId }
        asset4KJSON = G3JSONValue.array(items).json
    }

    private func environment() throws -> (ProjectStore, ArtifactPublicationService, UUID, String) {
        guard let store = state.projectStore,
              let publisher = state.publicationService,
              let project = state.g1Project,
              let dbPath = store.dbURL?.path else {
            throw G3StoreError.blocked("Mở canonical G1 project trước khi sử dụng G5")
        }
        return (store, publisher, project.projectId, dbPath)
    }

    private func requestParams(_ stage: Bool = false) throws -> G3JSONValue {
        let (_, _, projectId, dbPath) = try environment()
        let value = try G3JSONValue.parse(stage ? stage4KJSON : asset4KJSON)
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
                throw G3StoreError.invalidPayload("G5 published assets must be a JSON array")
            }
            fields["assets"] = value
        }
        return .object(fields)
    }

    private func rpc(_ method: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            if method == "g5.render.start_4k",
               await ResourceGovernor.shared.currentActiveLease() != nil {
                throw G3StoreError.blocked("Giải phóng lease S07 heavy trước khi chạy 4K Resolve render")
            }
            let params = try requestParams()
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: method, params: params, timeoutSeconds: 1200
            )
            resultText = response.json
            if method == "g5.render.inspect_4k",
               response.fields?["status"]?.string == "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED" {
                finalReceiptJSON = response.json
                finalPath = response.fields?["final_path"]?.string ?? ""
                finalSHA = response.fields?["final_sha256"]?.string ?? ""
                drpPath = response.fields?["drp_path"]?.string ?? ""
                drpSHA = response.fields?["drp_sha256"]?.string ?? ""
                finalPubID = nil
                drpPubID = nil
                reviewed4K = false
            } else {
                finalReceiptJSON = ""
                finalPath = ""
                finalSHA = ""
                drpPath = ""
                drpSHA = ""
                finalPubID = nil
                drpPubID = nil
                reviewed4K = false
            }
        } catch {
            resultText = "\(method) blocked: \(error.localizedDescription)"
        }
    }

    private func stageAndPublish4K() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if await ResourceGovernor.shared.currentActiveLease() != nil {
                throw G3StoreError.blocked("Hoàn tất tác vụ nặng S07 trước khi conform 4K caption G5")
            }
            let (store, publisher, projectID, _) = try environment()
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: "g5.caption.stage_4k", params: try requestParams(true), timeoutSeconds: 1200
            )
            guard response.fields?["status"]?.string == "STAGED_REQUIRES_S08_COMMIT",
                  let video = response.fields?["video_path"]?.string,
                  let videoSHA = response.fields?["video_sha256"]?.string,
                  let receipt = response.fields?["receipt_path"]?.string,
                  let receiptSHA = response.fields?["receipt_sha256"]?.string,
                  let beatID = response.fields?["beat_id"]?.string else {
                throw G3StoreError.blocked("S22 4K staging thất bại")
            }
            let videoPub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: video),
                artifactType: "g5_captioned_cfr_4k", expectedSHA256: videoSHA,
                // (P1-01) 4K captioned video + conform receipt.
                expectedPublicationCount: 2
            )
            let receiptPub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: receipt),
                artifactType: "g5_conform_receipt", expectedSHA256: receiptSHA
            )
            var items = try G3JSONValue.parse(asset4KJSON).elements ?? []
            items.removeAll { $0.fields?["beat_id"]?.string == beatID }
            items.append(.object([
                "beat_id": .string(beatID),
                "publication_id": .string(videoPub.publicationId.uuidString),
                "receipt_publication_id": .string(receiptPub.publicationId.uuidString),
            ]))
            // (P1-54) remember the validated `g2_source_mapping` publication
            if let mappingField = (try? G3JSONValue.parse(stage4KJSON))?.fields?["mapping_publication_id"]?.string,
               mappingField.count == 36 {
                state.latestG2MappingPublicationId = mappingField
            }
            asset4KJSON = G3JSONValue.array(items).json
            resultText = "S08 đã commit G5 4K beat artifacts: \(beatID)"
        } catch {
            resultText = "G5 4K stage/S08 thất bại: \(error.localizedDescription)"
        }
    }

    private func publishFinalAndDRP() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let (store, publisher, projectID, _) = try environment()
            guard !finalReceiptJSON.isEmpty else {
                throw G3StoreError.blocked("Chạy 4K render inspect trước khi publish")
            }
            let mp4Pub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: finalPath),
                artifactType: "g5_final_mp4", expectedSHA256: finalSHA,
                // (P1-01) final MP4 + provenance (.drp or native receipt) = 2 artifacts.
                expectedPublicationCount: 2
            )
            // Provenance slot: either a Resolve .drp archive or the ffmpeg
            // native render receipt. The S22 guard verifies whichever it finds.
            let provenanceType = drpPath.hasSuffix(".drp") ? "g5_handoff_drp" : "g5_native_receipt"
            let drpPub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: drpPath),
                artifactType: provenanceType, expectedSHA256: drpSHA
            )
            finalPubID = mp4Pub.publicationId
            drpPubID = drpPub.publicationId
            resultText = "S08 đã commit Final 4K MP4 (\(mp4Pub.publicationId)) và provenance (\(drpPub.publicationId))"
        } catch {
            resultText = "Final 4K publication blocked: \(error.localizedDescription)"
        }
    }

    private func approveFinal() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let (store, _, projectID, _) = try environment()
            guard let mp4ID = finalPubID, let drpID = drpPubID else {
                throw G3StoreError.blocked("Final 4K MP4 và DRP phải được commit qua S08")
            }
            let approved = try await store.approveG5Final(
                projectId: projectID,
                finalPublicationId: mp4ID,
                drpPublicationId: drpID,
                receiptJSON: finalReceiptJSON,
                reviewedBy: NSUserName(),
                reviewNotes: reviewNotes,
                watchedFull4KAndVerifiedCaptionsAndAudio: reviewed4K
            )
            state.latestG5PublicationId = mp4ID.uuidString
            reviewed4K = false
            resultText = "Canonical S22 Final 4K Approval: \(approved.approvalId.uuidString)\nFinal SHA: \(approved.finalSHA256)"
        } catch {
            resultText = "G5 final approval blocked: \(error.localizedDescription)"
        }
    }

    private func forkManualHandoff() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let (store, publisher, projectID, _) = try environment()
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: "g5.handoff.fork", params: try requestParams(), timeoutSeconds: 300
            )
            guard response.fields?["status"]?.string == "MANUAL_HANDOFF_BRANCH_CREATED",
                  let branchObj = response.fields?["branch"],
                  let drpFile = branchObj.fields?["handoff_drp_path"]?.string,
                  let drpHash = branchObj.fields?["handoff_drp_sha256"]?.string else {
                throw G3StoreError.blocked("Tạo manual handoff branch thất bại")
            }
            let pub = try await publisher.publishG4File(
                store: store, projectId: projectID,
                source: URL(fileURLWithPath: drpFile),
                artifactType: "g5_manual_handoff_drp", expectedSHA256: drpHash
            )
            let recorded = try await store.recordG5ManualHandoffBranch(
                projectId: projectID,
                handoffDrpPublicationId: pub.publicationId,
                branchReceiptJSON: branchObj.json,
                createdBy: NSUserName()
            )
            resultText = "Manual Handoff Branch đã commit: \(recorded.handoffProjectName) (\(recorded.branchId))"
        } catch {
            resultText = "Manual handoff fork blocked: \(error.localizedDescription)"
        }
    }

    private func managePreferences(action: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let params: G3JSONValue = .object(["action": .string(action)])
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: "g5.preferences.manage", params: params, timeoutSeconds: 30
            )
            resultText = response.json
        } catch {
            resultText = "Preferences RPC failed: \(error.localizedDescription)"
        }
    }

    /// S26 asks the worker for the release handover manifest. It names the gate the
    /// evidence describes, so a manifest can never be read as "S25 passed" by accident:
    /// this UI has no real S25 fault run to offer, so it explicitly reports `no_real_fault_run`.
    private func sendReleaseManifest() async {
        let fields: [String: G3JSONValue] = [
            "s25_evidence_status": .string("no_real_fault_run_available"),
        ]
        isBusy = true
        defer { isBusy = false }
        do {
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: "g5.release.manifest",
                params: G3JSONValue.object(fields),
                timeoutSeconds: 120
            )
            resultText = response.json
        } catch {
            resultText = "Lỗi: \(error.localizedDescription)"
        }
    }

    private func runSimpleRPC(_ method: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response: G3JSONValue = try await state.worker.sendRequest(
                method: method, params: G3JSONValue.object([:]), timeoutSeconds: 120
            )
            resultText = response.json
        } catch {
            resultText = "\(method) failed: \(error.localizedDescription)"
        }
    }
}
