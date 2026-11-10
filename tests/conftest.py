"""
pytest configuration and path setup for AIVideo regression test suites.
Ensures repository root and workers/src are in sys.path regardless of execution context.
"""

from __future__ import annotations

from pathlib import Path
import sys

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))
