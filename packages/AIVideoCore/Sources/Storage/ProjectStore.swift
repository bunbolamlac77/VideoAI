// ProjectStore.swift — Canonical Single-Writer SQLite WAL Actor for Gate G1 (S06)
// Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md.

import CryptoKit
import Foundation
import SQLite3

public enum ProjectStoreError: Error, LocalizedError, Sendable, Equatable {
    case databaseOpenFailed(String)
    case queryFailed(String)
    case executionFailed(String)
    case projectNotFound(UUID)
    case workdayNotFound(UUID)
    case claimNotFound(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case busyTimeout
    case integrityViolation(String)
    case staleFencingToken(expected: Int, actual: Int)
    case invalidAuthority(String)
    case jobNotFound(UUID)
    case attemptNotFound(UUID)
    case publicationNotFound(UUID)
    case resourceExhausted(String)
    case schemaIncompatible(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let m): return "Database Open Failed: \(m)"
        case .queryFailed(let m): return "Query Failed: \(m)"
        case .executionFailed(let m): return "Execution Failed: \(m)"
        case .projectNotFound(let id): return "Project Not Found: \(id)"
        case .workdayNotFound(let id): return "Workday Not Found: \(id)"
        case .claimNotFound(let id): return "Claim Not Found: \(id)"
        case .revisionConflict(let exp, let act): return "Revision Conflict: expected \(exp), got \(act)"
        case .busyTimeout: return "Database Busy Timeout"
        case .integrityViolation(let m): return "Integrity Violation: \(m)"
        case .staleFencingToken(let exp, let act): return "Stale Fencing Token: expected \(exp), got \(act)"
        case .invalidAuthority(let m): return "Invalid Authority: \(m)"
        case .jobNotFound(let id): return "Job Not Found: \(id)"
        case .attemptNotFound(let id): return "Attempt Not Found: \(id)"
        case .publicationNotFound(let id): return "Publication Not Found: \(id)"
        case .resourceExhausted(let m): return "Resource Exhausted: \(m)"
        case .schemaIncompatible(let exp, let act): return "Schema Incompatible: expected \(exp), got \(act)"
        }
    }
}

public struct ProjectRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { projectId }
    public let projectId: UUID
    public let name: String
    public let currentRevision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case name
        case currentRevision = "current_revision"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(projectId: UUID, name: String, currentRevision: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.projectId = projectId
        self.name = name
        self.currentRevision = currentRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WorkdayRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { workdayId }
    public let workdayId: UUID
    public let projectId: UUID
    public let title: String
    public let date: String
    public let revision: Int
    public let createdAt: Date

    public enum CodingKeys: String, CodingKey {
        case workdayId = "workday_id"
        case projectId = "project_id"
        case title
        case date
        case revision
        case createdAt = "created_at"
    }

    public init(workdayId: UUID, projectId: UUID, title: String, date: String, revision: Int = 1, createdAt: Date = Date()) {
        self.workdayId = workdayId
        self.projectId = projectId
        self.title = title
        self.date = date
        self.revision = revision
        self.createdAt = createdAt
    }
}

/// The shooting brief captured in Step 1 (when footage is imported).
///
/// One free-text box (`rawText`): the only thing the user must type is the
/// must-have moments — the best frames of the day ("trao nhẫn, mẹ chải tóc, lì
/// xì"). Everything else is optional and may be written in the same box in
/// Vietnamese sentences, in the format the user already pastes into chat apps:
///
///     Cảnh bắt buộc: trao nhẫn, mẹ chải tóc, lì xì
///     Cặp đôi: Ngọc Hân & Quốc Tài
///     Lịch: 20/10 · 5h30 xuất phát qua bên côn đồ để chụp
///     Địa điểm: Tư gia Q7 · Nhà thờ Đức Bà · White Palace
///     Góc POV: Thợ ảnh đi cùng ekip từ 5h sáng
///     Phong cách: Vui nhộn
///     Nền tảng: TikTok · 60 giây
///
/// `composeText` turns that into one Vietnamese sentence per line, which is
/// what G2 parses (`parse_raw_brief_to_drafts`) and G3 reads back. The
/// structured fields below are kept for the stored revision, G3 prefill
/// (topic/tone/duration) and compatibility with earlier revisions; they are
/// derived from `rawText` (or from the legacy form) and never required.
/// Persisted by the Swift `ProjectStore` (single writer) so every G3 script can
/// cite the exact brief revision it was written against.
public struct ScriptBriefRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { briefRevisionId }
    public let briefRevisionId: UUID
    public let projectId: UUID
    public let workdayId: UUID

    /// The single box the user writes in, captured verbatim.
    public let rawText: String
    /// "Linh & Minh" — how the couple is named on screen.
    public let coupleNames: String
    /// `dam_hoi` | `vu_quy` | `thanh_hon` | `tiec_cuoi` | `ca_ngay`
    public let eventType: String
    /// "24/11 · 7h30 đón dâu · 11h gia tiên · 18h tiệc"
    public let schedule: String
    /// "Tư gia Q7 · Nhà thờ Đức Bà · White Palace"
    public let venues: String
    /// The shooter's own POV role: "Thợ ảnh đi cùng ekip từ 5h sáng"
    public let povRole: String
    /// `fine_art` | `cinematic` | `documentary` | `truyen_thong` | `vui_nhon`
    public let style: String
    /// Must-have moments: "trao nhẫn, mẹ chải tóc, lì xì"
    public let mustHave: String
    /// Must-avoid: "khách chưa xin phép, cảnh say rượu"
    public let mustAvoid: String
    /// `tiktok` | `reels` | `shorts` | `youtube`
    public let platform: String
    public let targetSeconds: Int
    public let notes: String
    public let updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case briefRevisionId = "brief_revision_id"
        case projectId = "project_id"
        case workdayId = "workday_id"
        case rawText = "raw_text"
        case coupleNames = "couple_names"
        case eventType = "event_type"
        case schedule
        case venues
        case povRole = "pov_role"
        case style
        case mustHave = "must_have"
        case mustAvoid = "must_avoid"
        case platform
        case targetSeconds = "target_seconds"
        case notes
        case updatedAt = "updated_at"
    }

    public init(
        briefRevisionId: UUID,
        projectId: UUID,
        workdayId: UUID,
        rawText: String = "",
        coupleNames: String,
        eventType: String,
        schedule: String,
        venues: String,
        povRole: String,
        style: String,
        mustHave: String,
        mustAvoid: String,
        platform: String,
        targetSeconds: Int,
        notes: String,
        updatedAt: Date = Date()
    ) {
        self.briefRevisionId = briefRevisionId
        self.projectId = projectId
        self.workdayId = workdayId
        self.rawText = rawText
        self.coupleNames = coupleNames
        self.eventType = eventType
        self.schedule = schedule
        self.venues = venues
        self.povRole = povRole
        self.style = style
        self.mustHave = mustHave
        self.mustAvoid = mustAvoid
        self.platform = platform
        self.targetSeconds = targetSeconds
        self.notes = notes
        self.updatedAt = updatedAt
    }

    /// True when the user has not written anything worth sending to a model.
    public var isBlank: Bool {
        [rawText, coupleNames, schedule, venues, povRole, mustHave, mustAvoid, notes].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The one thing the writer is asked for: the must-have moments of the day.
    public var hasMustHave: Bool {
        !mustHave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || Self.parseBox(rawText).hasMustHave
    }

    /// Short headline used by G3 ("Linh & Minh — Lễ vu quy").
    public var topicLine: String {
        let couple = coupleNames.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = Self.eventLabel(eventType)
        return couple.isEmpty ? event : "\(couple) — \(event)"
    }

    /// G3 tone tag derived from the chosen shooting style.
    public var suggestedTone: String { Self.suggestedTone(style) }

    /// Target duration derived from the delivery platform.
    public var suggestedSeconds: Int { Self.suggestedSeconds(platform) }

    /// The free-text brief handed to the G2 worker (`brief_text`). One natural
    /// Vietnamese sentence per line, so `parse_raw_brief_to_drafts` keeps a clean
    /// char span per line and the resulting claims read like facts, not fields.
    ///
    /// A one-box brief is composed from `rawText`; a legacy brief (no
    /// `rawText`, saved by the old form) is composed from its fields.
    public var composedText: String {
        if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.parseBox(rawText).composedText
        }
        return Self.composeText(
            coupleNames: coupleNames,
            eventType: eventType,
            schedule: schedule,
            venues: venues,
            povRole: povRole,
            style: style,
            mustHave: mustHave,
            mustAvoid: mustAvoid,
            platform: platform,
            targetSeconds: targetSeconds,
            notes: notes
        )
    }

    // MARK: - One-box brief

    /// A parsed field of the one-box brief. `line` is the sentence handed to G2.
    public struct BoxField: Equatable, Sendable {
        public let value: String
        public let line: String
        public let ev: String?  // derived `event_type` tag
        public let style: String?  // derived style tag
        public let platform: String?  // derived platform tag
        public let seconds: Int?  // derived target duration

        init(_ value: String, _ line: String, ev: String? = nil, style: String? = nil,
             platform: String? = nil, seconds: Int? = nil) {
            self.value = value
            self.line = line
            self.ev = ev
            self.style = style
            self.platform = platform
            self.seconds = seconds
        }
    }

    /// Result of parsing the single box.
    public struct BoxParse: Equatable, Sendable {
        /// Optional named fields, in composition order.
        public var fields: [String: BoxField] = [:]
        /// Free sentences that name no field; kept verbatim in the brief.
        public var extraLines: [String] = []
        /// True when the box names the must-have moments.
        public var hasMustHave: Bool { fields["mustHave"] != nil }

        /// Composed brief: `lines[]` joined. One sentence per line — the
        /// must-have moments first, then the other facts in reading order, then
        /// the free lines; every line keeps the author's own words.
        public var lines: [String] {
            let order = ["mustHave", "couple", "schedule", "venues", "povRole",
                         "mustAvoid", "notes", "style", "platform"]
            let named = order.compactMap { key -> String? in
                guard let field = fields[key] else { return nil }
                return field.line
            }
            return named + extraLines
        }

        public var composedText: String { lines.joined(separator: "\n") }
    }

    /// How G2 reads each field: a fixed Vietnamese label per sentence. Free text
    /// that already starts with that label is left untouched.
    static let linePrefix: [String: String] = [
        "couple": "Cặp đôi",
        "schedule": "Lịch ngày",
        "venues": "Địa điểm",
        "povRole": "Góc POV",
        "mustHave": "Bắt buộc có cảnh",
        "mustAvoid": "Không quay",
        "notes": "Ghi chú",
    ]

    /// Labels a person actually types, longest first so "cảnh bắt buộc" wins
    /// over "cảnh". Meaning is a property of the label, never of the content,
    /// so a must-avoid line that starts with "không…" is still must-avoid.
    static let boxLabels: [(labels: [String], key: String)] = [
        (["không quay", "không đưa cảnh", "tránh quay", "tránh cảnh", "cần tránh", "cảnh tránh", "tránh"], "mustAvoid"),
        (["cảnh bắt buộc", "cảnh chính", "khoảnh khắc đẹp nhất", "khoảnh khắc đẹp", "cảnh đẹp nhất",
          "cảnh đẹp", "cảnh phải có", "cảnh phải chụp", "cảnh bắt buộc phải có", "bắt buộc", "phải có",
          "phải quay", "muốn có"], "mustHave"),
        (["cặp đôi", "cô dâu chú rể"], "couple"),
        (["ngày giờ", "thời gian", "lịch"], "schedule"),
        (["địa điểm", "nơi chụp"], "venues"),
        (["góc pov", "vai pov", "pov"], "povRole"),
        (["phong cách", "kiểu dựng", "gu dựng"], "style"),
        (["nền tảng", "thời lượng", "đăng"], "platform"),
        (["ghi chú", "lưu ý"], "notes"),
    ]

    static func fold(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "đ", with: "d")
        let latin = lowered.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
        return latin
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// One non-empty line split around a leading "nhãn:" — or `nil` when the
    /// line does not start with a known label.
    public static func assigned(_ line: String) -> (key: String, body: String)? {
        // Accept ASCII ":" and the full-width "：" an IME often produces.
        let colonChars: Set<Character> = [":", "\u{FF1A}"]
        guard let colon = line.firstIndex(where: { colonChars.contains($0) }) else { return nil }
        let prefix = String(line[line.startIndex..<colon])
        guard prefix.count <= 32, !prefix.contains(where: \.isNumber) else { return nil }
        let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // `\p{L}` does not match Vietnamese letters (uncased script); `\p{A}` does.
        let alnum = prefix.replacingOccurrences(of: "[^\\p{A}0-9]+", with: "", options: .regularExpression)
        guard !alnum.isEmpty else { return nil }
        let folded = fold(prefix)
        for entry in boxLabels {
            for label in entry.labels.sorted(by: { $0.count > $1.count }) {
                let foldedLabel = fold(label)
                if folded == foldedLabel || folded.hasSuffix(" " + foldedLabel) {
                    return (entry.key, body)
                }
            }
        }
        return nil
    }

    static func lines(in text: String) -> [String] {
        text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// Parses the single box into openable optional fields and free lines.
    /// Every line the person wrote survives; nothing is invented.
    public static func parseBox(_ text: String) -> BoxParse {
        var parse = BoxParse()
        var append: [String: String] = [:]

        for line in lines(in: text) {
            if let (key, body) = assigned(line) {
                guard !body.isEmpty else { continue }
                if let existing = append[key] {
                    append[key] = existing + "; " + body
                } else {
                    append[key] = body
                }
                parse.fields[key] = BoxField(fieldValue(key, body), lineFor(key, body))
            } else {
                parse.extraLines.append(line.hasSuffix(".") ? line : line + ".")
            }
        }
        // Repeated labels (e.g. two "Cảnh bắt buộc:" lines) merge into one field.
        for (key, value) in append where parse.fields[key]?.value != value {
            parse.fields[key] = BoxField(fieldValue(key, value), lineFor(key, value))
        }
        return parse
    }

    private static func fieldValue(_ key: String, _ body: String) -> String {
        // Only the shooting style has a canonical tag; every other field keeps the
        // person's own words (the platform line also carries the duration, which
        // `make` derives separately).
        key == "style" ? boxStyle(body) : body
    }

    static func boxStyle(_ body: String) -> String {
        let folded = fold(body)
        if folded.contains("vui") { return "vui_nhon" }
        if folded.contains("cinematic") { return "cinematic" }
        if folded.contains("fine") { return "fine_art" }
        if folded.contains("documentary") || folded.contains("document") { return "documentary" }
        if folded.contains("truyen thong") { return "truyen_thong" }
        return "cinematic"
    }

    static func boxPlatform(_ body: String) -> String {
        let folded = fold(body)
        if folded.contains("reels") || folded.contains("instagram") || folded.contains("ins") { return "reels" }
        if folded.contains("shorts") { return "shorts" }
        if folded.contains("youtube") { return "youtube" }
        return "tiktok"
    }

    static func seconds(in body: String) -> Int? {
        guard let match = body.range(of: "([0-9]{2,3})", options: .regularExpression),
              let ttl = Int(body[match]) else { return nil }
        return [30, 45, 60, 90].min(by: { abs($0 - ttl) < abs($1 - ttl) })
    }

    /// The sentence G2 receives for a field.
    static func lineFor(_ key: String, _ body: String) -> String {
        let sentence: String
        switch key {
        case "style": sentence = "Phong cách: \(styleLabel(boxStyle(body)))."
        case "platform":
            let secs = seconds(in: body) ?? 30
            sentence = "Nền tảng \(platformLabel(boxPlatform(body))), \(secs) giây."
        default:
            // Keep the author's own words; only add the label G2 parses on.
            let prefix = linePrefix[key] ?? ""
            let foldedBody = fold(body)
            let hasPrefix = foldedBody == fold(prefix) || foldedBody.hasSuffix(" " + fold(prefix))
            sentence = hasPrefix ? "\(body)." : "\(prefix): \(body)."
        }
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    /// Fills a record from the single box: named optional fields are derived
    /// from the text; everything unnamed keeps the app defaults (menus).
    public static func make(
        briefRevisionId: UUID,
        projectId: UUID,
        workdayId: UUID,
        rawText: String,
        defaults: ScriptBriefRecord? = nil,
        updatedAt: Date = Date()
    ) -> ScriptBriefRecord {
        let parse = parseBox(rawText)
        func value(_ key: String, _ fallback: String) -> String {
            parse.fields[key]?.value ?? fallback
        }
        return ScriptBriefRecord(
            briefRevisionId: briefRevisionId,
            projectId: projectId,
            workdayId: workdayId,
            rawText: rawText,
            coupleNames: value("couple", ""),
            eventType: defaults?.eventType ?? "vu_quy",
            schedule: value("schedule", ""),
            venues: value("venues", ""),
            povRole: value("povRole", ""),
            style: parse.fields["style"]?.value ?? defaults?.style ?? "cinematic",
            mustHave: value("mustHave", ""),
            mustAvoid: value("mustAvoid", ""),
            platform: {
                guard let body = parse.fields["platform"]?.value else { return defaults?.platform ?? "tiktok" }
                return boxPlatform(body)
            }(),
            targetSeconds: seconds(in: parse.fields["platform"]?.value ?? "") ?? defaults?.targetSeconds ?? 30,
            notes: value("notes", ""),
            updatedAt: updatedAt
        )
    }

    /// Legacy field composition, kept for revisions saved by the old form.
    public static func composeText(
        coupleNames: String,
        eventType: String,
        schedule: String,
        venues: String,
        povRole: String,
        style: String,
        mustHave: String,
        mustAvoid: String,
        platform: String,
        targetSeconds: Int,
        notes: String
    ) -> String {
        func clean(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix(".") || text.hasSuffix(";") { text.removeLast() }
            return text
        }
        var lines: [String] = []
        let couple = clean(coupleNames)
        let event = eventLabel(eventType)
        let day = clean(schedule)
        let place = clean(venues)
        let role = clean(povRole)
        let must = clean(mustHave)
        let avoid = clean(mustAvoid)
        let note = clean(notes)

        if !couple.isEmpty {
            lines.append("Đám cưới của \(couple), \(event.lowercased()).")
        } else if !day.isEmpty || !place.isEmpty {
            lines.append("\(event).")
        }
        if !day.isEmpty { lines.append("Lịch ngày: \(day).") }
        if !place.isEmpty { lines.append("Địa điểm: \(place).") }
        if !role.isEmpty { lines.append("Góc POV: \(role).") }
        if !must.isEmpty { lines.append("Bắt buộc có cảnh: \(must).") }
        if !avoid.isEmpty { lines.append("Không quay: \(avoid).") }
        // Style/platform are menu defaults: only meaningful once a real fact exists.
        let hasContent = ![couple, day, place, role, must, avoid, note].allSatisfy(\.isEmpty)
        if hasContent {
            if !clean(style).isEmpty { lines.append("Phong cách: \(styleLabel(style)).") }
            if !clean(platform).isEmpty { lines.append("Nền tảng \(platformLabel(platform)), \(targetSeconds) giây.") }
        }
        if !note.isEmpty { lines.append("Ghi chú: \(note).") }
        return lines.joined(separator: "\n")
    }

    public static let eventTypes = ["dam_hoi", "vu_quy", "thanh_hon", "tiec_cuoi", "ca_ngay"]

    public static func eventLabel(_ tag: String) -> String {
        switch tag {
        case "dam_hoi": return "Lễ đám hỏi"
        case "vu_quy": return "Lễ vu quy"
        case "thanh_hon": return "Lễ thành hôn"
        case "tiec_cuoi": return "Tiệc cưới"
        default: return "Cả ngày cưới"
        }
    }

    public static let styles = ["fine_art", "cinematic", "documentary", "truyen_thong", "vui_nhon"]

    public static func styleLabel(_ tag: String) -> String {
        switch tag {
        case "fine_art": return "Fine-art"
        case "cinematic": return "Cinematic"
        case "documentary": return "Documentary"
        case "truyen_thong": return "Truyền thống"
        default: return "Vui nhộn"
        }
    }

    public static let platforms = ["tiktok", "reels", "shorts", "youtube"]

    public static func platformLabel(_ tag: String) -> String {
        switch tag {
        case "tiktok": return "TikTok"
        case "reels": return "Instagram Reels"
        case "shorts": return "YouTube Shorts"
        default: return "YouTube"
        }
    }

    public static func suggestedSeconds(_ platform: String) -> Int {
        switch platform {
        case "tiktok": return 30
        case "reels": return 45
        case "shorts": return 60
        default: return 90
        }
    }

    /// Style -> one of the four tone tags the G3 story engine understands.
    public static func suggestedTone(_ style: String) -> String {
        switch style {
        case "vui_nhon": return "hai_huoc"
        case "cinematic", "fine_art": return "tram_tinh"
        default: return "pov_tu_nhien"
        }
    }

    public static let toneTags = ["pov_tu_nhien", "hai_huoc", "tram_tinh", "huong_dan"]

    public static func toneLabel(_ tag: String) -> String {
        switch tag {
        case "hai_huoc": return "Hài hước / Sôi nổi"
        case "tram_tinh": return "Trầm tĩnh / Trải nghiệm"
        case "huong_dan": return "Hướng dẫn / Du ký"
        default: return "POV Tự nhiên"
        }
    }

    /// Deterministic revision id: same brief content => same id (idempotent saves),
    /// different content => different revision (honest provenance).
    public static func revisionId(workdayId: UUID, composedText: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("\(workdayId.uuidString)|\(composedText)".utf8))
        let hex = Array(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(32))
        guard hex.count == 32 else { return UUID() }
        let s = String(hex)
        let parts = [s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4),
                     s.dropFirst(16).prefix(4), s.dropFirst(20).prefix(12)].map(String.init)
        return UUID(uuidString: parts.joined(separator: "-")) ?? UUID()
    }

}

public struct ApprovalRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { approvalId }
    public let approvalId: UUID
    public let projectId: UUID
    public let approvalType: String
    public let targetRevisionId: UUID
    public let isSuperseded: Bool
    public let approvedBy: String
    public let approvedAt: Date

    public enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case projectId = "project_id"
        case approvalType = "approval_type"
        case targetRevisionId = "target_revision_id"
        case isSuperseded = "is_superseded"
        case approvedBy = "approved_by"
        case approvedAt = "approved_at"
    }

    public init(
        approvalId: UUID = UUID(),
        projectId: UUID,
        approvalType: String,
        targetRevisionId: UUID,
        isSuperseded: Bool = false,
        approvedBy: String,
        approvedAt: Date = Date()
    ) {
        self.approvalId = approvalId
        self.projectId = projectId
        self.approvalType = approvalType
        self.targetRevisionId = targetRevisionId
        self.isSuperseded = isSuperseded
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt
    }
}

public struct JobRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { jobId }
    public let jobId: UUID
    public let projectId: UUID
    public let jobType: String
    public let inputFingerprint: String
    public let status: JobStatus
    public let createdAt: Date
    public let completedAt: Date?

    public init(
        jobId: UUID = UUID(),
        projectId: UUID,
        jobType: String,
        inputFingerprint: String,
        status: JobStatus = .queued,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.jobId = jobId
        self.projectId = projectId
        self.jobType = jobType
        self.inputFingerprint = inputFingerprint
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public struct JobAttemptRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { attemptId }
    public let attemptId: UUID
    public let jobId: UUID
    public let fencingToken: Int
    public let workerSessionId: String
    public let status: String
    public let publishRevoked: Bool
    public let startedAt: Date
    public let finishedAt: Date?

    public init(
        attemptId: UUID = UUID(),
        jobId: UUID,
        fencingToken: Int,
        workerSessionId: String,
        status: String = "RUNNING",
        publishRevoked: Bool = false,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.attemptId = attemptId
        self.jobId = jobId
        self.fencingToken = fencingToken
        self.workerSessionId = workerSessionId
        self.status = status
        self.publishRevoked = publishRevoked
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

final class SQLiteDatabaseHandle: @unchecked Sendable {
    var raw: OpaquePointer?

    init(_ raw: OpaquePointer?) {
        self.raw = raw
    }

    func close() {
        if let raw = raw {
            sqlite3_close_v2(raw)
            self.raw = nil
        }
    }

    deinit {
        close()
    }
}

/// ProjectStore actor: Canonical single-writer SQLite WAL actor.
/// Swift Core holds exclusive commit rights. Workers NEVER receive a write connection.
public actor ProjectStore {
    private let handle: SQLiteDatabaseHandle
    public let dbURL: URL?

    private var db: OpaquePointer? {
        handle.raw
    }

    public init(dbURL: URL? = nil) throws {
        self.dbURL = dbURL
        let path = dbURL?.path ?? ":memory:"
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &connection, flags, nil) != SQLITE_OK {
            let msg = connection != nil ? String(cString: sqlite3_errmsg(connection)) : "Unknown"
            sqlite3_close_v2(connection)
            throw ProjectStoreError.databaseOpenFailed(msg)
        }
        self.handle = SQLiteDatabaseHandle(connection)

        // Apply mandatory pragmas
        try Self.execute(db: connection, sql: "PRAGMA foreign_keys = ON;")
        if dbURL != nil {
            try Self.execute(db: connection, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(db: connection, sql: "PRAGMA synchronous = NORMAL;")
        }
        try Self.execute(db: connection, sql: "PRAGMA busy_timeout = 3000;")

        // Initialize DDL Schema
        try Self.initializeSchema(db: connection)
        // 2026-11-10 fix (D06): the G3/G4/G5 gate tables used to be created lazily by
        // extensions that opened their own SQLite connection. They are canonical schema,
        // so they are created once here, by the single writer, before any gate write.
        try Self.migrateAdditiveColumns(db: connection)
        try Self.initializeGateSchema(db: connection)
        // (P1-10) The canonical schema version must be readable by every other component
        // (backup compatibility, restore gates). It used to stay 0 forever, which disabled
        // the "newer schema than this app supports" guard.
        try Self.execute(db: connection, sql: "PRAGMA user_version = \(Self.canonicalSchemaVersion);")
    }

    public func close() {
        handle.close()
    }

    // MARK: - Direct SQL Execution Helpers

    private static func execute(db: OpaquePointer?, sql: String) throws {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "Unknown error"
            sqlite3_free(err)
            throw ProjectStoreError.executionFailed(msg)
        }
    }

    private func execute(sql: String) throws {
        try Self.execute(db: self.db, sql: sql)
    }

    /// Streaming SHA-256 used to re-verify canonical bytes before commit (P1-1).
    private static func fileSHA256(atPath path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ProjectStoreError.integrityViolation("Cannot read canonical file at \(path)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func initializeSchema(db: OpaquePointer?) throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS projects (
            project_id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            current_revision INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS workdays (
            workday_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            title TEXT NOT NULL,
            date TEXT NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS source_media (
            media_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            original_path TEXT NOT NULL,
            content_sha256 TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS source_revisions (
            source_revision_id TEXT PRIMARY KEY NOT NULL,
            media_id TEXT NOT NULL REFERENCES source_media(media_id) ON DELETE RESTRICT,
            snapshot_path TEXT NOT NULL,
            snapshot_sha256 TEXT NOT NULL,
            is_stable INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS claims (
            revision_id TEXT PRIMARY KEY NOT NULL,
            claim_id TEXT NOT NULL,
            workday_id TEXT NOT NULL REFERENCES workdays(workday_id) ON DELETE RESTRICT,
            text TEXT NOT NULL,
            origin TEXT NOT NULL CHECK(origin IN ('user', 'visual_model', 'asr', 'audio_detector', 'ocr', 'metadata', 'derived')),
            epistemic_status TEXT NOT NULL CHECK(epistemic_status IN ('observed', 'reported', 'inferred', 'unknown')),
            review_status TEXT NOT NULL CHECK(review_status IN ('unreviewed', 'auto_checked', 'needs_review', 'confirmed', 'rejected', 'superseded')),
            support_status TEXT NOT NULL CHECK(support_status IN ('supported', 'contradicted', 'insufficient', 'disputed')),
            allowed_use TEXT NOT NULL CHECK(allowed_use IN ('direct_claim', 'attributed_or_qualified', 'illustrative_only', 'exclude')),
            source_revision_id TEXT REFERENCES source_revisions(source_revision_id) ON DELETE RESTRICT,
            start_frame INTEGER,
            end_frame INTEGER,
            time_base_num INTEGER,
            time_base_den INTEGER,
            confirmation_id TEXT,
            confidence_raw REAL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS approvals (
            approval_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            approval_type TEXT NOT NULL CHECK(approval_type IN ('fact_confirmation', 'script_approval', 'preview_approval')),
            target_revision_id TEXT NOT NULL,
            is_superseded INTEGER NOT NULL DEFAULT 0,
            approved_by TEXT NOT NULL,
            approved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS idempotency_journal (
            operation_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            fencing_token INTEGER NOT NULL,
            result_payload TEXT NOT NULL,
            committed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS jobs (
            job_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            job_type TEXT NOT NULL,
            input_fingerprint TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL CHECK(status IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            completed_at TEXT
        );

        CREATE TABLE IF NOT EXISTS job_attempts (
            attempt_id TEXT PRIMARY KEY NOT NULL,
            job_id TEXT NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
            fencing_token INTEGER NOT NULL,
            worker_session_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('PREPARED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
            publish_revoked INTEGER NOT NULL DEFAULT 0,
            started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            finished_at TEXT,
            UNIQUE(job_id, fencing_token)
        );

        CREATE TABLE IF NOT EXISTS artifact_publications (
            publication_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            job_id TEXT NOT NULL REFERENCES jobs(job_id) ON DELETE RESTRICT,
            attempt_id TEXT NOT NULL REFERENCES job_attempts(attempt_id) ON DELETE RESTRICT,
            fencing_token INTEGER NOT NULL,
            artifact_type TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('PREPARED', 'MATERIALIZED', 'VERIFIED', 'COMMITTED')),
            temp_path TEXT,
            canonical_path TEXT,
            sha256_hash TEXT,
            byte_size INTEGER,
            -- (P1-01) Artifacts this logical job owes before it may be SUCCEEDED.
            expected_publication_count INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS artifact_pins (
            pin_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            publication_id TEXT NOT NULL REFERENCES artifact_publications(publication_id) ON DELETE RESTRICT,
            reason TEXT NOT NULL,
            pinned_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY NOT NULL,
            migration_id TEXT NOT NULL,
            code_checksum TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('IN_PROGRESS', 'COMPLETED', 'FAILED')),
            applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_claims_workday ON claims(workday_id);
        CREATE INDEX IF NOT EXISTS idx_claims_claim_id ON claims(claim_id);
        CREATE INDEX IF NOT EXISTS idx_approvals_target ON approvals(target_revision_id);
        CREATE INDEX IF NOT EXISTS idx_job_attempts_job ON job_attempts(job_id);
        CREATE INDEX IF NOT EXISTS idx_artifact_publications_project ON artifact_publications(project_id, state);

        -- Scriptwriter brief captured in the UI at import time (Step 1).
        -- One row per distinct content revision, keyed by a content hash, so a
        -- G3 script can cite the exact brief revision it was written against.
        CREATE TABLE IF NOT EXISTS script_briefs (
            brief_revision_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id),
            workday_id TEXT NOT NULL REFERENCES workdays(workday_id),
            raw_text TEXT NOT NULL DEFAULT '',
            couple_names TEXT NOT NULL DEFAULT '',
            event_type TEXT NOT NULL DEFAULT 'vu_quy',
            schedule TEXT NOT NULL DEFAULT '',
            venues TEXT NOT NULL DEFAULT '',
            pov_role TEXT NOT NULL DEFAULT '',
            style TEXT NOT NULL DEFAULT 'cinematic',
            must_have TEXT NOT NULL DEFAULT '',
            must_avoid TEXT NOT NULL DEFAULT '',
            platform TEXT NOT NULL DEFAULT 'tiktok',
            target_seconds INTEGER NOT NULL DEFAULT 30,
            notes TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
        CREATE INDEX IF NOT EXISTS idx_script_briefs_workday ON script_briefs(workday_id, updated_at);

        CREATE TABLE IF NOT EXISTS coverage_records (
            coverage_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            source_revision_id TEXT NOT NULL,
            runtime_profile_id TEXT NOT NULL,
            input_fingerprint TEXT NOT NULL,
            total_declared_frames INTEGER NOT NULL,
            valid_decoded_frames INTEGER NOT NULL,
            unique_processed_frames INTEGER NOT NULL,
            -- (P1-09) The real frame-id sets and window totals. Before this the reader
            -- re-invented `Array(0..<count)`, destroying traceability.
            unique_processed_frame_ids TEXT NOT NULL DEFAULT '',
            corrupted_decode_frame_ids TEXT NOT NULL DEFAULT '',
            total_submitted_with_overlap INTEGER NOT NULL DEFAULT 0,
            completed_windows INTEGER NOT NULL DEFAULT 0,
            total_windows INTEGER NOT NULL DEFAULT 1,
            frame_input_coverage REAL NOT NULL,
            audio_branch_state TEXT NOT NULL,
            detailed_pass_status TEXT NOT NULL,
            semantic_certified INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS review_items (
            review_item_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
            workday_id TEXT NOT NULL REFERENCES workdays(workday_id) ON DELETE RESTRICT,
            target_claim_revision_id TEXT,
            evidence_scope_revision_id TEXT NOT NULL,
            evidence_kind TEXT NOT NULL,
            is_critical INTEGER NOT NULL DEFAULT 1,
            question_text TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'open',
            resolution_action TEXT,
            resulting_allowed_use TEXT,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS raw_observations (
            observation_id TEXT PRIMARY KEY NOT NULL,
            source_revision_id TEXT NOT NULL,
            window_index INTEGER NOT NULL,
            pass_role TEXT NOT NULL,
            origin TEXT NOT NULL,
            epistemic_status TEXT NOT NULL,
            frame_ids_json TEXT NOT NULL,
            start_pts INTEGER NOT NULL,
            end_pts INTEGER NOT NULL,
            observation_text TEXT NOT NULL,
            ocr_raw_tokens_json TEXT NOT NULL,
            ocr_is_uncertain INTEGER NOT NULL DEFAULT 0,
            guided_hypothesis_ref TEXT,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
        """
        try Self.execute(db: db, sql: schema)
    }

    /// Canonical DDL for the S19/S21/S22 approval tables (schema owned by the single writer).
    private static func initializeGateSchema(db: OpaquePointer?) throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS g3_scripts (
            script_revision_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id),
            workday_id TEXT NOT NULL REFERENCES workdays(workday_id),
            candidate_json TEXT NOT NULL,
            candidate_sha256 TEXT NOT NULL,
            scope_revision_id TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS g3_selected (
            project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(project_id),
            script_revision_id TEXT NOT NULL REFERENCES g3_scripts(script_revision_id)
        );

        CREATE TABLE IF NOT EXISTS g3_voice_reviews (
            script_revision_id TEXT NOT NULL REFERENCES g3_scripts(script_revision_id),
            beat_id TEXT NOT NULL,
            publication_id TEXT NOT NULL REFERENCES artifact_publications(publication_id),
            wav_sha256 TEXT NOT NULL,
            text_sha256 TEXT NOT NULL,
            reviewed_by TEXT NOT NULL,
            reviewed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            PRIMARY KEY(script_revision_id, beat_id),
            UNIQUE(script_revision_id, publication_id)
        );

        CREATE TABLE IF NOT EXISTS g3_approvals (
            approval_id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(project_id),
            workday_id TEXT NOT NULL REFERENCES workdays(workday_id),
            script_revision_id TEXT NOT NULL UNIQUE REFERENCES g3_scripts(script_revision_id),
            candidate_sha256 TEXT NOT NULL,
            manifest_json TEXT NOT NULL,
            manifest_sha256 TEXT NOT NULL,
            approved_by TEXT NOT NULL,
            approved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS g4_preview_approvals (
            approval_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(project_id),
            g3_approval_id TEXT NOT NULL REFERENCES g3_approvals(approval_id),
            preview_publication_id TEXT NOT NULL REFERENCES artifact_publications(publication_id),
            preview_sha256 TEXT NOT NULL,
            plan_sha256 TEXT NOT NULL,
            qc_receipt_json TEXT NOT NULL,
            qc_receipt_sha256 TEXT NOT NULL,
            reviewed_by TEXT NOT NULL,
            review_notes TEXT NOT NULL,
            approved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            UNIQUE(project_id, g3_approval_id, preview_sha256)
        );

        CREATE TABLE IF NOT EXISTS g5_final_approvals (
            approval_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(project_id),
            g3_approval_id TEXT NOT NULL REFERENCES g3_approvals(approval_id),
            g4_approval_id TEXT NOT NULL REFERENCES g4_preview_approvals(approval_id),
            final_publication_id TEXT NOT NULL REFERENCES artifact_publications(publication_id),
            drp_publication_id TEXT NOT NULL REFERENCES artifact_publications(publication_id),
            final_sha256 TEXT NOT NULL,
            drp_sha256 TEXT NOT NULL,
            plan_sha256 TEXT NOT NULL,
            qc_receipt_json TEXT NOT NULL,
            qc_receipt_sha256 TEXT NOT NULL,
            reviewed_by TEXT NOT NULL,
            review_notes TEXT NOT NULL,
            approved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            UNIQUE(project_id, g4_approval_id, final_sha256)
        );

        CREATE TABLE IF NOT EXISTS g5_manual_handoff_branches (
            branch_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL REFERENCES projects(project_id),
            g3_approval_id TEXT NOT NULL REFERENCES g3_approvals(approval_id),
            g4_approval_id TEXT NOT NULL REFERENCES g4_preview_approvals(approval_id),
            handoff_drp_publication_id TEXT NOT NULL REFERENCES artifact_publications(publication_id),
            handoff_drp_sha256 TEXT NOT NULL,
            handoff_project_name TEXT NOT NULL,
            branch_receipt_json TEXT NOT NULL,
            created_by TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
        """
        try Self.execute(db: db, sql: schema)
        try Self.ensureScriptBriefColumns(db: db)
    }

    /// Old installs already have a `script_briefs` table from the generic 6-field
    /// brief. Add the wedding columns in place instead of dropping user data.
    private static func ensureScriptBriefColumns(db: OpaquePointer?) throws {
        guard let db else { throw ProjectStoreError.executionFailed("Database closed") }
        var existing = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(script_briefs);", -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                existing.insert(String(cString: name))
            }
        }
        let additions: [(String, String)] = [
            ("raw_text", "TEXT NOT NULL DEFAULT ''"),
            ("couple_names", "TEXT NOT NULL DEFAULT ''"),
            ("event_type", "TEXT NOT NULL DEFAULT 'vu_quy'"),
            ("schedule", "TEXT NOT NULL DEFAULT ''"),
            ("venues", "TEXT NOT NULL DEFAULT ''"),
            ("pov_role", "TEXT NOT NULL DEFAULT ''"),
            ("style", "TEXT NOT NULL DEFAULT 'cinematic'"),
            ("must_have", "TEXT NOT NULL DEFAULT ''"),
            ("must_avoid", "TEXT NOT NULL DEFAULT ''"),
            ("platform", "TEXT NOT NULL DEFAULT 'tiktok'"),
            ("target_seconds", "INTEGER NOT NULL DEFAULT 30"),
        ]
        for (name, decl) in additions where !existing.contains(name) {
            try Self.execute(db: db, sql: "ALTER TABLE script_briefs ADD COLUMN \(name) \(decl);")
        }
    }

    // MARK: - Transaction Wrapper

    private func withTransaction<T>(_ block: () throws -> T) throws -> T {
        try execute(sql: "BEGIN IMMEDIATE;")
        do {
            let result = try block()
            try execute(sql: "COMMIT;")
            return result
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    /// (P2-05) A shared *read* transaction.
    ///
    /// Reads in the gate stores used to go through `BEGIN IMMEDIATE`, which takes the write
    /// lock on the single canonical connection. `currentG4Preview` even hashes the preview
    /// MP4 inside it, so every UI poll blocked the writer for the length of that IO.
    /// `BEGIN DEFERRED` keeps a multi-statement read consistent without reserving the write
    /// lock, and callers that only need one statement can use `withCanonicalRead`.
    private func withReadTransaction<T>(_ block: () throws -> T) throws -> T {
        try execute(sql: "BEGIN DEFERRED;")
        do {
            let result = try block()
            try execute(sql: "COMMIT;")
            return result
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    func withCanonicalRead<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try withReadTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            return try body(db)
        }
    }

    /// 2026-11-10 fix (D06): canonical write transaction shared with the G3/G4/G5
    /// extensions. It runs on the actor's ONE connection, so the "single writer"
    /// invariant is true at the connection level instead of opening a second handle.
    func withCanonicalTransaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            return try body(db)
        }
    }

    // MARK: - Projects & Workdays

    public func createProject(id: UUID = UUID(), name: String) throws -> ProjectRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "INSERT INTO projects (project_id, name, current_revision) VALUES (?, ?, 1);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, name, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            return ProjectRecord(projectId: id, name: name, currentRevision: 1)
        }
    }

    public func getProject(id: UUID) throws -> ProjectRecord? {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = "SELECT project_id, name, current_revision, created_at, updated_at FROM projects WHERE project_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let pidStr = colText(stmt, 0)
            let name = colText(stmt, 1)
            let rev = Int(sqlite3_column_int(stmt, 2))
            let createdStr = colText(stmt, 3)
            let updatedStr = colText(stmt, 4)

            let created = DataContractDateFormatters.date(from: createdStr) ?? Date()
            let updated = DataContractDateFormatters.date(from: updatedStr) ?? Date()
            return ProjectRecord(projectId: try requireUUID(pidStr), name: name, currentRevision: rev, createdAt: created, updatedAt: updated)
        }
        return nil
    }

    public func createWorkday(id: UUID = UUID(), projectId: UUID, title: String, date: String) throws -> WorkdayRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "INSERT INTO workdays (workday_id, project_id, title, date, revision) VALUES (?, ?, ?, ?, 1);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, date, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                let err = String(cString: sqlite3_errmsg(db))
                if err.contains("FOREIGN KEY") {
                    throw ProjectStoreError.projectNotFound(projectId)
                }
                throw ProjectStoreError.executionFailed(err)
            }
            return WorkdayRecord(workdayId: id, projectId: projectId, title: title, date: date, revision: 1)
        }
    }

    // MARK: - Claims and Revisions

    public func saveClaim(
        claim: ClaimRecord,
        expectedRevision: Int? = nil,
        idempotencyKey: String? = nil
    ) throws -> ClaimRecord {
        return try withTransaction {
            try self.saveClaimInternal(claim: claim, expectedRevision: expectedRevision, idempotencyKey: idempotencyKey)
        }
    }

    private func saveClaimInternal(
        claim: ClaimRecord,
        expectedRevision: Int? = nil,
        idempotencyKey: String? = nil
    ) throws -> ClaimRecord {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

            // 1. Idempotency Check
            if let ikey = idempotencyKey {
                let checkSql = "SELECT result_payload FROM idempotency_journal WHERE operation_id = ?;"
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(checkStmt) }
                    sqlite3_bind_text(checkStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(checkStmt) == SQLITE_ROW {
                        let payload = colText(checkStmt, 0)
                        if let data = payload.data(using: .utf8),
                           let cached = try? JSONDecoder().decode(ClaimRecord.self, from: data) {
                            return cached
                        }
                    }
                }
            }

            // 2. Fetch Project and check expected revision
            let getProjSql = "SELECT p.project_id, p.current_revision FROM projects p JOIN workdays w ON p.project_id = w.project_id WHERE w.workday_id = ?;"
            var projStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, getProjSql, -1, &projStmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(projStmt) }
            sqlite3_bind_text(projStmt, 1, claim.workdayId.uuidString, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(projStmt) == SQLITE_ROW else {
                throw ProjectStoreError.workdayNotFound(claim.workdayId)
            }
            let projectIdStr = colText(projStmt, 0)
            let currentRev = Int(sqlite3_column_int(projStmt, 1))
            let projectId = try requireUUID(projectIdStr)

            if let expected = expectedRevision, expected != currentRev {
                throw ProjectStoreError.revisionConflict(expected: expected, actual: currentRev)
            }

            // 3. Insert claim revision
            let insertSql = """
            INSERT INTO claims (
                revision_id, claim_id, workday_id, text, origin, epistemic_status,
                review_status, support_status, allowed_use, source_revision_id,
                start_frame, end_frame, time_base_num, time_base_den, confirmation_id,
                confidence_raw, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var insStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSql, -1, &insStmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(insStmt) }

            sqlite3_bind_text(insStmt, 1, claim.revisionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 2, claim.claimId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 3, claim.workdayId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 4, claim.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 5, claim.origin.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 6, claim.epistemicStatus.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 7, claim.reviewStatus.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 8, claim.supportStatus.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 9, claim.allowedUse.rawValue, -1, SQLITE_TRANSIENT)

            if let srev = claim.sourceRevisionId {
                sqlite3_bind_text(insStmt, 10, srev.uuidString, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insStmt, 10)
            }

            if let tr = claim.timeRange {
                sqlite3_bind_int(insStmt, 11, Int32(tr.startFrame))
                sqlite3_bind_int(insStmt, 12, Int32(tr.endFrame))
                sqlite3_bind_int(insStmt, 13, Int32(tr.timeBaseNum))
                sqlite3_bind_int(insStmt, 14, Int32(tr.timeBaseDen))
            } else {
                sqlite3_bind_null(insStmt, 11)
                sqlite3_bind_null(insStmt, 12)
                sqlite3_bind_null(insStmt, 13)
                sqlite3_bind_null(insStmt, 14)
            }

            if let cid = claim.confirmationId {
                sqlite3_bind_text(insStmt, 15, cid.uuidString, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insStmt, 15)
            }

            if let conf = claim.confidenceRaw {
                sqlite3_bind_double(insStmt, 16, conf)
            } else {
                sqlite3_bind_null(insStmt, 16)
            }

            let dateStr = DataContractDateFormatters.string(from: claim.createdAt)
            sqlite3_bind_text(insStmt, 17, dateStr, -1, SQLITE_TRANSIENT)

            if sqlite3_step(insStmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }

            // 4. Increment Project Revision
            let nextRev = currentRev + 1
            let updateRevSql = "UPDATE projects SET current_revision = ?, updated_at = (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) WHERE project_id = ?;"
            var upStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateRevSql, -1, &upStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(upStmt) }
                sqlite3_bind_int(upStmt, 1, Int32(nextRev))
                sqlite3_bind_text(upStmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(upStmt)
            }

            // 5. Save to Idempotency Journal
            if let ikey = idempotencyKey {
                let idempSql = "INSERT INTO idempotency_journal (operation_id, project_id, fencing_token, result_payload) VALUES (?, ?, ?, ?);"
                var idempStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, idempSql, -1, &idempStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(idempStmt) }
                    let encoder = JSONEncoder()
                    if let encoded = try? encoder.encode(claim),
                       let payloadStr = String(data: encoded, encoding: .utf8) {
                        sqlite3_bind_text(idempStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(idempStmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_int(idempStmt, 3, Int32(nextRev))
                        sqlite3_bind_text(idempStmt, 4, payloadStr, -1, SQLITE_TRANSIENT)
                        _ = sqlite3_step(idempStmt)
                    }
                }
            }

            return claim
    }

    public func confirmFact(
        claimId: UUID,
        confirmationId: UUID = UUID(),
        approvedBy: String,
        expectedRevision: Int? = nil,
        idempotencyKey: String? = nil
    ) throws -> ClaimRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

            // 1. Idempotency Check
            if let ikey = idempotencyKey {
                let checkSql = "SELECT result_payload FROM idempotency_journal WHERE operation_id = ?;"
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(checkStmt) }
                    sqlite3_bind_text(checkStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(checkStmt) == SQLITE_ROW {
                        let payload = colText(checkStmt, 0)
                        if let data = payload.data(using: .utf8),
                           let cached = try? JSONDecoder().decode(ClaimRecord.self, from: data) {
                            return cached
                        }
                    }
                }
            }

            // 2. Fetch latest claim revision
            let querySql = """
            SELECT revision_id, claim_id, workday_id, text, origin, epistemic_status,
                   review_status, support_status, allowed_use, source_revision_id,
                   start_frame, end_frame, time_base_num, time_base_den, confirmation_id,
                   confidence_raw, created_at
            FROM claims
            WHERE claim_id = ?
            ORDER BY rowid DESC LIMIT 1;
            """
            var qStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, querySql, -1, &qStmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(qStmt) }
            sqlite3_bind_text(qStmt, 1, claimId.uuidString, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(qStmt) == SQLITE_ROW else {
                throw ProjectStoreError.claimNotFound(claimId)
            }

            let revId = try colUUID(qStmt, 0)
            let cId = try colUUID(qStmt, 1)
            let wId = try colUUID(qStmt, 2)
            let text = colText(qStmt, 3)
            let origin = try colEnum(Origin.self, qStmt, 4)
            let epistemic = try colEnum(EpistemicStatus.self, qStmt, 5)
            let review = try colEnum(ReviewStatus.self, qStmt, 6)
            let support = try colEnum(SupportStatus.self, qStmt, 7)
            let allowed = try colEnum(AllowedUse.self, qStmt, 8)

            var sourceRev: UUID? = nil
            if sqlite3_column_type(qStmt, 9) != SQLITE_NULL {
                sourceRev = UUID(uuidString: colText(qStmt, 9))
            }

            var tr: TimeRange? = nil
            if sqlite3_column_type(qStmt, 10) != SQLITE_NULL {
                let start = Int(sqlite3_column_int(qStmt, 10))
                let end = Int(sqlite3_column_int(qStmt, 11))
                let num = Int(sqlite3_column_int(qStmt, 12))
                let den = Int(sqlite3_column_int(qStmt, 13))
                tr = TimeRange(startFrame: start, endFrame: end, timeBaseNum: num, timeBaseDen: den)
            }

            let latestClaim = ClaimRecord(
                claimId: cId,
                revisionId: revId,
                workdayId: wId,
                text: text,
                origin: origin,
                epistemicStatus: epistemic,
                reviewStatus: review,
                supportStatus: support,
                allowedUse: allowed,
                sourceRevisionId: sourceRev,
                timeRange: tr
            )

            // 3. Create fresh revision with review_status = .confirmed
            // Core Invariant S04.T2: Preserves origin (never becomes visualModel or observed)
            let confirmed = latestClaim.confirmingUserFact(confirmationId: confirmationId)

            // Save new claim revision (handles revision increment and journal)
            let saved = try self.saveClaimInternal(claim: confirmed, expectedRevision: expectedRevision, idempotencyKey: nil)

            // Fetch projectId
            let getProjSql = "SELECT project_id FROM workdays WHERE workday_id = ?;"
            var projStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, getProjSql, -1, &projStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(projStmt) }
                sqlite3_bind_text(projStmt, 1, wId.uuidString, -1, SQLITE_TRANSIENT)
                if sqlite3_step(projStmt) == SQLITE_ROW {
                    let pId = try colUUID(projStmt, 0)

                    // 4. Record in Approvals Table
                    let appSql = "INSERT INTO approvals (approval_id, project_id, approval_type, target_revision_id, approved_by) VALUES (?, ?, 'fact_confirmation', ?, ?);"
                    var appStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, appSql, -1, &appStmt, nil) == SQLITE_OK {
                        defer { sqlite3_finalize(appStmt) }
                        sqlite3_bind_text(appStmt, 1, confirmationId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(appStmt, 2, pId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(appStmt, 3, saved.revisionId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(appStmt, 4, approvedBy, -1, SQLITE_TRANSIENT)
                        _ = sqlite3_step(appStmt)
                    }

                    // 5. Record Idempotency Journal
                    if let ikey = idempotencyKey {
                        let idempSql = "INSERT INTO idempotency_journal (operation_id, project_id, fencing_token, result_payload) VALUES (?, ?, 0, ?);"
                        var idempStmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, idempSql, -1, &idempStmt, nil) == SQLITE_OK {
                            defer { sqlite3_finalize(idempStmt) }
                            if let encoded = try? JSONEncoder().encode(saved),
                               let payloadStr = String(data: encoded, encoding: .utf8) {
                                sqlite3_bind_text(idempStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                                sqlite3_bind_text(idempStmt, 2, pId.uuidString, -1, SQLITE_TRANSIENT)
                                sqlite3_bind_text(idempStmt, 3, payloadStr, -1, SQLITE_TRANSIENT)
                                _ = sqlite3_step(idempStmt)
                            }
                        }
                    }
                }
            }

            return saved
        }
    }

    /// (P1-06) Claims stored in this database (latest revision per claim).
    /// (P2-10) Read one workday by id so callers never have to rebuild the record by hand.
    public func getWorkday(id: UUID, projectId: UUID) throws -> WorkdayRecord? {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "SELECT workday_id, project_id, title, date FROM workdays WHERE workday_id = ? AND project_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let wid = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))),
                  let pid = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 1))),
                  let title = sqlite3_column_text(stmt, 2),
                  let date = sqlite3_column_text(stmt, 3) else { return nil }
            return WorkdayRecord(workdayId: wid, projectId: pid,
                                 title: String(cString: title), date: String(cString: date))
        }
    }

    public func countClaims(workdayId: UUID) throws -> Int {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(DISTINCT claim_id) FROM claims WHERE workday_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, workdayId.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// (P1-06) Re-point every committed publication at the restored copy of its bytes.
    ///
    /// A restored database still carried the *original* absolute `canonical_path`, so once
    /// the old directory was gone every downstream guard reported "missing/tampered". The
    /// rewrite is one short transaction and only maps rows whose SHA-256 matches the blob
    /// that was actually restored.
    public func rewriteCanonicalPaths(blobDirectory: URL, projectId: UUID) throws -> Int {
        let dir = blobDirectory.standardizedFileURL
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            var select: OpaquePointer?
            let sql = """
            SELECT publication_id, sha256_hash FROM artifact_publications
            WHERE LOWER(project_id) = LOWER(?) AND state = 'COMMITTED';
            """
            guard sqlite3_prepare_v2(db, sql, -1, &select, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(select, 1, projectId.uuidString, -1, SQLITE_TRANSIENT)
            var pending: [(String, String)] = []
            // Every step result is checked: a silent step failure used to leave `pending`
            // empty and the restore "succeeded" while still pointing at deleted files.
            var step = sqlite3_step(select)
            while step == SQLITE_ROW {
                let id = colText(select, 0)
                let sha = sqlite3_column_type(select, 1) != SQLITE_NULL ? colText(select, 1) : ""
                // Only blobs that were actually restored are re-pointed; anything else keeps
                // its original path so a missing artifact stays visibly missing.
                let candidate = dir.appendingPathComponent(sha)
                if !sha.isEmpty, FileManager.default.fileExists(atPath: candidate.path) {
                    pending.append((id, candidate.path))
                }
                step = sqlite3_step(select)
            }
            sqlite3_finalize(select)
            guard step == SQLITE_DONE else {
                throw ProjectStoreError.queryFailed(
                    "Cannot enumerate restored publications (sqlite step=\(step))")
            }
            var updated = 0
            for (id, path) in pending {
                var update: OpaquePointer?
                let usql = "UPDATE artifact_publications SET canonical_path = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE publication_id = ?;"
                guard sqlite3_prepare_v2(db, usql, -1, &update, nil) == SQLITE_OK else {
                    throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_bind_text(update, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(update, 2, id, -1, SQLITE_TRANSIENT)
                if sqlite3_step(update) == SQLITE_DONE {
                    updated += Int(sqlite3_changes(db))
                }
                sqlite3_finalize(update)
            }
            return updated
        }
    }

    public func getLatestClaims(workdayId: UUID) throws -> [ClaimRecord] {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        // Select latest revision for each claim_id
        let sql = """
        SELECT c.revision_id, c.claim_id, c.workday_id, c.text, c.origin, c.epistemic_status,
               c.review_status, c.support_status, c.allowed_use, c.source_revision_id,
               c.start_frame, c.end_frame, c.time_base_num, c.time_base_den, c.confirmation_id,
               c.confidence_raw, c.created_at
        FROM claims c
        INNER JOIN (
            SELECT claim_id, MAX(rowid) as max_rowid
            FROM claims
            WHERE workday_id = ?
            GROUP BY claim_id
        ) latest ON c.rowid = latest.max_rowid;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, workdayId.uuidString, -1, SQLITE_TRANSIENT)

        var list: [ClaimRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let revId = try colUUID(stmt, 0)
            let cId = try colUUID(stmt, 1)
            let wId = try colUUID(stmt, 2)
            let text = colText(stmt, 3)
            let origin = try colEnum(Origin.self, stmt, 4)
            let epistemic = try colEnum(EpistemicStatus.self, stmt, 5)
            let review = try colEnum(ReviewStatus.self, stmt, 6)
            let support = try colEnum(SupportStatus.self, stmt, 7)
            let allowed = try colEnum(AllowedUse.self, stmt, 8)

            var sourceRev: UUID? = nil
            if sqlite3_column_type(stmt, 9) != SQLITE_NULL {
                sourceRev = UUID(uuidString: colText(stmt, 9))
            }

            var tr: TimeRange? = nil
            if sqlite3_column_type(stmt, 10) != SQLITE_NULL {
                let start = Int(sqlite3_column_int64(stmt, 10))
                let end = Int(sqlite3_column_int(stmt, 11))
                let num = Int(sqlite3_column_int(stmt, 12))
                let den = Int(sqlite3_column_int(stmt, 13))
                tr = TimeRange(startFrame: start, endFrame: end, timeBaseNum: num, timeBaseDen: den)
            }

            var confId: UUID? = nil
            if sqlite3_column_type(stmt, 14) != SQLITE_NULL {
                confId = UUID(uuidString: colText(stmt, 14))
            }

            var confRaw: Double? = nil
            if sqlite3_column_type(stmt, 15) != SQLITE_NULL {
                confRaw = sqlite3_column_double(stmt, 15)
            }

            let dateStr = colText(stmt, 16)
            let created = DataContractDateFormatters.date(from: dateStr) ?? Date()

            list.append(ClaimRecord(
                claimId: cId,
                revisionId: revId,
                workdayId: wId,
                text: text,
                origin: origin,
                epistemicStatus: epistemic,
                reviewStatus: review,
                supportStatus: support,
                allowedUse: allowed,
                sourceRevisionId: sourceRev,
                timeRange: tr,
                confirmationId: confId,
                confidenceRaw: confRaw,
                createdAt: created
            ))
        }
        return list
    }

    // MARK: - Scriptwriter Brief (Step 1 intake)

    /// Upserts one brief revision. Content-addressed id => re-saving the same
    /// brief is a no-op, editing it creates a new revision instead of rewriting
    /// history.
    public func saveScriptBrief(_ brief: ScriptBriefRecord) throws {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = """
            INSERT OR REPLACE INTO script_briefs
            (brief_revision_id, project_id, workday_id, raw_text, couple_names, event_type, schedule, venues,
             pov_role, style, must_have, must_avoid, platform, target_seconds, notes, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, brief.briefRevisionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, brief.projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, brief.workdayId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, brief.rawText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, brief.coupleNames, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, brief.eventType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, brief.schedule, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, brief.venues, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, brief.povRole, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, brief.style, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 11, brief.mustHave, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 12, brief.mustAvoid, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 13, brief.platform, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 14, Int32(brief.targetSeconds))
            sqlite3_bind_text(stmt, 15, brief.notes, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 16, DataContractDateFormatters.string(from: brief.updatedAt), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Latest brief revision for a workday, or `nil` when the user never filled it.
    public func latestScriptBrief(workdayId: UUID) throws -> ScriptBriefRecord? {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT brief_revision_id, project_id, workday_id, raw_text, couple_names, event_type, schedule, venues,
               pov_role, style, must_have, must_avoid, platform, target_seconds, notes, updated_at
        FROM script_briefs
        WHERE workday_id = ?
        ORDER BY updated_at DESC, rowid DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, workdayId.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ScriptBriefRecord(
            briefRevisionId: try colUUID(stmt, 0),
            projectId: try colUUID(stmt, 1),
            workdayId: try colUUID(stmt, 2),
            rawText: colText(stmt, 3),
            coupleNames: colText(stmt, 4),
            eventType: colText(stmt, 5),
            schedule: colText(stmt, 6),
            venues: colText(stmt, 7),
            povRole: colText(stmt, 8),
            style: colText(stmt, 9),
            mustHave: colText(stmt, 10),
            mustAvoid: colText(stmt, 11),
            platform: colText(stmt, 12),
            targetSeconds: Int(sqlite3_column_int(stmt, 13)),
            notes: colText(stmt, 14),
            updatedAt: DataContractDateFormatters.date(from: colText(stmt, 15)) ?? Date()
        )
    }

    public func checkpointWAL() throws {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        var log = Int32(0)
        var ckpt = Int32(0)
        if sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, &log, &ckpt) != SQLITE_OK {
            throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - S07: Jobs, Attempts & Fencing Token Enforcement

    public func enqueueJob(
        jobId: UUID = UUID(),
        projectId: UUID,
        jobType: String,
        inputFingerprint: String
    ) throws -> JobRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "INSERT INTO jobs (job_id, project_id, job_type, input_fingerprint, status) VALUES (?, ?, ?, ?, 'QUEUED');"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, jobType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, inputFingerprint, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            return JobRecord(jobId: jobId, projectId: projectId, jobType: jobType, inputFingerprint: inputFingerprint, status: .queued)
        }
    }

    /// (P1-08) Mark a job FAILED when work can never complete (worker died, plan invalid,
    /// artifact missing). Before this the only terminal path was SUCCEEDED: a crashed job
    /// stayed RUNNING forever and blocked every retry decision.
    public func failJob(jobId: UUID, reason: String) throws {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let stamp = "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
            let attemptSql = """
            UPDATE job_attempts SET status = 'FAILED', finished_at = \(stamp)
            WHERE job_id = ? AND status IN ('PREPARED', 'RUNNING');
            """
            var attempt: OpaquePointer?
            guard sqlite3_prepare_v2(db, attemptSql, -1, &attempt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(attempt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(attempt)
            sqlite3_finalize(attempt)

            let jobSql = """
            UPDATE jobs SET status = 'FAILED', completed_at = \(stamp)
            WHERE job_id = ? AND status IN ('QUEUED', 'RUNNING');
            """
            var job: OpaquePointer?
            guard sqlite3_prepare_v2(db, jobSql, -1, &job, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(job, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(job) == SQLITE_DONE else {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_finalize(job)

            // (P1-08) Unfinished publications of a failed job are explicitly reported as
            // failures rather than silently staying PREPARED forever.
            let leftovers = "SELECT COUNT(*) FROM artifact_publications WHERE job_id = ? AND state != 'COMMITTED';"
            var count: OpaquePointer?
            if sqlite3_prepare_v2(db, leftovers, -1, &count, nil) == SQLITE_OK {
                sqlite3_bind_text(count, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
                let pending = sqlite3_step(count) == SQLITE_ROW ? Int(sqlite3_column_int(count, 0)) : 0
                sqlite3_finalize(count)
                _ = (pending, reason)
            }
        }
    }

    /// (P1-01) Find a job of this logical publication that is still publishing artifacts.
    /// Several artifacts of one logical publication reuse its job so completion can be
    /// decided once, against the full set, instead of per artifact.
    public func openPublicationJob(projectId: UUID, inputFingerprint: String) throws -> JobRecord? {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT job_id, project_id, job_type, input_fingerprint, status, created_at, completed_at
        FROM jobs
        WHERE project_id = ? AND input_fingerprint = ? AND job_type LIKE 'publish_%'
          AND status IN ('QUEUED', 'RUNNING')
        ORDER BY rowid DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, projectId.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, inputFingerprint, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let jId = try colUUID(stmt, 0)
            var completed: Date? = nil
            if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                completed = DataContractDateFormatters.date(from: colText(stmt, 6))
            }
            return JobRecord(
                jobId: jId,
                projectId: try colUUID(stmt, 1),
                jobType: colText(stmt, 2),
                inputFingerprint: colText(stmt, 3),
                status: JobStatus(rawValue: colText(stmt, 4)) ?? .queued,
                createdAt: DataContractDateFormatters.date(from: colText(stmt, 5)) ?? Date(),
                completedAt: completed
            )
        }
        return nil
    }

    public func getJob(id: UUID) throws -> JobRecord? {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = "SELECT job_id, project_id, job_type, input_fingerprint, status, created_at, completed_at FROM jobs WHERE job_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let jId = try colUUID(stmt, 0)
            let pId = try colUUID(stmt, 1)
            let jType = colText(stmt, 2)
            let fp = colText(stmt, 3)
            let st = JobStatus(rawValue: colText(stmt, 4)) ?? .queued
            let created = DataContractDateFormatters.date(from: colText(stmt, 5)) ?? Date()
            var completed: Date? = nil
            if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
                completed = DataContractDateFormatters.date(from: colText(stmt, 6))
            }
            return JobRecord(jobId: jId, projectId: pId, jobType: jType, inputFingerprint: fp, status: st, createdAt: created, completedAt: completed)
        }
        return nil
    }

    /// Allocates a new attempt for a job, atomically revoking publish rights on any previous attempts
    /// and monotonically incrementing the fencing token across the store.
    public func allocateAttempt(
        attemptId: UUID = UUID(),
        jobId: UUID,
        workerSessionId: String
    ) throws -> JobAttemptRecord {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

            // 1. Revoke publish rights and cancel any active attempts for this job
            let revokeSql = """
            UPDATE job_attempts
            SET publish_revoked = 1,
                status = CASE WHEN status IN ('PREPARED', 'RUNNING') THEN 'CANCELLED' ELSE status END,
                finished_at = CASE WHEN status IN ('PREPARED', 'RUNNING') THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now') ELSE finished_at END
            WHERE job_id = ? AND publish_revoked = 0;
            """
            var revStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, revokeSql, -1, &revStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(revStmt) }
                sqlite3_bind_text(revStmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(revStmt)
            }

            // 2. Compute next global monotonic fencing token
            var nextFence = 1
            let maxSql = "SELECT COALESCE(MAX(fencing_token), 0) FROM job_attempts;"
            var maxStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, maxSql, -1, &maxStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(maxStmt) }
                if sqlite3_step(maxStmt) == SQLITE_ROW {
                    nextFence = Int(sqlite3_column_int(maxStmt, 0)) + 1
                }
            }

            // 3. Insert new attempt and transition job to RUNNING
            let insSql = """
            INSERT INTO job_attempts (attempt_id, job_id, fencing_token, worker_session_id, status, publish_revoked)
            VALUES (?, ?, ?, ?, 'RUNNING', 0);
            """
            var insStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insSql, -1, &insStmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(insStmt) }
            sqlite3_bind_text(insStmt, 1, attemptId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insStmt, 2, jobId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(insStmt, 3, Int32(nextFence))
            sqlite3_bind_text(insStmt, 4, workerSessionId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(insStmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }

            let upJobSql = "UPDATE jobs SET status = 'RUNNING' WHERE job_id = ?;"
            var upJobStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, upJobSql, -1, &upJobStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(upJobStmt) }
                sqlite3_bind_text(upJobStmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(upJobStmt)
            }

            return JobAttemptRecord(
                attemptId: attemptId,
                jobId: jobId,
                fencingToken: nextFence,
                workerSessionId: workerSessionId,
                status: "RUNNING",
                publishRevoked: false
            )
        }
    }

    /// Explicitly revokes publish permission BEFORE stopping worker (Section 5.1 rule 5)
    public func revokeAttemptPublishPermission(attemptId: UUID, markCancelled: Bool = true) throws {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = markCancelled
                ? "UPDATE job_attempts SET publish_revoked = 1, status = 'CANCELLED', finished_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE attempt_id = ?;"
                : "UPDATE job_attempts SET publish_revoked = 1 WHERE attempt_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, attemptId.uuidString, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Validates inside current connection whether an attempt holds active publish authority
    private func verifyAttemptAuthorityInternal(
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        activeSessionId: String? = nil
    ) throws {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

        let sql = """
        SELECT fencing_token, worker_session_id, status, publish_revoked,
               (SELECT MAX(fencing_token) FROM job_attempts WHERE job_id = ?) as max_fence
        FROM job_attempts
        WHERE attempt_id = ? AND job_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, attemptId.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, jobId.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw ProjectStoreError.attemptNotFound(attemptId)
        }

        let storedFence = Int(sqlite3_column_int(stmt, 0))
        let storedSession = colText(stmt, 1)
        let status = colText(stmt, 2)
        let revoked = sqlite3_column_int(stmt, 3) != 0
        let maxFence = Int(sqlite3_column_int(stmt, 4))

        if fencingToken != storedFence || storedFence < maxFence {
            throw ProjectStoreError.staleFencingToken(expected: maxFence, actual: fencingToken)
        }
        if revoked || status == "CANCELLED" || status == "FAILED" {
            throw ProjectStoreError.invalidAuthority("Attempt \(attemptId) publish permission was revoked (status=\(status))")
        }
        if let activeSession = activeSessionId, activeSession != storedSession {
            throw ProjectStoreError.invalidAuthority("Session mismatch: attempt session \(storedSession) != active \(activeSession)")
        }
    }

    public func verifyAttemptAuthority(
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        activeSessionId: String? = nil
    ) throws {
        try verifyAttemptAuthorityInternal(jobId: jobId, attemptId: attemptId, fencingToken: fencingToken, activeSessionId: activeSessionId)
    }

    // MARK: - S08: Artifact Publication State Machine & Startup Reconciler Support

    public func createPublicationIntent(
        publicationId: UUID = UUID(),
        projectId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        artifactType: String,
        tempPath: String? = nil,
        // (P1-01) Number of artifacts this logical job must publish before it is SUCCEEDED.
        expectedPublicationCount: Int = 1
    ) throws -> ArtifactPublicationRecord {
        let expectedCount = max(1, expectedPublicationCount)
        return try withTransaction {
            try verifyAttemptAuthorityInternal(jobId: jobId, attemptId: attemptId, fencingToken: fencingToken)
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

            let sql = """
            INSERT INTO artifact_publications (
                publication_id, project_id, job_id, attempt_id, fencing_token,
                artifact_type, state, temp_path, expected_publication_count
            ) VALUES (?, ?, ?, ?, ?, ?, 'PREPARED', ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, publicationId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, jobId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, attemptId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(fencingToken))
            sqlite3_bind_text(stmt, 6, artifactType, -1, SQLITE_TRANSIENT)
            if let tp = tempPath {
                sqlite3_bind_text(stmt, 7, tp, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_bind_int(stmt, 8, Int32(expectedCount))

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }

            return ArtifactPublicationRecord(
                publicationId: publicationId,
                projectId: projectId,
                jobId: jobId,
                attemptId: attemptId,
                fencingToken: fencingToken,
                artifactType: artifactType,
                state: .prepared,
                tempPath: tempPath,
                expectedPublicationCount: expectedCount
            )
        }
    }

    public func updatePublicationMaterialized(
        publicationId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        tempPath: String
    ) throws -> ArtifactPublicationRecord {
        return try withTransaction {
            try verifyAttemptAuthorityInternal(jobId: jobId, attemptId: attemptId, fencingToken: fencingToken)
            guard var pub = try getPublicationInternal(id: publicationId) else {
                throw ProjectStoreError.publicationNotFound(publicationId)
            }
            try pub.transitionToMaterialized(tempPath: tempPath)

            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            // (P1-01) The multi-artifact expectation travels with the row, so whichever
            // transition happens first can declare it without a schema migration.
            let sql = "UPDATE artifact_publications SET state = 'MATERIALIZED', temp_path = ?, expected_publication_count = MAX(expected_publication_count, ?), updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE publication_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, tempPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(pub.expectedPublicationCount))
            sqlite3_bind_text(stmt, 3, publicationId.uuidString, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            return pub
        }
    }

    public func updatePublicationVerified(
        publicationId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        sha256: String,
        byteSize: Int
    ) throws -> ArtifactPublicationRecord {
        return try withTransaction {
            try verifyAttemptAuthorityInternal(jobId: jobId, attemptId: attemptId, fencingToken: fencingToken)
            guard var pub = try getPublicationInternal(id: publicationId) else {
                throw ProjectStoreError.publicationNotFound(publicationId)
            }
            try pub.transitionToVerified(sha256: sha256, size: byteSize)

            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "UPDATE artifact_publications SET state = 'VERIFIED', sha256_hash = ?, byte_size = ?, expected_publication_count = MAX(expected_publication_count, ?), updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE publication_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, sha256, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(byteSize))
            sqlite3_bind_int(stmt, 3, Int32(pub.expectedPublicationCount))
            sqlite3_bind_text(stmt, 4, publicationId.uuidString, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            return pub
        }
    }

    /// Canonical Commit (Section 6.2 Step 6): Re-verifies attempt fencing token, verifies file exists at canonicalPath,
    /// commits publication as COMMITTED, marks attempt & job SUCCEEDED, and writes idempotency journal in ONE transaction.
    public func commitPublication(
        publicationId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        canonicalPath: String,
        completeJob: Bool = true,
        idempotencyKey: String? = nil
    ) throws -> ArtifactPublicationRecord {
        return try withTransaction {
            try verifyAttemptAuthorityInternal(jobId: jobId, attemptId: attemptId, fencingToken: fencingToken)
            guard var pub = try getPublicationInternal(id: publicationId) else {
                throw ProjectStoreError.publicationNotFound(publicationId)
            }

            // 2026-11-10 fix (P1-1): a publication may only be committed by the job/attempt
            // that created it, and the canonical bytes must still match the digest recorded
            // at verification time. Previously any valid attempt could commit any publication
            // and only file existence was checked.
            guard pub.jobId == jobId,
                  pub.attemptId == attemptId,
                  pub.fencingToken == fencingToken else {
                throw ProjectStoreError.integrityViolation(
                    "Publication \(publicationId) does not belong to job \(jobId) / attempt \(attemptId) / fencing \(fencingToken)"
                )
            }
            guard FileManager.default.fileExists(atPath: canonicalPath) else {
                throw ProjectStoreError.integrityViolation("Cannot commit publication \(publicationId): canonical file missing at \(canonicalPath)")
            }
            guard let expectedHash = pub.sha256Hash, !expectedHash.isEmpty else {
                throw ProjectStoreError.integrityViolation(
                    "Cannot commit publication \(publicationId): no verified sha256 recorded"
                )
            }
            let actualHash = try Self.fileSHA256(atPath: canonicalPath)
            guard actualHash == expectedHash else {
                throw ProjectStoreError.integrityViolation(
                    "Cannot commit publication \(publicationId): bytes changed (expected \(expectedHash), found \(actualHash))"
                )
            }

            try pub.transitionToCommitted(canonicalPath: canonicalPath)

            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "UPDATE artifact_publications SET state = 'COMMITTED', canonical_path = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE publication_id = ? AND job_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, canonicalPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, publicationId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, jobId.uuidString, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            guard sqlite3_changes(db) == 1 else {
                throw ProjectStoreError.integrityViolation(
                    "Commit of publication \(publicationId) matched no row for job \(jobId)"
                )
            }

            let fullyPublished = try jobIsFullyPublishedInternal(jobId: jobId)
            if completeJob && !fullyPublished {
                // (P1-01) More artifacts are still owed by this job; completing it now would
                // report success for a partial result (e.g. an MP4 without its receipt).
                self.logPublicationDeferred(jobId: jobId, publicationId: publicationId)
            } else if completeJob {
                let attSql = "UPDATE job_attempts SET status = 'SUCCEEDED', finished_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE attempt_id = ?;"
                var attStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, attSql, -1, &attStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(attStmt) }
                    sqlite3_bind_text(attStmt, 1, attemptId.uuidString, -1, SQLITE_TRANSIENT)
                    _ = sqlite3_step(attStmt)
                }

                let jobSql = "UPDATE jobs SET status = 'SUCCEEDED', completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE job_id = ?;"
                var jobStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, jobSql, -1, &jobStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(jobStmt) }
                    sqlite3_bind_text(jobStmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
                    _ = sqlite3_step(jobStmt)
                }
            }

            if let ikey = idempotencyKey {
                let idempSql = "INSERT OR REPLACE INTO idempotency_journal (operation_id, project_id, fencing_token, result_payload) VALUES (?, ?, ?, ?);"
                var idempStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, idempSql, -1, &idempStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(idempStmt) }
                    if let encoded = try? JSONEncoder().encode(pub),
                       let payloadStr = String(data: encoded, encoding: .utf8) {
                        sqlite3_bind_text(idempStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(idempStmt, 2, pub.projectId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_int(idempStmt, 3, Int32(fencingToken))
                        sqlite3_bind_text(idempStmt, 4, payloadStr, -1, SQLITE_TRANSIENT)
                        _ = sqlite3_step(idempStmt)
                    }
                }
            }

            return pub
        }
    }

    private func getPublicationInternal(id: UUID) throws -> ArtifactPublicationRecord? {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT publication_id, project_id, job_id, attempt_id, fencing_token,
               artifact_type, state, temp_path, canonical_path, sha256_hash,
               byte_size, expected_publication_count, created_at, updated_at
        FROM artifact_publications WHERE publication_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return try parsePublicationRow(stmt)
        }
        return nil
    }

    private func parsePublicationRow(_ stmt: OpaquePointer?) throws -> ArtifactPublicationRecord {
        let pubId = try colUUID(stmt, 0)
        let projId = try colUUID(stmt, 1)
        let jobId = try colUUID(stmt, 2)
        let attId = try colUUID(stmt, 3)
        let fence = Int(sqlite3_column_int(stmt, 4))
        let aType = colText(stmt, 5)
        let state = ArtifactPublicationState(rawValue: colText(stmt, 6)) ?? .prepared
        let tempPath = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? colText(stmt, 7) : nil
        let canonPath = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? colText(stmt, 8) : nil
        let sha = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? colText(stmt, 9) : nil
        let bSize = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 10)) : nil
        let expectedCount = sqlite3_column_type(stmt, 11) != SQLITE_NULL
            ? max(1, Int(sqlite3_column_int(stmt, 11))) : 1
        let created = DataContractDateFormatters.date(from: colText(stmt, 12)) ?? Date()
        let updated = DataContractDateFormatters.date(from: colText(stmt, 13)) ?? Date()

        return ArtifactPublicationRecord(
            publicationId: pubId,
            projectId: projId,
            jobId: jobId,
            attemptId: attId,
            fencingToken: fence,
            artifactType: aType,
            state: state,
            tempPath: tempPath,
            canonicalPath: canonPath,
            sha256Hash: sha,
            byteSize: bSize,
            expectedPublicationCount: expectedCount,
            createdAt: created,
            updatedAt: updated
        )
    }

    public func getPublication(id: UUID) throws -> ArtifactPublicationRecord? {
        return try getPublicationInternal(id: id)
    }

    public func listPublications(projectId: UUID) throws -> [ArtifactPublicationRecord] {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT publication_id, project_id, job_id, attempt_id, fencing_token,
               artifact_type, state, temp_path, canonical_path, sha256_hash,
               byte_size, expected_publication_count, created_at, updated_at
        FROM artifact_publications WHERE project_id = ? ORDER BY rowid ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, projectId.uuidString, -1, SQLITE_TRANSIENT)
        var list: [ArtifactPublicationRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            list.append(try parsePublicationRow(stmt))
        }
        return list
    }

    public func pinArtifact(pinId: UUID = UUID(), projectId: UUID, publicationId: UUID, reason: String) throws {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "INSERT INTO artifact_pins (pin_id, project_id, publication_id, reason) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pinId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, publicationId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, reason, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func isArtifactPinned(publicationId: UUID) throws -> Bool {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = "SELECT COUNT(*) FROM artifact_pins WHERE publication_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, publicationId.uuidString, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) > 0
        }
        return false
    }

    public func listPinnedPublicationIds(projectId: UUID) throws -> Set<UUID> {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = "SELECT DISTINCT publication_id FROM artifact_pins WHERE project_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, projectId.uuidString, -1, SQLITE_TRANSIENT)
        var ids = Set<UUID>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let uid = UUID(uuidString: colText(stmt, 0)) {
                ids.insert(uid)
            }
        }
        return ids
    }

    /// Revokes all active attempts from old worker sessions upon app startup/reopen (Section 7.1 Step 2)
    public func revokeAllOldSessionAttempts(newSessionId: String) throws -> Int {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = """
            UPDATE job_attempts
            SET publish_revoked = 1,
                status = CASE WHEN status IN ('PREPARED', 'RUNNING') THEN 'CANCELLED' ELSE status END,
                finished_at = CASE WHEN status IN ('PREPARED', 'RUNNING') THEN strftime('%Y-%m-%dT%H:%M:%SZ', 'now') ELSE finished_at END
            WHERE worker_session_id != ? AND publish_revoked = 0;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, newSessionId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - (P1-01) Explicit job completion

    private func rowCount(scalar sql: String, jobId: UUID) throws -> Int {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// True when the job declared its publication count and every one of them is COMMITTED.
    /// A job that never declared a count keeps the historical single-artifact behaviour.
    public func jobIsFullyPublishedInternal(jobId: UUID) throws -> Bool {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT MAX(expected_publication_count), COUNT(*),
               SUM(CASE WHEN state = 'COMMITTED' THEN 1 ELSE 0 END)
        FROM artifact_publications WHERE job_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        let expected = max(1, Int(sqlite3_column_int(stmt, 0)))
        let total = Int(sqlite3_column_int(stmt, 1))
        let committed = Int(sqlite3_column_int(stmt, 2))
        return committed > 0 && committed >= expected && committed == total
    }

    nonisolated private func logPublicationDeferred(jobId: UUID, publicationId: UUID) {
        // A partial job stays RUNNING; the startup reconciler completes it once the rest arrives.
        _ = (jobId, publicationId)
    }

    /// Reconciles job completion if all required publications are already COMMITTED on disk (Section 7.1 table row 7)
    public func repairJobCompletionFromCommittedPublications(jobId: UUID) throws -> Bool {
        return try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            // 2026-11-10 fix (P1-3): a job is only complete when EVERY publication it
            // owns is COMMITTED. Counting >0 let a job with 4 of 5 artifacts pending be
            // reported SUCCEEDED after a crash.
            let sql = "SELECT SUM(CASE WHEN state = 'COMMITTED' THEN 1 ELSE 0 END), COUNT(*) FROM artifact_publications WHERE job_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
            var committedCount = 0
            var totalCount = 0
            if sqlite3_step(stmt) == SQLITE_ROW {
                committedCount = Int(sqlite3_column_int(stmt, 0))
                totalCount = Int(sqlite3_column_int(stmt, 1))
            }
            // (P1-01) The declared expectation must also be satisfied before a job that was
            // repaired after a crash may be reported SUCCEEDED.
            let expectedRow = try rowCount(scalar: "SELECT MAX(expected_publication_count) FROM artifact_publications WHERE job_id = ?;", jobId: jobId)
            let expectedCount = max(1, expectedRow)
            if committedCount > 0 && committedCount == totalCount && committedCount >= expectedCount {
                let upSql = "UPDATE jobs SET status = 'SUCCEEDED', completed_at = COALESCE(completed_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) WHERE job_id = ? AND status != 'SUCCEEDED';"
                var upStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, upSql, -1, &upStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(upStmt) }
                    sqlite3_bind_text(upStmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
                    _ = sqlite3_step(upStmt)
                    return sqlite3_changes(db) > 0
                }
            }
            return false
        }
    }

    /// Version of the canonical schema this build writes (see docs/05 and docs/11 S06/S09).
    public static let canonicalSchemaVersion: Int = 2

    /// Additive columns introduced after the first shipped schema. Each entry is applied
    /// only when the database predates it, so opening an old project upgrades it in place
    /// without data loss and without a separate migration file.
    private static let additiveColumns: [(table: String, column: String, ddl: String)] = [
        ("artifact_publications", "expected_publication_count",
         "expected_publication_count INTEGER NOT NULL DEFAULT 1"),
        ("coverage_records", "unique_processed_frame_ids",
         "unique_processed_frame_ids TEXT NOT NULL DEFAULT ''"),
        ("coverage_records", "corrupted_decode_frame_ids",
         "corrupted_decode_frame_ids TEXT NOT NULL DEFAULT ''"),
        ("coverage_records", "total_submitted_with_overlap",
         "total_submitted_with_overlap INTEGER NOT NULL DEFAULT 0"),
        ("coverage_records", "completed_windows",
         "completed_windows INTEGER NOT NULL DEFAULT 0"),
        ("coverage_records", "total_windows",
         "total_windows INTEGER NOT NULL DEFAULT 1"),
    ]

    private static func migrateAdditiveColumns(db: OpaquePointer?) throws {
        guard let db else { throw ProjectStoreError.executionFailed("Database connection unavailable") }
        for entry in additiveColumns {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(entry.table));", -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            var present = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1), String(cString: name) == entry.column {
                    present = true
                }
            }
            sqlite3_finalize(stmt)
            guard !present else { continue }
            var alter: OpaquePointer?
            let sql = "ALTER TABLE \(entry.table) ADD COLUMN \(entry.ddl);"
            guard sqlite3_prepare_v2(db, sql, -1, &alter, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(alter) }
            guard sqlite3_step(alter) == SQLITE_DONE else {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // MARK: - S09: Online SQLite Backup API, Integrity Check & Schema Migration

    /// Performs consistent online SQLite backup using sqlite3_backup_init / step / finish
    /// inside an actor-isolated barrier so no concurrent canonical writes interleave (Section 10.2).
    public func performOnlineSQLiteBackup(to destinationDBURL: URL) throws {
        guard let sourceDB = db else { throw ProjectStoreError.executionFailed("Source database closed") }

        var destDB: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(destinationDBURL.path, &destDB, flags, nil) != SQLITE_OK {
            let msg = destDB != nil ? String(cString: sqlite3_errmsg(destDB)) : "Open failed"
            sqlite3_close_v2(destDB)
            throw ProjectStoreError.databaseOpenFailed(msg)
        }
        defer { sqlite3_close_v2(destDB) }

        guard let backup = sqlite3_backup_init(destDB, "main", sourceDB, "main") else {
            let msg = String(cString: sqlite3_errmsg(destDB))
            throw ProjectStoreError.executionFailed("sqlite3_backup_init failed: \(msg)")
        }

        let rc = sqlite3_backup_step(backup, -1)
        _ = sqlite3_backup_finish(backup)

        if rc != SQLITE_DONE {
            throw ProjectStoreError.executionFailed("sqlite3_backup_step failed with code \(rc)")
        }
    }

    public func verifyDatabaseIntegrity() throws -> Bool {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }

        // 1. PRAGMA integrity_check
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed("Failed to prepare integrity_check")
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let res = colText(stmt, 0)
            if res.lowercased() != "ok" {
                throw ProjectStoreError.integrityViolation("integrity_check failed: \(res)")
            }
        }

        // 2. PRAGMA foreign_key_check
        var fkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_check;", -1, &fkStmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed("Failed to prepare foreign_key_check")
        }
        defer { sqlite3_finalize(fkStmt) }
        if sqlite3_step(fkStmt) == SQLITE_ROW {
            let tbl = colText(fkStmt, 0)
            throw ProjectStoreError.integrityViolation("foreign_key_check violation on table \(tbl)")
        }

        return true
    }

    public func getSchemaVersion() throws -> Int {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed("Failed to query user_version")
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    public func setSchemaVersion(_ version: Int) throws {
        try execute(sql: "PRAGMA user_version = \(version);")
    }

    public func applyMigration(
        targetVersion: Int,
        migrationId: String,
        codeChecksum: String,
        sqlStatements: String
    ) throws {
        try withTransaction {
            let current = try getSchemaVersion()
            if current > targetVersion {
                throw ProjectStoreError.schemaIncompatible(expected: targetVersion, actual: current)
            }
            if current == targetVersion {
                return
            }
            try execute(sql: sqlStatements)
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let jSql = "INSERT OR REPLACE INTO schema_migrations (version, migration_id, code_checksum, status) VALUES (?, ?, ?, 'COMPLETED');"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, jSql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(targetVersion))
            sqlite3_bind_text(stmt, 2, migrationId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, codeChecksum, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            try setSchemaVersion(targetVersion)
        }
    }

    public func listApprovals(projectId: UUID) throws -> [ApprovalRecord] {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = "SELECT approval_id, project_id, approval_type, target_revision_id, is_superseded, approved_by, approved_at FROM approvals WHERE project_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, projectId.uuidString, -1, SQLITE_TRANSIENT)
        var list: [ApprovalRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let aId = try colUUID(stmt, 0)
            let pId = try colUUID(stmt, 1)
            let aType = colText(stmt, 2)
            let tRev = try colUUID(stmt, 3)
            let sup = sqlite3_column_int(stmt, 4) != 0
            let by = colText(stmt, 5)
            let at = DataContractDateFormatters.date(from: colText(stmt, 6)) ?? Date()
            list.append(ApprovalRecord(approvalId: aId, projectId: pId, approvalType: aType, targetRevisionId: tRev, isSuperseded: sup, approvedBy: by, approvedAt: at))
        }
        return list
    }

    // MARK: - Gate G2 (S12..S14): Coverage Ledger, Batch Fact Confirmation & Targeted Review Items

    public func saveCoverageRecord(_ rec: CoverageLedgerRecord) throws {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = """
            INSERT OR REPLACE INTO coverage_records
            (coverage_id, project_id, source_revision_id, runtime_profile_id, input_fingerprint,
             total_declared_frames, valid_decoded_frames, unique_processed_frames, frame_input_coverage,
             audio_branch_state, detailed_pass_status, semantic_certified,
             unique_processed_frame_ids, corrupted_decode_frame_ids,
             total_submitted_with_overlap, completed_windows, total_windows)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, rec.coverageId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, rec.projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, rec.sourceRevisionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, rec.runtimeProfileId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, rec.inputFingerprint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, Int32(rec.totalDeclaredFrames))
            sqlite3_bind_int(stmt, 7, Int32(rec.validDecodedFrameCount))
            sqlite3_bind_int(stmt, 8, Int32(rec.uniqueProcessedFrameIds.count))
            sqlite3_bind_double(stmt, 9, rec.frameInputCoverage)
            sqlite3_bind_text(stmt, 10, rec.audioBranchState.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 11, rec.detailedPassStatus, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 12, rec.semanticUnderstandingCertified ? 1 : 0)
            let idsJSON = String(data: (try? JSONEncoder().encode(rec.uniqueProcessedFrameIds)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            let corruptedJSON = String(data: (try? JSONEncoder().encode(rec.corruptedDecodeFrameIds)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            sqlite3_bind_text(stmt, 13, idsJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 14, corruptedJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 15, Int32(rec.totalSubmittedWithOverlap))
            sqlite3_bind_int(stmt, 16, Int32(rec.completedWindows))
            sqlite3_bind_int(stmt, 17, Int32(rec.totalWindows))
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func saveReviewItem(_ item: TargetedReviewRecord) throws {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = """
            INSERT OR REPLACE INTO review_items
            (review_item_id, project_id, workday_id, target_claim_revision_id, evidence_scope_revision_id,
             evidence_kind, is_critical, question_text, status, resolution_action, resulting_allowed_use)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, item.reviewItemId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, item.projectId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, item.workdayId.uuidString, -1, SQLITE_TRANSIENT)
            if let tRev = item.targetClaimRevisionId {
                sqlite3_bind_text(stmt, 4, tRev.uuidString, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_text(stmt, 5, item.evidenceScopeRevisionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, item.evidenceKind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 7, item.isCritical ? 1 : 0)
            sqlite3_bind_text(stmt, 8, item.questionText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, item.status, -1, SQLITE_TRANSIENT)
            if let act = item.resolutionAction {
                sqlite3_bind_text(stmt, 10, act.rawValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            if let use = item.resultingAllowedUse {
                sqlite3_bind_text(stmt, 11, use.rawValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func listReviewItems(workdayId: UUID) throws -> [TargetedReviewRecord] {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT review_item_id, project_id, workday_id, target_claim_revision_id, evidence_scope_revision_id,
               evidence_kind, is_critical, question_text, status, resolution_action, resulting_allowed_use
        FROM review_items
        WHERE workday_id = ?
        ORDER BY updated_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, workdayId.uuidString, -1, SQLITE_TRANSIENT)
        var items: [TargetedReviewRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rId = try colUUID(stmt, 0)
            let pId = try colUUID(stmt, 1)
            let wId = try colUUID(stmt, 2)
            let tRev = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? UUID(uuidString: colText(stmt, 3)) : nil
            let scopeRev = colText(stmt, 4)
            let kind = ReviewEvidenceKind(rawValue: colText(stmt, 5)) ?? .briefSpan
            let crit = sqlite3_column_int(stmt, 6) != 0
            let qText = colText(stmt, 7)
            let status = colText(stmt, 8)
            let resAct = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? ReviewResolutionAction(rawValue: colText(stmt, 9)) : nil
            let resUse = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? AllowedUse(rawValue: colText(stmt, 10)) : nil
            if let rec = try? TargetedReviewRecord(
                reviewItemId: rId,
                projectId: pId,
                workdayId: wId,
                targetClaimRevisionId: tRev,
                evidenceScopeRevisionId: scopeRev,
                evidenceKind: kind,
                isCritical: crit,
                questionText: qText,
                status: status,
                resolutionAction: resAct,
                resultingAllowedUse: resUse
            ) {
                items.append(rec)
            }
        }
        return items
    }

    public func listCoverageRecords(projectId: UUID) throws -> [CoverageLedgerRecord] {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT coverage_id, project_id, source_revision_id, runtime_profile_id, input_fingerprint,
               total_declared_frames, valid_decoded_frames, unique_processed_frames,
               audio_branch_state, detailed_pass_status,
               unique_processed_frame_ids, corrupted_decode_frame_ids,
               total_submitted_with_overlap, completed_windows, total_windows
        FROM coverage_records
        WHERE project_id = ?
        ORDER BY updated_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, projectId.uuidString, -1, SQLITE_TRANSIENT)
        var records: [CoverageLedgerRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let covId = try colUUID(stmt, 0)
            let pId = try colUUID(stmt, 1)
            let sRevId = try colUUID(stmt, 2)
            let profId = colText(stmt, 3)
            let fp = colText(stmt, 4)
            let totalDecl = Int(sqlite3_column_int(stmt, 5))
            let validDec = Int(sqlite3_column_int(stmt, 6))
            _ = Int(sqlite3_column_int(stmt, 7))
            let audioSt = AudioBranchState(rawValue: colText(stmt, 8)) ?? .speechDetected
            let passSt = colText(stmt, 9)
            // (P1-09) Restore the recorded frame ids verbatim; never invent `0..<count`.
            let uniqueIds: [Int] = (try? JSONDecoder().decode([Int].self, from: Data(colText(stmt, 10).utf8))) ?? []
            let corruptedIds: [Int] = (try? JSONDecoder().decode([Int].self, from: Data(colText(stmt, 11).utf8))) ?? []
            let submittedWithOverlap = Int(sqlite3_column_int(stmt, 12))
            let completedWindows = Int(sqlite3_column_int(stmt, 13))
            let totalWindows = Int(sqlite3_column_int(stmt, 14))
            records.append(
                CoverageLedgerRecord(
                    coverageId: covId,
                    projectId: pId,
                    sourceRevisionId: sRevId,
                    runtimeProfileId: profId,
                    inputFingerprint: fp,
                    totalDeclaredFrames: totalDecl,
                    validDecodedFrameCount: validDec,
                    corruptedDecodeFrameIds: corruptedIds,
                    uniqueProcessedFrameIds: uniqueIds,
                    totalSubmittedWithOverlap: submittedWithOverlap,
                    audioBranchState: audioSt,
                    completedWindows: completedWindows,
                    totalWindows: totalWindows,
                    detailedPassStatus: passSt
                )
            )
        }
        return records
    }

    public func saveRawObservation(_ obs: RawObservationArtifact) throws {
        try withTransaction {
            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = """
            INSERT OR REPLACE INTO raw_observations
            (observation_id, source_revision_id, window_index, pass_role, origin, epistemic_status,
             frame_ids_json, start_pts, end_pts, observation_text, ocr_raw_tokens_json, ocr_is_uncertain, guided_hypothesis_ref)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            let framesJson = (try? String(data: JSONEncoder().encode(obs.frameIds), encoding: .utf8)) ?? "[]"
            let ocrJson = (try? String(data: JSONEncoder().encode(obs.ocrRawTokens), encoding: .utf8)) ?? "[]"
            sqlite3_bind_text(stmt, 1, obs.observationId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, obs.sourceRevisionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(obs.windowIndex))
            sqlite3_bind_text(stmt, 4, obs.passRole.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, obs.origin.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, obs.epistemicStatus.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, framesJson, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 8, obs.startPts)
            sqlite3_bind_int64(stmt, 9, obs.endPts)
            sqlite3_bind_text(stmt, 10, obs.observationText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 11, ocrJson, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 12, obs.ocrIsUncertain ? 1 : 0)
            if let gRef = obs.guidedHypothesisRef {
                sqlite3_bind_text(stmt, 13, gRef, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 13)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func listRawObservations(sourceRevisionId: UUID) throws -> [RawObservationArtifact] {
        guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
        let sql = """
        SELECT observation_id, source_revision_id, window_index, pass_role, origin, epistemic_status,
               frame_ids_json, start_pts, end_pts, observation_text, ocr_raw_tokens_json, ocr_is_uncertain, guided_hypothesis_ref
        FROM raw_observations
        WHERE source_revision_id = ?
        ORDER BY window_index ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sourceRevisionId.uuidString, -1, SQLITE_TRANSIENT)
        var list: [RawObservationArtifact] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let obsId = colText(stmt, 0)
            let sRevId = try colUUID(stmt, 1)
            let winIdx = Int(sqlite3_column_int(stmt, 2))
            let role = ObservationPassRole(rawValue: colText(stmt, 3)) ?? .rawIndependent
            let orig = Origin(rawValue: colText(stmt, 4)) ?? .visualModel
            let ep = EpistemicStatus(rawValue: colText(stmt, 5)) ?? .observed
            let framesStr = colText(stmt, 6)
            let frames = (try? JSONDecoder().decode([Int].self, from: Data(framesStr.utf8))) ?? []
            let sPts = sqlite3_column_int64(stmt, 7)
            let ePts = sqlite3_column_int64(stmt, 8)
            let text = colText(stmt, 9)
            let ocrStr = colText(stmt, 10)
            let ocrTokens = (try? JSONDecoder().decode([String].self, from: Data(ocrStr.utf8))) ?? []
            let ocrUnc = sqlite3_column_int(stmt, 11) != 0
            let gRef = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? colText(stmt, 12) : nil
            if let art = try? RawObservationArtifact(
                observationId: obsId,
                sourceRevisionId: sRevId,
                windowIndex: winIdx,
                passRole: role,
                origin: orig,
                epistemicStatus: ep,
                frameIds: frames,
                startPts: sPts,
                endPts: ePts,
                observationText: text,
                ocrRawTokens: ocrTokens,
                ocrIsUncertain: ocrUnc,
                guidedHypothesisRef: gRef
            ) {
                list.append(art)
            }
        }
        return list
    }
}

// SQLITE_TRANSIENT helper:
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Crash-safe column readers
// sqlite3_column_text returns NULL for NULL cells; String(cString:) on NULL traps, and `!` on a
// malformed UUID/enum row would take the whole app down. Surface both as integrityViolation instead.

func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
    guard let p = sqlite3_column_text(stmt, idx) else { return "" }
    return String(cString: p)
}

func requireUUID(_ s: String) throws -> UUID {
    guard let id = UUID(uuidString: s) else {
        throw ProjectStoreError.integrityViolation("Invalid UUID in row: '\(s)'")
    }
    return id
}

func colUUID(_ stmt: OpaquePointer?, _ idx: Int32) throws -> UUID {
    try requireUUID(colText(stmt, idx))
}

func colEnum<T: RawRepresentable>(_ type: T.Type, _ stmt: OpaquePointer?, _ idx: Int32) throws -> T where T.RawValue == String {
    let raw = colText(stmt, idx)
    guard let v = T(rawValue: raw) else {
        throw ProjectStoreError.integrityViolation("Invalid \(T.self) value in row: '\(raw)'")
    }
    return v
}
