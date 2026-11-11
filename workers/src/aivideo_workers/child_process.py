"""
workers/src/aivideo_workers/child_process.py — tracked child processes.

`subprocess.run` spawns ffmpeg/ffprobe outside the worker's child registry, so a
killed worker left orphan encoders behind (P1-13). Everything that shells out now
goes through `run_tracked`, which registers the process group for the lifetime of
the call and unregisters it afterwards. The registry itself lives here so both
`main_g2` and the media adapters can use it without a circular import.
"""

from __future__ import annotations

import os
import signal
import subprocess
import threading
from functools import lru_cache
import time
from typing import Dict, Optional

_TRACKED_CHILD_PROCS: Dict[int, Optional[subprocess.Popen]] = {}
_CHILD_LOCK = threading.Lock()


def register_child_process(proc: subprocess.Popen) -> None:
    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS[proc.pid] = proc


def unregister_child_process(proc: subprocess.Popen) -> None:
    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS.pop(proc.pid, None)


def register_child_pid(pid: int) -> None:
    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS.setdefault(pid, None)


def unregister_child_pid(pid: int) -> None:
    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS.pop(pid, None)


def tracked_child_count() -> int:
    with _CHILD_LOCK:
        return len(_TRACKED_CHILD_PROCS)


def is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def run_tracked(
    cmd,
    *,
    timeout: float,
    capture_output: bool = True,
    text: bool = False,
) -> subprocess.CompletedProcess:
    """Run a child process while keeping it visible to the worker's reaper."""
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        text=text,
        start_new_session=True,
    )
    register_child_process(proc)
    try:
        out, err = proc.communicate(timeout=timeout)
        return subprocess.CompletedProcess(cmd, proc.returncode, out, err)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        out, err = proc.communicate()
        raise subprocess.TimeoutExpired(cmd, timeout, output=out, stderr=err)
    finally:
        unregister_child_process(proc)


def cleanup_child_subprocesses() -> None:
    """Terminate only the subprocess groups this worker tracked and owns."""
    with _CHILD_LOCK:
        tracked = list(_TRACKED_CHILD_PROCS.items())

    for pid, proc in tracked:
        if proc is not None:
            if proc.poll() is not None:
                continue
        elif not is_pid_alive(pid):
            continue
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass

    deadline = time.time() + 1.0
    for pid, proc in tracked:
        while time.time() < deadline:
            if proc is not None:
                if proc.poll() is not None:
                    break
            elif not is_pid_alive(pid):
                break
            time.sleep(0.05)

        still_alive = proc.poll() is None if proc is not None else is_pid_alive(pid)
        if still_alive:
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

        if proc is not None:
            try:
                proc.poll()
            except Exception as exc:
                from .diagnostics import note_suppressed
                note_suppressed("child_process.py:132", exc)
                pass

    with _CHILD_LOCK:
        _TRACKED_CHILD_PROCS.clear()


@lru_cache(maxsize=8)
def ffmpeg_has_filter(name: str) -> bool:
    """True when the ffmpeg on PATH exposes `name` (e.g. drawtext needs freetype)."""
    try:
        result = run_tracked(
            ["ffmpeg", "-hide_banner", "-filters"],
            timeout=15,
            capture_output=True,
            text=True,
        )
    except Exception as exc:
        from .diagnostics import note_suppressed
        note_suppressed("child_process.py:149", exc)
        return False
    if result.returncode != 0:
        return False
    return name in (result.stdout or "")
