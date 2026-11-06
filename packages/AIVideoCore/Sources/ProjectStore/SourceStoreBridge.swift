import Foundation

/// S05 -> S06 boundary.
/// Separate prepare and commit for safe retries.
public enum SourceStoreBridge {
    public static func prepare(
        projectID: UUID,
        mediaID: UUID,
        sourceURL: URL,
        projectRoot: URL,
        bookmarkData: Data? = nil
    ) async throws -> PreparedSourceRecord {
        try await Task.detached(
            priority: .utility
        ) {
            let result = try SourceAcquisition.acquire(
                sourceURL: sourceURL,
                mediaId: mediaID,
                projectRoot: projectRoot,
                bookmarkData: bookmarkData
            )

            _ = try AuthoritativeSourceReader.verifySnapshot(
                ref: result.sealedRef,
                projectRoot: projectRoot
            )

            return PreparedSourceRecord(
                mediaID: mediaID,
                sourceRevisionID: result.revision.sourceRevisionId,
                projectID: projectID,
                originalPath: sourceURL.path,
                snapshotPath: result.revision.snapshotRelativePath,
                sha256: result.revision.contentSha256,
                byteSize: result.revision.byteSize
            )
        }.value
    }

    /// Retry with the SAME prepared source and operationID.
    public static func commit(
        _ prepared: PreparedSourceRecord,
        to store: ProjectStore,
        expectedProjectRevision: Int,
        operationID: String
    ) async throws -> StoreReceipt {
        try await store.registerPreparedSource(
            prepared,
            expectedProjectRevision: expectedProjectRevision,
            operationID: operationID
        )
    }
}
