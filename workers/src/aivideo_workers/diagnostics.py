"""
workers/src/aivideo_workers/diagnostics.py — one place for errors a caller chose to survive.

(P2-06) `except Exception:` blocks used to fall through silently: a broken model adapter,
an unreadable key file or a failing cleanup step left no trace at all, so the only symptom
was a wrong result much later. Every handler that does not re-raise must call
`note_suppressed()` (or explicitly annotate `# noqa: BLE001 - <reason>`), and the note is
recorded in a bounded ring buffer that the worker exposes through `diag.suppressed`.

The buffer is deliberately cheap: these are "we continued anyway" events, not incidents.
"""

from __future__ import annotations

import sys
import threading
import traceback
from typing import Any, Dict, List

_MAX_NOTES = 200
_notes: List[Dict[str, Any]] = []
_lock = threading.Lock()


def note_suppressed(context: str, exc: BaseException, **detail: Any) -> Dict[str, Any]:
    """Record that `exc` was handled at `context` instead of propagating.

    Always visible on stderr (so a log capture shows it) and kept in a ring buffer for
    `diag.suppressed`.
    """
    entry = {
        "context": context,
        "error_type": type(exc).__name__,
        "error": str(exc)[:500],
        "detail": detail,
        "traceback_tail": traceback.format_exc().splitlines()[-3:],
    }
    with _lock:
        _notes.append(entry)
        if len(_notes) > _MAX_NOTES:
            del _notes[: len(_notes) - _MAX_NOTES]
    print(
        f"[suppressed] {context}: {type(exc).__name__}: {str(exc)[:200]}",
        file=sys.stderr,
        flush=True,
    )
    return entry


def suppressed_notes() -> List[Dict[str, Any]]:
    with _lock:
        return list(_notes)


def clear_suppressed() -> None:
    with _lock:
        _notes.clear()
