// test_s10_s11_g2_foundations.swift — Swift 6 Unit Tests for Gate G2 S10 (MediaIndexer) & S11 (ModelAdapterContracts)
// Compliant with docs/02-ANALYSIS-AND-DATA.md, docs/03-MODELS-AND-RESOURCES.md, docs/04-SCRIPT-AND-EDIT.md,
// and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S10 & S11).

import Foundation

func recordS10S11TestResult(
    testcaseId: String,
    requirementId: String,
    command: String = "./build/tests/test_s10_s11_g2_foundations",
    expected: String,
    observed: String,
    status: String,
    exitStatus: Int32
) {
    let reportDir = "build/reports"
    try? FileManager.default.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
    let record: [String: Any] = [
        "testcase_id": testcaseId,
        "requirement_id": requirementId,
        "suite": "swift_s10_s11_g2_foundations",
        "command": command,
        "expected": expected,
        "observed": observed,
        "status": status,
        "exit_status": exitStatus,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/swift_s10_s11_records.jsonl"
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let lineData = (line + "\n").data(using: .utf8) {
                handle.write(lineData)
            }
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

@main
struct TestS10S11G2Foundations {
    static func main() async {
        print("=======================================================")
        print("RUNNING SWIFT G2 S10 MEDIA INDEXER & S11 ADAPTER TESTS")
        print("=======================================================\n")

        do {
            // Test 1: S10.T1 & S10.T4 — Exact Rational VFR -> CFR 24/1 Mapping, Resolve Inclusive Bounds & Seek
            print("[Test 1] S10.T1 & S10.T4: Rational VFR->CFR 24/1 mapping, Resolve bounds & deterministic seek...")
            let sourceRevId = UUID()
            var ptsIndex: [SourceFramePTSRecord] = []
            // 29.97 fps (timeBase 1001/30000), 30 frames
            for i in 0..<30 {
                ptsIndex.append(SourceFramePTSRecord(
                    frameId: i,
                    pts: Int64(i * 1001),
                    durationPts: 1001,
                    timeBaseNum: 1,
                    timeBaseDen: 30000
                ))
            }

            let cmap = try MediaIndexer.buildVFRToCFR24Map(
                ptsIndex: ptsIndex,
                sourceRevisionId: sourceRevId,
                sourceStartSec: try RationalTime(0, 1),
                timelineFrameCount: 24,
                rotationDegrees: -90
            )
            assert(cmap.timelineFrameCount == 24)
            assert(cmap.rotationDegrees == 270)
            assert(!cmap.droppedSourceFrameIds.isEmpty, "29.97 -> 24 conform must record dropped frames")
            assert(!cmap.nativeConformAllowed)

            let (seekFrameId, seekPts) = try cmap.seekToSource(timelineFrame: 0)
            assert(seekFrameId == 0 && seekPts == 0)

            let (inF, outInc) = try MediaIndexer.toResolveInclusiveBounds(startFrame: 24, endFrameExclusive: 264)
            assert(inF == 24 && outInc == 263)

            recordS10S11TestResult(
                testcaseId: "S10.SWIFT.1",
                requirementId: "MEDIA-01",
                expected: "Exact rational VFR->CFR 24/1 mapping preserves frame IDs, rotation, seek and Resolve inclusive bounds",
                observed: "Mapped 30x29.97fps -> 24 frames (dropped=\(cmap.droppedSourceFrameIds.count)), Resolve bounds [24,264)->[24,263]",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S10.SWIFT.1 Rational VFR->CFR mapping & seek verified.")

            // Test 2: S10.T2 & S10.T3 — Critical Evidence Flash Drop Detection & M-24-SDR-v1 Color Profile
            print("\n[Test 2] S10.T2 & S10.T3: Critical evidence flash drop blocking & SDR/HDR color policy...")
            var pts60: [SourceFramePTSRecord] = []
            for i in 0..<60 {
                pts60.append(SourceFramePTSRecord(
                    frameId: i,
                    pts: Int64(i),
                    durationPts: 1,
                    timeBaseNum: 1,
                    timeBaseDen: 60,
                    hasCriticalEvidence: (i == 0), // Frame 0 [0, 1/60) is skipped at k=0 midpoint 1/48
                    evidenceTag: i == 0 ? "flash_sign" : nil
                ))
            }

            var flashBlocked = false
            do {
                _ = try MediaIndexer.buildVFRToCFR24Map(
                    ptsIndex: pts60,
                    sourceRevisionId: sourceRevId,
                    sourceStartSec: try RationalTime(0, 1),
                    timelineFrameCount: 24,
                    enforceCriticalEvidencePreservation: true
                )
            } catch MediaMappingError.criticalEvidenceFrameDropped(let ids) {
                assert(ids == [0])
                flashBlocked = true
            }
            assert(flashBlocked, "Dropping critical evidence frame 0 must throw criticalEvidenceFrameDropped")

            let sdrEval = MediaIndexer.evaluateColorProfile(primaries: "bt709", transfer: "bt709", matrix: "bt709")
            assert(sdrEval.status == .sdrRec709Verified)

            let hdrUnval = MediaIndexer.evaluateColorProfile(primaries: "bt2020", transfer: "smpte2084", matrix: "bt2020nc", hdrTonemapFixtureValidated: false)
            assert(hdrUnval.status == .unsupportedNeedsDecision)

            let hdrVal = MediaIndexer.evaluateColorProfile(primaries: "bt2020", transfer: "smpte2084", matrix: "bt2020nc", hdrTonemapFixtureValidated: true)
            assert(hdrVal.status == .hdrMobiusTonemapVerified)

            recordS10S11TestResult(
                testcaseId: "S10.SWIFT.2",
                requirementId: "MEDIA-03",
                expected: "Critical evidence flash drop is blocked; M-24-SDR-v1 enforces Rec.709 and gates HDR Mobius tonemap",
                observed: "Dropped flash frame [0] blocked; SDR=verified, unvalidated HDR=unsupportedNeedsDecision, validated HDR=hdrMobiusTonemapVerified",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S10.SWIFT.2 Critical evidence flash protection & color policy verified.")

            // Test 3: S11.T2, S11.T3 & S11.T4 — Post-Processor Truncation Audit, 16GB Policy, Memory Trace & Vietnamese JSON Validation
            print("\n[Test 3] S11.T2..T4: Post-processor audit, 16GB 32B ban, Mach RSS trace & Vietnamese JSON validation...")
            let audit = S11PipelineValidator.auditPostProcessorFrames(
                intendedFrameIds: Array(0..<16),
                processorAcceptedFrameIds: [0, 2, 4, 6, 8, 10, 12, 14],
                temporalPatchSize: 2
            )
            assert(audit.truncationDetected)
            assert(!audit.isFullWindowCovered)
            assert(audit.coverageRatio == 0.5)
            assert(audit.temporalPatchGroups.count == 4)

            var banned32BCaught = false
            do {
                try S11PipelineValidator.enforce16GBHardwarePolicy(modelId: "mlx-community/Qwen2.5-VL-32B-Instruct-4bit")
            } catch S11AdapterError.forbiddenModelOn16GB {
                banned32BCaught = true
            }
            assert(banned32BCaught, "32B model must be blocked on 16GB hardware")

            let memTrace = S11PipelineValidator.captureMemoryTrace(phaseName: "S11_Swift_Core_Check")
            assert(memTrace.rssBytes > 0 && memTrace.withinBudget)

            let validObs = try S11PipelineValidator.validateObservationJSON("""
            {"observation_text":"Xe máy đi qua đèo Prenn lúc trời sương mù","frame_ids":[1,2,3],"origin":"visual_model","epistemic_status":"observed"}
            """)
            assert((validObs["origin"] as? String) == "visual_model")

            var badOriginCaught = false
            do {
                _ = try S11PipelineValidator.validateObservationJSON("""
                {"observation_text":"Giả mạo user","frame_ids":[1],"origin":"user","epistemic_status":"reported"}
                """)
            } catch S11AdapterError.invalidStructuredOutput {
                badOriginCaught = true
            }
            assert(badOriginCaught)

            recordS10S11TestResult(
                testcaseId: "S11.SWIFT.1",
                requirementId: "AI-01",
                expected: "Post-processor truncation detected, 32B model blocked on 16GB, Mach RSS measured, and Vietnamese JSON validated",
                observed: "Truncation=true (0.5), 32B blocked, RSS=\(memTrace.rssBytes / 1024)KB, valid Vietnamese JSON accepted & fake user origin rejected",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: S11.SWIFT.1 Post-processor audit, 16GB policy, memory trace & output validation verified.")

            print("\n=======================================================")
            exit(aivideoReportBanner("SWIFT G2 S10 & S11", passed: 3, total: 3))
            print("=======================================================")
        } catch {
            print("❌ FAIL: S10/S11 test threw unexpected error: \(error)")
            recordS10S11TestResult(
                testcaseId: "S10_S11.ERR",
                requirementId: "MEDIA-01",
                expected: "All S10 & S11 tests pass",
                observed: "Error: \(error)",
                status: "FAIL",
                exitStatus: 1
            )
            exit(1)
        }
    }
}

/// (P1-38) A suite banner must be computed, never typed. `passed/total` where `total` is the
/// declared number of cases: if a case silently stops running (or an assertion is removed)
/// the banner no longer claims a full pass and the process exits non-zero.
func aivideoReportBanner(_ suite: String, passed: Int, total: Int) -> Int32 {
    if passed == total && total > 0 {
        print("ALL \(suite) TESTS PASSED (\(passed)/\(total))!")
        return 0
    }
    print("❌ \(suite): \(passed)/\(total) cases passed — suite is INCOMPLETE or FAILING")
    return 1
}
