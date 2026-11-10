"""Real worker-subprocess regression for strict JSON-RPC parsing."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "workers/src/aivideo_workers/main.py"


class TestRPCJSONCompliance(unittest.TestCase):
    def _exchange(self, requests: bytes) -> list[dict]:
        with subprocess.Popen(
            [sys.executable, "-u", str(WORKER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=ROOT,
        ) as proc:
            stdout, stderr = proc.communicate(
                requests + b'{"jsonrpc":"2.0","method":"shutdown"}\n',
                timeout=12,
            )
            self.assertEqual(proc.returncode, 0, stderr.decode(errors="replace"))
            return [json.loads(line) for line in stdout.splitlines() if line]

    def test_nan_in_params_is_rejected_but_next_request_still_runs(self):
        rows = self._exchange(
            b'{"jsonrpc":"2.0","id":11,"method":"system.ping","params":{"v":NaN}}\n'
            b'{"jsonrpc":"2.0","id":12,"method":"system.ping","params":{}}\n'
        )
        self.assertEqual(rows[0]["error"]["code"], -32700)
        self.assertEqual(rows[1]["id"], 12)
        self.assertEqual(rows[1]["result"]["status"], "pong")

    def test_duplicate_method_key_is_rejected_not_executed(self):
        rows = self._exchange(
            b'{"jsonrpc":"2.0","id":21,"method":"system.ping","method":"shutdown"}\n'
            b'{"jsonrpc":"2.0","id":22,"method":"system.ping"}\n'
        )
        self.assertEqual(rows[0]["error"]["code"], -32700)
        self.assertEqual(rows[1]["id"], 22)
        self.assertEqual(rows[1]["result"]["status"], "pong")

    def test_overflow_exponent_rejected(self):
        rows = self._exchange(b'{"jsonrpc":"2.0","id":31,"method":"system.ping","params":{"v":1e999}}\n')
        self.assertEqual(rows[0]["error"]["code"], -32700)


if __name__ == "__main__":
    unittest.main()
