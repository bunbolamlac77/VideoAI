// G2AnalysisAndReviewEngine.swift — S12..S15 Swift 6 Analysis Ledger, Section 6 Decision Table,
// Partial-Order Event Graph, Scope-Sensitive Revalidation, Targeted Review & Gate G2 Benchmark Evaluator.
// Compliant with docs/02-ANALYSIS-AND-DATA.md, docs/07-OPTIMIZATION.md, docs/08-ACCURACY-FIRST.md,
// docs/09-UPGRADES-AND-ACCEPTANCE.md, and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S12-S15).

import Foundation

// MARK: - S12: Coverage Ledger & Raw Observation Isolation (AI-01, AI-02, JOB-03, JOB-05)

public enum ObservationPassRole: String, Codable, Sendable, Equatable {
    case rawIndependent = "raw_independent"
    case guidedRevisit = "guided_revisit"
    case omissionAudit = "omission_audit"
}

public enum AudioBranchState: String, Codable, Sendable, Equatable {
    case noAudio = "no_audio"
    case noSpeech = "no_speech"
    case speechDetected = "speech_detected"
}

public struct RawObservationArtifact: Codable, Sendable, Identifiable, Equatable {
    public var id: String { observationId }
    public let observationId: String
    public let sourceRevisionId: UUID
    public let windowIndex: Int
    public let passRole: ObservationPassRole
    public let origin: Origin
    public let epistemicStatus: EpistemicStatus
    public let frameIds: [Int]
    public let startPts: Int64
    public let endPts: Int64
    public let observationText: String
    public let ocrRawTokens: [String]
    public let ocrIsUncertain: Bool
    public let guidedHypothesisRef: String?

    public init(
        observationId: String,
        sourceRevisionId: UUID,
        windowIndex: Int,
        passRole: ObservationPassRole,
        origin: Origin = .visualModel,
        epistemicStatus: EpistemicStatus = .observed,
        frameIds: [Int],
        startPts: Int64,
        endPts: Int64,
        observationText: String,
        ocrRawTokens: [String] = [],
        ocrIsUncertain: Bool = false,
        guidedHypothesisRef: String? = nil
    ) throws {
        if passRole == .rawIndependent && guidedHypothesisRef != nil {
            throw ContractError.invalidPayload("AI-02 violation: raw_independent observation cannot carry guidedHypothesisRef")
        }
        if origin == .user {
            throw ContractError.invalidPayload("INV-02 violation: visual/ASR observation cannot claim user origin")
        }
        self.observationId = observationId
        self.sourceRevisionId = sourceRevisionId
        self.windowIndex = windowIndex
        self.passRole = passRole
        self.origin = origin
        self.epistemicStatus = epistemicStatus
        self.frameIds = frameIds
        self.startPts = startPts
        self.endPts = endPts
        self.observationText = observationText
        self.ocrRawTokens = ocrRawTokens
        self.ocrIsUncertain = ocrIsUncertain
        self.guidedHypothesisRef = guidedHypothesisRef
    }
}

public struct CoverageLedgerRecord: Codable, Sendable, Equatable {
    public let coverageId: UUID
    public let projectId: UUID
    public let sourceRevisionId: UUID
    public let runtimeProfileId: String
    public let inputFingerprint: String
    public let totalDeclaredFrames: Int
    public let validDecodedFrameCount: Int
    public let corruptedDecodeFrameIds: [Int]
    public let uniqueProcessedFrameIds: [Int]
    public let totalSubmittedWithOverlap: Int
    public let frameInputCoverage: Double
    public let audioBranchState: AudioBranchState
    public let visualBranchEnabled: Bool
    public let completedWindows: Int
    public let totalWindows: Int
    public let detailedPassStatus: String
    public let semanticUnderstandingCertified: Bool

    public init(
        coverageId: UUID = UUID(),
        projectId: UUID,
        sourceRevisionId: UUID,
        runtimeProfileId: String = "P-VISION-DEV-v1",
        inputFingerprint: String,
        totalDeclaredFrames: Int,
        validDecodedFrameCount: Int,
        corruptedDecodeFrameIds: [Int] = [],
        uniqueProcessedFrameIds: [Int],
        totalSubmittedWithOverlap: Int,
        audioBranchState: AudioBranchState = .speechDetected,
        completedWindows: Int,
        totalWindows: Int,
        detailedPassStatus: String = "completed"
    ) {
        self.coverageId = coverageId
        self.projectId = projectId
        self.sourceRevisionId = sourceRevisionId
        self.runtimeProfileId = runtimeProfileId
        self.inputFingerprint = inputFingerprint
        self.totalDeclaredFrames = max(1, totalDeclaredFrames)
        self.validDecodedFrameCount = validDecodedFrameCount
        self.corruptedDecodeFrameIds = corruptedDecodeFrameIds
        let dedupSorted = Array(Set(uniqueProcessedFrameIds)).sorted()
        self.uniqueProcessedFrameIds = dedupSorted
        self.totalSubmittedWithOverlap = totalSubmittedWithOverlap
        // AI-01: Corrupted frames stay in totalDeclaredFrames denominator so coverage is never faked as 100%!
        self.frameInputCoverage = Double(dedupSorted.count) / Double(max(1, totalDeclaredFrames))
        self.audioBranchState = audioBranchState
        self.visualBranchEnabled = true // AI-01: no_audio / no_speech NEVER disables visual branch
        self.completedWindows = completedWindows
        self.totalWindows = totalWindows
        self.detailedPassStatus = detailedPassStatus
        self.semanticUnderstandingCertified = false // S12.G: Frame coverage != 100% semantic understanding
    }
}

// MARK: - S13: Brief Parser, Atomic Claims, Section 6 Decision Table & Event Graph

public enum TimePrecisionKind: String, Codable, Sendable, Equatable {
    case exact
    case approximate
    case range
    case dateOnly = "date_only"
    case unknown
}

public enum NarrativeType: String, Codable, Sendable, Equatable {
    case observed
    case reportedByUser = "reported_by_user"
    case inferred
    case nonliteralCommentary = "nonliteral_commentary"
}

public enum EvidenceEdgeRole: String, Codable, Sendable, Equatable {
    case supports
    case contradicts
    case contextOnly = "context_only"
}

public struct EvidenceLinkEdge: Codable, Sendable, Equatable {
    public let edgeId: String
    public let claimRevisionId: UUID
    public let evidenceRevisionId: String
    public let evidenceKind: String // "visual_observation", "asr_transcript", "user_fact", "ocr_crop"
    public let role: EvidenceEdgeRole
    public let coveredComponentIds: [String]
    public let schemaAndHashValid: Bool

    public init(
        edgeId: String = UUID().uuidString,
        claimRevisionId: UUID,
        evidenceRevisionId: String,
        evidenceKind: String,
        role: EvidenceEdgeRole,
        coveredComponentIds: [String],
        schemaAndHashValid: Bool = true
    ) {
        self.edgeId = edgeId
        self.claimRevisionId = claimRevisionId
        self.evidenceRevisionId = evidenceRevisionId
        self.evidenceKind = evidenceKind
        self.role = role
        self.coveredComponentIds = coveredComponentIds
        self.schemaAndHashValid = schemaAndHashValid
    }
}

public struct ClaimUseEvaluation: Codable, Sendable, Equatable {
    public static let policyVersion = "DECISION-TABLE-02-v1"

    public let claimRevisionId: UUID
    public let evidenceScopeRevisionId: String
    public let policyVersion: String
    public let supportStatus: SupportStatus
    public let allowedUse: AllowedUse
    public let narrativeType: NarrativeType
    public let isEffective: Bool
    public let requiresTargetedReview: Bool
    public let reason: String
}

public enum S13SemanticDecisionEngine {
    /// S13.2, S13.3, S13.T1, S13.T2 & docs/02 Section 6:
    /// Evaluates an atomic or compound/causal claim against its evidence edges using the 12-row ordered Decision Table.
    public static func evaluateClaimUse(
        claim: ClaimRecord,
        claimType: String = "atomic_action",
        requiredComponentIds: [String],
        isCritical: Bool = true,
        edges: [EvidenceLinkEdge],
        evidenceScopeRevisionId: String,
        narrativeType: NarrativeType = .observed,
        pendingRevalidation: Bool = false,
        nonliteralHasFalsePremise: Bool = false
    ) -> ClaimUseEvaluation {
        let relEdges = edges.filter { $0.claimRevisionId == claim.revisionId }

        // Row 1: Invalid schema/hash/timecode -> exclude
        if relEdges.contains(where: { !$0.schemaAndHashValid }) {
            return ClaimUseEvaluation(
                claimRevisionId: claim.revisionId,
                evidenceScopeRevisionId: evidenceScopeRevisionId,
                policyVersion: ClaimUseEvaluation.policyVersion,
                supportStatus: .insufficient,
                allowedUse: .exclude,
                narrativeType: narrativeType,
                isEffective: false,
                requiresTargetedReview: true,
                reason: "Row 1: Schema, hash, or timecode reference invalid."
            )
        }

        let supporting = relEdges.filter { $0.role == .supports }
        let contradicting = relEdges.filter { $0.role == .contradicts }
        let contextOnly = relEdges.filter { $0.role == .contextOnly }

        let reqSet = Set(requiredComponentIds.isEmpty ? [claim.claimId.uuidString] : requiredComponentIds)
        var visualOrAsrCovered = Set<String>()
        var confirmedUserCovered = Set<String>()
        var hasUnconfirmedUserFact = false

        for edge in supporting {
            if edge.evidenceKind == "user_fact" {
                if claim.reviewStatus == .confirmed {
                    confirmedUserCovered.formUnion(edge.coveredComponentIds)
                } else {
                    hasUnconfirmedUserFact = true
                }
            } else if edge.evidenceKind == "asr_transcript" && claimType != "utterance_only" {
                // Section 4: Hearing someone say "Tôi đã lên phà" only supports utterance_only, not the external event
                continue
            } else {
                visualOrAsrCovered.formUnion(edge.coveredComponentIds)
            }
        }

        let allCovered = visualOrAsrCovered.union(confirmedUserCovered)
        let fullyCovered = reqSet.isSubset(of: allCovered)
        let purelyVisualCovered = reqSet.isSubset(of: visualOrAsrCovered)

        let supportStatus: SupportStatus
        if !contradicting.isEmpty {
            supportStatus = supporting.isEmpty ? .contradicted : .disputed
        } else if !fullyCovered {
            supportStatus = .insufficient
        } else {
            supportStatus = .supported
        }

        // Row 2: Pending scope revalidation withholds effective decision
        if pendingRevalidation {
            return ClaimUseEvaluation(
                claimRevisionId: claim.revisionId,
                evidenceScopeRevisionId: evidenceScopeRevisionId,
                policyVersion: ClaimUseEvaluation.policyVersion,
                supportStatus: supportStatus,
                allowedUse: .exclude,
                narrativeType: narrativeType,
                isEffective: false,
                requiresTargetedReview: false,
                reason: "Row 2: Scope revalidation pending."
            )
        }

        // Row 3: Contradicted or disputed -> exclude
        if supportStatus == .contradicted || supportStatus == .disputed {
            return ClaimUseEvaluation(
                claimRevisionId: claim.revisionId,
                evidenceScopeRevisionId: evidenceScopeRevisionId,
                policyVersion: ClaimUseEvaluation.policyVersion,
                supportStatus: supportStatus,
                allowedUse: .exclude,
                narrativeType: narrativeType,
                isEffective: true,
                requiresTargetedReview: true,
                reason: "Row 3: Contradictory evidence detected."
            )
        }

        // Row 12: Non-literal commentary with false factual premise -> exclude
        if narrativeType == .nonliteralCommentary && nonliteralHasFalsePremise {
            return ClaimUseEvaluation(
                claimRevisionId: claim.revisionId,
                evidenceScopeRevisionId: evidenceScopeRevisionId,
                policyVersion: ClaimUseEvaluation.policyVersion,
                supportStatus: supportStatus,
                allowedUse: .exclude,
                narrativeType: narrativeType,
                isEffective: true,
                requiresTargetedReview: true,
                reason: "Row 12: Non-literal commentary introduces unsupported factual premise."
            )
        }

        // Row 4: Unconfirmed user/brief fact -> exclude
        if hasUnconfirmedUserFact || (claim.origin == .user && claim.reviewStatus != .confirmed) {
            return ClaimUseEvaluation(
                claimRevisionId: claim.revisionId,
                evidenceScopeRevisionId: evidenceScopeRevisionId,
                policyVersion: ClaimUseEvaluation.policyVersion,
                supportStatus: supportStatus,
                allowedUse: .exclude,
                narrativeType: narrativeType,
                isEffective: true,
                requiresTargetedReview: true,
                reason: "Row 4: User fact revision is not confirmed."
            )
        }

        // Row 5 & Row 6: Supported
        if supportStatus == .supported {
            if !confirmedUserCovered.isEmpty || claim.origin == .user || claim.epistemicStatus == .reported || claim.epistemicStatus == .inferred {
                if narrativeType == .observed {
                    return ClaimUseEvaluation(
                        claimRevisionId: claim.revisionId,
                        evidenceScopeRevisionId: evidenceScopeRevisionId,
                        policyVersion: ClaimUseEvaluation.policyVersion,
                        supportStatus: supportStatus,
                        allowedUse: .exclude,
                        narrativeType: narrativeType,
                        isEffective: true,
                        requiresTargetedReview: true,
                        reason: "INV-02 / Row 6: User-reported or inferred claim cannot be narrated as observed."
                    )
                }
                return ClaimUseEvaluation(
                    claimRevisionId: claim.revisionId,
                    evidenceScopeRevisionId: evidenceScopeRevisionId,
                    policyVersion: ClaimUseEvaluation.policyVersion,
                    supportStatus: supportStatus,
                    allowedUse: .attributedOrQualified,
                    narrativeType: narrativeType,
                    isEffective: true,
                    requiresTargetedReview: false,
                    reason: "Row 6: Supported with confirmed user provenance (attributed_or_qualified)."
                )
            }
            if purelyVisualCovered {
                return ClaimUseEvaluation(
                    claimRevisionId: claim.revisionId,
                    evidenceScopeRevisionId: evidenceScopeRevisionId,
                    policyVersion: ClaimUseEvaluation.policyVersion,
                    supportStatus: supportStatus,
                    allowedUse: .directClaim,
                    narrativeType: narrativeType,
                    isEffective: true,
                    requiresTargetedReview: false,
                    reason: "Row 5: Direct observation covers all required components."
                )
            }
        }

        // Row 9: Context-only match for non-critical illustration
        if !contextOnly.isEmpty && !isCritical && narrativeType == .nonliteralCommentary {
            return ClaimUseEvaluation(
                claimRevisionId: claim.revisionId,
                evidenceScopeRevisionId: evidenceScopeRevisionId,
                policyVersion: ClaimUseEvaluation.policyVersion,
                supportStatus: supportStatus,
                allowedUse: .illustrativeOnly,
                narrativeType: narrativeType,
                isEffective: true,
                requiresTargetedReview: false,
                reason: "Row 9: Context-only match allowed strictly as illustrative B-roll."
            )
        }

        // Row 10 & Row 11: Insufficient evidence (context_only never upgrades to supports!)
        return ClaimUseEvaluation(
            claimRevisionId: claim.revisionId,
            evidenceScopeRevisionId: evidenceScopeRevisionId,
            policyVersion: ClaimUseEvaluation.policyVersion,
            supportStatus: .insufficient,
            allowedUse: .exclude,
            narrativeType: narrativeType,
            isEffective: true,
            requiresTargetedReview: isCritical,
            reason: "Row 10/11: Insufficient component coverage (\(contextOnly.count) context-only edges did not upgrade)."
        )
    }
}

// MARK: - S14: Targeted Review Items, Resolution Commands & Batch Confirmation Filter

public enum ReviewEvidenceKind: String, Codable, Sendable, Equatable {
    case videoOrAudio = "video_or_audio"
    case stillPhoto = "still_photo"
    case briefSpan = "brief_span"
}

public enum ReviewResolutionAction: String, Codable, Sendable, Equatable {
    case confirmUserFact = "confirm_user_fact"
    case editFactOrClaim = "edit_fact_or_claim"
    case rejectAiObservation = "reject_ai_observation"
    case answerUnknown = "answer_unknown"
    case dropClaimOrDetail = "drop_claim_or_detail"
    case excludeAssetFromEdit = "exclude_asset_from_edit"
}

public struct TargetedReviewRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { reviewItemId }
    public let reviewItemId: UUID
    public let projectId: UUID
    public let workdayId: UUID
    public let targetClaimRevisionId: UUID?
    public let evidenceScopeRevisionId: String
    public let evidenceKind: ReviewEvidenceKind
    public let isCritical: Bool
    public let questionText: String
    public let affectedConceptIds: [String]
    public let sourceTimeSec: Double?
    public let timelineTimeSec: Double?
    public let status: String // "open", "resolved"
    public let resolutionAction: ReviewResolutionAction?
    public let resultingAllowedUse: AllowedUse?

    public init(
        reviewItemId: UUID = UUID(),
        projectId: UUID,
        workdayId: UUID,
        targetClaimRevisionId: UUID? = nil,
        evidenceScopeRevisionId: String,
        evidenceKind: ReviewEvidenceKind,
        isCritical: Bool = true,
        questionText: String,
        affectedConceptIds: [String] = ["concept-A"],
        sourceTimeSec: Double? = nil,
        timelineTimeSec: Double? = nil,
        status: String = "open",
        resolutionAction: ReviewResolutionAction? = nil,
        resultingAllowedUse: AllowedUse? = nil
    ) throws {
        // S14.T2: Still photos and brief spans must NOT carry fake media timecodes
        if (evidenceKind == .stillPhoto || evidenceKind == .briefSpan) && sourceTimeSec != nil {
            throw ContractError.invalidPayload("S14.T2 violation: \(evidenceKind.rawValue) cannot carry fake media timecode")
        }
        self.reviewItemId = reviewItemId
        self.projectId = projectId
        self.workdayId = workdayId
        self.targetClaimRevisionId = targetClaimRevisionId
        self.evidenceScopeRevisionId = evidenceScopeRevisionId
        self.evidenceKind = evidenceKind
        self.isCritical = isCritical
        self.questionText = questionText
        self.affectedConceptIds = affectedConceptIds
        self.sourceTimeSec = sourceTimeSec
        self.timelineTimeSec = timelineTimeSec
        self.status = status
        self.resolutionAction = resolutionAction
        self.resultingAllowedUse = resultingAllowedUse
    }
}

public enum S14ReviewCoordinator {
    /// S14.1 & S14.T3 (UI-08): Batch confirmation only applies to revisions that were BOTH displayed in the UI snapshot
    /// AND selected by the user; background arrivals are excluded.
    public static func filterBatchConfirmable(
        displayedRevisionIds: [UUID],
        selectedRevisionIds: Set<UUID>,
        currentStoreRevisionIds: [UUID]
    ) -> (confirmable: [UUID], skippedBackgroundArrivals: [UUID]) {
        let dispSet = Set(displayedRevisionIds)
        let confirmable = displayedRevisionIds.filter { selectedRevisionIds.contains($0) }
        let skipped = currentStoreRevisionIds.filter { !dispSet.contains($0) }
        return (confirmable, skipped)
    }

    /// S14.3 & S14.T1: Resolves a review item. Answering `.answerUnknown` never grants support (`exclude`),
    /// and a critical issue only blocks `affectedConceptIds`, leaving other story concepts viable.
    public static func resolveReviewItem(
        item: TargetedReviewRecord,
        action: ReviewResolutionAction,
        allConceptIds: [String] = ["concept-A", "concept-B"]
    ) throws -> (updatedItem: TargetedReviewRecord, blockedConcepts: [String], viableConcepts: [String]) {
        let allowedUse: AllowedUse
        let blocked: [String]
        switch action {
        case .confirmUserFact, .editFactOrClaim:
            allowedUse = .attributedOrQualified
            blocked = []
        case .answerUnknown, .rejectAiObservation, .dropClaimOrDetail, .excludeAssetFromEdit:
            allowedUse = .exclude
            blocked = item.isCritical ? allConceptIds.filter { item.affectedConceptIds.contains($0) } : []
        }
        let viable = allConceptIds.filter { !blocked.contains($0) }
        let updated = try TargetedReviewRecord(
            reviewItemId: item.reviewItemId,
            projectId: item.projectId,
            workdayId: item.workdayId,
            targetClaimRevisionId: item.targetClaimRevisionId,
            evidenceScopeRevisionId: item.evidenceScopeRevisionId,
            evidenceKind: item.evidenceKind,
            isCritical: item.isCritical,
            questionText: item.questionText,
            affectedConceptIds: item.affectedConceptIds,
            sourceTimeSec: item.sourceTimeSec,
            timelineTimeSec: item.timelineTimeSec,
            status: "resolved",
            resolutionAction: action,
            resultingAllowedUse: allowedUse
        )
        return (updated, blocked, viable)
    }
}
