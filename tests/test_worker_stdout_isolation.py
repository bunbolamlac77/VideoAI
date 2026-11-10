"""Regression: stray prints from third-party libs must never reach the JSON-RPC stdout channel,
and oversized results must become an explicit error instead of an unframeable line."""
import json
import subprocess
import sys
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "workers" / "src"

SCRIPT = r"""
import os, sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, os.path.join(sys.argv[1], "aivideo_workers"))
from aivideo_workers import main_g2 as m
m._isolate_protocol_stdout()
print("noise from python print")
os.write(1, b"noise from C-level write\n")
m.send_response({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})
m.send_response({"jsonrpc": "2.0", "id": 2, "result": {"blob": "x" * (m.MAX_FRAME_BYTES + 10)}})
"""


class TestWorkerStdoutIsolation(unittest.TestCase):
    def test_only_rpc_frames_on_stdout(self):
        proc = subprocess.run([sys.executable, "-c", SCRIPT, str(SRC)],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [l for l in proc.stdout.splitlines() if l.strip()]
        self.assertEqual(len(lines), 2, proc.stdout[:500])
        first, second = (json.loads(l) for l in lines)
        self.assertEqual(first["result"], {"ok": True})
        self.assertEqual(second["id"], 2)
        self.assertEqual(second["error"]["data"]["kind"], "RESULT_TOO_LARGE")
        self.assertIn("noise from python print", proc.stderr)
        self.assertIn("noise from C-level write", proc.stderr)


if __name__ == "__main__":
    unittest.main()
