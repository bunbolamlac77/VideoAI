"""
workers/src/aivideo_workers/corpus_labels.py — clip labels and acceptance eligibility.

A label file describes what is actually visible in a clip. Two fields decide whether
a set of labels can support Gate G2 acceptance:

  labeler_type = "human"            (an independent person wrote it)
  source_kind  = "field_footage"    (real footage, not a generated fixture)

Anything else is useful for regression tests but is NOT acceptance evidence. The
repository currently ships labels for five generated title cards, so
`acceptance_eligible` is False by construction.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List

LABEL_SCHEMA = "aivideo-clip-label-v1"
ACCEPTANCE_LABELER = "human"
ACCEPTANCE_SOURCE_KIND = "field_footage"


def load_clip_labels(labels_dir: str | Path) -> Dict[str, Dict[str, Any]]:
    labels, _ = load_clip_labels_with_problems(labels_dir)
    return labels


def load_clip_labels_with_problems(
    labels_dir: str | Path,
) -> tuple[Dict[str, Dict[str, Any]], List[str]]:
    """Load labels and report every file that could not be used.

    (P1-21) A corrupt or wrongly-schemad label file used to be skipped silently, so a
    corpus could shrink (or lose exactly the inconvenient clips) while still looking
    eligible. Problems are now returned to the caller, which must treat them as blockers.
    """
    directory = Path(labels_dir)
    labels: Dict[str, Dict[str, Any]] = {}
    problems: List[str] = []
    if not directory.is_dir():
        return labels, problems
    for path in sorted(directory.glob("*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            problems.append(f"LABEL_UNREADABLE: {path.name}: {exc}")
            continue
        if not isinstance(payload, dict) or payload.get("schema") != LABEL_SCHEMA:
            problems.append(f"LABEL_SCHEMA_INVALID: {path.name}")
            continue
        trip_id = str(payload.get("trip_id") or path.stem)
        payload["_label_path"] = str(path)
        labels[trip_id] = payload
    return labels, problems


def validate_clip_labels(
    labels: Dict[str, Dict[str, Any]],
    corpus_dir: str | Path,
) -> List[str]:
    """Return a list of human-readable problems; empty means consistent with disk."""
    corpus = Path(corpus_dir)
    problems: List[str] = []
    for trip_id, label in labels.items():
        clip = corpus / f"{trip_id}.mp4"
        if not clip.is_file():
            problems.append(f"{trip_id}: clip missing")
            continue
        actual = hashlib.sha256(clip.read_bytes()).hexdigest()
        if str(label.get("source_sha256", "")).lower() != actual:
            problems.append(f"{trip_id}: source_sha256 does not match the clip on disk")
        if label.get("labeler_type") not in ("human", "agent_visual_review"):
            problems.append(f"{trip_id}: unknown labeler_type {label.get('labeler_type')!r}")
        if label.get("source_kind") not in ("field_footage", "synthetic_title_card"):
            problems.append(f"{trip_id}: unknown source_kind {label.get('source_kind')!r}")
    return problems


def summarize_label_eligibility(
    labels: Dict[str, Dict[str, Any]],
    problems: Iterable[str] = (),
) -> Dict[str, Any]:
    labelers = sorted({str(l.get("labeler_type", "unknown")) for l in labels.values()})
    kinds = sorted({str(l.get("source_kind", "unknown")) for l in labels.values()})
    problem_list = list(problems)
    eligible = (
        bool(labels)
        and not problem_list
        and all(
            l.get("labeler_type") == ACCEPTANCE_LABELER
            and l.get("source_kind") == ACCEPTANCE_SOURCE_KIND
            for l in labels.values()
        )
    )
    return {
        "label_problems": problem_list,
        "clip_count": len(labels),
        "labeler_types": labelers,
        "source_kinds": kinds,
        "acceptance_eligible": eligible,
        "required_labeler_type": ACCEPTANCE_LABELER,
        "required_source_kind": ACCEPTANCE_SOURCE_KIND,
    }


def label_blockers(summary: Dict[str, Any]) -> List[str]:
    blockers: List[str] = []
    if summary.get("clip_count", 0) == 0:
        blockers.append("NO_LABELS")
        return blockers
    if summary.get("labeler_types") != [ACCEPTANCE_LABELER]:
        blockers.append(f"LABELS_NOT_HUMAN:{summary.get('labeler_types')}")
    if summary.get("source_kinds") != [ACCEPTANCE_SOURCE_KIND]:
        blockers.append(f"NOT_FIELD_FOOTAGE:{summary.get('source_kinds')}")
    return blockers


def clips_missing_labels(corpus_dir: str | Path, labels: Dict[str, Dict[str, Any]]) -> List[str]:
    corpus = Path(corpus_dir)
    return sorted(
        clip.stem for clip in corpus.glob("*.mp4") if clip.stem not in labels
    )
