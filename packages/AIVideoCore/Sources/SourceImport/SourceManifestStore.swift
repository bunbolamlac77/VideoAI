//
// SourceManifestStore.swift — Versioned Manifest & Content Identity Store for Gate G1 S05
//
// Manages immutable source revisions, content deduplication, provenance history,
// safe atomic persistence, and orphan staging recovery.
//

import Darwin
import Foundation

public struct SourceManifestData: Codable, Sendable {
    public let manifestVersion: String
    public var assets: [UUID: SourceAsset]
    public var revisions: [UUID: SourceRevision]
    public var revisionsByMediaId: [UUID: [UUID]]
    public var revisionsByContentHash: [String: UUID]

    public enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case assets
        case revisions
        case revisionsByMediaId = "revisions_by_media_id"
        case revisionsByContentHash = "revisions_by_content_hash"
    }

    public init(
        manifestVersion: String = "1.0",
        assets: [UUID: SourceAsset] = [:],
        revisions: [UUID: SourceRevision] = [:],
        revisionsByMediaId: [UUID: [UUID]] = [:],
        revisionsByContentHash: [String: UUID] = [:]
    ) {
        self.manifestVersion = manifestVersion
        self.assets = assets
        self.revisions = revisions
        self.revisionsByMediaId = revisionsByMediaId
        self.revisionsByContentHash = revisionsByContentHash
    }
}

public actor SourceManifestStore {
    public let projectRoot: URL
    private let manifestRelativePath = "manifests/sources_manifest.v1.json"
    private var data: SourceManifestData

    public init(projectRoot: URL) throws {
        self.projectRoot = projectRoot
        let manifestURL = projectRoot.appendingPathComponent("manifests/sources_manifest.v1.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let jsonData = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            self.data = try decoder.decode(SourceManifestData.self, from: jsonData)
        } else {
            self.data = SourceManifestData()
        }
    }

    /// Register a logical asset
    public func registerAsset(_ asset: SourceAsset) throws {
        data.assets[asset.mediaId] = asset
        try saveManifest()
    }

    /// Register a new source revision for an asset
    public func registerRevision(_ revision: SourceRevision) throws {
        let mediaId = revision.mediaId
        data.revisions[revision.sourceRevisionId] = revision

        // Append to history list for this mediaId (preserves all previous revisions)
        if var list = data.revisionsByMediaId[mediaId] {
            list.append(revision.sourceRevisionId)
            data.revisionsByMediaId[mediaId] = list
        } else {
            data.revisionsByMediaId[mediaId] = [revision.sourceRevisionId]
        }

        // Map content hash if not already registered
        if data.revisionsByContentHash[revision.contentSha256] == nil {
            data.revisionsByContentHash[revision.contentSha256] = revision.sourceRevisionId
        }

        try saveManifest()
    }

    /// Retrieve asset by mediaId
    public func getAsset(mediaId: UUID) -> SourceAsset? {
        return data.assets[mediaId]
    }

    /// Retrieve all assets
    public func getAllAssets() -> [SourceAsset] {
        return Array(data.assets.values)
    }

    /// Retrieve revision by sourceRevisionId
    public func getRevision(sourceRevisionId: UUID) -> SourceRevision? {
        return data.revisions[sourceRevisionId]
    }

    /// Retrieve complete revision history for a mediaId in chronological order
    public func getRevisions(for mediaId: UUID) -> [SourceRevision] {
        guard let idList = data.revisionsByMediaId[mediaId] else { return [] }
        return idList.compactMap { data.revisions[$0] }
    }

    /// Retrieve latest revision for a mediaId
    public func getLatestRevision(for mediaId: UUID) -> SourceRevision? {
        guard let lastId = data.revisionsByMediaId[mediaId]?.last else { return nil }
        return data.revisions[lastId]
    }

    /// Find an existing revision by exact content SHA-256 (for deduplication)
    public func findRevision(byContentSha256 sha256: String) -> SourceRevision? {
        guard let revId = data.revisionsByContentHash[sha256] else { return nil }
        return data.revisions[revId]
    }

    /// Find asset by original file path
    public func findAsset(byOriginalPath path: String) -> SourceAsset? {
        return data.assets.values.first { $0.originalPath == path }
    }

    /// Reconcile and safely clean orphan files in staging directory
    /// Guaranteed NEVER to touch committed blobs in blobs/
    @discardableResult
    public func reconcileOrphanStaging() throws -> [String] {
        let stagingDir = projectRoot.appendingPathComponent(SourceAcquisition.stagingSubdir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagingDir.path) else { return [] }

        let fileNames = try fm.contentsOfDirectory(atPath: stagingDir.path)
        var cleaned: [String] = []

        for name in fileNames {
            if name.hasSuffix(".tmp") {
                let fileURL = stagingDir.appendingPathComponent(name)
                try? fm.removeItem(at: fileURL)
                cleaned.append(fileURL.path)
            }
        }
        return cleaned
    }

    /// Atomically persist manifest to disk (tmp file -> fsync -> rename)
    private func saveManifest() throws {
        let manifestsDir = projectRoot.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)

        let targetURL = projectRoot.appendingPathComponent(manifestRelativePath)
        let tmpURL = projectRoot.appendingPathComponent("manifests/sources_manifest.v1.tmp")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(data)

        // Write to temporary file
        let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "Không thể tạo tệp manifest tạm (\(err))")
        }

        let written = jsonData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, jsonData.count)
        }
        guard written == jsonData.count else {
            close(fd)
            let err = errno
            throw SourceImportError.ioError(message: "Ghi tệp manifest tạm không trọn vẹn (\(err))")
        }

        // Flush bytes to disk
        fsync(fd)
        close(fd)

        // Atomic rename
        let renameResult = rename(tmpURL.path, targetURL.path)
        guard renameResult == 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "Atomic rename manifest thất bại (\(err))")
        }
    }
}
