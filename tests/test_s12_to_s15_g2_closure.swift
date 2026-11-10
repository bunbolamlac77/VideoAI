// test_s12_to_s15_g2_closure.swift — Gate G2 Swift 6 Verification Suite for S12..S15
// Verifies CoverageLedgerRecord, RawObservationArtifact isolation, S13SemanticDecisionEngine,
// S14ReviewCoordinator batch confirmation & ProjectStore SQLite WAL persistence.

import Foundation

/// Resolve a Python interpreter for tests: explicit override, managed runtime,
/// Homebrew, then PATH. Hosted runners do not have /opt/homebrew/bin/python3.12.
func aivideo_test_python_path() -> String {
    let env = ProcessInfo.processInfo.environment
    let fm = FileManager.default
    if let override = env["AIVIDEO_PYTHON"], fm.isExecutableFile(atPath: override) {
        return override
    }
    let home = fm.homeDirectoryForCurrentUser.path
    var candidates = [
        "\(home)/Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime/bin/python3",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3"
    ]
    if let path = env["PATH"] {
        for dir in path.split(separator: ":") {
            candidates.append("\(dir)/python3")
        }
    }
    return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
}



@main
struct TestS12ToS15G2Closure {
    static func main() async {
        var records: [[String: Any]] = []
        let commit = ProcessInfo.processInfo.environment["GIT_COMMIT"] ?? "unknown"

        func record(_ caseId: String, _ reqId: String, _ passed: Bool, _ details: String) {
            print("[\(passed ? "PASS" : "FAIL")] \(caseId) (\(reqId)): \(details)")
            records.append([
                "case_id": caseId,
                "requirement_id": reqId,
                "status": passed ? "PASS" : "FAIL",
                "details": details,
                "commit": commit
            ])
        }

        // 1. S12_SWIFT_T1: RawObservationArtifact brief-isolation & CoverageLedgerRecord union/denominator
        do {
            let srcRev = UUID()
            // Attempting to attach guidedHypothesisRef to rawIndependent must throw
            var blockedBriefLeak = false
            do {
                _ = try RawObservationArtifact(
                    observationId: "obs-1",
                    sourceRevisionId: srcRev,
                    windowIndex: 0,
                    passRole: .rawIndependent,
                    frameIds: [0, 1, 2, 3],
                    startPts: 0,
                    endPts: 4000,
                    observationText: "Raw pass",
                    guidedHypothesisRef: "hyp-leak"
                )
            } catch {
                blockedBriefLeak = true
            }

            let ledger = CoverageLedgerRecord(
                projectId: UUID(),
                sourceRevisionId: srcRev,
                inputFingerprint: "fp-s12-001",
                totalDeclaredFrames: 32,
                validDecodedFrameCount: 30,
                corruptedDecodeFrameIds: [30, 31],
                uniqueProcessedFrameIds: Array(0..<16) + Array(12..<30), // Overlapping windows [0..15] and [12..29] -> 30 unique
                totalSubmittedWithOverlap: 34,
                audioBranchState: .noAudio,
                completedWindows: 2,
                totalWindows: 2
            )

            let ok = blockedBriefLeak
                && ledger.uniqueProcessedFrameIds.count == 30
                && abs(ledger.frameInputCoverage - (30.0 / 32.0)) < 1e-9
                && ledger.visualBranchEnabled == true
                && ledger.semanticUnderstandingCertified == false
            record(
                "S12_SWIFT_T1_COVERAGE_AND_RAW_ISOLATION",
                "AI-01/AI-02",
                ok,
                "Blocked brief leak in raw pass; union unique frames=30/32 (0.9375), visualBranchEnabled=true on no_audio, semanticCertified=false"
            )
        }

        // 2. S13_SWIFT_T1: S13SemanticDecisionEngine causal split, context_only non-upgrade & INV-02 provenance
        do {
            let wdId = UUID()
            let causalClaim = ClaimRecord(
                workdayId: wdId,
                text: "Quay đầu vì GPS báo nhầm",
                origin: .derived,
                epistemicStatus: .inferred,
                reviewStatus: .unreviewed
            )
            // Only action component supported + context_only edge for cause -> must be insufficient / exclude
            let edgesPartial = [
                EvidenceLinkEdge(
                    claimRevisionId: causalClaim.revisionId,
                    evidenceRevisionId: "obs-turn",
                    evidenceKind: "visual_observation",
                    role: .supports,
                    coveredComponentIds: ["comp-action"]
                ),
                EvidenceLinkEdge(
                    claimRevisionId: causalClaim.revisionId,
                    evidenceRevisionId: "obs-map-context",
                    evidenceKind: "visual_observation",
                    role: .contextOnly,
                    coveredComponentIds: ["comp-cause"]
                )
            ]
            let evalPartial = S13SemanticDecisionEngine.evaluateClaimUse(
                claim: causalClaim,
                claimType: "causal_relation",
                requiredComponentIds: ["comp-action", "comp-cause"],
                isCritical: true,
                edges: edgesPartial,
                evidenceScopeRevisionId: "scope-v1",
                narrativeType: .observed
            )

            // User-confirmed fact for cause: origin=user, epistemic=reported, review=confirmed
            let userConfirmedClaim = ClaimRecord(
                workdayId: wdId,
                text: "Quay đầu vì GPS báo nhầm",
                origin: .user,
                epistemicStatus: .reported,
                reviewStatus: .confirmed
            )
            let edgesConfirmed = [
                EvidenceLinkEdge(
                    claimRevisionId: userConfirmedClaim.revisionId,
                    evidenceRevisionId: "obs-turn",
                    evidenceKind: "visual_observation",
                    role: .supports,
                    coveredComponentIds: ["comp-action"]
                ),
                EvidenceLinkEdge(
                    claimRevisionId: userConfirmedClaim.revisionId,
                    evidenceRevisionId: "fact-user-gps",
                    evidenceKind: "user_fact",
                    role: .supports,
                    coveredComponentIds: ["comp-cause"]
                )
            ]
            let evalIllegalObs = S13SemanticDecisionEngine.evaluateClaimUse(
                claim: userConfirmedClaim,
                claimType: "causal_relation",
                requiredComponentIds: ["comp-action", "comp-cause"],
                isCritical: true,
                edges: edgesConfirmed,
                evidenceScopeRevisionId: "scope-v1",
                narrativeType: .observed
            )
            let evalValidReported = S13SemanticDecisionEngine.evaluateClaimUse(
                claim: userConfirmedClaim,
                claimType: "causal_relation",
                requiredComponentIds: ["comp-action", "comp-cause"],
                isCritical: true,
                edges: edgesConfirmed,
                evidenceScopeRevisionId: "scope-v1",
                narrativeType: .reportedByUser
            )

            let ok = evalPartial.supportStatus == .insufficient
                && evalPartial.allowedUse == .exclude
                && evalIllegalObs.allowedUse == .exclude
                && evalValidReported.supportStatus == .supported
                && evalValidReported.allowedUse == .attributedOrQualified
            record(
                "S13_SWIFT_T1_DECISION_TABLE_AND_PROVENANCE",
                "AI-03/AI-05/INV-02",
                ok,
                "Partial causal + context_only -> exclude; user-confirmed as observed -> exclude; user-confirmed as reported_by_user -> attributed_or_qualified"
            )
        }

        // 3. S14_SWIFT_T1: Targeted review persistence in ProjectStore, answerUnknown != agreement & batch confirm filter
        do {
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("s14_swift_test_\(UUID().uuidString)")
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }

            let dbURL = tmpDir.appendingPathComponent("test_g2.sqlite")
            let store = try ProjectStore(dbURL: dbURL)
            let proj = try await store.createProject(name: "G2 Review Project")
            let wd = try await store.createWorkday(projectId: proj.projectId, title: "Ngày 1", date: "2026-11-09")

            // Verify fake timecode on brief_span is rejected
            var rejectedFakeTimecode = false
            do {
                _ = try TargetedReviewRecord(
                    projectId: proj.projectId,
                    workdayId: wd.workdayId,
                    evidenceScopeRevisionId: "scope-v1",
                    evidenceKind: .briefSpan,
                    questionText: "Câu hỏi từ brief?",
                    sourceTimeSec: 12.5
                )
            } catch {
                rejectedFakeTimecode = true
            }

            let reviewItem = try TargetedReviewRecord(
                projectId: proj.projectId,
                workdayId: wd.workdayId,
                evidenceScopeRevisionId: "scope-v1",
                evidenceKind: .briefSpan,
                isCritical: true,
                questionText: "Làm rõ nguyên nhân dừng xe trong ghi chú?",
                affectedConceptIds: ["concept-A"]
            )
            try await store.saveReviewItem(reviewItem)

            let (resolvedItem, blocked, viable) = try S14ReviewCoordinator.resolveReviewItem(
                item: reviewItem,
                action: .answerUnknown,
                allConceptIds: ["concept-A", "concept-B"]
            )
            try await store.saveReviewItem(resolvedItem)
            let loaded = try await store.listReviewItems(workdayId: wd.workdayId)

            // Batch confirm filter test
            let r1 = UUID(), r2 = UUID(), r3Bg = UUID()
            let (confirmable, skippedBg) = S14ReviewCoordinator.filterBatchConfirmable(
                displayedRevisionIds: [r1, r2],
                selectedRevisionIds: [r1, r2, r3Bg],
                currentStoreRevisionIds: [r1, r2, r3Bg]
            )

            await store.close()

            let ok = rejectedFakeTimecode
                && loaded.count == 1
                && loaded[0].status == "resolved"
                && loaded[0].resolutionAction == .answerUnknown
                && loaded[0].resultingAllowedUse == .exclude
                && blocked == ["concept-A"]
                && viable == ["concept-B"]
                && confirmable == [r1, r2]
                && skippedBg == [r3Bg]
            record(
                "S14_SWIFT_T1_REVIEW_STORE_AND_BATCH_FILTER",
                "AI-09/UI-08/UI-12",
                ok,
                "Rejected fake timecode on brief; answer_unknown persisted with allowedUse=exclude, blocked=['concept-A'], viable=['concept-B'], skippedBg count=1"
            )
        } catch {
            record("S14_SWIFT_T1_REVIEW_STORE_AND_BATCH_FILTER", "AI-09/UI-08/UI-12", false, "Error: \(error)")
        }

        // 4. S12_S14_E2E_WORKER_RPC_AND_SQLITE: Real video -> WorkerClient g2.analyze_source -> ProjectStore SQLite -> Review
        do {
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("s12_e2e_test_\(UUID().uuidString)")
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }

            let clipPath = tmpDir.appendingPathComponent("test_e2e_clip.mp4").path
            let ffProc = Process()
            ffProc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            ffProc.arguments = [
                "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=green:s=320x240:r=24:d=1",
                "-pix_fmt", "yuv420p", clipPath
            ]
            ffProc.standardInput = FileHandle.nullDevice
            ffProc.standardOutput = FileHandle.nullDevice
            ffProc.standardError = FileHandle.nullDevice
            try ffProc.run()
            ffProc.waitUntilExit()

            let client = WorkerClient()
            let pyPath = aivideo_test_python_path()
            _ = try await client.start(pythonPath: pyPath, scriptPath: "workers/src/aivideo_workers/main.py", timeoutSeconds: 8.0)

            let srcRevUUID = UUID()
            let wdUUID = UUID()
            let rpcRes = try await client.analyzeG2Source(
                filePath: clipPath,
                sourceRevisionId: srcRevUUID.uuidString,
                workdayId: wdUUID.uuidString,
                briefText: "Dừng xe tại đèo Prenn vì GPS báo nhầm."
            )
            await client.terminate()

            let dbURL = tmpDir.appendingPathComponent("e2e_store.sqlite")
            let store = try ProjectStore(dbURL: dbURL)
            let proj = try await store.createProject(name: "E2E G2 Project")
            _ = try await store.createWorkday(id: wdUUID, projectId: proj.projectId, title: "Ngày E2E", date: "2026-11-09")

            let covRec = CoverageLedgerRecord(
                projectId: proj.projectId,
                sourceRevisionId: srcRevUUID,
                runtimeProfileId: rpcRes.coverageLedger.runtimeProfileId,
                inputFingerprint: rpcRes.coverageLedger.inputFingerprint,
                totalDeclaredFrames: rpcRes.coverageLedger.totalDeclaredSourceFrames,
                validDecodedFrameCount: rpcRes.coverageLedger.validDecodedFrameIds.count,
                corruptedDecodeFrameIds: rpcRes.coverageLedger.corruptedDecodeFrameIds,
                uniqueProcessedFrameIds: rpcRes.coverageLedger.uniquePostProcessorFrameIds,
                totalSubmittedWithOverlap: rpcRes.coverageLedger.totalSubmittedFramesWithOverlap,
                completedWindows: 0,
                totalWindows: 1,
                detailedPassStatus: rpcRes.coverageLedger.detailedPassStatus
            )
            try await store.saveCoverageRecord(covRec)
            let loadedCovs = try await store.listCoverageRecords(projectId: proj.projectId)

            for cDto in rpcRes.claims {
                let claimRec = ClaimRecord(
                    workdayId: wdUUID,
                    text: cDto.text,
                    origin: Origin(rawValue: cDto.origin) ?? .user,
                    epistemicStatus: EpistemicStatus(rawValue: cDto.epistemicStatus) ?? .reported,
                    reviewStatus: ReviewStatus(rawValue: cDto.reviewStatus) ?? .unreviewed,
                    supportStatus: SupportStatus(rawValue: cDto.supportStatus) ?? .insufficient,
                    allowedUse: AllowedUse(rawValue: cDto.allowedUse) ?? .exclude
                )
                _ = try await store.saveClaim(claim: claimRec, idempotencyKey: "e2e-claim-\(cDto.claimId)")
            }
            let loadedClaims = try await store.getLatestClaims(workdayId: wdUUID)

            for rDto in rpcRes.reviewItems {
                let rec = try TargetedReviewRecord(
                    projectId: proj.projectId,
                    workdayId: wdUUID,
                    evidenceScopeRevisionId: rDto.evidenceScopeRevisionId,
                    evidenceKind: ReviewEvidenceKind(rawValue: rDto.evidenceKind) ?? .briefSpan,
                    isCritical: rDto.isCritical,
                    questionText: rDto.questionText
                )
                try await store.saveReviewItem(rec)
            }
            let loadedReviews = try await store.listReviewItems(workdayId: wdUUID)
            await store.close()

            // Since visual model is not installed, status MUST be blocked_model_unavailable with 0% coverage & 0 fake observations,
            // while brief decomposition creates real claims & targeted review items persisted in SQLite!
            let ok = rpcRes.coverageLedger.detailedPassStatus == "blocked_model_unavailable"
                && rpcRes.coverageLedger.frameInputCoverage == 0.0
                && rpcRes.rawObservationsCount == 0
                && rpcRes.rawObservations.isEmpty
                && rpcRes.audioBranchState == "no_audio"
                && rpcRes.coverageLedger.totalDeclaredSourceFrames == 24
                && loadedCovs.count == 1
                && loadedCovs[0].detailedPassStatus == "blocked_model_unavailable"
                && loadedClaims.count >= 2
                && loadedReviews.count >= 2
            record(
                "S12_S14_SWIFT_E2E_WORKER_RPC_TO_SQLITE",
                "AI-01/AI-03/AI-09",
                ok,
                "E2E video -> g2.analyze_source -> blocked_model_unavailable (0% coverage, 0 fake obs, no_audio), \(loadedClaims.count) claims & \(loadedReviews.count) review items persisted in SQLite"
            )
        } catch {
            record("S12_S14_SWIFT_E2E_WORKER_RPC_TO_SQLITE", "AI-01/AI-03/AI-09", false, "Error: \(error)")
        }

        // Write JSONL evidence
        if let outPath = ProcessInfo.processInfo.environment["TEST_RECORDS_OUT"] {
            var lines: [String] = []
            for r in records {
                if let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]),
                   let s = String(data: d, encoding: .utf8) {
                    lines.append(s)
                }
            }
            let content = lines.joined(separator: "\n") + "\n"
            try? content.write(toFile: outPath, atomically: true, encoding: .utf8)
        }

        let failedCount = records.filter { ($0["status"] as? String) != "PASS" }.count
        if failedCount > 0 {
            Foundation.exit(1)
        }
    }
}
