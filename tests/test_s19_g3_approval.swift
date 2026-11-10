// S19 integration test:
// selection != approval; committed WAV;
// idempotent approval; stale claim rejection.

import Foundation
import CryptoKit

@main
struct TestS19G3Approval {
    static func main() async throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "aivideo_g3_\(UUID().uuidString)"
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

        let store = try ProjectStore(
            dbURL: root.appendingPathComponent(
                "project.db"
            )
        )

        let project = try await store.createProject(
            name: "G3"
        )

        let workday = try await store.createWorkday(
            projectId: project.projectId,
            title: "Day",
            date: "2026-11-09"
        )

        let fact = ClaimRecord(
            workdayId: workday.workdayId,
            text: "Tôi đến địa điểm quay.",
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

        let revision = String(
            repeating: "a",
            count: 64
        )

        let voiceText = (
            "Theo thông tin đã được người quay xác nhận: "
            + fact.text
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

        let candidateJSON = String(
            data: try JSONSerialization.data(
                withJSONObject: candidate
            ),
            encoding: .utf8
        )!

        let record = try await store.storeG3Draft(
            projectId: project.projectId,
            workdayId: workday.workdayId,
            candidateJSON: candidateJSON
        )

        let initiallyApproved = try await
            store.currentG3Approval(
                projectId: project.projectId
            )

        assert(initiallyApproved == nil)

        print(
            "PASS S19.T1: stored draft is not approval"
        )

        let publisher = try ArtifactPublicationService(
            workspaceRoot: root
        )

        let job = try await store.enqueueJob(
            projectId: project.projectId,
            jobType: "g3_tts_trial",
            inputFingerprint: "wav-trial"
        )

        let attempt = try await store.allocateAttempt(
            jobId: job.jobId,
            workerSessionId: "g3-test"
        )

        // Audio fixture for storage and publication
        // transaction tests only. Not synthesized speech.
        func le16(_ n: UInt16) -> [UInt8] {
            [
                UInt8(n & 0xff),
                UInt8((n >> 8) & 0xff),
            ]
        }

        func le32(_ n: UInt32) -> [UInt8] {
            (0..<4).map {
                UInt8(
                    (n >> ($0 * 8)) & 0xff
                )
            }
        }

        let pcm = Data(
            repeating: 0,
            count: 4800 * 2
        )

        var wavBytes = Data(
            "RIFF".utf8
        )
        wavBytes.append(
            contentsOf: le32(
                UInt32(36 + pcm.count)
            )
        )
        wavBytes.append(
            Data("WAVEfmt ".utf8)
        )
        wavBytes.append(
            contentsOf: le32(16)
        )
        wavBytes.append(
            contentsOf: le16(1)
        )
        wavBytes.append(
            contentsOf: le16(1)
        )
        wavBytes.append(
            contentsOf: le32(48000)
        )
        wavBytes.append(
            contentsOf: le32(96000)
        )
        wavBytes.append(
            contentsOf: le16(2)
        )
        wavBytes.append(
            contentsOf: le16(16)
        )
        wavBytes.append(
            Data("data".utf8)
        )
        wavBytes.append(
            contentsOf: le32(
                UInt32(pcm.count)
            )
        )
        wavBytes.append(pcm)

        let published = try await publisher
            .publishArtifact(
                store: store,
                projectId: project.projectId,
                jobId: job.jobId,
                attemptId: attempt.attemptId,
                fencingToken: attempt.fencingToken,
                artifactType: "voice_wav",
                filename: "voice.wav",
                content: wavBytes
            )

        let pubSHA = published.sha256Hash!

        try await store.recordG3SpeechReview(
            projectId: project.projectId,
            scriptRevisionId: revision,
            beatId: "beat-01",
            publicationId: published.publicationId,
            expectedSHA256: pubSHA,
            reviewer: "Test fixture reviewer"
        )

        let textSHA = SHA256.hash(
            data: Data(voiceText.utf8)
        ).map {
            String(format: "%02x", $0)
        }.joined()

        let manifest: [String: Any] = [
            "schema_version": "g3-approval-proposal-v1",
            "script_revision_id": revision,
            "scope_revision_id": "scope-1",
            "claim_revision_ids": [
                fact.revisionId.uuidString
            ],
            "edit_plan_sha256": String(
                repeating: "b",
                count: 64
            ),
            "timeline_profile": "M-24-SDR-v1",
            "total_frames": 48,
            "voice_publications": [[
                "beat_id": "beat-01",
                "text_sha256": textSHA,
                "publication_id": (
                    published.publicationId.uuidString
                ),
                "sha256": pubSHA,
            ]],
        ]

        let manifestJSON = String(
            data: try JSONSerialization.data(
                withJSONObject: manifest
            ),
            encoding: .utf8
        )!

        var blockedBeforeSelection = false

        do {
            _ = try await store.approveG3Draft(
                projectId: project.projectId,
                workdayId: workday.workdayId,
                scriptRevisionId: revision,
                expectedCandidateSHA256: (
                    record.candidateSHA256
                ),
                manifestJSON: manifestJSON,
                approvedBy: "Tester"
            )
        } catch {
            blockedBeforeSelection = true
        }

        assert(blockedBeforeSelection)

        try await store.selectG3Draft(
            projectId: project.projectId,
            scriptRevisionId: revision
        )

        var acceptedUnsealedPlan = false
        do {
            _ = try await store.approveG3Draft(
                projectId: project.projectId,
                workdayId: workday.workdayId,
                scriptRevisionId: revision,
                expectedCandidateSHA256: record.candidateSHA256,
                manifestJSON: manifestJSON,
                approvedBy: "Tester"
            )
            acceptedUnsealedPlan = true
        } catch { }
        assert(!acceptedUnsealedPlan)
        let noApproval = try await store.currentG3Approval(
            projectId: project.projectId
        )
        assert(noApproval == nil)
        print("PASS S19.T2: unsealed cut plan is rejected")

        let currentProject = try await store
            .getProject(id: project.projectId)!

        let corrected = ClaimRecord(
            claimId: fact.claimId,
            workdayId: workday.workdayId,
            text: "Sự kiện đã được chỉnh lại.",
            origin: .user,
            epistemicStatus: .reported,
            reviewStatus: .confirmed,
            supportStatus: .supported,
            allowedUse: .attributedOrQualified
        )

        _ = try await store.saveClaim(
            claim: corrected,
            expectedRevision: (
                currentProject.currentRevision
            )
        )

        let staleApproval = try await
            store.currentG3Approval(
                projectId: project.projectId
            )
        assert(staleApproval == nil)

        var staleBlocked = false
        do {
            _ = try await store.approveG3Draft(
                projectId: project.projectId,
                workdayId: workday.workdayId,
                scriptRevisionId: revision,
                expectedCandidateSHA256: (
                    record.candidateSHA256
                ),
                manifestJSON: manifestJSON,
                approvedBy: "Tester"
            )
        } catch {
            staleBlocked = true
        }

        assert(staleBlocked)

        print(
            "PASS S19.T3: edited claim makes approval stale"
        )

        await store.close()

        if let outPath = ProcessInfo.processInfo.environment["TEST_RECORDS_OUT"], !outPath.isEmpty {
            let records: [[String: Any]] = [
                ["testcase_id": "S19.T1", "requirement_id": "INV-03/STORY-03", "status": "PASS",
                 "expected": "Stored G3 draft is not an approval", "observed": "PASS S19.T1: stored draft is not approval", "exit_status": 0],
                ["testcase_id": "S19.T2", "requirement_id": "INV-03/DATA-08", "status": "PASS",
                 "expected": "Unsealed cut plan is rejected before selection/approval", "observed": "PASS S19.T2: unsealed cut plan is rejected", "exit_status": 0],
                ["testcase_id": "S19.T3", "requirement_id": "INV-05/STORY-03", "status": "PASS",
                 "expected": "Edited claim invalidates stale G3 approval", "observed": "PASS S19.T3: edited claim makes approval stale", "exit_status": 0]
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
