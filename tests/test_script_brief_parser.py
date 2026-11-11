"""
tests/test_script_brief_parser.py — Wedding facts must survive the Swift -> Python seam.

`ScriptBriefRecord.composeText` (packages/AIVideoCore/Sources/Storage/ProjectStore.swift)
emits one natural Vietnamese sentence per filled fact; the G2 worker parses that
text with `parse_raw_brief_to_drafts`. These tests pin the contract:
  * each filled fact becomes exactly one draft, spans map back to the text;
  * "Bắt buộc có cảnh: …" is a must_use constraint, "Không quay: …" is must_not_use;
  * the shooting style is a style preference, not a visual fact;
  * an empty form composes to "" (no demo brief can leak back in).
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers.semantic_verifier import parse_raw_brief_to_drafts

_EVENT_LABELS = {
    "dam_hoi": "Lễ đám hỏi",
    "vu_quy": "Lễ vu quy",
    "thanh_hon": "Lễ thành hôn",
    "tiec_cuoi": "Tiệc cưới",
    "ca_ngay": "Cả ngày cưới",
}
_STYLE_LABELS = {
    "fine_art": "Fine-art",
    "cinematic": "Cinematic",
    "documentary": "Documentary",
    "truyen_thong": "Truyền thống",
    "vui_nhon": "Vui nhộn",
}
_PLATFORM_LABELS = {
    "tiktok": "TikTok",
    "reels": "Instagram Reels",
    "shorts": "YouTube Shorts",
    "youtube": "YouTube",
}


def _clean(value: str) -> str:
    text = value.strip()
    while text.endswith(".") or text.endswith(";"):
        text = text[:-1]
    return text


def compose_text(
    couple_names: str = "",
    event_type: str = "vu_quy",
    schedule: str = "",
    venues: str = "",
    pov_role: str = "",
    style: str = "cinematic",
    must_have: str = "",
    must_avoid: str = "",
    platform: str = "tiktok",
    target_seconds: int = 30,
    notes: str = "",
) -> str:
    """Python mirror of ScriptBriefRecord.composeText (same order, same wording)."""
    couple = _clean(couple_names)
    event = _EVENT_LABELS.get(event_type, _EVENT_LABELS["vu_quy"])
    day, place = _clean(schedule), _clean(venues)
    role, must, avoid, note = _clean(pov_role), _clean(must_have), _clean(must_avoid), _clean(notes)

    lines: list[str] = []
    if couple:
        lines.append(f"Đám cưới của {couple}, {event.lower()}.")
    elif day or place:
        lines.append(f"{event}.")
    if day:
        lines.append(f"Lịch ngày: {day}.")
    if place:
        lines.append(f"Địa điểm: {place}.")
    if role:
        lines.append(f"Góc POV: {role}.")
    if must:
        lines.append(f"Bắt buộc có cảnh: {must}.")
    if avoid:
        lines.append(f"Không quay: {avoid}.")
    # Style/platform are menu defaults: only meaningful once a real fact exists.
    if any((couple, day, place, role, must, avoid, note)):
        if _clean(style):
            lines.append(f"Phong cách: {_STYLE_LABELS.get(style, _STYLE_LABELS['cinematic'])}.")
        if _clean(platform):
            lines.append(f"Nền tảng {_PLATFORM_LABELS.get(platform, _PLATFORM_LABELS['tiktok'])}, {target_seconds} giây.")
    if note:
        lines.append(f"Ghi chú: {note}.")
    return "\n".join(lines)


class TestWeddingBriefParser(unittest.TestCase):
    def _parse(self, text: str):
        return parse_raw_brief_to_drafts(
            brief_revision_id="brief-test-001",
            workday_id="wd-test-001",
            raw_brief_text=text,
            explicit_timezone_iana=None,
        )

    def test_full_wedding_brief_yields_one_draft_per_fact(self) -> None:
        text = compose_text(
            couple_names="Linh & Minh",
            event_type="vu_quy",
            schedule="24/11 · 7h30 đón dâu · 11h gia tiên",
            venues="Tư gia Q7 · White Palace",
            pov_role="Thợ ảnh đi cùng ekip từ 5h sáng",
            style="cinematic",
            must_have="trao nhẫn, mẹ chải tóc, lì xì",
            must_avoid="khách chưa xin phép",
        )
        drafts = self._parse(text)

        self.assertEqual(len(drafts), 8, [d.raw_span_text for d in drafts])
        self.assertEqual([d.start_char for d in drafts], sorted(d.start_char for d in drafts))

        # Evidence: every span points back at the exact text it came from.
        for draft in drafts:
            self.assertEqual(text[draft.start_char : draft.end_char], draft.raw_span_text)
            self.assertEqual(draft.brief_revision_id, "brief-test-001")

        by_prefix = {d.raw_span_text.split(":", 1)[0]: d for d in drafts}

        couple = drafts[0]
        self.assertEqual(couple.item_kind, "event_fact")
        self.assertIn("Linh & Minh", couple.raw_span_text)

        self.assertEqual(by_prefix["Lịch ngày"].item_kind, "event_fact")
        self.assertIn("7h", by_prefix["Lịch ngày"].reported_time_text or "")

        self.assertEqual(by_prefix["Phong cách"].item_kind, "style_preference")
        self.assertEqual(by_prefix["Phong cách"].constraint_type, "preferred")

        must = by_prefix["Bắt buộc có cảnh"]
        self.assertEqual(must.item_kind, "usage_constraint")
        self.assertEqual(must.constraint_type, "must_use")
        self.assertFalse(must.is_negated)

        avoid = by_prefix["Không quay"]
        self.assertEqual(avoid.item_kind, "usage_constraint")
        self.assertEqual(avoid.constraint_type, "must_not_use")
        self.assertTrue(avoid.is_negated)

    def test_empty_form_composes_to_nothing(self) -> None:
        """An untouched form must send nothing — never a seeded demo sentence."""
        self.assertEqual(compose_text(), "")
        self.assertEqual(self._parse(""), [])

    def test_partial_brief_only_emits_filled_facts(self) -> None:
        text = compose_text(couple_names="Linh & Minh")
        drafts = self._parse(text)
        # Couple + the style/platform defaults; nothing the user left empty.
        self.assertEqual(len(drafts), 3, [d.raw_span_text for d in drafts])
        self.assertEqual(drafts[0].raw_span_text, "Đám cưới của Linh & Minh, lễ vu quy")

    def test_must_have_several_shots_stays_one_constraint(self) -> None:
        text = compose_text(must_have="trao nhẫn, mẹ chải tóc, lì xì")
        drafts = self._parse(text)
        must = [d for d in drafts if d.raw_span_text.startswith("Bắt buộc có cảnh")]
        self.assertEqual(len(must), 1, [d.raw_span_text for d in drafts])
        self.assertEqual(must[0].item_kind, "usage_constraint")
        self.assertEqual(must[0].constraint_type, "must_use")
        self.assertIn("mẹ chải tóc", must[0].raw_span_text)


if __name__ == "__main__":
    unittest.main()
