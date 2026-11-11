"""G3 S16-S19: evidence-constrained story, offline TTS,
SEARCH-v1, and approval proposals.

Only Swift ProjectStore commits canonical approvals.
The Python worker returns drafts and staged WAV files.
"""
from __future__ import annotations

import array
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import wave
from typing import Any, Callable

from .tts_engine import (
    TTS_PROFILE_ID,
    KokoroVietnameseTTSEngine,
    TTSEngineUnavailable,
)

FPS = 24
SAMPLE_RATE = 48_000
SAMPLES_PER_FRAME = 2_000
MAX_TIMELINE_FRAMES = 4_319
SEARCH_VERSION = "SEARCH-v1"
CHECKER_VERSION = "EXACT-v1"


def digest(value: Any) -> str:
    if isinstance(value, bytes):
        data = value
    else:
        data = json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode()
    return hashlib.sha256(data).hexdigest()


def _required_text(
    value: Any,
    name: str,
    limit: int = 4_096,
) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > limit
    ):
        raise ValueError(
            f"{name} must be nonempty UTF-8 text <= {limit} chars"
        )
    return value.strip()


def _required_list(
    value: Any,
    name: str,
    limit: int = 512,
) -> list:
    if not isinstance(value, list) or len(value) > limit:
        raise ValueError(
            f"{name} must be a list <= {limit} items"
        )
    return value


def eligible_claims(
    claims: list[dict],
    scope: str,
) -> tuple[list[dict], list[dict]]:
    """Exclude unsupported, stale, disputed or unconfirmed facts."""
    eligible, rejected = [], []

    for raw in claims:
        claim = dict(raw)
        cid = _required_text(
            claim.get("claim_id"),
            "claim_id",
            128,
        )
        reason = None
        text = claim.get(
            "text",
            claim.get("predicate_text", ""),
        )
        revision = claim.get(
            "revision_id",
            claim.get("claim_revision_id"),
        )

        if (
            not isinstance(text, str)
            or not text.strip()
            or not revision
        ):
            reason = "missing_text_or_revision"
        elif claim.get("evidence_scope_revision_id") != scope:
            reason = "stale_or_missing_scope"
        elif claim.get("scope_revalidation_status") is None:
            # (P0-07) A missing revalidation state is not evidence of completion; the
            # previous default made every claim silently "revalidated".
            reason = "missing_scope_revalidation"
        elif claim.get("scope_revalidation_status") != "complete":
            reason = "pending_scope_revalidation"
        elif claim.get("support_status") != "supported":
            reason = "not_supported"
        elif claim.get("allowed_use") not in (
            "direct_claim",
            "attributed_or_qualified",
        ):
            reason = "not_allowed_for_narration"
        elif claim.get("review_status") in (
            "rejected",
            "superseded",
            "needs_review",
            "unreviewed",
        ):
            reason = "review_required"
        elif (
            claim.get("origin") == "user"
            and claim.get("review_status") != "confirmed"
        ):
            reason = "user_fact_unconfirmed"
        elif (
            claim.get("origin") != "user"
            and not claim.get("evidence_sha256")
        ):
            reason = "missing_observation_evidence"
        elif (
            claim.get("is_critical", False)
            and claim.get("epistemic_status") in (
                "unknown",
                "inferred",
            )
        ):
            reason = "critical_uncertainty"

        if reason:
            rejected.append({
                "claim_id": cid,
                "reason": reason,
            })
        else:
            claim["text"] = text.strip()
            claim["revision_id"] = str(revision)
            eligible.append(claim)

    return eligible, rejected



def _llm_rewrite_beats(
    beats: list,
    claim_texts: list,
    script_engine: str,
) -> tuple[list, dict]:
    """Rewrite approved beats with the local story LLM.

    The LLM may only re-word a claim it was given: the evidence reference
    (`claim_refs`), the beat order and the shot candidates are never touched.
    Any schema/fact violation falls back to the verbatim claim text and records
    why, so a failed rewrite can never fabricate a script.
    """
    from .story_writer import LLMStoryWriter, StoryWriterError

    if script_engine not in ("llm", "auto"):
        return beats, {"engine": "deterministic", "reason": "requested_deterministic"}

    prepared = []
    for beat, claim_text in zip(beats, claim_texts):
        item = dict(beat)
        item["_claim_text"] = claim_text
        prepared.append(item)

    try:
        result = LLMStoryWriter().rewrite(prepared)
    except StoryWriterError as exc:
        return beats, {
            "engine": "deterministic",
            "fallback_reason": exc.code,
            "detail": exc.message,
        }

    rewritten = {b["beat_id"]: b["voice_text"] for b in result["beats"]}
    # (P0-08) All-or-nothing: a script that mixes LLM wording with verbatim claim text could
    # not be approved honestly, so a single missing/short beat falls back as a whole.
    if set(rewritten) != {b["beat_id"] for b in beats} or any(
        not isinstance(v, str) or not v.strip() for v in rewritten.values()
    ):
        return beats, {
            "engine": "deterministic",
            "fallback_reason": "STORY_REWRITE_INCOMPLETE",
        }

    meta = dict(result["meta"])

    def _fallback(beats_local, reason: str):
        return beats_local, {
            "engine": "deterministic",
            "fallback_reason": reason,
            "detail": "LLM output failed narration validation; verbatim claim text used",
        }

    # (P0-08) Narration must stay attributable: every beat is labelled
    # `llm_local_rewrite` together with the model/prompt/raw-output digests that produced it,
    # the same fields S19 compares before it will approve the script.
    original = {b["beat_id"]: str(b.get("voice_text") or "") for b in beats}
    updated = []
    for beat in beats:
        text = rewritten[beat["beat_id"]].strip()
        if any(ch in text for ch in ("\ufffd", "\x00")):
            return _fallback(beats, "STORY_ENCODING_CORRUPTION")
        if not 8 <= len(text) <= 320:
            return _fallback(beats, "STORY_NARRATION_LENGTH")
        if _DIGITS_ONLY(text) and not _DIGITS_ONLY(text) <= _DIGITS_ONLY(original[beat["beat_id"]]):
            return _fallback(beats, "STORY_INVENTED_DIGITS")
        item = dict(beat)
        item["voice_text"] = text
        item["voice_text_origin"] = "llm_local_rewrite"
        item["voice_text_source_text"] = original[beat["beat_id"]]
        item["voice_text_sha256"] = digest(text.encode("utf-8"))
        item["voice_raw_output_sha256"] = str(meta.get("raw_output_sha256") or "")
        item["voice_prompt_sha256"] = str(meta.get("prompt_sha256") or "")
        item["voice_model_id"] = str(meta.get("model_id") or "")
        updated.append(item)
    meta["engine"] = "llm_local"
    meta["claim_refs_unchanged"] = True
    meta["narration_origin"] = "llm_local_rewrite"
    return updated, meta


def _DIGITS_ONLY(text: str) -> set:
    import re as _re

    return set(_re.findall(r"\d+", text or ""))


def generate_story(params: dict) -> dict:
    """Generate conservative source-backed drafts.

    This function does not invent events or claim to have run
    an LLM. A small corpus produces only one candidate.
    """
    scope = _required_text(
        params.get("evidence_scope_revision_id"),
        "evidence_scope_revision_id",
        128,
    )
    claims = _required_list(
        params.get("claims"),
        "claims",
    )
    shots = _required_list(
        params.get("shots", []),
        "shots",
    )
    locks = dict(params.get("constraints", {}))

    for key in ("must_use", "must_not_use", "preferred"):
        locks[key] = _required_list(
            locks.get(key, []),
            key,
            128,
        )

    script_engine = str(
        params.get("script_engine", "deterministic")
    ).strip().lower()
    if script_engine not in ("deterministic", "llm", "auto"):
        raise ValueError(
            "script_engine must be one of: deterministic, llm, auto"
        )

    blocked_ids = set(locks["must_not_use"])
    allowed, rejected = eligible_claims(claims, scope)

    allowed = [
        c for c in allowed
        if c["claim_id"] not in blocked_ids
    ]
    missing_must = sorted(
        set(locks["must_use"])
        - {c["claim_id"] for c in allowed}
    )

    if missing_must:
        return {
            "status": "blocked_constraints",
            "missing_must_use": missing_must,
            "candidates": [],
            "excluded": rejected,
        }

    if not allowed:
        return {
            "status": "blocked_no_eligible_claims",
            "candidates": [],
            "excluded": rejected,
        }

    if len(allowed) > 24:
        allowed = allowed[:24]
        lost = (
            set(locks["must_use"])
            - {c["claim_id"] for c in allowed}
        )
        if lost:
            return {
                "status": "blocked_too_many_required_claims",
                "missing_must_use": sorted(lost),
                "candidates": [],
                "excluded": rejected,
            }

    allowed_by_id = {
        c["claim_id"]: c for c in allowed
    }
    shots_by_claim: dict[str, list] = {}

    for shot in shots:
        if (
            shot.get("source_sha256")
            and shot.get("source_revision_id")
            and shot.get("mapping_sha256")
        ):
            for cid in shot.get("claim_ids", []):
                if (
                    cid in allowed_by_id
                    and shot.get(
                        "evidence_scope_revision_id"
                    ) == scope
                ):
                    shots_by_claim.setdefault(
                        cid, []
                    ).append(shot)

    orders = [allowed]
    if (
        len(allowed) >= 3
        and params.get(
            "allow_alternate_narrative", False
        )
    ):
        orders.append(
            [allowed[-1]] + allowed[:-1]
        )

    candidates = []

    for variant, ordered in enumerate(orders):
        beats = []
        claim_texts = []

        for index, claim in enumerate(ordered):
            attributed = (
                claim["allowed_use"]
                == "attributed_or_qualified"
                or claim.get("epistemic_status")
                == "reported"
            )

            prefix = (
                "Theo thông tin đã được người quay xác nhận: "
                if attributed else ""
            )
            text = prefix + claim["text"]
            beat_id = f"beat-{index + 1:02d}"
            matching_shots = shots_by_claim.get(
                claim["claim_id"], []
            )

            beats.append({
                "beat_id": beat_id,
                "narrative_order": index,
                "claim_refs": [{
                    "claim_id": claim["claim_id"],
                    "revision_id": claim["revision_id"],
                    "allowed_use": claim["allowed_use"],
                    "evidence_scope_revision_id": scope,
                }],
                "voice_text": text,
                "narrative_type": (
                    "reported_by_user"
                    if attributed
                    else "evidence_backed"
                ),
                "shot_candidate_ids": [
                    s["shot_id"] for s in matching_shots
                ],
                "visual_role": (
                    "proof"
                    if matching_shots
                    else "illustrative_only"
                ),
                "status": "draft_not_voice_verified",
            })
            claim_texts.append(text)

        beats, engine_meta = _llm_rewrite_beats(
            beats, claim_texts, script_engine
        )

        identity = digest({
            "scope": scope,
            "beats": beats,
            "locks": locks,
            "variant": variant,
        })

        candidates.append({
            "candidate_id": identity[:24],
            "script_revision_id": identity,
            "revision": 1,
            "concept": (
                "Theo trình tự dữ kiện"
                if variant == 0
                else "Mở đầu bằng chi tiết cuối, "
                     "không khẳng định thứ tự hình"
            ),
            "scope_revision_id": scope,
            "claim_revision_ids": sorted(
                c["revision_id"] for c in ordered
            ),
            "constraints": locks,
            "beats": beats,
            "status": "DRAFT_NOT_BUILDABLE",
            "derived_from": "validated_claims_only",
            "script_engine": engine_meta,
        })

    return {
        "status": "draft",
        "candidates": candidates,
        "excluded": rejected,
        "missing_must_use": [],
        "script_engine_requested": script_engine,
    }


def edit_story(params: dict) -> dict:
    story = dict(params.get("candidate") or {})
    beats = [
        dict(b) for b in story.get("beats", [])
    ]
    beat_id = _required_text(
        params.get("beat_id"),
        "beat_id",
        128,
    )
    new_text = _required_text(
        params.get("new_text"),
        "new_text",
    )

    locks = story.get("constraints", {})

    if beat_id in locks.get("locked_beats", []):
        return {
            "status": "blocked_locked_beat",
            "candidate": story,
        }

    changed = False

    for beat in beats:
        if beat.get("beat_id") == beat_id:
            if beat.get("voice_text") != new_text:
                beat["voice_text"] = new_text
                beat["status"] = (
                    "requires_claim_revalidation"
                )
                changed = True

    if not changed:
        return {
            "status": "unchanged",
            "candidate": story,
        }

    story["beats"] = beats
    story["revision"] = (
        int(story.get("revision", 1)) + 1
    )
    story["script_revision_id"] = digest({
        "previous": story.get("script_revision_id"),
        "beats": beats,
        "revision": story["revision"],
    })
    story["status"] = (
        "BLOCKED_PENDING_CLAIM_REVALIDATION"
    )
    story["voice_trials"] = []
    story["edit_plan"] = None

    return {
        "status": "revalidation_required",
        "candidate": story,
        "invalidated": [
            "claim_use",
            "voice",
            "alignment",
            "cut",
            "caption",
            "mix",
            "approval",
        ],
    }


def _wav_info(path: Path) -> dict:
    with wave.open(str(path), "rb") as wf:
        channels = wf.getnchannels()
        rate = wf.getframerate()
        width = wf.getsampwidth()
        samples = wf.getnframes()

        if (
            channels not in (1, 2)
            or rate != SAMPLE_RATE
            or width != 2
            or samples <= 0
        ):
            raise ValueError(
                "WAV must be PCM16 mono/stereo at "
                "48000 Hz with nonzero duration"
            )

        peak = 0

        for _ in range(math.ceil(samples / 16384)):
            chunk = wf.readframes(16384)
            if not chunk:
                break
            pcm = array.array("h")
            pcm.frombytes(chunk)
            if sys.byteorder != "little":
                pcm.byteswap()
            peak = max(
                peak,
                max(
                    (abs(sample) for sample in pcm),
                    default=0,
                ),
            )

        if peak >= 32767:
            raise ValueError(
                "WAV is clipped at PCM16 full scale; "
                "manual re-record is required"
            )

    return {
        "sample_rate": rate,
        "channels": channels,
        "samples": samples,
        "duration_frames_ceil": math.ceil(
            samples / SAMPLES_PER_FRAME
        ),
        "duration_seconds": round(
            samples / rate, 6
        ),
        "sha256": digest(path.read_bytes()),
        "size_bytes": path.stat().st_size,
    }


def _tts_blocked(exc: Exception) -> dict:
    """(P1-36) The runtime can only fail as *unavailable*, never as an internal error."""
    return {
        "status": "blocked_tts_runtime_unavailable",
        "required": "kokoro-vietnamese local TTS runtime (Apache-2.0, offline)",
        "detail": getattr(exc, "detail", "") or str(exc),
    }


def voice_trial(
    params: dict,
    tts_factory: Callable[[], Any] | None = None,
) -> dict:
    """Produce real offline WAV; never fake missing TTS."""
    script_rev = _required_text(
        params.get("script_revision_id"),
        "script_revision_id",
        128,
    )
    beat_id = _required_text(
        params.get("beat_id"),
        "beat_id",
        128,
    )
    text = _required_text(
        params.get("voice_text"),
        "voice_text",
        2048,
    )
    voice = _required_text(
        params.get("voice_id"),
        "voice_id",
        128,
    )

    if float(params.get("speed", 1.0)) != 1.0:
        raise ValueError(
            "G3 profile locks TTS speed at 1.0x"
        )

    out_dir = Path(
        _required_text(
            params.get("staging_dir"),
            "staging_dir",
            4096,
        )
    ).expanduser().resolve()

    if not out_dir.is_dir():
        raise ValueError(
            "staging_dir must exist "
            "and be a directory owned by the app"
        )

    if params.get("pronunciation_unresolved", False):
        return {
            "status": "blocked_pronunciation_review",
            "script_revision_id": script_rev,
        }

    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

    if tts_factory is None:
        try:
            tts = KokoroVietnameseTTSEngine()
        except TTSEngineUnavailable as exc:
            return {
                "status": "blocked_tts_runtime_unavailable",
                "required": "kokoro-vietnamese local TTS runtime (Apache-2.0, offline)",
                "detail": exc.detail or str(exc),
            }
    else:
        tts = tts_factory()

    preset_names = [
        v[0] for v in tts.list_preset_voices()
    ]

    if voice not in preset_names:
        raise ValueError(
            "voice_id is not an installed Kokoro-Vietnamese preset; "
            "do not silently substitute"
        )

    file_id = digest({
        "script_rev": script_rev,
        "text": text,
        "voice": voice,
        "model": TTS_PROFILE_ID,
        "nonce": params.get(
            "trial_nonce", "initial"
        ),
    })

    staged = out_dir / f"g3_voice_{file_id}.wav"

    fd, temp_name = tempfile.mkstemp(
        prefix=".g3_voice_",
        suffix=".wav",
        dir=str(out_dir),
    )
    os.close(fd)

    try:
        # (P1-36) The constructor was guarded but `infer`/`save` were not: a runtime that "
        # fails at first use (missing wheel, unreadable weights) surfaced as -32603
        # INTERNAL_ERROR instead of the documented blocked status.
        try:
            samples = tts.infer(text, voice=voice)
            tts.save(samples, temp_name)
        except (TTSEngineUnavailable, RuntimeError, OSError) as exc:
            if os.path.exists(temp_name):
                os.unlink(temp_name)
            return _tts_blocked(exc)
        info = _wav_info(Path(temp_name))
        os.replace(temp_name, staged)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)

    transcript = params.get("asr_transcript")
    finding = (
        "ASR_NOT_PROVIDED_REQUIRES_LISTENING_REVIEW"
    )

    if isinstance(transcript, str):
        normalize = lambda s: re.findall(
            r"\w+", s.lower(), re.UNICODE
        )
        finding = (
            "ASR_TEXT_MISMATCH_REVIEW"
            if normalize(transcript) != normalize(text)
            else
            "ASR_MATCH_STILL_REQUIRES_LISTENING_REVIEW"
        )

    return {
        "status": (
            "staged_pending_core_publication_"
            "and_speech_review"
        ),
        "script_revision_id": script_rev,
        "beat_id": beat_id,
        "text_fingerprint": digest(
            text.encode("utf-8")
        ),
        "voice_id": voice,
        "model_profile_id": TTS_PROFILE_ID,
        "speed": 1.0,
        "staging_path": str(staged),
        "wav": info,
        "speech_check_finding": finding,
        "alignment_status": (
            "requires_verified_phrase_cues"
        ),
        "approved": False,
        # (P0-07) Derived from this run, never asserted by the client: a freshly staged
        # WAV is not reviewed and not published until a human listens and S08 commits it.
        "voice_review_status": "unverified",
        "voice_review_reason": (
            "A human must listen and S08 must publish the WAV before cut search "
            "may treat the voice as verified"
        ),
    }


MAX_PHRASES = 16
MAX_PHRASE_CHARS = 200


def voice_phrases(
    params: dict,
    tts_factory: Callable[[], Any] | None = None,
) -> dict:
    """Synthesize each caption phrase separately so cue timing is exact.

    The subtitle timeline must not be estimated from word counts: each phrase is
    voiced on its own, its real sample length is measured, and the cue offsets are
    derived from those samples. The concatenated WAV is the beat narration.
    """
    script_rev = _required_text(params.get("script_revision_id"), "script_revision_id", 128)
    beat_id = _required_text(params.get("beat_id"), "beat_id", 128)
    voice = _required_text(params.get("voice_id"), "voice_id", 128)
    raw_phrases = params.get("phrases")
    if not isinstance(raw_phrases, list) or not 1 <= len(raw_phrases) <= MAX_PHRASES:
        raise ValueError(f"phrases must be a list of 1..{MAX_PHRASES} strings")
    phrases = []
    for phrase in raw_phrases:
        if not isinstance(phrase, str):
            raise ValueError("each phrase must be a string")
        text = " ".join(phrase.split())
        if not text or len(text) > MAX_PHRASE_CHARS:
            raise ValueError(f"phrase must be 1..{MAX_PHRASE_CHARS} characters")
        phrases.append(text)
    if float(params.get("speed", 1.0)) != 1.0:
        raise ValueError("G3 profile locks TTS speed at 1.0x")
    gap_frames = int(params.get("gap_frames", 0) or 0)
    if not 0 <= gap_frames <= 48:
        raise ValueError("gap_frames must be 0..48")

    out_dir = Path(_required_text(params.get("staging_dir"), "staging_dir", 4096)).expanduser().resolve()
    if not out_dir.is_dir():
        raise ValueError("staging_dir must exist and be a directory owned by the app")

    if tts_factory is None:
        try:
            tts = KokoroVietnameseTTSEngine()
        except TTSEngineUnavailable as exc:
            return {
                "status": "blocked_tts_runtime_unavailable",
                "required": "kokoro-vietnamese local TTS runtime (Apache-2.0, offline)",
                "detail": exc.detail or str(exc),
            }
    else:
        tts = tts_factory()

    presets = [v[0] for v in tts.list_preset_voices()]
    if voice not in presets:
        raise ValueError(
            "voice_id is not an installed Kokoro-Vietnamese preset; do not silently substitute"
        )

    file_id = digest({
        "script_rev": script_rev,
        "beat_id": beat_id,
        "phrases": phrases,
        "voice": voice,
        "model": TTS_PROFILE_ID,
        "gap_frames": gap_frames,
        "nonce": params.get("trial_nonce", "initial"),
    })
    gap_samples = gap_frames * SAMPLES_PER_FRAME

    cursor = 0
    entries = []
    frames_pcm = []
    per_phrase_paths = []
    for index, text in enumerate(phrases):
        phrase_path = out_dir / f"g3_phrase_{file_id}_{index:02d}.wav"
        # (P1-36) same rule as the trial path: a runtime failure is "unavailable".
        try:
            audio = tts.infer(text, voice=voice)
            tts.save(audio, str(phrase_path))
        except (TTSEngineUnavailable, RuntimeError, OSError) as exc:
            return _tts_blocked(exc)
        info = _wav_info(phrase_path)
        start_sample = cursor
        end_sample = start_sample + info["samples"]
        entries.append({
            "index": index,
            "text": text,
            "text_sha256": digest(text.encode("utf-8")),
            "wav": info,
            "start_sample": start_sample,
            "end_sample": end_sample,
            "start_frame": start_sample // SAMPLES_PER_FRAME,
            "end_frame": math.ceil(end_sample / SAMPLES_PER_FRAME),
        })
        per_phrase_paths.append(str(phrase_path))
        with wave.open(str(phrase_path), "rb") as wf:
            frames_pcm.append(wf.readframes(wf.getnframes()))
        cursor = end_sample + gap_samples

    total_samples = entries[-1]["end_sample"]
    combined_path = out_dir / f"g3_voice_phrases_{file_id}.wav"
    with wave.open(str(combined_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        for index, data in enumerate(frames_pcm):
            wf.writeframes(data)
            if gap_samples and index < len(frames_pcm) - 1:
                wf.writeframes(b"\x00\x00" * gap_samples)
    combined = _wav_info(combined_path)
    # `total_samples` already includes the gaps between phrases (they advance the
    # cursor before the next phrase starts), and no gap is appended after the last.
    if combined["samples"] != total_samples:
        raise ValueError(
            f"Concatenated narration length {combined['samples']} != last cue end {total_samples}"
        )

    return {
        "status": "staged_pending_core_publication_and_speech_review",
        "script_revision_id": script_rev,
        "beat_id": beat_id,
        "voice_id": voice,
        "model_profile_id": TTS_PROFILE_ID,
        "speed": 1.0,
        "gap_frames": gap_frames,
        "phrases": entries,
        "phrase_paths": per_phrase_paths,
        "combined_path": str(combined_path),
        "combined_wav": combined,
        "total_frames": math.ceil(combined["samples"] / SAMPLES_PER_FRAME),
        "speech_check_finding": "ASR_NOT_PROVIDED_REQUIRES_LISTENING_REVIEW",
        "alignment_status": "exact_phrase_sample_offsets",
        "approved": False,
    }


def _domain_fingerprint(
    beats: list[list[dict]],
    constraints: dict,
) -> str:
    return digest({
        "version": SEARCH_VERSION,
        "beats": beats,
        "constraints": constraints,
    })


def _option_reasons(
    option: dict,
    constraints: dict,
    beat_index: int,
    used: tuple[dict, ...],
    frame: int,
) -> list[str]:
    reasons = []

    if (
        not option.get("shot_id")
        or not option.get("source_revision_id")
        or not option.get("source_sha256")
        or not option.get("mapping_sha256")
    ):
        reasons.append(
            "missing_sealed_media_mapping"
        )

    if (
        option.get("evidence_scope_valid") is not True
        or option.get("claim_use_valid") is not True
    ):
        reasons.append("unverified_claim_or_scope")

    if option.get(
        "crop_preserves_evidence"
    ) is not True:
        reasons.append(
            "crop_evidence_unverified"
        )

    if option.get("shot_id") in constraints.get(
        "must_not_use", []
    ):
        reasons.append("must_not_use")

    if (
        not isinstance(
            option.get("range_start"), int
        )
        or not isinstance(
            option.get("range_end"), int
        )
        or option.get("range_start", 0) < 0
        or option.get("range_end", 0)
        <= option.get("range_start", 0)
    ):
        reasons.append("invalid_source_range")

    if (
        not isinstance(
            option.get("duration_frames"), int
        )
        or option.get("duration_frames", 0) <= 0
    ):
        reasons.append("invalid_duration")

    if (
        option.get("duration_frames", 0)
        > option.get("range_end", 0)
        - option.get("range_start", 0)
    ):
        reasons.append("source_too_short")

    min_frames = constraints.get(
        "voice_min_frames",
        [0] * len(
            constraints.get("_beat_ids", [])
        ),
    )

    if (
        beat_index < len(min_frames)
        and option.get("duration_frames", 0)
        < min_frames[beat_index]
    ):
        reasons.append("voice_overrun")

    transition = option.get(
        "transition_overlap_frames", 0
    )

    if (
        not isinstance(transition, int)
        or transition < 0
        or transition >= option.get(
            "duration_frames", 0
        )
    ):
        reasons.append(
            "invalid_transition_overlap"
        )
        transition = 0

    next_frame = (
        frame
        + option.get("duration_frames", 0)
        - (transition if used else 0)
    )

    if next_frame > min(
        MAX_TIMELINE_FRAMES,
        constraints.get(
            "max_timeline_frames",
            MAX_TIMELINE_FRAMES,
        ),
    ):
        reasons.append(
            "max_timeline_duration"
        )

    for old in used:
        if (
            option.get("reuse_key")
            and old.get("reuse_key")
            == option.get("reuse_key")
            and not option.get(
                "intentional_callback", False
            )
        ):
            reasons.append(
                "repeated_source_key"
            )

        if (
            option.get("source_revision_id")
            == old.get("source_revision_id")
            and max(
                option.get("range_start", 0),
                old.get("range_start", 0),
            )
            < min(
                option.get("range_end", 0),
                old.get("range_end", 0),
            )
            and not option.get(
                "intentional_callback", False
            )
        ):
            reasons.append(
                "source_range_overlap"
            )

        if (
            constraints.get(
                "chronology_strict", False
            )
            and int(
                option.get("chronology_index", 0)
            )
            < int(
                old.get("chronology_index", 0)
            )
        ):
            reasons.append(
                "chronology_violation"
            )

    return sorted(set(reasons))


def _validate_solution(
    chosen: list[dict],
    beats: list[list[dict]],
    constraints: dict,
) -> dict:
    if len(chosen) != len(beats):
        return {
            "valid": False,
            "reason": "missing_mandatory_beat",
        }

    used: tuple[dict, ...] = ()
    frame = 0

    for i, shot in enumerate(chosen):
        if not any(
            s.get("shot_id") == shot.get("shot_id")
            for s in beats[i]
        ):
            return {
                "valid": False,
                "reason": (
                    "shot_outside_declared_domain"
                ),
            }

        reasons = _option_reasons(
            shot, constraints, i, used, frame
        )
        if reasons:
            return {
                "valid": False,
                "reason": reasons,
            }

        frame += (
            shot["duration_frames"]
            - (
                shot.get(
                    "transition_overlap_frames", 0
                )
                if i else 0
            )
        )
        used += (shot,)

    if (
        set(constraints.get("must_use", []))
        - {s.get("shot_id") for s in chosen}
    ):
        return {
            "valid": False,
            "reason": "must_use_missing",
        }

    return {
        "valid": True,
        "timeline_frames": frame,
        "duration_seconds": frame / FPS,
    }


def search_cuts(params: dict) -> dict:
    """Beam + forward check + optional bounded exact oracle."""
    beats = _required_list(
        params.get("candidate_options"),
        "candidate_options",
        48,
    )

    if (
        not beats
        or any(
            not isinstance(x, list) or not x
            for x in beats
        )
    ):
        return {
            "status": "CANDIDATE_SET_EXHAUSTED",
            "reason": "missing_candidate_options",
        }

    if any(
        len(options) > 128
        for options in beats
    ):
        raise ValueError(
            "candidate domain too large"
        )

    constraints = dict(
        params.get("constraints", {})
    )
    for key in ("must_use", "must_not_use"):
        constraints[key] = _required_list(
            constraints.get(key, []), key
        )

    min_samples = params.get(
        "voice_samples_per_beat", []
    )
    if (
        not isinstance(min_samples, list)
        or len(min_samples) != len(beats)
        or any(
            not isinstance(x, int) or x < 0
            for x in min_samples
        )
    ):
        raise ValueError(
            "voice_samples_per_beat must match beats "
            "with measured integer WAV sample counts"
        )

    # 2026-11-11 fix (P0-07): the voice gate is a *decision*, so the caller must state it
    # explicitly. The G3 console used to send the constants "verified"/true before the user
    # had heard any WAV, which disabled the gate entirely. `unverified` is the only value
    # that may skip the check, and skipping it is reported, never silently accepted.
    voice_review_state = str(
        params.get("voice_review_status") or ""
    ).strip()
    if voice_review_state == "unverified":
        pass
    elif (
        voice_review_state != "verified"
        or params.get("voice_wav_published") is not True
    ):
        return {
            "status": "BLOCKED_VOICE_NOT_VERIFIED",
            "reason": (
                "missing reviewed and published WAV"
            ),
        }

    constraints["voice_min_frames"] = [
        math.ceil(s / SAMPLES_PER_FRAME)
        for s in min_samples
    ]
    constraints["_beat_ids"] = list(
        range(len(beats))
    )

    width = int(
        params.get("beam_width", 4)
    )
    if not 1 <= width <= 256:
        raise ValueError(
            "beam_width must be in 1..256"
        )

    budget = int(
        params.get("node_budget", 50_000)
    )
    if not 1 <= budget <= 500_000:
        raise ValueError(
            "node_budget must be in 1..500000"
        )

    forward = (
        params.get("forward_check", True)
        is True
    )
    exact = (
        params.get("run_exact_checker", False)
        is True
    )
    exact_limit = int(
        params.get(
            "exact_node_budget", 10_000
        )
    )

    domain_sha = _domain_fingerprint(
        beats, constraints
    )
    trace: list[dict] = []
    beam = [(0.0, tuple(), 0)]
    pruned_beam = False
    spent = 0

    def has_future(
        remaining: list[list[dict]],
        used: tuple[dict, ...],
        frame: int,
        start: int,
    ) -> tuple[bool, int]:
        # (P1-35) Return how many option evaluations this lookahead actually cost. The old
        # version reported a boolean and its work was invisible to `node_budget`, so a
        # "budget exhausted" search could still run for a very long time.
        cost = 0
        for j, options in enumerate(
            remaining, start
        ):
            feasible = False
            for opt in options:
                cost += 1
                if not _option_reasons(
                    opt,
                    constraints,
                    j,
                    used,
                    frame,
                ):
                    feasible = True
                    break
            if not feasible:
                return False, cost
        return True, cost

    for i, options in enumerate(beats):
        next_states: list[
            tuple[
                float,
                tuple[dict, ...],
                int,
            ]
        ] = []

        for score, used, frame in beam:
            for opt in options:
                spent += 1

                if spent > budget:
                    return {
                        "status": (
                            "SEARCH_BUDGET_EXHAUSTED"
                        ),
                        "reason": "node_budget",
                        "domain_sha256": domain_sha,
                        "trace": trace,
                        "nodes_visited": spent,
                    }

                reasons = _option_reasons(
                    opt,
                    constraints,
                    i,
                    used,
                    frame,
                )
                if reasons:
                    trace.append({
                        "event": "hard_prune",
                        "beat": i,
                        "option": opt.get("shot_id"),
                        "reasons": reasons,
                    })
                    continue

                next_frame = (
                    frame
                    + opt["duration_frames"]
                    - (
                        opt.get(
                            "transition_overlap_frames",
                            0,
                        )
                        if used else 0
                    )
                )
                candidate_used = used + (opt,)

                forward_feasible = True
                if forward and i + 1 < len(beats):
                    forward_feasible, lookahead_cost = has_future(
                        beats[i + 1:],
                        candidate_used,
                        next_frame,
                        i + 1,
                    )
                    # (P1-35) lookahead work counts against node_budget
                    spent += lookahead_cost
                    if spent > budget:
                        return {
                            "status": "SEARCH_BUDGET_EXHAUSTED",
                            "reason": "node_budget_exceeded_in_forward_check",
                            "nodes_visited": spent,
                        }
                if not forward_feasible:
                    trace.append({
                        "event": "forward_prune",
                        "beat": i,
                        "option": opt.get("shot_id"),
                        "reason": (
                            "future_beat_has_no_"
                            "hard_valid_option"
                        ),
                    })
                    continue

                next_states.append((
                    score + float(
                        opt.get(
                            "quality_score", 0.0
                        )
                    ),
                    candidate_used,
                    next_frame,
                ))

        next_states.sort(
            key=lambda entry: (
                -entry[0],
                [
                    o.get("shot_id")
                    for o in entry[1]
                ],
            )
        )

        if len(next_states) > width:
            pruned_beam = True
            for item in next_states[width:]:
                trace.append({
                    "event": "beam_prune",
                    "beat": i,
                    "option": (
                        item[1][-1].get("shot_id")
                    ),
                    "reason": "beam_width",
                })

        beam = next_states[:width]
        if not beam:
            break

    for score, used, frame in beam:
        checked = _validate_solution(
            list(used), beats, constraints
        )
        if checked["valid"]:
            return {
                "status": "SOLUTION_FOUND",
                "domain_sha256": domain_sha,
                "score": score,
                "shots": [
                    s["shot_id"] for s in used
                ],
                "edit_plan": list(used),
                "validation": checked,
                "nodes_visited": spent,
                "trace": trace,
                "exact_checker_used": False,
            }

    if exact:
        checked_nodes = 0
        found: tuple[dict, ...] | None = None
        best_score = float("-inf")
        incomplete = False

        def dfs(
            i: int,
            chosen: tuple[dict, ...],
            frame: int,
            score: float,
        ) -> None:
            nonlocal checked_nodes
            nonlocal found
            nonlocal best_score
            nonlocal incomplete

            if incomplete:
                return

            if i == len(beats):
                verdict = _validate_solution(
                    list(chosen),
                    beats,
                    constraints,
                )
                if (
                    verdict["valid"]
                    and score > best_score
                ):
                    found = chosen
                    best_score = score
                return

            for opt in beats[i]:
                checked_nodes += 1

                if checked_nodes > exact_limit:
                    incomplete = True
                    return

                if _option_reasons(
                    opt,
                    constraints,
                    i,
                    chosen,
                    frame,
                ):
                    continue

                new_frame = (
                    frame
                    + opt["duration_frames"]
                    - (
                        opt.get(
                            "transition_overlap_frames",
                            0,
                        )
                        if chosen else 0
                    )
                )
                dfs(
                    i + 1,
                    chosen + (opt,),
                    new_frame,
                    score + float(
                        opt.get(
                            "quality_score", 0.0
                        )
                    ),
                )

        dfs(0, tuple(), 0, 0.0)

        if incomplete:
            return {
                "status": (
                    "SEARCH_BUDGET_EXHAUSTED"
                ),
                "reason": (
                    "exact_checker_budget"
                ),
                "domain_sha256": domain_sha,
                "checker": CHECKER_VERSION,
                "exact_nodes_visited": (
                    checked_nodes
                ),
                "trace": trace,
            }

        if found is not None:
            verdict = _validate_solution(
                list(found),
                beats,
                constraints,
            )
            return {
                "status": "SOLUTION_FOUND",
                "domain_sha256": domain_sha,
                "score": best_score,
                "shots": [
                    s["shot_id"] for s in found
                ],
                "edit_plan": list(found),
                "validation": verdict,
                "exact_checker_used": True,
                "checker": CHECKER_VERSION,
                "exact_nodes_visited": (
                    checked_nodes
                ),
                "trace": trace,
            }

        return {
            "status": (
                "PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN"
            ),
            "domain_sha256": domain_sha,
            "checker": CHECKER_VERSION,
            "proof": {
                "exhaustively_visited_nodes": (
                    checked_nodes
                ),
                "fully_enumerated": True,
                "constraints_sha256": digest(
                    constraints
                ),
            },
            "trace": trace,
        }

    return {
        "status": (
            "SEARCH_BUDGET_EXHAUSTED"
            if pruned_beam
            else "CANDIDATE_SET_EXHAUSTED"
        ),
        "reason": (
            "beam_pruned_potential_solution"
            if pruned_beam
            else
            "search_frontier_empty_without_exact_proof"
        ),
        "domain_sha256": domain_sha,
        "trace": trace,
        "nodes_visited": spent,
    }


def approval_proposal(params: dict) -> dict:
    """Proposal only. Swift ProjectStore is the approval authority."""
    script = dict(
        params.get("candidate") or {}
    )
    cuts = dict(
        params.get("cut_result") or {}
    )
    voice = _required_list(
        params.get("voice_trials"),
        "voice_trials",
        48,
    )

    if (
        script.get("status")
        != "DRAFT_NOT_BUILDABLE"
        or not script.get("beats")
    ):
        return {
            "status": "blocked_script_not_validated"
        }

    if any(
        b.get("status")
        == "requires_claim_revalidation"
        for b in script["beats"]
    ):
        return {
            "status": "blocked_claim_revalidation"
        }

    if (
        cuts.get("status")
        != "SOLUTION_FOUND"
        or cuts.get(
            "validation", {}
        ).get("valid") is not True
    ):
        return {
            "status": "blocked_no_valid_cut"
        }

    if len(voice) != len(script["beats"]):
        return {
            "status": "blocked_missing_voice"
        }

    if any(
        v.get("speech_review_status")
        != "verified"
        or v.get("publication_state")
        != "COMMITTED"
        or not v.get("publication_id")
        or not v.get(
            "wav", {}
        ).get("sha256")
        or v.get("beat_id")
        != beat.get("beat_id")
        or v.get("script_revision_id")
        != script.get(
            "script_revision_id"
        )
        or v.get("text_fingerprint")
        != digest(
            beat.get(
                "voice_text", ""
            ).encode("utf-8")
        )
        for beat, v in zip(
            script["beats"], voice
        )
    ):
        return {
            "status": "blocked_voice_or_publication"
        }

    evidence = _required_list(
        params.get("claim_revisions", []),
        "claim_revisions",
        256,
    )

    expected = set(
        script.get("claim_revision_ids", [])
    )
    actual = {
        str(c.get("revision_id"))
        for c in evidence
        if (
            c.get("support_status")
            == "supported"
            and c.get(
                "scope_revalidation_status"
            ) == "complete"
            and c.get("allowed_use") in (
                "direct_claim",
                "attributed_or_qualified",
            )
        )
    }

    if expected - actual:
        return {
            "status": (
                "blocked_claim_revision_mismatch"
            ),
            "missing_revisions": sorted(
                expected - actual
            ),
        }

    manifest = {
        "schema_version": (
            "g3-approval-proposal-v1"
        ),
        "script_revision_id": (
            script["script_revision_id"]
        ),
        "scope_revision_id": (
            script["scope_revision_id"]
        ),
        "claim_revision_ids": sorted(
            expected
        ),
        "constraints_sha256": digest(
            script.get("constraints", {})
        ),
        "storyboard_sha256": digest(
            script["beats"]
        ),
        "voice_publications": [{
            "beat_id": v["beat_id"],
            "text_sha256": (
                v["text_fingerprint"]
            ),
            "publication_id": (
                v["publication_id"]
            ),
            "sha256": v["wav"]["sha256"],
        } for v in voice],
        "edit_plan_sha256": digest(
            cuts["edit_plan"]
        ),
        "domain_sha256": (
            cuts["domain_sha256"]
        ),
        "total_frames": (
            cuts["validation"][
                "timeline_frames"
            ]
        ),
        "timeline_profile": "M-24-SDR-v1",
        "approval_type": "script_approval",
    }

    return {
        "status": (
            "ready_for_core_transaction_"
            "not_approved"
        ),
        "manifest": manifest,
        "manifest_sha256": digest(
            manifest
        ),
    }


def script_ready_metrics(params: dict) -> dict:
    """Measure AI-03 only at script_ready on locked held-out labels."""
    rows = _required_list(
        params.get(
            "human_labeled_claim_uses", []
        ),
        "human_labeled_claim_uses",
        100_000,
    )
    presented = set(
        _required_list(
            params.get(
                "presented_candidate_ids", []
            ),
            "presented_candidate_ids",
            1_000,
        )
    )

    if (
        not rows
        or not presented
        or params.get("evaluation_split")
        != "held_out"
        or params.get("oracle_locked")
        is not True
    ):
        return {
            "checkpoint": "script_ready",
            "result": "NOT_RUN",
            "accepted_claim_support_precision": None,
            "denominator": 0,
            "critical_false_accept_count": None,
            "interval_95": None,
            "reason": (
                "requires all presented candidates, "
                "independently locked held-out labels"
            ),
        }

    seen = set()
    captured = set()
    correct = 0
    accepted = 0
    critical_false = 0
    groups = set()

    for row in rows:
        cid = str(
            row.get("candidate_id", "")
        )
        claim_id = str(
            row.get("claim_id", "")
        )
        group = str(
            row.get("trip_group_id", "")
        )
        key = (cid, claim_id)

        if (
            not cid
            or not claim_id
            or not group
            or key in seen
            or cid not in presented
        ):
            return {
                "checkpoint": "script_ready",
                "result": (
                    "INVALID_EVALUATION_SET"
                ),
                "reason": (
                    "duplicate/missing/out-of-scope label"
                ),
            }

        for field in (
            "accepted_for_narration",
            "oracle_supported",
            "critical",
        ):
            if type(row.get(field)) is not bool:
                return {
                    "checkpoint": "script_ready",
                    "result": (
                        "INVALID_EVALUATION_SET"
                    ),
                    "reason": (
                        f"missing boolean {field}"
                    ),
                }

        seen.add(key)
        captured.add(cid)
        groups.add(group)

        if row["accepted_for_narration"]:
            accepted += 1
            correct += int(
                row["oracle_supported"]
            )
            if (
                row["critical"]
                and not row["oracle_supported"]
            ):
                critical_false += 1

    if (
        captured != presented
        or accepted == 0
    ):
        return {
            "checkpoint": "script_ready",
            "result": "NOT_RUN",
            "reason": (
                "not all presented candidates "
                "evaluated, or accepted "
                "denominator is zero"
            ),
            "denominator": accepted,
        }

    p = correct / accepted
    z = 1.95996398454
    denominator = 1 + (
        z * z / accepted
    )
    center = (
        p + z*z/(2*accepted)
    ) / denominator
    half = (
        z * math.sqrt(
            (p*(1-p)/accepted)
            + (
                z*z /
                (4*accepted*accepted)
            )
        ) / denominator
    )

    return {
        "checkpoint": "script_ready",
        "evaluation_split": "held_out",
        "result": (
            "PASS"
            if (
                p >= 0.98
                and critical_false == 0
                and len(groups) >= 5
            )
            else
            "FAIL_OR_INSUFFICIENT_GROUPS"
        ),
        "accepted_claim_support_precision": round(
            p, 6
        ),
        "accepted_correct": correct,
        "denominator": accepted,
        "critical_false_accept_count": (
            critical_false
        ),
        "interval_95": [
            round(
                max(0.0, center - half), 6
            ),
            round(
                min(1.0, center + half), 6
            ),
        ],
        "interval_method": (
            "Wilson_95_descriptive; "
            "group_bootstrap_not_run"
        ),
        "trip_group_count": len(groups),
        "presented_candidate_count": (
            len(presented)
        ),
    }
