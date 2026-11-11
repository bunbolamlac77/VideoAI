// DataContracts.swift — Canonical Data Models and Enums for Gate G1 (S04)
// Implements the 5 orthogonal axes and publication state machines defined in 02-ANALYSIS-AND-DATA.md and 05-ARCHITECTURE-AND-ROADMAP.md.

import Foundation

// MARK: - 1. The 5 Orthogonal Evidence Axes

public enum Origin: String, Codable, Sendable {
    case user
    case visualModel = "visual_model"
    case asr
    case audioDetector = "audio_detector"
    case ocr
    case metadata
    case derived
}

public enum EpistemicStatus: String, Codable, Sendable {
    case observed
    case reported
    case inferred
    case unknown
}

public enum ReviewStatus: String, Codable, Sendable {
    case unreviewed
    case autoChecked = "auto_checked"
    case needsReview = "needs_review"
    case confirmed
    case rejected
    case superseded
}

public enum SupportStatus: String, Codable, Sendable {
    case supported
    case contradicted
    case insufficient
    case disputed
}

public enum AllowedUse: String, Codable, Sendable {
    case directClaim = "direct_claim"
    case attributedOrQualified = "attributed_or_qualified"
    case illustrativeOnly = "illustrative_only"
    case exclude
}

// MARK: - 2. Artifact Publication State Machine (Section 6)

public enum ArtifactPublicationState: String, Codable, Sendable, Comparable {
    case prepared = "PREPARED"
    case materialized = "MATERIALIZED"
    case verified = "VERIFIED"
    case committed = "COMMITTED"

    private var rank: Int {
        switch self {
        case .prepared: return 1
        case .materialized: return 2
        case .verified: return 3
        case .committed: return 4
        }
    }

    public static func < (lhs: ArtifactPublicationState, rhs: ArtifactPublicationState) -> Bool {
        return lhs.rank < rhs.rank
    }

    /// Validates state transition strictly: PREPARED -> MATERIALIZED -> VERIFIED -> COMMITTED
    public func canTransition(to next: ArtifactPublicationState) -> Bool {
        switch (self, next) {
        case (.prepared, .materialized): return true
        case (.materialized, .verified): return true
        case (.verified, .committed): return true
        default: return false
        }
    }
}

// MARK: - 3. Job and Attempt State Machine (Section 7)

public enum JobStatus: String, Codable, Sendable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"

    public func canTransition(to next: JobStatus) -> Bool {
        switch (self, next) {
        case (.queued, .running): return true
        case (.queued, .cancelled): return true
        case (.running, .succeeded): return true
        case (.running, .failed): return true
        case (.running, .cancelled): return true
        default: return false
        }
    }
}

// MARK: - 4. Canonical Claim Model

public enum DataContractDateFormatters {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: string) {
            return d
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

public struct TimeRange: Codable, Sendable, Equatable {
    public let startFrame: Int
    public let endFrame: Int
    public let timeBaseNum: Int
    public let timeBaseDen: Int

    public enum CodingKeys: String, CodingKey {
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case timeBaseNum = "time_base_num"
        case timeBaseDen = "time_base_den"
    }

    public init(startFrame: Int, endFrame: Int, timeBaseNum: Int = 1, timeBaseDen: Int = 24) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.timeBaseNum = timeBaseNum
        self.timeBaseDen = timeBaseDen
    }

    public var durationSeconds: Double {
        let frames = Double(max(0, endFrame - startFrame))
        let fps = Double(timeBaseDen) / Double(timeBaseNum)
        return fps > 0 ? frames / fps : 0.0
    }
}

public struct ClaimRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { claimId }
    public let claimId: UUID
    public let revisionId: UUID
    public let workdayId: UUID
    public let text: String

    // The 5 Orthogonal Axes
    public let origin: Origin
    public let epistemicStatus: EpistemicStatus
    public let reviewStatus: ReviewStatus
    public let supportStatus: SupportStatus
    public let allowedUse: AllowedUse

    public let sourceRevisionId: UUID?
    public let timeRange: TimeRange?
    public let confirmationId: UUID?
    public let confidenceRaw: Double?
    public let createdAt: Date

    public enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case revisionId = "revision_id"
        case workdayId = "workday_id"
        case text
        case origin
        case epistemicStatus = "epistemic_status"
        case reviewStatus = "review_status"
        case supportStatus = "support_status"
        case allowedUse = "allowed_use"
        case sourceRevisionId = "source_revision_id"
        case timeRange = "time_range"
        case confirmationId = "confirmation_id"
        case confidenceRaw = "confidence_raw"
        case createdAt = "created_at"
    }

    public init(
        claimId: UUID = UUID(),
        revisionId: UUID = UUID(),
        workdayId: UUID,
        text: String,
        origin: Origin,
        epistemicStatus: EpistemicStatus,
        reviewStatus: ReviewStatus = .unreviewed,
        supportStatus: SupportStatus = .insufficient,
        allowedUse: AllowedUse = .exclude,
        sourceRevisionId: UUID? = nil,
        timeRange: TimeRange? = nil,
        confirmationId: UUID? = nil,
        confidenceRaw: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.claimId = claimId
        self.revisionId = revisionId
        self.workdayId = workdayId
        self.text = text
        self.origin = origin
        self.epistemicStatus = epistemicStatus
        self.reviewStatus = reviewStatus
        self.supportStatus = supportStatus
        self.allowedUse = allowedUse
        self.sourceRevisionId = sourceRevisionId
        self.timeRange = timeRange
        self.confirmationId = confirmationId
        self.confidenceRaw = confidenceRaw
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.claimId = try container.decode(UUID.self, forKey: .claimId)
        self.revisionId = try container.decode(UUID.self, forKey: .revisionId)
        self.workdayId = try container.decode(UUID.self, forKey: .workdayId)
        self.text = try container.decode(String.self, forKey: .text)
        self.origin = try container.decode(Origin.self, forKey: .origin)
        self.epistemicStatus = try container.decode(EpistemicStatus.self, forKey: .epistemicStatus)
        self.reviewStatus = try container.decodeIfPresent(ReviewStatus.self, forKey: .reviewStatus) ?? .unreviewed
        self.supportStatus = try container.decodeIfPresent(SupportStatus.self, forKey: .supportStatus) ?? .insufficient
        self.allowedUse = try container.decodeIfPresent(AllowedUse.self, forKey: .allowedUse) ?? .exclude
        self.sourceRevisionId = try container.decodeIfPresent(UUID.self, forKey: .sourceRevisionId)
        self.timeRange = try container.decodeIfPresent(TimeRange.self, forKey: .timeRange)
        self.confirmationId = try container.decodeIfPresent(UUID.self, forKey: .confirmationId)
        self.confidenceRaw = try container.decodeIfPresent(Double.self, forKey: .confidenceRaw)

        let dateStr = try container.decode(String.self, forKey: .createdAt)
        guard let parsedDate = DataContractDateFormatters.date(from: dateStr) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: container, debugDescription: "Invalid ISO-8601 date format: \(dateStr)")
        }
        self.createdAt = parsedDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(claimId, forKey: .claimId)
        try container.encode(revisionId, forKey: .revisionId)
        try container.encode(workdayId, forKey: .workdayId)
        try container.encode(text, forKey: .text)
        try container.encode(origin, forKey: .origin)
        try container.encode(epistemicStatus, forKey: .epistemicStatus)
        try container.encode(reviewStatus, forKey: .reviewStatus)
        try container.encode(supportStatus, forKey: .supportStatus)
        try container.encode(allowedUse, forKey: .allowedUse)
        try container.encodeIfPresent(sourceRevisionId, forKey: .sourceRevisionId)
        try container.encodeIfPresent(timeRange, forKey: .timeRange)
        try container.encodeIfPresent(confirmationId, forKey: .confirmationId)
        try container.encodeIfPresent(confidenceRaw, forKey: .confidenceRaw)
        try container.encode(DataContractDateFormatters.string(from: createdAt), forKey: .createdAt)
    }

    /// Invariant: user_confirmed does NOT turn origin into observed
    public func confirmingUserFact(confirmationId: UUID = UUID()) -> ClaimRecord {
        return ClaimRecord(
            claimId: self.claimId,
            revisionId: UUID(), // creates fresh revision
            workdayId: self.workdayId,
            text: self.text,
            origin: self.origin, // Preserves origin (never becomes visualModel or observed)
            epistemicStatus: self.epistemicStatus, // Preserves reported
            reviewStatus: .confirmed,
            supportStatus: self.supportStatus,
            allowedUse: self.allowedUse,
            sourceRevisionId: self.sourceRevisionId,
            timeRange: self.timeRange,
            confirmationId: confirmationId,
            confidenceRaw: self.confidenceRaw,
            createdAt: Date()
        )
    }
}

// MARK: - 5. Canonical Artifact Publication Model

public struct ArtifactPublicationRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { publicationId }
    public let publicationId: UUID
    public let projectId: UUID
    public let jobId: UUID
    public let attemptId: UUID
    public let fencingToken: Int
    public let artifactType: String
    public private(set) var state: ArtifactPublicationState
    public private(set) var tempPath: String?
    public private(set) var canonicalPath: String?
    public private(set) var sha256Hash: String?
    public private(set) var byteSize: Int?
    /// (P1-01) How many artifacts this logical job will publish. A job may only be marked
    /// SUCCEEDED once this many publications are COMMITTED; a job with a multi-artifact
    /// expectation (e.g. MP4 + DRP + receipt) used to be declared successful after the first.
    public let expectedPublicationCount: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case publicationId = "publication_id"
        case projectId = "project_id"
        case jobId = "job_id"
        case attemptId = "attempt_id"
        case fencingToken = "fencing_token"
        case artifactType = "artifact_type"
        case state
        case tempPath = "temp_path"
        case canonicalPath = "canonical_path"
        case sha256Hash = "sha256_hash"
        case byteSize = "byte_size"
        case expectedPublicationCount = "expected_publication_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        publicationId: UUID = UUID(),
        projectId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        artifactType: String,
        state: ArtifactPublicationState = .prepared,
        tempPath: String? = nil,
        canonicalPath: String? = nil,
        sha256Hash: String? = nil,
        byteSize: Int? = nil,
        expectedPublicationCount: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.publicationId = publicationId
        self.projectId = projectId
        self.jobId = jobId
        self.attemptId = attemptId
        self.fencingToken = fencingToken
        self.artifactType = artifactType
        self.state = state
        self.tempPath = tempPath
        self.canonicalPath = canonicalPath
        self.sha256Hash = sha256Hash
        self.byteSize = byteSize
        self.expectedPublicationCount = max(1, expectedPublicationCount)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.publicationId = try container.decode(UUID.self, forKey: .publicationId)
        self.projectId = try container.decode(UUID.self, forKey: .projectId)
        self.jobId = try container.decode(UUID.self, forKey: .jobId)
        self.attemptId = try container.decode(UUID.self, forKey: .attemptId)
        self.fencingToken = try container.decode(Int.self, forKey: .fencingToken)
        self.artifactType = try container.decode(String.self, forKey: .artifactType)
        self.state = try container.decode(ArtifactPublicationState.self, forKey: .state)
        self.tempPath = try container.decodeIfPresent(String.self, forKey: .tempPath)
        self.canonicalPath = try container.decodeIfPresent(String.self, forKey: .canonicalPath)
        self.sha256Hash = try container.decodeIfPresent(String.self, forKey: .sha256Hash)
        self.byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize)
        // Legacy rows predate the field and describe single-artifact jobs.
        self.expectedPublicationCount = max(
            1, try container.decodeIfPresent(Int.self, forKey: .expectedPublicationCount) ?? 1
        )

        let createdStr = try container.decode(String.self, forKey: .createdAt)
        guard let parsedCreated = DataContractDateFormatters.date(from: createdStr) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: container, debugDescription: "Invalid ISO-8601 created_at: \(createdStr)")
        }
        self.createdAt = parsedCreated

        let updatedStr = try container.decode(String.self, forKey: .updatedAt)
        guard let parsedUpdated = DataContractDateFormatters.date(from: updatedStr) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: container, debugDescription: "Invalid ISO-8601 updated_at: \(updatedStr)")
        }
        self.updatedAt = parsedUpdated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(publicationId, forKey: .publicationId)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(jobId, forKey: .jobId)
        try container.encode(attemptId, forKey: .attemptId)
        try container.encode(fencingToken, forKey: .fencingToken)
        try container.encode(artifactType, forKey: .artifactType)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(tempPath, forKey: .tempPath)
        try container.encodeIfPresent(canonicalPath, forKey: .canonicalPath)
        try container.encodeIfPresent(sha256Hash, forKey: .sha256Hash)
        try container.encodeIfPresent(byteSize, forKey: .byteSize)
        try container.encode(expectedPublicationCount, forKey: .expectedPublicationCount)
        try container.encode(DataContractDateFormatters.string(from: createdAt), forKey: .createdAt)
        try container.encode(DataContractDateFormatters.string(from: updatedAt), forKey: .updatedAt)
    }

    public mutating func transitionToMaterialized(tempPath: String) throws {
        guard state.canTransition(to: .materialized) else {
            throw ContractError.illegalStateTransition("Cannot transition from \(state.rawValue) to MATERIALIZED")
        }
        self.tempPath = tempPath
        self.state = .materialized
        self.updatedAt = Date()
    }

    public mutating func transitionToVerified(sha256: String, size: Int) throws {
        guard state.canTransition(to: .verified) else {
            throw ContractError.illegalStateTransition("Cannot transition from \(state.rawValue) to VERIFIED")
        }
        guard sha256.count == 64 else {
            throw ContractError.invalidPayload("SHA-256 hash must be 64 hexadecimal characters")
        }
        self.sha256Hash = sha256
        self.byteSize = size
        self.state = .verified
        self.updatedAt = Date()
    }

    public mutating func transitionToCommitted(canonicalPath: String) throws {
        guard state.canTransition(to: .committed) else {
            throw ContractError.illegalStateTransition("Cannot transition from \(state.rawValue) to COMMITTED")
        }
        self.canonicalPath = canonicalPath
        self.state = .committed
        self.updatedAt = Date()
    }
}

// MARK: - 6. Contract Errors

public enum ContractError: Error, LocalizedError {
    case illegalStateTransition(String)
    case invalidPayload(String)
    case expiredApproval(String)
    case staleRevision(String)

    public var errorDescription: String? {
        switch self {
        case .illegalStateTransition(let msg): return "Illegal State Transition: \(msg)"
        case .invalidPayload(let msg): return "Invalid Payload: \(msg)"
        case .expiredApproval(let msg): return "Expired Approval: \(msg)"
        case .staleRevision(let msg): return "Stale Revision: \(msg)"
        }
    }
}
