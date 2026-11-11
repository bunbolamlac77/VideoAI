// G3ConsoleView.swift — Gate G3 (S16..S19) Dedicated Form Console.
// Story Generation, Revision, Kokoro-Vietnamese TTS Voice Trial, SEARCH-v1 Cut Search & Canonical Approval.
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
    /// (P1-49) Measured length of this beat's narration WAV. Cue timing is derived from it;
    /// a nil value means the WAV was not synthesised yet and no cue may claim a duration.
    var voiceSamples: Int?
}

@MainActor
struct G3ConsoleView: View {
    @ObservedObject var state: AppState

    // S16 Story Form State
    // (P0-09) No fabricated default: when empty, the builder derives the scope from the
    // selected claim's own source_revision_id instead of a constant that exists nowhere.
    @State private var scopeRevisionId: String = ""
    @State private var storyTopic: String = ""
    @State private var storyTone: String = "pov_tu_nhien"
    @State private var targetSeconds: Int = 30
    @State private var selectedClaimId: UUID?
    @State private var editBeatId: String = "beat-01"
    @State private var editVoiceText: String = ""

    // S17 TTS Voice Form State
    @State private var voiceModelChoice: String = "nu_mien_bac"
    @State private var voiceTrialBeatId: String = "beat-01"
    @State private var voiceBeatId: String = "beat-01"
    @State private var voicePublicationId: String = ""
    @State private var reviewedVoiceSHA256: String = ""
    @State private var listenedToVoice: Bool = false
    // (P0-07) Reported by `g3.voice.trial`; never asserted by this view. A fresh WAV is
    // always "unverified" until a human listens and S08 publishes it.
    @State private var engineVoiceReviewStatus: String = "unverified"
    @State private var engineVoiceReviewReason: String = ""

    // S18 Cut Search Form State
    @State private var beamWidth: Int = 4
    @State private var nodeBudget: Int = 500
    @State private var forwardCheck: Bool = true
    @State private var pacingStyle: String = "balanced"

    // Raw JSON bindings maintained for full backward compatibility
    @State private var storyRequest: String = """
        {
          "evidence_scope_revision_id": "",
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
    /// Brief from Step 1 is applied once, so later manual edits are never overwritten.
    @State private var didApplyBrief: Bool = false

    /// Prefills the story form from the Step 1 wedding facts: topic from the
    /// couple + ceremony, tone from the shooting style, duration from the
    /// delivery platform. Values the user already typed are never overwritten.
    private func applyBriefDefaultsIfNeeded() {
        guard !didApplyBrief else { return }
        didApplyBrief = true
        guard let brief = state.latestScriptBrief else { return }
        let trimmedTopic = storyTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTopic.isEmpty || trimmedTopic == "Chuyến đi thực tế" {
            storyTopic = brief.topicLine
        }
        if storyTone == "pov_tu_nhien" {
            storyTone = brief.suggestedTone
        }
        targetSeconds = brief.suggestedSeconds
    }

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
            // Scope rule, one line (the page header already carries the title).
            Label(
                "Chỉ dùng claim/evidence đã xác thực từ G2; mọi kịch bản phải qua cổng S19.",
                systemImage: "checkmark.shield"
            )
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)

            // Brief người dùng đã ghi ở Bước 1 — ngữ cảnh gốc cho kịch bản.
            ScriptBriefSummaryCard()
                .task { applyBriefDefaultsIfNeeded() }

            // Form 1: S16 — Story Generation & Revision
            Card(title: "1. S16 — Tạo kịch bản có nguồn & Hiệu chỉnh", symbol: "pencil.line") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Evidence Scope Revision ID").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("(tự lấy từ fact đã chọn)", text: $scopeRevisionId)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: 180)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chủ đề / Góc nhìn").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("Linh & Minh — Lễ vu quy", text: $storyTopic)
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
                                Text("90 giây").tag(90)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        .frame(maxWidth: 130)
                    }

                    // Fact claim binding — only claims that already exist in G1 can be narrated.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Fact Claim nguồn (bắt buộc từ G1/G2)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        if state.g1Claims.isEmpty {
                            Text("Chưa có fact nào trong G1. Hãy chạy phân tích G2 ở Bước 1 để tạo fact có bằng chứng nguồn.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Picker("", selection: $selectedClaimId) {
                                Text("— Chọn một fact —").tag(UUID?.none)
                                ForEach(state.g1Claims) { claim in
                                    Text("\(claim.text.prefix(70)) · \(claim.reviewStatus.rawValue)")
                                        .tag(Optional(claim.claimId))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)

                            if let claim = selectedClaim {
                                HStack(spacing: 8) {
                                    badge(claim.origin.rawValue)
                                    badge(claim.epistemicStatus.rawValue)
                                    badge(claim.reviewStatus.rawValue)
                                    badge(claim.supportStatus.rawValue)
                                    badge(claim.allowedUse.rawValue)
                                }
                                if claim.reviewStatus != .confirmed {
                                    Button("Xác nhận fact này (người dùng xác nhận)") {
                                        confirmSelectedClaim()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
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

            // Form 2: S17 — Kokoro-Vietnamese TTS Synthesis & Speech Review
            Card(title: "2. S17 — Kokoro-Vietnamese Offline & Speech Review", symbol: "waveform") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Giọng đọc Kokoro-Vietnamese").font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
                            Text("Tốc độ: 1.0× (profile khoá)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text("P-TTS-KOKORO-VI-V1 chỉ chấp nhận 1.0×; engine Kokoro-Vietnamese (Apache-2.0) chạy offline trên CPU, nếu thiếu weights worker trả blocked_tts_runtime_unavailable.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 200)

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
                        // (P1-46) a cut plan can only be staged for a stored revision
                        .disabled(isBusy || !state.isWorkerConnected || saved == nil)
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

            if state.isStep2StoryApproved {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kịch bản và các điểm cắt đã được duyệt thành công!")
                                .font(.headline)
                            Text("Approval ID: \(state.latestG3PublicationId.prefix(18))… · Đã tự động chuyển dữ liệu sang Bước 3")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            state.navigateToSection(.preview)
                        } label: {
                            HStack {
                                Text("Tiếp tục sang Bước 3: Xem trước (Preview)")
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
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 60, maxHeight: 120)
            }
        }
        .padding(.vertical, 4)
    }

    private var selectedClaim: ClaimRecord? {
        guard let id = selectedClaimId else { return nil }
        return state.g1Claims.first { $0.claimId == id }
    }

    private func confirmSelectedClaim() {
        guard let store = state.projectStore,
              let workday = state.g1Workday,
              let claim = selectedClaim else { return }
        Task {
            do {
                _ = try await store.confirmFact(
                    claimId: claim.claimId,
                    approvedBy: NSUserName()
                )
                state.g1Claims = try await store.getLatestClaims(workdayId: workday.workdayId)
                output = "Đã xác nhận fact \(claim.claimId.uuidString.prefix(8)) — origin và epistemic status được giữ nguyên."
            } catch {
                output = "Không xác nhận được fact: \(error.localizedDescription)"
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func buildAndSendStoryRequest() {
        guard let claim = selectedClaim else {
            output = "Lỗi: chọn một fact đã có trong G1 trước khi sinh kịch bản."
            return
        }
        guard claim.reviewStatus == .confirmed else {
            output = "Lỗi: fact chưa được xác nhận. Bấm 'Xác nhận fact này' rồi thử lại."
            return
        }
        do {
            storyRequest = try G3StoryRequestBuilder.makeJSON(
                claim: claim,
                // Empty means "use the claim's real evidence scope" (P0-09).
                scopeRevisionId: scopeRevisionId.isEmpty ? nil : scopeRevisionId,
                tone: storyTone,
                targetSeconds: targetSeconds
            )
        } catch {
            output = "Lỗi: \(error.localizedDescription)"
            return
        }

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
        let textToUse = parsedBeats.first(where: { $0.beatId == voiceTrialBeatId })?.voiceText ?? "Kiểm tra giọng đọc tiếng Việt offline."
        let obj: [String: G3JSONValue] = [
            "beat_id": .string(voiceTrialBeatId),
            "voice_id": .string(voiceModelChoice),
            "speed": .decimal(1.0),
            "text": .string(textToUse)
        ]
        voiceRequest = G3JSONValue.object(obj).json

        Task {
            await rpc(method: "g3.voice.trial", json: voiceRequest) { res in
                if let sha = res.fields?["wav"]?.fields?["sha256"]?.string {
                    reviewedVoiceSHA256 = sha
                }
                engineVoiceReviewStatus = res.fields?["voice_review_status"]?.string ?? "unverified"
                engineVoiceReviewReason = res.fields?["voice_review_reason"]?.string ?? ""
                voiceBeatId = voiceTrialBeatId
            }
        }
    }

    private func buildAndSendCutSearch() {
        // (P0-07) Send the engine's real review state. The view never claims "verified":
        // that only happens after the user hears the WAV and S08 publishes it.
        let voiceVerified = engineVoiceReviewStatus == "verified"
        let obj: [String: G3JSONValue] = [
            "candidate_options": .array([]),
            "voice_samples_per_beat": .array([.integer(48000)]),
            "voice_review_status": .string(voiceVerified ? "verified" : "unverified"),
            "voice_wav_published": .bool(voiceVerified),
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
            // (P1-46) Staging needs a real stored revision; `rev-01` was invented and the
            // worker happily staged a cut plan for a script that does not exist.
            "script_revision_id": .string(saved?.scriptRevisionId ?? ""),
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
            output = "Lỗi: Chưa mở project hoặc chưa lưu bản nháp script để chọn."
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
            // (P0-07) A recorded review is still not "verified" for S18 until S08 has
            // published exactly the WAV the reviewer heard with the same SHA-256.
            if engineVoiceReviewStatus != "verified", reviewedVoiceSHA256.count == 64 {
                engineVoiceReviewReason = engineVoiceReviewReason.isEmpty
                    ? "Chờ S08 publish WAV đã nghe trước khi coi là verified"
                    : engineVoiceReviewReason
            }
        } catch {
            output = "Speech review blocked: " + error.localizedDescription
        }
    }

    private func approve() async {
        guard
            let store = state.projectStore,
            let project = state.g1Project,
            let workday = state.g1Workday
        else {
            output = "Lỗi: Chưa mở project/workday trong tab Dự án (ProjectStore chưa sẵn sàng)."
            return
        }

        guard let record = saved, selected else {
            output = "Lỗi: Cần lưu và chọn bản nháp script (selected=true) trước khi phê duyệt."
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

            state.syncApprovedStoryToBeatsAndCues(beats: parsedBeats, publicationId: result.approvalId.uuidString)
            output = "APPROVED by Swift Core: " + result.approvalId.uuidString + "\nManifest SHA256: " + result.manifestSHA256
            explicitApproval = false
        } catch {
            output = "Approval blocked: " + error.localizedDescription
        }
    }
}
