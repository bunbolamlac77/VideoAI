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

    private let manifestRelativePath =
        "manifests/sources_manifest.v1.json"

    private var data: SourceManifestData

    public init(projectRoot: URL) throws {
        self.projectRoot = projectRoot

        let manifestURL = projectRoot.appendingPathComponent(
            "manifests/sources_manifest.v1.json"
        )

        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let bytes = try Data(contentsOf: manifestURL)
            self.data = try JSONDecoder().decode(
                SourceManifestData.self,
                from: bytes
            )
        } else {
            self.data = SourceManifestData()
        }
    }

    /// Register asset and revision in ONE atomic manifest update.
    public func registerImport(
        asset: SourceAsset,
        revision: SourceRevision
    ) throws {
        guard asset.mediaId == revision.mediaId else {
            throw SourceImportError.ioError(
                message: "Asset/revision mediaId mismatch"
            )
        }

        var next = data

        if let existing = next.assets[asset.mediaId] {
            guard existing.originalPath == asset.originalPath,
                  existing.logicalName == asset.logicalName,
                  existing.candidateKind == asset.candidateKind else {
                throw SourceImportError.ioError(
                    message: "Conflicting provenance for existing mediaId"
                )
            }
        } else {
            next.assets[asset.mediaId] = asset
        }

        try insertRevision(revision, into: &next)

        try persist(next)
        data = next
    }

    /// Compatibility API for existing S05 tests.
    public func registerAsset(_ asset: SourceAsset) throws {
        var next = data
        next.assets[asset.mediaId] = asset

        try persist(next)
        data = next
    }

    /// Compatibility API for existing S05 tests.
    public func registerRevision(_ revision: SourceRevision) throws {
        guard data.assets[revision.mediaId] != nil else {
            throw SourceImportError.ioError(
                message: "Cannot register revision without asset"
            )
        }

        var next = data
        try insertRevision(revision, into: &next)

        try persist(next)
        data = next
    }

    private func insertRevision(
        _ revision: SourceRevision,
        into next: inout SourceManifestData
    ) throws {
        if let previous = next.revisions[revision.sourceRevisionId] {
            guard previous == revision else {
                throw SourceImportError.ioError(
                    message: "Revision UUID collision"
                )
            }

            // Safe retry. Do not duplicate revision history.
            return
        }

        next.revisions[revision.sourceRevisionId] = revision

        next.revisionsByMediaId[
            revision.mediaId,
            default: []
        ].append(revision.sourceRevisionId)

        if next.revisionsByContentHash[revision.contentSha256] == nil {
            next.revisionsByContentHash[
                revision.contentSha256
            ] = revision.sourceRevisionId
        }
    }

    public func getAsset(mediaId: UUID) -> SourceAsset? {
        data.assets[mediaId]
    }

    public func getAllAssets() -> [SourceAsset] {
        Array(data.assets.values)
    }

    public func getRevision(
        sourceRevisionId: UUID
    ) -> SourceRevision? {
        data.revisions[sourceRevisionId]
    }

    public func getRevisions(
        for mediaId: UUID
    ) -> [SourceRevision] {
        (data.revisionsByMediaId[mediaId] ?? [])
            .compactMap { data.revisions[$0] }
    }

    public func getLatestRevision(
        for mediaId: UUID
    ) -> SourceRevision? {
        guard let id = data.revisionsByMediaId[mediaId]?.last else {
            return nil
        }

        return data.revisions[id]
    }

    public func findRevision(
        byContentSha256 sha256: String
    ) -> SourceRevision? {
        guard let id = data.revisionsByContentHash[sha256] else {
            return nil
        }

        return data.revisions[id]
    }

    public func findAsset(
        byOriginalPath path: String
    ) -> SourceAsset? {
        data.assets.values.first {
            $0.originalPath == path
        }
    }

    @discardableResult
    public func reconcileOrphanStaging() throws -> [String] {
        let directory = projectRoot.appendingPathComponent(
            SourceAcquisition.stagingSubdir
        )

        let fm = FileManager.default

        guard fm.fileExists(atPath: directory.path) else {
            return []
        }

        var removed: [String] = []

        for name in try fm.contentsOfDirectory(
            atPath: directory.path
        ) where name.hasSuffix(".tmp") {
            let url = directory.appendingPathComponent(name)

            try fm.removeItem(at: url)
            removed.append(url.path)
        }

        return removed
    }

    /// Persist a complete manifest snapshot.
    private func persist(_ next: SourceManifestData) throws {
        let fm = FileManager.default

        let dir = projectRoot.appendingPathComponent(
            "manifests",
            isDirectory: true
        )

        try fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let target = projectRoot.appendingPathComponent(
            manifestRelativePath
        )

        let tmp = dir.appendingPathComponent(
            ".manifest_\(UUID().uuidString).tmp"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let json = try encoder.encode(next)

        var fd = open(
            tmp.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )

        guard fd >= 0 else {
            throw SourceImportError.ioError(
                message: "Create temporary manifest failed: errno \(errno)"
            )
        }

        var renamed = false

        defer {
            if fd >= 0 {
                _ = close(fd)
            }

            if !renamed {
                try? fm.removeItem(at: tmp)
            }
        }

        try json.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw SourceImportError.ioError(
                    message: "Empty manifest JSON buffer"
                )
            }

            var offset = 0

            while offset < raw.count {
                let n = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset
                )

                if n < 0 && errno == EINTR {
                    continue
                }

                guard n > 0 else {
                    throw SourceImportError.ioError(
                        message: "Write manifest failed: errno \(errno)"
                    )
                }

                offset += n
            }
        }

        guard fsync(fd) == 0 else {
            throw SourceImportError.ioError(
                message: "fsync manifest failed: errno \(errno)"
            )
        }

        let closeResult = close(fd)
        fd = -1

        guard closeResult == 0 else {
            throw SourceImportError.ioError(
                message: "close manifest failed: errno \(errno)"
            )
        }

        // This rename atomically REPLACES the manifest on purpose.
        // Do not use this operation for immutable content blobs.
        guard rename(tmp.path, target.path) == 0 else {
            throw SourceImportError.ioError(
                message: "Atomic manifest rename failed: errno \(errno)"
            )
        }

        renamed = true

        // Disk manifest now contains next, even if directory sync fails.
        data = next

        let dirFD = open(dir.path, O_RDONLY)

        guard dirFD >= 0 else {
            throw SourceImportError.ioError(
                message: "Open manifest directory failed: errno \(errno)"
            )
        }
        defer { _ = close(dirFD) }

        guard fsync(dirFD) == 0 else {
            throw SourceImportError.ioError(
                message: "fsync manifest directory failed: errno \(errno)"
            )
        }
    }
}
