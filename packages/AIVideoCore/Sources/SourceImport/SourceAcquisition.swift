import CryptoKit
import Darwin
import Foundation

public enum AcquisitionFaultInjection: Sendable, Equatable {
    case simulateInterruptedCopy(bytesToWrite: Int)
    case simulateSourceMutationBeforeSeal
}

public struct AcquisitionResult: Sendable, Equatable {
    public let revision: SourceRevision
    public let sealedRef: SealedSourceRef
    public let isDeduplicated: Bool

    public init(
        revision: SourceRevision,
        sealedRef: SealedSourceRef,
        isDeduplicated: Bool
    ) {
        self.revision = revision
        self.sealedRef = sealedRef
        self.isDeduplicated = isDeduplicated
    }
}

public struct SourceAcquisition: Sendable {
    public static let stagingSubdir = "staging/sources"
    public static let blobsSubdir = "blobs"
    public static let copyChunkSize = 1024 * 1024

    public init() {}

    public static func acquire(
        sourceURL: URL,
        mediaId: UUID,
        projectRoot: URL,
        bookmarkData: Data? = nil,
        preferredMethod: AcquisitionMethod? = nil,
        simulatedAvailableBytes: Int64? = nil,
        faultInjection: AcquisitionFaultInjection? = nil
    ) throws -> AcquisitionResult {
        try SourceInspector.withSourceAccess(
            url: sourceURL,
            bookmarkData: bookmarkData
        ) { resolvedURL in
            try acquireResolved(
                sourceURL: resolvedURL,
                mediaId: mediaId,
                projectRoot: projectRoot,
                preferredMethod: preferredMethod,
                simulatedAvailableBytes: simulatedAvailableBytes,
                faultInjection: faultInjection
            )
        }
    }

    private static func acquireResolved(
        sourceURL: URL,
        mediaId: UUID,
        projectRoot: URL,
        preferredMethod: AcquisitionMethod?,
        simulatedAvailableBytes: Int64?,
        faultInjection: AcquisitionFaultInjection?
    ) throws -> AcquisitionResult {
        let preflight = try SourceInspector.inspectResolvedURL(sourceURL)
        let initial = preflight.fileIdentity

        // One descriptor for copying, checking identity and hashing.
        let sourceFD = open(sourceURL.path, O_RDONLY)
        guard sourceFD >= 0 else {
            throw SourceImportError.ioError(
                message: "Open source failed: errno \(errno)"
            )
        }
        defer { _ = close(sourceFD) }

        try verifySourceStability(
            sourceFD: sourceFD,
            sourceURL: sourceURL,
            initialIdentity: initial
        )

        let method = preferredMethod ?? (
            APFSCapability.canClone(
                from: sourceURL,
                to: projectRoot
            ) ? .apfsClone : .fullCopy
        )

        _ = try DiskBudgetPlanner.planBudget(
            fileSize: initial.byteSize,
            method: method,
            destinationURL: projectRoot,
            simulatedAvailableBytes: simulatedAvailableBytes
        )

        let fm = FileManager.default
        let stagingDir = projectRoot.appendingPathComponent(
            stagingSubdir,
            isDirectory: true
        )

        try fm.createDirectory(
            at: stagingDir,
            withIntermediateDirectories: true
        )

        let stagingURL = stagingDir.appendingPathComponent(
            "\(UUID().uuidString).tmp"
        )

        defer {
            if case .simulateInterruptedCopy = faultInjection {
                // Preserve staging for the crash-recovery test.
            } else {
                try? fm.removeItem(at: stagingURL)
            }
        }

        // Acquire source bytes.
        var actualMethod = method

        if method == .apfsClone {
            do {
                try APFSCapability.clone(
                    from: sourceURL,
                    to: stagingURL
                )
            } catch SourceImportError.insufficientDiskSpace {
                throw SourceImportError.insufficientDiskSpace(
                    requiredBytes: initial.byteSize,
                    availableBytes: 0,
                    reserveBytes: DiskBudgetPlanner.defaultSystemReserveBytes
                )
            } catch {
                // Clone is an optimization, not a requirement.
                try? fm.removeItem(at: stagingURL)

                actualMethod = .fullCopy

                // A clone budget is insufficient for full-copy fallback.
                _ = try DiskBudgetPlanner.planBudget(
                    fileSize: initial.byteSize,
                    method: .fullCopy,
                    destinationURL: projectRoot,
                    simulatedAvailableBytes: simulatedAvailableBytes
                )

                try performFullCopy(
                    sourceFD: sourceFD,
                    to: stagingURL,
                    expectedSize: initial.byteSize,
                    faultInjection: faultInjection
                )
            }
        } else {
            try performFullCopy(
                sourceFD: sourceFD,
                to: stagingURL,
                expectedSize: initial.byteSize,
                faultInjection: faultInjection
            )
        }

        if faultInjection == .simulateSourceMutationBeforeSeal {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: sourceURL.path,
                reason: "Injected mutation for regression test"
            )
        }

        // Check identity before reading the digests.
        try verifySourceStability(
            sourceFD: sourceFD,
            sourceURL: sourceURL,
            initialIdentity: initial
        )

        let snapshotHash = try SnapshotVerifier.computeSha256(
            for: stagingURL
        )

        let sourceHash = try computeSourceSha256(sourceFD)

        // Check again after both hashes are calculated.
        try verifySourceStability(
            sourceFD: sourceFD,
            sourceURL: sourceURL,
            initialIdentity: initial
        )

        guard sourceHash == snapshotHash else {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: sourceURL.path,
                reason: "Source and snapshot SHA-256 differ"
            )
        }

        var stagingStat = stat()
        guard stat(stagingURL.path, &stagingStat) == 0 else {
            throw SourceImportError.ioError(
                message: "stat staging failed: errno \(errno)"
            )
        }

        guard Int64(stagingStat.st_size) == initial.byteSize else {
            throw SourceImportError.corruptedSnapshot(
                path: stagingURL.path,
                reason: "Staging size differs from source size"
            )
        }

        // Content-addressed immutable blob path.
        let relativePath =
            "\(blobsSubdir)/\(snapshotHash.prefix(2))/\(snapshotHash).blob"

        let sealedURL = try SnapshotVerifier.resolveSafePath(
            relativePath: relativePath,
            projectRoot: projectRoot
        )

        let blobDir = sealedURL.deletingLastPathComponent()

        try fm.createDirectory(
            at: blobDir,
            withIntermediateDirectories: true
        )

        // Verify again after creating the destination directory.
        _ = try SnapshotVerifier.resolveSafePath(
            relativePath: relativePath,
            projectRoot: projectRoot
        )

        // Set read-only and synchronize BEFORE publication.
        try sealAndSyncStaging(stagingURL)

        // This operation will never overwrite an existing blob.
        let promotion = renamex_np(
            stagingURL.path,
            sealedURL.path,
            UInt32(RENAME_EXCL)
        )

        let isDeduplicated: Bool

        if promotion == 0 {
            isDeduplicated = false
            try fsyncDirectory(blobDir)

        } else if errno == EEXIST {
            // Another import may have published this hash concurrently.
            let existingHash = try SnapshotVerifier.computeSha256(
                for: sealedURL
            )

            guard existingHash == snapshotHash else {
                throw SourceImportError.existingBlobConflict(
                    path: sealedURL.path
                )
            }

            try fm.removeItem(at: stagingURL)
            isDeduplicated = true

        } else {
            throw SourceImportError.ioError(
                message: "Exclusive blob promotion failed: errno \(errno)"
            )
        }

        // Only construct a verified reference after promotion.
        let revisionID = UUID()
        let now = Date()

        let revision = SourceRevision(
            sourceRevisionId: revisionID,
            mediaId: mediaId,
            contentSha256: snapshotHash,
            byteSize: initial.byteSize,
            snapshotRelativePath: relativePath,
            acquisitionMethod: actualMethod,
            verifiedAt: now,
            verificationStatus: .verified,
            fileIdentity: initial,
            policyVersion: "1.0"
        )

        let sealedRef = SealedSourceRef(
            sourceRevisionId: revisionID,
            mediaId: mediaId,
            contentSha256: snapshotHash,
            byteSize: initial.byteSize,
            snapshotRelativePath: relativePath,
            verifiedAt: now,
            isSealed: true
        )

        return AcquisitionResult(
            revision: revision,
            sealedRef: sealedRef,
            isDeduplicated: isDeduplicated
        )
    }

    private static func sealAndSyncStaging(_ url: URL) throws {
        let fd = open(url.path, O_RDWR)

        guard fd >= 0 else {
            throw SourceImportError.ioError(
                message: "Open staging for sealing failed: errno \(errno)"
            )
        }
        defer { _ = close(fd) }

        guard fchmod(
            fd,
            S_IRUSR | S_IRGRP | S_IROTH
        ) == 0 else {
            throw SourceImportError.ioError(
                message: "fchmod staging failed: errno \(errno)"
            )
        }

        guard fsync(fd) == 0 else {
            throw SourceImportError.ioError(
                message: "fsync staging failed: errno \(errno)"
            )
        }
    }

    private static func fsyncDirectory(_ dir: URL) throws {
        let dirFD = open(dir.path, O_RDONLY)

        guard dirFD >= 0 else {
            throw SourceImportError.ioError(
                message: "Open blob directory failed: errno \(errno)"
            )
        }
        defer { _ = close(dirFD) }

        guard fsync(dirFD) == 0 else {
            throw SourceImportError.ioError(
                message: "fsync blob directory failed: errno \(errno)"
            )
        }
    }

    private static func performFullCopy(
        sourceFD: Int32,
        to stagingURL: URL,
        expectedSize: Int64,
        faultInjection: AcquisitionFaultInjection?
    ) throws {
        var dstFD = open(
            stagingURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )

        guard dstFD >= 0 else {
            throw SourceImportError.ioError(
                message: "Create staging failed: errno \(errno)"
            )
        }
        defer {
            if dstFD >= 0 {
                _ = close(dstFD)
            }
        }

        guard lseek(sourceFD, 0, SEEK_SET) >= 0 else {
            throw SourceImportError.ioError(
                message: "Seek source failed: errno \(errno)"
            )
        }

        var buffer = [UInt8](
            repeating: 0,
            count: copyChunkSize
        )
        var total: Int64 = 0

        while true {
            let count = read(
                sourceFD,
                &buffer,
                buffer.count
            )

            if count < 0 && errno == EINTR {
                continue
            }

            guard count >= 0 else {
                throw SourceImportError.ioError(
                    message: "Read source failed: errno \(errno)"
                )
            }

            if count == 0 {
                break
            }

            if let faultInjection,
               case .simulateInterruptedCopy(let limit) = faultInjection,
               total + Int64(count) >= Int64(limit) {

                let partial = max(0, limit - Int(total))

                if partial > 0 {
                    try writeAll(
                        dstFD,
                        bytes: buffer,
                        count: partial,
                        expectedSize: expectedSize,
                        alreadyWritten: total
                    )
                }

                throw SourceImportError.ioError(
                    message: "Injected interrupted copy"
                )
            }

            try writeAll(
                dstFD,
                bytes: buffer,
                count: count,
                expectedSize: expectedSize,
                alreadyWritten: total
            )

            total += Int64(count)
        }

        guard total == expectedSize else {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: stagingURL.path,
                reason: "Source size changed during copy"
            )
        }

        guard fsync(dstFD) == 0 else {
            throw SourceImportError.ioError(
                message: "fsync staging failed: errno \(errno)"
            )
        }

        let closeResult = close(dstFD)
        dstFD = -1

        guard closeResult == 0 else {
            throw SourceImportError.ioError(
                message: "close staging failed: errno \(errno)"
            )
        }
    }

    private static func writeAll(
        _ fd: Int32,
        bytes: [UInt8],
        count: Int,
        expectedSize: Int64,
        alreadyWritten: Int64
    ) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw SourceImportError.ioError(
                    message: "Empty copy buffer"
                )
            }

            var position = 0

            while position < count {
                let n = Darwin.write(
                    fd,
                    base.advanced(by: position),
                    count - position
                )

                if n < 0 && errno == EINTR {
                    continue
                }

                if n < 0 && errno == ENOSPC {
                    throw SourceImportError.insufficientDiskSpace(
                        requiredBytes: expectedSize,
                        availableBytes: alreadyWritten + Int64(position),
                        reserveBytes: 0
                    )
                }

                guard n > 0 else {
                    throw SourceImportError.ioError(
                        message: "Write staging failed: errno \(errno)"
                    )
                }

                position += n
            }
        }
    }

    private static func computeSourceSha256(
        _ fd: Int32
    ) throws -> String {
        var sha = SHA256()
        var buffer = [UInt8](
            repeating: 0,
            count: copyChunkSize
        )
        var offset: Int64 = 0

        while true {
            let n = pread(
                fd,
                &buffer,
                buffer.count,
                off_t(offset)
            )

            if n < 0 && errno == EINTR {
                continue
            }

            guard n >= 0 else {
                throw SourceImportError.ioError(
                    message: "Hash source read failed: errno \(errno)"
                )
            }

            if n == 0 {
                break
            }

            sha.update(data: Data(buffer[0..<n]))
            offset += Int64(n)
        }

        return sha.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // Internal to permit deterministic mutation tests.
    static func verifySourceStability(
        sourceFD: Int32,
        sourceURL: URL,
        initialIdentity: FileIdentity
    ) throws {
        var fdStat = stat()
        var pathStat = stat()

        guard fstat(sourceFD, &fdStat) == 0,
              stat(sourceURL.path, &pathStat) == 0 else {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: sourceURL.path,
                reason: "Source disappeared or fstat/stat failed"
            )
        }

        func isSame(_ st: stat) -> Bool {
            guard UInt64(st.st_ino) == initialIdentity.inode,
                  UInt64(st.st_dev) == initialIdentity.device,
                  Int64(st.st_size) == initialIdentity.byteSize else {
                return false
            }

            let mtime =
                Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 +
                Int64(st.st_mtimespec.tv_nsec)

            let ctime =
                Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 +
                Int64(st.st_ctimespec.tv_nsec)

            if let previous = initialIdentity.modifiedTimeNanoseconds,
               previous != mtime {
                return false
            }

            if let previous = initialIdentity.statusChangedTimeNanoseconds,
               previous != ctime {
                return false
            }

            return true
        }

        guard isSame(fdStat), isSame(pathStat) else {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: sourceURL.path,
                reason: "Source inode, size, mtime(ns) or ctime(ns) changed"
            )
        }
    }

    public static func acquireBatch(
        sources: [(url: URL, mediaId: UUID, bookmark: Data?)],
        projectRoot: URL,
        manifestStore: SourceManifestStore? = nil,
        preferredMethod: AcquisitionMethod? = nil
    ) async -> BatchImportReport {
        var results: [BatchImportItemResult] = []

        for item in sources {
            do {
                let acquired = try acquire(
                    sourceURL: item.url,
                    mediaId: item.mediaId,
                    projectRoot: projectRoot,
                    bookmarkData: item.bookmark,
                    preferredMethod: preferredMethod
                )

                if let store = manifestStore {
                    let asset = SourceAsset(
                        mediaId: item.mediaId,
                        logicalName: item.url.lastPathComponent,
                        originalPath: item.url.path,
                        candidateKind: MediaCandidateKind.from(
                            pathExtension: item.url.pathExtension
                        ),
                        securityScopedBookmark: item.bookmark
                    )

                    // Never swallow a manifest persistence error.
                    try await store.registerImport(
                        asset: asset,
                        revision: acquired.revision
                    )
                }

                results.append(
                    BatchImportItemResult(
                        url: item.url,
                        mediaId: item.mediaId,
                        result: .success(acquired)
                    )
                )

            } catch let error as SourceImportError {
                results.append(
                    BatchImportItemResult(
                        url: item.url,
                        mediaId: item.mediaId,
                        result: .failure(error)
                    )
                )

            } catch {
                results.append(
                    BatchImportItemResult(
                        url: item.url,
                        mediaId: item.mediaId,
                        result: .failure(
                            .ioError(message: error.localizedDescription)
                        )
                    )
                )
            }
        }

        return BatchImportReport(items: results)
    }
}

public struct BatchImportItemResult: Sendable {
    public let url: URL
    public let mediaId: UUID
    public let result: Result<AcquisitionResult, SourceImportError>

    public init(
        url: URL,
        mediaId: UUID,
        result: Result<AcquisitionResult, SourceImportError>
    ) {
        self.url = url
        self.mediaId = mediaId
        self.result = result
    }
}

public struct BatchImportReport: Sendable {
    public let items: [BatchImportItemResult]

    public init(items: [BatchImportItemResult]) {
        self.items = items
    }

    public var succeededCount: Int {
        items.filter {
            if case .success = $0.result {
                return true
            }
            return false
        }.count
    }

    public var failedCount: Int {
        items.filter {
            if case .failure = $0.result {
                return true
            }
            return false
        }.count
    }
}
