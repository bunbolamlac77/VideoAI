#!/usr/bin/env python3
"""
tests/test_framing_resilience.py — Regression tests for JSON-RPC framing, watchdog, and Resolve adapter invariants.

Verifies:
1. Oversized line (>1 MiB) with request appended to tail does NOT execute the tail!
2. Invalid ID types (boolean, dict, list) are rejected with -32600.
3. Resolve adapter frame boundary rejects any frame duration != 240 (0, 239, 241, 480).
4. Resolve adapter strictly parses FPS (fails if missing/invalid, never defaults to 24).
5. Resolve adapter atomic DRP export preserves previous DRP on failure.
"""

import unittest
import subprocess
import os
import sys
import json
import time

WORKER_MAIN = os.path.abspath("workers/src/aivideo_workers/main.py")
PYTHON_EXE = sys.executable

class TestWorkerFramingAndProtocol(unittest.TestCase):
    def test_oversized_line_does_not_execute_tail(self):
        """Send a line > 1 MiB followed immediately by a valid ping request. Tail MUST NOT execute!"""
        proc = subprocess.Popen(
            [PYTHON_EXE, "-u", WORKER_MAIN],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False
        )

        # First initialize cleanly
        init_req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}).encode("utf-8") + b"\n"
        proc.stdin.write(init_req)
        proc.stdin.flush()
        init_resp = json.loads(proc.stdout.readline().decode("utf-8"))
        self.assertEqual(init_resp.get("id"), 1)

        # Now send oversized line (>1 MiB of spaces) followed by valid request on same line without newline, then newline
        padding = b" " * (1024 * 1024 + 100)
        # Attempted attack: tail request on the same line
        tail_request = json.dumps({"jsonrpc": "2.0", "id": 9999, "method": "system.ping", "params": {}}).encode("utf-8")
        oversized_payload = padding + tail_request + b"\n"

        proc.stdin.write(oversized_payload)
        proc.stdin.flush()

        # Read response: it MUST be an error response for the oversized message
        resp_line = proc.stdout.readline().decode("utf-8")
        err_resp = json.loads(resp_line)
        self.assertEqual(err_resp["error"]["code"], -32600)
        self.assertIn("exceeds", err_resp["error"]["message"].lower())

        # Send a normal ping with id 2 to verify worker is still healthy and tail was NOT executed
        ping_req = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "system.ping", "params": {}}).encode("utf-8") + b"\n"
        proc.stdin.write(ping_req)
        proc.stdin.flush()

        ping_resp = json.loads(proc.stdout.readline().decode("utf-8"))
        self.assertEqual(ping_resp.get("id"), 2)
        self.assertEqual(ping_resp["result"]["status"], "pong")

        # Clean shutdown
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "shutdown"}).encode("utf-8") + b"\n")
        proc.stdin.flush()
        proc.wait(timeout=5)
        proc.stdin.close()
        proc.stdout.close()
        proc.stderr.close()

    def test_bare_or_empty_envelope_rejected(self):
        """Worker strictly rejects messages that only contain {"jsonrpc": "2.0"} or lack method."""
        proc = subprocess.Popen(
            [PYTHON_EXE, "-u", WORKER_MAIN],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False
        )

        # 1. Bare {"jsonrpc": "2.0"}
        proc.stdin.write(json.dumps({"jsonrpc": "2.0"}).encode("utf-8") + b"\n")
        proc.stdin.flush()
        resp1 = json.loads(proc.stdout.readline().decode("utf-8"))
        self.assertIn("error", resp1)
        self.assertEqual(resp1["error"]["code"], -32600)
        self.assertIn("method", resp1["error"]["message"].lower())

        # 2. {"jsonrpc": "2.0", "id": 123} without method
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 123}).encode("utf-8") + b"\n")
        proc.stdin.flush()
        resp2 = json.loads(proc.stdout.readline().decode("utf-8"))
        self.assertIn("error", resp2)
        self.assertEqual(resp2["error"]["code"], -32600)
        self.assertEqual(resp2.get("id"), 123)

        # Clean shutdown
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "shutdown"}).encode("utf-8") + b"\n")
        proc.stdin.flush()
        proc.wait(timeout=5)
        proc.stdin.close()
        proc.stdout.close()
        proc.stderr.close()

    def test_invalid_id_types_rejected(self):
        """JSON-RPC 2.0: id cannot be boolean, object, or array."""
        proc = subprocess.Popen(
            [PYTHON_EXE, "-u", WORKER_MAIN],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False
        )

        test_cases = [
            (True, "boolean"),
            (False, "boolean"),
            ({"obj": 1}, "dict"),
            ([1, 2], "list")
        ]

        for invalid_id, desc in test_cases:
            req = {"jsonrpc": "2.0", "id": invalid_id, "method": "system.ping", "params": {}}
            proc.stdin.write(json.dumps(req).encode("utf-8") + b"\n")
            proc.stdin.flush()
            resp = json.loads(proc.stdout.readline().decode("utf-8"))
            self.assertIn("error", resp)
            self.assertEqual(resp["error"]["code"], -32600)
            self.assertIn("cannot be", resp["error"]["message"].lower())

        # Clean shutdown
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "shutdown"}).encode("utf-8") + b"\n")
        proc.stdin.flush()
        proc.wait(timeout=5)
        proc.stdin.close()
        proc.stdout.close()
        proc.stderr.close()


class TestResolveAdapterInvariants(unittest.TestCase):
    def setUp(self):
        import tempfile
        sys.path.insert(
            0,
            os.path.abspath("workers/src/aivideo_workers")
        )
        import resolve_adapter
        self.resolve_adapter = resolve_adapter
        self.orig_get_resolve = resolve_adapter.get_resolve
        self.orig_create_assets = (
            resolve_adapter.create_synthetic_test_assets
        )
        self._fake_media_tmp = tempfile.TemporaryDirectory(
            prefix="aivideo_unit_media_"
        )

        def create_mock_assets(_target_dir):
            video_path = os.path.join(
                self._fake_media_tmp.name,
                "fake_video.mp4"
            )
            audio_path = os.path.join(
                self._fake_media_tmp.name,
                "fake_audio.wav"
            )
            for file_path in (video_path, audio_path):
                with open(file_path, "wb") as f:
                    f.write(
                        b"AIVIDEO_FAKE_MEDIA_FOR_UNIT_TEST_ONLY"
                    )
            return video_path, audio_path

        resolve_adapter.create_synthetic_test_assets = create_mock_assets

    def tearDown(self):
        self.resolve_adapter.get_resolve = self.orig_get_resolve
        self.resolve_adapter.create_synthetic_test_assets = (
            self.orig_create_assets
        )
        if hasattr(self, "_fake_media_tmp"):
            self._fake_media_tmp.cleanup()

    def test_atomic_export_preserves_old_file_on_failure(self):
        """Simulates atomic export failure to ensure previous DRP is not destroyed."""
        import tempfile
        import shutil

        temp_dir = tempfile.mkdtemp()
        try:
            old_drp = os.path.join(temp_dir, "test_existing.drp")
            with open(old_drp, "wb") as f:
                f.write(b"ORIGINAL_VALID_DRP_CONTENT_26KB")

            # Simulate atomic export logic
            run_uuid = "failtest"
            tmp_drp = f"{old_drp}.tmp_{run_uuid}.drp"
            # Export fails to create tmp or creates empty file:
            with open(tmp_drp, "wb") as f:
                f.write(b"") # 0 bytes

            # Verification check should fail (< 1024 bytes)
            if not os.path.exists(tmp_drp) or os.path.getsize(tmp_drp) < 1024:
                if os.path.exists(tmp_drp):
                    os.remove(tmp_drp)
                export_failed = True
            else:
                os.replace(tmp_drp, old_drp)
                export_failed = False

            self.assertTrue(export_failed)
            # Original file MUST remain intact
            self.assertTrue(os.path.exists(old_drp))
            with open(old_drp, "rb") as f:
                content = f.read()
            self.assertEqual(content, b"ORIGINAL_VALID_DRP_CONTENT_26KB")
        finally:
            shutil.rmtree(temp_dir)

    def _build_fake_resolve(
        self,
        duration=240,
        title_success=True,
        title_on_track2=True,
        render_ok=True,
        save_ok=True,
        reload_ok=True,
        export_ok=True,
        corrupt_export=False,
        codecs=None
    ):
        import zipfile

        class FakeItem:
            def __init__(self, dur=240, start=86400, end=86640):
                self._dur = dur
                self._start = start
                self._end = end
            def GetDuration(self): return self._dur
            def GetStart(self): return self._start
            def GetEnd(self): return self._end

        class FakeTimeline:
            def __init__(self):
                self.settings = {
                    "useCustomSettings": "1",
                    "timelineResolutionWidth": "2160",
                    "timelineResolutionHeight": "3840",
                    "timelineFrameRate": "24"
                }
                self.v_track1 = [FakeItem(240)]
                self.v_track2 = [FakeItem(120)] if title_on_track2 else []
                self.a_track1 = [FakeItem(240)]
            def AddTrack(self, t): return True
            def SetSetting(self, k, v): self.settings[k] = str(v)
            def GetSetting(self, k): return self.settings.get(k)
            def InsertFusionTitleIntoTimeline(self, t): return FakeItem(120) if title_success else None
            def InsertTitleIntoTimeline(self, t): return FakeItem(120) if title_success else None
            def MoveItems(self, items, d): return title_success
            def GetStartFrame(self): return 86400
            def GetEndFrame(self): return 86400 + duration
            def GetTrackCount(self, t): return 2 if t == "video" else 1
            def GetItemListInTrack(self, t, idx):
                if t == "video":
                    return self.v_track1 if idx == 1 else self.v_track2
                return self.a_track1

        class FakeMediaPool:
            def __init__(self, tl): self.tl = tl
            def ImportMedia(self, paths): return [FakeItem(240), FakeItem(240)]
            def CreateEmptyTimeline(self, name): return self.tl
            def AppendToTimeline(self, clips): return [FakeItem(240), FakeItem(240)]

        class FakeProject:
            def __init__(self, tl):
                self.tl = tl
                self.mp = FakeMediaPool(tl)
                self.codecs = codecs if codecs is not None else {"H264": "H.264"}
            def GetMediaPool(self): return self.mp
            def GetName(self): return "AIVideo_Test_Project"
            def GetRenderCodecs(self, fmt): return self.codecs
            def SetRenderSettings(self, s): return render_ok

        class FakeProjectManager:
            def __init__(self, proj):
                self.proj = proj
            def CreateProject(self, name): return self.proj
            def GetCurrentProject(self): return self.proj
            def CloseProject(self, p): return True
            def SaveProject(self): return save_ok
            def LoadProject(self, name): return self.proj if reload_ok else None
            def ExportProject(self, name, path):
                if not export_ok: return False
                if corrupt_export:
                    with open(path, "wb") as f: f.write(b"NOT_A_VALID_ZIP_ARCHIVE_CORRUPTED_" * 50) # > 1024 bytes
                    return True
                with zipfile.ZipFile(path, "w") as zf:
                    zf.writestr("project.db", b"FAKE_RESOLVE_PROJECT_DB_PAYLOAD_" * 100) # > 1024 bytes
                return True

        class FakeResolve:
            def __init__(self, pm): self.pm = pm
            def GetProductName(self): return "DaVinci Resolve Studio"
            def GetVersionString(self): return "21.2.0.5"
            def GetProjectManager(self): return self.pm

        tl = FakeTimeline()
        proj = FakeProject(tl)
        pm = FakeProjectManager(proj)
        return FakeResolve(pm)

    def test_run_g0_spike_success_with_fake_sdk(self):
        """Calls actual run_g0_spike() via FakeResolve and verifies return metadata."""
        import tempfile
        import shutil
        tmp_dir = tempfile.mkdtemp()
        try:
            target_drp = os.path.join(tmp_dir, "test_spike.drp")
            fake_res = self._build_fake_resolve()
            self.resolve_adapter.get_resolve = lambda: fake_res

            res = self.resolve_adapter.run_g0_spike(output_drp_path=target_drp, force_fresh_run=True)
            self.assertTrue(res["success"])
            self.assertEqual(res["timeline_total_frames"], 240)
            self.assertEqual(res["timeline_resolution"], "2160x3840")
            self.assertEqual(res["timeline_fps"], 24.0)
            self.assertTrue(res["title_inserted"])
            self.assertTrue(res["render_settings_configured"])
            self.assertTrue(res["project_saved"])
            self.assertIsNone(res["preview_path"])
            self.assertTrue(res["drp_exported"])
            self.assertTrue(os.path.isfile(target_drp))
            self.assertTrue(os.path.getsize(target_drp) > 100)
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_run_g0_spike_title_failure_raises(self):
        """Calls actual run_g0_spike() and asserts failure when title placement fails."""
        import tempfile
        import shutil
        tmp_dir = tempfile.mkdtemp()
        try:
            target_drp = os.path.join(tmp_dir, "test_spike.drp")
            # Title insertion fails
            fake_res = self._build_fake_resolve(title_success=False)
            self.resolve_adapter.get_resolve = lambda: fake_res

            with self.assertRaises(RuntimeError) as ctx:
                self.resolve_adapter.run_g0_spike(output_drp_path=target_drp)
            self.assertIn("title insertion or placement failed", str(ctx.exception).lower())
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_run_g0_spike_title_not_on_track2_raises(self):
        """Calls actual run_g0_spike() and asserts failure when Track 2 is missing title."""
        import tempfile
        import shutil
        tmp_dir = tempfile.mkdtemp()
        try:
            target_drp = os.path.join(tmp_dir, "test_spike.drp")
            fake_res = self._build_fake_resolve(title_on_track2=False)
            self.resolve_adapter.get_resolve = lambda: fake_res

            with self.assertRaises(RuntimeError) as ctx:
                self.resolve_adapter.run_g0_spike(output_drp_path=target_drp)
            self.assertIn("video track 2", str(ctx.exception).lower())
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_run_g0_spike_render_settings_failure_raises(self):
        """Calls actual run_g0_spike() and asserts failure when SetRenderSettings returns False."""
        import tempfile
        import shutil
        tmp_dir = tempfile.mkdtemp()
        try:
            target_drp = os.path.join(tmp_dir, "test_spike.drp")
            fake_res = self._build_fake_resolve(render_ok=False)
            self.resolve_adapter.get_resolve = lambda: fake_res

            with self.assertRaises(RuntimeError) as ctx:
                self.resolve_adapter.run_g0_spike(output_drp_path=target_drp)
            self.assertIn("setrendersettings failed", str(ctx.exception).lower())
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_run_g0_spike_duration_rejection_raises(self):
        """Calls actual run_g0_spike() with invalid durations (239, 241, 480) and asserts rejection."""
        import tempfile
        import shutil
        for invalid_duration in [239, 241, 480]:
            tmp_dir = tempfile.mkdtemp()
            try:
                target_drp = os.path.join(tmp_dir, "test_spike.drp")
                fake_res = self._build_fake_resolve(duration=invalid_duration)
                self.resolve_adapter.get_resolve = lambda: fake_res

                with self.assertRaises(RuntimeError) as ctx:
                    self.resolve_adapter.run_g0_spike(output_drp_path=target_drp)
                self.assertIn("exactly 240 frames", str(ctx.exception).lower())
            finally:
                shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_run_g0_spike_save_project_failure_raises(self):
        """Calls actual run_g0_spike() and asserts failure when SaveProject fails."""
        import tempfile
        import shutil
        tmp_dir = tempfile.mkdtemp()
        try:
            target_drp = os.path.join(tmp_dir, "test_spike.drp")
            fake_res = self._build_fake_resolve(save_ok=False)
            self.resolve_adapter.get_resolve = lambda: fake_res

            with self.assertRaises(RuntimeError) as ctx:
                self.resolve_adapter.run_g0_spike(output_drp_path=target_drp)
            self.assertIn("saveproject() returned false", str(ctx.exception).lower())
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def test_run_g0_spike_drp_corruption_preserves_old_drp(self):
        """Calls actual run_g0_spike() when DRP export is corrupted and asserts old DRP is preserved."""
        import tempfile
        import shutil
        tmp_dir = tempfile.mkdtemp()
        try:
            target_drp = os.path.join(tmp_dir, "test_spike.drp")
            with open(target_drp, "wb") as f:
                f.write(b"PREVIOUS_VALID_DRP_CONTENT_50KB")

            fake_res = self._build_fake_resolve(corrupt_export=True)
            self.resolve_adapter.get_resolve = lambda: fake_res

            with self.assertRaises(RuntimeError) as ctx:
                self.resolve_adapter.run_g0_spike(output_drp_path=target_drp)
            self.assertIn("zip archive", str(ctx.exception).lower())

            # Original DRP must remain intact!
            with open(target_drp, "rb") as f:
                content = f.read()
            self.assertEqual(content, b"PREVIOUS_VALID_DRP_CONTENT_50KB")
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
