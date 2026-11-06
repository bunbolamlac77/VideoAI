"""
workers/src/aivideo_workers/local_model.py — Real Local Model Adapter for AIVideo G0

G0 Profile Specification:
- profile_id: g0-text-smoke-v1
- purpose: g0_inference_smoke_only
- model_id: mlx-community/Qwen3-0.6B-4bit
- model_revision: 73e3e38d981303bc594367cd910ea6eb48349da8
- backend: mlx-lm
- max_input_tokens: 1024
- max_output_tokens: 128
- enable_thinking: false
- execution_policy: local_only
- auto_download_during_inference: false

Invariants:
- NO download during inference or preflight status checks.
- Lazy import: missing MLX will not crash handshake or module import.
- Offline environment enforced before backend import.
- Exactly one inference active at a time (Resource lock).
- Token counting after real chat template, bounded input check.
- Structured JSON-RPC error mapping with standard/scoped codes.
"""

import os
import sys
import json
import time
import uuid
import hashlib
import threading
from typing import Dict, Any, Optional, Tuple, List

# MARK: - Offline Environment Configuration
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

G0_PROFILE_ID = "g0-text-smoke-v1"
G0_MODEL_ID = "mlx-community/Qwen3-0.6B-4bit"
G0_MODEL_REVISION = "73e3e38d981303bc594367cd910ea6eb48349da8"
MAX_INPUT_TOKENS = 1024
MAX_OUTPUT_TOKENS = 128

REQUIRED_ARTIFACTS = [
    "config.json",
    "model.safetensors",
    "model.safetensors.index.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "added_tokens.json",
    "special_tokens_map.json",
    "merges.txt",
    "vocab.json"
]

# Single-inference mutex for G0
_INFERENCE_LOCK = threading.Lock()

# MARK: - Scoped Exception Classes

class ModelError(Exception):
    def __init__(self, code: int, kind: str, message: str, details: Optional[str] = None):
        super().__init__(message)
        self.code = code
        self.kind = kind
        self.message = message
        self.details = details or message

    def to_rpc_error(self) -> dict:
        return {
            "code": self.code,
            "message": self.message,
            "data": {
                "kind": self.kind,
                "details": self.details
            }
        }

class ModelNotInstalledError(ModelError):
    def __init__(self, message: str = "Model is not installed.", details: Optional[str] = None):
        super().__init__(-32001, "MODEL_NOT_INSTALLED", message, details)

class ModelIntegrityError(ModelError):
    def __init__(self, message: str = "Model integrity check failed.", details: Optional[str] = None):
        super().__init__(-32002, "MODEL_INTEGRITY_ERROR", message, details)

class ModelPermissionError(ModelError):
    def __init__(self, message: str = "Permission denied accessing model files.", details: Optional[str] = None):
        super().__init__(-32003, "MODEL_PERMISSION_DENIED", message, details)

class RuntimeUnavailableError(ModelError):
    def __init__(self, message: str = "MLX/MLX-LM runtime is unavailable.", details: Optional[str] = None):
        super().__init__(-32004, "RUNTIME_UNAVAILABLE", message, details)

class ResourceBusyError(ModelError):
    def __init__(self, message: str = "Another inference is currently in progress.", details: Optional[str] = None):
        super().__init__(-32005, "RESOURCE_BUSY", message, details)

class InputTooLargeError(ModelError):
    def __init__(self, message: str = "Input tokens exceed max allowed limit (1024).", details: Optional[str] = None):
        super().__init__(-32006, "INPUT_TOO_LARGE", message, details)

class InferenceFailedError(ModelError):
    def __init__(self, message: str = "Model inference failed.", details: Optional[str] = None):
        super().__init__(-32007, "INFERENCE_FAILED", message, details)


# MARK: - Path Resolution Helpers

def resolve_app_support_dir(custom_path: Optional[str] = None) -> str:
    if custom_path and os.path.isdir(custom_path):
        return os.path.abspath(custom_path)
    if "AIVIDEO_APP_SUPPORT" in os.environ and os.path.isdir(os.environ["AIVIDEO_APP_SUPPORT"]):
        return os.path.abspath(os.environ["AIVIDEO_APP_SUPPORT"])
    home = os.path.expanduser("~")
    return os.path.join(home, "Library", "Application Support", "AIVideo")

def resolve_lock_file() -> Optional[str]:
    # 1. Environment variables if provided by .app bundle or test harness
    if "AIVIDEO_CONTRACTS_DIR" in os.environ:
        p = os.path.join(os.environ["AIVIDEO_CONTRACTS_DIR"], "g0_model.lock.json")
        if os.path.isfile(p):
            return os.path.abspath(p)
    if "AIVIDEO_APP_RESOURCES" in os.environ:
        p = os.path.join(os.environ["AIVIDEO_APP_RESOURCES"], "contracts", "g0_model.lock.json")
        if os.path.isfile(p):
            return os.path.abspath(p)

    # 2. Check candidate paths relative to current file and workspace
    file_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        # Explicit workspace relative
        os.path.abspath("contracts/g0_model.lock.json"),
        # Relative to src/aivideo_workers -> ../../../contracts/g0_model.lock.json
        os.path.join(file_dir, "..", "..", "..", "contracts", "g0_model.lock.json"),
        # Relative to aivideo_workers in Contents/Resources/Workers/aivideo_workers/ -> ../../contracts/g0_model.lock.json
        os.path.join(file_dir, "..", "..", "contracts", "g0_model.lock.json"),
        # Relative to Contents/Resources/workers/src/aivideo_workers/ -> ../../../../contracts/g0_model.lock.json
        os.path.join(file_dir, "..", "..", "..", "..", "contracts", "g0_model.lock.json"),
        # Direct sibling contracts
        os.path.join(file_dir, "..", "contracts", "g0_model.lock.json")
    ]
    for p in candidates:
        norm = os.path.normpath(p)
        if os.path.isfile(norm):
            return norm

    # 3. Walk up directory tree to find Contents/Resources/contracts or contracts
    curr = file_dir
    for _ in range(6):
        bundle_cand = os.path.join(curr, "Contents", "Resources", "contracts", "g0_model.lock.json")
        if os.path.isfile(bundle_cand):
            return os.path.normpath(bundle_cand)
        res_cand = os.path.join(curr, "Resources", "contracts", "g0_model.lock.json")
        if os.path.isfile(res_cand):
            return os.path.normpath(res_cand)
        contracts_cand = os.path.join(curr, "contracts", "g0_model.lock.json")
        if os.path.isfile(contracts_cand):
            return os.path.normpath(contracts_cand)
        parent = os.path.dirname(curr)
        if parent == curr:
            break
        curr = parent

    return None

def compute_file_sha256(path: str) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()

def check_runtime_import() -> Tuple[bool, Optional[str], Optional[str]]:
    """Checks if MLX and MLX-LM can be imported without crashing."""
    try:
        import mlx
        import mlx.core as mx
        import mlx_lm
        return True, mlx_lm.__version__, None
    except Exception as e:
        return False, None, str(e)


# MARK: - Preflight Status Check

def check_status(params: Optional[dict] = None) -> dict:
    """
    Evaluates current model and runtime installation state.
    Strictly offline. No downloads, no inference.
    """
    params = params or {}
    profile_id = params.get("profile_id") or G0_PROFILE_ID
    app_support = resolve_app_support_dir(params.get("app_support_path"))

    if profile_id != G0_PROFILE_ID:
        return {
            "status": "not_configured",
            "profile_id": profile_id,
            "model_id": None,
            "model_revision": None,
            "model_path": None,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Unknown profile_id '{profile_id}'. Only '{G0_PROFILE_ID}' is supported for G0.",
            "missing_files": []
        }

    lock_file = resolve_lock_file()
    if not lock_file or not os.path.isfile(lock_file):
        return {
            "status": "not_configured",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": None,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": "Model lock file 'contracts/g0_model.lock.json' not found.",
            "missing_files": []
        }

    try:
        with open(lock_file, "r", encoding="utf-8") as f:
            lock_data = json.load(f)
    except Exception as e:
        return {
            "status": "not_configured",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": None,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Failed reading lock file: {str(e)}",
            "missing_files": []
        }

    # Resolve target model directory
    model_dir = os.path.join(app_support, "Models", "g0-text", G0_MODEL_REVISION)

    # Check installation registry
    reg_file = os.path.join(app_support, "Installations", f"{G0_PROFILE_ID}.json")
    if os.path.isfile(reg_file):
        try:
            with open(reg_file, "r", encoding="utf-8") as rf:
                reg_data = json.load(rf)
                if reg_data.get("model_path"):
                    model_dir = reg_data["model_path"]
        except Exception:
            pass

    if not os.path.isdir(model_dir):
        return {
            "status": "not_installed",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": model_dir,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Model directory does not exist at '{model_dir}'. Run tools/setup_g0_model.py --install.",
            "missing_files": REQUIRED_ARTIFACTS
        }

    # Check required artifact files
    missing_files = []
    unreadable_files = []
    for art in REQUIRED_ARTIFACTS:
        art_path = os.path.join(model_dir, art)
        if not os.path.exists(art_path):
            missing_files.append(art)
        elif not os.access(art_path, os.R_OK):
            unreadable_files.append(art)

    if missing_files:
        return {
            "status": "invalid_assets",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": model_dir,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Model directory is missing required files: {', '.join(missing_files)}",
            "missing_files": missing_files
        }

    if unreadable_files:
        return {
            "status": "invalid_assets",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": model_dir,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Permission denied reading artifacts: {', '.join(unreadable_files)}",
            "missing_files": unreadable_files
        }

    # Lock validation: must be verified, match model_id and model_revision, and contain all required artifact hashes
    if lock_data.get("status") != "verified":
        return {
            "status": "not_configured",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": model_dir,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Model contract lock status is '{lock_data.get('status')}', not 'verified'. Run tools/setup_g0_model.py --install.",
            "missing_files": []
        }

    if lock_data.get("model_id") != G0_MODEL_ID or lock_data.get("model_revision") != G0_MODEL_REVISION:
        return {
            "status": "not_configured",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": model_dir,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Model identity mismatch in lock file: expected '{G0_MODEL_ID}@{G0_MODEL_REVISION}', got '{lock_data.get('model_id')}@{lock_data.get('model_revision')}'.",
            "missing_files": []
        }

    verified_artifacts = lock_data.get("verified_artifacts", {})
    if not verified_artifacts or not all(a in verified_artifacts for a in REQUIRED_ARTIFACTS):
        return {
            "status": "invalid_assets",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": model_dir,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": "Model lock file is missing required checksums for one or more artifacts.",
            "missing_files": [a for a in REQUIRED_ARTIFACTS if a not in verified_artifacts]
        }

    # Verify every required artifact against pinned manifest
    for art_name in REQUIRED_ARTIFACTS:
        art_info = verified_artifacts[art_name]
        expected_hash = art_info.get("sha256")
        expected_size = art_info.get("size_bytes")
        art_path = os.path.join(model_dir, art_name)
        if not os.path.isfile(art_path):
            return {
                "status": "invalid_assets",
                "profile_id": profile_id,
                "model_id": G0_MODEL_ID,
                "model_revision": G0_MODEL_REVISION,
                "model_path": model_dir,
                "python_path": sys.executable,
                "backend_name": "mlx-lm",
                "details": f"Required artifact '{art_name}' not found on disk.",
                "missing_files": [art_name]
            }

        actual_size = os.path.getsize(art_path)
        if expected_size is not None and actual_size != expected_size:
            return {
                "status": "invalid_assets",
                "profile_id": profile_id,
                "model_id": G0_MODEL_ID,
                "model_revision": G0_MODEL_REVISION,
                "model_path": model_dir,
                "python_path": sys.executable,
                "backend_name": "mlx-lm",
                "details": f"Size mismatch for '{art_name}' (expected {expected_size}, got {actual_size})",
                "missing_files": [art_name]
            }

        if expected_hash:
            actual_hash = compute_file_sha256(art_path)
            if actual_hash != expected_hash:
                return {
                    "status": "invalid_assets",
                    "profile_id": profile_id,
                    "model_id": G0_MODEL_ID,
                    "model_revision": G0_MODEL_REVISION,
                    "model_path": model_dir,
                    "python_path": sys.executable,
                    "backend_name": "mlx-lm",
                    "details": f"SHA-256 checksum mismatch for '{art_name}'",
                    "missing_files": [art_name]
                }

    # Verify runtime
    runtime_ok, backend_ver, runtime_err = check_runtime_import()
    if not runtime_ok:
        return {
            "status": "runtime_unavailable",
            "profile_id": profile_id,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_path": model_dir,
            "python_path": sys.executable,
            "backend_name": "mlx-lm",
            "details": f"Failed importing MLX / MLX-LM runtime: {runtime_err}",
            "missing_files": []
        }

    return {
        "status": "available_unloaded",
        "profile_id": profile_id,
        "model_id": G0_MODEL_ID,
        "model_revision": G0_MODEL_REVISION,
        "model_path": model_dir,
        "python_path": sys.executable,
        "backend_name": f"mlx-lm {backend_ver}",
        "details": "Model artifacts and MLX runtime verified. Ready to load.",
        "missing_files": []
    }


# MARK: - Real Local Model Inference

# Cached model instance for single-session efficiency
_CACHED_MODEL_BUNDLE: Optional[Tuple[Any, Any, str]] = None

def get_or_load_model(model_path: str) -> Tuple[Any, Any, float]:
    """Loads model and tokenizer with local_files_only & trust_remote_code=False."""
    global _CACHED_MODEL_BUNDLE
    if _CACHED_MODEL_BUNDLE is not None:
        cached_model, cached_tok, cached_path = _CACHED_MODEL_BUNDLE
        if cached_path == model_path:
            return cached_model, cached_tok, 0.0

    load_tic = time.perf_counter()
    try:
        import mlx_lm
    except ImportError as e:
        raise RuntimeUnavailableError(f"MLX-LM import failed: {e}")

    try:
        model, tokenizer = mlx_lm.load(model_path, trust_remote_code=False)
    except Exception as e:
        raise ModelIntegrityError(f"mlx_lm.load failed on '{model_path}': {e}")

    load_ms = round((time.perf_counter() - load_tic) * 1000.0, 2)
    _CACHED_MODEL_BUNDLE = (model, tokenizer, model_path)
    return model, tokenizer, load_ms


def run_inference(params: dict) -> dict:
    """
    Executes real local forward-pass generation with locked G0 profile.
    Enforces resource lock, chat template formatting, token limits, and timing.
    """
    prompt = params.get("prompt") or params.get("text")
    if not prompt or not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("Parameter 'prompt' (or 'text') must be a non-empty string.")

    profile_id = params.get("profile_id") or G0_PROFILE_ID
    if profile_id != G0_PROFILE_ID:
        raise ValueError(f"Unsupported profile_id '{profile_id}'. Expected '{G0_PROFILE_ID}'.")

    # Enforce strictly 1 inference at a time
    if not _INFERENCE_LOCK.acquire(blocking=False):
        raise ResourceBusyError("Worker is currently executing another inference request.")

    try:
        # Preflight verification
        status_info = check_status({
            "profile_id": profile_id,
            "app_support_path": params.get("app_support_path")
        })
        status_code = status_info.get("status")

        if status_code == "not_installed":
            raise ModelNotInstalledError(status_info.get("details", "Model is not installed."))
        elif status_code == "not_configured":
            raise ModelNotInstalledError(status_info.get("details", "Model is not configured."))
        elif status_code == "invalid_assets":
            raise ModelIntegrityError(status_info.get("details", "Model assets are corrupted or missing."))
        elif status_code == "runtime_unavailable":
            raise RuntimeUnavailableError(status_info.get("details", "Runtime is unavailable."))
        elif status_code != "available_unloaded":
            raise ModelIntegrityError(f"Model preflight failed with status: {status_code}")

        model_dir = status_info["model_path"]
        if not model_dir or not os.path.isdir(model_dir):
            raise ModelNotInstalledError(f"Resolved model directory '{model_dir}' does not exist.")

        # Read model lock sha256
        lock_file = resolve_lock_file()
        lock_sha256 = compute_file_sha256(lock_file) if lock_file and os.path.isfile(lock_file) else "UNKNOWN"

        input_sha256 = hashlib.sha256(prompt.encode("utf-8")).hexdigest()

        # Load model & tokenizer
        model, tokenizer, load_time_ms = get_or_load_model(model_dir)

        # Apply real Chat Template
        messages = [{"role": "user", "content": prompt.strip()}]
        try:
            formatted_prompt = tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False
            )
        except Exception:
            # Fallback standard chat formatting if apply_chat_template raises on kwargs
            formatted_prompt = tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True
            )

        # Token count check (after chat template formatting)
        encoded_input = tokenizer.encode(formatted_prompt, add_special_tokens=False)
        input_token_count = len(encoded_input)
        if input_token_count > MAX_INPUT_TOKENS:
            raise InputTooLargeError(
                f"Input tokens ({input_token_count}) exceed max allowed limit of {MAX_INPUT_TOKENS} tokens."
            )

        # Run stream generation
        import mlx_lm
        gen_tic = time.perf_counter()
        output_text = ""
        output_token_count = 0
        finish_reason = "stop"

        for response in mlx_lm.stream_generate(
            model=model,
            tokenizer=tokenizer,
            prompt=formatted_prompt,
            max_tokens=MAX_OUTPUT_TOKENS
        ):
            output_text += response.text
            output_token_count = response.generation_tokens
            if response.finish_reason:
                finish_reason = response.finish_reason

        generation_time_ms = round((time.perf_counter() - gen_tic) * 1000.0, 2)

        return {
            "schema_version": "1.0.0",
            "run_id": str(uuid.uuid4()),
            "profile_id": G0_PROFILE_ID,
            "model_id": G0_MODEL_ID,
            "model_revision": G0_MODEL_REVISION,
            "model_lock_sha256": lock_sha256,
            "backend_name": "mlx-lm",
            "backend_version": getattr(mlx_lm, "__version__", "0.32.2"),
            "input_sha256": input_sha256,
            "output_text": output_text.strip(),
            "input_token_count": input_token_count,
            "output_token_count": output_token_count,
            "finish_reason": finish_reason,
            "load_time_ms": load_time_ms,
            "generation_time_ms": generation_time_ms
        }

    except ModelError:
        raise
    except ValueError:
        raise
    except Exception as e:
        raise InferenceFailedError(f"Unexpected error during model inference: {str(e)}")
    finally:
        _INFERENCE_LOCK.release()
