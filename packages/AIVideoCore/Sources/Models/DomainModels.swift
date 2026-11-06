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
}

public struct JSONRPCResponseEnvelope: Decodable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let error: JSONRPCErrorPayload?
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

// MARK: - Local AI Inference / Smoke Test DTOs

public struct LocalSmokeTestParams: Codable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct LocalSmokeTestResult: Codable, Sendable {
    public let status: String
    public let executionType: String
    public let inputLength: Int
    public let tokenCount: Int
    public let contentSha256: String
    public let detectedLanguage: String
    public let offlineVerified: Bool

    public enum CodingKeys: String, CodingKey {
        case status
        case executionType = "execution_type"
        case inputLength = "input_length"
        case tokenCount = "token_count"
        case contentSha256 = "content_sha256"
        case detectedLanguage = "detected_language"
        case offlineVerified = "offline_verified"
    }
}

public struct LocalModelInferParams: Codable, Sendable {
    public let prompt: String
    public let modelPath: String?

    public enum CodingKeys: String, CodingKey {
        case prompt
        case modelPath = "model_path"
    }

    public init(prompt: String, modelPath: String? = nil) {
        self.prompt = prompt
        self.modelPath = modelPath
    }
}

public struct LocalModelInferResult: Codable, Sendable {
    public let status: String
    public let modelId: String
    public let runtime: String
    public let weightsSha256: String
    public let tokensGenerated: Int
    public let outputText: String
    public let inferenceLatencyMs: Double
    public let offlineVerified: Bool

    public enum CodingKeys: String, CodingKey {
        case status
        case modelId = "model_id"
        case runtime
        case weightsSha256 = "weights_sha256"
        case tokensGenerated = "tokens_generated"
        case outputText = "output_text"
        case inferenceLatencyMs = "inference_latency_ms"
        case offlineVerified = "offline_verified"
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
    public let status: String
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
    public let titleInserted: Bool
    public let previewRendered: Bool
    public let previewPath: String?
    public let finalRendered: Bool
    public let finalPath: String?
    public let drpExported: Bool
    public let drpPath: String
    public let supportedMp4Codecs: [String]
    public let offlineVerified: Bool
    public let reconciliationStatus: String

    public enum CodingKeys: String, CodingKey {
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
        case titleInserted = "title_inserted"
        case previewRendered = "preview_rendered"
        case previewPath = "preview_path"
        case finalRendered = "final_rendered"
        case finalPath = "final_path"
        case drpExported = "drp_exported"
        case drpPath = "drp_path"
        case supportedMp4Codecs = "supported_mp4_codecs"
        case offlineVerified = "offline_verified"
        case reconciliationStatus = "reconciliation_status"
    }
}
