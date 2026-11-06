#!/usr/bin/env python3
"""
AIVideo Python Worker — JSON-RPC 2.0 Subprocess
Operating Protocol: JSON-RPC 2.0 over UTF-8 JSON Lines (stdin/stdout)
Rule: stdout MUST ONLY contain valid JSON-RPC responses. All logging goes to stderr.
"""

import sys
import os
import json
import subprocess
import signal
import time
import hashlib
import traceback

PROTOCOL_VERSION = "2.0"
WORKER_VERSION = "0.1.0"

def log(msg: str):
    """Log strictly to stderr to prevent polluting stdout JSON-RPC stream."""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    sys.stderr.write(f"[{timestamp}] [Worker-{os.getpid()}] {msg}\n")
    sys.stderr.flush()

def send_response(response: dict):
    """Serialize and write a single JSON line to stdout."""
    line = json.dumps(response, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()

def handle_initialize(params: dict) -> dict:
    return {
        "status": "ready",
        "worker_name": "aivideo_worker",
        "worker_version": WORKER_VERSION,
        "protocol_version": PROTOCOL_VERSION,
        "worker_pid": os.getpid(),
        "python_version": sys.version.split()[0],
        "capabilities": [
            "media.probe",
            "system.ping",
            "ai.local_infer_test"
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

    # Validate file existence and access
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Source file does not exist: {file_path}")
    if not os.access(file_path, os.R_OK):
        raise PermissionError(f"Permission denied reading file: {file_path}")

    # Run ffprobe
    cmd = [
        "ffprobe",
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
                "avg_frame_rate": s.get("avg_frame_rate"),
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

def handle_local_infer_test(params: dict) -> dict:
    """
    Spike local inference simulation verifying zero cloud calls and deterministic execution.
    """
    input_text = params.get("text", "")
    # Deterministic local hash and mock token embeddings
    tokens = input_text.split()
    content_hash = hashlib.sha256(input_text.encode("utf-8")).hexdigest()
    
    return {
        "status": "success",
        "mode": "100%_LOCAL_OFFLINE",
        "input_length": len(input_text),
        "token_count": len(tokens),
        "content_sha256": content_hash,
        "synthetic_analysis": {
            "language": "vi" if any(c in input_text for c in "àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ") else "en",
            "summary_claims_count": max(1, len(tokens) // 5),
            "offline_verified": True
        }
    }

METHODS = {
    "initialize": handle_initialize,
    "system.ping": handle_ping,
    "media.probe": handle_media_probe,
    "ai.local_infer_test": handle_local_infer_test,
}

def main():
    log("AIVideo worker process starting up...")

    def signal_handler(signum, frame):
        log(f"Received signal {signum}, exiting cleanly.")
        sys.exit(0)

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                log("EOF received on stdin, shutting down worker.")
                break

            line = line.strip()
            if not line:
                continue

            try:
                req = json.loads(line)
            except json.JSONDecodeError as err:
                log(f"Invalid JSON received: {err}")
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": None,
                    "error": {
                        "code": -32700,
                        "message": f"Parse error: {str(err)}"
                    }
                })
                continue

            req_id = req.get("id")
            method = req.get("method")
            params = req.get("params", {})

            if method == "shutdown":
                log("Received shutdown request. Terminating.")
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "result": {"status": "terminated"}
                })
                break

            handler = METHODS.get(method)
            if not handler:
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "error": {
                        "code": -32601,
                        "message": f"Method not found: {method}"
                    }
                })
                continue

            try:
                result = handler(params)
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "result": result
                })
            except FileNotFoundError as err:
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
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "error": {
                        "code": -32002,
                        "message": str(err),
                        "data": {"type": "PERMISSION_DENIED"}
                    }
                })
            except Exception as err:
                log(f"Error handling method {method}: {err}\n{traceback.format_exc()}")
                send_response({
                    "jsonrpc": PROTOCOL_VERSION,
                    "id": req_id,
                    "error": {
                        "code": -32000,
                        "message": str(err),
                        "data": {"traceback": traceback.format_exc()}
                    }
                })

        except KeyboardInterrupt:
            log("KeyboardInterrupt caught, shutting down.")
            break
        except Exception as e:
            log(f"Unexpected loop exception: {e}")
            break

    log("AIVideo worker process exited cleanly.")
    sys.exit(0)

if __name__ == "__main__":
    main()
