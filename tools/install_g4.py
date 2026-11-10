#!/usr/bin/env python3
"""Guarded idempotent G4 installer, compatible with the audited G3 layout."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def patch(path: str, before: str, after: str) -> None:
    file = ROOT / path
    current = file.read_text(encoding="utf-8")
    if after in current:
        print("ALREADY_PATCHED", path)
        return
    if current.count(before) != 1:
        raise RuntimeError("Refusing to patch unexpected layout: " + path)
    file.write_text(current.replace(before, after, 1), encoding="utf-8")
    print("PATCHED", path)


def main():
    # Keep the caller's latest G3 wrapper rather than replacing it with an old copy.
    main_worker = "workers/src/aivideo_workers/main.py"
    patch(main_worker,
          "from aivideo_workers import g3_rpc_safe as g3\n",
          "from aivideo_workers import g3_rpc_safe as g3\n"
          "from aivideo_workers import g4_stage, g4_resolve\n"
          "from aivideo_workers.g4_core import technical_qc\n")
    patch(main_worker,
          '        "g3.metrics.script_ready",\n',
          '        "g3.metrics.script_ready",\n'
          '        "g4.caption.stage", "g4.timeline.build",\n'
          '        "g4.render.start", "g4.render.inspect", "g4.preview.technical_qc",\n')
    patch(main_worker,
          '    "g3.metrics.script_ready": g3.script_ready_metrics,\n',
          '    "g3.metrics.script_ready": g3.script_ready_metrics,\n'
          '    "g4.caption.stage": g4_stage.stage_captioned_clip,\n'
          '    "g4.timeline.build": g4_resolve.build,\n'
          '    "g4.render.start": g4_resolve.render_start,\n'
          '    "g4.render.inspect": g4_resolve.render_inspect,\n'
          '    "g4.preview.technical_qc": lambda params: technical_qc(\n'
          '        params["preview_path"], params["preview_sha256"], params["total_frames"]),\n')
    app = "apps/macos/Sources/AIVideoApp.swift"
    patch(app, "    private var publicationService: ArtifactPublicationService?",
          "    var publicationService: ArtifactPublicationService? // shared S08 actor for G4")
    patch(app, "                    G3ConsoleView(state: state)",
          "                    G3ConsoleView(state: state)\n                    G4ConsoleView(state: state)")
    build = "tools/build_macos_app.sh"
    patch(build, "  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \\\n",
          "  packages/AIVideoCore/Sources/Storage/G3ApprovalGuard.swift \\\n"
          "  packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift \\\n"
          "  packages/AIVideoCore/Sources/Storage/G4S21Guard.swift \\\n")
    patch(build, "  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \\\n",
          "  packages/AIVideoCore/Sources/Publication/ArtifactPublisher.swift \\\n"
          "  packages/AIVideoCore/Sources/Publication/G4FilePublisher.swift \\\n")
    patch(build, "  apps/macos/Sources/G3ConsoleView.swift \\\n",
          "  apps/macos/Sources/G3ConsoleView.swift \\\n"
          "  apps/macos/Sources/G4ConsoleView.swift \\\n")
    client = "packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift"
    patch(client, '        proc.environment = env\n', '''        // A single app-owned G4 staging/journal root. Never derive it from RPC.
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let g4 = support.appendingPathComponent("AIVideo/G4", isDirectory: true)
            try FileManager.default.createDirectory(
                at: g4, withIntermediateDirectories: true
            )
            env["AIVIDEO_G4_WORK_ROOT"] = g4.path
        }
        proc.environment = env
''')


if __name__ == "__main__":
    main()
