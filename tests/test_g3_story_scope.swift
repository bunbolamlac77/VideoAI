import Foundation

// P0-09 (audit 2026-11-11): the evidence scope of a story request must be the claim's own
// provenance. Before this fix `G3ConsoleView` sent the literal `"scope-g2-main"` — a revision
// id that exists nowhere in SQLite — and `G3StoryFactPayload.scopeRevalidationStatus` was
// hard-coded to `"complete"` for every claim. The worker only checks that the scope string is
// non-empty and defaults revalidation to "complete", so both fabrications travelled silently
// into the story request.
//
// Every check below fails against the pre-fix builder (it has no `evidenceScope` /
// `scopeRevalidationStatus` helpers and always stamps "complete").

@main
struct G3StoryScopeTests {
    static let scopeUUID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let otherUUID = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!

    static func claim(sourceRevisionId: UUID?) -> ClaimRecord {
        ClaimRecord(
            workdayId: UUID(),
            text: "Cô dâu bước vào lễ đường lúc 10 giờ.",
            origin: .user,
            epistemicStatus: .reported,
            reviewStatus: .confirmed,
            supportStatus: .supported,
            allowedUse: .directClaim,
            sourceRevisionId: sourceRevisionId
        )
    }

    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }

        let withScope = claim(sourceRevisionId: scopeUUID)

        // 1) The scope defaults to the claim's own source revision, not a constant.
        check(
            G3StoryRequestBuilder.evidenceScope(for: withScope) == scopeUUID.uuidString,
            "evidenceScope must be the claim's source_revision_id"
        )
        let payload = try G3StoryRequestBuilder.makePayload(
            claim: withScope,
            scopeRevisionId: nil,
            tone: "tram_tinh",
            targetSeconds: 30
        )
        check(
            payload.evidenceScopeRevisionId == scopeUUID.uuidString,
            "an empty scope must resolve to the claim's own scope"
        )
        check(
            payload.claims[0].evidenceScopeRevisionId == scopeUUID.uuidString,
            "the fact must carry the same scope"
        )
        check(
            payload.claims[0].scopeRevalidationStatus == "complete",
            "the claim's own scope is the only complete case"
        )

        // 2) A foreign scope is never stamped "complete".
        let foreign = try G3StoryRequestBuilder.makePayload(
            claim: withScope,
            scopeRevisionId: otherUUID.uuidString,
            tone: "tram_tinh",
            targetSeconds: 30
        )
        check(
            foreign.claims[0].scopeRevalidationStatus != "complete",
            "a foreign scope must not be reported as revalidated"
        )

        // 3) A claim without provenance cannot invent a scope.
        let noScope = claim(sourceRevisionId: nil)
        var missingScope = false
        do {
            _ = try G3StoryRequestBuilder.makeJSON(
                claim: noScope,
                scopeRevisionId: nil,
                tone: "tram_tinh",
                targetSeconds: 30
            )
        } catch G3StoryRequestError.missingScope {
            missingScope = true
        }
        check(missingScope, "a claim with no source revision must be refused")

        // 4) No wire payload may ever contain the old fabricated constant.
        let json = try G3StoryRequestBuilder.makeJSON(
            claim: withScope,
            scopeRevisionId: nil,
            tone: "tram_tinh",
            targetSeconds: 30
        )
        check(!json.contains("scope-g2-main"), "the fabricated scope constant must never be sent")

        if failures > 0 {
            print("G3 STORY SCOPE TESTS FAILED (\(failures))")
            exit(1)
        }
        print("G3 STORY SCOPE TESTS PASSED")
    }
}
