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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

PROTOCOL_VERSION = "2.0"
WORKER_VERSION = "0.2.1"
MAX_FRAME_BYTES = 1024 * 1024 # 1 MiB strict limit

# Tracked child subprocesses spawned by this worker
_TRACKED_CHILD_PIDS: Set[int] = set()
_CHILD_LOCK = threading.Lock()

def register_child_pid(pid: int):
    with _CHILD_LOCK:
        _TRACKED_CHILD_PIDS.add(pid)

def unregister_child_pid(pid: int):
    with _CHILD_LOCK:
        _TRACKED_CHILD_PIDS.discard(pid)

def cleanup_child_subprocesses():
    """Cleanly terminate only subprocesses tracked by this worker."""
    with _CHILD_LOCK:
        pids = list(_TRACKED_CHILD_PIDS)

    for pid in pids:
        if is_pid_alive(pid):
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass

    # Wait up to 1.0 second for child processes to exit
    deadline = time.time() + 1.0
    for pid in pids:
        while time.time() < deadline and is_pid_alive(pid):
            time.sleep(0.05)
        if is_pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
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
            "ai.model_status",
            "ai.local_infer_test",
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
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        register_child_pid(proc.pid)
        try:
            stdout, stderr = proc.communicate(timeout=15)
        finally:
            unregister_child_pid(proc.pid)

        if proc.returncode != 0:
            raise RuntimeError(f"ffprobe execution failed: {stderr.strip()}")
        probe_data = json.loads(stdout)
    except subprocess.TimeoutExpired:
        if proc:
            proc.kill()
            unregister_child_pid(proc.pid)
        raise TimeoutError(f"ffprobe timed out after 15s for file: {file_path}")

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

METHODS = {
    "initialize": handle_initialize,
    "system.ping": handle_ping,
    "media.probe": handle_media_probe,
    "ai.model_status": handle_model_status,
    "ai.local_infer_test": handle_local_infer_test,
    "ai.local_model_infer": handle_local_infer_test,
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
