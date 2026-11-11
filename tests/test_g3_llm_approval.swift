// tests/test_g3_llm_approval.swift — Regression for audit P0-08 (2026-11-11).
//
// The default G3 script engine is the local LLM (`script_engine = "llm"`), whose prompt
// forbids repeating the claim verbatim. `approveG3Draft` compared the narration to the
// exact claim text (`G3ProjectStore.swift:726-737`), so every LLM-written script was
// rejected at S19 after the user had already paid for the TTS of that very text.
//
// S19 now also accepts a narration that carries complete `llm_local_rewrite` provenance,
// and only if the rewrite cannot have introduced a fact: the hashed text must be exactly
// the approved narration, the source text must be the canonical claim, the digits must be
// a subset of the claim's digits, and the text must be well-formed and 8…320 chars.
//
// The fixture mirrors `test_g3_approval_guard.swift` (sealed source + g2 mapping +
// published g3_cut_plan + published WAV) so each case exercises the real S19 path.
// Every rejection case must stay rejected — a looser fix would let a fabricated script
// through, which is worse than the bug.

import Foundation
import SQLite3
import CryptoKit

@main
struct TestG3LLMApproval {
    static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func json(_ dictionary: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }

    static func wav(sampleFrames: Int) -> Data {
        func u16(_ x: Int) -> [UInt8] { [UInt8(x & 255), UInt8((x >> 8) & 255)] }
        func u32(_ x: Int) -> [UInt8] { (0..<4).map { UInt8((x >> ($0 * 8)) & 255) } }
        let pcm = Data(repeating: 0, count: sampleFrames * 2)
        var result = Data("RIFF".utf8)
        result.append(contentsOf: u32(36 + pcm.count))
        result.append(Data("WAVEfmt ".utf8))
        result.append(contentsOf: u32(16))
        result.append(contentsOf: u16(1))
        result.append(contentsOf: u16(1))
        result.append(contentsOf: u32(48000))
        result.append(contentsOf: u32(96000))
        result.append(contentsOf: u16(2))
        result.append(contentsOf: u16(16))
        result.append(Data("data".utf8))
        result.append(contentsOf: u32(pcm.count))
        result.append(pcm)
        return result
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aivideo_g3llm_\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("project.db")
        let store = try ProjectStore(dbURL: dbURL)
        let project = try await store.createProject(name: "G3-LLM")
        let day = try await store.createWorkday(
            projectId: project.projectId,
            title: "Day",
            date: "2026-11-11"
        )

        let claimText = "Tôi đến địa điểm quay lúc 10 giờ sáng."
        let fact = ClaimRecord(
            workdayId: day.workdayId,
            text: claimText,
            origin: .user,
            epistemicStatus: .reported,
            reviewStatus: .confirmed,
            supportStatus: .supported,
            allowedUse: .attributedOrQualified
        )
        _ = try await store.saveClaim(claim: fact, expectedRevision: project.currentRevision)

        // Sealed source revision (test-only registration; production uses S05 import).
        let sourceId = UUID()
        let mediaId = UUID()
        let sealedPath = root.appendingPathComponent("sealed.mp4")
        let sourceBytes = Data("sealed-video-fixture".utf8)
        try sourceBytes.write(to: sealedPath)
        let sourceSHA = sha(sourceBytes)

        var conn: OpaquePointer?
        guard sqlite3_open(dbURL.path, &conn) == SQLITE_OK, let db = conn else {
            fatalError("test DB")
        }
        let ddl = """
        INSERT INTO source_media(media_id,project_id,original_path,content_sha256,byte_size)
        VALUES ('\(mediaId.uuidString)','\(project.projectId.uuidString)','fixture','\(sourceSHA)',\(sourceBytes.count));
        INSERT INTO source_revisions(source_revision_id,media_id,snapshot_path,snapshot_sha256,is_stable)
        VALUES ('\(sourceId.uuidString)','\(mediaId.uuidString)','\(sealedPath.path)','\(sourceSHA)',1);
        """
        assert(sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let publisher = try ArtifactPublicationService(workspaceRoot: root)

        func publish(kind: String, bytes: Data) async throws -> ArtifactPublicationRecord {
            let job = try await store.enqueueJob(
                projectId: project.projectId,
                jobType: "test-\(kind)",
                inputFingerprint: UUID().uuidString
            )
            let attempt = try await store.allocateAttempt(jobId: job.jobId, workerSessionId: "g3-llm")
            return try await publisher.publishArtifact(
                store: store,
                projectId: project.projectId,
                jobId: job.jobId,
                attemptId: attempt.attemptId,
                fencingToken: attempt.fencingToken,
                artifactType: kind,
                filename: "artifact.bin",
                content: bytes
            )
        }

        let frameMappings = (0..<48).map { ["timeline_frame_index": $0, "source_frame_id": $0] }
        let mapping: [String: Any] = [
            "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA,
            "conform_map": [
                "profile_id": "M-24-SDR-v1",
                "source_revision_id": sourceId.uuidString,
                "timeline_frame_count": 48,
                "is_valid_for_evidence": true,
                "dropped_critical_evidence_frame_ids": [],
                "mappings": frameMappings
            ] as [String: Any]
        ]
        let mappingPub = try await publish(kind: "g2_source_mapping", bytes: json(mapping))
        let voicePub = try await publish(kind: "voice_wav", bytes: wav(sampleFrames: 4800))

        let scope = "scope-llm"
        let domain = String(repeating: "d", count: 64)
        let modelDigest = String(repeating: "1", count: 64)
        let promptDigest = String(repeating: "2", count: 64)

        // What the local LLM writes: re-worded, no invented numbers, no verbatim echo.
        let llmNarration = "Buổi sáng, người quay đã có mặt ở nơi ghi hình từ lúc 10 giờ."

        func revisionId(_ n: Int) -> String {
            String(repeating: "d", count: 56) + String(format: "%08d", n)
        }

        func beat(_ narration: String, provenance: Bool) -> [String: Any] {
            var b: [String: Any] = [
                "beat_id": "beat-01",
                "voice_text": narration,
                "shot_candidate_ids": ["shot-A"],
                "claim_refs": [[
                    "revision_id": fact.revisionId.uuidString,
                    "allowed_use": "attributed_or_qualified"
                ]]
            ]
            if provenance {
                b["voice_text_origin"] = "llm_local_rewrite"
                b["voice_text_source_text"] = claimText
                b["voice_text_sha256"] = sha(Data(narration.utf8))
                b["voice_raw_output_sha256"] = modelDigest
                b["voice_prompt_sha256"] = promptDigest
                b["voice_model_id"] = "mlx-community/Qwen3-8B-4bit"
            }
            return b
        }

        let shot: [String: Any] = [
            "shot_id": "shot-A",
            "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA,
            "mapping_sha256": mappingPub.sha256Hash!,
            "mapping_publication_id": mappingPub.publicationId.uuidString,
            "range_start": 0,
            "range_end": 48,
            "duration_frames": 48,
            "transition_overlap_frames": 0,
            "range_profile": "M-24-SDR-v1",
            "evidence_scope_valid": true,
            "claim_use_valid": true,
            "crop_preserves_evidence": true
        ]

        let cut: [String: Any] = [
            "schema_version": "g3-cut-plan-v1",
            "script_revision_id": revisionId(1),
            "scope_revision_id": scope,
            "domain_sha256": domain,
            "timeline_profile": "M-24-SDR-v1",
            "edit_plan": [shot]
        ]
        let cutPub = try await publish(kind: "g3_cut_plan", bytes: json(cut))

        await store.close()

        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }

        // Each case uses its own script revision (the revision id is the script's identity).
        func attemptApproval(caseNumber: Int, beatValue: [String: Any], narration: String) async -> Bool {
            let store = try! ProjectStore(dbURL: dbURL)
            defer { Task { await store.close() } }
            let rev = revisionId(caseNumber)
            do {
                var scopedCut = cut
                scopedCut["script_revision_id"] = rev
                _ = scopedCut
                let record = try await store.storeG3Draft(
                    projectId: project.projectId,
                    workdayId: day.workdayId,
                    candidateJSON: String(
                        decoding: try json([
                            "script_revision_id": rev,
                            "scope_revision_id": scope,
                            "status": "DRAFT_NOT_BUILDABLE",
                            "claim_revision_ids": [fact.revisionId.uuidString],
                            "beats": [beatValue]
                        ]),
                        as: UTF8.self
                    )
                )
                try await store.selectG3Draft(projectId: project.projectId, scriptRevisionId: rev)
                try await store.recordG3SpeechReview(
                    projectId: project.projectId,
                    scriptRevisionId: rev,
                    beatId: "beat-01",
                    publicationId: voicePub.publicationId,
                    expectedSHA256: voicePub.sha256Hash!,
                    reviewer: "Manual test"
                )
                let manifest: [String: Any] = [
                    "schema_version": "g3-approval-proposal-v1",
                    "script_revision_id": rev,
                    "scope_revision_id": scope,
                    "claim_revision_ids": [fact.revisionId.uuidString],
                    "domain_sha256": domain,
                    "edit_plan_sha256": cutPub.sha256Hash!,
                    "cut_publication_id": cutPub.publicationId.uuidString,
                    "timeline_profile": "M-24-SDR-v1",
                    "total_frames": 48,
                    "voice_publications": [[
                        "beat_id": "beat-01",
                        "text_sha256": sha(Data(narration.utf8)),
                        "publication_id": voicePub.publicationId.uuidString,
                        "sha256": voicePub.sha256Hash!
                    ]]
                ]
                _ = try await store.approveG3Draft(
                    projectId: project.projectId,
                    workdayId: day.workdayId,
                    scriptRevisionId: rev,
                    expectedCandidateSHA256: record.candidateSHA256,
                    manifestJSON: String(decoding: try json(manifest), as: UTF8.self),
                    approvedBy: "Human tester"
                )
                return true
            } catch {
                print("  refused (\(caseNumber)): \(error)")
                return false
            }
        }

        // 1) The core bug: a fully provenanced LLM rewrite must now be approvable.
        check(
            await attemptApproval(caseNumber: 1, beatValue: beat(llmNarration, provenance: true), narration: llmNarration),
            "a provenanced LLM rewrite must pass S19 (P0-08)"
        )
        // 2) Rewrite without provenance stays blocked.
        check(
            !(await attemptApproval(caseNumber: 2, beatValue: beat(llmNarration, provenance: false), narration: llmNarration)),
            "an unprovenanced rewrite must still be blocked"
        )
        // 3) A hash that does not match the approved narration stays blocked.
        var tampered = beat(llmNarration, provenance: true)
        tampered["voice_text_sha256"] = sha(Data("Một câu khác hoàn toàn.".utf8))
        check(
            !(await attemptApproval(caseNumber: 3, beatValue: tampered, narration: llmNarration)),
            "a mismatched narration hash must be blocked"
        )
        // 4) Inventing a number stays blocked.
        let invented = "Người quay đã có mặt ở nơi ghi hình lúc 18 giờ chiều."
        check(
            !(await attemptApproval(caseNumber: 4, beatValue: beat(invented, provenance: true), narration: invented)),
            "an invented number must be blocked"
        )
        // 5) A source text that is not the cited canonical claim stays blocked.
        var wrongSource = beat(llmNarration, provenance: true)
        wrongSource["voice_text_source_text"] = "Một claim khác hoàn toàn không tồn tại."
        check(
            !(await attemptApproval(caseNumber: 5, beatValue: wrongSource, narration: llmNarration)),
            "a forged source text must be blocked"
        )

        if failures > 0 {
            print("G3 LLM APPROVAL TESTS FAILED (\(failures))")
            exit(1)
        }
        print("G3 LLM APPROVAL TESTS PASSED (5/5)")
    }
}
