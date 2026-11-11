//
// AppState+ScriptBrief.swift — Dữ kiện chụp cưới (Bước 1).
//
// The brief is the ONLY human-authored context that reaches G2/G3. It is:
//   * ONE box on the same screen where footage is imported — the person types
//     (or pastes) what matters; the must-have moments ("cảnh bắt buộc") are the
//     required part, everything else is optional;
//   * parsed by `ScriptBriefRecord.parseBox` (labels like "Cặp đôi:", "Địa
//     điểm:", "Cảnh bắt buộc:") so the stored revision still carries structured
//     fields for G3 prefill, while every free line survives verbatim;
//   * persisted by `ProjectStore` (single writer) as a content-addressed
//     revision, so any generated script can cite the exact brief it used;
//   * composed into the worker's `brief_text` as natural Vietnamese sentences,
//     which S13 parses into draft claims/questions with char-span evidence.
//
// Kept out of AppState.swift so both files stay reviewable.
//

import Foundation

@MainActor
extension AppState {
    /// Parsed view of the single box.
    var briefDraft: ScriptBriefRecord.BoxParse {
        ScriptBriefRecord.parseBox(briefRawText)
    }

    /// True once the required "khoảnh khắc đẹp nhất" line is written.
    var briefHasMustHave: Bool { briefDraft.hasMustHave }

    /// Snapshot of the box as the store/worker will see it.
    var currentBriefDraft: ScriptBriefRecord {
        let workdayId = g1Workday?.workdayId ?? UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let projectId = g1Project?.projectId ?? UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let draft = ScriptBriefRecord.make(
            briefRevisionId: UUID(),
            projectId: projectId,
            workdayId: workdayId,
            rawText: briefRawText,
            defaults: latestScriptBrief
        )
        return ScriptBriefRecord(
            briefRevisionId: ScriptBriefRecord.revisionId(workdayId: workdayId, composedText: draft.composedText),
            projectId: projectId,
            workdayId: workdayId,
            rawText: briefRawText,
            coupleNames: draft.coupleNames,
            eventType: draft.eventType,
            schedule: draft.schedule,
            venues: draft.venues,
            povRole: draft.povRole,
            style: draft.style,
            mustHave: draft.mustHave,
            mustAvoid: draft.mustAvoid,
            platform: draft.platform,
            targetSeconds: draft.targetSeconds,
            notes: draft.notes,
            updatedAt: Date()
        )
    }

    /// What G2 receives today. Empty string (never demo text) when the box is empty.
    func composedBriefText() -> String {
        currentBriefDraft.composedText
    }

    /// True when the box differs from the last saved revision.
    var isBriefDirty: Bool {
        guard let saved = latestScriptBrief else {
            return !briefRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return saved.rawText != briefRawText
    }

    /// Loads the latest stored revision into the box (called after store init).
    /// A legacy revision (saved by the old 11-field form) is folded back into
    /// the single box, so the user never loses what they already typed.
    func loadScriptBrief() async {
        guard let store = projectStore, let wd = g1Workday else { return }
        do {
            guard let record = try await store.latestScriptBrief(workdayId: wd.workdayId) else {
                latestScriptBrief = nil
                briefSaveStatus = "Chưa lưu"
                return
            }
            // Never clobber text the user typed before the store finished opening:
            // keep the box, remember the stored revision, let autosave persist it.
            guard briefRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                latestScriptBrief = record
                return
            }
            latestScriptBrief = record
            briefRawText = record.rawText.isEmpty
                ? Self.legacyBriefText(record)
                : record.rawText
            briefSaveStatus = "Đã lưu · \(Self.shortRevision(record.briefRevisionId))"
        } catch {
            briefSaveStatus = "Lỗi đọc brief: \(error.localizedDescription)"
        }
    }

    /// Persists the box through the single-writer store. Saving the same content
    /// twice is a no-op because the revision id is content-addressed.
    @discardableResult
    func saveScriptBrief() async -> Bool {
        guard let store = projectStore, g1Project != nil, g1Workday != nil else {
            briefSaveStatus = "Chưa sẵn sàng cơ sở dữ liệu"
            return false
        }
        let draft = currentBriefDraft
        guard !draft.isBlank else {
            briefSaveStatus = "Chưa có nội dung để lưu"
            return false
        }
        briefSaveStatus = "Đang lưu…"
        do {
            try await store.saveScriptBrief(draft)
            latestScriptBrief = draft
            briefSaveStatus = "Đã lưu · \(Self.shortRevision(draft.briefRevisionId))"
            return true
        } catch {
            briefSaveStatus = "Lỗi lưu: \(error.localizedDescription)"
            return false
        }
    }

    /// Called right before analysis: the brief must exist in SQLite before any
    /// claim/question can point at it.
    func persistBriefIfNeeded() async {
        guard !currentBriefDraft.isBlank else { return }
        if isBriefDirty || latestScriptBrief == nil {
            _ = await saveScriptBrief()
        }
    }

    /// Debounced autosave while typing, so a typed brief is never lost when the
    /// app quits before the user reaches the analysis button.
    func scheduleBriefAutosave() {
        briefAutosaveTask?.cancel()
        briefAutosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.isBriefDirty else { return }
            _ = await self.saveScriptBrief()
        }
    }

    /// Folds an old multi-field revision into the one-box format.
    static func legacyBriefText(_ record: ScriptBriefRecord) -> String {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines: [String] = []
        if !trimmed(record.mustHave).isEmpty { lines.append("Cảnh bắt buộc: \(trimmed(record.mustHave))") }
        if !trimmed(record.coupleNames).isEmpty { lines.append("Cặp đôi: \(trimmed(record.coupleNames))") }
        if !trimmed(record.schedule).isEmpty { lines.append("Ngày giờ: \(trimmed(record.schedule))") }
        if !trimmed(record.venues).isEmpty { lines.append("Địa điểm: \(trimmed(record.venues))") }
        if !trimmed(record.povRole).isEmpty { lines.append("Góc POV: \(trimmed(record.povRole))") }
        if !trimmed(record.mustAvoid).isEmpty { lines.append("Cần tránh: \(trimmed(record.mustAvoid))") }
        if !trimmed(record.style).isEmpty { lines.append("Phong cách: \(ScriptBriefRecord.styleLabel(record.style))") }
        if !trimmed(record.platform).isEmpty {
            lines.append("Nền tảng: \(ScriptBriefRecord.platformLabel(record.platform)) · \(record.targetSeconds) giây")
        }
        if !trimmed(record.notes).isEmpty { lines.append("Ghi chú: \(trimmed(record.notes))") }
        return lines.joined(separator: "\n")
    }

    private static func shortRevision(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
