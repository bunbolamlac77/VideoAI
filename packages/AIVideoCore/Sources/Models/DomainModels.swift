//
// DomainModels.swift — Strongly-Typed Core Data Contracts for AIVideo v3.1
//
// All models conform to Codable and Sendable for strict Swift 6 concurrency.
//

import Foundation

// MARK: - JSON-RPC 2.0 Envelopes

public struct JSONRPCRequest<P: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc: String = "2.0"
    public let id: Int?
    public let method: String
    public let params: P?

    public init(id: Int?, method: String, params: P? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCErrorPayload: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: [String: String]?

    public init(code: Int, message: String, data: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var kind: String? {
        return data?["kind"] ?? data?["type"]
    }
}

public struct JSONRPCResponseEnvelope: Decodable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let hasResult: Bool
    public let hasMethod: Bool
    public let error: JSONRPCErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
        case method
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        self.id = try container.decodeIfPresent(Int.self, forKey: .id)
        self.hasResult = container.contains(.result)
        self.hasMethod = container.contains(.method)
        self.error = try container.decodeIfPresent(JSONRPCErrorPayload.self, forKey: .error)
    }
}

// MARK: - Handshake & System DTOs

public struct InitializeParams: Codable, Sendable {
    public let clientName: String
    public let clientVersion: String

    public enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case clientVersion = "client_version"
    }

    public init(clientName: String = "AIVideoCore", clientVersion: String = "1.0.0") {
        self.clientName = clientName
        self.clientVersion = clientVersion
    }
}

public struct InitializeResult: Codable, Sendable {
    public let status: String
    public let workerName: String
    public let workerVersion: String
    public let protocolVersion: String
    public let workerPid: Int32
    public let pythonVersion: String
    public let capabilities: [String]

    public enum CodingKeys: String, CodingKey {
        case status
        case workerName = "worker_name"
        case workerVersion = "worker_version"
        case protocolVersion = "protocol_version"
        case workerPid = "worker_pid"
        case pythonVersion = "python_version"
        case capabilities
    }
}

public struct PingResult: Codable, Sendable {
    public let status: String
    public let serverTime: Double

    public enum CodingKeys: String, CodingKey {
        case status
        case serverTime = "server_time"
    }
}

// MARK: - Media Probe DTOs

public struct MediaProbeParams: Codable, Sendable {
    public let filePath: String

    public enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }

    public init(filePath: String) {
        self.filePath = filePath
    }
}

public struct VideoStreamInfo: Codable, Sendable {
    public let index: Int?
    public let codecName: String?
    public let width: Int?
    public let height: Int?
    public let frameRate: String?
    public let duration: String?
    public let pixelFormat: String?

    public enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case width
        case height
        case frameRate = "r_frame_rate"
        case duration
        case pixelFormat = "pix_fmt"
    }

    public init(index: Int?, codecName: String?, width: Int?, height: Int?, frameRate: String?, duration: String?, pixelFormat: String?) {
        self.index = index
        self.codecName = codecName
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.duration = duration
        self.pixelFormat = pixelFormat
    }
}

public struct AudioStreamInfo: Codable, Sendable {
    public let index: Int?
    public let codecName: String?
    public let sampleRate: String?
    public let channels: Int?
    public let duration: String?

    public enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case sampleRate = "sample_rate"
        case channels
        case duration
    }

    public init(index: Int?, codecName: String?, sampleRate: String?, channels: Int?, duration: String?) {
        self.index = index
        self.codecName = codecName
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration = duration
    }
}

public struct MediaProbeResult: Codable, Sendable {
    public let filePath: String
    public let formatName: String?
    public let durationSeconds: Double
    public let sizeBytes: Int64
    public let bitRate: Int64?
    public let videoStreams: [VideoStreamInfo]
    public let audioStreams: [AudioStreamInfo]

    public enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case formatName = "format_name"
        case durationSeconds = "duration_seconds"
        case sizeBytes = "size_bytes"
        case bitRate = "bit_rate"
        case videoStreams = "video_streams"
        case audioStreams = "audio_streams"
    }

    public init(filePath: String, formatName: String?, durationSeconds: Double, sizeBytes: Int64, bitRate: Int64?, videoStreams: [VideoStreamInfo], audioStreams: [AudioStreamInfo]) {
        self.filePath = filePath
        self.formatName = formatName
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
        self.bitRate = bitRate
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
    }
}

// MARK: - Local AI Model Status & Real Inference DTOs (G0 Spec)

public enum ModelStatusCode: String, Codable, Sendable {
    case notConfigured = "not_configured"
    case notInstalled = "not_installed"
    case invalidAssets = "invalid_assets"
    case runtimeUnavailable = "runtime_unavailable"
    case availableUnloaded = "available_unloaded"
}

public struct ModelStatusParams: Codable, Sendable {
    public let profileId: String?

    public enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
    }

    public init(profileId: String? = nil) {
        self.profileId = profileId
    }
}

public struct ModelStatusResult: Codable, Sendable {
    public let status: ModelStatusCode
    public let profileId: String
    public let modelId: String?
    public let modelRevision: String?
    public let modelPath: String?
    public let pythonPath: String?
    public let backendName: String?
    public let details: String?
    public let missingFiles: [String]?

    public enum CodingKeys: String, CodingKey {
        case status
        case profileId = "profile_id"
        case modelId = "model_id"
        case modelRevision = "model_revision"
        case modelPath = "model_path"
        case pythonPath = "python_path"
        case backendName = "backend_name"
        case details
        case missingFiles = "missing_files"
    }

    public init(
        status: ModelStatusCode,
        profileId: String,
        modelId: String? = nil,
        modelRevision: String? = nil,
        modelPath: String? = nil,
        pythonPath: String? = nil,
        backendName: String? = nil,
        details: String? = nil,
        missingFiles: [String]? = nil
    ) {
        self.status = status
        self.profileId = profileId
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.modelPath = modelPath
        self.pythonPath = pythonPath
        self.backendName = backendName
        self.details = details
        self.missingFiles = missingFiles
    }
}

public struct LocalInferParams: Codable, Sendable {
    public let prompt: String
    public let profileId: String?

    public enum CodingKeys: String, CodingKey {
        case prompt
        case profileId = "profile_id"
    }

    public init(prompt: String, profileId: String? = nil) {
        self.prompt = prompt
        self.profileId = profileId
    }
}

public struct LocalInferResult: Codable, Sendable {
    public let schemaVersion: String
    public let runId: String
    public let profileId: String
    public let modelId: String
    public let modelRevision: String
    public let modelLockSha256: String
    public let backendName: String
    public let backendVersion: String
    public let inputSha256: String
    public let outputText: String
    public let inputTokenCount: Int
    public let outputTokenCount: Int
    public let finishReason: String
    public let loadTimeMs: Double?
    public let generationTimeMs: Double?

    public enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runId = "run_id"
        case profileId = "profile_id"
        case modelId = "model_id"
        case modelRevision = "model_revision"
        case modelLockSha256 = "model_lock_sha256"
        case backendName = "backend_name"
        case backendVersion = "backend_version"
        case inputSha256 = "input_sha256"
        case outputText = "output_text"
        case inputTokenCount = "input_token_count"
        case outputTokenCount = "output_token_count"
        case finishReason = "finish_reason"
        case loadTimeMs = "load_time_ms"
        case generationTimeMs = "generation_time_ms"
    }

    public init(
        schemaVersion: String,
        runId: String,
        profileId: String,
        modelId: String,
        modelRevision: String,
        modelLockSha256: String,
        backendName: String,
        backendVersion: String,
        inputSha256: String,
        outputText: String,
        inputTokenCount: Int,
        outputTokenCount: Int,
        finishReason: String,
        loadTimeMs: Double? = nil,
        generationTimeMs: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runId = runId
        self.profileId = profileId
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.modelLockSha256 = modelLockSha256
        self.backendName = backendName
        self.backendVersion = backendVersion
        self.inputSha256 = inputSha256
        self.outputText = outputText
        self.inputTokenCount = inputTokenCount
        self.outputTokenCount = outputTokenCount
        self.finishReason = finishReason
        self.loadTimeMs = loadTimeMs
        self.generationTimeMs = generationTimeMs
    }
}

// MARK: - DaVinci Resolve DTOs

public struct ResolveStatusResult: Codable, Sendable {
    public let running: Bool
    public let connected: Bool
    public let productName: String?
    public let version: String?
    public let error: String?

    public enum CodingKeys: String, CodingKey {
        case running
        case connected
        case productName = "product_name"
        case version
        case error
    }
}

public struct ResolveSpikeParams: Codable, Sendable {
    public let outputDrpPath: String
    public let forceFreshRun: Bool

    public enum CodingKeys: String, CodingKey {
        case outputDrpPath = "output_drp_path"
        case forceFreshRun = "force_fresh_run"
    }

    public init(outputDrpPath: String = "fixtures/AIVideo_G0_Spike.drp", forceFreshRun: Bool = false) {
        self.outputDrpPath = outputDrpPath
        self.forceFreshRun = forceFreshRun
    }
}

public struct ResolveSpikeResult: Codable, Sendable {
    public let success: Bool?
    public let status: String?
    public let resolveProduct: String?
    public let resolveVersion: String?
    public let projectName: String
    public let timelineName: String
    public let timelineResolution: String
    public let timelineFps: Double
    public let timelineStartFrame: Int
    public let timelineEndFrame: Int
    public let timelineTotalFrames: Int
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let videoItemsCount: Int
    public let audioItemsCount: Int
    public let videoItemDuration: Int?
    public let audioItemDuration: Int?
    public let titleInserted: Bool
    public let renderSettingsConfigured: Bool?
    public let projectSaved: Bool?
    public let previewPath: String?
    public let drpExported: Bool
    public let drpPath: String
    public let drpSizeBytes: Int?
    public let supportedMp4Codecs: [String]
    public let verifiedSteps: [String]?
    public let offlineVerified: Bool?
    public let reconciliationStatus: String?

    public enum CodingKeys: String, CodingKey {
        case success
        case status
        case resolveProduct = "resolve_product"
        case resolveVersion = "resolve_version"
        case projectName = "project_name"
        case timelineName = "timeline_name"
        case timelineResolution = "timeline_resolution"
        case timelineFps = "timeline_fps"
        case timelineStartFrame = "timeline_start_frame"
        case timelineEndFrame = "timeline_end_frame"
        case timelineTotalFrames = "timeline_total_frames"
        case videoTrackCount = "video_track_count"
        case audioTrackCount = "audio_track_count"
        case videoItemsCount = "video_items_count"
        case audioItemsCount = "audio_items_count"
        case videoItemDuration = "video_item_duration"
        case audioItemDuration = "audio_item_duration"
        case titleInserted = "title_inserted"
        case renderSettingsConfigured = "render_settings_configured"
        case projectSaved = "project_saved"
        case previewPath = "preview_path"
        case drpExported = "drp_exported"
        case drpPath = "drp_path"
        case drpSizeBytes = "drp_size_bytes"
        case supportedMp4Codecs = "supported_mp4_codecs"
        case verifiedSteps = "verified_steps"
        case offlineVerified = "offline_verified"
        case reconciliationStatus = "reconciliation_status"
    }
}

// MARK: - Gate G2 Source Analysis RPC DTOs

public struct G2AnalyzeSourceParams: Codable, Sendable {
    public let filePath: String
    public let sourceRevisionId: String
    public let workdayId: String
    public let briefText: String

    public enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case sourceRevisionId = "source_revision_id"
        case workdayId = "workday_id"
        case briefText = "brief_text"
    }

    public init(filePath: String, sourceRevisionId: String, workdayId: String, briefText: String) {
        self.filePath = filePath
        self.sourceRevisionId = sourceRevisionId
        self.workdayId = workdayId
        self.briefText = briefText
    }
}

public struct G2FrameIdRangesDTO: Codable, Sendable {
    public let uniquePostProcessor: [[Int]]
    public let validDecoded: [[Int]]

    public enum CodingKeys: String, CodingKey {
        case uniquePostProcessor = "unique_post_processor"
        case validDecoded = "valid_decoded"
    }
}

public struct G2AnalyzeCoverageDTO: Codable, Sendable {
    public let sourceRevisionId: String
    public let runtimeProfileId: String
    public let inputFingerprint: String
    public let totalDeclaredSourceFrames: Int
    public let validDecodedFrameIds: [Int]
    public let corruptedDecodeFrameIds: [Int]
    public let uniquePostProcessorFrameIds: [Int]
    public let totalSubmittedFramesWithOverlap: Int
    public let frameInputCoverage: Double
    public let detailedPassStatus: String
    public let semanticUnderstandingCertified: Bool
    public let vlmFrameCoverage: Double?
    public let frameIdsTruncated: Bool?
    public let frameIdRanges: G2FrameIdRangesDTO?

    public enum CodingKeys: String, CodingKey {
        case sourceRevisionId = "source_revision_id"
        case runtimeProfileId = "runtime_profile_id"
        case inputFingerprint = "input_fingerprint"
        case totalDeclaredSourceFrames = "total_declared_source_frames"
        case validDecodedFrameIds = "valid_decoded_frame_ids"
        case corruptedDecodeFrameIds = "corrupted_decode_frame_ids"
        case uniquePostProcessorFrameIds = "unique_post_processor_frame_ids"
        case totalSubmittedFramesWithOverlap = "total_submitted_frames_with_overlap"
        case frameInputCoverage = "frame_input_coverage"
        case detailedPassStatus = "detailed_pass_status"
        case semanticUnderstandingCertified = "semantic_understanding_certified"
        case vlmFrameCoverage = "vlm_frame_coverage"
        case frameIdsTruncated = "frame_ids_truncated"
        case frameIdRanges = "frame_id_ranges"
    }

    private static func expand(_ ranges: [[Int]]?) -> [Int] {
        guard let ranges else { return [] }
        var ids: [Int] = []
        for pair in ranges where pair.count == 2 && pair[0] <= pair[1] {
            ids.append(contentsOf: pair[0]...pair[1])
        }
        return ids
    }

    /// Long sources return compact ranges instead of a multi-megabyte id list.
    public var resolvedUniquePostProcessorFrameIds: [Int] {
        uniquePostProcessorFrameIds.isEmpty
            ? Self.expand(frameIdRanges?.uniquePostProcessor)
            : uniquePostProcessorFrameIds
    }

    public var resolvedValidDecodedFrameIds: [Int] {
        validDecodedFrameIds.isEmpty
            ? Self.expand(frameIdRanges?.validDecoded)
            : validDecodedFrameIds
    }
}

public struct G2AnalyzeRawObservationDTO: Codable, Sendable {
    public let observationId: String
    public let sourceRevisionId: String
    public let windowIndex: Int
    public let passRole: String
    public let origin: String
    public let epistemicStatus: String
    public let frameIds: [Int]
    public let startPtsTicks: Int64
    public let endPtsTicks: Int64
    public let observationText: String
    public let ocrRawTokens: [String]
    public let ocrIsUncertain: Bool

    public enum CodingKeys: String, CodingKey {
        case observationId = "observation_id"
        case sourceRevisionId = "source_revision_id"
        case windowIndex = "window_index"
        case passRole = "pass_role"
        case origin
        case epistemicStatus = "epistemic_status"
        case frameIds = "frame_ids"
        case startPtsTicks = "start_pts_ticks"
        case endPtsTicks = "end_pts_ticks"
        case observationText = "observation_text"
        case ocrRawTokens = "ocr_raw_tokens"
        case ocrIsUncertain = "ocr_is_uncertain"
    }
}

public struct G2AnalyzeClaimDTO: Codable, Sendable {
    public let claimId: String
    public let text: String
    public let origin: String
    public let epistemicStatus: String
    public let reviewStatus: String
    public let supportStatus: String
    public let allowedUse: String
    public let requiresTargetedReview: Bool

    public enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case text
        case origin
        case epistemicStatus = "epistemic_status"
        case reviewStatus = "review_status"
        case supportStatus = "support_status"
        case allowedUse = "allowed_use"
        case requiresTargetedReview = "requires_targeted_review"
    }
}

public struct G2AnalyzeReviewItemDTO: Codable, Sendable {
    public let evidenceScopeRevisionId: String
    public let evidenceKind: String
    public let isCritical: Bool
    public let questionText: String

    public enum CodingKeys: String, CodingKey {
        case evidenceScopeRevisionId = "evidence_scope_revision_id"
        case evidenceKind = "evidence_kind"
        case isCritical = "is_critical"
        case questionText = "question_text"
    }
}

public struct G2AnalyzeSourceResult: Codable, Sendable {
    public let sourceRevisionId: String
    public let sourceSha256: String
    public let visionModelInstalled: Bool
    public let coverageLedger: G2AnalyzeCoverageDTO
    public let rawObservationsCount: Int
    public let rawObservations: [G2AnalyzeRawObservationDTO]
    public let audioBranchState: String
    public let omissionFindingsCount: Int
    public let claims: [G2AnalyzeClaimDTO]
    public let reviewItems: [G2AnalyzeReviewItemDTO]

    public enum CodingKeys: String, CodingKey {
        case sourceRevisionId = "source_revision_id"
        case sourceSha256 = "source_sha256"
        case visionModelInstalled = "vision_model_installed"
        case coverageLedger = "coverage_ledger"
        case rawObservationsCount = "raw_observations_count"
        case rawObservations = "raw_observations"
        case audioBranchState = "audio_branch_state"
        case omissionFindingsCount = "omission_findings_count"
        case claims
        case reviewItems = "review_items"
    }
}
