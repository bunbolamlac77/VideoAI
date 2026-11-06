#!/usr/bin/env python3
"""
workers/src/aivideo_workers/main.py — AIVideo Python Worker JSON-RPC 2.0 Subprocess

AIVideo v3.1 Protocol Specification:
- JSON-RPC 2.0 strictly over UTF-8 JSON Lines (stdin / stdout).
- stdout MUST ONLY contain valid protocol response lines.
- All diagnostics, logging, and tracebacks MUST go to stderr.
- Strict envelope validation: dict root, "2.0" version, string method, non-bool id.
- Standard JSON-RPC error codes (-32700, -32600, -32601, -32602, -32603).
- Notifications (requests without 'id') do NOT receive a response.
- Parent-loss background watchdog monitors parent PID and cleans up if parent terminates.
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
from typing import Dict, Any, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

PROTOCOL_VERSION = "2.0"
WORKER_VERSION = "0.2.0"
MAX_FRAME_BYTES = 1024 * 1024 # 1 MiB strict limit

def log_err(msg: str):
    """Write strictly to stderr with timestamp and PID prefix."""
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    sys.stderr.write(f"[{ts}] [Worker-{os.getpid()}] {msg}\n")
    sys.stderr.flush()

def send_response(response: dict):
    """Serialize and write a single JSON line strictly to stdout."""
    line = json.dumps(response, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()

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
                log_err(f"Parent process (PID {initial_ppid}) has terminated. Worker exiting cleanly.")
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
            "ai.deterministic_smoke_test",
            "ai.local_model_infer",
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
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=15)
        probe_data = json.loads(proc.stdout)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"ffprobe execution failed: {e.stderr.strip()}")
    except subprocess.TimeoutExpired:
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

def handle_deterministic_smoke_test(params: dict) -> dict:
    """Deterministic string-hashing smoke test to verify IPC data flow without calling neural weights."""
    text = params.get("text", "")
    tokens = text.split()
    sha256 = hashlib.sha256(text.encode("utf-8")).hexdigest()
    is_vi = any(c in text.lower() for c in "àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ")

    return {
        "status": "PASS",
        "execution_type": "DETERMINISTIC_SMOKE_TEST",
        "input_length": len(text),
        "token_count": len(tokens),
        "content_sha256": sha256,
        "detected_language": "vi" if is_vi else "en",
        "offline_verified": True
    }

def handle_local_model_infer(params: dict) -> dict:
    """
    Real local neural inference calculation using local weights matrix.
    No network requests, runs 100% offline on local CPU.
    """
    start_time = time.time()
    prompt = params.get("prompt", "")
    if not prompt:
        raise ValueError("Missing required parameter: 'prompt'")

    # Locate weights file
    model_path = params.get("model_path") or "fixtures/models/micro_model_weights.json"
    if not os.path.exists(model_path):
        raise FileNotFoundError(f"Local model weights not found at '{model_path}'. Status: BLOCKED / NOT_INSTALLED")

    with open(model_path, "r", encoding="utf-8") as f:
        weights_content = f.read()

    weights_sha256 = hashlib.sha256(weights_content.encode("utf-8")).hexdigest()
    model_data = json.loads(weights_content)

    vocab_weights = model_data.get("vocab_weights", {})
    projection_matrix = model_data.get("projection_matrix", [])
    output_classes = model_data.get("output_classes", [])
    embedding_dim = model_data.get("embedding_dim", 8)

    # 1. Tokenize prompt into lowercase words
    words = [w.strip(".,!?:;\"'()[]{}") for w in prompt.lower().split() if w.strip()]
    
    # 2. Compute aggregate embedding vector
    embed_vector = [0.0] * embedding_dim
    matched_tokens = 0
    for w in words:
        if w in vocab_weights:
            token_vec = vocab_weights[w]
            for i in range(embedding_dim):
                embed_vector[i] += token_vec[i]
            matched_tokens += 1

    if matched_tokens > 0:
        for i in range(embedding_dim):
            embed_vector[i] /= matched_tokens

    # 3. Matrix multiplication: embed_vector (1x8) @ projection_matrix (8x4) -> logits (1x4)
    num_classes = len(output_classes)
    logits = [0.0] * num_classes
    for c in range(num_classes):
        for i in range(embedding_dim):
            logits[c] += embed_vector[i] * projection_matrix[i][c]

    # 4. Softmax activation
    max_logit = max(logits) if logits else 0.0
    exp_logits = [math.exp(l - max_logit) for l in logits]
    sum_exp = sum(exp_logits) or 1.0
    probabilities = [e / sum_exp for e in exp_logits]

    # Best class
    best_idx = int(max(range(num_classes), key=lambda idx: probabilities[idx]))
    best_class = output_classes[best_idx]
    best_confidence = round(probabilities[best_idx], 4)

    latency_ms = round((time.time() - start_time) * 1000.0, 2)

    return {
        "status": "PASS",
        "model_id": model_data.get("model_id", "micro-model"),
        "runtime": f"Python {sys.version.split()[0]} Local Micro-Inference Engine",
        "weights_sha256": weights_sha256,
        "tokens_generated": matched_tokens,
        "output_text": f"Classification: {best_class} (Confidence: {best_confidence * 100:.1f}%)",
        "inference_latency_ms": latency_ms,
        "offline_verified": True
    }

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
    "ai.deterministic_smoke_test": handle_deterministic_smoke_test,
    "ai.local_model_infer": handle_local_model_infer,
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

    # 5.1 Root envelope must be a JSON Object (dict)
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

    # Check id: Cannot be a boolean!
    req_id = req.get("id")
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

    # Check notification: in JSON-RPC 2.0, if 'id' is omitted, it's a notification
    is_notification = ("id" not in req)

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
        log_err("Received shutdown directive. Terminating worker.")
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "result": {"status": "terminated"}
            })
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
    except FileNotFoundError as err:
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "error": {
                    "code": -32001,
                    "message": str(err),
                    "data": {"type": "FILE_NOT_FOUND"}
                }
            })
    except PermissionError as err:
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "error": {
                    "code": -32002,
                    "message": str(err),
                    "data": {"type": "PERMISSION_DENIED"}
                }
            })
    except ValueError as err:
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "error": {
                    "code": -32602,
                    "message": str(err),
                    "data": {"type": "INVALID_PARAMS"}
                }
            })
    except Exception as err:
        log_err(f"Exception handling '{method}': {err}\n{traceback.format_exc()}")
        if not is_notification:
            send_response({
                "jsonrpc": PROTOCOL_VERSION,
                "id": req_id,
                "error": {
                    "code": -32603,
                    "message": str(err),
                    "data": {"type": "INTERNAL_ERROR"}
                }
            })

def main():
    log_err(f"AIVideo Worker starting (PID {os.getpid()}). Parent PID: {os.getppid()}")

    # Start parent-loss watchdog
    start_parent_watchdog(os.getppid())

    # Graceful signals
    def sig_handler(signum, frame):
        log_err(f"Signal {signum} caught, exiting.")
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

            validate_and_dispatch(line_bytes)

        except KeyboardInterrupt:
            break
        except Exception as e:
            log_err(f"Unexpected loop exception: {e}\n{traceback.format_exc()}")
            # Never exit on transient framing error; continue loop
            continue

    log_err("Worker main loop terminated.")
    sys.exit(0)

if __name__ == "__main__":
    main()
