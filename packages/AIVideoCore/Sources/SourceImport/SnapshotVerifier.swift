//
// SnapshotVerifier.swift — Streaming SHA-256 Verification & Authoritative Snapshot Reader for Gate G1 S05
//
// Streams large files without loading entire bytes into memory, validates path traversal,
// and ensures authoritative readers never accept tampered or corrupted snapshots.
//

import CryptoKit
import Darwin
import Foundation

public struct SnapshotVerifier: Sendable {
    public static let defaultChunkSize: Int = 128 * 1024 // 128 KiB chunks

    public init() {}

    /// Computes streaming SHA-256 hex string for a file at given URL
    public static func computeSha256(for url: URL, chunkSize: Int = defaultChunkSize) throws -> String {
        let path = url.standardizedFileURL.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "Không thể mở file để tính SHA-256 (\(path), errno \(err))")
        }
        defer { close(fd) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = read(fd, &buffer, chunkSize)
            if bytesRead < 0 {
                let err = errno
                throw SourceImportError.ioError(message: "Lỗi đọc tệp khi băm SHA-256 (\(err))")
            }
            if bytesRead == 0 {
                break
            }
            hasher.update(data: Data(buffer[0..<bytesRead]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates that a relative path does not escape the project root (prevents path traversal and symlink escape)
    public static func resolveSafePath(
        relativePath: String,
        projectRoot: URL
    ) throws -> URL {
        let segments = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )

        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !segments.contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              }) else {
            throw SourceImportError.pathTraversalDetected(
                path: relativePath
            )
        }

        let root = projectRoot.standardizedFileURL
            .resolvingSymlinksInPath()

        let target = root.appendingPathComponent(
            relativePath
        ).standardizedFileURL

        let parent = target.deletingLastPathComponent()
            .resolvingSymlinksInPath()

        let prefix = root.path.hasSuffix("/")
            ? root.path
            : root.path + "/"

        // Check parent even if the target does not exist yet.
        guard parent.path == root.path ||
              parent.path.hasPrefix(prefix) else {
            throw SourceImportError.pathTraversalDetected(
                path: parent.path
            )
        }

        let finalResolved = target.resolvingSymlinksInPath()

        guard finalResolved.path == root.path ||
              finalResolved.path.hasPrefix(prefix) else {
            throw SourceImportError.pathTraversalDetected(
                path: finalResolved.path
            )
        }

        return target
    }
}

// MARK: - Authoritative Snapshot Reader

public struct AuthoritativeSourceReader: Sendable {
    public init() {}

    /// Authoritative verification: verifies that the sealed snapshot exists, matches byteSize,
    /// matches contentSha256, and resides safely within projectRoot.
    public static func verifySnapshot(ref: SealedSourceRef, projectRoot: URL) throws -> URL {
        guard ref.isSealed else {
            throw SourceImportError.corruptedSnapshot(
                path: ref.snapshotRelativePath,
                reason: "Unsealed source reference"
            )
        }

        let snapshotURL = try SnapshotVerifier.resolveSafePath(
            relativePath: ref.snapshotRelativePath,
            projectRoot: projectRoot
        )

        let path = snapshotURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SourceImportError.fileNotFound(path: path)
        }

        // 1. Verify byte size
        var st = stat()
        guard stat(path, &st) == 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "stat snapshot thất bại (\(err))")
        }
        let actualSize = Int64(st.st_size)
        if actualSize != ref.byteSize {
            throw SourceImportError.corruptedSnapshot(
                path: path,
                reason: "Kích thước không khớp (kỳ vọng: \(ref.byteSize), thực tế: \(actualSize))"
            )
        }

        // 2. Verify SHA-256 hash
        let actualHash = try SnapshotVerifier.computeSha256(for: snapshotURL)
        if actualHash != ref.contentSha256 {
            throw SourceImportError.checksumMismatch(expected: ref.contentSha256, actual: actualHash)
        }

        return snapshotURL
    }

    /// Stream large media without loading the entire file into RAM.
    ///
    /// Do not publish authoritative outputs before this method
    /// returns without throwing.
    public static func forEachVerifiedChunk(
        ref: SealedSourceRef,
        projectRoot: URL,
        chunkSize: Int = SnapshotVerifier.defaultChunkSize,
        consume: (Data) throws -> Void
    ) throws {
        guard chunkSize > 0 else {
            throw SourceImportError.ioError(
                message: "chunkSize must be positive"
            )
        }

        let verifiedURL = try verifySnapshot(
            ref: ref,
            projectRoot: projectRoot
        )

        let handle = try FileHandle(forReadingFrom: verifiedURL)
        defer { try? handle.close() }

        while let bytes = try handle.read(
            upToCount: chunkSize
        ), !bytes.isEmpty {
            try consume(bytes)
        }

        // Revalidate to detect changes during streaming.
        _ = try verifySnapshot(
            ref: ref,
            projectRoot: projectRoot
        )
    }

    /// Read full data of snapshot after authoritative verification
    public static func readData(ref: SealedSourceRef, projectRoot: URL) throws -> Data {
        let verifiedURL = try verifySnapshot(ref: ref, projectRoot: projectRoot)
        return try Data(contentsOf: verifiedURL)
    }
}
