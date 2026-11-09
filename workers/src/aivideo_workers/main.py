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
from typing import Dict, Any, Optional, Set

_FILE_DIR = os.path.dirname(os.path.abspath(__file__))
_SRC_DIR = os.path.dirname(_FILE_DIR)
for _p in (_FILE_DIR, _SRC_DIR):
    if _p not in sys.path:
        sys.path.insert(0, _p)

PROTOCOL_VERSION = "2.0"
WORKER_VERSION = "0.2.1"
MAX_FRAME_BYTES = 1024 * 1024 # 1 MiB strict limit

# Tracked child subprocesses spawned by this worker (handles + process groups)
_TRACKED_CHILD_PROCS: Dict[int, Optional[subprocess.Popen]] = {}
_CHILD_LOCK = threading.Lock()

def register_child_process(proc: subprocess.Popen):
    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS[proc.pid] = proc

def unregister_child_process(proc: subprocess.Popen):
    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS.pop(proc.pid, None)

def register_child_pid(pid: int):
    with _CHILD_LOCK:
        if pid not in _TRACKED_CHILD_PROCS:
            _TRACKED_CHILD_PROCS[pid] = None

def unregister_child_pid(pid: int):
    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS.pop(pid, None)

def cleanup_child_subprocesses():
    """Cleanly terminate only subprocesses tracked and verified owned by this worker."""
    with _CHILD_LOCK:
        tracked = list(_TRACKED_CHILD_PROCS.items())

    for pid, proc in tracked:
        # Check ownership and state
        if proc is not None:
            if proc.poll() is not None:
                continue
        elif not is_pid_alive(pid):
            continue

        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass

    # Wait up to 1.0 second for child processes to exit
    deadline = time.time() + 1.0
    for pid, proc in tracked:
        while time.time() < deadline:
            if proc is not None:
                if proc.poll() is not None:
                    break
            elif not is_pid_alive(pid):
                break
            time.sleep(0.05)

        still_alive = proc.poll() is None if proc is not None else is_pid_alive(pid)
        if still_alive:
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

        # Reap zombie
        if proc is not None:
            try:
                proc.poll()
            except Exception:
                pass

def log_err(msg: str):
    """Write strictly to stderr with timestamp and PID prefix. Protected against BrokenPipeError."""
    try:
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        sys.stderr.write(f"[{ts}] [Worker-{os.getpid()}] {msg}\n")
        sys.stderr.flush()
    except (BrokenPipeError, OSError):
        pass

def send_response(response: dict):
    """Serialize and write a single JSON line strictly to stdout. Protected against BrokenPipeError."""
    try:
        line = json.dumps(response, ensure_ascii=False)
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        pass

def is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

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


def handle_g2_analyze_source(params: dict) -> dict:
    """
    S10..S14 End-to-End G2 Worker RPC (`g2.analyze_source`):
    1. Probes real video file via ffprobe (`probe_and_index_real_video`).
    2. Checks whether `P-VISION-DEV-v1` (`Qwen3-VL-4B-Instruct-4bit`) is installed offline on disk.
    3. Runs `FullFrameAnalysisPipeline.run_or_resume_analysis` (returns `blocked_model_unavailable` with 0% coverage
       and 0 fabricated observations when the visual model is not installed; decodes real source window frames and
       runs offline visual window inspection when installed).
    4. Parses optional user brief via `parse_user_brief` and evaluates claims via `evaluate_claim_decision_table` (S13).
    """
    from pathlib import Path
    import tempfile
    from aivideo_workers.media_indexer import (
        SourceFrameEntry,
        _compute_file_sha256,
        probe_and_index_real_video,
    )
    from aivideo_workers.pipeline_adapters import PipelineAdapterError, S11ModelRegistryAndAdapters
    from aivideo_workers.full_frame_pipeline import BoundedPipelineConfig, FullFrameAnalysisPipeline
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

    # Check if S11 visual model adapter is installed offline and build real window inspector
    models_root_override = params.get("models_root_dir")
    s11_reg = S11ModelRegistryAndAdapters(models_root_dir=models_root_override)
    vision_installed = False
    inspector_fn = None
    try:
        s11_reg.preflight_adapter_offline(
            role="visual_analysis_primary",
            required_files=["config.json", "model.safetensors"],
        )
        vision_installed = True
        inspector_fn = params.get("_inspector_fn") or s11_reg.build_offline_visual_window_inspector(src_path)
    except PipelineAdapterError:
        vision_installed = False
        inspector_fn = None

    ckpt_dir = Path(params.get("checkpoint_dir") or tempfile.gettempdir())
    ckpt_path = ckpt_dir / f"g2_ckpt_{source_rev_id[:8]}_{src_sha256[:8]}.json"

    pipeline = FullFrameAnalysisPipeline(BoundedPipelineConfig())
    # When vision_installed is False, window_inspector_fn is None -> returns blocked_model_unavailable!
    ledger, raw_obs, audio_res, findings = pipeline.run_or_resume_analysis(
        source_revision_id=source_rev_id,
        source_sha256=src_sha256,
        pts_index=pts_entries,
        total_declared_source_frames=len(pts_entries),
        checkpoint_path=ckpt_path,
        has_audio_stream=bool(probed.get("has_audio_stream", False)),
        window_inspector_fn=inspector_fn,
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
        "color_decision": probed["color_decision"],
        "coverage_ledger": ledger.to_dict(),
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
        req = json.loads(raw_str)
    except json.JSONDecodeError as err:
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

    # Check jsonrpc version
    if req.get("jsonrpc") != PROTOCOL_VERSION:
        send_response({
            "jsonrpc": PROTOCOL_VERSION,
            "id": req.get("id"),
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
            "id": req.get("id"),
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

            # If the line length exceeded MAX_FRAME_BYTES or does not end with newline:
            # We must discard the entire oversized line up to newline, and NEVER execute the tail!
            if len(line_bytes) > MAX_FRAME_BYTES and not line_bytes.endswith(b"\n"):
                log_err(f"Frame exceeded {MAX_FRAME_BYTES} bytes. Discarding rest of oversized line.")
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
