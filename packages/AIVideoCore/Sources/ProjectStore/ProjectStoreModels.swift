import Foundation

public enum ProjectStoreError: Error, Sendable, Equatable, LocalizedError {
    case database(code: Int32, message: String)
    case projectLocked
    case unsupportedSchema(version: Int)
    case invalidInput(String)
    case notFound(String)
    case revisionConflict(expected: Int, actual: Int)
    case idempotencyConflict(operationID: String)
    case staleAIResult
    case approvalTargetMismatch
    case simulatedWriteFailure

    public var errorDescription: String? {
        switch self {
        case .database(let code, let message):
            return "SQLite \(code): \(message)"
        case .projectLocked:
            return "Project is already open for writing in another process"
        case .unsupportedSchema(let version):
            return "Unsupported schema version: \(version)"
        case .invalidInput(let value):
            return "Invalid input: \(value)"
        case .notFound(let value):
            return "Missing record: \(value)"
        case .revisionConflict(let expected, let actual):
            return "Expected revision \(expected), current revision \(actual)"
        case .idempotencyConflict(let operationID):
            return "Idempotency key reused with different payload: \(operationID)"
        case .staleAIResult:
            return "AI result targets an obsolete brief revision"
        case .approvalTargetMismatch:
            return "Script not the selected revision displayed to user"
        case .simulatedWriteFailure:
            return "Injected failure before commit"
        }
    }
}

public struct StoreReceipt: Codable, Sendable, Equatable {
    public let operationID: String
    public let projectID: UUID
    public let workdayID: UUID?
    public let subjectID: UUID
    public let committedRevision: Int
    public var wasReplayed: Bool

    public init(
        operationID: String,
        projectID: UUID,
        workdayID: UUID?,
        subjectID: UUID,
        committedRevision: Int,
        wasReplayed: Bool = false
    ) {
        self.operationID = operationID
        self.projectID = projectID
        self.workdayID = workdayID
        self.subjectID = subjectID
        self.committedRevision = committedRevision
        self.wasReplayed = wasReplayed
    }
}

public struct BriefSnapshot: Sendable, Equatable {
    public let briefRevisionID: UUID
    public let workdayID: UUID
    public let text: String
    public let workdayRevision: Int

    public init(
        briefRevisionID: UUID,
        workdayID: UUID,
        text: String,
        workdayRevision: Int
    ) {
        self.briefRevisionID = briefRevisionID
        self.workdayID = workdayID
        self.text = text
        self.workdayRevision = workdayRevision
    }
}

public struct StoreDiagnostics: Sendable, Equatable {
    public let journalMode: String
    public let synchronous: Int
    public let foreignKeys: Bool
    public let schemaVersion: Int

    public init(
        journalMode: String,
        synchronous: Int,
        foreignKeys: Bool,
        schemaVersion: Int
    ) {
        self.journalMode = journalMode
        self.synchronous = synchronous
        self.foreignKeys = foreignKeys
        self.schemaVersion = schemaVersion
    }
}

public enum SavePhase: Sendable, Equatable {
    case idle
    case pending
    case saving
    case saved(revision: Int)
    case failed(message: String)
}

public struct PreparedSourceRecord: Sendable {
    public let mediaID: UUID
    public let sourceRevisionID: UUID
    public let projectID: UUID
    public let originalPath: String
    public let snapshotPath: String
    public let sha256: String
    public let byteSize: Int64

    public init(
        mediaID: UUID,
        sourceRevisionID: UUID,
        projectID: UUID,
        originalPath: String,
        snapshotPath: String,
        sha256: String,
        byteSize: Int64
    ) {
        self.mediaID = mediaID
        self.sourceRevisionID = sourceRevisionID
        self.projectID = projectID
        self.originalPath = originalPath
        self.snapshotPath = snapshotPath
        self.sha256 = sha256
        self.byteSize = byteSize
    }
}
