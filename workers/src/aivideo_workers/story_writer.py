"""Local LLM script writer for G3 (S16) — Qwen3-8B-4bit via MLX.

The registry has always declared `P-STORY-SYNTH-v1` (`mlx-community/Qwen3-8B-4bit`,
role `story_script_synthesis`), but `g3_engine.generate_story` only pasted claim
text together. This module adds the missing call site under strict evidence
rules:

- the model may only REWRITE the wording of an already-approved claim;
- it cannot add, drop, reorder or merge beats, and cannot introduce claim ids
  that were not in the eligible set;
- any schema / fact / diacritic violation raises, and the caller falls back to
  the deterministic (verbatim claim) text. A failed rewrite never fabricates a
  script and never blocks the pipeline;
- 100% local: weights must already exist on disk (`HF_HUB_OFFLINE=1`), no cloud
  fallback, no download at inference time.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import time
from typing import Any, Dict, List, Optional, Sequence

STORY_PROFILE_ID = "P-STORY-SYNTH-v1"
STORY_MODEL_ID = "mlx-community/Qwen3-8B-4bit"
STORY_MODEL_DIR_ENV = "AIVIDEO_STORY_MODEL_DIR"
PROMPT_VERSION = "pov-rewrite-v1"
MAX_INPUT_BEATS = 24
MIN_TEXT_CHARS = 8
MAX_TEXT_CHARS = 320

_DIACRITIC_RE = re.compile(r"[ăâđêôơưàáảãạằắẳẵặầấẩẫậèéẻẽẹềếểễệìíỉĩịòóỏõọồốổỗộờớởỡợùúủũụừứửữựỳýỷỹỵ]", re.IGNORECASE)
_DIGITS_RE = re.compile(r"\d+")
_JSON_OBJECT_RE = re.compile(r"\{.*\}", re.DOTALL)

_STORY_MODEL_CACHE: Dict[str, Any] = {}


class StoryWriterError(RuntimeError):
    """Raised when the local writer cannot produce a valid, faithful rewrite."""

    def __init__(self, code: str, message: str, *, detail: str = "") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


class StoryWriterUnavailable(StoryWriterError):
    def __init__(self, message: str, *, detail: str = "") -> None:
        super().__init__("STORY_MODEL_UNAVAILABLE", message, detail=detail)


def resolve_story_model_dir(explicit: Optional[str] = None) -> Path:
    raw = explicit or os.environ.get(STORY_MODEL_DIR_ENV, "")
    path = Path(raw).expanduser() if raw else (
        Path.home() / "Library" / "Application Support" / "AIVideo" / "Models" / "story_synthesis"
    )
    return path.resolve()


def story_model_available(model_dir: Optional[str] = None) -> bool:
    directory = resolve_story_model_dir(model_dir)
    return (directory / "model.safetensors").is_file() and (directory / "config.json").is_file()


SYSTEM_PROMPT = """Bạn là biên tập viên kịch bản video POV du lịch tiếng Việt.

Viết lại lời kể cho từng beat thành câu kể tự nhiên ở NGÔI THỨ NHẤT (tôi / chúng tôi), như đang nhớ lại chuyến đi.

Quy tắc bắt buộc:
1. KHÔNG lặp lại nguyên văn câu claim: phải đổi cấu trúc câu và cách diễn đạt.
2. Chỉ dùng dữ kiện có trong claim. Không thêm địa danh, con số, mốc thời gian, sự kiện mới.
3. Không gộp beat, không bỏ beat, không đổi thứ tự, không đổi beat_id hay claim_id.
4. voice_text: 12-45 từ, tiếng Việt CÓ DẤU, một đoạn, không xuống dòng, không markdown.
5. Claim nào là lời người khác kể lại thì giữ sắc thái đó ("được kể rằng", "nghe nói").

Ví dụ:
claim: "Đoạn đường đèo uốn lượn, hai bên là rừng thông."
voice_text: "Tôi đi qua con đèo uốn theo triền núi, hai bên là rừng thông."

Chỉ trả về JSON đúng schema, không giải thích:
{"beats":[{"beat_id":"...","claim_id":"...","voice_text":"..."}]}"""


def _normalize(text: str) -> str:
    return " ".join(str(text).split())


def build_prompt(beats: Sequence[Dict[str, Any]]) -> str:
    payload = [
        {
            "beat_id": beat["beat_id"],
            "claim_id": beat["claim_refs"][0]["claim_id"],
            "claim": _normalize(beat["_claim_text"]),
            "narrative_type": beat.get("narrative_type", "evidence_backed"),
        }
        for beat in beats
    ]
    return (
        "Viết lại lời kể cho các beat sau. Trả về JSON.\n"
        + json.dumps(payload, ensure_ascii=False, indent=1)
    )


def parse_and_validate(raw_text: str, beats: Sequence[Dict[str, Any]]) -> List[Dict[str, str]]:
    """Parse model output and enforce schema + faithfulness. Raises StoryWriterError."""
    match = _JSON_OBJECT_RE.search(raw_text or "")
    if not match:
        raise StoryWriterError(
            "STORY_OUTPUT_NOT_JSON",
            "Model output contains no JSON object",
            detail=(raw_text or "")[:300],
        )
    try:
        payload = json.loads(match.group(0))
    except ValueError as exc:
        raise StoryWriterError(
            "STORY_OUTPUT_INVALID_JSON",
            f"Model output is not valid JSON: {exc}",
            detail=(raw_text or "")[:300],
        ) from exc

    if not isinstance(payload, dict) or not isinstance(payload.get("beats"), list):
        raise StoryWriterError("STORY_OUTPUT_SCHEMA", "Expected {'beats': [...]} object")

    items = payload["beats"]
    if len(items) != len(beats):
        raise StoryWriterError(
            "STORY_BEAT_COUNT_MISMATCH",
            f"Model returned {len(items)} beats for {len(beats)} approved claims",
        )

    validated: List[Dict[str, str]] = []
    for index, (item, beat) in enumerate(zip(items, beats)):
        if not isinstance(item, dict):
            raise StoryWriterError("STORY_OUTPUT_SCHEMA", f"Beat #{index} is not an object")
        expected_beat = beat["beat_id"]
        expected_claim = beat["claim_refs"][0]["claim_id"]
        if item.get("beat_id") != expected_beat:
            raise StoryWriterError(
                "STORY_BEAT_ORDER_CHANGED",
                f"Beat #{index}: expected {expected_beat}, got {item.get('beat_id')!r}",
            )
        if item.get("claim_id") != expected_claim:
            raise StoryWriterError(
                "STORY_CLAIM_ID_CHANGED",
                f"Beat {expected_beat}: expected claim {expected_claim}, got {item.get('claim_id')!r}",
            )
        text = _normalize(item.get("voice_text") or "")
        if not MIN_TEXT_CHARS <= len(text) <= MAX_TEXT_CHARS:
            raise StoryWriterError(
                "STORY_TEXT_LENGTH",
                f"Beat {expected_beat}: voice_text length {len(text)} outside "
                f"[{MIN_TEXT_CHARS}, {MAX_TEXT_CHARS}]",
            )
        if "\ufffd" in text or "�" in text:
            raise StoryWriterError(
                "STORY_TEXT_CORRUPTED", f"Beat {expected_beat}: replacement characters in output"
            )
        if not _DIACRITIC_RE.search(text):
            raise StoryWriterError(
                "STORY_TEXT_NO_DIACRITICS",
                f"Beat {expected_beat}: Vietnamese text without diacritics",
                detail=text[:120],
            )
        claim_text = _normalize(beat["_claim_text"])
        invented = {d for d in _DIGITS_RE.findall(text) if d not in _DIGITS_RE.findall(claim_text)}
        if invented:
            raise StoryWriterError(
                "STORY_INVENTED_FACT",
                f"Beat {expected_beat}: numbers {sorted(invented)} are not in the claim",
                detail=text[:120],
            )
        # (P1-37) Checking digits alone let the model add places, people and events the
        # claim never mentioned. Every capitalised proper noun (and every token that looks
        # like a Vietnamese place name) must already appear in the claim.
        invented_entities = _invented_entities(text, claim_text)
        if invented_entities:
            raise StoryWriterError(
                "STORY_INVENTED_ENTITY",
                f"Beat {expected_beat}: names/places {invented_entities} are not in the claim",
                detail=text[:120],
            )
        validated.append({"beat_id": expected_beat, "claim_id": expected_claim, "voice_text": text})
    return validated


class LLMStoryWriter:
    """Thin, cached MLX wrapper around the pinned story model."""

    def __init__(
        self,
        model_dir: Optional[str] = None,
        max_output_tokens: int = 1024,
        temperature: float = 0.3,
    ) -> None:
        self.model_dir = resolve_story_model_dir(model_dir)
        if not story_model_available(str(self.model_dir)):
            raise StoryWriterUnavailable(
                f"Story model is not installed at {self.model_dir}",
                detail="run the story-model setup step first (offline inference never downloads)",
            )
        self.max_output_tokens = max_output_tokens
        self.temperature = temperature

    def _engine(self):
        key = str(self.model_dir)
        engine = _STORY_MODEL_CACHE.get(key)
        if engine is not None:
            return engine
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        try:
            from mlx_lm import load
        except ImportError as exc:  # pragma: no cover - environment dependent
            raise StoryWriterUnavailable("mlx-lm is not installed in the worker venv", detail=str(exc)) from exc
        try:
            model, tokenizer = load(key)
        except Exception as exc:  # noqa: BLE001 - surfaced with context
            raise StoryWriterUnavailable(
                f"Failed to load story model from {key}", detail=f"{type(exc).__name__}: {exc}"
            ) from exc
        engine = (model, tokenizer)
        _STORY_MODEL_CACHE[key] = engine
        return engine

    def _render_prompt(self, tokenizer, user_prompt: str) -> str:
        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ]
        try:
            return tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True, enable_thinking=False
            )
        except TypeError:
            return tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True
            )

    def rewrite(self, beats: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
        """Rewrite approved beats in place-safe form; returns validated beats + meta."""
        if not beats:
            raise StoryWriterError("STORY_NO_BEATS", "No beats to rewrite")
        if len(beats) > MAX_INPUT_BEATS:
            raise StoryWriterError(
                "STORY_TOO_MANY_BEATS", f"{len(beats)} beats exceeds the {MAX_INPUT_BEATS} limit"
            )
        missing = [b["beat_id"] for b in beats if not b.get("_claim_text")]
        if missing:
            raise StoryWriterError("STORY_MISSING_CLAIM_TEXT", f"Beats without claim text: {missing}")

        model, tokenizer = self._engine()
        from mlx_lm import generate

        user_prompt = build_prompt(beats)
        prompt = self._render_prompt(tokenizer, user_prompt)
        started = time.time()
        # mlx-lm >= 0.30 samples through an explicit sampler (the old ``temp``
        # kwarg is gone). The default 0.3 keeps the wording varied enough to be a
        # real rewrite; a fixed seed keeps re-runs reproducible.
        import mlx.core as mx
        from mlx_lm.sample_utils import make_sampler

        # Fixed seed keeps a given (claims, prompt, temperature) reproducible
        # even when sampling above zero, so a re-run cannot silently change an
        # approved script's wording.
        mx.random.seed(0)
        sampler = make_sampler(temp=max(0.0, self.temperature))
        kwargs: Dict[str, Any] = {
            "max_tokens": self.max_output_tokens,
            "verbose": False,
            "sampler": sampler,
        }
        try:
            raw = generate(model, tokenizer, prompt=prompt, **kwargs)
        except Exception as exc:  # noqa: BLE001 - surfaced with context
            raise StoryWriterError(
                "STORY_GENERATION_FAILED", f"Generation failed: {type(exc).__name__}: {exc}"
            ) from exc
        validated = parse_and_validate(raw, beats)
        return {
            "beats": validated,
            "meta": {
                "profile_id": STORY_PROFILE_ID,
                "model_id": STORY_MODEL_ID,
                "model_dir": str(self.model_dir),
                "prompt_version": PROMPT_VERSION,
                "prompt_sha256": _sha256(prompt),
                "temperature": self.temperature,
                "elapsed_seconds": round(time.time() - started, 2),
                "raw_output_sha256": _sha256(raw),
                "engine": "mlx_lm_local",
            },
        }


_SENTENCE_START = {
    "tôi", "anh", "chị", "em", "chúng", "người", "buổi", "sáng", "trưa", "chiều", "tối",
    "hôm", "ngày", "sau", "trước", "khi", "rồi", "và", "nhưng", "còn", "cả", "hai", "một",
    "đoạn", "con", "cảnh", "bên", "trên", "dưới", "từ", "ở", "vì", "nên", "thế", "đây",
    "cô", "chú", "bác", "gia", "lúc", "đến", "qua", "dọc", "theo", "mọi", "các", "những",
    # common narrative openers
    "nghe", "nhìn", "thấy", "có", "không", "chỉ", "vẫn", "rất", "hơi", "cũng", "nếu",
}


def _invented_entities(text: str, claim_text: str) -> list[str]:
    """Proper nouns used by the rewrite that the claim never mentioned.

    Vietnamese has no reliable capitalisation rule for places, so this errs towards
    flagging: a capitalised word that is not a sentence-start word and does not occur in
    the claim is treated as an invented entity. The caller falls back to the verbatim
    claim, which is always safe.
    """
    import re as _re

    # A capitalised word that does not open a sentence and never appears in the claim is
    # treated as an invented name. The claim may spell it lowercase ("nghe nói" vs
    # "Nu nghe"), so the comparison is case-insensitive on both sides.
    claim_tokens = {t.lower() for t in _re.findall(r"[^\W\d_]+", claim_text, _re.UNICODE)}
    invented: list[str] = []
    for match in _re.finditer(r"[^\W\d_]+", text, _re.UNICODE):
        word = match.group(0)
        if not word[:1].isupper():
            continue
        before = text[: match.start()].rstrip()
        sentence_start = not before or before[-1] in ".!?\n" or before.endswith(("'", "\""))
        # Sentence-openers are never evidence of a name, anywhere in the sentence: the
        # validated payload capitalises every beat ("Nghe nói…"), so position alone is not
        # a reliable signal in Vietnamese. Compare without case folding: Python's
        # `lower()` folds "Ngô" into "ngô", which would hide a real place name.
        if word[:1].lower() + word[1:] in _SENTENCE_START:
            continue
        if word.lower() in claim_tokens:
            continue
        if word not in invented:
            invented.append(word)
    return invented


def _sha256(text: str) -> str:
    import hashlib

    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def probe_writer(model_dir: Optional[str] = None) -> Dict[str, Any]:
    """Availability report without loading weights."""
    directory = resolve_story_model_dir(model_dir)
    try:
        import mlx_lm  # noqa: F401

        runtime = True
    except ImportError:
        runtime = False
    return {
        "profile_id": STORY_PROFILE_ID,
        "model_id": STORY_MODEL_ID,
        "model_dir": str(directory),
        "runtime_available": runtime,
        "weights_available": story_model_available(str(directory)),
        "prompt_version": PROMPT_VERSION,
    }
