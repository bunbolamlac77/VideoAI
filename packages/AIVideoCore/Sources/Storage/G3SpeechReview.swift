//
// G3SpeechReview.swift — S19 speech review kept with the script it reviewed.
//
// (P2-01) Split out of G3ProjectStore.swift, which mixed draft selection, speech review,
// approval and read-back in one 1.1k-line file. Behaviour is unchanged: same actor, same
// canonical connection, same SQL.
//

import Foundation
import SQLite3
import CryptoKit

extension ProjectStore {

    public func recordG3SpeechReview(
        projectId: UUID,
        scriptRevisionId: String,
        beatId: String,
        publicationId: UUID,
        expectedSHA256: String,
        reviewer: String
    ) throws {
        guard !reviewer.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw G3StoreError.invalidPayload(
                "Human reviewer is required"
            )
        }

        try withG3Transaction { db in
            guard let script = try G3SQL.row(
                db,
                """
                SELECT project_id,candidate_json
                FROM g3_scripts
                WHERE script_revision_id=?
                """,
                [scriptRevisionId]
            ),
            script[0].lowercased()
                == projectId.uuidString.lowercased()
            else {
                throw G3StoreError.blocked(
                    "Unknown script revision"
                )
            }

            let candidate = try G3SQL.dictionary(
                script[1]
            )
            guard let beats = candidate[
                "beats"
            ] as? [[String: Any]],
            let beat = beats.first(where: {
                $0["beat_id"] as? String == beatId
            }),
            let text = beat["voice_text"]
                as? String else {
                throw G3StoreError.blocked(
                    "Unknown beat or voice text"
                )
            }

            let textSHA256 = G3SQL.sha256(
                Data(text.utf8)
            )

            guard let publication = try G3SQL.row(
                db,
                """
                SELECT state,sha256_hash,canonical_path,artifact_type
                FROM artifact_publications
                WHERE project_id=? AND publication_id=?
                """,
                [
                    projectId.uuidString,
                    publicationId.uuidString,
                ]
            ),
            publication[0] == "COMMITTED",
            publication[1] == expectedSHA256,
            publication[3] == "voice_wav"
            else {
                throw G3StoreError.blocked(
                    "WAV artifact not committed or mismatched"
                )
            }

            let file = URL(
                fileURLWithPath: publication[2]
            )

            guard let bytes = try? Data(
                contentsOf: file
            ),
            G3SQL.sha256(bytes) == expectedSHA256,
            bytes.count >= 44,
            String(
                data: bytes.prefix(4),
                encoding: .ascii
            ) == "RIFF",
            String(
                data: bytes[8..<12],
                encoding: .ascii
            ) == "WAVE"
            else {
                throw G3StoreError.blocked(
                    "WAV missing, tampered or not a RIFF/WAVE file"
                )
            }

            try G3SQL.run(
                db,
                """
                INSERT INTO g3_voice_reviews(
                    script_revision_id,
                    beat_id,
                    publication_id,
                    wav_sha256,
                    text_sha256,
                    reviewed_by
                ) VALUES(?,?,?,?,?,?)
                ON CONFLICT(script_revision_id,beat_id)
                DO UPDATE SET
                    publication_id=excluded.publication_id,
                    wav_sha256=excluded.wav_sha256,
                    text_sha256=excluded.text_sha256,
                    reviewed_by=excluded.reviewed_by,
                    reviewed_at=strftime(
                        '%Y-%m-%dT%H:%M:%SZ','now'
                    )
                """,
                [
                    scriptRevisionId,
                    beatId,
                    publicationId.uuidString,
                    expectedSHA256,
                    textSHA256,
                    reviewer,
                ]
            )
        }
    }

    /// (P0-08) Accept an LLM-rewritten narration only with complete, checkable provenance.
    func beatIsProvenancedLLMRewrite(
        _ beat: [String: Any],
        narration: String,
        claimText: String,
        scriptRevisions: [String]
    ) throws -> Bool {
        guard let origin = beat["voice_text_origin"] as? String,
              origin == "llm_local_rewrite"
        else { return false }

        // Only user-visible wording may be rewritten; observed facts must stay verbatim.
        guard !claimText.isEmpty else { return false }

        let hashes = ["voice_text_sha256", "voice_raw_output_sha256", "voice_prompt_sha256"]
        for key in hashes {
            guard let value = beat[key] as? String,
                  value.count == 64,
                  value.allSatisfy({ $0.isHexDigit })
            else { return false }
        }
        guard let modelID = beat["voice_model_id"] as? String, !modelID.isEmpty,
              let sourceText = beat["voice_text_source_text"] as? String,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        // The narration the user approves must be exactly the text that was hashed.
        let narrationHash = G3SQL.sha256(Data(narration.utf8))
        guard beat["voice_text_sha256"] as? String == narrationHash else { return false }

        // The rewrite may re-phrase but never add numbers the claim did not contain.
        let claimDigits = Set(claimText.split(whereSeparator: { !$0.isNumber }).map(String.init))
        let narrationDigits = Set(narration.split(whereSeparator: { !$0.isNumber }).map(String.init))
        guard narrationDigits.isSubset(of: claimDigits) else { return false }
        guard !narration.contains("\u{FFFD}") else { return false }
        guard (8...320).contains(narration.count) else { return false }

        // The source text must be the canonical claim text this beat cites.
        guard sourceText == claimText else { return false }
        return true
    }

    func checkG3ClaimRevisions(
        _ db: OpaquePointer,
        _ revisions: [String],
        workdayId: UUID
    ) throws {
        guard
            !revisions.isEmpty,
            revisions.count == Set(revisions).count
        else {
            throw G3StoreError.blocked(
                "No valid/unique claim revision set"
            )
        }

        for rev in revisions {
            guard let claim = try G3SQL.row(
                db,
                """
                SELECT
                    claim_id,origin,review_status,
                    support_status,allowed_use
                FROM claims
                WHERE revision_id=? AND workday_id=?
                """,
                [
                    rev,
                    workdayId.uuidString,
                ]
            ) else {
                throw G3StoreError.conflict(
                    "Claim revision missing: \(rev)"
                )
            }

            guard let latest = try G3SQL.row(
                db,
                """
                SELECT revision_id FROM claims
                WHERE claim_id=?
                ORDER BY rowid DESC LIMIT 1
                """,
                [claim[0]]
            ),
            latest[0] == rev else {
                throw G3StoreError.conflict(
                    "Claim was modified after candidate creation: \(claim[0])"
                )
            }

            guard
                claim[3] == "supported",
                [
                    "direct_claim",
                    "attributed_or_qualified",
                ].contains(claim[4]),
                ![
                    "rejected",
                    "superseded",
                    "needs_review",
                    "unreviewed",
                ].contains(claim[2]),
                claim[1] != "user"
                    || (claim[2] == "confirmed" && claim[4] == "attributed_or_qualified")
            else {
                throw G3StoreError.blocked(
                    "Claim not eligible for narration: \(claim[0])"
                )
            }
        }
    }
}
