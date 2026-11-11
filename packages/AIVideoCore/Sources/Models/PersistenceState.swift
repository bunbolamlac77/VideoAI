//
// PersistenceState.swift — typed save state instead of matching Vietnamese prefixes.
//
// (P2-07) The UI decided colour by `status.hasPrefix("Đã lưu")` / `hasPrefix("Lưu lỗi")`.
// Renaming one message silently turned "saved" into green for a failure, and every new
// caller had to re-derive the rule. The message is now only for display; the state is typed.
//

import Foundation

public enum PersistenceState: String, Sendable, Equatable {
    case idle
    case saving
    case saved
    case failed
    case notReady
    case empty

    /// Whether a save is currently in flight (drives spinners, not colour).
    public var isBusy: Bool { self == .saving }

    /// Whether the last attempt succeeded. Only this state may be shown as "saved".
    public var isSaved: Bool { self == .saved }

    /// Whether the user must act again before the work is durable.
    public var needsAttention: Bool { self == .failed || self == .notReady }
}
