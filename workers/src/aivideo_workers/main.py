#!/usr/bin/env python3
"""G0-G3 stdio RPC entrypoint with guarded G3 methods."""
import sys
from pathlib import Path

_CURRENT = Path(__file__).resolve()

for _directory in (
    _CURRENT.parent,
    _CURRENT.parent.parent,
):
    if str(_directory) not in sys.path:
        sys.path.insert(
            0,
            str(_directory),
        )

from aivideo_workers import main_g2 as legacy
from aivideo_workers import g3_rpc_safe as g3
from aivideo_workers import g4_stage, g4_resolve
from aivideo_workers.g4_core import technical_qc
from aivideo_workers import g5_final, g5_capabilities, g5_release_audit, g5_release_guards

_legacy_initialize = legacy.handle_initialize


def handle_initialize(params: dict) -> dict:
    result = _legacy_initialize(params)
    existing = list(
        result.get("capabilities", [])
    )

    result["capabilities"] = list(
        dict.fromkeys(
            existing + [
                "g3.story.generate",
                "g3.story.edit",
                "g3.voice.trial",
                "g3.cut.search",
                "g3.cut.stage",
                "g3.approval.propose",
                "g3.metrics.script_ready",
                "g4.caption.stage",
                "g4.timeline.build",
                "g4.render.start",
                "g4.render.inspect",
                "g4.preview.technical_qc",
                "g5.caption.stage_4k",
                "g5.timeline.build_4k",
                "g5.render.start_4k",
                "g5.render.inspect_4k",
                "g5.final.technical_qc",
                "g5.handoff.fork",
                "g5.capability.evaluate",
                "g5.photo.match",
                "g5.events.partial_order",
                "g5.audit.final_vs_sources",
                "g5.preferences.manage",
                "g5.comedy.align_cues",
                "g5.fault.run_suite",
                "g5.eval.e0_e1_accounting",
                "g5.release.manifest",
            ]
        )
    )

    result["g3_approval_policy"] = (
        "CORE_REVERIFICATION_REQUIRED"
    )
    result["g5_release_policy"] = (
        "S21_PREVIEW_AND_S22_CORE_REVERIFICATION_REQUIRED"
    )

    return result


legacy.METHODS.update({
    "initialize": handle_initialize,
    "g3.story.generate": g3.generate_story,
    "g3.story.edit": g3.edit_story,
    "g3.voice.trial": g3.voice_trial,
    "g3.cut.search": g3.search_cuts,
    "g3.cut.stage": g3.stage_cut_plan,
    "g3.approval.propose": g3.approval_proposal,
    "g3.metrics.script_ready": g3.script_ready_metrics,
    "g4.caption.stage": g4_stage.stage_captioned_clip,
    "g4.timeline.build": g4_resolve.build,
    "g4.render.start": g4_resolve.render_start,
    "g4.render.inspect": g4_resolve.render_inspect,
    "g4.preview.technical_qc": lambda params: technical_qc(
        params["preview_path"], params["preview_sha256"], params["total_frames"]),
    "g5.caption.stage_4k": g5_final.stage_final_captioned_clip,
    "g5.timeline.build_4k": g5_final.build_final,
    "g5.render.start_4k": g5_final.render_final_start,
    "g5.render.inspect_4k": g5_final.render_final_inspect,
    "g5.final.technical_qc": lambda params: g5_final.final_technical_qc(
        params["final_path"], params["final_sha256"], params["total_frames"]),
    "g5.handoff.fork": g5_final.fork_manual_handoff,
    "g5.capability.evaluate": g5_release_guards.capability,
    "g5.photo.match": g5_release_guards.photo_match,
    "g5.events.partial_order": g5_capabilities.build_partial_order_event_graph,
    "g5.audit.final_vs_sources": g5_capabilities.audit_final_against_sources,
    "g5.preferences.manage": g5_capabilities.manage_preference_profile,
    "g5.comedy.align_cues": g5_capabilities.align_comedy_timing_cues,
    "g5.fault.run_suite": g5_release_audit.run_commit_boundary_fault_suite,
    "g5.eval.e0_e1_accounting": g5_release_audit.evaluate_e0_e1_accounting,
    "g5.release.manifest": g5_release_audit.generate_release_handover_manifest,
})

METHODS = legacy.METHODS
MAX_FRAME_BYTES = legacy.MAX_FRAME_BYTES
WORKER_VERSION = legacy.WORKER_VERSION
PROTOCOL_VERSION = legacy.PROTOCOL_VERSION

handle_g2_analyze_source = (
    legacy.handle_g2_analyze_source
)
handle_media_index_and_proxy = (
    legacy.handle_media_index_and_proxy
)
handle_resolve_status = (
    legacy.handle_resolve_status
)
handle_local_infer_test = (
    legacy.handle_local_infer_test
)

validate_and_dispatch = (
    legacy.validate_and_dispatch
)
main = legacy.main


if __name__ == "__main__":
    main()
