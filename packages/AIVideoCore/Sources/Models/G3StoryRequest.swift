// G3StoryRequest.swift — canonical S16 story-request payload builder.
//
// The G3 console used to send a hard-coded `claim_id = "c1"` with
// `review_status = confirmed`, `support_status = supported` and
// `allowed_use = attributed_or_qualified`, regardless of the real claim. The worker
// then narrated a sentence the user typed but never confirmed, while the audit trail
// implied a verified fact. This builder is the only way to construct the request:
// it requires a real ClaimRecord and refuses anything that is not user-confirmed.

import Foundation

public enum G3StoryRequestError: Error, LocalizedError, Sendable {
    case missingClaim
    case unconfirmedClaim(ReviewStatus)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingClaim:
            return "Chọn một fact đã có trong G1 trước khi sinh kịch bản."
        case .unconfirmedClaim(let status):
            return "Fact chưa được xác nhận (review_status=\(status.rawValue)); hãy xác nhận trước."
        case .encodingFailed(let reason):
            return "Không mã hoá được story request: \(reason)"
        }
    }
}

public struct G3StoryFactPayload: Codable, Sendable, Equatable {
    public let claimId: String
    public let revisionId: String
    public let text: String
    public let origin: String
    public let epistemicStatus: String
    public let reviewStatus: String
    public let supportStatus: String
    public let allowedUse: String
    public let scopeRevalidationStatus: String
    public let evidenceScopeRevisionId: String

    public enum CodingKeys: String, CodingKey {
        case claimId = "claim_id"
        case revisionId = "revision_id"
        case text
        case origin
        case epistemicStatus = "epistemic_status"
        case reviewStatus = "review_status"
        case supportStatus = "support_status"
        case allowedUse = "allowed_use"
        case scopeRevalidationStatus = "scope_revalidation_status"
        case evidenceScopeRevisionId = "evidence_scope_revision_id"
    }
}

public struct G3StoryConstraintsPayload: Codable, Sendable, Equatable {
    public let tone: String
    public let targetSeconds: Int
    public let mustUse: [String]
    public let mustNotUse: [String]
    public let preferred: [String]

    public enum CodingKeys: String, CodingKey {
        case tone
        case targetSeconds = "target_seconds"
        case mustUse = "must_use"
        case mustNotUse = "must_not_use"
        case preferred
    }
}

public struct G3StoryRequestPayload: Codable, Sendable, Equatable {
    public let evidenceScopeRevisionId: String
    public let claims: [G3StoryFactPayload]
    public let shots: [String]
    public let constraints: G3StoryConstraintsPayload

    public enum CodingKeys: String, CodingKey {
        case evidenceScopeRevisionId = "evidence_scope_revision_id"
        case claims
        case shots
        case constraints
    }
}

public enum G3StoryRequestBuilder {
    /// Build the wire payload for `g3.story.generate` from a real claim.
    public static func makePayload(
        claim: ClaimRecord?,
        scopeRevisionId: String,
        tone: String,
        targetSeconds: Int
    ) throws -> G3StoryRequestPayload {
        guard let claim else { throw G3StoryRequestError.missingClaim }
        guard claim.reviewStatus == .confirmed else {
            throw G3StoryRequestError.unconfirmedClaim(claim.reviewStatus)
        }
        let trimmedScope = scopeRevisionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScope.isEmpty else {
            throw G3StoryRequestError.encodingFailed("scope revision id rỗng")
        }

        let fact = G3StoryFactPayload(
            claimId: claim.claimId.uuidString,
            revisionId: claim.revisionId.uuidString,
            text: claim.text,
            origin: claim.origin.rawValue,
            epistemicStatus: claim.epistemicStatus.rawValue,
            reviewStatus: claim.reviewStatus.rawValue,
            supportStatus: claim.supportStatus.rawValue,
            allowedUse: claim.allowedUse.rawValue,
            scopeRevalidationStatus: "complete",
            evidenceScopeRevisionId: trimmedScope
        )

        return G3StoryRequestPayload(
            evidenceScopeRevisionId: trimmedScope,
            claims: [fact],
            shots: [],
            constraints: G3StoryConstraintsPayload(
                tone: tone,
                targetSeconds: targetSeconds,
                mustUse: [],
                mustNotUse: [],
                preferred: []
            )
        )
    }

    /// JSON string ready for the `g3.story.generate` RPC.
    public static func makeJSON(
        claim: ClaimRecord?,
        scopeRevisionId: String,
        tone: String,
        targetSeconds: Int
    ) throws -> String {
        let payload = try makePayload(
            claim: claim,
            scopeRevisionId: scopeRevisionId,
            tone: tone,
            targetSeconds: targetSeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(payload)
            guard let json = String(data: data, encoding: .utf8) else {
                throw G3StoryRequestError.encodingFailed("JSON không phải UTF-8")
            }
            return json
        } catch let error as G3StoryRequestError {
            throw error
        } catch {
            throw G3StoryRequestError.encodingFailed(error.localizedDescription)
        }
    }
}
