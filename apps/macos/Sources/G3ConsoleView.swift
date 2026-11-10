// G3ConsoleView.swift — Gate G3 (S16..S19) Dedicated Form Console.
// Story Generation, Revision, VieNeu-TTS Voice Trial, SEARCH-v1 Cut Search & Canonical Approval.
// Approval is always committed by ProjectStore actor, never the Python worker.

import Foundation
import SwiftUI
import AppKit

indirect enum G3JSONValue: Codable, Sendable {
    case string(String)
    case integer(Int)
    case decimal(Double)
    case bool(Bool)
    case array([G3JSONValue])
    case object([String: G3JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .integer(v)
        } else if let v = try? container.decode(Double.self) {
            self = .decimal(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([G3JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try container.decode([String: G3JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .string(let v):
            try container.encode(v)
        case .integer(let v):
            try container.encode(v)
        case .decimal(let v):
            try container.encode(v)
        case .bool(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }

    static func parse(_ raw: String) throws -> G3JSONValue {
        try JSONDecoder().decode(G3JSONValue.self, from: Data(raw.utf8))
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]

        guard let data = try? encoder.encode(self) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    var fields: [String: G3JSONValue]? {
        if case let .object(v) = self {
            return v
        }
        return nil
    }

    var string: String? {
        if case let .string(v) = self {
            return v
        }
        return nil
    }

    var elements: [G3JSONValue]? {
        if case let .array(v) = self {
            return v
        }
        return nil
    }
}

struct G3BeatItem: Identifiable, Hashable {
    var id: String { beatId }
    var beatId: String
    var voiceText: String
    var claimId: String?
}

@MainActor
struct G3ConsoleView: View {
    @ObservedObject var state: AppState

    // S16 Story Form State
    @State private var scopeRevisionId: String = "scope-g2-main"
    @State private var storyTopic: String = "Chuyến đi thực tế"
    @State private var storyTone: String = "pov_tu_nhien"
    @State private var targetSeconds: Int = 30
    @State private var customClaimText: String = "Tôi đã đến địa điểm này và trải nghiệm thực tế."
    @State private var editBeatId: String = "beat-01"
    @State private var editVoiceText: String = ""

    // S17 TTS Voice Form State
    @State private var voiceModelChoice: String = "nu_mien_bac"
    @State private var voiceTrialBeatId: String = "beat-01"
    @State private var voiceSpeed: Double = 1.0
    @State private var voiceBeatId: String = "beat-01"
    @State private var voicePublicationId: String = ""
    @State private var reviewedVoiceSHA256: String = ""
    @State private var listenedToVoice: Bool = false

    // S18 Cut Search Form State
    @State private var beamWidth: Int = 4
    @State private var nodeBudget: Int = 500
    @State private var forwardCheck: Bool = true
    @State private var pacingStyle: String = "balanced"

    // Raw JSON bindings maintained for full backward compatibility
    @State private var storyRequest: String = """
        {
          "evidence_scope_revision_id": "scope-g2-main",
          "claims": [],
          "shots": [],
          "constraints": {
            "must_use": [],
            "must_not_use": [],
            "preferred": []
          }
        }
        """
    @State private var editRequest: String = "{}"
    @State private var voiceRequest: String = "{}"
    @State private var searchRequest: String = "{}"
    @State private var cutStageRequest: String = "{}"
    @State private var proposalRequest: String = "{}"

    @State private var draftJSON: String = ""
    @State private var lastProposal: String = ""
    @State private var output: String = "Chưa có G3 RPC nào chạy."

    @State private var saved: G3StoredDraft?
    @State private var selected: Bool = false
    @State private var explicitApproval: Bool = false
    @State private var isBusy: Bool = false
    @State private var showRawJSON: Bool = false

    var parsedBeats: [G3BeatItem] {
        guard let obj = try? G3JSONValue.parse(draftJSON),
              let beats = obj.fields?["beats"]?.elements else { return [] }
        return beats.compactMap { b in
            guard let bid = b.fields?["beat_id"]?.string,
                  let text = b.fields?["voice_text"]?.string else { return nil }
            let claim = b.fields?["claim_id"]?.string
            return G3BeatItem(beatId: bid, voiceText: text, claimId: claim)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header notice
            HStack(spacing: 10) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(Color.brandTeal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("G3 — Kịch bản, VieNeu-TTS, Cut Search & Phê duyệt S19")
                        .font(.headline)
                    Text("Chỉ sử dụng claim và evidence đã xác thực từ G2. Mọi kịch bản bắt buộc qua cổng S19 Approval Guard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.brandTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Form 1: S16 — Story Generation & Revision
            Card(title: "1. S16 — Tạo kịch bản có nguồn & Hiệu chỉnh", symbol: "pencil.line") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Evidence Scope Revision ID").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("scope-g2-main", text: $scopeRevisionId)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: 180)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chủ đề / Góc nhìn").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("Chuyến đi Đà Lạt, Trải nghiệm ẩm thực...", text: $storyTopic)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Phong cách (Tone)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Picker("", selection: $storyTone) {
                                Text("POV Tự nhiên").tag("pov_tu_nhien")
                                Text("Hài hước / Sôi nổi").tag("hai_huoc")
                                Text("Trầm tĩnh / Trải nghiệm").tag("tram_tinh")
                                Text("Hướng dẫn / Du ký").tag("huong_dan")
                            }
                            .pickerStyle(.menu)
                        }
                        .frame(maxWidth: 160)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thời lượng mục tiêu").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Picker("", selection: $targetSeconds) {
                                Text("30 giây").tag(30)
                                Text("45 giây").tag(45)
                                Text("60 giây").tag(60)
                            }
                            .pickerStyle(.segmented)
                        }
                        .frame(maxWidth: 160)
                    }

                    // Fact claim binding
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fact Claim nguồn (từ G1/G2)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("Nội dung fact claim cần đối chiếu...", text: $customClaimText)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 10) {
                        Button {
                            buildAndSendStoryRequest()
                        } label: {
                            HStack(spacing: 6) {
                                if isBusy { ProgressView().controlSize(.small) }
                                Image(systemName: "sparkles")
                                Text("Tạo kịch bản từ Claim đã kiểm chứng")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !state.isWorkerConnected)

                        Spacer()
                    }

                    Divider()

                    // Candidate Beats Inspector
                    if !parsedBeats.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Các đoạn Beat kịch bản sinh ra (\(parsedBeats.count))").font(.subheadline.weight(.semibold))
                            ForEach(parsedBeats) { beat in
                                HStack(alignment: .top, spacing: 10) {
                                    StatusPill(text: beat.beatId, color: .brandTeal)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(beat.voiceText).font(.callout)
                                        if let c = beat.claimId {
                                            Text("Claim: \(c)").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Sửa câu này") {
                                        editBeatId = beat.beatId
                                        editVoiceText = beat.voiceText
                                    }
                                    .controlSize(.small)
                                }
                                .padding(8)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }

                    // Inline Beat Editing Form
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hiệu chỉnh lời thoại Beat (S16 Edit)").font(.subheadline.weight(.semibold))
                        HStack(spacing: 10) {
                            TextField("Beat ID", text: $editBeatId).frame(width: 90).textFieldStyle(.roundedBorder)
                            TextField("Lời thoại mới cần thay đổi...", text: $editVoiceText).textFieldStyle(.roundedBorder)
                            Button("Sửa câu & tạo revision") {
                                buildAndSendEditRequest()
                            }
                            .buttonStyle(.bordered)
                            .disabled(isBusy || editVoiceText.isEmpty)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    // Revision Actions
                    HStack(spacing: 12) {
                        Button("Lưu revision bất biến vào SQLite") {
                            Task { await saveDraft() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || draftJSON.isEmpty)

                        Button("Chọn revision hiện tại") {
                            Task { await selectDraft() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || saved == nil)

                        Text(selected ? "Trạng thái: Đã chọn (chưa duyệt)" : "Trạng thái: Chưa chọn")
                            .font(.caption)
                            .foregroundStyle(selected ? Color.brandTeal : Color.secondary)
                    }
                }
            }

            // Form 2: S17 — VieNeu-TTS Voice Synthesis & Speech Review
            Card(title: "2. S17 — VieNeu-TTS Offline & Speech Review", symbol: "waveform") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Giọng đọc VieNeu-TTS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Picker("", selection: $voiceModelChoice) {
                                Text("Nữ miền Bắc (Chuẩn)").tag("nu_mien_bac")
                                Text("Nam miền Bắc").tag("nam_mien_bac")
                                Text("Nữ miền Nam").tag("nu_mien_nam")
                                Text("Nam miền Nam").tag("nam_mien_nam")
                            }
                            .pickerStyle(.menu)
                        }
                        .frame(maxWidth: 180)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Beat cần tạo WAV").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("beat-01", text: $voiceTrialBeatId)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: 120)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tốc độ: \(String(format: "%.1fx", voiceSpeed))").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Slider(value: $voiceSpeed, in: 0.8...1.2, step: 0.05)
                        }
                        .frame(maxWidth: 160)

                        Button("Tạo WAV 48 kHz") {
                            buildAndSendVoiceTrial()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !state.isWorkerConnected)
                    }

                    Divider()

                    // Speech Review verification
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Xác nhận đã nghe WAV (S08 Artifact)").font(.subheadline.weight(.semibold))
                        HStack(spacing: 10) {
                            TextField("Beat ID", text: $voiceBeatId).frame(width: 90).textFieldStyle(.roundedBorder)
                            TextField("Publication UUID từ S08", text: $voicePublicationId).textFieldStyle(.roundedBorder)
                            TextField("SHA-256 WAV (64 ký tự hex)", text: $reviewedVoiceSHA256).textFieldStyle(.roundedBorder)
                        }

                        Toggle("Tôi đã trực tiếp nghe toàn bộ WAV, kiểm từ ngữ, số liệu, tên riêng và nhịp điệu", isOn: $listenedToVoice)
                            .font(.callout)

                        Button("Ghi nhận Speech Review vào SQLite") {
                            Task { await registerVoiceReview() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !listenedToVoice || saved == nil || reviewedVoiceSHA256.count != 64)
                    }
                }
            }

            // Form 3: S18 — SEARCH-v1 Cut Search
            Card(title: "3. S18 — SEARCH-v1 Cut Selection & Staging", symbol: "scissors") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            Text("Beam Width:").font(.callout)
                            Stepper("\(beamWidth)", value: $beamWidth, in: 1...8)
                                .monospacedDigit()
                        }

                        HStack(spacing: 6) {
                            Text("Node Budget:").font(.callout)
                            Stepper("\(nodeBudget)", value: $nodeBudget, in: 100...2000, step: 100)
                                .monospacedDigit()
                        }

                        Toggle("Forward Check", isOn: $forwardCheck)
                            .font(.callout)

                        Picker("Nhịp cắt", selection: $pacingStyle) {
                            Text("Cân bằng").tag("balanced")
                            Text("Nhanh").tag("dynamic")
                            Text("Cinematic").tag("cinematic")
                        }
                        .frame(maxWidth: 140)
                    }

                    HStack(spacing: 12) {
                        Button("Tìm Cut hợp lệ (SEARCH-v1)") {
                            buildAndSendCutSearch()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected)

                        Button("Stage Cut Plan để S08 Publish") {
                            buildAndSendCutStage()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected)
                    }
                }
            }

            // Form 4: S19 — Đề nghị duyệt / Phê duyệt kịch bản (Approval Guard)
            Card(title: "4. S19 — Đề nghị duyệt & Phê duyệt Script", symbol: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Button("Kiểm tra Manifest đề nghị duyệt") {
                            buildAndSendProposal()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !state.isWorkerConnected || saved == nil)

                        if !lastProposal.isEmpty {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Manifest đề xuất sẵn sàng").font(.caption)
                        }
                    }

                    Toggle("Tôi đã đối chiếu toàn bộ story, evidence, WAV âm thanh và cut của bản revision đang chọn", isOn: $explicitApproval)
                        .font(.callout)

                    Button {
                        Task { await approve() }
                    } label: {
                        HStack(spacing: 8) {
                            if isBusy { ProgressView().controlSize(.small) }
                            Image(systemName: "checkmark.circle.fill")
                            Text("Duyệt kịch bản trong SQLite (S19 Guard)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy || !explicitApproval || !selected || saved == nil || lastProposal.isEmpty)
                }
            }

            // Collapsible Developer Section for Raw JSON
            DisclosureGroup(isExpanded: $showRawJSON) {
                VStack(alignment: .leading, spacing: 8) {
                    jsonEditor("Tham số story (JSON)", text: $storyRequest, height: 75)
                    jsonEditor("Script revision JSON", text: $draftJSON, height: 85)
                    jsonEditor("Đề xuất sửa câu (JSON)", text: $editRequest, height: 65)
                    jsonEditor("Voice trial JSON", text: $voiceRequest, height: 65)
                    jsonEditor("SEARCH-v1 JSON", text: $searchRequest, height: 65)
                    jsonEditor("Cut plan staging JSON", text: $cutStageRequest, height: 65)
                    jsonEditor("Proposal JSON", text: $proposalRequest, height: 75)
                }
                .padding(.top, 4)
            } label: {
                Text("Nâng cao: Xem & Chỉnh sửa JSON thô (Developer / Debug)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Log Console
            Card(title: "Nhật ký G3 / Kết quả RPC", symbol: "terminal") {
                ScrollView {
                    Text(output)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 60, maxHeight: 120)
            }
        }
        .padding(.vertical, 4)
    }

    private func buildAndSendStoryRequest() {
        let cid = "c1"
        let factObj: [String: G3JSONValue] = [
            "claim_id": .string(cid),
            "revision_id": .string("rev-\(cid)"),
            "text": .string(customClaimText),
            "origin": .string("user"),
            "epistemic_status": .string("reported"),
            "review_status": .string("confirmed"),
            "support_status": .string("supported"),
            "allowed_use": .string("attributed_or_qualified"),
            "scope_revalidation_status": .string("complete"),
            "evidence_scope_revision_id": .string(scopeRevisionId)
        ]
        let obj: [String: G3JSONValue] = [
            "evidence_scope_revision_id": .string(scopeRevisionId),
            "claims": .array([.object(factObj)]),
            "shots": .array([]),
            "constraints": .object([
                "tone": .string(storyTone),
                "target_seconds": .integer(targetSeconds),
                "must_use": .array([]),
                "must_not_use": .array([]),
                "preferred": .array([])
            ])
        ]
        storyRequest = G3JSONValue.object(obj).json

        Task {
            await rpc(method: "g3.story.generate", json: storyRequest) { result in
                if let first = result.fields?["candidates"]?.elements?.first {
                    draftJSON = first.json
                    saved = nil
                    selected = false
                    lastProposal = ""
                    explicitApproval = false
                }
            }
        }
    }

    private func buildAndSendEditRequest() {
        let obj: [String: G3JSONValue] = [
            "candidate": (try? G3JSONValue.parse(draftJSON)) ?? .object([:]),
            "beat_id": .string(editBeatId),
            "new_voice_text": .string(editVoiceText)
        ]
        editRequest = G3JSONValue.object(obj).json

        Task {
            await rpc(method: "g3.story.edit", json: editRequest) { result in
                if let edited = result.fields?["candidate"] {
                    draftJSON = edited.json
                }
                saved = nil
                selected = false
                lastProposal = ""
                explicitApproval = false
            }
        }
    }

    private func buildAndSendVoiceTrial() {
        let obj: [String: G3JSONValue] = [
            "beat_id": .string(voiceTrialBeatId),
            "voice_id": .string(voiceModelChoice),
            "speed": .decimal(voiceSpeed),
            "text": .string(parsedBeats.first(where: { $0.beatId == voiceTrialBeatId })?.voiceText ?? "Kiểm tra giọng đọc tiếng Việt offline.")
        ]
        voiceRequest = G3JSONValue.object(obj).json

        Task {
            await rpc(method: "g3.voice.trial", json: voiceRequest) { _ in }
        }
    }

    private func buildAndSendCutSearch() {
        let obj: [String: G3JSONValue] = [
            "candidate_options": .array([]),
            "voice_samples_per_beat": .array([.integer(48000)]),
            "voice_review_status": .string("verified"),
            "voice_wav_published": .bool(true),
            "beam_width": .integer(beamWidth),
            "node_budget": .integer(nodeBudget),
            "forward_check": .bool(forwardCheck)
        ]
        searchRequest = G3JSONValue.object(obj).json

        Task {
            await rpc(method: "g3.cut.search", json: searchRequest) { _ in }
        }
    }

    private func buildAndSendCutStage() {
        let obj: [String: G3JSONValue] = [
            "script_revision_id": .string(saved?.scriptRevisionId ?? "rev-01"),
            "pacing": .string(pacingStyle)
        ]
        cutStageRequest = G3JSONValue.object(obj).json

        Task {
            await rpc(method: "g3.cut.stage", json: cutStageRequest) { _ in }
        }
    }

    private func buildAndSendProposal() {
        let obj: [String: G3JSONValue] = [
            "script_revision_id": .string(saved?.scriptRevisionId ?? ""),
            "script": (try? G3JSONValue.parse(draftJSON)) ?? .object([:])
        ]
        proposalRequest = G3JSONValue.object(obj).json

        Task {
            await rpc(method: "g3.approval.propose", json: proposalRequest) { result in
                lastProposal = result.json
                explicitApproval = false
            }
        }
    }

    private func jsonEditor(
        _ label: String,
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: text)
                .font(
                    .system(
                        size: 11,
                        design: .monospaced
                    )
                )
                .frame(height: height)
                .border(
                    Color.secondary.opacity(0.3)
                )
        }
    }

    private func rpc(
        method: String,
        json: String,
        then: @MainActor (G3JSONValue) -> Void
    ) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let params = try G3JSONValue.parse(json)

            guard params.fields != nil else {
                throw G3StoreError.invalidPayload(
                    "RPC params must be a JSON object"
                )
            }

            let result: G3JSONValue = try await
                state.worker.sendRequest(
                    method: method,
                    params: params,
                    timeoutSeconds: (
                        method == "g3.voice.trial"
                        ? 240
                        : 25
                    )
                )

            output = result.json
            then(result)
        } catch {
            output = "[\(method)] \(error.localizedDescription)"
        }
    }

    private func saveDraft() async {
        guard
            let store = state.projectStore,
            let project = state.g1Project,
            let workday = state.g1Workday
        else {
            output = "ProjectStore chưa sẵn sàng"
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let record = try await store.storeG3Draft(
                projectId: project.projectId,
                workdayId: workday.workdayId,
                candidateJSON: draftJSON
            )
            saved = record
            selected = false
            explicitApproval = false
            output = "Đã lưu revision: " + record.scriptRevisionId + ". Chưa duyệt."
        } catch {
            output = error.localizedDescription
        }
    }

    private func selectDraft() async {
        guard
            let store = state.projectStore,
            let project = state.g1Project,
            let record = saved
        else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await store.selectG3Draft(
                projectId: project.projectId,
                scriptRevisionId: record.scriptRevisionId
            )
            selected = true
            output = "Đã chọn bản " + record.scriptRevisionId + "; approval chưa được tạo."
        } catch {
            output = error.localizedDescription
        }
    }

    private func registerVoiceReview() async {
        guard
            let store = state.projectStore,
            let project = state.g1Project,
            let record = saved,
            !voiceBeatId.isEmpty,
            let pub = UUID(uuidString: voicePublicationId),
            reviewedVoiceSHA256.count == 64
        else {
            output = "Thiếu script đã lưu hoặc publication UUID/SHA256 (64 hex)"
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await store.recordG3SpeechReview(
                projectId: project.projectId,
                scriptRevisionId: record.scriptRevisionId,
                beatId: voiceBeatId,
                publicationId: pub,
                expectedSHA256: reviewedVoiceSHA256,
                reviewer: NSUserName()
            )

            listenedToVoice = false
            output = "Đã ghi manual speech review cho WAV " + pub.uuidString + ". Chưa duyệt script."
        } catch {
            output = "Speech review blocked: " + error.localizedDescription
        }
    }

    private func approve() async {
        guard
            let store = state.projectStore,
            let project = state.g1Project,
            let workday = state.g1Workday,
            let record = saved,
            selected
        else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let response = try G3JSONValue.parse(lastProposal)

            guard
                response.fields?["status"]?.string == "ready_for_core_reverification_not_approved",
                let manifest = response.fields?["manifest"]
            else {
                throw G3StoreError.blocked("Worker proposal not eligible")
            }

            let result = try await store.approveG3Draft(
                projectId: project.projectId,
                workdayId: workday.workdayId,
                scriptRevisionId: record.scriptRevisionId,
                expectedCandidateSHA256: record.candidateSHA256,
                manifestJSON: manifest.json,
                approvedBy: NSUserName()
            )

            output = "APPROVED by Swift Core: " + result.approvalId.uuidString + "\nManifest SHA256: " + result.manifestSHA256
            explicitApproval = false
        } catch {
            output = "Approval blocked: " + error.localizedDescription
        }
    }
}
