"""
tests/test_s11_vision_pixel_budget.py — Vision prefill budget for G2 analysis.

Rules under test:
  * the registry's declared `default_pixel_budget` is the runtime default;
  * the env override is validated fail-closed (no silent fallback);
  * downscaling preserves the aspect ratio, keeps dimensions even, and never
    exceeds the budget;
  * sources already inside the budget are passed through untouched;
  * the declared default in code and in the registry lock cannot drift apart.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if _p.as_posix() not in sys.path:
        sys.path.insert(0, _p.as_posix())

from aivideo_workers.pipeline_adapters import (  # noqa: E402
    DEFAULT_VISION_PIXEL_CAP,
    MAX_VISION_PIXEL_CAP,
    MIN_VISION_PIXEL_CAP,
    PipelineAdapterError,
    resolve_vision_pixel_cap,
    vision_frame_target_size,
)

REGISTRY = _ROOT / "contracts" / "s11_model_registry.lock.json"


class TestVisionPixelCapResolution(unittest.TestCase):
    def test_default_matches_registry_declared_budget(self) -> None:
        registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
        declared = registry["runtime_profiles"]["P-VISION-DEV-v1"]["default_pixel_budget"]
        self.assertEqual(DEFAULT_VISION_PIXEL_CAP, declared)
        self.assertEqual(resolve_vision_pixel_cap(""), declared)

    def test_env_override_is_honoured(self) -> None:
        self.assertEqual(resolve_vision_pixel_cap("262144"), 262144)
        self.assertEqual(resolve_vision_pixel_cap(" 1048576 "), MAX_VISION_PIXEL_CAP)

    def test_malformed_override_fails_closed(self) -> None:
        for bad in ("abc", "58982.4", "-1"):
            with self.assertRaises(PipelineAdapterError) as ctx:
                resolve_vision_pixel_cap(bad)
            self.assertEqual(ctx.exception.code, "INVALID_VISION_PIXEL_CAP")

    def test_out_of_range_override_fails_closed(self) -> None:
        for bad in (MIN_VISION_PIXEL_CAP - 1, MAX_VISION_PIXEL_CAP + 1, 0):
            with self.assertRaises(PipelineAdapterError) as ctx:
                resolve_vision_pixel_cap(str(bad))
            self.assertEqual(ctx.exception.code, "INVALID_VISION_PIXEL_CAP")


class TestVisionFrameTargetSize(unittest.TestCase):
    def test_1080x1920_is_capped_to_declared_budget(self) -> None:
        width, height = vision_frame_target_size(1080, 1920, DEFAULT_VISION_PIXEL_CAP)
        self.assertLessEqual(width * height, DEFAULT_VISION_PIXEL_CAP)
        self.assertGreater(width * height, DEFAULT_VISION_PIXEL_CAP * 0.95)
        self.assertEqual(width % 2, 0)
        self.assertEqual(height % 2, 0)

    def test_aspect_ratio_is_preserved(self) -> None:
        for src_w, src_h in ((1080, 1920), (3840, 2160), (1920, 1080), (1440, 1080)):
            width, height = vision_frame_target_size(src_w, src_h, 262144)
            self.assertLessEqual(width * height, 262144)
            source_ratio = src_w / src_h
            target_ratio = width / height
            self.assertAlmostEqual(target_ratio / source_ratio, 1.0, delta=0.01,
                                   msg=f"aspect drift for {src_w}x{src_h}")

    def test_small_source_is_not_upscaled(self) -> None:
        self.assertEqual(vision_frame_target_size(320, 240, DEFAULT_VISION_PIXEL_CAP), (320, 240))

    def test_odd_small_source_is_made_even(self) -> None:
        self.assertEqual(vision_frame_target_size(321, 241, DEFAULT_VISION_PIXEL_CAP), (320, 240))

    def test_invalid_inputs_are_rejected(self) -> None:
        with self.assertRaises(PipelineAdapterError):
            vision_frame_target_size(0, 1920, DEFAULT_VISION_PIXEL_CAP)
        with self.assertRaises(PipelineAdapterError):
            vision_frame_target_size(1080, 1920, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
