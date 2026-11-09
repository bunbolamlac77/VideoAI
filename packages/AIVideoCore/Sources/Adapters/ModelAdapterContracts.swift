// ModelAdapterContracts.swift — S11 Pipeline Model Adapters, Capability Registry & Post-Processor Audit
// Compliant with docs/03-MODELS-AND-RESOURCES.md, docs/08-ACCURACY-FIRST.md,
// docs/09-UPGRADES-AND-ACCEPTANCE.md (AI-01, AI-08, JOB-02, JOB-05, OFF-01..03),
// and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S11).

import Foundation

public enum CapabilityBackendStatus: String, Codable, Sendable, Equatable {
    case candidate = "candidate"
    case validated = "validated"
    case disabled = "disabled"
}

public struct CapabilityRegistryEntry: Codable, Sendable, Equatable {
    public let capabilityId: String
    public let status: CapabilityBackendStatus
    public let primaryModel: String?
    public let fallbackWhenUnvalidated: String

    public init(
        capabilityId: String,
        status: CapabilityBackendStatus,
        primaryModel: String?,
        fallbackWhenUnvalidated: String
    ) {
        self.capabilityId = capabilityId
        self.status = status
        self.primaryModel = primaryModel
        self.fallbackWhenUnvalidated = fallbackWhenUnvalidated
    }
}

public struct PostProcessorCoverageAudit: Codable, Sendable, Equatable {
    public let runtimeProfileId: String
    public let intendedSourceFrameIds: [Int]
    public let actualProcessedFrameIds: [Int]
    public let droppedOrTruncatedFrameIds: [Int]
    public let temporalPatchGroups: [[Int]]
    public let postProcessorWidth: Int
    public let postProcessorHeight: Int
    public let coverageRatio: Double
    public let truncationDetected: Bool
    public let isFullWindowCovered: Bool
}

public struct PhaseMemoryTrace: Codable, Sendable, Equatable {
    public let phaseName: String
    public let pid: Int32
    public let rssBytes: Int64
    public let budgetLimitBytes: Int64
    public let withinBudget: Bool
}

public enum S11AdapterError: Error, LocalizedError, Sendable, Equatable {
    case offlineArtifactMissing(role: String, missingFiles: [String])
    case forbiddenModelOn16GB(modelId: String)
    case processorFrameTruncationDetected(droppedFrames: [Int])
    case invalidStructuredOutput(reason: String)
    case invalidVietnameseTTSOutput(reason: String)

    public var errorDescription: String? {
        switch self {
        case .offlineArtifactMissing(let role, let files):
            return "Offline adapter '\(role)' missing local artifacts: \(files). Cloud fallback is forbidden."
        case .forbiddenModelOn16GB(let modelId):
            return "Model '\(modelId)' is forbidden on 16 GB Unified Memory hardware."
        case .processorFrameTruncationDetected(let dropped):
            return "Post-processor audit detected dropped/truncated frames: \(dropped)."
        case .invalidStructuredOutput(let reason):
            return "Invalid structured model output: \(reason)"
        case .invalidVietnameseTTSOutput(let reason):
            return "Invalid Vietnamese TTS output: \(reason)"
        }
    }
}

public enum S11PipelineValidator {
    /// S11.4: Blocks 32B/72B/FLUX/SUPIR models on 16 GB Apple Silicon.
    public static func enforce16GBHardwarePolicy(modelId: String) throws {
        let lower = modelId.lowercased()
        for token in ["32b", "72b", "flux", "supir"] {
            if lower.contains(token) {
                throw S11AdapterError.forbiddenModelOn16GB(modelId: modelId)
            }
        }
    }

    /// S11.T2: Audits intended frame IDs against actual post-processor frames and maps temporal patch groups.
    public static func auditPostProcessorFrames(
        runtimeProfileId: String = "P-VISION-DEV-v1",
        intendedFrameIds: [Int],
        processorAcceptedFrameIds: [Int],
        temporalPatchSize: Int = 2,
        postWidth: Int = 952,
        postHeight: Int = 532
    ) -> PostProcessorCoverageAudit {
        let acceptedSet = Set(processorAcceptedFrameIds)
        let kept = intendedFrameIds.filter { acceptedSet.contains($0) }
        let dropped = intendedFrameIds.filter { !acceptedSet.contains($0) }

        var groups: [[Int]] = []
        let step = max(1, temporalPatchSize)
        var i = 0
        while i < kept.count {
            let end = min(i + step, kept.count)
            groups.append(Array(kept[i..<end]))
            i += step
        }

        let ratio = intendedFrameIds.isEmpty ? 0.0 : Double(kept.count) / Double(intendedFrameIds.count)
        let truncated = !dropped.isEmpty

        return PostProcessorCoverageAudit(
            runtimeProfileId: runtimeProfileId,
            intendedSourceFrameIds: intendedFrameIds,
            actualProcessedFrameIds: kept,
            droppedOrTruncatedFrameIds: dropped,
            temporalPatchGroups: groups,
            postProcessorWidth: postWidth,
            postProcessorHeight: postHeight,
            coverageRatio: ratio,
            truncationDetected: truncated,
            isFullWindowCovered: !truncated
        )
    }

    /// S11.T3: Measures current resident memory of the process and validates AI <-> Resolve phase release.
    public static func captureMemoryTrace(phaseName: String, budgetLimitBytes: Int64 = 12 * 1024 * 1024 * 1024) -> PhaseMemoryTrace {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let rss = (kerr == KERN_SUCCESS) ? Int64(info.resident_size) : 0
        return PhaseMemoryTrace(
            phaseName: phaseName,
            pid: ProcessInfo.processInfo.processIdentifier,
            rssBytes: rss,
            budgetLimitBytes: budgetLimitBytes,
            withinBudget: rss <= budgetLimitBytes
        )
    }

    /// S11.T4: Validates LLM/VLM JSON output and Vietnamese text integrity before allowing any claim proposal.
    public static func validateObservationJSON(_ rawJSON: String) throws -> [String: Any] {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw S11AdapterError.invalidStructuredOutput(reason: "Malformed or truncated JSON")
        }
        guard let text = obj["observation_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw S11AdapterError.invalidStructuredOutput(reason: "Missing or empty observation_text")
        }
        if text.contains("\u{FFFD}") || text.contains("\0") {
            throw S11AdapterError.invalidStructuredOutput(reason: "Corrupted Vietnamese encoding (U+FFFD)")
        }
        guard let origin = obj["origin"] as? String, ["visual_model", "asr", "ocr"].contains(origin) else {
            throw S11AdapterError.invalidStructuredOutput(reason: "Model output cannot impersonate user origin")
        }
        guard let frames = obj["frame_ids"] as? [Int], !frames.isEmpty else {
            throw S11AdapterError.invalidStructuredOutput(reason: "Missing or empty frame_ids")
        }
        return obj
    }
}
