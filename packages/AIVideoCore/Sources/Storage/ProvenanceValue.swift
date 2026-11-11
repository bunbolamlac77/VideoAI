//
// ProvenanceValue.swift — canonical comparison of values that cross the Python/Swift border.
//
// (P2-03, P2-04) Two defect classes used to live in every gate guard:
//   * UUIDs were compared with `==` against `uuidString`. Python normalises ids to
//     uppercase in some paths and lowercase in others, so a perfectly valid receipt was
//     rejected as "a different approval".
//   * `avg_frame_rate` was parsed with `s.split(separator: "/")[0]`, which traps (crash)
//     when ffprobe reports an empty string.
// Both now have exactly one implementation, and every guard uses it.
//

import Foundation

public enum ProvenanceValue {
    /// Case-insensitive UUID equality for ids that travel through JSON.
    /// Returns false for non-UUID strings on either side (never a silent "equal").
    public static func uuidsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs,
              let left = UUID(uuidString: lhs.trimmingCharacters(in: .whitespacesAndNewlines)),
              let right = UUID(uuidString: rhs.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return left == right
    }

    /// Parse an ffprobe rational frame rate ("24/1", "24000/1001", "24") without trapping.
    /// An empty, malformed, zero or non-finite value yields 0 so the caller fails closed.
    public static func frameRate(_ raw: Any?) -> Double {
        guard let text = raw as? String else { return 0 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty,
              let numerator = Double(first), numerator.isFinite, numerator > 0 else { return 0 }
        if parts.count == 1 { return numerator }
        guard parts.count == 2, !parts[1].isEmpty,
              let denominator = Double(parts[1]),
              denominator.isFinite, denominator > 0 else { return 0 }
        let value = numerator / denominator
        return value.isFinite ? value : 0
    }

    /// True when both ffprobe frame-rate fields are exactly 24 fps (24/1).
    ///
    /// The gate contract is "2160×3840 @ 24.0 fps", so 23.976 material must not pass: it
    /// would render a timeline that drifts against the approved frame count.
    public static func is24fps(_ stream: [String: Any], tolerance: Double = 1e-6) -> Bool {
        let average = frameRate(stream["avg_frame_rate"])
        let real = frameRate(stream["r_frame_rate"])
        return abs(average - 24) < tolerance && abs(real - 24) < tolerance
    }
}
