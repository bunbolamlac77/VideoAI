//
// ScriptBriefView.swift — Bước 1: "Khoảnh khắc cần có cho người viết kịch bản".
//
// ONE box. The required part is the must-have moments of the day — the best
// frames the clip must contain ("trao nhẫn, mẹ chải tóc, lì xì"). Couple, time,
// venue, POV, style, platform are optional: the person may write them in the
// same box as "Nhãn: …" lines, or open "Chi tiết" for a few prefilled rows that
// are appended to the box. There is no second form and nothing else to fill.
//
// Saved by ProjectStore through AppState+ScriptBrief; G2 parses the composed
// text and G3 reads the stored revision back.
//

import SwiftUI

struct ScriptBriefCard: View {
    @EnvironmentObject var state: AppState
    @FocusState private var boxFocused: Bool
    @State private var isExpanded = true
    @State private var showDetails = false
    /// Once the user opens/closes the card by hand, stop auto-adjusting it.
    @State private var userToggled = false

    private var draft: ScriptBriefRecord.BoxParse { state.briefDraft }
    private var filledCount: Int { draft.fields.count }

    private var statusColor: Color {
        if state.briefSaveStatus.hasPrefix("Đã lưu") { return .green }
        if state.briefSaveStatus.hasPrefix("Đang lưu") { return .blue }
        if state.briefSaveStatus.hasPrefix("Lỗi") { return .red }
        return .orange
    }

    /// One-line digest shown when the card is collapsed.
    private var summaryLine: String {
        let raw = state.briefRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "Chưa có dữ kiện — bấm Mở rộng để ghi khoảnh khắc đẹp nhất cần có (trao nhẫn, mẹ chải tóc, lì xì…)."
        }
        let moments = state.currentBriefDraft.mustHave
        return moments.isEmpty ? raw : "Khoảnh khắc cần có: \(moments)"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header

                if isExpanded {
                    form
                } else {
                    Text(summaryLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .onAppear {
            isExpanded = state.mediaItems.isEmpty && state.currentBriefDraft.isBlank
        }
        .onChange(of: state.mediaItems.count) { _, _ in
            guard !userToggled, !state.mediaItems.isEmpty, state.currentBriefDraft.isBlank else { return }
            isExpanded = false
        }
        .onChange(of: state.briefRawText) { _, _ in
            state.scheduleBriefAutosave()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Khoảnh khắc cần có cho người viết kịch bản", systemImage: "sparkles.rectangle.stack")
                .font(.headline)

            Spacer()

            StatusPill(text: state.briefSaveStatus, color: statusColor)
            if filledCount > 0 {
                Text("\(filledCount) mục tự nhận")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Các dòng có nhãn như “Cặp đôi:”, “Địa điểm:” được tự tách ra cho người viết kịch bản.")
            }

            Button(isExpanded ? "Thu gọn" : "Mở rộng") {
                userToggled = true
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .help(isExpanded ? "Ẩn ô ghi để xem danh sách tư liệu" : "Hiện ô ghi khoảnh khắc cần có")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Khoảnh khắc đẹp nhất cần có")
                    .font(.caption.weight(.semibold))
                Text("bắt buộc")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.brandTeal.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.brandTeal)
                Spacer()
                if !state.briefHasMustHave {
                    Label("Chưa ghi — người viết kịch bản chưa biết cảnh nào phải có", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            ZStack(alignment: .topLeading) {
                if state.briefRawText.isEmpty {
                    Text("Cảnh bắt buộc: trao nhẫn, mẹ chải tóc, lì xì\n\nDòng khác nếu muốn (tuỳ chọn):\nCặp đôi: Ngọc Hân & Quốc Tài\nNgày giờ: 20/10 · 5h30 xuất phát\nĐịa điểm: Tư gia Q7 · White Palace\nGóc POV: Thợ ảnh đi cùng ekip từ 5h sáng\nPhong cách: Vui nhộn\nNền tảng: TikTok · 60 giây")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $state.briefRawText)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96, maxHeight: 200)
                    .focused($boxFocused)
            }
            .padding(4)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        state.briefHasMustHave ? Color.primary.opacity(0.08) : Color.orange.opacity(0.45)
                    )
            )
            .onDrop(of: [.plainText, .text], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    Task { @MainActor in
                        Self.insert(text, into: state)
                    }
                }
                return true
            }
            .help("Gõ hoặc dán thẳng dữ kiện (vd. tin nhắn khách gửi) — các dòng có nhãn được tự tách.")

            detailsSection

            footer
        }
    }

    /// Optional fields live behind one disclosure and write into the same box.
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
            } label: {
                Label(showDetails ? "Ẩn chi tiết tuỳ chọn" : "Chi tiết tuỳ chọn (cặp đôi, lịch, địa điểm, phong cách…)",
                      systemImage: showDetails ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .controlSize(.small)

            if showDetails {
                VStack(alignment: .leading, spacing: 8) {
                    optionalRow("Cặp đôi", "Ngọc Hân & Quốc Tài", key: "couple")
                    optionalRow("Ngày giờ", "20/10 · 5h30 xuất phát · 11h gia tiên", key: "schedule")
                    optionalRow("Địa điểm", "Tư gia Q7 · Nhà thờ Đức Bà · White Palace", key: "venues")
                    optionalRow("Góc POV", "Thợ ảnh đi cùng ekip từ 5h sáng", key: "povRole")
                    optionalRow("Cần tránh", "khách chưa xin phép, cảnh say rượu", key: "mustAvoid")
                    optionalRow("Phong cách", "Vui nhộn", key: "style")
                    optionalRow("Nền tảng · thời lượng", "TikTok · 60 giây", key: "platform")
                }
                .padding(.leading, 12)
            }
        }
    }

    /// One optional field: empty until the box has the line; typing writes the
    /// matching "Nhãn: …" line into the box instead of keeping a second copy.
    private func optionalRow(_ label: String, _ placeholder: String, key: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            TextField(placeholder, text: Binding(
                get: { draft.fields[key]?.value ?? "" },
                set: { newValue in
                    Self.setOptional(key: key, label: label, value: newValue, state: state)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Tự động lưu trước khi phân tích video. Dòng không có nhãn được gửi nguyên văn cho người viết kịch bản.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                Task {
                    if await state.saveScriptBrief() {
                        userToggled = true
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded = false }
                    }
                }
            } label: {
                Label("Lưu dữ kiện", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(state.projectStore == nil || state.currentBriefDraft.isBlank)
            .help("Lưu vào cơ sở dữ liệu dự án (kèm revision để kịch bản trích dẫn)")
        }
    }

    // MARK: - Box editing helpers

    /// Replaces (or appends) the "Nhãn: …" line for `key`. Empty value removes it.
    static func setOptional(key: String, label: String, value: String, state: AppState) {
        var lines = state.briefRawText.components(separatedBy: .newlines)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = lines.firstIndex {
            ScriptBriefRecord.assigned($0.trimmingCharacters(in: .whitespaces))?.key == key
        }
        if trimmed.isEmpty {
            guard let index else { return }
            lines.remove(at: index)
        } else {
            let line = "\(label): \(trimmed)"
            if let index {
                lines[index] = line
            } else {
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.removeLast()
                }
                lines.append(line)
            }
        }
        state.briefRawText = lines.joined(separator: "\n")
    }

    /// Drops pasted text into the box; keeps the required line discoverable when
    /// the paste carries no label at all.
    static func insert(_ text: String, into state: AppState) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = ScriptBriefRecord.parseBox(trimmed)
        let labelled = parsed.extraLines.count == 0 || parsed.fields.isEmpty == false
        let body = labelled ? trimmed : "Cảnh bắt buộc: \(trimmed)"
        let current = state.briefRawText
        state.briefRawText = current.isEmpty ? body : current + "\n" + body
    }
}

/// Read-only wedding facts shown in Step 2 (G3) so the script is written from
/// the brief, not from memory.
struct ScriptBriefSummaryCard: View {
    @EnvironmentObject var state: AppState

    private var brief: ScriptBriefRecord? {
        state.latestScriptBrief
    }

    var body: some View {
        Card(title: "Khoảnh khắc cần có từ Bước 1", symbol: "sparkles.rectangle.stack") {
            if let brief {
                VStack(alignment: .leading, spacing: 8) {
                    KeyValueRow(
                        key: "Cảnh bắt buộc",
                        value: brief.mustHave.isEmpty ? "— (chưa ghi)" : brief.mustHave
                    )
                    if let parse = optional(brief), !parse.lines.isEmpty {
                        Text(parse.lines.joined(separator: "\n"))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let raw = optional(brief), !raw.lines.isEmpty {
                        DisclosureGroup("Đúng như bạn đã ghi") {
                            Text(raw.lines.joined(separator: "\n"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                    HStack {
                        Text("Revision \(brief.briefRevisionId.uuidString.prefix(8)) · \(brief.updatedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Sửa ở Bước 1") { state.navigateToSection(.media) }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(Color.brandTeal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chưa có dữ kiện")
                            .font(.callout.weight(.semibold))
                        Text("Quay lại Bước 1 và ghi khoảnh khắc đẹp nhất cần có — chỉ một ô duy nhất.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Điền dữ kiện") { state.navigateToSection(.media) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    /// Brief text minus the must-have line (shown above).
    private func optional(_ brief: ScriptBriefRecord) -> ScriptBriefRecord.BoxParse? {
        guard !brief.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ScriptBriefRecord.parseBox(brief.rawText)
    }
}
