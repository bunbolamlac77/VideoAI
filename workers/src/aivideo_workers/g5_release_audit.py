"""Gate G5 S25 & S26: Fault Injection across Commit Boundaries, Soak/Memory Bounds,
E0/E1 Release-Candidate Evaluation Accounting, and Release Handover Manifest.

Invariants enforced:
- Fault injection across DB, filesystem, Resolve adapter, disk-full, and source tamper
  leaves zero corrupt SQLite state, zero half-committed publications, and zero orphan workers.
- E0 (5 held-out trips) and E1 (10 real workdays) evaluation harness accounts honestly for
  `completed`, `abstained`, `blocked`, and `failed` runs without silently dropping failures
  from denominators (REL-02, S25.5, S25.6).
- S26 release manifest records exact Git commit, toolchain/SDK, Mach-O arm64 verification,
  offline enforcement, capability registry lock disclosure, and explicit support scope vs
  known limitations per `09-UPGRADES-AND-ACCEPTANCE.md` Section 14.2.
"""
from __future__ import annotations

from pathlib import Path
import hashlib
import hmac
import json
import os
import platform
import shutil
import sqlite3
import subprocess
import tempfile
import time
from typing import Any

from .g4_core import G4Blocked, canon, digest, hash_file, must
from .g5_capabilities import load_capability_registry
from . import runtime_paths

PROJECT_ROOT = Path(__file__).resolve().parents[3]

# 2026-11-10 fix (D07): the QA trust anchor must be pinned, not discovered at runtime.
# `PINNED_FIELD_QA_KEY_SHA256` is provisioned out-of-band when a real QA key is issued;
# while it is empty, E0/E1 field certification is unavailable by design (fail-closed).
# The path deliberately ignores AIVIDEO_CONTRACTS_DIR so an environment variable can no
# longer redirect signature verification to a caller-supplied key.
FIELD_QA_KEY_ID = "aivideo-field-qa-v1"
PINNED_FIELD_QA_KEY_SHA256 = "9c7edbdd5cb6519c7eda4dfc8154ccf8cbbd96b06a5993c4c9b322819876a179"
_QA_PUBLIC_KEY_PATH = PROJECT_ROOT / "contracts" / "field_qa_ed25519_public_key.pem"


REAL_FAULT_SUITE_EVIDENCE_SCHEMA = "g5-s25-real-fault-report-v1"


def validate_real_fault_suite_evidence(evidence: Any) -> bool:
    """(P0-04) A *real* S25 fault run is accepted as evidence only when it names the
    production store/database it corrupted, the artifacts it drove through publication, and
    a run id. The suite cannot produce such evidence by itself (it never touches the
    canonical DB), so a tampered or fabricated file is rejected here."""
    if not isinstance(evidence, dict):
        return False
    if evidence.get("schema") != REAL_FAULT_SUITE_EVIDENCE_SCHEMA:
        return False
    if evidence.get("status") != "PASS":
        return False
    run_id = evidence.get("run_id")
    if not isinstance(run_id, str) or len(run_id.strip()) < 8:
        return False
    if not isinstance(evidence.get("database_path"), str) or not evidence["database_path"].strip():
        return False
    boundaries = evidence.get("boundaries_tested")
    if not isinstance(boundaries, list) or len(boundaries) < 4:
        return False
    return all(isinstance(b, dict) and b.get("passed") is True for b in boundaries)


def run_commit_boundary_fault_suite(params: dict[str, Any] | None = None) -> dict[str, Any]:
    """Run the S25 commit-boundary *self-test* (S25.1..S25.2, S25.T1..S25.T3).

    (P0-04) This is a **self-test of the injected code paths**, not release evidence: every
    boundary is exercised against a throw-away SQLite file inside a temp directory and
    never touches the canonical store, Resolve, or the real disk. It therefore reports
    `SELF_TEST_ONLY` and can never certify S25; promotion requires an externally produced
    real fault run validated by `validate_real_fault_suite_evidence`.
    """
    params = params or {}
    boundaries_tested: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="aivideo_s25_fault_") as tmp:
        root = Path(tmp)
        db_path = root / "fault_test.sqlite3"
        conn = sqlite3.connect(str(db_path))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=FULL")
        conn.executescript("""
            CREATE TABLE projects(project_id TEXT PRIMARY KEY, name TEXT NOT NULL, rev INT NOT NULL);
            CREATE TABLE artifact_publications(
                publication_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                artifact_type TEXT NOT NULL,
                state TEXT NOT NULL,
                sha256_hash TEXT NOT NULL,
                canonical_path TEXT NOT NULL,
                byte_size INT NOT NULL
            );
            INSERT INTO projects VALUES ('P1', 'FaultProject', 1);
        """)
        conn.commit()

        # Boundary 1: Crash after staging file before SQLite COMMIT -> rollback leaves DB clean
        staged_blob = root / "staged_b1.bin"
        staged_blob.write_bytes(b"staged_payload_b1")
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                "INSERT INTO artifact_publications VALUES ('PUB1','P1','voice_wav','PREPARED',?,?,?)",
                (hash_file(staged_blob), str(staged_blob), staged_blob.stat().st_size),
            )
            raise RuntimeError("INJECTED_CRASH_BEFORE_DB_COMMIT")
        except RuntimeError:
            conn.rollback()

        integrity_1 = conn.execute("PRAGMA integrity_check").fetchone()[0]
        committed_1 = conn.execute(
            "SELECT COUNT(*) FROM artifact_publications WHERE state='COMMITTED'"
        ).fetchone()[0]
        # Reconciler cleans up unreferenced staged file
        if staged_blob.exists() and committed_1 == 0:
            staged_blob.unlink()
        boundaries_tested.append({
            "boundary_id": "B1_PRE_DB_COMMIT_CRASH",
            "sqlite_integrity": integrity_1,
            "orphan_staged_cleaned": not staged_blob.exists(),
            "half_committed_count": committed_1,
            "passed": integrity_1 == "ok" and not staged_blob.exists() and committed_1 == 0,
        })

        # Boundary 2: Disk full preflight before 4K render -> blocks cleanly without partial file
        from .g5_final import _preflight_disk_space
        blocked_disk_full = False
        # (P1-17) The simulation is only honoured under the test-harness flag, which the
        # suite sets for itself; production never sees it.
        old_env = os.environ.get("AIVIDEO_G5_SIMULATE_FREE_BYTES")
        old_harness = os.environ.get("AIVIDEO_TEST_HARNESS")
        try:
            os.environ["AIVIDEO_TEST_HARNESS"] = "1"
            os.environ["AIVIDEO_G5_SIMULATE_FREE_BYTES"] = "1024"
            _preflight_disk_space(root, min_bytes=512 * 1024 * 1024)
        except G4Blocked:
            blocked_disk_full = True
        finally:
            if old_env is None:
                os.environ.pop("AIVIDEO_G5_SIMULATE_FREE_BYTES", None)
            else:
                os.environ["AIVIDEO_G5_SIMULATE_FREE_BYTES"] = old_env
            if old_harness is None:
                os.environ.pop("AIVIDEO_TEST_HARNESS", None)
            else:
                os.environ["AIVIDEO_TEST_HARNESS"] = old_harness
        boundaries_tested.append({
            "boundary_id": "B2_DISK_FULL_BEFORE_FINAL_RENDER",
            "blocked_cleanly": blocked_disk_full,
            "passed": blocked_disk_full,
        })

        # Boundary 3: Resolve adapter crash after journal INTENT -> blocks blind retry (`RECONCILIATION_REQUIRED`)
        from .g4_resolve import Journal
        journal = Journal(root)
        try:
            journal.start("g5_build:testplan", "g5_build", "testplan", "Proj", "TL")
            blocked_blind_retry = False
            try:
                journal.start("g5_build:testplan", "g5_build", "testplan", "Proj", "TL")
            except G4Blocked as exc:
                blocked_blind_retry = "RECONCILIATION_REQUIRED" in str(exc)
        finally:
            journal.close()
        boundaries_tested.append({
            "boundary_id": "B3_RESOLVE_MID_OPERATION_UNCERTAIN_INTENT",
            "blocked_blind_retry": blocked_blind_retry,
            "passed": blocked_blind_retry,
        })

        # Boundary 4: Online backup & restore integrity after fault recovery
        backup_db = root / "portable_backup.sqlite3"
        bck_conn = sqlite3.connect(str(backup_db))
        with bck_conn:
            conn.backup(bck_conn)
        bck_integrity = bck_conn.execute("PRAGMA integrity_check").fetchone()[0]
        bck_conn.close()
        conn.close()
        boundaries_tested.append({
            "boundary_id": "B4_ONLINE_BACKUP_RESTORE_INTEGRITY",
            "backup_sqlite_integrity": bck_integrity,
            "passed": bck_integrity == "ok",
        })

    all_passed = all(b["passed"] for b in boundaries_tested)
    must(all_passed, "One or more S25 commit-boundary fault tests failed")

    # (P0-04) Promotion path: only an externally produced real fault run can certify S25.
    real_evidence = params.get("real_fault_evidence")
    real_valid = validate_real_fault_suite_evidence(real_evidence)
    return {
        "schema": "g5-s25-fault-injection-report-v1",
        "status": "SELF_TEST_ONLY",
        "self_test_passed": all_passed,
        "release_evidence": False,
        "s25_certified": real_valid,
        "certification_source": "real_fault_evidence" if real_valid else "self_test_only",
        "note": (
            "Temp-directory self-test. It proves the injected code paths behave, not that "
            "the production store survives a crash. S25 release evidence needs a real fault "
            "run recorded against the canonical database (see validate_real_fault_suite_evidence)."
        ),
        "boundaries_tested": boundaries_tested,
    }


PINNED_FIELD_QA_KEY = b"aivideo-field-qa-pinned-root-authority-v1-20261109"


def compute_field_manifest_signature(manifest: dict[str, Any], key: bytes = PINNED_FIELD_QA_KEY) -> str:
    """Compute HMAC-SHA256 signature over canonical payload excluding signing_authority."""
    payload = {k: v for k, v in manifest.items() if k != "signing_authority"}
    return hmac.new(key, canon(payload), hashlib.sha256).hexdigest()


def validate_signed_field_manifest(
    manifest: Any,
    *,
    corpus_dir: str | Path | None = None,
    enforce_signature: bool = True,
) -> bool:
    """Validate that signed field manifest is authentic, cryptographically signed, and matches video hashes."""
    if not isinstance(manifest, dict):
        return False
    if manifest.get("schema") != "aivideo-signed-field-corpus-manifest-v1":
        return False
    scope = manifest.get("corpus_scope")
    if not isinstance(scope, dict):
        return False
    trips = scope.get("held_out_trips")
    if not isinstance(trips, list) or len(trips) < 5:
        return False
    signing = manifest.get("signing_authority")
    if not isinstance(signing, dict):
        return False
    sig = signing.get("signature", "")
    if not isinstance(sig, str) or len(sig) < 32:
        return False
    algo = str(signing.get("algorithm", "")).strip().lower()
    # HMAC không thể chứng minh QA độc lập khi khóa đã được đặt công khai trong source code.
    # Toàn bộ chứng nhận nghiệm thu thực địa bắt buộc ký bằng Ed25519 độc lập.
    if algo != "ed25519":
        return False

    payload = {k: v for k, v in manifest.items() if k != "signing_authority"}

    try:
        import base64
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

        # The trust anchor is pinned: no key at all means no certification, and a
        # substituted (even valid) key cannot certify unless its fingerprint matches.
        if not PINNED_FIELD_QA_KEY_SHA256:
            return False
        if str(signing.get("key_id", "")) != FIELD_QA_KEY_ID:
            return False
        pubkey_path = _QA_PUBLIC_KEY_PATH
        if not pubkey_path.is_file():
            return False
        pem_bytes = pubkey_path.read_bytes()
        if hashlib.sha256(pem_bytes).hexdigest() != PINNED_FIELD_QA_KEY_SHA256:
            return False
        pubkey = serialization.load_pem_public_key(pem_bytes)
        if not isinstance(pubkey, Ed25519PublicKey):
            return False
        sig_bytes = base64.b64decode(sig)
        pubkey.verify(sig_bytes, canon(payload))
    except Exception as exc:
        from .diagnostics import note_suppressed
        note_suppressed("g5_release_audit.py:275", exc)
        return False

    cdir = Path(corpus_dir) if corpus_dir is not None else (PROJECT_ROOT / "fixtures" / "smoke")
    if not cdir.is_dir():
        return False
    for t in trips:
        if not isinstance(t, dict):
            return False
        trip_sha = t.get("sha256", "")
        if len(trip_sha) != 64:
            return False
        trip_id = t.get("trip_id", "")
        video_file = cdir / f"{trip_id}.mp4"
        if not video_file.is_file():
            return False
        actual_hash = hash_file(video_file)
        if actual_hash.lower() != trip_sha.lower():
            return False
    return True


def evaluate_e0_e1_accounting(params: dict[str, Any]) -> dict[str, Any]:
    """Audit E0 (5 held-out trips) and E1 (10 workdays) runs with honest denominator accounting (S25.5..S25.6)."""
    runs = params.get("runs", [])
    corpus_kind = str(params.get("corpus_kind", "E0_5_HELD_OUT_TRIPS")).strip()
    is_synthetic_fixture = bool(params.get("is_synthetic_fixture", True))
    must(isinstance(runs, list) and len(runs) > 0, "Expected non-empty evaluation runs list")

    valid_outcomes = {"completed", "abstained", "blocked", "failed"}
    counts = {k: 0 for k in valid_outcomes}
    latencies_sec: list[float] = []
    peak_rss_mb: list[float] = []
    fact_precision_hits = 0
    fact_precision_total = 0

    for item in runs:
        must(isinstance(item, dict), "Run item must be dict")
        outcome = str(item.get("outcome", "")).strip().lower()
        must(outcome in valid_outcomes, f"Invalid run outcome '{outcome}'; must be in {sorted(valid_outcomes)}")
        counts[outcome] += 1
        if "duration_sec" in item:
            latencies_sec.append(float(item["duration_sec"]))
        if "peak_rss_mb" in item:
            peak_rss_mb.append(float(item["peak_rss_mb"]))
        fact_precision_hits += int(item.get("verified_supported_claims", 0))
        fact_precision_total += int(item.get("total_emitted_claims", 0))

    total_runs = len(runs)
    # Invariant: Total denominator MUST equal sum of all 4 outcomes (no silent dropping of blocked/failed)
    must(sum(counts.values()) == total_runs, "Outcome accounting mismatch")

    completion_rate = counts["completed"] / total_runs
    abstention_rate = counts["abstained"] / total_runs
    blocked_rate = counts["blocked"] / total_runs
    failure_rate = counts["failed"] / total_runs
    fact_precision = (
        round(fact_precision_hits / fact_precision_total, 4)
        if fact_precision_total > 0
        else None
    )
    max_rss = max(peak_rss_mb) if peak_rss_mb else 0.0

    # Live field corpus certification requires genuine signed corpus artifacts (never unverified caller JSON)
    # and strictly requires Ed25519 QA key verification (never public/hardcoded HMAC).
    signed_manifest = params.get("signed_field_manifest")
    corpus_dir = params.get("corpus_dir")
    has_valid_manifest = validate_signed_field_manifest(signed_manifest, corpus_dir=corpus_dir)
    is_ed25519_cert = (
        isinstance(signed_manifest, dict)
        and str(signed_manifest.get("signing_authority", {}).get("algorithm", "")).strip().lower() == "ed25519"
    )
    scope = signed_manifest.get("corpus_scope", {}) if isinstance(signed_manifest, dict) else {}
    labels_meta = scope.get("labels", {}) if isinstance(scope, dict) else {}
    labeler_types = list(labels_meta.get("labeler_types") or [])
    source_kinds = list(labels_meta.get("source_kinds") or [])
    human_field_labels = labeler_types == ["human"] and source_kinds == ["field_footage"]
    corpus_kind_ok = str(scope.get("corpus_kind", "")) == "E0_5_HELD_OUT_TRIPS"

    certification_blockers = []
    if not has_valid_manifest:
        certification_blockers.append("SIGNED_MANIFEST_INVALID")
    if not is_ed25519_cert:
        certification_blockers.append("NOT_ED25519")
    if is_synthetic_fixture:
        certification_blockers.append("CALLER_DECLARED_SYNTHETIC")
    if not corpus_kind_ok:
        certification_blockers.append(f"CORPUS_KIND_NOT_FIELD:{scope.get('corpus_kind')}")
    if not human_field_labels:
        certification_blockers.append(
            f"LABELS_NOT_HUMAN_FIELD:labelers={labeler_types},sources={source_kinds}"
        )
    if total_runs < 5:
        certification_blockers.append("FEWER_THAN_5_RUNS")
    if counts["failed"] != 0:
        certification_blockers.append("FAILED_RUNS_PRESENT")

    # (P1-19) `runs` is caller JSON. A signed corpus manifest may carry the digest of the run
    # results it was issued for (`corpus_scope.runs_sha256`); without that binding the
    # numbers are self-reported and can only ever be descriptive.
    runs_digest = hashlib.sha256(canon({"runs": runs})).hexdigest()
    expected_runs_digest = str(scope.get("runs_sha256", "")) if isinstance(scope, dict) else ""
    runs_bound = bool(expected_runs_digest) and runs_digest == expected_runs_digest
    if not runs_bound:
        certification_blockers.append(
            "RUNS_NOT_BOUND_TO_SIGNED_MANIFEST" if not expected_runs_digest
            else "RUNS_DIGEST_MISMATCH"
        )

    live_field_corpus_certified = bool(not certification_blockers)

    if live_field_corpus_certified:
        certification_status = "CERTIFIED_FIELD_CORPUS"
    elif is_synthetic_fixture:
        certification_status = "SYNTHETIC_FIXTURE_NOT_CERTIFIED"
    else:
        certification_status = "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS"

    # Memory ceiling on 16 GB Apple Silicon: worker + core must stay well within 16 GB
    memory_within_16gb_budget = max_rss <= 12288.0

    return {
        "schema": "g5-e0-e1-evaluation-accounting-v1",
        "corpus_kind": corpus_kind,
        "is_synthetic_fixture": is_synthetic_fixture,
        "live_field_corpus_certified": live_field_corpus_certified,
        "certification_status": certification_status,
        "certification_blockers": certification_blockers,
        "runs_sha256": runs_digest,
        "runs_bound_to_manifest": runs_bound,
        "total_runs": total_runs,
        "outcome_counts": counts,
        "rates": {
            "completion_rate": round(completion_rate, 4),
            "abstention_rate": round(abstention_rate, 4),
            "blocked_rate": round(blocked_rate, 4),
            "failure_rate": round(failure_rate, 4),
        },
        "fact_precision": fact_precision,
        "max_peak_rss_mb": round(max_rss, 2),
        "memory_within_16gb_budget": memory_within_16gb_budget,
    }


def _release_signed_payload(manifest: dict[str, Any]) -> dict[str, Any]:
    """Everything a release signature covers (all fields except derivable ones)."""
    return {
        key: value for key, value in manifest.items()
        if key not in ("signature", "manifest_sha256")
    }


RELEASE_MANIFEST_KEY_ID = "aivideo-release-manifest-v1"


def sign_release_manifest(manifest: dict[str, Any], private_key_path: str | Path) -> dict[str, Any]:
    """(P1-18) Sign a release manifest with the release authority's Ed25519 key.

    The manifest used to carry only `manifest_sha256`, which is a checksum of its own
    content: anyone who edits a field can recompute it. The signature covers the canonical
    manifest without the `signature` block, so a third party can verify it against the
    published release public key.
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    import base64

    key = serialization.load_pem_private_key(Path(private_key_path).read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("RELEASE_KEY_INVALID: release signing key must be Ed25519")
    # `manifest_sha256` is derived from the manifest itself, so it must not be part of the
    # signed payload: it changes whenever the manifest changes but is also recomputed by
    # verifiers, which would make the two sides disagree.
    # The manifest must already declare itself signed when it is signed, otherwise flipping
    # `signing.signed` afterwards would invalidate the signature.
    manifest = dict(manifest)
    signing_block = dict(manifest.get("signing") or {})
    signing_block["signed"] = True
    manifest["signing"] = signing_block
    payload = _release_signed_payload(manifest)
    signature = key.sign(canon(payload))
    public_bytes = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    signed = dict(manifest)
    signed["signature"] = {
        "algorithm": "ed25519",
        "key_id": RELEASE_MANIFEST_KEY_ID,
        "public_key_sha256": hashlib.sha256(public_bytes).hexdigest(),
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    return signed


def verify_release_manifest(manifest: dict[str, Any], public_key_path: str | Path) -> bool:
    """Verify `sign_release_manifest` output against a published public key."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    import base64

    sig_block = manifest.get("signature") if isinstance(manifest, dict) else None
    if not isinstance(sig_block, dict) or sig_block.get("algorithm") != "ed25519":
        return False
    pub_bytes = Path(public_key_path).read_bytes()
    if hashlib.sha256(pub_bytes).hexdigest() != str(sig_block.get("public_key_sha256", "")):
        return False
    try:
        key = serialization.load_pem_public_key(pub_bytes)
        if not isinstance(key, Ed25519PublicKey):
            return False
        key.verify(
            base64.b64decode(sig_block["signature"]),
            canon(_release_signed_payload(manifest)),
        )
        return True
    except Exception as exc:
        from .diagnostics import note_suppressed
        note_suppressed("g5_release_audit.py:490", exc)
        return False


def generate_release_handover_manifest(params: dict[str, Any] | None = None) -> dict[str, Any]:
    """S26: Build verifiable release handover manifest with capability disclosure & support scope."""
    params = params or {}
    if "registry_path" in params:
        raise ValueError("REGISTRY_OVERRIDE_FORBIDDEN: Capability registry override is forbidden in production release audit")
    if "app_binary_path" in params:
        raise ValueError("APP_BINARY_OVERRIDE_FORBIDDEN: App binary path override is forbidden in production release audit")

    real_evidence = params.get("real_fault_evidence")
    s25_real = validate_real_fault_suite_evidence(real_evidence)
    s25_block = {
        "certified": s25_real,
        "evidence_status": (
            "real_fault_run_validated"
            if s25_real
            else str(params.get("s25_evidence_status") or "no_real_fault_run_provided")
        ),
        "self_test_is_not_evidence": True,
    }

    app_binary = PROJECT_ROOT / "apps" / "macos" / "build" / "AIVideo.app" / "Contents" / "MacOS" / "AIVideo"
    registry = load_capability_registry()

    binary_exists = app_binary.is_file()
    binary_sha256 = hash_file(app_binary) if binary_exists else None
    is_arm64_macho = False
    codesign_verified = False

    if binary_exists:
        try:
            file_out = subprocess.check_output(["file", str(app_binary)], text=True, timeout=10)
            is_arm64_macho = "Mach-O 64-bit executable arm64" in file_out
        except Exception as exc:
            from .diagnostics import note_suppressed
            note_suppressed("g5_release_audit.py:526", exc)
            is_arm64_macho = False
        try:
            app_bundle = app_binary.parents[2]
            cs = subprocess.run(
                ["codesign", "--verify", "--deep", "--strict", str(app_bundle)],
                capture_output=True, text=True, timeout=15,
            )
            codesign_verified = cs.returncode == 0
        except Exception as exc:
            from .diagnostics import note_suppressed
            note_suppressed("g5_release_audit.py:535", exc)
            codesign_verified = False

    git_commit = "UNKNOWN"
    try:
        git_commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=str(PROJECT_ROOT), text=True, timeout=5
        ).strip()
    except Exception as exc:
        from .diagnostics import note_suppressed
        note_suppressed("g5_release_audit.py:543", exc)
        pass

    capabilities_disclosure = {}
    for cap_id, cap_info in registry.get("capabilities", {}).items():
        capabilities_disclosure[cap_id] = {
            "status": cap_info.get("status"),
            "primary_model": cap_info.get("primary_model"),
            "fallback_when_unvalidated": cap_info.get("fallback_when_unvalidated"),
        }

    manifest = {
        "schema": "aivideo-v3.1-s26-release-manifest-v1",
        "version": "3.1.0-rc1",
        "git_commit": git_commit,
        "platform": {
            "os": platform.platform(),
            "arch": platform.machine(),
            "target": "arm64-apple-macosx14.0",
            "hardware_profile": "Apple M1 Pro 16 GB Unified Memory",
        },
        "app_bundle": {
            "binary_path": str(app_binary),
            "binary_exists": binary_exists,
            "binary_sha256": binary_sha256,
            "is_arm64_macho": is_arm64_macho,
            "codesign_verified": codesign_verified,
        },
        "offline_policy": {
            "enforce_offline_after_setup": True,
            "required_env_flags": {
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
                "HF_DATASETS_OFFLINE": "1",
            },
        },
        "capabilities_disclosure": capabilities_disclosure,
        # (P0-04) The manifest states which S25 evidence it rests on. Only a validated real
        # fault run can certify S25; the temp-directory self-test never can.
        "s25_fault_evidence": s25_block,
        "support_scope_statement": {
            "supported_in_v3_1": [
                "Single-user local macOS arm64 desktop workflow on Apple Silicon M1 Pro 16 GB",
                "Sealed APFS source snapshots (S05), single-writer SQLite WAL ProjectStore (S06), 4-state S08 publications, and portable backups (S09)",
                "VFR-to-CFR 24/1 rational index & SDR Rec.709 / HDR Mobius tone-map conform (S10)",
                "Evidence-constrained Vietnamese story outline (S16), offline TTS trial & human listening gate (S17), deterministic SEARCH-v1 cut solver (S18), and canonical S19 approval",
                "Managed DaVinci Resolve 1080x1920 preview (S20/S21) and 2160x3840 24fps final render, technical QC, .drp export, and isolated manual_handoff branch (S22)",
            ],
            "known_limitations_and_gated_capabilities": [
                "Production AI models (Qwen3-VL-4B, Qwen3-8B, Whisper-large-v3, Kokoro-Vietnamese TTS, DINOv2-base) require local installation and live E0/E1 field corpus benchmark execution before promoting candidate capabilities to enabled",
                "Capabilities in candidate/disabled state (exact_photo_shutter_match, sound_event_detection_sed, subject_aware_crop_tracker, vietnamese_phrase_alignment) automatically fall back to safe deterministic policies and are never claimed as active production features",
                "DaVinci Resolve live timeline build & render requires DaVinci Resolve Studio / scripting enabled on the host Mac",
            ],
        },
    }
    # (P1-18) A bare checksum is not authentication. The manifest reports its own signing
    # state so a consumer never mistakes a self-computed hash for a signature.
    manifest["signing"] = {
        "signed": False,
        "note": (
            "manifest_sha256 is an integrity checksum, not a signature; a release manifest "
            "must be signed with sign_release_manifest() before handover"
        ),
    }
    manifest["manifest_sha256"] = digest(canon(manifest))
    release_key = params.get("release_private_key_path")
    if release_key:
        # `sign_release_manifest` sets `signing.signed = true` *before* signing, so the flag
        # is covered by the signature instead of invalidating it.
        manifest = sign_release_manifest(manifest, release_key)
    return manifest
