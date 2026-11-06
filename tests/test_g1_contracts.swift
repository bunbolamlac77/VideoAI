// test_g1_contracts.swift — Swift Unit Tests for Gate G1 S04 Contracts & State Machines

import Foundation

@main
struct TestG1Contracts {
    static func main() {
        print("=======================================================")
        print("RUNNING SWIFT G1 CONTRACTS & STATE MACHINE TESTS (S04)")
        print("=======================================================\n")

        var passCount = 0

        // Test 1: Invariant S04.T2: User confirmation preserves origin and epistemic status
        print("[Test 1] S04.T2: User confirmation preserves origin=user and epistemic=reported...")
        let workdayId = UUID()
        let claim = ClaimRecord(
            workdayId: workdayId,
            text: "Tôi đã quay phim tại Đèo Prenn lúc hoàng hôn.",
            origin: .user,
            epistemicStatus: .reported,
            reviewStatus: .unreviewed,
            supportStatus: .insufficient,
            allowedUse: .exclude
        )
        let confirmed = claim.confirmingUserFact()
        assert(confirmed.origin == .user, "Origin must remain .user")
        assert(confirmed.epistemicStatus == .reported, "Epistemic status must remain .reported")
        assert(confirmed.reviewStatus == .confirmed, "Review status must be .confirmed")
        assert(confirmed.revisionId != claim.revisionId, "Revision ID must increment")
        print("   ✅ PASS: Invariant S04.T2 verified.")
        passCount += 1

        // Test 2: Artifact Publication State Machine transitions
        print("\n[Test 2] S04.3: Artifact Publication State Machine transitions...")
        var pub = ArtifactPublicationRecord(
            projectId: UUID(),
            jobId: UUID(),
            attemptId: UUID(),
            fencingToken: 1,
            artifactType: "tts_audio"
        )
        assert(pub.state == .prepared, "Initial state must be PREPARED")

        // Illegal jump: prepared -> committed throws
        var threwIllegal = false
        do {
            try pub.transitionToCommitted(canonicalPath: "/storage/audio.wav")
        } catch {
            threwIllegal = true
        }
        assert(threwIllegal, "PREPARED -> COMMITTED must throw illegalStateTransition")

        // Legal: prepared -> materialized
        do {
            try pub.transitionToMaterialized(tempPath: "/tmp/audio_attempt.wav")
            assert(pub.state == .materialized, "State must be MATERIALIZED")
        } catch {
            fatalError("Failed legal transition to MATERIALIZED: \(error)")
        }

        // Legal: materialized -> verified
        do {
            let validHash = String(repeating: "f", count: 64)
            try pub.transitionToVerified(sha256: validHash, size: 2048)
            assert(pub.state == .verified, "State must be VERIFIED")
        } catch {
            fatalError("Failed legal transition to VERIFIED: \(error)")
        }

        // Legal: verified -> committed
        do {
            try pub.transitionToCommitted(canonicalPath: "/storage/canonical_audio.wav")
            assert(pub.state == .committed, "State must be COMMITTED")
        } catch {
            fatalError("Failed legal transition to COMMITTED: \(error)")
        }
        print("   ✅ PASS: Artifact publication state machine transitions verified.")
        passCount += 1

        // Test 3: Job State Machine transitions
        print("\n[Test 3] S04.3: Job status transition barriers...")
        assert(JobStatus.queued.canTransition(to: .running), "QUEUED -> RUNNING allowed")
        assert(JobStatus.running.canTransition(to: .succeeded), "RUNNING -> SUCCEEDED allowed")
        assert(!JobStatus.succeeded.canTransition(to: .running), "SUCCEEDED -> RUNNING forbidden")
        assert(!JobStatus.failed.canTransition(to: .running), "FAILED -> RUNNING forbidden")
        print("   ✅ PASS: Job status transition barriers verified.")
        passCount += 1

        print("\n=======================================================")
        print("ALL SWIFT G1 CONTRACT TESTS PASSED (\(passCount)/\(passCount))!")
        print("=======================================================\n")
    }
}
