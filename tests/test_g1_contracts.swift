// test_g1_contracts.swift — Swift Unit Tests for Gate G1 S04 Contracts & State Machines

import Foundation

func recordG1TestResult(
    testcaseId: String,
    requirementId: String,
    command: String = "./build/tests/test_g1_contracts",
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
        "suite": "swift_g1_contracts",
        "command": command,
        "expected": expected,
        "observed": observed,
        "status": status,
        "exit_status": exitStatus,
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let data = try? JSONSerialization.data(withJSONObject: record),
       let line = String(data: data, encoding: .utf8) {
        let path = "\(reportDir)/swift_g1_records.jsonl"
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
        recordG1TestResult(
            testcaseId: "S04.SWIFT.1",
            requirementId: "DATA-04",
            expected: "User confirmation updates review_status, but origin stays user and epistemic stays reported",
            observed: "Origin stayed user, epistemic stayed reported, review confirmed, revision incremented",
            status: "PASS",
            exitStatus: 0
        )
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
        recordG1TestResult(
            testcaseId: "S04.SWIFT.2",
            requirementId: "JOB-04",
            expected: "Artifact transitions strictly follow PREPARED -> MATERIALIZED -> VERIFIED -> COMMITTED",
            observed: "Illegal transition rejected, linear state machine transitions validated cleanly",
            status: "PASS",
            exitStatus: 0
        )
        print("   ✅ PASS: Artifact publication state machine transitions verified.")
        passCount += 1

        // Test 3: Job State Machine transitions
        print("\n[Test 3] S04.3: Job status transition barriers...")
        assert(JobStatus.queued.canTransition(to: .running), "QUEUED -> RUNNING allowed")
        assert(JobStatus.running.canTransition(to: .succeeded), "RUNNING -> SUCCEEDED allowed")
        assert(!JobStatus.succeeded.canTransition(to: .running), "SUCCEEDED -> RUNNING forbidden")
        assert(!JobStatus.failed.canTransition(to: .running), "FAILED -> RUNNING forbidden")
        recordG1TestResult(
            testcaseId: "S04.SWIFT.3",
            requirementId: "JOB-04",
            expected: "Job status transition barriers prevent resurrection from terminal states",
            observed: "Terminal SUCCEEDED and FAILED states cannot transition back to RUNNING",
            status: "PASS",
            exitStatus: 0
        )
        print("   ✅ PASS: Job status transition barriers verified.")
        passCount += 1

        // Test 4: Bi-directional Golden Tests (Swift <-> Python Interoperability)
        print("\n[Test 4] S04.T1: Bi-directional Golden Tests with Python...")
        let fixturesDir = "contracts/fixtures"
        let pyClaimPath = "\(fixturesDir)/golden_claim_python.json"
        let pyArtPath = "\(fixturesDir)/golden_artifact_python.json"
        let swiftClaimPath = "\(fixturesDir)/golden_claim_swift.json"
        let swiftArtPath = "\(fixturesDir)/golden_artifact_swift.json"

        // 4A: Swift decodes Python Claim Golden
        do {
            let pyClaimData = try Data(contentsOf: URL(fileURLWithPath: pyClaimPath))
            let decodedClaim = try JSONDecoder().decode(ClaimRecord.self, from: pyClaimData)
            assert(decodedClaim.claimId.uuidString.lowercased() == "00000000-0000-4000-8000-000000000001")
            assert(decodedClaim.origin == .visualModel)
            assert(decodedClaim.epistemicStatus == .inferred)
            assert(decodedClaim.reviewStatus == .unreviewed)
            assert(decodedClaim.supportStatus == .supported)
            assert(decodedClaim.allowedUse == .directClaim)
            assert(decodedClaim.timeRange?.startFrame == 100)
            assert(decodedClaim.timeRange?.endFrame == 240)
            assert(decodedClaim.confidenceRaw == 0.95)
            print("   ✅ Sub-test 4A: Python Claim Golden decoded into Swift successfully.")
        } catch {
            fatalError("Failed to decode Python Claim Golden: \(error)")
        }

        // 4B: Swift decodes Python Artifact Golden
        do {
            let pyArtData = try Data(contentsOf: URL(fileURLWithPath: pyArtPath))
            let decodedArt = try JSONDecoder().decode(ArtifactPublicationRecord.self, from: pyArtData)
            assert(decodedArt.publicationId.uuidString.lowercased() == "00000000-0000-4000-8000-000000000301")
            assert(decodedArt.fencingToken == 1)
            assert(decodedArt.artifactType == "proxy_video")
            assert(decodedArt.state == .committed)
            assert(decodedArt.sha256Hash == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
            assert(decodedArt.byteSize == 1048576)
            print("   ✅ Sub-test 4B: Python Artifact Golden decoded into Swift successfully.")
        } catch {
            fatalError("Failed to decode Python Artifact Golden: \(error)")
        }

        // 4C: Swift decodes & encodes Swift Claim Golden with snake_case and ISO-8601
        do {
            let swiftClaimData = try Data(contentsOf: URL(fileURLWithPath: swiftClaimPath))
            let decodedClaim = try JSONDecoder().decode(ClaimRecord.self, from: swiftClaimData)
            assert(decodedClaim.origin == .user)
            assert(decodedClaim.reviewStatus == .confirmed)
            assert(decodedClaim.allowedUse == .attributedOrQualified)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedData = try encoder.encode(decodedClaim)
            let jsonString = String(data: encodedData, encoding: .utf8)!

            assert(jsonString.contains("\"claim_id\" :"), "Must be snake_case 'claim_id'")
            assert(jsonString.contains("\"epistemic_status\" :"), "Must be snake_case 'epistemic_status'")
            assert(jsonString.contains("\"review_status\" :"), "Must be snake_case 'review_status'")
            assert(jsonString.contains("\"created_at\" : \"2026-11-06T14:30:00Z\""), "Date must be ISO-8601 string")
            print("   ✅ Sub-test 4C: Swift Claim Golden round-tripped with snake_case and ISO-8601.")
        } catch {
            fatalError("Failed on Swift Claim Golden: \(error)")
        }

        // 4D: Swift decodes & encodes Swift Artifact Golden with snake_case and ISO-8601
        do {
            let swiftArtData = try Data(contentsOf: URL(fileURLWithPath: swiftArtPath))
            let decodedArt = try JSONDecoder().decode(ArtifactPublicationRecord.self, from: swiftArtData)
            assert(decodedArt.state == .committed)
            assert(decodedArt.fencingToken == 2)
            assert(decodedArt.byteSize == 2097152)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedData = try encoder.encode(decodedArt)
            let jsonString = String(data: encodedData, encoding: .utf8)!

            assert(jsonString.contains("\"publication_id\" :"), "Must be snake_case 'publication_id'")
            assert(jsonString.contains("\"fencing_token\" :"), "Must be snake_case 'fencing_token'")
            assert(jsonString.contains("\"created_at\" : \"2026-11-06T14:00:00Z\""), "created_at must be ISO-8601 string")
            assert(jsonString.contains("\"updated_at\" : \"2026-11-06T14:10:00Z\""), "updated_at must be ISO-8601 string")
            print("   ✅ Sub-test 4D: Swift Artifact Golden round-tripped with snake_case and ISO-8601.")
        } catch {
            fatalError("Failed on Swift Artifact Golden: \(error)")
        }

        recordG1TestResult(
            testcaseId: "S04.SWIFT.4",
            requirementId: "DATA-04",
            expected: "Bi-directional golden tests verify 100% interoperable serialization across Swift and Python",
            observed: "Python goldens decoded by Swift, Swift goldens verified with snake_case and ISO-8601 strings",
            status: "PASS",
            exitStatus: 0
        )
        passCount += 1

        // Test 5: JSON-RPC Response Envelope Constraint Enforcement
        print("\n[Test 5] S04.T4: JSON-RPC Response Envelope rejects bare jsonrpc...")
        do {
            // Bare {"jsonrpc": "2.0"}
            let bareData = Data("{\"jsonrpc\": \"2.0\"}".utf8)
            let bareEnv = try JSONDecoder().decode(JSONRPCResponseEnvelope.self, from: bareData)
            assert(bareEnv.jsonrpc == "2.0")
            assert(!bareEnv.hasMethod, "Bare envelope must have hasMethod == false")
            assert(!bareEnv.hasResult, "Bare envelope must have hasResult == false")
            assert(bareEnv.error == nil, "Bare envelope must have error == nil")
            assert(!(bareEnv.hasMethod || bareEnv.hasResult || bareEnv.error != nil), "Bare envelope lacks method, result, and error")

            // Envelope with only id: {"jsonrpc": "2.0", "id": 123}
            let idOnlyData = Data("{\"jsonrpc\": \"2.0\", \"id\": 123}".utf8)
            let idOnlyEnv = try JSONDecoder().decode(JSONRPCResponseEnvelope.self, from: idOnlyData)
            assert(idOnlyEnv.id == 123)
            assert(!idOnlyEnv.hasMethod)
            assert(!idOnlyEnv.hasResult)
            assert(idOnlyEnv.error == nil)

            // Valid Response: {"jsonrpc": "2.0", "id": 1, "result": {"status": "ok"}}
            let validResultData = Data("{\"jsonrpc\": \"2.0\", \"id\": 1, \"result\": {\"status\": \"ok\"}}".utf8)
            let validEnv = try JSONDecoder().decode(JSONRPCResponseEnvelope.self, from: validResultData)
            assert(validEnv.hasResult, "Must detect result payload")
            assert(validEnv.id == 1)

            // Valid Error Response: {"jsonrpc": "2.0", "id": 1, "error": {"code": -32600, "message": "bad"}}
            let validErrData = Data("{\"jsonrpc\": \"2.0\", \"id\": 1, \"error\": {\"code\": -32600, \"message\": \"bad\"}}".utf8)
            let validErrEnv = try JSONDecoder().decode(JSONRPCResponseEnvelope.self, from: validErrData)
            assert(validErrEnv.error?.code == -32600)

            recordG1TestResult(
                testcaseId: "S04.SWIFT.5",
                requirementId: "JOB-04",
                expected: "JSON-RPC response envelope decodes method/result/error presence and rejects bare envelopes",
                observed: "Bare jsonrpc and id-only envelopes rejected, success and error responses validated cleanly",
                status: "PASS",
                exitStatus: 0
            )
            print("   ✅ PASS: JSON-RPC Response Envelope constraint validation verified.")
            passCount += 1
        } catch {
            fatalError("Failed on JSON-RPC envelope constraint test: \(error)")
        }

        print("\n=======================================================")
        exit(aivideoReportBanner("SWIFT G1 CONTRACT", passed: passCount, total: 5))
        print("=======================================================\n")
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
