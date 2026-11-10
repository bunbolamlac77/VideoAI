// Streaming S08 publication for large G4 MP4 files; never loads full video into RAM.
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

extension ArtifactPublicationService {
    public func publishG4File(
        store: ProjectStore,
        projectId: UUID,
        source: URL,
        artifactType: String,
        expectedSHA256: String
    ) async throws -> ArtifactPublicationRecord {
        guard ["g4_captioned_cfr", "g4_conform_receipt", "g4_preview_mp4"].contains(artifactType),
              expectedSHA256.count == 64, expectedSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw G3StoreError.invalidPayload("G4 publication kind/hash is invalid")
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw G3StoreError.blocked("Application Support directory is unavailable")
        }
        let managedRoot = support.appendingPathComponent(
            "AIVideo/G4", isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalSource.isFileURL,
              canonicalSource.path.hasPrefix(managedRoot.path + "/"),
              FileManager.default.fileExists(atPath: canonicalSource.path) else {
            throw G3StoreError.blocked(
                "G4 publication source is outside app-owned staging/render directory"
            )
        }
        let job = try await store.enqueueJob(
            projectId: projectId,
            jobType: "publish_\(artifactType)",
            inputFingerprint: expectedSHA256
        )
        let attempt = try await store.allocateAttempt(
            jobId: job.jobId,
            workerSessionId: "g4-publisher-\(UUID().uuidString)"
        )
        let publicationId = UUID()
        let temp = try attemptTempFileURL(attemptId: attempt.attemptId, filename: "g4-staged.bin")
        _ = try await store.createPublicationIntent(
            publicationId: publicationId,
            projectId: projectId,
            jobId: job.jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            artifactType: artifactType,
            tempPath: temp.path
        )
        let input = try FileHandle(forReadingFrom: canonicalSource)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            try? input.close()
            throw G3StoreError.blocked("Cannot create G4 publication temp")
        }
        let output = try FileHandle(forWritingTo: temp)
        var hash = SHA256()
        var count: Int64 = 0
        do {
            while true {
                let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                count += Int64(data.count)
                guard count <= 4 * 1024 * 1024 * 1024 else {
                    throw G3StoreError.blocked("G4 publication exceeds 4GB limit")
                }
                hash.update(data: data)
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try output.close()
            try input.close()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count > 0 && actual == expectedSHA256 else {
            throw G3StoreError.blocked("Staged G4 file changed during streaming publication")
        }
        _ = try await store.updatePublicationMaterialized(
            publicationId: publicationId,
            jobId: job.jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            tempPath: temp.path
        )
        _ = try await store.updatePublicationVerified(
            publicationId: publicationId,
            jobId: job.jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            sha256: actual,
            byteSize: Int(count)
        )
        let target = canonicalBlobURL(forSHA256: actual)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: target.path) {
            let existing = try FileHandle(forReadingFrom: target)
            var existingHash = SHA256()
            do {
                while true {
                    let bytes = try existing.read(upToCount: 1024 * 1024) ?? Data()
                    if bytes.isEmpty { break }
                    existingHash.update(data: bytes)
                }
                try existing.close()
            } catch {
                try? existing.close()
                throw error
            }
            let known = existingHash.finalize().map { String(format: "%02x", $0) }.joined()
            guard known == actual else {
                throw G3StoreError.blocked("Existing S08 blob is corrupted")
            }
            try FileManager.default.removeItem(at: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444], ofItemAtPath: target.path
            )
        }
        #if canImport(Darwin)
        // Mirror S08's durable file + directory flush after rename.
        let blobFd = open(target.path, O_RDONLY)
        if blobFd >= 0 {
            _ = fcntl(blobFd, F_FULLFSYNC)
            close(blobFd)
        }
        let parentFd = open(target.deletingLastPathComponent().path, O_RDONLY)
        if parentFd >= 0 {
            _ = fsync(parentFd)
            close(parentFd)
        }
        #endif
        // The source is never deleted. A crash after rename is handled by S08 startup reconciliation.
        return try await store.commitPublication(
            publicationId: publicationId,
            jobId: job.jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            canonicalPath: target.path,
            completeJob: true
        )
    }
}
