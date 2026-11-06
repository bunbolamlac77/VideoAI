//
// APFSCapability.swift — Filesystem Probe and APFS Clone Primitives for Gate G1 S05
//
// Conforms strictly to Sendable for Swift 6 concurrency.
//

import Darwin
import Foundation

public struct APFSCapability: Sendable {
    public init() {}

    /// Query the filesystem type name for a given URL (e.g., "apfs", "hfs", "msdos")
    public static func filesystemType(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        var sfs = statfs()
        guard statfs(path, &sfs) == 0 else {
            return nil
        }
        return withUnsafePointer(to: &sfs.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { cStr in
                String(cString: cStr).lowercased()
            }
        }
    }

    /// Check whether the URL resides on an APFS filesystem
    public static func isAPFSVolume(at url: URL) -> Bool {
        return filesystemType(for: url) == "apfs"
    }

    /// Check if two URLs reside on the exact same device/volume
    public static func isSameVolume(source: URL, destination: URL) -> Bool {
        var stSource = stat()
        var stDest = stat()

        let srcPath = source.standardizedFileURL.path
        let dstPath = destination.standardizedFileURL.path

        guard stat(srcPath, &stSource) == 0 else {
            return false
        }
        // If destination doesn't exist yet, inspect its parent directory
        if stat(dstPath, &stDest) != 0 {
            let parentPath = destination.deletingLastPathComponent().standardizedFileURL.path
            guard stat(parentPath, &stDest) == 0 else {
                return false
            }
        }

        return stSource.st_dev == stDest.st_dev
    }

    /// Check whether APFS clone is possible between source and destination
    /// Requirements:
    /// 1. Both reside on an APFS volume.
    /// 2. Both reside on the same volume (device ID matches).
    public static func canClone(from source: URL, to destination: URL) -> Bool {
        guard isAPFSVolume(at: source) else { return false }
        guard isAPFSVolume(at: destination.deletingLastPathComponent()) else { return false }
        guard isSameVolume(source: source, destination: destination) else { return false }
        return true
    }

    /// Perform atomic APFS clone using Darwin clonefile(2) with CLONE_NOFOLLOW
    public static func clone(from source: URL, to destination: URL) throws {
        let srcPath = source.standardizedFileURL.path
        let dstPath = destination.standardizedFileURL.path

        // Check source existence
        guard FileManager.default.fileExists(atPath: srcPath) else {
            throw SourceImportError.fileNotFound(path: srcPath)
        }

        // Call clonefile(const char *src, const char *dst, int flags)
        let result = clonefile(srcPath, dstPath, UInt32(CLONE_NOFOLLOW))
        if result != 0 {
            let err = errno
            let errMsg = String(cString: strerror(err))
            if err == EXDEV {
                throw SourceImportError.unsupportedFilesystem(
                    path: dstPath,
                    reason: "Không thể clone qua các phân vùng/ổ đĩa khác nhau (EXDEV). Yêu cầu fallback sang copy."
                )
            } else if err == ENOTSUP {
                throw SourceImportError.unsupportedFilesystem(
                    path: dstPath,
                    reason: "Hệ thống tệp không hỗ trợ clonefile (ENOTSUP). Yêu cầu fallback sang copy."
                )
            } else if err == ENOSPC {
                throw SourceImportError.insufficientDiskSpace(requiredBytes: 0, availableBytes: 0, reserveBytes: 0)
            } else {
                throw SourceImportError.ioError(message: "Lỗi clonefile (\(err)): \(errMsg)")
            }
        }
    }

    /// Live capability probe: attempts a real clone operation in the target directory
    public static func probeCloneSupport(at directoryURL: URL) -> Bool {
        let fm = FileManager.default
        let dirPath = directoryURL.standardizedFileURL.path
        guard fm.fileExists(atPath: dirPath) else { return false }

        let probeSource = directoryURL.appendingPathComponent(".apfs_probe_src_\(UUID().uuidString)")
        let probeDest = directoryURL.appendingPathComponent(".apfs_probe_dst_\(UUID().uuidString)")

        let probeData = Data("APFS_CLONE_PROBE".utf8)
        do {
            try probeData.write(to: probeSource)
            defer {
                try? fm.removeItem(at: probeSource)
                try? fm.removeItem(at: probeDest)
            }
            let res = clonefile(probeSource.path, probeDest.path, UInt32(CLONE_NOFOLLOW))
            return res == 0
        } catch {
            return false
        }
    }
}
