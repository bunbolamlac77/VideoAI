//
// WorkerClient.swift — Manages Python Worker Subprocess via JSON-RPC 2.0 stdio
//
// Compliant with AIVideo v3.1 Specifications:
// - Strict Swift 6 Concurrency (Sendable, Actor isolation)
// - Dedicated bounded SequentialPipeWriter preventing synchronous write deadlock on actor
// - Ordered stdout stream processing with strictly FIFO chunk framing
// - 1 MiB framing limit enforced on both incoming and outgoing messages
// - Safe discard of oversized lines up to newline without executing partial tail
// - Continuous non-blocking drain for stdout & stderr with stderr ring buffer
// - Exactly-once continuation resolver with Task cancellation support and safe deadline timer
// - Full session UUID and request ID validation on all callbacks
// - Clean process termination with exit verification before handle disposal
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    case requestCancelled

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
            return "Message exceeded 1 MiB limit (\(bytes) bytes)."
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
        case .requestCancelled:
            return "Request was cancelled by client."
        }
    }
}

fileprivate struct GenericRPCEnvelope<T: Decodable>: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: T?
    let error: JSONRPCErrorPayload?
}

// MARK: - Sequential Pipe Writer (Actor with bounded queue)

fileprivate actor SequentialPipeWriter {
    private let fileHandle: FileHandle
    private var isClosed: Bool = false
    private let maxQueuedBytes: Int = 4 * 1024 * 1024 // 4 MiB buffer limit
    private var queuedBytes: Int = 0

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func write(data: Data) throws {
        guard !isClosed else {
            throw WorkerError.processNotRunning
        }
        guard queuedBytes + data.count <= maxQueuedBytes else {
            throw WorkerError.framingError("Pipe writer buffer full (\(queuedBytes) bytes queued).")
        }

        queuedBytes += data.count
        defer { queuedBytes -= data.count }

        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            isClosed = true
            throw error
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? fileHandle.close()
    }
}

// MARK: - WorkerClient Actor

public actor WorkerClient {
    // Process and Pipes
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pipeWriter: SequentialPipeWriter?

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
    private var isDiscardingOversizedLine: Bool = false
    private let maxFrameBytes: Int = 1024 * 1024 // Strict 1 MiB limit
    private var stderrRingBuffer: [String] = []
    private let maxStderrLines: Int = 500

    // Receiver task and stream
    private var stdoutStreamContinuation: AsyncStream<Data>.Continuation?
    private var stdoutConsumerTask: Task<Void, Never>?

    // Public State
    public private(set) var workerPid: Int32 = 0
    public private(set) var pythonVersion: String = ""
    public private(set) var workerVersion: String = ""
    public private(set) var capabilities: [String] = []
    public private(set) var isConnected: Bool = false

    public init() {}

    deinit {
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
        let sessionId = UUID()
        self.currentSessionId = sessionId
        self.incomingBuffer.removeAll(keepingCapacity: true)
        self.isDiscardingOversizedLine = false
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
        self.pipeWriter = SequentialPipeWriter(fileHandle: inPipe.fileHandleForWriting)

        // Setup ordered stdout AsyncStream to guarantee FIFO chunk handling
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.stdoutStreamContinuation = continuation

        // Spawns a single consumer task for all incoming chunks
        self.stdoutConsumerTask = Task { [weak self] in
            for await chunk in stream {
                guard let self = self else { break }
                await self.processIncomingStdoutChunk(chunk, session: sessionId)
            }
            guard let self = self else { return }
            await self.handleStdoutEOF(session: sessionId)
        }

        // Readability Handler delivers chunks to stream sequentially
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF reached
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        // Continuous Stderr Drain to Ring Buffer
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

    // MARK: - Incoming Chunk & Framing Handling (FIFO)

    private func processIncomingStdoutChunk(_ chunk: Data, session: UUID) {
        guard session == self.currentSessionId else { return }

        incomingBuffer.append(chunk)

        // Process frames delimited by newline byte (0x0A)
        while let newlineIndex = incomingBuffer.firstIndex(of: 0x0A) {
            let lineData = incomingBuffer.subdata(in: 0..<newlineIndex)
            incomingBuffer.removeSubrange(0...newlineIndex)

            if isDiscardingOversizedLine {
                // We reached the newline of the oversized line; reset discard mode and do NOT dispatch tail
                isDiscardingOversizedLine = false
                continue
            }

            if lineData.count > maxFrameBytes {
                failAllPending(with: WorkerError.messageTooLarge(bytes: lineData.count), session: session)
                continue
            }

            guard !lineData.isEmpty else { continue }
            handleCompleteFrame(lineData, session: session)
        }

        // If buffer has exceeded maxFrameBytes without reaching a newline, enter discard mode
        if incomingBuffer.count > maxFrameBytes {
            let overflowBytes = incomingBuffer.count
            isDiscardingOversizedLine = true
            incomingBuffer.removeAll(keepingCapacity: false)
            failAllPending(with: WorkerError.messageTooLarge(bytes: overflowBytes), session: session)
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

        // Process any trailing bytes before closing
        if !incomingBuffer.isEmpty && !isDiscardingOversizedLine {
            let remaining = incomingBuffer
            incomingBuffer.removeAll()
            if remaining.count <= maxFrameBytes {
                handleCompleteFrame(remaining, session: session)
            }
        }

        self.isConnected = false
        failAllPending(with: WorkerError.processTerminated, session: session)
    }

    private func handleCompleteFrame(_ frameData: Data, session: UUID) {
        guard session == self.currentSessionId else { return }

        guard let envelope = try? JSONDecoder().decode(JSONRPCResponseEnvelope.self, from: frameData) else {
            return
        }

        // Validate JSON-RPC 2.0 version
        guard envelope.jsonrpc == "2.0" else {
            return
        }

        guard let id = envelope.id else {
            return
        }

        guard let pending = pendingRequests[id], pending.sessionId == session else {
            return
        }

        if let errorPayload = envelope.error {
            resolveRequest(id: id, session: session, result: .failure(WorkerError.rpcError(
                code: errorPayload.code,
                message: errorPayload.message,
                data: errorPayload.data
            )))
        } else {
            resolveRequest(id: id, session: session, result: .success(frameData))
        }
    }

    // MARK: - Centralized Continuation Resolver

    private func resolveRequest(id: Int, session: UUID, result: Result<Data, Error>) {
        guard let pending = pendingRequests[id] else { return }
        guard pending.sessionId == session else { return }

        pendingRequests.removeValue(forKey: id)
        pending.deadlineTask?.cancel()
        pending.continuation.resume(with: result)
    }

    private func failAllPending(with error: Error, session: UUID) {
        let matching = pendingRequests.filter { $0.value.sessionId == session }
        for (id, _) in matching {
            pendingRequests.removeValue(forKey: id)
        }
        for (_, pending) in matching {
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
        guard let proc = process, proc.isRunning, let writer = pipeWriter else {
            throw WorkerError.processNotRunning
        }

        let reqId = nextRequestId
        nextRequestId += 1
        let sessionId = self.currentSessionId

        let rpcReq = JSONRPCRequest(id: reqId, method: method, params: params)
        let data = try JSONEncoder().encode(rpcReq)
        var lineData = data
        lineData.append(0x0A) // '\n'

        // Enforce 1 MiB framing limit on outbound request
        guard lineData.count <= maxFrameBytes else {
            throw WorkerError.messageTooLarge(bytes: lineData.count)
        }

        let responseFrameData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Deadline timer task that returns immediately on cancellation
                let deadlineTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        await self?.resolveRequest(
                            id: reqId,
                            session: sessionId,
                            result: .failure(WorkerError.requestTimeout(seconds: timeoutSeconds))
                        )
                    } catch {
                        // Cancelled before deadline: return immediately
                        return
                    }
                }

                self.pendingRequests[reqId] = PendingRequest(
                    id: reqId,
                    sessionId: sessionId,
                    continuation: continuation,
                    deadlineTask: deadlineTask
                )

                // Write asynchronously via sequential pipe writer
                Task {
                    do {
                        try await writer.write(data: lineData)
                    } catch {
                        self.resolveRequest(id: reqId, session: sessionId, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolveRequest(id: reqId, session: sessionId, result: .failure(WorkerError.requestCancelled))
            }
        }

        // Validate envelope
        let envelope = try JSONDecoder().decode(GenericRPCEnvelope<R>.self, from: responseFrameData)
        guard envelope.jsonrpc == "2.0" else {
            throw WorkerError.invalidResponse("Invalid JSON-RPC version: \(envelope.jsonrpc)")
        }

        if let res = envelope.result {
            return res
        } else if let err = envelope.error {
            throw WorkerError.rpcError(code: err.code, message: err.message, data: err.data)
        } else {
            throw WorkerError.invalidResponse("Envelope contained neither result nor error.")
        }
    }

    public func sendNotification<P: Encodable & Sendable>(method: String, params: P? = nil) async throws {
        guard let proc = process, proc.isRunning, let writer = pipeWriter else {
            throw WorkerError.processNotRunning
        }
        let notif = JSONRPCRequest<P>(id: nil, method: method, params: params)
        var data = try JSONEncoder().encode(notif)
        data.append(0x0A)
        guard data.count <= maxFrameBytes else {
            throw WorkerError.messageTooLarge(bytes: data.count)
        }
        try await writer.write(data: data)
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

    public func modelStatus(profileId: String? = nil) async throws -> ModelStatusResult {
        let params = ModelStatusParams(profileId: profileId)
        return try await sendRequest(method: "ai.model_status", params: params, timeoutSeconds: 10.0)
    }

    public func localInferTest(prompt: String, profileId: String? = nil) async throws -> LocalInferResult {
        let params = LocalInferParams(prompt: prompt, profileId: profileId)
        return try await sendRequest(method: "ai.local_infer_test", params: params, timeoutSeconds: 60.0)
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
        let session = self.currentSessionId
        failAllPending(with: WorkerError.processTerminated, session: session)

        guard let proc = process, proc.isRunning else {
            self.stdoutStreamContinuation?.finish()
            await self.pipeWriter?.close()
            self.process = nil
            self.isConnected = false
            self.workerPid = 0
            return
        }

        let pid = proc.processIdentifier

        // 1. Try graceful shutdown notification
        try? await sendNotification(method: "shutdown", params: nil as String?)

        // 2. Close stdin handle
        await pipeWriter?.close()

        // 3. Grace period wait (Keep stdout/stderr draining active)
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

        // 6. Verify process exit before disposal
        for _ in 0..<10 {
            if kill(pid, 0) != 0 {
                terminated = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Now detach readability handlers safely after exit
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutStreamContinuation?.finish()
        stdoutConsumerTask?.cancel()

        self.process = nil
        self.isConnected = false
        self.workerPid = 0
    }
}
