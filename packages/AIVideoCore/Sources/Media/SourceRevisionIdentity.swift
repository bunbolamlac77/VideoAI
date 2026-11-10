import Foundation
import CryptoKit

public struct SourceRevisionFingerprint: Sendable, Equatable {
    public let canonicalPath: String
    public let sha256: String

    public init(canonicalPath: String, sha256: String) {
        self.canonicalPath = canonicalPath
        self.sha256 = sha256
    }
}

public enum SourceRevisionIdentityError: Error, LocalizedError, Sendable {
    case notRegularFile
    case sourceChangedDuringRead

    public var errorDescription: String? {
        switch self {
        case .notRegularFile:
            return "File video nguồn không hợp lệ."
        case .sourceChangedDuringRead:
            return "Video nguồn đã thay đổi trong quá trình kiểm tra."
        }
    }
}

public enum SourceRevisionIdentity {
    public static func fingerprint(
        filePath: String
    ) throws -> SourceRevisionFingerprint {
        let url = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
        let path = url.path
        let fm = FileManager.default
        let before = try fm.attributesOfItem(atPath: path)

        guard
            let sizeBefore = before[.size] as? NSNumber,
            let mtimeBefore = before[.modificationDate] as? Date,
            before[.type] as? FileAttributeType == .typeRegular
        else {
            throw SourceRevisionIdentityError.notRegularFile
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var sha256 = SHA256()

        while true {
            try Task.checkCancellation()

            guard let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }

            sha256.update(data: chunk)
        }

        let after = try fm.attributesOfItem(atPath: path)

        guard
            let sizeAfter = after[.size] as? NSNumber,
            let mtimeAfter = after[.modificationDate] as? Date,
            sizeBefore.int64Value == sizeAfter.int64Value,
            mtimeBefore == mtimeAfter
        else {
            throw SourceRevisionIdentityError.sourceChangedDuringRead
        }

        let hex = sha256.finalize()
            .map { String(format: "%02x", $0) }
            .joined()

        return SourceRevisionFingerprint(
            canonicalPath: path,
            sha256: hex
        )
    }
}
