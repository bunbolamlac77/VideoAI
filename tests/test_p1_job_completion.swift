// tests/test_p1_job_completion.swift — Regression for audit P1-01 (2026-11-11).
//
// `commitPublication` marked the job SUCCEEDED on the first committed artifact, no matter
// how many artifacts the job still owed. The G4/G5 publish flow commits an MP4 *and* its
// provenance (receipt / .drp) under one logical publication, so a crash between the two
// left a "successful" job whose final artifact never existed.
//
// A publication may now declare `expectedPublicationCount`; the job is only SUCCEEDED once
// that many publications are COMMITTED. Jobs that never declare a count keep the previous
// single-artifact behaviour, and the crash-repair path uses the same rule.

import Foundation
import CryptoKit

@main
struct TestP1JobCompletion {
    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func publish(
        store: ProjectStore,
        projectId: UUID,
        jobId: UUID,
        attempt: JobAttemptRecord,
        dir: URL,
        name: String,
        expectedCount: Int
    ) async throws -> ArtifactPublicationRecord {
        let file = dir.appendingPathComponent(name)
        let bytes = Data("artifact \(name)".utf8)
        try bytes.write(to: file)
        let pub = try await store.createPublicationIntent(
            projectId: projectId,
            jobId: jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            artifactType: "g5_final_mp4",
            tempPath: file.path,
            expectedPublicationCount: expectedCount
        )
        _ = try await store.updatePublicationMaterialized(
            publicationId: pub.publicationId,
            jobId: jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            tempPath: file.path
        )
        _ = try await store.updatePublicationVerified(
            publicationId: pub.publicationId,
            jobId: jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            sha256: sha(bytes),
            byteSize: bytes.count
        )
        return try await store.commitPublication(
            publicationId: pub.publicationId,
            jobId: jobId,
            attemptId: attempt.attemptId,
            fencingToken: attempt.fencingToken,
            canonicalPath: file.path
        )
    }

    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1_job_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try ProjectStore(dbURL: dir.appendingPathComponent("store.db"))
        let project = try await store.createProject(name: "P1-01")
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("❌ FAIL: \(message)") } else { print("✅ PASS: \(message)") }
        }

        // 1) A two-artifact job stays RUNNING after the first committed artifact.
        let jobA = try await store.enqueueJob(
            projectId: project.projectId, jobType: "publish_g5", inputFingerprint: "fp-job-a")
        let attA = try await store.allocateAttempt(jobId: jobA.jobId, workerSessionId: "s-a")
        _ = try await publish(
            store: store, projectId: project.projectId, jobId: jobA.jobId, attempt: attA,
            dir: dir, name: "a1.bin", expectedCount: 2)
        let afterFirst = try await store.getJob(id: jobA.jobId)
        check(afterFirst?.status == .running,
              "job with 1/2 artifacts committed is still RUNNING (was SUCCEEDED before the fix)")

        // 2) The second committed artifact completes the job.
        _ = try await publish(
            store: store, projectId: project.projectId, jobId: jobA.jobId, attempt: attA,
            dir: dir, name: "a2.bin", expectedCount: 2)
        let afterSecond = try await store.getJob(id: jobA.jobId)
        check(afterSecond?.status == .succeeded,
              "job with 2/2 artifacts committed is SUCCEEDED")

        // 3) A job that declares only one artifact is unaffected.
        let jobB = try await store.enqueueJob(
            projectId: project.projectId, jobType: "publish_one", inputFingerprint: "fp-job-b")
        let attB = try await store.allocateAttempt(jobId: jobB.jobId, workerSessionId: "s-b")
        _ = try await publish(
            store: store, projectId: project.projectId, jobId: jobB.jobId, attempt: attB,
            dir: dir, name: "b1.bin", expectedCount: 1)
        let jobBState = try await store.getJob(id: jobB.jobId)
        check(jobBState?.status == .succeeded, "single-artifact job is SUCCEEDED after its only artifact")

        // 4) Crash repair respects the declared expectation too.
        let jobC = try await store.enqueueJob(
            projectId: project.projectId, jobType: "publish_g5", inputFingerprint: "fp-job-c")
        let attC = try await store.allocateAttempt(jobId: jobC.jobId, workerSessionId: "s-c")
        let file = dir.appendingPathComponent("c1.bin")
        let bytes = Data("only one of two".utf8)
        try bytes.write(to: file)
        let pubC = try await store.createPublicationIntent(
            projectId: project.projectId, jobId: jobC.jobId,
            attemptId: attC.attemptId, fencingToken: attC.fencingToken,
            artifactType: "g5_final_mp4", tempPath: file.path,
            expectedPublicationCount: 2
        )
        _ = try await store.updatePublicationMaterialized(
            publicationId: pubC.publicationId, jobId: jobC.jobId,
            attemptId: attC.attemptId, fencingToken: attC.fencingToken, tempPath: file.path)
        _ = try await store.updatePublicationVerified(
            publicationId: pubC.publicationId, jobId: jobC.jobId,
            attemptId: attC.attemptId, fencingToken: attC.fencingToken,
            sha256: sha(bytes), byteSize: bytes.count)
        _ = try await store.commitPublication(
            publicationId: pubC.publicationId, jobId: jobC.jobId,
            attemptId: attC.attemptId, fencingToken: attC.fencingToken,
            canonicalPath: file.path, completeJob: false)
        let repaired = try await store.repairJobCompletionFromCommittedPublications(jobId: jobC.jobId)
        let jobCState = try await store.getJob(id: jobC.jobId)
        check(!repaired && jobCState?.status != .succeeded,
              "crash repair does not mark a 1/2 job SUCCEEDED")

        await store.close()
        if failures > 0 {
            print("P1-01 JOB COMPLETION TESTS FAILED (\(failures))")
            exit(1)
        }
        print("P1-01 JOB COMPLETION TESTS PASSED (4/4)")
    }
}
