//
// SourceInspector.swift — Read-Only Source Scanner & Preflight Inspector for Gate G1 S05
//
// Reads files strictly in read-only mode, preserves security-scoped access,
// captures robust FileIdentity, and classifies errors specifically.
//

import Darwin
import Foundation

public struct SourceInspector: Sendable {
    public init() {}

    /// Inspect a source URL with optional security-scoped bookmark
    public static func inspect(url: URL, bookmarkData: Data? = nil) throws -> PreflightReport {
        var targetURL = url
        var isSecurityScoped = false

        // 1. Resolve security-scoped bookmark if provided
        if let bookmarkData = bookmarkData {
            var isStale = false
            do {
                let resolved = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    throw SourceImportError.permissionDenied(
                        path: url.path,
                        message: "Quyền truy cập file đã cũ (stale bookmark). Vui lòng chọn lại file."
                    )
                }
                targetURL = resolved
                isSecurityScoped = true
            } catch {
                throw SourceImportError.permissionDenied(
                    path: url.path,
                    message: "Không thể giải mã security-scoped bookmark: \(error.localizedDescription)"
                )
            }
        }

        // 2. Start security-scoped access if applicable
        if isSecurityScoped || targetURL.path.hasPrefix("/Volumes/") {
            let accessed = targetURL.startAccessingSecurityScopedResource()
            if accessed {
                defer { targetURL.stopAccessingSecurityScopedResource() }
                return try inspectFileInternal(url: targetURL)
            }
        }

        return try inspectFileInternal(url: targetURL)
    }

    private static func inspectFileInternal(url: URL) throws -> PreflightReport {
        let path = url.standardizedFileURL.path

        // Check format candidate from extension
        let ext = url.pathExtension.lowercased()
        let kind = MediaCandidateKind.from(pathExtension: ext)
        guard kind != .unsupported else {
            throw SourceImportError.unsupportedFormat(
                path: path,
                reason: "Định dạng file không thuộc danh mục được hỗ trợ (.mov, .mp4, .m4v, .jpg, .jpeg, .heic, .png)"
            )
        }

        // Open file strictly read-only using POSIX descriptor
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            let err = errno
            if err == ENOENT {
                throw SourceImportError.fileNotFound(path: path)
            } else if err == EACCES || err == EPERM {
                throw SourceImportError.permissionDenied(
                    path: path,
                    message: "Không có quyền đọc file (errno \(err): \(String(cString: strerror(err))))"
                )
            } else {
                throw SourceImportError.ioError(
                    message: "Lỗi mở file (\(err)): \(String(cString: strerror(err)))"
                )
            }
        }
        defer { close(fd) }

        // Query file status via fstat
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let err = errno
            throw SourceImportError.ioError(message: "fstat thất bại (\(err)): \(String(cString: strerror(err)))")
        }

        let size = Int64(st.st_size)
        guard size > 0 else {
            throw SourceImportError.zeroByteFile(path: path)
        }

        // Validate basic media header sanity
        try validateMediaHeader(fd: fd, kind: kind, path: path, fileSize: size)

        let identity = FileIdentity(
            inode: UInt64(st.st_ino),
            device: UInt64(st.st_dev),
            byteSize: size,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
            permissions: UInt16(st.st_mode & 0o777)
        )

        let logicalName = url.lastPathComponent

        return PreflightReport(
            url: url,
            logicalName: logicalName,
            candidateKind: kind,
            byteSize: size,
            fileIdentity: identity
        )
    }

    /// Read first few bytes to verify basic media header integrity
    private static func validateMediaHeader(fd: Int32, kind: MediaCandidateKind, path: String, fileSize: Int64) throws {
        var headerBuffer = [UInt8](repeating: 0, count: min(Int(fileSize), 128))
        let bytesRead = pread(fd, &headerBuffer, headerBuffer.count, 0)
        guard bytesRead >= min(Int(fileSize), 16) else {
            throw SourceImportError.ioError(message: "Không thể đọc header file: \(path)")
        }

        switch kind {
        case .video:
            // MP4 / MOV / M4V files typically have 'ftyp' at offset 4..7 or 'moov'
            let hasFtyp = bytesRead >= 8 && headerBuffer[4] == 0x66 && headerBuffer[5] == 0x74 && headerBuffer[6] == 0x79 && headerBuffer[7] == 0x70 // "ftyp"
            let hasMoov = bytesRead >= 8 && headerBuffer[4] == 0x6d && headerBuffer[5] == 0x6f && headerBuffer[6] == 0x6f && headerBuffer[7] == 0x76 // "moov"
            let hasWide = bytesRead >= 8 && headerBuffer[4] == 0x77 && headerBuffer[5] == 0x69 && headerBuffer[6] == 0x64 && headerBuffer[7] == 0x65 // "wide"
            let hasMdat = bytesRead >= 8 && headerBuffer[4] == 0x6d && headerBuffer[5] == 0x64 && headerBuffer[6] == 0x61 && headerBuffer[7] == 0x74 // "mdat"
            if !hasFtyp && !hasMoov && !hasWide && !hasMdat {
                throw SourceImportError.unsupportedFormat(
                    path: path,
                    reason: "Header video không hợp lệ (không chứa ftyp/moov/wide/mdat)"
                )
            }
        case .image:
            let isJPEG = bytesRead >= 2 && headerBuffer[0] == 0xFF && headerBuffer[1] == 0xD8
            let isPNG = bytesRead >= 4 && headerBuffer[0] == 0x89 && headerBuffer[1] == 0x50 && headerBuffer[2] == 0x4E && headerBuffer[3] == 0x47
            let isHEIC = bytesRead >= 8 && headerBuffer[4] == 0x66 && headerBuffer[5] == 0x74 && headerBuffer[6] == 0x79 && headerBuffer[7] == 0x70
            if !isJPEG && !isPNG && !isHEIC {
                throw SourceImportError.unsupportedFormat(
                    path: path,
                    reason: "Header hình ảnh không hợp lệ (không phải JPEG, PNG hoặc HEIC chuẩn)"
                )
            }
        case .unsupported:
            throw SourceImportError.unsupportedFormat(path: path, reason: "Định dạng không được hỗ trợ")
        }
    }
}
