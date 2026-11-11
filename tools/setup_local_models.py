#!/usr/bin/env python3
"""Install the local G3/S17 models that are not part of the app bundle.

Two optional models are resolved from the local disk only; inference never
downloads (`HF_HUB_OFFLINE=1` in the worker). This script is the sanctioned
setup step:

  * TTS   — Kokoro-Vietnamese (Apache-2.0, 82M)  -> Models/tts_kokoro_vi
  * STORY — Qwen3-8B-4bit (`P-STORY-SYNTH-v1`)   -> Models/story_synthesis

Usage:
    tools/setup_local_models.py --plan            # local report, no network
    tools/setup_local_models.py --install --tts   # download TTS weights
    tools/setup_local_models.py --install --story # download story weights
    tools/setup_local_models.py --install --all

Downloads are staged into a sibling directory and published by rename, so a
failed or partial download never replaces a working install.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys

MODELS_ROOT = Path(
    os.environ.get("AIVIDEO_MODELS_ROOT")
    or (Path.home() / "Library" / "Application Support" / "AIVideo" / "Models")
).expanduser()

TARGETS = {
    "tts": {
        "repo": "contextboxai/Kokoro-Vietnamese",
        "directory": MODELS_ROOT / "tts_kokoro_vi",
        "required": ["config.json", "kokoro_vi.pth", "voices.json"],
        "patterns": ["config.json", "kokoro_vi.pth", "voices.json", "voicepacks/*.pt"],
        "notes": "Apache-2.0 Vietnamese TTS, 82M params, preset voicepacks",
    },
    "story": {
        "repo": "mlx-community/Qwen3-8B-4bit",
        "directory": MODELS_ROOT / "story_synthesis",
        "required": ["config.json", "model.safetensors", "tokenizer.json"],
        "patterns": ["*.json", "*.safetensors", "*.txt", "*.model", "*.jinja"],
        "notes": "P-STORY-SYNTH-v1 script writer (4-bit MLX)",
    },
}


def report(key: str) -> dict:
    target = TARGETS[key]
    directory = target["directory"]
    missing = [n for n in target["required"] if not (directory / n).is_file()]
    size = 0
    if directory.is_dir():
        size = sum(p.stat().st_size for p in directory.rglob("*") if p.is_file())
    return {
        "target": key,
        "repo": target["repo"],
        "directory": str(directory),
        "installed": not missing,
        "missing_files": missing,
        "size_mb": round(size / (1024 ** 2), 1),
        "notes": target["notes"],
    }


def install(key: str) -> dict:
    target = TARGETS[key]
    try:
        from huggingface_hub import snapshot_download
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise SystemExit(f"huggingface_hub is required to install: {exc}")

    directory = target["directory"]
    staging = directory.with_name(directory.name + ".partial")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    print(f"[{key}] downloading {target['repo']} -> {staging}")
    snapshot_download(
        target["repo"],
        local_dir=str(staging),
        allow_patterns=target["patterns"],
    )
    missing = [n for n in target["required"] if not (staging / n).is_file()]
    if missing:
        raise SystemExit(f"[{key}] download incomplete, missing: {missing}")
    if directory.exists():
        shutil.rmtree(directory)
    staging.rename(directory)
    print(f"[{key}] published to {directory}")
    return report(key)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="download missing weights")
    parser.add_argument("--tts", action="store_true", help="select the TTS target")
    parser.add_argument("--story", action="store_true", help="select the story target")
    parser.add_argument("--all", action="store_true", help="select every target")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    if args.all or (not args.tts and not args.story):
        keys = list(TARGETS)
    else:
        keys = [k for k, flag in (("tts", args.tts), ("story", args.story)) if flag]
    if args.install:
        os.environ.pop("HF_HUB_OFFLINE", None)

    results = []
    for key in keys:
        if args.install and not report(key)["installed"]:
            results.append(install(key))
        else:
            results.append(report(key))

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=1))
    else:
        for item in results:
            state = "INSTALLED" if item["installed"] else "MISSING " + ",".join(item["missing_files"])
            print(f"{item['target']:6s} {state:28s} {item['size_mb']:8.1f} MB  {item['directory']}")
            print(f"       {item['repo']} — {item['notes']}")
    return 0 if all(item["installed"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
