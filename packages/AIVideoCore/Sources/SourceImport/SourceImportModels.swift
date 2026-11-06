//
// SourceImportModels.swift — Strongly-Typed Models for Gate G1 (S05) Source Import & Snapshots
//
// Conforms strictly to Sendable and Codable for Swift 6 concurrency.
// Defined in docs/02-ANALYSIS-AND-DATA.md (mục 8) and docs/05-ARCHITECTURE-AND-ROADMAP.md.
//

import Foundation

// MARK: - Media Candidate Kinds

public enum MediaCandidateKind: String, Codable, Sendable, CaseIterable {
    case video = "video"
    case image = "image"
    case unsupported = "unsupported"

    public static func from(pathExtension: String) -> MediaCandidateKind {
        let ext = pathExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch ext {
        case "mov", "mp4", "m4v":
            return .video
        case "jpg", "jpeg", "heic", "png":
            return .image
        default:
            return .unsupported
        }
    }
}

// MARK: - File Identity (Stat-based)

public struct FileIdentity: Codable, Sendable, Equatable {
    public let inode: UInt64
    public let device: UInt64
    public let byteSize: Int64
    public let modifiedAt: Date
    public let permissions: UInt16

    // Optional to preserve compatibility with older manifests.
    public let modifiedTimeNanoseconds: Int64?
    public let statusChangedTimeNanoseconds: Int64?

    public enum CodingKeys: String, CodingKey {
        case inode
        case device
        case byteSize = "byte_size"
        case modifiedAt = "modified_at"
        case permissions
        case modifiedTimeNanoseconds = "modified_time_ns"
        case statusChangedTimeNanoseconds = "status_changed_time_ns"
    }

    public init(
        inode: UInt64,
        device: UInt64,
        byteSize: Int64,
        modifiedAt: Date,
        permissions: UInt16,
        modifiedTimeNanoseconds: Int64? = nil,
        statusChangedTimeNanoseconds: Int64? = nil
    ) {
        self.inode = inode
        self.device = device
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.modifiedTimeNanoseconds = modifiedTimeNanoseconds
        self.statusChangedTimeNanoseconds = statusChangedTimeNanoseconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        inode = try c.decode(UInt64.self, forKey: .inode)
        device = try c.decode(UInt64.self, forKey: .device)
        byteSize = try c.decode(Int64.self, forKey: .byteSize)
        permissions = try c.decode(UInt16.self, forKey: .permissions)

        modifiedTimeNanoseconds = try c.decodeIfPresent(
            Int64.self, forKey: .modifiedTimeNanoseconds
        )

        statusChangedTimeNanoseconds = try c.decodeIfPresent(
            Int64.self, forKey: .statusChangedTimeNanoseconds
        )

        let dateString = try c.decode(String.self, forKey: .modifiedAt)
        guard let date = DataContractDateFormatters.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .modifiedAt,
                in: c,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        modifiedAt = date
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encode(inode, forKey: .inode)
        try c.encode(device, forKey: .device)
        try c.encode(byteSize, forKey: .byteSize)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(
            DataContractDateFormatters.string(from: modifiedAt),
            forKey: .modifiedAt
        )
        try c.encodeIfPresent(
            modifiedTimeNanoseconds, forKey: .modifiedTimeNanoseconds
        )
        try c.encodeIfPresent(
            statusChangedTimeNanoseconds, forKey: .statusChangedTimeNanoseconds
        )
    }
}

// MARK: - Acquisition Method

public enum AcquisitionMethod: String, Codable, Sendable, Equatable {
    case apfsClone = "clone"
    case fullCopy = "copy"
}

// MARK: - Source Verification Status

public enum SourceVerificationStatus: String, Codable, Sendable, Equatable {
    case unverified = "unverified"
    case verified = "verified"
    case corrupted = "corrupted"
    case rejected = "rejected"
}

// MARK: - Source Asset (Logical Asset)

public struct SourceAsset: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { mediaId }
    public let mediaId: UUID
    public let workdayId: UUID?
    public let projectId: UUID?
    public let logicalName: String
    public let originalPath: String
    public let candidateKind: MediaCandidateKind
    public let securityScopedBookmark: Data?
    public let createdAt: Date

    public enum CodingKeys: String, CodingKey {
        case mediaId = "media_id"
        case workdayId = "workday_id"
        case projectId = "project_id"
        case logicalName = "logical_name"
        case originalPath = "original_path"
        case candidateKind = "candidate_kind"
        case securityScopedBookmark = "security_scoped_bookmark"
        case createdAt = "created_at"
    }

    public init(
        mediaId: UUID = UUID(),
        workdayId: UUID? = nil,
        projectId: UUID? = nil,
        logicalName: String,
        originalPath: String,
        candidateKind: MediaCandidateKind,
        securityScopedBookmark: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.mediaId = mediaId
        self.workdayId = workdayId
        self.projectId = projectId
        self.logicalName = logicalName
        self.originalPath = originalPath
        self.candidateKind = candidateKind
        self.securityScopedBookmark = securityScopedBookmark
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mediaId = try container.decode(UUID.self, forKey: .mediaId)
        self.workdayId = try container.decodeIfPresent(UUID.self, forKey: .workdayId)
        self.projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        self.logicalName = try container.decode(String.self, forKey: .logicalName)
        self.originalPath = try container.decode(String.self, forKey: .originalPath)
        self.candidateKind = try container.decode(MediaCandidateKind.self, forKey: .candidateKind)
        self.securityScopedBookmark = try container.decodeIfPresent(Data.self, forKey: .securityScopedBookmark)

        let dateStr = try container.decode(String.self, forKey: .createdAt)
        guard let parsedDate = DataContractDateFormatters.date(from: dateStr) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: container, debugDescription: "Invalid ISO-8601 date: \(dateStr)")
        }
        self.createdAt = parsedDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaId, forKey: .mediaId)
        try container.encodeIfPresent(workdayId, forKey: .workdayId)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encode(logicalName, forKey: .logicalName)
        try container.encode(originalPath, forKey: .originalPath)
        try container.encode(candidateKind, forKey: .candidateKind)
        try container.encodeIfPresent(securityScopedBookmark, forKey: .securityScopedBookmark)
        try container.encode(DataContractDateFormatters.string(from: createdAt), forKey: .createdAt)
    }
}

// MARK: - Source Revision (Content Revision)

public struct SourceRevision: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { sourceRevisionId }
    public let sourceRevisionId: UUID
    public let mediaId: UUID
    public let contentSha256: String
    public let byteSize: Int64
    public let snapshotRelativePath: String
    public let acquisitionMethod: AcquisitionMethod
    public let verifiedAt: Date
    public let verificationStatus: SourceVerificationStatus
    public let fileIdentity: FileIdentity
    public let policyVersion: String

    public enum CodingKeys: String, CodingKey {
        case sourceRevisionId = "source_revision_id"
        case mediaId = "media_id"
        case contentSha256 = "content_sha256"
        case byteSize = "byte_size"
        case snapshotRelativePath = "snapshot_relative_path"
        case acquisitionMethod = "acquisition_method"
        case verifiedAt = "verified_at"
        case verificationStatus = "verification_status"
        case fileIdentity = "file_identity"
        case policyVersion = "policy_version"
    }

    public init(
        sourceRevisionId: UUID = UUID(),
        mediaId: UUID,
        contentSha256: String,
        byteSize: Int64,
        snapshotRelativePath: String,
        acquisitionMethod: AcquisitionMethod,
        verifiedAt: Date = Date(),
        verificationStatus: SourceVerificationStatus = .verified,
        fileIdentity: FileIdentity,
        policyVersion: String = "1.0"
    ) {
        self.sourceRevisionId = sourceRevisionId
        self.mediaId = mediaId
        self.contentSha256 = contentSha256
        self.byteSize = byteSize
        self.snapshotRelativePath = snapshotRelativePath
        self.acquisitionMethod = acquisitionMethod
        self.verifiedAt = verifiedAt
        self.verificationStatus = verificationStatus
        self.fileIdentity = fileIdentity
        self.policyVersion = policyVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceRevisionId = try container.decode(UUID.self, forKey: .sourceRevisionId)
        self.mediaId = try container.decode(UUID.self, forKey: .mediaId)
        self.contentSha256 = try container.decode(String.self, forKey: .contentSha256)
        self.byteSize = try container.decode(Int64.self, forKey: .byteSize)
        self.snapshotRelativePath = try container.decode(String.self, forKey: .snapshotRelativePath)
        self.acquisitionMethod = try container.decode(AcquisitionMethod.self, forKey: .acquisitionMethod)
        self.verificationStatus = try container.decode(SourceVerificationStatus.self, forKey: .verificationStatus)
        self.fileIdentity = try container.decode(FileIdentity.self, forKey: .fileIdentity)
        self.policyVersion = try container.decode(String.self, forKey: .policyVersion)

        let dateStr = try container.decode(String.self, forKey: .verifiedAt)
        guard let parsedDate = DataContractDateFormatters.date(from: dateStr) else {
            throw DecodingError.dataCorruptedError(forKey: .verifiedAt, in: container, debugDescription: "Invalid ISO-8601 date: \(dateStr)")
        }
        self.verifiedAt = parsedDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceRevisionId, forKey: .sourceRevisionId)
        try container.encode(mediaId, forKey: .mediaId)
        try container.encode(contentSha256, forKey: .contentSha256)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encode(snapshotRelativePath, forKey: .snapshotRelativePath)
        try container.encode(acquisitionMethod, forKey: .acquisitionMethod)
        try container.encode(verificationStatus, forKey: .verificationStatus)
        try container.encode(fileIdentity, forKey: .fileIdentity)
        try container.encode(policyVersion, forKey: .policyVersion)
        try container.encode(DataContractDateFormatters.string(from: verifiedAt), forKey: .verifiedAt)
    }
}

// MARK: - Sealed Source Reference (Authoritative Ref)

public struct SealedSourceRef: Codable, Sendable, Equatable {
    public let sourceRevisionId: UUID
    public let mediaId: UUID
    public let contentSha256: String
    public let byteSize: Int64
    public let snapshotRelativePath: String
    public let verifiedAt: Date
    public let isSealed: Bool

    public enum CodingKeys: String, CodingKey {
        case sourceRevisionId = "source_revision_id"
        case mediaId = "media_id"
        case contentSha256 = "content_sha256"
        case byteSize = "byte_size"
        case snapshotRelativePath = "snapshot_relative_path"
        case verifiedAt = "verified_at"
        case isSealed = "is_sealed"
    }

    public init(
        sourceRevisionId: UUID,
        mediaId: UUID,
        contentSha256: String,
        byteSize: Int64,
        snapshotRelativePath: String,
        verifiedAt: Date = Date(),
        isSealed: Bool = true
    ) {
        self.sourceRevisionId = sourceRevisionId
        self.mediaId = mediaId
        self.contentSha256 = contentSha256
        self.byteSize = byteSize
        self.snapshotRelativePath = snapshotRelativePath
        self.verifiedAt = verifiedAt
        self.isSealed = isSealed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceRevisionId = try container.decode(UUID.self, forKey: .sourceRevisionId)
        self.mediaId = try container.decode(UUID.self, forKey: .mediaId)
        self.contentSha256 = try container.decode(String.self, forKey: .contentSha256)
        self.byteSize = try container.decode(Int64.self, forKey: .byteSize)
        self.snapshotRelativePath = try container.decode(String.self, forKey: .snapshotRelativePath)
        self.isSealed = try container.decode(Bool.self, forKey: .isSealed)

        let dateStr = try container.decode(String.self, forKey: .verifiedAt)
        guard let parsedDate = DataContractDateFormatters.date(from: dateStr) else {
            throw DecodingError.dataCorruptedError(forKey: .verifiedAt, in: container, debugDescription: "Invalid ISO-8601 date: \(dateStr)")
        }
        self.verifiedAt = parsedDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceRevisionId, forKey: .sourceRevisionId)
        try container.encode(mediaId, forKey: .mediaId)
        try container.encode(contentSha256, forKey: .contentSha256)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encode(snapshotRelativePath, forKey: .snapshotRelativePath)
        try container.encode(isSealed, forKey: .isSealed)
        try container.encode(DataContractDateFormatters.string(from: verifiedAt), forKey: .verifiedAt)
    }
}

// MARK: - Preflight Report

public struct PreflightReport: Sendable, Equatable {
    public let url: URL
    public let logicalName: String
    public let candidateKind: MediaCandidateKind
    public let byteSize: Int64
    public let fileIdentity: FileIdentity

    public init(
        url: URL,
        logicalName: String,
        candidateKind: MediaCandidateKind,
        byteSize: Int64,
        fileIdentity: FileIdentity
    ) {
        self.url = url
        self.logicalName = logicalName
        self.candidateKind = candidateKind
        self.byteSize = byteSize
        self.fileIdentity = fileIdentity
    }
}

// MARK: - Source Import Errors

public enum SourceImportError: LocalizedError, Sendable, Equatable {
    case fileNotFound(path: String)
    case permissionDenied(path: String, message: String)
    case unsupportedFormat(path: String, reason: String)
    case zeroByteFile(path: String)
    case ioError(message: String)
    case sourceMutatedDuringAcquisition(path: String, reason: String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64, reserveBytes: Int64)
    case unsupportedFilesystem(path: String, reason: String)
    case checksumMismatch(expected: String, actual: String)
    case pathTraversalDetected(path: String)
    case corruptedSnapshot(path: String, reason: String)
    case existingBlobConflict(path: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Tệp nguồn không tồn tại: \(path)"
        case .permissionDenied(let path, let msg):
            return "Quyền truy cập tệp bị từ chối (\(path)): \(msg)"
        case .unsupportedFormat(let path, let reason):
            return "Định dạng tệp không được hỗ trợ (\(path)): \(reason)"
        case .zeroByteFile(let path):
            return "Tệp nguồn có dung lượng 0 byte: \(path)"
        case .ioError(let msg):
            return "Lỗi đọc/ghi I/O: \(msg)"
        case .sourceMutatedDuringAcquisition(let path, let reason):
            return "Nguồn bị thay đổi trong quá trình snapshot (\(path)): \(reason)"
        case .insufficientDiskSpace(let req, let avail, let res):
            return "Không đủ dung lượng ổ đĩa (cần: \(req) bytes, khả dụng: \(avail) bytes, dự trữ: \(res) bytes)"
        case .unsupportedFilesystem(let path, let reason):
            return "Hệ thống tệp không được hỗ trợ (\(path)): \(reason)"
        case .checksumMismatch(let exp, let act):
            return "Mã băm SHA-256 không khớp (kỳ vọng: \(exp), thực tế: \(act))"
        case .pathTraversalDetected(let path):
            return "Phát hiện đường dẫn không hợp lệ hoặc path traversal: \(path)"
        case .corruptedSnapshot(let path, let reason):
            return "Bản snapshot bị hỏng hoặc sai lệch (\(path)): \(reason)"
        case .existingBlobConflict(let path):
            return "Xung đột bản ghi blob hiện có: \(path)"
        }
    }
}
