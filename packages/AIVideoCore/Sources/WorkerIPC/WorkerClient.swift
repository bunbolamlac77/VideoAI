//
// WorkerClient.swift — Manages Python Worker Subprocess via JSON-RPC 2.0 stdio
//

import Foundation

public enum WorkerError: LocalizedError, Sendable {
    case processNotRunning
    case invalidResponse(String)
    case rpcError(code: Int, message: String)
    case requestTimeout
    case fileNotFound(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Python worker subprocess is not running."
        case .invalidResponse(let msg):
            return "Invalid JSON-RPC response from worker: \(msg)"
        case .rpcError(let code, let msg):
            return "Worker RPC error (\(code)): \(msg)"
        case .requestTimeout:
            return "Request to worker timed out."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied accessing: \(path)"
        }
    }
}

public actor WorkerClient {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextRequestId: Int = 1
    private var pendingContinuations: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var incomingBuffer = Data()

    public private(set) var workerPid: Int32 = 0
    public private(set) var pythonVersion: String = ""
    public private(set) var isConnected: Bool = false

    public init() {}

    deinit {
        // Ensure child process is never orphaned
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }

    public func start(pythonPath: String = "/opt/homebrew/bin/python3.12", scriptPath: String) async throws {
        guard process == nil || !(process!.isRunning) else {
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-u", scriptPath]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        // Set up event-driven readability handler
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { [weak self] in
                await self?.processIncomingChunk(data)
            }
        }

        try proc.run()
        self.workerPid = proc.processIdentifier

        // Perform initialization handshake
        let initParams: [String: Any] = [
            "client_name": "AIVideoCore",
            "client_version": "1.0.0"
        ]
        let result = try await sendRequest(method: "initialize", params: initParams)
        if let pyVer = result["python_version"] as? String {
            self.pythonVersion = pyVer
        }
        self.isConnected = true
    }

    private func processIncomingChunk(_ chunk: Data) {
        incomingBuffer.append(chunk)

        while let newlineIndex = incomingBuffer.firstIndex(of: 0x0A) { // '\n'
            let lineData = incomingBuffer.subdata(in: 0..<newlineIndex)
            incomingBuffer.removeSubrange(0...newlineIndex)

            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                handleIncomingLine(line)
            }
        }
    }

    private func handleIncomingLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        if let reqId = json["id"] as? Int, let continuation = pendingContinuations.removeValue(forKey: reqId) {
            if let errorDict = json["error"] as? [String: Any] {
                let code = errorDict["code"] as? Int ?? -1
                let message = errorDict["message"] as? String ?? "Unknown RPC error"
                continuation.resume(throwing: WorkerError.rpcError(code: code, message: message))
            } else if let resultDict = json["result"] as? [String: Any] {
                continuation.resume(returning: resultDict)
            } else {
                continuation.resume(throwing: WorkerError.invalidResponse("Missing result and error"))
            }
        }
    }

    public func sendRequest(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let proc = process, proc.isRunning, let stdin = stdinPipe?.fileHandleForWriting else {
            throw WorkerError.processNotRunning
        }

        let reqId = nextRequestId
        nextRequestId += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        var lineData = data
        lineData.append(0x0A) // '\n'

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuations[reqId] = continuation
            do {
                try stdin.write(contentsOf: lineData)
            } catch {
                self.pendingContinuations.removeValue(forKey: reqId)
                continuation.resume(throwing: error)
            }
        }
    }

    public func ping() async throws -> Bool {
        let res = try await sendRequest(method: "system.ping")
        return (res["status"] as? String) == "pong"
    }

    public func probeMedia(filePath: String) async throws -> MediaProbeResult {
        let res = try await sendRequest(method: "media.probe", params: ["file_path": filePath])

        var videoStreams: [VideoStreamInfo] = []
        if let vList = res["video_streams"] as? [[String: Any]] {
            for v in vList {
                videoStreams.append(VideoStreamInfo(
                    index: v["index"] as? Int,
                    codecName: v["codec_name"] as? String,
                    width: v["width"] as? Int,
                    height: v["height"] as? Int,
                    frameRate: v["r_frame_rate"] as? String,
                    duration: v["duration"] as? String,
                    pixelFormat: v["pix_fmt"] as? String
                ))
            }
        }

        var audioStreams: [AudioStreamInfo] = []
        if let aList = res["audio_streams"] as? [[String: Any]] {
            for a in aList {
                audioStreams.append(AudioStreamInfo(
                    index: a["index"] as? Int,
                    codecName: a["codec_name"] as? String,
                    sampleRate: a["sample_rate"] as? String,
                    channels: a["channels"] as? Int,
                    duration: a["duration"] as? String
                ))
            }
        }

        return MediaProbeResult(
            filePath: res["file_path"] as? String ?? filePath,
            formatName: res["format_name"] as? String,
            durationSeconds: res["duration_seconds"] as? Double ?? 0.0,
            sizeBytes: (res["size_bytes"] as? NSNumber)?.int64Value ?? 0,
            bitRate: (res["bit_rate"] as? NSNumber)?.int64Value,
            videoStreams: videoStreams,
            audioStreams: audioStreams
        )
    }

    public func localInferTest(text: String) async throws -> LocalInferResult {
        let res = try await sendRequest(method: "ai.local_infer_test", params: ["text": text])
        let synthetic = res["synthetic_analysis"] as? [String: Any] ?? [:]

        return LocalInferResult(
            status: res["status"] as? String ?? "unknown",
            mode: res["mode"] as? String ?? "LOCAL",
            inputLength: res["input_length"] as? Int ?? 0,
            tokenCount: res["token_count"] as? Int ?? 0,
            contentSha256: res["content_sha256"] as? String ?? "",
            language: synthetic["language"] as? String ?? "vi",
            summaryClaimsCount: synthetic["summary_claims_count"] as? Int ?? 1,
            offlineVerified: synthetic["offline_verified"] as? Bool ?? true
        )
    }

    public func resolveStatus() async throws -> [String: Any] {
        return try await sendRequest(method: "resolve.status")
    }

    public func runResolveSpike(drpPath: String = "fixtures/AIVideo_G0_Spike.drp") async throws -> [String: Any] {
        return try await sendRequest(method: "resolve.spike_timeline", params: ["drp_path": drpPath])
    }

    public func terminate() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil

        // Clear continuations
        for (_, cont) in pendingContinuations {
            cont.resume(throwing: WorkerError.processNotRunning)
        }
        pendingContinuations.removeAll()

        if let proc = process, proc.isRunning {
            try? stdinPipe?.fileHandleForWriting.close()
            proc.terminate()
        }
        process = nil
        isConnected = false
    }
}
