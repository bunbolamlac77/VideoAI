#!/usr/bin/env python3
"""AIVideo local, authenticated, operator-approved bridge (Python stdlib only).

No ChatGPT DOM scraping or browser automation. ChatGPT output is submitted
explicitly by the user. The local worker applies exactly FILE blocks.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

MAX_BODY = 1_500_000
MAX_FILES = 32
BLOCK = re.compile(r"^```FILE:\s*([^\n`]+)\n(.*?)^```[ \t]*$", re.M | re.S)
ALLOWED_TOP = {"apps", "packages", "workers", "contracts", "tools", "tests", "reports", "docs", "fixtures"}
ALLOWED_ROOT = {"README.md", "PROGRESS_TRACKER.md"}
BLOCKED_PARTS = {".git", ".venv", "node_modules", "__pycache__", "build", ".DS_Store", ".env", ".ssh", "autobridge"}
ALLOWED_EXT = {".swift", ".py", ".md", ".json", ".sql", ".sh", ".toml", ".yml", ".yaml", ".plist", ".html", ".css", ".js"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def blocks_from_text(text: str) -> list[tuple[str, str]]:
    if not isinstance(text, str) or not text.strip():
        raise ValueError("No response text received")
    pairs = [(m.group(1).strip(), m.group(2)) for m in BLOCK.finditer(text)]
    if not pairs:
        raise ValueError('No ```FILE: relative/path\n...\n``` blocks found')
    if len(pairs) > MAX_FILES:
        raise ValueError(f"Too many files; limit is {MAX_FILES}")
    if len({p for p, _ in pairs}) != len(pairs):
        raise ValueError("Duplicate FILE path in the submitted response")
    return pairs


def checked_path(root: Path, relative: str) -> Path:
    if "\\" in relative or "\x00" in relative or relative.startswith("/") or relative.startswith("~"):
        raise ValueError(f"Invalid path: {relative!r}")
    p = PurePosixPath(relative)
    parts = relative.split("/")
    if not relative or any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"Unsafe path: {relative!r}")
    if any(part in BLOCKED_PARTS for part in parts):
        raise ValueError(f"Protected folder: {relative!r}")
    if (parts[0] not in ALLOWED_TOP and relative not in ALLOWED_ROOT) or p.suffix not in ALLOWED_EXT:
        raise ValueError(f"Path not on allowlist: {relative!r}")
    root = root.resolve(strict=True)
    dest = root / relative
    if dest.is_symlink() or any(parent.is_symlink() for parent in dest.parents if parent != root):
        raise ValueError(f"Symlink destination rejected: {relative!r}")
    if not dest.resolve(strict=False).is_relative_to(root):
        raise ValueError(f"Path traversal: {relative!r}")
    return dest


def prepare_files(root: Path, response: str) -> list[tuple[str, Path, bytes]]:
    files = []
    for name, content in blocks_from_text(response):
        if len(content.encode("utf-8")) > MAX_BODY:
            raise ValueError("A file exceeds the size limit")
        files.append((name, checked_path(root, name), content.encode("utf-8")))
    return files


def apply_files(root: Path, state_dir: Path, job_id: str, response: str) -> list[str]:
    """Preflight every path; backup originals outside repo; replace atomically per-file."""
    files = prepare_files(root, response)
    backup_dir = state_dir / "backups" / job_id
    backup_dir.mkdir(parents=True, exist_ok=False)
    planned = []
    try:
        for rel, dest, body in files:
            # Read just once for optimistic concurrency control.
            original = dest.read_bytes() if dest.exists() else None
            if dest.exists() and not dest.is_file():
                raise ValueError(f"Not a regular file: {rel}")
            if original is not None:
                backup_path = backup_dir / rel
                backup_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dest, backup_path)
            planned.append((rel, dest, body, original))
        changed = []
        for rel, dest, body, original in planned:
            # If a human edits the same file while the bridge runs, abort rather than overwrite.
            recent = dest.read_bytes() if dest.exists() else None
            if recent != original:
                raise RuntimeError(f"Concurrent modification detected: {rel}")
            dest.parent.mkdir(parents=True, exist_ok=True)
            fd, tmpname = tempfile.mkstemp(prefix=".aivideo-", dir=dest.parent)
            try:
                if original is not None:
                    os.fchmod(fd, dest.stat().st_mode & 0o777)
                with os.fdopen(fd, "wb") as f:
                    f.write(body)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmpname, dest)
            finally:
                if os.path.exists(tmpname):
                    os.unlink(tmpname)
            changed.append(rel)
        return changed
    except Exception as exc:
        from aivideo_workers.diagnostics import note_suppressed
        note_suppressed("bridge.py:123", exc)
        # Best-effort rollback for exceptions. Power loss mid-batch requires git review.
        for rel, dest, _body, original in reversed(planned):
            if original is None:
                if dest.exists() and dest.is_file():
                    dest.unlink()
            else:
                saved = backup_dir / rel
                if saved.exists():
                    shutil.copy2(saved, dest)
        raise


def run_checks(repo: Path, checks: list[list[str]]) -> tuple[bool, str]:
    entries = []
    ok = True
    for argv in checks:
        try:
            p = subprocess.run(argv, cwd=repo, capture_output=True, text=True,
                               timeout=900, errors="replace", check=False)
            ok = ok and p.returncode == 0
            output = (p.stdout + "\n" + p.stderr)[-5000:]
            entries.append(f"$ {' '.join(argv)}\nexit={p.returncode}\n{output}")
        except (OSError, subprocess.TimeoutExpired) as ex:
            ok = False
            entries.append(f"$ {' '.join(argv)}\nFAILED: {ex}")
    return ok, "\n\n".join(entries)


def git_summary(repo: Path) -> str:
    if not (repo / ".git").exists():
        return "No .git directory; git status unavailable"
    try:
        p = subprocess.run(["git", "status", "--short"], cwd=repo,
                           text=True, capture_output=True, timeout=20, check=False)
        return (p.stdout or p.stderr or "clean")[:5000]
    except (OSError, subprocess.TimeoutExpired) as ex:
        return f"Cannot read git status: {ex}"


class Store:
    def __init__(self, db_path: Path):
        self.db_path = db_path
        db_path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as c:
            c.execute("""CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, body TEXT NOT NULL, state TEXT NOT NULL,
                created TEXT NOT NULL, updated TEXT NOT NULL,
                result TEXT NOT NULL DEFAULT '', file_list TEXT NOT NULL DEFAULT '[]'
            )""")
            # A crashed worker cannot safely replay writes without operator review.
            c.execute("UPDATE jobs SET state='interrupted', updated=? WHERE state='running'", (now(),))

    @contextmanager
    def connect(self):
        c = sqlite3.connect(self.db_path, timeout=10, isolation_level=None)
        try:
            c.row_factory = sqlite3.Row
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("PRAGMA busy_timeout=10000")
            yield c
        finally:
            c.close()

    def submit(self, body: str, file_list: list[str]) -> dict:
        job_id = hashlib.sha256(body.encode("utf-8")).hexdigest()[:20]
        with self.connect() as c:
            c.execute("""INSERT OR IGNORE INTO jobs (id, body, state, created, updated, file_list)
                         VALUES (?, ?, 'queued', ?, ?, ?)""",
                      (job_id, body, now(), now(), json.dumps(file_list, ensure_ascii=False)))
            r = c.execute("SELECT id, state FROM jobs WHERE id=?", (job_id,)).fetchone()
            return dict(r)

    def claim(self):
        with self.connect() as c:
            c.execute("BEGIN IMMEDIATE")
            r = c.execute("SELECT id, body FROM jobs WHERE state='queued' ORDER BY created, rowid LIMIT 1").fetchone()
            if r is not None:
                c.execute("UPDATE jobs SET state='running', updated=? WHERE id=?", (now(), r["id"]))
            c.execute("COMMIT")
            return dict(r) if r is not None else None

    def complete(self, job_id: str, state: str, result: str):
        assert state in ("done", "failed")
        with self.connect() as c:
            c.execute("UPDATE jobs SET state=?, result=?, updated=? WHERE id=?",
                      (state, result, now(), job_id))

    def latest(self) -> dict | None:
        with self.connect() as c:
            row = c.execute("""SELECT id, state, created, updated, result, file_list
                            FROM jobs ORDER BY created DESC, rowid DESC LIMIT 1""").fetchone()
            if row is None:
                return None
            out = dict(row)
            out["files"] = json.loads(out.pop("file_list"))
            return out


def worker(store: Store, repo: Path, state_dir: Path, checks: list[list[str]], stop: threading.Event):
    while not stop.is_set():
        job = store.claim()
        if job is None:
            stop.wait(0.7)
            continue
        try:
            files = apply_files(repo, state_dir, job["id"], job["body"])
            ok, logs = run_checks(repo, checks)
            result = (f"JOB {job['id']}\nFILES: {', '.join(files)}\n"
                      f"TESTS: {'PASS' if ok else 'FAIL'}\n\n{logs}\n\n"
                      f"GIT STATUS:\n{git_summary(repo)}\n\n"
                      "Review S06 gate and recommend the next code-only FILE blocks. "
                      "Do not claim a macOS runtime test passed unless logs prove it.")
            store.complete(job["id"], "done" if ok else "failed", result)
        except Exception as ex:
            from aivideo_workers.diagnostics import note_suppressed
            note_suppressed("bridge.py:237", ex)
            store.complete(job["id"], "failed", f"JOB {job['id']} FAILED: {type(ex).__name__}: {ex}")


def load_token(state_dir: Path) -> str:
    state_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(state_dir, 0o700)
    except OSError:
        pass
    path = state_dir / "token"
    if not path.exists():
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            with os.fdopen(fd, "w") as f:
                f.write(secrets.token_urlsafe(32))
        except BaseException:
            path.unlink(missing_ok=True)
            raise
    return path.read_text().strip()


def make_handler(repo: Path, token: str, store: Store):
    class Handler(BaseHTTPRequestHandler):
        server_version = "AIVideoBridge/2.0"

        def log_message(self, fmt, *args):
            sys.stderr.write("[bridge] " + (fmt % args) + "\n")

        def send_json(self, code: int, payload: dict):
            raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def authorized(self) -> bool:
            supplied = self.headers.get("X-Bridge-Token", "")
            if not hmac.compare_digest(token, supplied):
                self.send_json(401, {"error": "Invalid bridge token"})
                return False
            return True

        def do_GET(self):
            if not self.authorized():
                return
            path = urlsplit(self.path).path
            if path == "/api/status":
                self.send_json(200, {"ok": True, "repository": str(repo), "latest": store.latest()})
            else:
                self.send_json(404, {"error": "Unknown endpoint"})

        def do_POST(self):
            if not self.authorized():
                return
            if urlsplit(self.path).path != "/api/submit":
                return self.send_json(404, {"error": "Unknown endpoint"})
            if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
                return self.send_json(415, {"error": "Expected application/json"})
            try:
                length = int(self.headers.get("Content-Length", "-1"))
            except ValueError:
                length = -1
            if not 0 < length <= MAX_BODY:
                return self.send_json(413, {"error": "Body is missing or exceeds 1.5 MB"})
            try:
                obj = json.loads(self.rfile.read(length))
                body = obj.get("content") if isinstance(obj, dict) else None
                files = [rel for rel, _dest, _content in prepare_files(repo, body)]
                accepted = store.submit(body, files)
                self.send_json(202, {"ok": True, **accepted, "files": files})
            except (ValueError, TypeError, UnicodeError, json.JSONDecodeError) as ex:
                self.send_json(400, {"error": str(ex)})

    return Handler


def main():
    p = argparse.ArgumentParser(description="Local bridge, no ChatGPT DOM scraping")
    p.add_argument("command", choices=("serve", "token"))
    p.add_argument("--repo", type=Path, default=Path.cwd())
    p.add_argument("--state", type=Path, default=Path.home() / ".aivideo-bridge")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--skip-project-tests", action="store_true")
    args = p.parse_args()
    secret = load_token(args.state)
    if args.command == "token":
        print(secret)
        return
    repo = args.repo.expanduser().resolve(strict=True)
    if not (repo / "PROGRESS_TRACKER.md").is_file():
        p.error("--repo must be the AIVideo project root (PROGRESS_TRACKER.md missing)")
    checks = [] if args.skip_project_tests else [
        [sys.executable, "tools/run_python_tests.py"],
        ["bash", "tools/run_s06_tests.sh"],
    ]
    # Single-instance guard: a second launch must not invalidate a live job.
    lock_fd = os.open(args.state / "server.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        p.error("another bridge process is already running for this state directory")
    store = Store(args.state / "jobs.sqlite3")
    stop = threading.Event()
    t = threading.Thread(target=worker, args=(store, repo, args.state, checks, stop), daemon=True)
    t.start()
    http = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(repo, secret, store))
    print(f"Bridge listening at http://127.0.0.1:{args.port} | project: {repo}", flush=True)
    print("Token: run python3 tools/autobridge/bridge.py token (do not commit/share it)", flush=True)
    try:
        http.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        http.server_close()
        stop.set()
        t.join(timeout=2)


if __name__ == "__main__":
    main()
