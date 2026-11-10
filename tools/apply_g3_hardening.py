#!/usr/bin/env python3
"""Apply audited G3 S16/S19 hardening patches.

Idempotent, guarded source changes.
Fails on unexpected source layouts.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_one(
    path: str,
    old: str,
    new: str,
) -> None:
    target = ROOT / path
    current = target.read_text(
        encoding="utf-8"
    )

    if new in current:
        print(f"OK already applied: {path}")
        return

    count = current.count(old)

    if count != 1:
        raise RuntimeError(
            f"Refusing unexpected layout in {path}: "
            f"anchor count={count}"
        )

    target.write_text(
        current.replace(old, new, 1),
        encoding="utf-8",
    )
    print(f"PATCHED {path}")


def main() -> None:
    core = (
        "packages/AIVideoCore/Sources/"
        "Storage/G3ProjectStore.swift"
    )

    replace_one(
        core,
        """                claim[1] != "user"
                    || claim[2] == "confirmed"
""",
        """                claim[1] != "user"
                    || (claim[2] == "confirmed" && claim[4] == "attributed_or_qualified")
""",
    )

    replace_one(
        core,
        '''            if let prior = try G3SQL.row(
                db,
                """
                SELECT
                    approval_id,manifest_sha256,
''',
        '''            // Never approve a hash-only plan: verify a COMMITTED S18 cut,
            // its G2 source/mapping chain and measured WAV durations independently.
            try G3ApprovalGuard.verify(
                db: db, projectId: projectId,
                scriptRevisionId: scriptRevisionId,
                candidate: candidate, manifest: manifest
            )

            if let prior = try G3SQL.row(
                db,
                """
                SELECT
                    approval_id,manifest_sha256,
''',
    )

    replace_one(
        core,
        """            if let pubs = manifest[
                "voice_publications"
            ] as? [[String: String]],
            let beats = candidate[
                "beats"
            ] as? [[String: Any]],
            pubs.count == beats.count {
""",
        """            // Legacy approvals lacking a sealed cut receipt are invalid for G4.
            do {
                try G3ApprovalGuard.verify(
                    db: db, projectId: projectId,
                    scriptRevisionId: row[1],
                    candidate: candidate, manifest: manifest
                )
            } catch {
                return nil
            }

            if let pubs = manifest[
                "voice_publications"
            ] as? [[String: String]],
            let beats = candidate[
                "beats"
            ] as? [[String: Any]],
            pubs.count == beats.count {
""",
    )

    build = "tools/build_macos_app.sh"

    replace_one(
        build,
        "  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \\\n",
        "  packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift \\\n"
        "  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \\\n",
    )

    ipc = (
        "packages/AIVideoCore/Sources/"
        "WorkerIPC/WorkerClient.swift"
    )

    replace_one(
        ipc,
        """        proc.environment = env

        let inPipe = Pipe()
""",
        """        // G3 file writes are restricted to an app-owned staging directory.
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let staging = support.appendingPathComponent(
                "AIVideo/G3/staging", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true
            )
            env["AIVIDEO_G3_STAGING_ROOT"] = staging.path
        }
        proc.environment = env

        let inPipe = Pipe()
""",
    )

    ui = "apps/macos/Sources/G3ConsoleView.swift"

    replace_one(
        ui,
        """                                if let first = result.fields?[
                                    "candidates"
                                ]?.elements?.first {
                                    draftJSON = first.json
                                }
""",
        """                                if let first = result.fields?[
                                    "candidates"
                                ]?.elements?.first {
                                    draftJSON = first.json
                                    saved = nil
                                    selected = false
                                    lastProposal = ""
                                    explicitApproval = false
                                }
""",
    )

    replace_one(
        ui,
        """                            ) { _ in
                                saved = nil
                                selected = false
                                explicitApproval = false
                            }
""",
        """                            ) { result in
                                if let edited = result.fields?["candidate"],
                                   result.fields?["status"]?.string == "revalidation_required" {
                                    draftJSON = edited.json
                                }
                                saved = nil
                                selected = false
                                lastProposal = ""
                                explicitApproval = false
                            }
""",
    )

    replace_one(
        ui,
        '    @State private var searchRequest = "{}"\n',
        '    @State private var searchRequest = "{}"\n'
        '    @State private var cutStageRequest = "{}"\n',
    )

    replace_one(
        ui,
        '''                    .disabled(
                        isBusy || !state.isWorkerConnected
                    )
                }

                DisclosureGroup(
                    "S19 — Đề nghị duyệt / phê duyệt"
''',
        '''                    .disabled(
                        isBusy || !state.isWorkerConnected
                    )
                    jsonEditor(
                        "S18 cut plan staging (chưa phải approval)",
                        text: $cutStageRequest,
                        height: 75
                    )
                    Button("Stage cut plan để S08 publish") {
                        Task {
                            await rpc(
                                method: "g3.cut.stage",
                                json: cutStageRequest
                            ) { _ in }
                        }
                    }
                    .disabled(isBusy || !state.isWorkerConnected)
                }

                DisclosureGroup(
                    "S19 — Đề nghị duyệt / phê duyệt"
''',
    )

    replace_one(
        ui,
        '"ready_for_core_transaction_not_approved",',
        '"ready_for_core_reverification_not_approved",',
    )

    test = "tests/test_s19_g3_approval.swift"
    start = (
        "        let approved = try await "
        "store.approveG3Draft(\n"
    )
    end = (
        "        let currentProject = "
        "try await store\n"
    )

    existing = (ROOT / test).read_text(
        encoding="utf-8"
    )

    if (
        "PASS S19.T2: unsealed cut plan is rejected"
        not in existing
    ):
        if (
            existing.count(start) != 1
            or existing.count(end) != 1
        ):
            raise RuntimeError(
                "Swift test changed; update it manually"
            )

        begin = existing.index(start)
        finish = existing.index(end)

        body = """        var acceptedUnsealedPlan = false
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

"""

        (ROOT / test).write_text(
            existing[:begin] + body + existing[finish:],
            encoding="utf-8",
        )
        print(f"PATCHED {test}")
    else:
        print(f"OK already applied: {test}")


if __name__ == "__main__":
    main()
