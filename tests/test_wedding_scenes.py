"""
tests/test_wedding_scenes.py — Wedding scene taxonomy for the local VLM.

The taxonomy is what turns "cô dâu và chú rể đứng cạnh nhau" into a usable
edit label, so these tests pin both sides of the contract:
  * a real ceremony cue is detected (trao nhẫn, gia tiên, lì xì, mẹ chải tóc…);
  * generic wedding words are NOT labels (no guessing, Unknown stays Unknown);
  * the rendered sentence only lists what was actually detected.
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers.wedding_scenes import (
    WEDDING_SCENES,
    detect_wedding_scenes,
    prompt_guide,
    wedding_scene_labels,
    wedding_scene_sentence,
)


class TestWeddingScenes(unittest.TestCase):
    def test_each_ceremony_moment_is_detected_from_its_cue(self) -> None:
        samples = {
            "dam_hoi": "Đoàn nhà trai bê mâm quả sang nhà gái trong lễ ăn hỏi.",
            "chai_toc": "Mẹ chải tóc cho cô dâu trước giờ xuất phát.",
            "ruoc_dau": "Đoàn rước dâu qua cổng hoa nhà trai.",
            "gia_tien": "Cô dâu chú rể thắp hương và lạy ông bà trước bàn thờ.",
            "thanh_le": "Linh mục làm phép trong thánh lễ tại nhà thờ.",
            "trao_nhan": "Chú rể đeo nhẫn cưới cho cô dâu.",
            "li_xi": "Bố mẹ trao phong bao lì xì cho hai con.",
            "chup_hinh": "Ekip chụp ảnh tạo dáng cho cô dâu bên cổng hoa.",
            "tiec_cuoi": "Khách nâng ly trong bàn tiệc cưới.",
            "nhay_mo_man": "Ekip nhảy mở màn trên sân khấu.",
        }
        for key, text in samples.items():
            with self.subTest(key=key):
                self.assertIn(key, detect_wedding_scenes(text))

    def test_generic_wedding_words_are_not_labels(self) -> None:
        """Saying it is a wedding is not the same as naming the moment."""
        generic = [
            "Cô dâu và chú rể đứng cạnh nhau trong đám cưới.",
            "Một đám cưới đông người, nhiều hoa và đèn.",
            "Người thân chúc mừng cặp đôi.",
        ]
        for text in generic:
            with self.subTest(text=text):
                self.assertEqual(detect_wedding_scenes(text), [])

    def test_labels_are_ordered_and_deduplicated(self) -> None:
        text = "Trao nhẫn rồi trao lì xì, sau đó mẹ chải tóc và lạy gia tiên."
        keys = detect_wedding_scenes(text)
        self.assertEqual(keys, ["chai_toc", "gia_tien", "trao_nhan", "li_xi"])
        self.assertEqual(len(keys), len(set(keys)))

    def test_case_and_unicode_variants_still_match(self) -> None:
        # Decomposed (NFD) Vietnamese input must match the NFC cues.
        nfd = "Me\u0309 cha\u0309i to\u0301c cho co\u0302 da\u0302u"
        self.assertIn("chai_toc", detect_wedding_scenes(nfd))
        self.assertIn("trao_nhan", detect_wedding_scenes("TRAO NHẪN CƯỚI"))

    def test_empty_or_unrelated_text_yields_nothing(self) -> None:
        for text in ("", "   ", "Con đường đèo sương mù buổi sáng."):
            with self.subTest(text=text):
                self.assertEqual(detect_wedding_scenes(text), [])
                self.assertEqual(wedding_scene_sentence(detect_wedding_scenes(text)), "")

    def test_rendered_sentence_lists_only_detected_labels(self) -> None:
        keys = detect_wedding_scenes("Đeo nhẫn cưới xong thì khách nâng ly.")
        self.assertEqual(wedding_scene_labels(keys), ["trao nhẫn", "tiệc cưới"])
        self.assertEqual(
            wedding_scene_sentence(keys),
            "Cảnh cưới nhận diện: trao nhẫn, tiệc cưới.",
        )

    def test_prompt_guide_names_every_label(self) -> None:
        guide = prompt_guide()
        for scene in WEDDING_SCENES:
            self.assertIn(scene.label_vi, guide)
        self.assertIn("không suy đoán", guide)


if __name__ == "__main__":
    unittest.main()
