//
// SourceAcquisition.swift — Safe Source Acquisition Pipeline (APFS Clone + Fallback Copy) for Gate G1 S05
//
// Enforces source stability checks, disk budget verification, atomic staging,
// deduplication, and immutable sealing. Never modifies or deletes originals.
//

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

    public init(revision: SourceRevision, sealedRef: SealedSourceRef, isDeduplicated: Bool) {
        self.revision = revision
        self.sealedRef = sealedRef
        self.isDeduplicated = isDeduplicated
    }
}

public struct SourceAcquisition: Sendable {
    public static let stagingSubdir = "staging/sources"
    public static let blobsSubdir = "blobs"
    public static let copyChunkSize = 1024 * 1024 // 1 MiB chunks

    public init() {}

    /// Perform safe acquisition of a source file into the project's immutable snapshot repository
    public static func acquire(
        sourceURL: URL,
        mediaId: UUID,
        projectRoot: URL,
        bookmarkData: Data? = nil,
        preferredMethod: AcquisitionMethod? = nil,
        simulatedAvailableBytes: Int64? = nil,
        faultInjection: AcquisitionFaultInjection? = nil
    ) throws -> AcquisitionResult {
        // 1. Preflight source inspection and capture authoritative initial FileIdentity
        let preflight = try SourceInspector.inspect(url: sourceURL, bookmarkData: bookmarkData)
        let initialIdentity = preflight.fileIdentity

        // 2. Determine acquisition capability (APFS clone vs full copy fallback)
        let method: AcquisitionMethod
        if let preferred = preferredMethod {
            method = preferred
        } else {
            let canClone = APFSCapability.canClone(from: sourceURL, to: projectRoot)
            method = canClone ? .apfsClone : .fullCopy
        }

        // 3. Verify disk budget before touching filesystem
        _ = try DiskBudgetPlanner.planBudget(
            fileSize: initialIdentity.byteSize,
            method: method,
            destinationURL: projectRoot,
            simulatedAvailableBytes: simulatedAvailableBytes
        )

        // 4. Create staging directory on target filesystem
        let stagingDir = projectRoot.appendingPathComponent(stagingSubdir, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let stagingFileName = "\(UUID().uuidString).tmp"
        let stagingURL = stagingDir.appendingPathComponent(stagingFileName)

        // Ensure staging file is cleaned up if acquisition fails prematurely
        var stagingCommitted = false
        defer {
            if !stagingCommitted && faultInjection != .simulateInterruptedCopy(bytesToWrite: 0) {
                // If fault injection simulated interrupted copy, preserve file for crash recovery test
                if case .simulateInterruptedCopy = faultInjection {
                    // keep file intact
                } else {
                    try? FileManager.default.removeItem(at: stagingURL)
                }
            }
        }

        // 5. Acquire bytes into staging location
        var actualMethod = method
        if method == .apfsClone {
            do {
                try APFSCapability.clone(from: sourceURL, to: stagingURL)
            } catch {
                // If clone failed unexpectedly (e.g. cross-volume or filesystem limitation), fallback to copy
                try? FileManager.default.removeItem(at: stagingURL)
                actualMethod = .fullCopy
                try performFullCopy(
                    from: sourceURL,
                    to: stagingURL,
                    expectedSize: initialIdentity.byteSize,
                    faultInjection: faultInjection
                )
            }
        } else {
            try performFullCopy(
                from: sourceURL,
                to: stagingURL,
                expectedSize: initialIdentity.byteSize,
                faultInjection: faultInjection
            )
        }

        // 6. Stability verification: check that original file has not mutated during acquisition
        if faultInjection == .simulateSourceMutationBeforeSeal {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: sourceURL.path,
                reason: "Simulated mutation: mtime changed during acquisition"
            )
        }

        try verifySourceStability(sourceURL: sourceURL, initialIdentity: initialIdentity)

        // 7. Verify snapshot & calculate streaming SHA-256
        let contentSha256 = try SnapshotVerifier.computeSha256(for: stagingURL)

        // Verify staging file size
        var stagingStat = stat()
        guard stat(stagingURL.path, &stagingStat) == 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "stat staging failed (\(err))")
        }
        let stagingSize = Int64(stagingStat.st_size)
        guard stagingSize == initialIdentity.byteSize else {
            throw SourceImportError.corruptedSnapshot(
                path: stagingURL.path,
                reason: "Dung lượng staging (\(stagingSize)) không khớp nguồn (\(initialIdentity.byteSize))"
            )
        }

        // 8. Deduplication & Atomic Promotion to Immutable Blob
        let hashPrefix = String(contentSha256.prefix(2))
        let relativeBlobPath = "\(blobsSubdir)/\(hashPrefix)/\(contentSha256).blob"
        let sealedURL = try SnapshotVerifier.resolveSafePath(relativePath: relativeBlobPath, projectRoot: projectRoot)

        var isDeduplicated = false
        if FileManager.default.fileExists(atPath: sealedURL.path) {
            // Deduplicated blob already exists! Verify existing blob hash before reusing
            let existingHash = try SnapshotVerifier.computeSha256(for: sealedURL)
            if existingHash == contentSha256 {
                // Valid deduplication: remove staging file and reuse existing blob
                try? FileManager.default.removeItem(at: stagingURL)
                isDeduplicated = true
            } else {
                throw SourceImportError.corruptedSnapshot(
                    path: sealedURL.path,
                    reason: "Blob hiện có bị sai lệch băm SHA-256"
                )
            }
        } else {
            // New blob: create parent directory, atomic rename, and set read-only permissions
            let blobDir = sealedURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)

            // Atomic rename from staging to final immutable location
            let renameResult = rename(stagingURL.path, sealedURL.path)
            guard renameResult == 0 else {
                let err = errno
                throw SourceImportError.ioError(message: "Atomic rename failed (\(err)): \(String(cString: strerror(err)))")
            }

            // Lock permissions to read-only (0444)
            chmod(sealedURL.path, S_IRUSR | S_IRGRP | S_IROTH)
        }

        stagingCommitted = true

        let sourceRevisionId = UUID()
        let now = Date()

        let revision = SourceRevision(
            sourceRevisionId: sourceRevisionId,
            mediaId: mediaId,
            contentSha256: contentSha256,
            byteSize: initialIdentity.byteSize,
            snapshotRelativePath: relativeBlobPath,
            acquisitionMethod: actualMethod,
            verifiedAt: now,
            verificationStatus: .verified,
            fileIdentity: initialIdentity,
            policyVersion: "1.0"
        )

        let sealedRef = SealedSourceRef(
            sourceRevisionId: sourceRevisionId,
            mediaId: mediaId,
            contentSha256: contentSha256,
            byteSize: initialIdentity.byteSize,
            snapshotRelativePath: relativeBlobPath,
            verifiedAt: now,
            isSealed: true
        )

        return AcquisitionResult(
            revision: revision,
            sealedRef: sealedRef,
            isDeduplicated: isDeduplicated
        )
    }

    /// Full-copy fallback implementation with chunked streaming and fault injection
    private static func performFullCopy(
        from sourceURL: URL,
        to stagingURL: URL,
        expectedSize: Int64,
        faultInjection: AcquisitionFaultInjection?
    ) throws {
        let srcFd = open(sourceURL.standardizedFileURL.path, O_RDONLY)
        guard srcFd >= 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "Không thể mở file nguồn để sao chép (errno \(err))")
        }
        defer { close(srcFd) }

        // Create staging file exclusively
        let dstFd = open(stagingURL.standardizedFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard dstFd >= 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "Không thể tạo file staging (errno \(err))")
        }
        defer { close(dstFd) }

        var buffer = [UInt8](repeating: 0, count: copyChunkSize)
        var totalWritten: Int64 = 0

        while true {
            let bytesRead = read(srcFd, &buffer, copyChunkSize)
            if bytesRead < 0 {
                let err = errno
                throw SourceImportError.ioError(message: "Lỗi đọc file nguồn khi copy (errno \(err))")
            }
            if bytesRead == 0 {
                break
            }

            // Check fault injection for simulated interruption
            if let fault = faultInjection, case .simulateInterruptedCopy(let limit) = fault {
                if totalWritten + Int64(bytesRead) >= Int64(limit) {
                    let toWrite = max(0, limit - Int(totalWritten))
                    if toWrite > 0 {
                        _ = buffer.withUnsafeBytes { ptr in
                            Darwin.write(dstFd, ptr.baseAddress!, toWrite)
                        }
                    }
                    throw SourceImportError.ioError(message: "Fault Injection: Tiến trình bị ngắt đột ngột khi đang copy")
                }
            }

            var writtenSoFar = 0
            while writtenSoFar < bytesRead {
                let remaining = bytesRead - writtenSoFar
                let written = buffer.withUnsafeBytes { rawPtr -> Int in
                    guard let base = rawPtr.baseAddress else { return -1 }
                    return Darwin.write(dstFd, base.advanced(by: writtenSoFar), remaining)
                }
                if written < 0 {
                    let err = errno
                    if err == ENOSPC {
                        throw SourceImportError.insufficientDiskSpace(
                            requiredBytes: expectedSize,
                            availableBytes: totalWritten,
                            reserveBytes: 0
                        )
                    }
                    throw SourceImportError.ioError(message: "Lỗi ghi file staging (errno \(err))")
                }
                writtenSoFar += written
            }
            totalWritten += Int64(bytesRead)
        }

        // Fsync to guarantee bytes are flushed to disk
        fsync(dstFd)
    }

    /// Verify that the original source file on disk has not been altered during copy
    private static func verifySourceStability(sourceURL: URL, initialIdentity: FileIdentity) throws {
        var currentStat = stat()
        let path = sourceURL.standardizedFileURL.path
        guard stat(path, &currentStat) == 0 else {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: path,
                reason: "Tệp nguồn bị di chuyển hoặc xóa trong lúc acquisition"
            )
        }

        if UInt64(currentStat.st_ino) != initialIdentity.inode ||
            UInt64(currentStat.st_dev) != initialIdentity.device {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: path,
                reason: "Tệp nguồn bị hoán đổi (inode hoặc dev thay đổi)"
            )
        }

        if Int64(currentStat.st_size) != initialIdentity.byteSize {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: path,
                reason: "Dung lượng tệp nguồn thay đổi trong lúc copy (\(initialIdentity.byteSize) -> \(currentStat.st_size))"
            )
        }

        let currentSec = currentStat.st_mtimespec.tv_sec
        let initialSec = Int(initialIdentity.modifiedAt.timeIntervalSince1970)
        if abs(currentSec - initialSec) > 1 {
            throw SourceImportError.sourceMutatedDuringAcquisition(
                path: path,
                reason: "Thời gian chỉnh sửa (mtime) của tệp nguồn bị thay đổi trong lúc copy"
            )
        }
    }

    /// Perform resilient batch import where failures on one file do not break independent files
    public static func acquireBatch(
        sources: [(url: URL, mediaId: UUID, bookmark: Data?)],
        projectRoot: URL,
        manifestStore: SourceManifestStore? = nil,
        preferredMethod: AcquisitionMethod? = nil
    ) async -> BatchImportReport {
        var results: [BatchImportItemResult] = []
        for item in sources {
            do {
                let res = try acquire(
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
                        candidateKind: MediaCandidateKind.from(pathExtension: item.url.pathExtension),
                        securityScopedBookmark: item.bookmark
                    )
                    try? await store.registerAsset(asset)
                    try? await store.registerRevision(res.revision)
                }
                results.append(BatchImportItemResult(url: item.url, mediaId: item.mediaId, result: .success(res)))
            } catch let err as SourceImportError {
                results.append(BatchImportItemResult(url: item.url, mediaId: item.mediaId, result: .failure(err)))
            } catch {
                results.append(BatchImportItemResult(url: item.url, mediaId: item.mediaId, result: .failure(.ioError(message: error.localizedDescription))))
            }
        }
        return BatchImportReport(items: results)
    }
}

public struct BatchImportItemResult: Sendable {
    public let url: URL
    public let mediaId: UUID
    public let result: Result<AcquisitionResult, SourceImportError>

    public init(url: URL, mediaId: UUID, result: Result<AcquisitionResult, SourceImportError>) {
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
        items.filter { if case .success = $0.result { return true }; return false }.count
    }

    public var failedCount: Int {
        items.filter { if case .failure = $0.result { return true }; return false }.count
    }
}
