import Foundation
import SQLite3
import CryptoKit

@main
struct TestG3ApprovalGuard {
    static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func json(
        _ dictionary: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys]
        )
    }

    static func wav(sampleFrames: Int) -> Data {
        func u16(_ x: Int) -> [UInt8] {
            [
                UInt8(x & 255),
                UInt8((x >> 8) & 255),
            ]
        }

        func u32(_ x: Int) -> [UInt8] {
            (0..<4).map {
                UInt8((x >> ($0 * 8)) & 255)
            }
        }

        let pcm = Data(
            repeating: 0,
            count: sampleFrames * 2
        )

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
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "g3_guard_\(UUID())"
            )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        let dbURL = root.appendingPathComponent(
            "project.db"
        )
        let store = try ProjectStore(
            dbURL: dbURL
        )

        let project = try await store.createProject(
            name: "Secure G3"
        )

        let day = try await store.createWorkday(
            projectId: project.projectId,
            title: "Day",
            date: "2026-11-09"
        )

        let fact = ClaimRecord(
            workdayId: day.workdayId,
            text: "Tôi đi đến nơi quay.",
            origin: .user,
            epistemicStatus: .reported,
            reviewStatus: .confirmed,
            supportStatus: .supported,
            allowedUse: .attributedOrQualified
        )

        _ = try await store.saveClaim(
            claim: fact,
            expectedRevision: project.currentRevision
        )

        let voiceText = (
            "Theo thông tin đã được người quay xác nhận: "
            + fact.text
        )

        let sourceId = UUID()
        let mediaId = UUID()

        let sealedPath = root.appendingPathComponent(
            "sealed.mp4"
        )

        let sourceBytes = Data(
            "sealed-video-fixture".utf8
        )
        try sourceBytes.write(to: sealedPath)
        let sourceSHA = sha(sourceBytes)

        // Test-only source registration. Production uses
        // canonical S05/ProjectStore import.
        var conn: OpaquePointer?

        guard sqlite3_open(
            dbURL.path,
            &conn
        ) == SQLITE_OK,
        let db = conn else {
            fatalError("test DB")
        }

        let ddl = """
        INSERT INTO source_media(
            media_id,project_id,original_path,
            content_sha256,byte_size
        ) VALUES (
            '\(mediaId.uuidString)',
            '\(project.projectId.uuidString)',
            'fixture',
            '\(sourceSHA)',
            \(sourceBytes.count)
        );

        INSERT INTO source_revisions(
            source_revision_id,media_id,snapshot_path,
            snapshot_sha256,is_stable
        ) VALUES (
            '\(sourceId.uuidString)',
            '\(mediaId.uuidString)',
            '\(sealedPath.path)',
            '\(sourceSHA)',
            1
        );
        """

        assert(
            sqlite3_exec(
                db, ddl, nil, nil, nil
            ) == SQLITE_OK
        )
        sqlite3_close(db)

        let publisher = try ArtifactPublicationService(
            workspaceRoot: root
        )

        func publish(
            kind: String,
            bytes: Data
        ) async throws -> ArtifactPublicationRecord {
            let job = try await store.enqueueJob(
                projectId: project.projectId,
                jobType: "test-\(kind)",
                inputFingerprint: UUID().uuidString
            )

            let attempt = try await store.allocateAttempt(
                jobId: job.jobId,
                workerSessionId: "g3-guard-test"
            )

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

        let frameMappings = (0..<48).map {
            [
                "timeline_frame_index": $0,
                "source_frame_id": $0,
            ]
        }

        let mapping: [String: Any] = [
            "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA,
            "conform_map": [
                "profile_id": "M-24-SDR-v1",
                "source_revision_id": sourceId.uuidString,
                "timeline_frame_count": 48,
                "is_valid_for_evidence": true,
                "dropped_critical_evidence_frame_ids": [],
                "mappings": frameMappings,
            ] as [String: Any],
        ]

        let mappingPub = try await publish(
            kind: "g2_source_mapping",
            bytes: json(mapping)
        )

        let voicePub = try await publish(
            kind: "voice_wav",
            bytes: wav(sampleFrames: 4800)
        )

        let revision = String(
            repeating: "a",
            count: 64
        )

        let candidate: [String: Any] = [
            "script_revision_id": revision,
            "scope_revision_id": "scope-1",
            "status": "DRAFT_NOT_BUILDABLE",
            "claim_revision_ids": [
                fact.revisionId.uuidString
            ],
            "beats": [[
                "beat_id": "beat-01",
                "voice_text": voiceText,
                "shot_candidate_ids": ["shot-A"],
                "claim_refs": [[
                    "revision_id": (
                        fact.revisionId.uuidString
                    ),
                    "allowed_use": (
                        "attributed_or_qualified"
                    ),
                ]],
            ]],
        ]

        let stored = try await store.storeG3Draft(
            projectId: project.projectId,
            workdayId: day.workdayId,
            candidateJSON: String(
                decoding: try json(candidate),
                as: UTF8.self
            )
        )

        try await store.selectG3Draft(
            projectId: project.projectId,
            scriptRevisionId: revision
        )

        try await store.recordG3SpeechReview(
            projectId: project.projectId,
            scriptRevisionId: revision,
            beatId: "beat-01",
            publicationId: voicePub.publicationId,
            expectedSHA256: voicePub.sha256Hash!,
            reviewer: "Manual test"
        )

        let domain = String(
            repeating: "d",
            count: 64
        )

        let shot: [String: Any] = [
            "shot_id": "shot-A",
            "source_revision_id": sourceId.uuidString,
            "source_sha256": sourceSHA,
            "mapping_sha256": mappingPub.sha256Hash!,
            "mapping_publication_id": (
                mappingPub.publicationId.uuidString
            ),
            "range_start": 0,
            "range_end": 48,
            "duration_frames": 48,
            "transition_overlap_frames": 0,
            "range_profile": "M-24-SDR-v1",
            "evidence_scope_valid": true,
            "claim_use_valid": true,
            "crop_preserves_evidence": true,
        ]

        let cut: [String: Any] = [
            "schema_version": "g3-cut-plan-v1",
            "script_revision_id": revision,
            "scope_revision_id": "scope-1",
            "domain_sha256": domain,
            "timeline_profile": "M-24-SDR-v1",
            "edit_plan": [shot],
        ]

        let cutPub = try await publish(
            kind: "g3_cut_plan",
            bytes: json(cut)
        )

        let manifest: [String: Any] = [
            "schema_version": "g3-approval-proposal-v1",
            "script_revision_id": revision,
            "scope_revision_id": "scope-1",
            "claim_revision_ids": [
                fact.revisionId.uuidString
            ],
            "domain_sha256": domain,
            "edit_plan_sha256": cutPub.sha256Hash!,
            "cut_publication_id": (
                cutPub.publicationId.uuidString
            ),
            "timeline_profile": "M-24-SDR-v1",
            "total_frames": 48,
            "voice_publications": [[
                "beat_id": "beat-01",
                "text_sha256": sha(
                    Data(voiceText.utf8)
                ),
                "publication_id": (
                    voicePub.publicationId.uuidString
                ),
                "sha256": voicePub.sha256Hash!,
            ]],
        ]

        let manifestJSON = String(
            decoding: try json(manifest),
            as: UTF8.self
        )

        let approval = try await store.approveG3Draft(
            projectId: project.projectId,
            workdayId: day.workdayId,
            scriptRevisionId: revision,
            expectedCandidateSHA256: (
                stored.candidateSHA256
            ),
            manifestJSON: manifestJSON,
            approvedBy: "Human tester"
        )

        assert(
            approval.scriptRevisionId == revision
        )

        let active = try await store.currentG3Approval(
            projectId: project.projectId
        )

        assert(active != nil)
        print(
            "PASS G3.GUARD.1: sealed source + mapping + WAV + cut approved"
        )

        try Data("tampered".utf8).write(
            to: sealedPath,
            options: .atomic
        )

        let revoked = try await store.currentG3Approval(
            projectId: project.projectId
        )

        assert(revoked == nil)
        print(
            "PASS G3.GUARD.2: source tampering invalidates approval"
        )

        await store.close()

        if let outPath = ProcessInfo.processInfo.environment["TEST_RECORDS_OUT"], !outPath.isEmpty {
            let records: [[String: Any]] = [
                ["testcase_id": "G3.GUARD.1", "requirement_id": "INV-03/EDIT-01", "status": "PASS",
                 "expected": "Sealed source + mapping + WAV + cut approved by G3ApprovalGuard", "observed": "PASS G3.GUARD.1: sealed source + mapping + WAV + cut approved", "exit_status": 0],
                ["testcase_id": "G3.GUARD.2", "requirement_id": "INV-05/DATA-01", "status": "PASS",
                 "expected": "Sealed source tampering invalidates G3 approval", "observed": "PASS G3.GUARD.2: source tampering invalidates approval", "exit_status": 0]
            ]
            let url = URL(fileURLWithPath: outPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = ""
            for rec in records {
                if let d = try? JSONSerialization.data(withJSONObject: rec),
                   let s = String(data: d, encoding: .utf8) { lines += s + "\n" }
            }
            try lines.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
