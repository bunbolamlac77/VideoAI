#!/usr/bin/env python3
"""
workers/src/aivideo_workers/main.py — AIVideo Python Worker JSON-RPC 2.0 Subprocess

AIVideo v3.1 Protocol Specification:
- JSON-RPC 2.0 strictly over UTF-8 JSON Lines (stdin / stdout).
- stdout MUST ONLY contain valid protocol response lines.
- All diagnostics, logging, and tracebacks MUST go to stderr.
- Strict envelope validation: dict root, "2.0" version, string method, valid string/int id.
- Reject invalid id types (bool, object, array).
- Bounded framing with full discard of oversized line tails (no partial tail dispatch).
- Standard JSON-RPC error codes (-32700, -32600, -32601, -32602, -32603).
- Notifications (requests without 'id') do NOT receive a response.
- Parent-loss background watchdog monitors parent PID and cleans up tracked child subprocesses.
- 100% offline local inference with verifiable local weights checksum.
"""

import sys
import os
import json
import subprocess
import signal
import time
import math
import hashlib
import threading
import traceback
from pathlib import Path
from typing import Callable, Dict, Any, Optional, Set
from aivideo_workers.child_process import (
    cleanup_child_subprocesses,
    is_pid_alive,
    register_child_pid,
    register_child_process,
    unregister_child_pid,
    unregister_child_process,
)

_FILE_DIR = os.path.dirname(os.path.abspath(__file__))
_SRC_DIR = os.path.dirname(_FILE_DIR)
for _p in (_FILE_DIR, _SRC_DIR):
    if _p not in sys.path:
        sys.path.insert(0, _p)

PROTOCOL_VERSION = "2.0"
WORKER_VERSION = "0.2.1"


def _reject_duplicate_keys(pairs):
    """Reject ambiguous JSON-RPC envelopes (Python json ordinarily takes last key)."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_nonfinite_constant(value):
    raise ValueError(f"Non-JSON numeric constant: {value}")


def _assert_json_numbers_finite(obj):
    """Catch numerical overflow, e.g. 1e999 parsed to float('inf')."""
    if isinstance(obj, float):
        if not math.isfinite(obj):
            raise ValueError("Non-finite JSON number")
    elif isinstance(obj, dict):
        for value in obj.values():
            _assert_json_numbers_finite(value)
    elif isinstance(obj, list):
        for value in obj:
            _assert_json_numbers_finite(value)

MAX_FRAME_BYTES = 1024 * 1024 # 1 MiB strict limit

def log_err(msg: str):
    """Write strictly to stderr with timestamp and PID prefix. Protected against BrokenPipeError."""
    try:
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        sys.stderr.write(f"[{ts}] [Worker-{os.getpid()}] {msg}\n")
        sys.stderr.flush()
    except (BrokenPipeError, OSError):
        pass

_RPC_OUT = None  # private dup of the original stdout fd; set by _isolate_protocol_stdout()


def _isolate_protocol_stdout():
    """Third-party libs (DaVinciResolveScript, mlx, tqdm) print to stdout, which corrupts JSON-RPC
    framing and makes the Swift client fail every pending request. Keep a private handle on the
    real stdout for RPC frames and point fd 1 / sys.stdout at stderr for everything else."""
    global _RPC_OUT
    if _RPC_OUT is not None:
        return
    try:
        sys.stdout.flush()
        rpc_fd = os.dup(1)
        os.dup2(2, 1)
        _RPC_OUT = os.fdopen(rpc_fd, "w", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr
    except OSError:
        _RPC_OUT = None


def send_response(response: dict):
    """Serialize and write a single JSON line to the RPC channel. Protected against BrokenPipeError."""
    try:
        try:
            line = json.dumps(response, ensure_ascii=False, allow_nan=False)
        except (TypeError, ValueError):
            # Never emit malformed JSON, even when an adapter returns NaN or a
            # non-serializable object. Surface the failure to the RPC caller.
            line = json.dumps({
                "jsonrpc": PROTOCOL_VERSION,
                "id": response.get("id"),
                "error": {"code": -32603, "message": "Worker result is not valid JSON"},
            }, ensure_ascii=False, allow_nan=False)
        if len(line.encode("utf-8")) + 1 > MAX_FRAME_BYTES and response.get("result") is not None:
            # Never emit a frame the client must reject; fail only this request, explicitly.
            line = json.dumps({
                "jsonrpc": PROTOCOL_VERSION,
                "id": response.get("id"),
                "error": {
                    "code": -32010,
                    "message": f"Result exceeds {MAX_FRAME_BYTES} byte frame limit.",
                    "data": {"kind": "RESULT_TOO_LARGE"},
                },
            }, ensure_ascii=False)
        out = _RPC_OUT or sys.stdout
        out.write(line + "\n")
        out.flush()
    except (BrokenPipeError, OSError):
        pass

def start_parent_watchdog(initial_ppid: int):
    """Background supervisor thread to detect parent termination even if main thread is busy."""
    def watchdog_loop():
        while True:
            time.sleep(0.5)
            curr_ppid = os.getppid()
            if curr_ppid != initial_ppid or not is_pid_alive(initial_ppid):
                try:
                    log_err(f"Parent process (PID {initial_ppid}) has terminated. Cleaning up and exiting.")
                except Exception:
                    pass
                cleanup_child_subprocesses()
                os._exit(0)

    t = threading.Thread(target=watchdog_loop, daemon=True, name="ParentWatchdog")
    t.start()

# MARK: - RPC Method Handlers

def handle_initialize(params: dict) -> dict:
    return {
        "status": "ready",
        "worker_name": "aivideo_worker",
        "worker_version": WORKER_VERSION,
        "protocol_version": PROTOCOL_VERSION,
        "worker_pid": os.getpid(),
        "python_version": sys.version.split()[0],
        "capabilities": [
            "system.ping",
            "media.probe",
            "media.index_and_proxy",
            "ai.model_status",
            "ai.local_infer_test",
            "g2.analyze_source",
            "resolve.status",
            "resolve.spike_timeline"
        ]
    }

def handle_ping(params: dict) -> dict:
    return {
        "status": "pong",
        "server_time": time.time()
    }

def handle_media_probe(params: dict) -> dict:
    file_path = params.get("file_path")
    if not file_path:
        raise ValueError("Missing required parameter: 'file_path'")

    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Source file does not exist: {file_path}")
    if not os.access(file_path, os.R_OK):
        raise PermissionError(f"Permission denied reading file: {file_path}")

    # Resolve ffprobe path
    ffprobe_bin = "/opt/homebrew/bin/ffprobe"
    if not os.path.exists(ffprobe_bin):
        import shutil
        ffprobe_bin = shutil.which("ffprobe") or "ffprobe"

    cmd = [
        ffprobe_bin,
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        file_path
    ]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True
    )

    register_child_process(proc)

    try:
        stdout, stderr = proc.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        stdout, stderr = proc.communicate()
        raise TimeoutError(
            f"ffprobe timed out after 15s: {file_path}"
        )
    finally:
        unregister_child_process(proc)

    if proc.returncode != 0:
        raise RuntimeError(f"ffprobe execution failed: {stderr.strip()}")
    probe_data = json.loads(stdout)

    fmt = probe_data.get("format", {})
    streams = probe_data.get("streams", [])

    video_streams = []
    audio_streams = []

    for s in streams:
        codec_type = s.get("codec_type")
        if codec_type == "video":
            video_streams.append({
                "index": s.get("index"),
                "codec_name": s.get("codec_name"),
                "width": s.get("width"),
                "height": s.get("height"),
                "r_frame_rate": s.get("r_frame_rate"),
                "duration": s.get("duration"),
                "pix_fmt": s.get("pix_fmt")
            })
        elif codec_type == "audio":
            audio_streams.append({
                "index": s.get("index"),
                "codec_name": s.get("codec_name"),
                "sample_rate": s.get("sample_rate"),
                "channels": s.get("channels"),
                "duration": s.get("duration")
            })

    return {
        "file_path": file_path,
        "format_name": fmt.get("format_name"),
        "duration_seconds": float(fmt.get("duration", 0.0)),
        "size_bytes": int(fmt.get("size", 0)),
        "bit_rate": int(fmt.get("bit_rate", 0)) if fmt.get("bit_rate") else None,
        "video_streams": video_streams,
        "audio_streams": audio_streams
    }

def handle_model_status(params: dict) -> dict:
    """Preflight check for local model and runtime readiness. Strictly offline, no downloads."""
    import local_model
    return local_model.check_status(params)

def handle_local_infer_test(params: dict) -> dict:
    """
    Real local neural inference calculation using local_model adapter.
    Runs 100% offline via MLX-LM backend.
    """
    import local_model
    return local_model.run_inference(params)

def handle_resolve_status(params: dict) -> dict:
    import resolve_adapter
    return resolve_adapter.check_resolve_status()

def handle_resolve_spike(params: dict) -> dict:
    import resolve_adapter
    drp_path = params.get("output_drp_path") or params.get("drp_path") or "fixtures/AIVideo_G0_Spike.drp"
    force_fresh = params.get("force_fresh_run", False)
    return resolve_adapter.run_g0_spike(output_drp_path=drp_path, force_fresh_run=force_fresh)


def handle_media_index_and_proxy(params: dict) -> dict:
    """S10 RPC: Probes presentation-order PTS index and generates CFR 24fps SDR Rec.709 proxy + conform map."""
    from pathlib import Path
    from aivideo_workers.media_indexer import generate_proxy_and_mapping, probe_and_index_real_video

    file_path = params.get("file_path")
    if not file_path:
        raise ValueError("Missing required parameter: 'file_path'")
    proxy_out = params.get("proxy_output_path")
    source_rev_id = params.get("source_revision_id") or "rev-source-001"
    fallback_sdr = bool(params.get("fallback_sdr_if_untagged", False))
    has_hdr_fixture = bool(params.get("has_validated_hdr_tonemap_fixture", False))
    if proxy_out:
        art = generate_proxy_and_mapping(
            source_video_path=Path(file_path),
            proxy_output_path=Path(proxy_out),
            source_revision_id=source_rev_id,
            target_height=int(params.get("target_height", 540)),
            has_validated_hdr_tonemap_fixture=has_hdr_fixture,
            fallback_sdr_if_untagged=fallback_sdr,
        )
        return art.to_dict()
    return probe_and_index_real_video(
        Path(file_path),
        fallback_sdr_if_untagged=fallback_sdr,
        has_validated_hdr_tonemap_fixture=has_hdr_fixture,
    )


def _estimate_source_fps(pts_entries) -> float:
    """Best-effort source fps from the PTS index, used only by the motion prefilter."""
    if len(pts_entries) < 2:
        return 24.0
    delta = int(pts_entries[1].pts) - int(pts_entries[0].pts)
    first = pts_entries[0]
    if delta <= 0 or first.time_base_num <= 0:
        return 24.0
    return float(first.time_base_den) / float(first.time_base_num) / float(delta)


def handle_g2_analyze_source(params: dict, *, inspector_factory: Optional[Callable[[Path], Callable[[Any], dict]]] = None) -> dict:
    """
    S10..S14 End-to-End G2 Worker RPC (`g2.analyze_source`):
    1. Probes real video file via ffprobe (`probe_and_index_real_video`).
    2. Checks whether `P-VISION-DEV-v1` (`Qwen3-VL-4B-Instruct-4bit`) is installed offline on disk.
    3. Runs `FullFrameAnalysisPipeline.run_or_resume_analysis` (returns `blocked_model_unavailable` with 0% coverage
       and 0 fabricated observations when the visual model is not installed; decodes real source window frames and
       runs offline visual window inspection when installed).
    4. Parses optional user brief via `parse_user_brief` and evaluates claims via `evaluate_claim_decision_table` (S13).

    `inspector_factory` is a Python-level test seam only. It is deliberately NOT
    read from `params`: a JSON-RPC caller must never be able to substitute the
    vision model and still be told `vision_model_installed = True` (D03).
    """
    if "_inspector_fn" in params:
        raise ValueError(
            "INSPECTOR_OVERRIDE_FORBIDDEN: g2.analyze_source does not accept an injectable "
            "inspector over JSON-RPC; vision provenance must come from the installed offline model."
        )

    from pathlib import Path
    import tempfile
    from aivideo_workers.media_indexer import (
        SourceFrameEntry,
        _compute_file_sha256,
        declared_source_frame_count,
        probe_and_index_real_video,
    )
    from aivideo_workers.model_installation import inspect_model_installation
    from aivideo_workers.pipeline_adapters import PipelineAdapterError, S11ModelRegistryAndAdapters
    from aivideo_workers.full_frame_pipeline import (
        BoundedPipelineConfig,
        FullFrameAnalysisPipeline,
        compact_coverage_ledger_payload,
        generate_overlapping_windows,
    )
    from aivideo_workers.prefilter import (
        build_window_prefilter,
        config_from_params,
        scan_motion_profile,
    )
    from aivideo_workers.semantic_verifier import (
        decompose_causal_or_compound_statement,
        evaluate_claim_support_and_use,
        parse_raw_brief_to_drafts,
    )

    file_path = params.get("file_path")
    if not file_path:
        raise ValueError("Missing required parameter: 'file_path'")
    src_path = Path(file_path)
    if not src_path.is_file():
        raise FileNotFoundError(f"Source file does not exist: {file_path}")

    source_rev_id = str(params.get("source_revision_id") or "00000000-0000-4000-8000-000000000101")
    workday_id = str(params.get("workday_id") or "00000000-0000-4000-8000-000000000002")
    brief_text = str(params.get("brief_text") or "").strip()

    probed = probe_and_index_real_video(
        src_path,
        fallback_sdr_if_untagged=bool(params.get("fallback_sdr_if_untagged", False)),
        has_validated_hdr_tonemap_fixture=bool(params.get("has_validated_hdr_tonemap_fixture", False)),
    )
    pts_entries = [
        SourceFrameEntry(
            frame_id=int(f["frame_id"]),
            pts=int(f["pts"]),
            duration_pts=int(f["duration_pts"]),
            time_base_num=int(f["time_base_num"]),
            time_base_den=int(f["time_base_den"]),
            key_frame=bool(f.get("key_frame", False)),
        )
        for f in probed["pts_index"]
    ]
    src_sha256 = _compute_file_sha256(src_path)
    declared_frames = declared_source_frame_count(probed, indexed_count=len(pts_entries))

    # Check if the S11 visual model is installed offline and build the real window inspector.
    # 2026-11-10 fix (D14): the worker and the release preflight now share one definition
    # of "installed" (model_installation.inspect_model_installation).
    models_root_override = params.get("models_root_dir")
    s11_reg = S11ModelRegistryAndAdapters(models_root_dir=models_root_override)
    vision_installed = False
    inspector_fn = None
    weights_verification = "missing"
    if inspector_factory is not None:
        # Python-level test seam only (never reachable from JSON-RPC).
        inspector_fn = inspector_factory(src_path)
        vision_installed = True
        weights_verification = "test_seam"
    else:
        install = inspect_model_installation(models_root_override)
        weights_verification = str(install["state"])
        if install["state"] in ("verified", "present_unverified"):
            try:
                s11_reg.preflight_adapter_offline(
                    role="visual_analysis_primary",
                    required_files=["config.json", "model.safetensors"],
                )
                sample_count = int(params.get("vision_sample_count", 2))
                if not 1 <= sample_count <= 16:
                    raise ValueError("vision_sample_count must be between 1 and 16")
                inspector_fn = s11_reg.build_offline_visual_window_inspector(
                    src_path, sample_count=sample_count
                )
                vision_installed = True
            except PipelineAdapterError:
                vision_installed = False
                inspector_fn = None

    # 2026-11-10 prefilter (opt-in): choose which windows are worth the vision model.
    prefilter_cfg = config_from_params(params.get("prefilter"))
    window_prefilter = None
    prefilter_signature = None
    prefilter_summary = {"enabled": False}
    if prefilter_cfg.enabled and vision_installed:
        source_fps = _estimate_source_fps(pts_entries)
        profile = scan_motion_profile(src_path, config=prefilter_cfg, source_fps=source_fps)
        windows_for_prefilter = generate_overlapping_windows(
            pts_entries,
            window_size=BoundedPipelineConfig().window_size_frames,
            overlap=BoundedPipelineConfig().window_overlap_frames,
        )
        window_prefilter = build_window_prefilter(windows_for_prefilter, profile, prefilter_cfg)
        prefilter_signature = {
            **prefilter_cfg.fingerprint_payload(),
            "profile_sha256": profile["profile_sha256"],
        }
        prefilter_summary = {
            "enabled": True,
            "sample_fps": prefilter_cfg.sample_fps,
            "motion_threshold": prefilter_cfg.motion_threshold,
            "profile_sha256": profile["profile_sha256"],
            "profile_sample_count": profile["sample_count"],
        }

    ckpt_dir = Path(params.get("checkpoint_dir") or tempfile.gettempdir())
    ckpt_path = ckpt_dir / f"g2_ckpt_{source_rev_id[:8]}_{src_sha256[:8]}.json"

    pipeline = FullFrameAnalysisPipeline(BoundedPipelineConfig())
    # When vision_installed is False, window_inspector_fn is None -> returns blocked_model_unavailable!
    ledger, raw_obs, audio_res, findings = pipeline.run_or_resume_analysis(
        source_revision_id=source_rev_id,
        source_sha256=src_sha256,
        pts_index=pts_entries,
        total_declared_source_frames=declared_frames,
        checkpoint_path=ckpt_path,
        has_audio_stream=bool(probed.get("has_audio_stream", False)),
        window_inspector_fn=inspector_fn,
        window_prefilter=window_prefilter,
        prefilter_signature=prefilter_signature,
    )

    claims_out = []
    reviews_out = []
    if brief_text:
        parsed_brief = parse_raw_brief_to_drafts(
            brief_revision_id="brief-live-01",
            workday_id=workday_id,
            raw_brief_text=brief_text,
        )
        for idx, stmt in enumerate(parsed_brief):
            if stmt.item_kind == "event_fact":
                proposals = decompose_causal_or_compound_statement(
                    compound_id=f"claim-live-{idx:02d}",
                    workday_id=workday_id,
                    raw_statement=stmt.raw_span_text,
                    origin="user",
                    epistemic_status="reported",
                    review_status="unreviewed",
                    is_critical=True,
                )
                for p in proposals:
                    sup, dec = evaluate_claim_support_and_use(
                        claim=p,
                        evidence_edges=[],
                        evidence_scope_revision_id=f"scope-{src_sha256[:8]}",
                        narrative_type="reported_by_user",
                    )
                    claims_out.append({
                        "claim_id": p.claim_id,
                        "text": p.predicate_text,
                        "origin": p.origin,
                        "epistemic_status": p.epistemic_status,
                        "review_status": p.review_status,
                        "support_status": sup.support_status,
                        "allowed_use": dec.allowed_use,
                        "requires_targeted_review": dec.requires_targeted_review,
                    })
                    if dec.requires_targeted_review:
                        reviews_out.append({
                            "evidence_scope_revision_id": f"scope-{src_sha256[:8]}",
                            "evidence_kind": "brief_span",
                            "is_critical": p.is_critical,
                            "question_text": f"Xác nhận thông tin từ brief: '{p.predicate_text}' (Visual model: {ledger.detailed_pass_status})?",
                        })

    return {
        "source_revision_id": source_rev_id,
        "source_sha256": src_sha256,
        "vision_model_installed": vision_installed,
        "visual_weights_verification": weights_verification,
        "prefilter": {
            **prefilter_summary,
            "skipped_count": ledger.prefilter_skipped_count,
            "analyzed_count": ledger.total_windows - ledger.prefilter_skipped_count,
            "skipped_window_indices": ledger.skipped_window_indices,
        },
        "color_decision": probed["color_decision"],
        "coverage_ledger": compact_coverage_ledger_payload(ledger.to_dict()),
        "raw_observations_count": len(raw_obs),
        "raw_observations": [o.to_dict() for o in raw_obs],
        "audio_branch_state": audio_res.audio_state,
        "omission_findings_count": len(findings),
        "claims": claims_out,
        "review_items": reviews_out,
    }


METHODS = {
    "initialize": handle_initialize,
    "system.ping": handle_ping,
    "media.probe": handle_media_probe,
    "media.index_and_proxy": handle_media_index_and_proxy,
    "ai.model_status": handle_model_status,
    "ai.local_infer_test": handle_local_infer_test,
    "ai.local_model_infer": handle_local_infer_test,
    "g2.analyze_source": handle_g2_analyze_source,
    "resolve.status": handle_resolve_status,
    "resolve.spike_timeline": handle_resolve_spike,
}

# MARK: - Request Validation & Execution Loop

def validate_and_dispatch(line_bytes: bytes):
    # Enforce strict 1 MiB framing limit
    if len(line_bytes) > MAX_FRAME_BYTES:
        send_response({
            "jsonrpc": PROTOCOL_VERSION,
            "id": None,
            "error": {
                "code": -32600,
                "message": f"Invalid Request: Message size {len(line_bytes)} exceeds 1 MiB limit."
            }
        })
        return

    # Parse JSON
    try:
        raw_str = line_bytes.decode("utf-8").strip()
    except UnicodeDecodeError as err:
        send_response({
            "jsonrpc": PROTOCOL_VERSION,
            "id": None,
            "error": {
                "code": -32700,
                "message": f"Parse error: Invalid UTF-8 encoding: {str(err)}"
            }
        })
        return

    if not raw_str:
        return

    try:
        req = json.loads(
            raw_str,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
        _assert_json_numbers_finite(req)
    except (json.JSONDecodeError, ValueError) as err:
        send_response({
            "jsonrpc": PROTOCOL_VERSION,
            "id": None,
            "error": {
                "code": -32700,
                "message": f"Parse error: {str(err)}"
            }
        })
        return

    # Root envelope must be a JSON Object (dict)
    if not isinstance(req, dict):
        send_response({
            "jsonrpc": PROTOCOL_VERSION,
            "id": None,
            "error": {
                "code": -32600,
                "message": f"Invalid Request: Root must be a JSON object, got {type(req).__name__}."
            }
        })
        return

    # Extract safe id for initial protocol error responses
    raw_id = req.get("id")
    safe_id = raw_id if (isinstance(raw_id, (str, int)) and not isinstance(raw_id, bool)) else None

    # Check jsonrpc version
    if req.get("jsonrpc") != PROTOCOL_VERSION:
        send_response({
            "jsonrpc": PROTOCOL_VERSION,
            "id": safe_id,
            "error": {
                "code": -32600,
                "message": f"Invalid Request: 'jsonrpc' must be exactly '{PROTOCOL_VERSION}'."
            }
        })
        return

    # Check method
    method = req.get("method")
    if not isinstance(method, str) or not method:
        send_response({
            "jsonrpc": PROTOCOL_VERSION,
            "id": safe_id,
            "error": {
                "code": -32600,
                "message": "Invalid Request: 'method' must be a non-empty string."
            }
        })
        return

    # Check id: MUST NOT be a boolean, object (dict), or array (list)
    has_id = ("id" in req)
    req_id = req.get("id")

    if has_id and req_id is not None:
        if isinstance(req_id, bool):
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": None,
                "error": {
                    "code": -32600,
                    "message": "Invalid Request: 'id' cannot be a boolean."
                }
            })
            return
        if isinstance(req_id, (dict, list)):
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": None,
                "error": {
                    "code": -32600,
                    "message": f"Invalid Request: 'id' cannot be an {type(req_id).__name__}."
                }
            })
            return
        if not isinstance(req_id, (str, int)):
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": None,
                "error": {
                    "code": -32600,
                    "message": f"Invalid Request: 'id' must be a string or integer, got {type(req_id).__name__}."
                }
            })
            return

    # Check notification: in JSON-RPC 2.0, if 'id' is omitted, it's a notification
    is_notification = (not has_id)

    # Check params
    params = req.get("params")
    if params is not None and not isinstance(params, dict):
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "error": {
                    "code": -32602,
                    "message": "Invalid params: Only structured named dictionary parameters are supported."
                }
            })
        return

    if params is None:
        params = {}

    # Handle shutdown notification / request
    if method == "shutdown":
        log_err("Received shutdown directive. Cleaning up and terminating worker.")
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "result": {"status": "terminated"}
            })
        cleanup_child_subprocesses()
        sys.exit(0)

    # Dispatch method
    handler = METHODS.get(method)
    if not handler:
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "error": {
                    "code": -32601,
                    "message": f"Method not found: '{method}'."
                }
            })
        return

    try:
        result = handler(params)
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "result": result
            })
    except Exception as err:
        import local_model
        if isinstance(err, local_model.ModelError):
            if not is_notification:
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "error": err.to_rpc_error()
                })
            return

        if isinstance(err, FileNotFoundError):
            if not is_notification:
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "error": {
                        "code": -32001,
                        "message": str(err),
                        "data": {"kind": "FILE_NOT_FOUND"}
                    }
                })
            return

        if isinstance(err, PermissionError):
            if not is_notification:
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "error": {
                        "code": -32002,
                        "message": str(err),
                        "data": {"kind": "PERMISSION_DENIED"}
                    }
                })
            return

        if isinstance(err, ValueError):
            if not is_notification:
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "error": {
                        "code": -32602,
                        "message": str(err),
                        "data": {"kind": "INVALID_PARAMS"}
                    }
                })
            return

        log_err(f"Exception handling '{method}': {err}\n{traceback.format_exc()}")
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "error": {
                    "code": -32603,
                    "message": str(err),
                    "data": {"kind": "INTERNAL_ERROR"}
                }
            })

def main():
    _isolate_protocol_stdout()
    log_err(f"AIVideo Worker starting (PID {os.getpid()}). Parent PID: {os.getppid()}")

    # Start parent-loss watchdog
    start_parent_watchdog(os.getppid())

    # Graceful signals
    def sig_handler(signum, frame):
        log_err(f"Signal {signum} caught, cleaning up child processes and exiting.")
        cleanup_child_subprocesses()
        sys.exit(0)

    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)

    stdin_buf = sys.stdin.buffer

    while True:
        try:
            line_bytes = stdin_buf.readline(MAX_FRAME_BYTES + 1)
            if not line_bytes:
                # EOF reached on stdin
                log_err("EOF on stdin. Worker terminating cleanly.")
                break

            # If the line length exceeded MAX_FRAME_BYTES:
            # We must discard the entire oversized line up to newline, and NEVER execute the tail!
            if len(line_bytes) > MAX_FRAME_BYTES:
                log_err(f"Frame exceeded {MAX_FRAME_BYTES} bytes. Discarding rest of oversized line.")
                if not line_bytes.endswith(b"\n"):
                    # Read and discard chunks until newline or EOF
                    discard_chunk_size = 65536
                    while True:
                        next_chunk = stdin_buf.readline(discard_chunk_size)
                        if not next_chunk or next_chunk.endswith(b"\n"):
                            break

                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": None,
                    "error": {
                        "code": -32600,
                        "message": f"Invalid Request: Message size exceeds {MAX_FRAME_BYTES} bytes limit."
                    }
                })
                continue

            validate_and_dispatch(line_bytes)

        except KeyboardInterrupt:
            break
        except Exception as e:
            log_err(f"Unexpected loop exception: {e}\n{traceback.format_exc()}")
            continue

    cleanup_child_subprocesses()
    log_err("Worker main loop terminated.")
    sys.exit(0)

if __name__ == "__main__":
    main()
