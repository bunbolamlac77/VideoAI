// MediaIndexer.swift — S10 PTS Index, Exact Rational VFR->CFR 24/1 Mapping, Audio 48kHz & M-24-SDR-v1 Color Policy
// Compliant with docs/02-ANALYSIS-AND-DATA.md, docs/04-SCRIPT-AND-EDIT.md (Sections 8, 9, 10, 11),
// docs/09-UPGRADES-AND-ACCEPTANCE.md (MEDIA-01..MEDIA-04), and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S10).

import Foundation

public enum MediaMappingError: Error, LocalizedError, Sendable, Equatable {
    case invalidRationalTimeBase(num: Int64, den: Int64)
    case duplicateOrNonMonotonicPTS(pts: Int64, frameIndex: Int)
    case unexplainedTimestampGap(gapSeconds: Double, afterFrameIndex: Int)
    case missingFinalFrameDuration
    case criticalEvidenceFrameDropped(droppedFrameIds: [Int])
    case invalidFrameRange(start: Int, end: Int)
    case unsupportedColorMetadata(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRationalTimeBase(let n, let d):
            return "Invalid rational timebase: \(n)/\(d)"
        case .duplicateOrNonMonotonicPTS(let pts, let idx):
            return "Duplicate or non-monotonic PTS \(pts) at frame \(idx)"
        case .unexplainedTimestampGap(let gap, let idx):
            return "Unexplained timestamp gap of \(gap)s after frame \(idx)"
        case .missingFinalFrameDuration:
            return "Final frame is missing verified display duration"
        case .criticalEvidenceFrameDropped(let ids):
            return "Conform 24/1 dropped critical evidence frame(s): \(ids)"
        case .invalidFrameRange(let s, let e):
            return "Invalid half-open frame range [\(s), \(e))"
        case .unsupportedColorMetadata(let r):
            return "Unsupported color metadata: \(r)"
        }
    }
}

/// Exact 64-bit Rational Number (`num / den` with `den > 0`) to prevent floating-point drift in VFR mapping.
public struct RationalTime: Codable, Sendable, Equatable, Comparable {
    public let num: Int64
    public let den: Int64

    public init(_ num: Int64, _ den: Int64 = 1) throws {
        guard den > 0 else {
            throw MediaMappingError.invalidRationalTimeBase(num: num, den: den)
        }
        let g = Self.gcd(abs(num), den)
        self.num = num / g
        self.den = den / g
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a
        var y = b
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return max(1, x)
    }

    public static func + (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        let n = lhs.num * rhs.den + rhs.num * lhs.den
        let d = lhs.den * rhs.den
        return try! RationalTime(n, d)
    }

    public static func - (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        let n = lhs.num * rhs.den - rhs.num * lhs.den
        let d = lhs.den * rhs.den
        return try! RationalTime(n, d)
    }

    public static func * (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        return try! RationalTime(lhs.num * rhs.num, lhs.den * rhs.den)
    }

    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        return lhs.num * rhs.den < rhs.num * lhs.den
    }

    public var doubleValue: Double {
        Double(num) / Double(den)
    }
}

public struct SourceFramePTSRecord: Codable, Sendable, Equatable {
    public let frameId: Int
    public let pts: Int64
    public let durationPts: Int64
    public let timeBaseNum: Int64
    public let timeBaseDen: Int64
    public let hasCriticalEvidence: Bool
    public let evidenceTag: String?

    public init(
        frameId: Int,
        pts: Int64,
        durationPts: Int64,
        timeBaseNum: Int64,
        timeBaseDen: Int64,
        hasCriticalEvidence: Bool = false,
        evidenceTag: String? = nil
    ) {
        self.frameId = frameId
        self.pts = pts
        self.durationPts = durationPts
        self.timeBaseNum = timeBaseNum
        self.timeBaseDen = timeBaseDen
        self.hasCriticalEvidence = hasCriticalEvidence
        self.evidenceTag = evidenceTag
    }

    public var startSec: RationalTime {
        try! RationalTime(pts * timeBaseNum, timeBaseDen)
    }

    public var endSec: RationalTime {
        try! RationalTime((pts + durationPts) * timeBaseNum, timeBaseDen)
    }

    /// Half-open interval `[startSec, endSec)`
    public func contains(_ t: RationalTime) -> Bool {
        return startSec <= t && t < endSec
    }
}

public struct TimelineFrameMapEntry: Codable, Sendable, Equatable {
    public let timelineFrameIndex: Int
    public let sampleMidpointSec: RationalTime
    public let sourceFrameId: Int
    public let sourcePts: Int64
    public let selectionReason: String
}

public struct VFRConformMapArtifact: Codable, Sendable, Equatable {
    public static let profileId = "M-24-SDR-v1"

    public let sourceRevisionId: UUID
    public let sourceStartSec: RationalTime
    public let timelineFrameCount: Int
    public let rotationDegrees: Int
    public let entries: [TimelineFrameMapEntry]
    public let repeatedSourceFrameIds: [Int]
    public let droppedSourceFrameIds: [Int]
    public let droppedCriticalEvidenceFrameIds: [Int]
    public let nativeConformAllowed: Bool

    /// S10.T4: Seek back to exact source frame ID and PTS from a 24fps timeline frame index
    /// (Never mixes display milliseconds with average FPS).
    public func seekToSource(timelineFrame: Int) throws -> (sourceFrameId: Int, sourcePts: Int64) {
        guard timelineFrame >= 0 && timelineFrame < entries.count else {
            throw MediaMappingError.invalidFrameRange(start: 0, end: entries.count)
        }
        let item = entries[timelineFrame]
        return (item.sourceFrameId, item.sourcePts)
    }
}

public enum ColorInterpretationStatus: String, Codable, Sendable, Equatable {
    case sdrRec709Verified = "sdr_passthrough_or_transform"
    case hdrMobiusTonemapVerified = "hdr_tonemap_validated"
    case unsupportedNeedsDecision = "unsupported_needs_decision"
}

public struct ColorProfileEvaluation: Codable, Sendable, Equatable {
    public let profileId: String
    public let status: ColorInterpretationStatus
    public let colorTransformRevision: String?
    public let ffmpegFilterChain: String?
    public let reason: String
}

public enum MediaIndexer {
    /// S10.2: Converts internal half-open interval `[startFrame, endFrameExclusive)`
    /// to DaVinci Resolve inclusive clip bounds `[startFrame, endFrameInclusive]`.
    public static func toResolveInclusiveBounds(startFrame: Int, endFrameExclusive: Int) throws -> (inFrame: Int, outFrameInclusive: Int) {
        guard endFrameExclusive > startFrame else {
            throw MediaMappingError.invalidFrameRange(start: startFrame, end: endFrameExclusive)
        }
        return (startFrame, endFrameExclusive - 1)
    }

    /// S10.1 & S10.4: Builds exact rational VFR -> CFR 24/1 mapping using midpoint sampling `t(k) = source_start + (k + 1/2) / 24`.
    public static func buildVFRToCFR24Map(
        ptsIndex: [SourceFramePTSRecord],
        sourceRevisionId: UUID,
        sourceStartSec: RationalTime,
        timelineFrameCount: Int,
        rotationDegrees: Int = 0,
        enforceCriticalEvidencePreservation: Bool = true
    ) throws -> VFRConformMapArtifact {
        guard timelineFrameCount > 0 else {
            throw MediaMappingError.invalidFrameRange(start: 0, end: timelineFrameCount)
        }
        let durationSec = try RationalTime(Int64(timelineFrameCount), 24)
        let shotEndSec = sourceStartSec + durationSec

        // startSec/endSec use try! — reject malformed time bases (ffprobe can emit 0/0) before touching them.
        if let bad = ptsIndex.first(where: { $0.timeBaseDen <= 0 || $0.durationPts < 0 }) {
            throw MediaMappingError.invalidRationalTimeBase(num: bad.timeBaseNum, den: bad.timeBaseDen)
        }
        let overlapping = ptsIndex.filter { $0.endSec > sourceStartSec && $0.startSec < shotEndSec }
        var entries: [TimelineFrameMapEntry] = []
        var counts: [Int: Int] = [:]

        for k in 0..<timelineFrameCount {
            let offset = try RationalTime(Int64(2 * k + 1), 48)
            let midpoint = sourceStartSec + offset

            guard let chosen = overlapping.first(where: { $0.contains(midpoint) }) else {
                throw MediaMappingError.unexplainedTimestampGap(gapSeconds: midpoint.doubleValue, afterFrameIndex: k)
            }

            let prev = counts[chosen.frameId, default: 0]
            counts[chosen.frameId] = prev + 1
            let reason = prev > 0 ? "repeated_cadence" : (chosen.startSec == midpoint ? "boundary_exact" : "primary")

            entries.append(TimelineFrameMapEntry(
                timelineFrameIndex: k,
                sampleMidpointSec: midpoint,
                sourceFrameId: chosen.frameId,
                sourcePts: chosen.pts,
                selectionReason: reason
            ))
        }

        let repeated = counts.compactMap { $0.value > 1 ? $0.key : nil }.sorted()
        let dropped = overlapping.map(\.frameId).filter { counts[$0] == nil }.sorted()
        let droppedCritical = overlapping.filter { $0.hasCriticalEvidence && counts[$0.frameId] == nil }.map(\.frameId).sorted()

        if enforceCriticalEvidencePreservation && !droppedCritical.isEmpty {
            throw MediaMappingError.criticalEvidenceFrameDropped(droppedFrameIds: droppedCritical)
        }

        return VFRConformMapArtifact(
            sourceRevisionId: sourceRevisionId,
            sourceStartSec: sourceStartSec,
            timelineFrameCount: timelineFrameCount,
            rotationDegrees: ((rotationDegrees % 360) + 360) % 360,
            entries: entries,
            repeatedSourceFrameIds: repeated,
            droppedSourceFrameIds: dropped,
            droppedCriticalEvidenceFrameIds: droppedCritical,
            nativeConformAllowed: false
        )
    }

    /// S10.5 & MEDIA-03: Evaluates source color tags against `M-24-SDR-v1`.
    public static func evaluateColorProfile(
        primaries: String?,
        transfer: String?,
        matrix: String?,
        range: String = "tv",
        hdrTonemapFixtureValidated: Bool = false
    ) -> ColorProfileEvaluation {
        let p = (primaries ?? "").lowercased()
        let t = (transfer ?? "").lowercased()
        let m = (matrix ?? "").lowercased()

        if p.isEmpty || t.isEmpty || m.isEmpty || p == "unknown" || t == "unknown" || m == "unknown" {
            return ColorProfileEvaluation(
                profileId: VFRConformMapArtifact.profileId,
                status: .unsupportedNeedsDecision,
                colorTransformRevision: nil,
                ffmpegFilterChain: nil,
                reason: "Missing or unknown color tags; refusing silent conversion."
            )
        }

        let sdrSet: Set<String> = ["bt709", "smpte170m", "bt470bg", "iec61966-2-1"]
        if sdrSet.contains(p) && sdrSet.contains(t) && sdrSet.contains(m) {
            return ColorProfileEvaluation(
                profileId: VFRConformMapArtifact.profileId,
                status: .sdrRec709Verified,
                colorTransformRevision: "COLOR-SDR-REC709-v1",
                ffmpegFilterChain: "scale=in_color_matrix=\(m):out_color_matrix=bt709,format=yuv420p",
                reason: "Verified SDR Rec.709 pipeline."
            )
        }

        if p == "bt2020" && (t == "smpte2084" || t == "arib-std-b67") && m.hasPrefix("bt2020") {
            guard hdrTonemapFixtureValidated else {
                return ColorProfileEvaluation(
                    profileId: VFRConformMapArtifact.profileId,
                    status: .unsupportedNeedsDecision,
                    colorTransformRevision: nil,
                    ffmpegFilterChain: nil,
                    reason: "HDR source requires validated Mobius tone-map fixture."
                )
            }
            return ColorProfileEvaluation(
                profileId: VFRConformMapArtifact.profileId,
                status: .hdrMobiusTonemapVerified,
                colorTransformRevision: "COLOR-HDR-MOBIUS-REC709-v1",
                ffmpegFilterChain: "zscale=t=linear:npl=100,format=gbrpf32le,tonemap=tonemap=mobius:desat=0,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p",
                reason: "Verified HDR -> SDR Rec.709 Mobius linear light pipeline."
            )
        }

        return ColorProfileEvaluation(
            profileId: VFRConformMapArtifact.profileId,
            status: .unsupportedNeedsDecision,
            colorTransformRevision: nil,
            ffmpegFilterChain: nil,
            reason: "Contradictory color tags (\(p)/\(t)/\(m))."
        )
    }
}
