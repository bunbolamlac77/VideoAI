#!/usr/bin/env python3
"""
tools/sign_field_corpus.py — build and Ed25519-sign the field corpus manifest.

The manifest that used to live in reports/evidence was hand-written fiction: its
SHA-256 values were patterned placeholders and its durations (1820 s) did not match
the 1.5 s clips in fixtures/corpus. This tool derives every field from the files on
disk and from the label files, then signs the result with the QA private key that
lives outside the repository (default ~/.aivideo-qa/field_qa_ed25519_private.pem).

Usage:
  workers/.venv/bin/python3 tools/sign_field_corpus.py \
      --corpus fixtures/corpus --labels fixtures/corpus/labels \
      --out reports/evidence/signed_field_corpus_manifest.json
  workers/.venv/bin/python3 tools/sign_field_corpus.py --verify
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "workers" / "src") not in sys.path:
    sys.path.insert(0, str(ROOT / "workers" / "src"))

from aivideo_workers.corpus_labels import (  # noqa: E402
    label_blockers,
    load_clip_labels,
    summarize_label_eligibility,
    validate_clip_labels,
)
from aivideo_workers.g4_core import canon  # noqa: E402

KEY_ID = "aivideo-field-qa-v1"
DEFAULT_KEY = Path.home() / ".aivideo-qa" / "field_qa_ed25519_private.pem"
DEFAULT_OUT = ROOT / "reports" / "evidence" / "signed_field_corpus_manifest.json"


def _probe(clip: Path) -> dict:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration:stream=codec_name,width,height",
            "-of", "json", str(clip),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    data = json.loads(result.stdout)
    streams = [s for s in data.get("streams", []) if s.get("codec_name")]
    stream = streams[0] if streams else {}
    return {
        "duration_seconds": round(float(data.get("format", {}).get("duration", 0.0)), 3),
        "codec": stream.get("codec_name", "unknown"),
        "width": int(stream.get("width", 0) or 0),
        "height": int(stream.get("height", 0) or 0),
    }


def build_manifest(corpus_dir: Path, labels_dir: Path) -> dict:
    labels = load_clip_labels(labels_dir)
    problems = validate_clip_labels(labels, corpus_dir)
    if problems:
        raise SystemExit("Label/clip mismatch:\n  " + "\n  ".join(problems))

    summary = summarize_label_eligibility(labels)
    trips = []
    for clip in sorted(corpus_dir.glob("*.mp4")):
        trip_id = clip.stem
        label = labels.get(trip_id, {})
        probe = _probe(clip)
        trips.append(
            {
                "trip_id": trip_id,
                "route": str(label.get("observed", {}).get("text_on_screen", "")),
                "workdays": 1,
                "total_video_duration_seconds": probe["duration_seconds"],
                "video_codec": probe["codec"],
                "resolution": f"{probe['width']}x{probe['height']}",
                "sha256": hashlib.sha256(clip.read_bytes()).hexdigest(),
                "ground_truth_claims_count": len(label.get("claims") or []),
                "labeler_type": label.get("labeler_type", "missing"),
                "source_kind": label.get("source_kind", "missing"),
            }
        )
    if len(trips) < 5:
        raise SystemExit(f"Expected at least 5 held-out clips, found {len(trips)}")

    return {
        "schema": "aivideo-signed-field-corpus-manifest-v1",
        "version": "1.1.0",
        "signed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "corpus_scope": {
            "corpus_kind": (
                "E0_5_HELD_OUT_TRIPS" if summary["acceptance_eligible"] else "SYNTHETIC_FIXTURE"
            ),
            "target_platform": "Apple Silicon (local offline)",
            "held_out_trips": trips,
            "labels": {
                "clip_count": summary["clip_count"],
                "labeler_types": summary["labeler_types"],
                "source_kinds": summary["source_kinds"],
                "acceptance_eligible": summary["acceptance_eligible"],
                "blockers": label_blockers(summary),
            },
        },
        "signing_authority": {
            "key_id": KEY_ID,
            "algorithm": "ed25519",
            "signature": "",
        },
    }


def sign_manifest(manifest: dict, private_key_path: Path) -> dict:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    key = serialization.load_pem_private_key(private_key_path.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise SystemExit("QA private key is not Ed25519")
    payload = {k: v for k, v in manifest.items() if k != "signing_authority"}
    signature = key.sign(canon(payload))
    out = dict(manifest)
    out["signing_authority"] = {
        "key_id": KEY_ID,
        "algorithm": "ed25519",
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    return out


def verify_manifest(path: Path) -> bool:
    from aivideo_workers.g5_release_audit import validate_signed_field_manifest

    manifest = json.loads(path.read_text(encoding="utf-8"))
    corpus = Path(manifest.get("corpus_scope", {}).get("_corpus_dir", ROOT / "fixtures" / "corpus"))
    return validate_signed_field_manifest(manifest, corpus_dir=corpus)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and sign the field corpus manifest")
    parser.add_argument("--corpus", default=str(ROOT / "fixtures" / "corpus"))
    parser.add_argument("--labels", default=str(ROOT / "fixtures" / "corpus" / "labels"))
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    parser.add_argument("--key", default=os.environ.get("AIVIDEO_QA_PRIVATE_KEY", str(DEFAULT_KEY)))
    parser.add_argument("--verify", action="store_true", help="verify an existing manifest and exit")
    args = parser.parse_args()

    out_path = Path(args.out)
    if args.verify:
        manifest = json.loads(out_path.read_text(encoding="utf-8"))
        corpus = Path(args.corpus)
        from aivideo_workers.g5_release_audit import validate_signed_field_manifest

        ok = validate_signed_field_manifest(manifest, corpus_dir=corpus)
        scope = manifest.get("corpus_scope", {})
        print(f"signature+hashes valid: {ok}")
        print(f"corpus_kind: {scope.get('corpus_kind')}")
        print(f"labels: {scope.get('labels')}")
        return 0 if ok else 1

    key_path = Path(args.key).expanduser()
    if not key_path.is_file():
        raise SystemExit(
            f"QA private key not found at {key_path}. "
            "Provision it outside the repository (chmod 600) before signing."
        )

    manifest = build_manifest(Path(args.corpus), Path(args.labels))
    signed = sign_manifest(manifest, key_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(signed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(out_path)
    print(f"wrote {out_path}")
    print(f"corpus_kind: {signed['corpus_scope']['corpus_kind']}")
    print(f"acceptance_eligible: {signed['corpus_scope']['labels']['acceptance_eligible']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
