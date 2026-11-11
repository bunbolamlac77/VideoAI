import Foundation

// D12: the G3 console must never fabricate a confirmed/supported claim. The payload
// builder is the only construction path and it must mirror the real ClaimRecord.

@main
struct G3StoryRequestTests {
    static func claim(
        review: ReviewStatus,
        origin: Origin = .user,
        epistemic: EpistemicStatus = .reported,
        support: SupportStatus = .insufficient,
        allowed: AllowedUse = .attributedOrQualified,
        sourceRevisionId: UUID? = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
    ) -> ClaimRecord {
        ClaimRecord(
            workdayId: UUID(),
            text: "Tôi đã đến Đà Lạt và đi xe máy qua đèo.",
            origin: origin,
            epistemicStatus: epistemic,
            reviewStatus: review,
            supportStatus: support,
            allowedUse: allowed,
            sourceRevisionId: sourceRevisionId
        )
    }

    static func main() throws {
        let confirmed = claim(review: .confirmed, support: .supported)
        let payload = try G3StoryRequestBuilder.makePayload(
            claim: confirmed,
            scopeRevisionId: nil,
            tone: "tram_tinh",
            targetSeconds: 45
        )
        precondition(payload.claims.count == 1)
        let fact = payload.claims[0]
        precondition(fact.claimId == confirmed.claimId.uuidString)
        precondition(fact.revisionId == confirmed.revisionId.uuidString)
        precondition(fact.reviewStatus == "confirmed")
        precondition(fact.supportStatus == "supported")
        // User-reported facts stay user/reported; they never become observed.
        precondition(fact.origin == "user")
        precondition(fact.epistemicStatus == "reported")
        precondition(payload.constraints.targetSeconds == 45)
        // P0-09: the scope is the claim's own provenance, never a caller constant.
        precondition(fact.evidenceScopeRevisionId == "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
        precondition(fact.scopeRevalidationStatus == "complete")

        // Unconfirmed claims are rejected instead of being silently relabelled.
        var unconfirmedRejected = false
        do {
            _ = try G3StoryRequestBuilder.makeJSON(
                claim: claim(review: .unreviewed),
                scopeRevisionId: nil,
                tone: "tram_tinh",
                targetSeconds: 45
            )
        } catch G3StoryRequestError.unconfirmedClaim {
            unconfirmedRejected = true
        }
        precondition(unconfirmedRejected, "unconfirmed claims must be rejected")

        // Missing claim is rejected.
        var missingRejected = false
        do {
            _ = try G3StoryRequestBuilder.makeJSON(
                claim: nil,
                scopeRevisionId: nil,
                tone: "tram_tinh",
                targetSeconds: 45
            )
        } catch G3StoryRequestError.missingClaim {
            missingRejected = true
        }
        precondition(missingRejected, "missing claim must be rejected")

        let json = try G3StoryRequestBuilder.makeJSON(
            claim: confirmed,
            scopeRevisionId: nil,
            tone: "tram_tinh",
            targetSeconds: 45
        )
        precondition(json.contains("\"claim_id\""))
        precondition(json.contains(confirmed.claimId.uuidString))
        precondition(!json.contains("\"c1\""))

        print("G3 STORY REQUEST BUILDER TESTS PASSED")
    }
}
