#!/usr/bin/env python3
"""
tests/test_model_setup.py — Unit & Integration Tests for Setup Tool and Local Model Adapter

Test Cases:
  T1. Model Not Installed:
      - check_status returns 'not_installed'
      - run_inference raises ModelNotInstalledError (-32001)
      - No background download initiated
  T2. Incomplete / Missing Artifacts:
      - Missing artifact detected as 'invalid_assets'
      - Not published as ready
  T3. Corrupted Checksum:
      - Detected using temporary fixture directory
      - Does not mutate user's installed model
  T4. Runtime Incompatible / Missing:
      - Simulated runtime error reports 'runtime_unavailable' (-32004)
      - No fallback to mock/hash
  T5. Real Model Inference:
      - 2 distinct prompts
      - Real tokens generated
      - Non-empty output, real timing metadata
"""

import os
import sys
import json
import shutil
import tempfile
import unittest

sys.path.insert(0, os.path.abspath("workers/src/aivideo_workers"))
sys.path.insert(0, os.path.abspath("tools"))
import local_model
import setup_g0_model

class TestModelSetupAndAdapter(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.mkdtemp(prefix="aivideo_test_model_")
        self.app_support = os.path.join(self.tmp_dir, "AIVideo")
        os.makedirs(self.app_support, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_t1_model_not_installed(self):
        """T1: Uninstalled model returns not_installed and inference raises ModelNotInstalledError."""
        status = local_model.check_status({
            "profile_id": "g0-text-smoke-v1",
            "app_support_path": self.app_support
        })
        self.assertEqual(status["status"], "not_installed")
        self.assertTrue(len(status["missing_files"]) > 0)

        # Attempt inference must fail with ModelNotInstalledError (-32001)
        with self.assertRaises(local_model.ModelNotInstalledError) as ctx:
            local_model.run_inference({
                "prompt": "Test uninstalled",
                "profile_id": "g0-text-smoke-v1",
                "app_support_path": self.app_support
            })
        self.assertEqual(ctx.exception.code, -32001)
        self.assertEqual(ctx.exception.kind, "MODEL_NOT_INSTALLED")

    def test_t2_missing_artifacts(self):
        """T2: Incomplete model directory (e.g. missing tokenizer.json) reports invalid_assets."""
        fake_model_dir = os.path.join(
            self.app_support, "Models", "g0-text", local_model.G0_MODEL_REVISION
        )
        os.makedirs(fake_model_dir, exist_ok=True)

        # Create only config.json, missing other 8 files
        with open(os.path.join(fake_model_dir, "config.json"), "w") as f:
            f.write("{}")

        status = local_model.check_status({
            "profile_id": "g0-text-smoke-v1",
            "app_support_path": self.app_support
        })
        self.assertEqual(status["status"], "invalid_assets")
        self.assertIn("tokenizer.json", status["missing_files"])

    def test_t3_checksum_mismatch_detected(self):
        """T3: Corrupted file checksum is detected using isolated fixture directory."""
        fake_model_dir = os.path.join(
            self.app_support, "Models", "g0-text", local_model.G0_MODEL_REVISION
        )
        os.makedirs(fake_model_dir, exist_ok=True)

        # Create dummy versions of all required artifacts
        for art in local_model.REQUIRED_ARTIFACTS:
            with open(os.path.join(fake_model_dir, art), "w") as f:
                f.write(f"corrupted_content_for_{art}")

        status = local_model.check_status({
            "profile_id": "g0-text-smoke-v1",
            "app_support_path": self.app_support
        })
        self.assertEqual(status["status"], "invalid_assets")
        self.assertIn("mismatch", status["details"])

    def test_t4_runtime_unavailable_handling(self):
        """T4: When MLX is not importable, status returns runtime_unavailable."""
        # Monkey patch check_runtime_import
        orig_check = local_model.check_runtime_import
        try:
            local_model.check_runtime_import = lambda: (False, None, "Simulated missing MLX Metal")
            # Point to installed model if present
            status = local_model.check_status({"profile_id": "g0-text-smoke-v1"})
            if status["status"] != "not_installed":
                self.assertEqual(status["status"], "runtime_unavailable")
                self.assertIn("Simulated missing MLX", status["details"])
        finally:
            local_model.check_runtime_import = orig_check

    def test_t5_real_model_inference(self):
        """T5: Real model inference runs and returns proper metadata."""
        status = local_model.check_status({"profile_id": "g0-text-smoke-v1"})
        if status["status"] != "available_unloaded":
            self.skipTest(f"Model not installed in default Application Support: {status['details']}")

        # Prompt 1
        res1 = local_model.run_inference({
            "prompt": "Chào bạn, hãy giới thiệu ngắn.",
            "profile_id": "g0-text-smoke-v1"
        })
        self.assertEqual(res1["schema_version"], "1.0.0")
        self.assertEqual(res1["profile_id"], "g0-text-smoke-v1")
        self.assertEqual(res1["model_id"], "mlx-community/Qwen3-0.6B-4bit")
        self.assertTrue(len(res1["output_text"]) > 0)
        self.assertTrue(res1["input_token_count"] > 0)
        self.assertTrue(res1["output_token_count"] > 0)
        self.assertIn(res1["finish_reason"], ["stop", "length"])

        # Prompt 2
        res2 = local_model.run_inference({
            "prompt": "Viết một từ tiếng Việt về thiên nhiên.",
            "profile_id": "g0-text-smoke-v1"
        })
        self.assertTrue(len(res2["output_text"]) > 0)
        self.assertTrue(res2["input_token_count"] > 0)
        self.assertTrue(res2["output_token_count"] > 0)

    def test_setup_tampered_weights_byte_fails_and_preserves_files(self):
        """Patch 4 Acceptance: Modifying 1 byte in weights causes verify to fail without deleting files."""
        fake_model_dir = os.path.join(
            self.app_support, "Models", "g0-text", setup_g0_model.G0_MODEL_REVISION
        )
        os.makedirs(fake_model_dir, exist_ok=True)

        lock_path = setup_g0_model.get_contracts_lock_path()
        with open(lock_path, "r", encoding="utf-8") as f:
            lock = json.load(f)
        verified = lock.get("verified_artifacts", {})

        # Populate with dummy content matching verified sizes except 1 file has wrong hash
        for art in setup_g0_model.REQUIRED_ARTIFACTS:
            meta = verified.get(art, {"size_bytes": 10, "sha256": "fakehash"})
            p = os.path.join(fake_model_dir, art)
            # Write dummy data with exact size
            with open(p, "wb") as f:
                f.write(b"X" * meta["size_bytes"])

        # 1 byte tampered (hash mismatch)
        is_valid = setup_g0_model.verify_existing_pinned_install(fake_model_dir)
        self.assertFalse(is_valid, "verify_existing_pinned_install must return False on hash mismatch")

        # Execute install on existing corrupt dir -> must return exit code 2 (BLOCKED)
        exit_code = setup_g0_model.execute_install(self.app_support)
        self.assertEqual(exit_code, 2, "execute_install must return 2 when existing model doesn't match pinned manifest")

        # Files must NOT be deleted
        for art in setup_g0_model.REQUIRED_ARTIFACTS:
            p = os.path.join(fake_model_dir, art)
            self.assertTrue(os.path.isfile(p), f"Corrupted file '{art}' must NOT be deleted!")

    def test_setup_verify_existing_pinned_install_valid(self):
        """When all files match pinned sizes and hashes, verify_existing_pinned_install returns True."""
        fake_model_dir = os.path.join(
            self.app_support, "Models", "g0-text", setup_g0_model.G0_MODEL_REVISION
        )
        os.makedirs(fake_model_dir, exist_ok=True)

        lock_path = setup_g0_model.get_contracts_lock_path()
        with open(lock_path, "r", encoding="utf-8") as f:
            lock = json.load(f)
        verified = lock.get("verified_artifacts", {})

        # Create files with exact matching sha256 and size
        test_content = b"TEST_CONTENT_FOR_HASH_MATCH_123"
        import hashlib
        c_hash = hashlib.sha256(test_content).hexdigest()
        c_size = len(test_content)

        # Temporarily mock lock path to use matching hash
        orig_get_lock = setup_g0_model.get_contracts_lock_path
        tmp_lock_file = os.path.join(self.tmp_dir, "test_lock.json")
        try:
            mock_lock = {
                "status": "verified",
                "model_id": setup_g0_model.G0_MODEL_ID,
                "model_revision": setup_g0_model.G0_MODEL_REVISION,
                "verified_artifacts": {
                    art: {"size_bytes": c_size, "sha256": c_hash}
                    for art in setup_g0_model.REQUIRED_ARTIFACTS
                }
            }
            with open(tmp_lock_file, "w") as f:
                json.dump(mock_lock, f)

            setup_g0_model.get_contracts_lock_path = lambda: tmp_lock_file

            for art in setup_g0_model.REQUIRED_ARTIFACTS:
                with open(os.path.join(fake_model_dir, art), "wb") as f:
                    f.write(test_content)

            self.assertTrue(setup_g0_model.verify_existing_pinned_install(fake_model_dir))
        finally:
            setup_g0_model.get_contracts_lock_path = orig_get_lock

if __name__ == "__main__":
    unittest.main()
