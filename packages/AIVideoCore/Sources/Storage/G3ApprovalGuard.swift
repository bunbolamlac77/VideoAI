import Foundation
import SQLite3
import CoreFoundation
import CryptoKit

/// Fail-closed validation of the cut delivered to S19.
/// Requires committed artifacts, sealed source, verified mapping and real WAV.
enum G3ApprovalGuard {
    private static let maxPlanBytes = 8 * 1024 * 1024
    private static let maxWAVBytes = 128 * 1024 * 1024
    private static let maxFrames = 4_319

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func fileSHA256(_ path: String) throws -> String {
        guard let handle = try? FileHandle(
            forReadingFrom: URL(fileURLWithPath: path)
        ) else {
            throw G3StoreError.blocked(
                "Sealed source snapshot missing"
            )
        }

        defer { try? handle.close() }

        var hasher = SHA256()

        repeat {
            let chunk = try handle.read(
                upToCount: 1024 * 1024
            ) ?? Data()

            if chunk.isEmpty { break }

            hasher.update(data: chunk)
        } while true

        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func text(
        _ object: [String: Any],
        _ key: String
    ) throws -> String {
        guard let value = object[key] as? String,
              !value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw G3StoreError.blocked(
                "G3 cut missing \(key)"
            )
        }
        return value
    }

    private static func int(
        _ object: [String: Any],
        _ key: String
    ) throws -> Int {
        guard let value = object[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw G3StoreError.blocked(
                "G3 cut invalid integer \(key)"
            )
        }

        let raw = value.doubleValue

        guard raw.isFinite,
              raw.rounded(.towardZero) == raw,
              raw >= Double(Int.min),
              raw <= Double(Int.max) else {
            throw G3StoreError.blocked(
                "G3 cut non-integral \(key)"
            )
        }
        return value.intValue
    }

    private static func object(
        _ data: Data
    ) throws -> [String: Any] {
        guard let json = try JSONSerialization
            .jsonObject(with: data) as? [String: Any] else {
            throw G3StoreError.blocked(
                "G3 cut artifact is not JSON object"
            )
        }
        return json
    }

    private static func row(
        _ db: OpaquePointer,
        _ query: String,
        _ args: [String]
    ) throws -> [String]? {
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(
            db, query, -1, &statement, nil
        ) == SQLITE_OK,
        let stmt = statement else {
            throw G3StoreError.database(
                String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }

        for (index, arg) in args.enumerated() {
            let rc = arg.withCString { ptr in
                sqlite3_bind_text(
                    stmt,
                    Int32(index + 1),
                    ptr,
                    -1,
                    unsafeBitCast(
                        -1,
                        to: sqlite3_destructor_type.self
                    )
                )
            }

            guard rc == SQLITE_OK else {
                throw G3StoreError.database("Bind failed")
            }
        }

        switch sqlite3_step(stmt) {
        case SQLITE_DONE:
            return nil

        case SQLITE_ROW:
            return (
                0..<sqlite3_column_count(stmt)
            ).map { index in
                sqlite3_column_text(
                    stmt, index
                ).map {
                    String(cString: $0)
                } ?? ""
            }

        default:
            throw G3StoreError.database(
                String(cString: sqlite3_errmsg(db))
            )
        }
    }

    private static func published(
        _ db: OpaquePointer,
        project: UUID,
        id: String,
        kind: String,
        expectedSHA: String,
        maxBytes: Int
    ) throws -> Data {
        guard UUID(uuidString: id) != nil,
              expectedSHA.count == 64,
              expectedSHA.allSatisfy({
                  $0.isHexDigit
              }) else {
            throw G3StoreError.blocked(
                "Invalid G3 publication ID/SHA"
            )
        }

        guard let artifact = try row(
            db,
            """
            SELECT state, sha256_hash, canonical_path,
                   artifact_type, byte_size
            FROM artifact_publications
            WHERE project_id=? AND publication_id=?
            """,
            [project.uuidString, id]
        ),
        artifact.count == 5,
        artifact[0] == "COMMITTED",
        artifact[1] == expectedSHA,
        artifact[3] == kind,
        let size = Int(artifact[4]),
        size > 0,
        size <= maxBytes else {
            throw G3StoreError.blocked(
                "Missing or uncommitted \(kind) artifact"
            )
        }

        let path = URL(
            fileURLWithPath: artifact[2]
        )

        guard let attrs = try? FileManager.default
            .attributesOfItem(atPath: path.path),
        (attrs[.size] as? NSNumber)?.intValue == size,
        let bytes = try? Data(contentsOf: path),
        bytes.count == size,
        sha(bytes) == expectedSHA else {
            throw G3StoreError.blocked(
                "Tampered or missing \(kind) artifact"
            )
        }

        return bytes
    }

    private static func pcm48kSampleCount(
        _ wav: Data
    ) throws -> Int {
        func isFourCC(
            _ offset: Int,
            _ value: String
        ) -> Bool {
            offset >= 0 &&
            offset + 4 <= wav.count &&
            Data(wav[offset..<(offset + 4)])
                == Data(value.utf8)
        }

        func u16(_ p: Int) -> Int {
            Int(wav[p]) |
            (Int(wav[p + 1]) << 8)
        }

        func u32(_ p: Int) -> Int {
            u16(p) | (u16(p + 2) << 16)
        }

        guard wav.count >= 44,
              isFourCC(0, "RIFF"),
              isFourCC(8, "WAVE") else {
            throw G3StoreError.blocked(
                "Voice is not RIFF/WAVE"
            )
        }

        var position = 12
        var channels = 0
        var blockAlign = 0
        var dataLength: Int?
        var validFormat = false

        while position + 8 <= wav.count {
            let size = u32(position + 4)
            let start = position + 8

            guard size >= 0,
                  size <= wav.count - start else {
                throw G3StoreError.blocked(
                    "Broken WAV chunk length"
                )
            }

            if isFourCC(position, "fmt ") {
                guard size >= 16 else {
                    throw G3StoreError.blocked(
                        "Short WAV format"
                    )
                }

                channels = u16(start + 2)
                blockAlign = u16(start + 12)

                validFormat =
                    u16(start) == 1 &&
                    (channels == 1 || channels == 2) &&
                    u32(start + 4) == 48_000 &&
                    u16(start + 14) == 16 &&
                    blockAlign == channels * 2

            } else if isFourCC(position, "data") {
                dataLength = size
            }

            position = start + size + (size % 2)
        }

        guard validFormat,
              let length = dataLength,
              length > 0,
              blockAlign > 0,
              length % blockAlign == 0 else {
            throw G3StoreError.blocked(
                "WAV must be nonempty PCM16 48kHz"
            )
        }

        return length / blockAlign
    }

    static func verify(
        db: OpaquePointer,
        projectId: UUID,
        scriptRevisionId: String,
        candidate: [String: Any],
        manifest: [String: Any]
    ) throws {
        let scope = try text(
            candidate, "scope_revision_id"
        )

        guard try text(
            manifest, "scope_revision_id"
        ) == scope else {
            throw G3StoreError.blocked(
                "Cut/evidence scope mismatch"
            )
        }

        let publicationId = try text(
            manifest, "cut_publication_id"
        )
        let planSHA = try text(
            manifest, "edit_plan_sha256"
        )

        let planBytes = try published(
            db,
            project: projectId,
            id: publicationId,
            kind: "g3_cut_plan",
            expectedSHA: planSHA,
            maxBytes: maxPlanBytes
        )

        let plan = try object(planBytes)

        guard try text(
            plan, "schema_version"
        ) == "g3-cut-plan-v1",
        try text(
            plan, "script_revision_id"
        ) == scriptRevisionId,
        try text(
            plan, "scope_revision_id"
        ) == scope,
        try text(
            plan, "domain_sha256"
        ) == text(manifest, "domain_sha256"),
        try text(
            plan, "timeline_profile"
        ) == "M-24-SDR-v1",
        let shots = plan["edit_plan"]
            as? [[String: Any]],
        let beats = candidate["beats"]
            as? [[String: Any]],
        shots.count == beats.count,
        !shots.isEmpty,
        shots.count <= 48,
        let voicePubs = manifest[
            "voice_publications"
        ] as? [[String: String]],
        voicePubs.count == beats.count else {
            throw G3StoreError.blocked(
                "Cut artifact does not match selected script"
            )
        }

        var usedIDs = Set<String>()
        var usedSourceRanges: [
            (String, Int, Int)
        ] = []
        var verifiedSourceHashes: [
            String: String
        ] = [:]
        var verifiedMappings: [
            String: [String: Any]
        ] = [:]
        var totalFrames = 0

        for i in shots.indices {
            let shot = shots[i]
            let beat = beats[i]

            let shotID = try text(
                shot, "shot_id"
            )
            let sourceID = try text(
                shot, "source_revision_id"
            )
            let sourceSHA = try text(
                shot, "source_sha256"
            )
            let mappingSHA = try text(
                shot, "mapping_sha256"
            )
            let mappingPubID = try text(
                shot, "mapping_publication_id"
            )

            let start = try int(
                shot, "range_start"
            )
            let end = try int(
                shot, "range_end"
            )
            let duration = try int(
                shot, "duration_frames"
            )
            let overlap = try int(
                shot, "transition_overlap_frames"
            )
            let beatID = try text(
                beat, "beat_id"
            )

            guard let declared = beat[
                "shot_candidate_ids"
            ] as? [String],
            declared.contains(shotID),
            usedIDs.insert(shotID).inserted,
            shot["range_profile"] as? String
                == "M-24-SDR-v1",
            start >= 0,
            end > start,
            duration > 0,
            duration <= end - start,
            overlap >= 0,
            overlap < duration,
            shot["evidence_scope_valid"]
                as? Bool == true,
            shot["claim_use_valid"]
                as? Bool == true,
            shot["crop_preserves_evidence"]
                as? Bool == true else {
                throw G3StoreError.blocked(
                    "Undeclared/unsafe cut at beat \(beatID)"
                )
            }

            if usedSourceRanges.contains(where: {
                $0.0 == sourceID &&
                max($0.1, start) < min($0.2, end)
            }) {
                throw G3StoreError.blocked(
                    "Overlapping sealed source ranges"
                )
            }

            usedSourceRanges.append((
                sourceID, start, end
            ))

            guard let source = try row(
                db,
                """
                SELECT r.snapshot_sha256,
                       r.is_stable, r.snapshot_path,
                       m.content_sha256
                FROM source_revisions r
                JOIN source_media m
                  ON m.media_id=r.media_id
                WHERE r.source_revision_id=?
                  AND m.project_id=?
                """,
                [
                    sourceID,
                    projectId.uuidString
                ]
            ),
            source[0] == sourceSHA,
            source[1] == "1",
            source[3] == sourceSHA,
            FileManager.default.fileExists(
                atPath: source[2]
            ) else {
                throw G3StoreError.blocked(
                    "Source is not sealed in ProjectStore"
                )
            }

            if verifiedSourceHashes[sourceID] == nil {
                verifiedSourceHashes[sourceID] =
                    try fileSHA256(source[2])
            }

            guard verifiedSourceHashes[sourceID]
                    == sourceSHA else {
                throw G3StoreError.blocked(
                    "Sealed source bytes changed on disk"
                )
            }

            let mappingKey =
                mappingPubID + ":" + mappingSHA

            let mapping: [String: Any]

            if let cached =
                verifiedMappings[mappingKey] {
                mapping = cached
            } else {
                let bytes = try published(
                    db,
                    project: projectId,
                    id: mappingPubID,
                    kind: "g2_source_mapping",
                    expectedSHA: mappingSHA,
                    maxBytes: maxPlanBytes
                )

                mapping = try object(bytes)
                verifiedMappings[mappingKey] = mapping
            }

            guard try text(
                mapping, "source_revision_id"
            ) == sourceID,
            try text(
                mapping, "source_sha256"
            ) == sourceSHA,
            let conform = mapping[
                "conform_map"
            ] as? [String: Any],
            conform["profile_id"] as? String
                == "M-24-SDR-v1",
            conform["source_revision_id"]
                as? String == sourceID,
            conform["is_valid_for_evidence"]
                as? Bool == true,
            let dropped = conform[
                "dropped_critical_evidence_frame_ids"
            ] as? [Int],
            dropped.isEmpty,
            let frames = conform[
                "mappings"
            ] as? [[String: Any]],
            frames.count >= end,
            try int(
                conform, "timeline_frame_count"
            ) == frames.count else {
                throw G3StoreError.blocked(
                    "Mapping is not bound to CFR24 source evidence"
                )
            }

            for f in start..<end {
                guard try int(
                    frames[f], "timeline_frame_index"
                ) == f,
                try int(
                    frames[f], "source_frame_id"
                ) >= 0 else {
                    throw G3StoreError.blocked(
                        "Mapping contains missing CFR frames"
                    )
                }
            }

            let voice = voicePubs[i]

            guard voice["beat_id"] == beatID,
                  let wavID = voice[
                      "publication_id"
                  ],
                  let wavSHA = voice["sha256"]
            else {
                throw G3StoreError.blocked(
                    "WAV beat mismatch"
                )
            }

            let wav = try published(
                db,
                project: projectId,
                id: wavID,
                kind: "voice_wav",
                expectedSHA: wavSHA,
                maxBytes: maxWAVBytes
            )

            let samples =
                try pcm48kSampleCount(wav)

            let usable = duration - (
                i == 0 ? 0 : overlap
            )

            guard usable >= (
                samples + 1999
            ) / 2000 else {
                throw G3StoreError.blocked(
                    "Real WAV overruns cut at beat \(beatID)"
                )
            }

            totalFrames += usable

            guard totalFrames <= maxFrames else {
                throw G3StoreError.blocked(
                    "Timeline exceeds M-24-SDR-v1 duration limit"
                )
            }
        }

        guard try int(
            manifest, "total_frames"
        ) == totalFrames else {
            throw G3StoreError.blocked(
                "Claimed timeline frames do not match cut"
            )
        }
    }
}
