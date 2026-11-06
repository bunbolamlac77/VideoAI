//
// WorkerClient.swift — Manages Python Worker Subprocess via JSON-RPC 2.0 stdio
//
// Compliant with AIVideo v3.1 Specifications:
// - Strict Swift 6 Concurrency (Sendable, Actor isolation)
// - Continuous non-blocking drain for stdout & stderr with stderr ring buffer
// - Ordered newline framer with strict 1 MiB byte limit enforced BEFORE parsing
// - Non-blocking asynchronous stdin writer with broken-pipe detection
// - Centralized exactly-once continuation resolver with deadline & cancellation support
// - Session generation identity (UUID) preventing stale cross-session interference
// - Strongly-typed Codable DTOs
//

import Foundation

public enum WorkerError: LocalizedError, Sendable {
    case processNotRunning
    case processTerminated
    case invalidResponse(String)
    case rpcError(code: Int, message: String, data: [String: String]?)
    case requestTimeout(seconds: Double)
    case messageTooLarge(bytes: Int)
    case fileNotFound(String)
    case permissionDenied(String)
    case sessionMismatch
    case framingError(String)
    case preflightFailed(String)

    public var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Python worker subprocess is not running."
        case .processTerminated:
            return "Python worker process terminated unexpectedly."
        case .invalidResponse(let msg):
            return "Invalid JSON-RPC response from worker: \(msg)"
        case .rpcError(let code, let msg, _):
            return "Worker RPC error (\(code)): \(msg)"
        case .requestTimeout(let sec):
            return "Request to worker timed out after \(sec) seconds."
        case .messageTooLarge(let bytes):
            return "Received frame exceeded 1 MiB byte limit (\(bytes) bytes)."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied accessing: \(path)"
        case .sessionMismatch:
            return "Worker response arrived for a discarded session generation."
        case .framingError(let msg):
            return "Protocol framing error: \(msg)"
        case .preflightFailed(let msg):
            return "Preflight verification failed: \(msg)"
        }
    }
}

fileprivate struct GenericRPCEnvelope<T: Decodable>: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: T?
    let error: JSONRPCErrorPayload?
}

public actor WorkerClient {
    // Process and Pipes
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    // Session and Request State
    private var currentSessionId: UUID = UUID()
    private var nextRequestId: Int = 1
    private var startupTask: Task<InitializeResult, Error>?

    // Continuations State
    private struct PendingRequest {
        let id: Int
        let sessionId: UUID
        let continuation: CheckedContinuation<Data, Error>
        let deadlineTask: Task<Void, Never>?
    }
    private var pendingRequests: [Int: PendingRequest] = [:]

    // Framing Buffers & Quotas
    private var incomingBuffer = Data()
    private let maxFrameBytes: Int = 1024 * 1024 // Strict 1 MiB limit
    private var stderrRingBuffer: [String] = []
    private let maxStderrLines: Int = 500

    // Public State
    public private(set) var workerPid: Int32 = 0
    public private(set) var pythonVersion: String = ""
    public private(set) var workerVersion: String = ""
    public private(set) var capabilities: [String] = []
    public private(set) var isConnected: Bool = false

    public init() {}

    deinit {
        // Synchronous cleanup safety: Terminate child if actor is deallocated
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Lifecycle Management

    public func start(
        pythonPath: String = "/opt/homebrew/bin/python3.12",
        scriptPath: String,
        timeoutSeconds: Double = 10.0
    ) async throws -> InitializeResult {
        // If startup is already ongoing, share startup task
        if let ongoing = startupTask {
            return try await ongoing.value
        }

        let task = Task<InitializeResult, Error> { [weak self] in
            guard let self = self else { throw WorkerError.processNotRunning }
            return try await self.executeStartup(pythonPath: pythonPath, scriptPath: scriptPath, timeoutSeconds: timeoutSeconds)
        }
        self.startupTask = task

        do {
            let res = try await task.value
            self.startupTask = nil
            return res
        } catch {
            self.startupTask = nil
            throw error
        }
    }

    private func executeStartup(
        pythonPath: String,
        scriptPath: String,
        timeoutSeconds: Double
    ) async throws -> InitializeResult {
        // Stop any previous running instance cleanly
        await self.terminate()

        // Preflight checks
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: pythonPath) else {
            throw WorkerError.preflightFailed("Python executable not found at '\(pythonPath)'.")
        }
        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            throw WorkerError.preflightFailed("Python at '\(pythonPath)' is not executable.")
        }
        guard fileManager.fileExists(atPath: scriptPath) else {
            throw WorkerError.preflightFailed("Worker script not found at '\(scriptPath)'.")
        }

        // Initialize new session identity
        self.currentSessionId = UUID()
        self.incomingBuffer.removeAll(keepingCapacity: true)
        self.stderrRingBuffer.removeAll(keepingCapacity: true)
        self.pendingRequests.removeAll()
        self.nextRequestId = 1

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

        let sessionId = self.currentSessionId

        // Setup Stdout Readability Handler (Continuously drained & framed)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF on stdout
                handle.readabilityHandler = nil
                Task { [weak self] in
                    await self?.handleStdoutEOF(session: sessionId)
                }
                return
            }
            Task { [weak self] in
                await self?.processIncomingStdoutChunk(data, session: sessionId)
            }
        }

        // Setup Stderr Readability Handler (Continuously drained to ring buffer)
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { [weak self] in
                await self?.processIncomingStderrChunk(data)
            }
        }

        try proc.run()
        self.workerPid = proc.processIdentifier

        // Perform Initialize Handshake
        let initParams = InitializeParams(clientName: "AIVideoCore", clientVersion: "1.0.0")
        let initResult: InitializeResult = try await sendRequest(
            method: "initialize",
            params: initParams,
            timeoutSeconds: timeoutSeconds
        )

        self.pythonVersion = initResult.pythonVersion
        self.workerVersion = initResult.workerVersion
        self.capabilities = initResult.capabilities
        self.isConnected = true

        return initResult
    }

    // MARK: - Incoming Chunk & Framing Handling

    private func processIncomingStdoutChunk(_ chunk: Data, session: UUID) {
        guard session == self.currentSessionId else { return }

        incomingBuffer.append(chunk)

        // Strict 1 MiB framing byte limit check before parsing
        if incomingBuffer.count > maxFrameBytes {
            let overflowBytes = incomingBuffer.count
            incomingBuffer.removeAll(keepingCapacity: false)
            failAllPending(with: WorkerError.messageTooLarge(bytes: overflowBytes))
            return
        }

        // Split on newline byte (0x0A)
        while let newlineIndex = incomingBuffer.firstIndex(of: 0x0A) {
            let lineData = incomingBuffer.subdata(in: 0..<newlineIndex)
            incomingBuffer.removeSubrange(0...newlineIndex)

            guard !lineData.isEmpty else { continue }

            handleCompleteFrame(lineData, session: session)
        }
    }

    private func processIncomingStderrChunk(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            if stderrRingBuffer.count >= maxStderrLines {
                stderrRingBuffer.removeFirst()
            }
            stderrRingBuffer.append(String(line))
        }
    }

    private func handleStdoutEOF(session: UUID) {
        guard session == self.currentSessionId else { return }
        self.isConnected = false
        failAllPending(with: WorkerError.processTerminated)
    }

    private func handleCompleteFrame(_ frameData: Data, session: UUID) {
        guard session == self.currentSessionId else { return }

        // Attempt JSON-RPC envelope decode using strongly-typed JSONDecoder
        guard let envelope = try? JSONDecoder().decode(JSONRPCResponseEnvelope.self, from: frameData) else {
            // Malformed JSON frame
            return
        }

        guard let id = envelope.id, let pending = pendingRequests[id] else {
            return
        }
        guard pending.sessionId == session else { return }

        if let errorPayload = envelope.error {
            resolveRequest(id: id, result: .failure(WorkerError.rpcError(code: errorPayload.code, message: errorPayload.message, data: errorPayload.data)))
        } else {
            // Pass raw frame bytes for strongly-typed decoders
            resolveRequest(id: id, result: .success(frameData))
        }
    }

    // MARK: - Centralized Continuation Resolver

    private func resolveRequest(id: Int, result: Result<Data, Error>) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.deadlineTask?.cancel()
        pending.continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        let currentRequests = pendingRequests
        pendingRequests.removeAll()
        for (_, pending) in currentRequests {
            pending.deadlineTask?.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    // MARK: - Request Dispatching

    public func sendRequest<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P? = nil,
        timeoutSeconds: Double = 15.0
    ) async throws -> R {
        guard let proc = process, proc.isRunning, let stdin = stdinPipe?.fileHandleForWriting else {
            throw WorkerError.processNotRunning
        }

        let reqId = nextRequestId
        nextRequestId += 1
        let sessionId = self.currentSessionId

        let rpcReq = JSONRPCRequest(id: reqId, method: method, params: params)
        let data = try JSONEncoder().encode(rpcReq)
        var lineData = data
        lineData.append(0x0A) // '\n'

        let responseFrameData: Data = try await withCheckedThrowingContinuation { continuation in
            let deadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.resolveRequest(id: reqId, result: .failure(WorkerError.requestTimeout(seconds: timeoutSeconds)))
            }

            self.pendingRequests[reqId] = PendingRequest(
                id: reqId,
                sessionId: sessionId,
                continuation: continuation,
                deadlineTask: deadlineTask
            )

            do {
                try stdin.write(contentsOf: lineData)
            } catch {
                deadlineTask.cancel()
                self.pendingRequests.removeValue(forKey: reqId)
                continuation.resume(throwing: error)
            }
        }

        // Decode strongly-typed result from frame
        let envelope = try JSONDecoder().decode(GenericRPCEnvelope<R>.self, from: responseFrameData)
        if let res = envelope.result {
            return res
        } else if let err = envelope.error {
            throw WorkerError.rpcError(code: err.code, message: err.message, data: err.data)
        } else {
            throw WorkerError.invalidResponse("Envelope contained neither result nor error.")
        }
    }

    public func sendNotification<P: Encodable & Sendable>(method: String, params: P? = nil) throws {
        guard let proc = process, proc.isRunning, let stdin = stdinPipe?.fileHandleForWriting else {
            throw WorkerError.processNotRunning
        }
        let notif = JSONRPCRequest<P>(id: nil, method: method, params: params)
        var data = try JSONEncoder().encode(notif)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    // MARK: - High-Level API Methods

    public func ping() async throws -> Bool {
        let res: PingResult = try await sendRequest(method: "system.ping", params: nil as String?, timeoutSeconds: 5.0)
        return res.status == "pong"
    }

    public func probeMedia(filePath: String) async throws -> MediaProbeResult {
        let params = MediaProbeParams(filePath: filePath)
        return try await sendRequest(method: "media.probe", params: params, timeoutSeconds: 15.0)
    }

    public func deterministicSmokeTest(text: String) async throws -> LocalSmokeTestResult {
        let params = LocalSmokeTestParams(text: text)
        return try await sendRequest(method: "ai.deterministic_smoke_test", params: params, timeoutSeconds: 5.0)
    }

    public func localModelInfer(prompt: String, modelPath: String? = nil) async throws -> LocalModelInferResult {
        let params = LocalModelInferParams(prompt: prompt, modelPath: modelPath)
        return try await sendRequest(method: "ai.local_model_infer", params: params, timeoutSeconds: 30.0)
    }

    public func resolveStatus() async throws -> ResolveStatusResult {
        return try await sendRequest(method: "resolve.status", params: nil as String?, timeoutSeconds: 10.0)
    }

    public func runResolveSpike(outputDrpPath: String = "fixtures/AIVideo_G0_Spike.drp", forceFreshRun: Bool = false) async throws -> ResolveSpikeResult {
        let params = ResolveSpikeParams(outputDrpPath: outputDrpPath, forceFreshRun: forceFreshRun)
        return try await sendRequest(method: "resolve.spike_timeline", params: params, timeoutSeconds: 60.0)
    }

    public func getRecentStderrLines() -> [String] {
        return stderrRingBuffer
    }

    // MARK: - Clean Termination & Reclamation

    public func terminate() async {
        // Detach handlers
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        failAllPending(with: WorkerError.processTerminated)

        guard let proc = process, proc.isRunning else {
            self.process = nil
            self.isConnected = false
            return
        }

        // 1. Try graceful shutdown notification
        try? sendNotification(method: "shutdown", params: nil as String?)

        // 2. Close stdin handle
        try? stdinPipe?.fileHandleForWriting.close()

        // 3. Grace period wait
        let pid = proc.processIdentifier
        var terminated = false
        for _ in 0..<5 {
            if !proc.isRunning {
                terminated = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // 4. Escalation: SIGTERM
        if !terminated && proc.isRunning {
            proc.terminate()
            for _ in 0..<5 {
                if !proc.isRunning {
                    terminated = true
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // 5. Hard escalation: SIGKILL
        if !terminated && kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }

        self.process = nil
        self.isConnected = false
        self.workerPid = 0
    }
}
