# Đề xuất thay đổi còn lại — bạn tự áp dụng

> ✅ **ĐÃ ÁP DỤNG & KIỂM CHỨNG (2026-11-11).**
> Toàn bộ code trong tài liệu này đã được đưa vào cây làm việc và chạy xanh:
> `tests/test_p31_transition_source.py` 4/4, `tests/test_p1_hashing_outside_transaction.swift` 5/5,
> `test_g4_approval.swift` có case `S21.P1_02B` (không còn IO trong write transaction).
> Vì vậy P1-02 và P1-31 nay là **ĐÃ SỬA ĐẦY ĐỦ** trong
> [`AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).
> Tài liệu được giữ lại như biên bản: nó giải thích *vì sao* từng bước làm như vậy, và §7 là danh
> sách bẫy vẫn còn giá trị. Đừng dán lại code — cây đã có.

Tài liệu này chứa **toàn bộ code tôi muốn sửa nhưng chưa sửa**, viết sẵn để bạn dán vào
repo. Tôi **không** áp dụng các thay đổi này; cây làm việc hiện tại chỉ chứa phần đã commit
(`fb00cf9`, `9e2c829`, đã push tới `origin/main`).

Chỉ còn **2 mục** ở trạng thái "sửa một phần" trong
[`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md):

| Mục | Vấn đề còn lại | File | Rủi ro |
|---|---|---|---|
| **P1-02** (nhánh G4 + `commitPublication`) | Băm file / ffprobe vẫn chạy **trong** `BEGIN IMMEDIATE` ⇒ giữ khoá ghi của writer duy nhất suốt thời gian IO | `G4ProjectStore.swift`, `G4S21Guard.swift`, `ProjectStore.swift` | Trung bình — logic không đổi, chỉ đổi **thứ tự** và **nơi** đọc |
| **P1-31** (phần transition) | Danh sách transition vẫn do request khai; chưa đối chiếu với plan đã duyệt (G4 preview render hard-cut) | `workers/src/aivideo_workers/native_render.py` | Thấp — thêm chặn, không đổi đường đi hợp lệ |

Thứ tự làm đề nghị: **P1-31 trước** (nhỏ, độc lập), rồi **P1-02A** (`commitPublication`),
rồi **P1-02B** (G4) — vì P1-02B chạm nhiều dòng nhất.

---

## 0. Cách dùng tài liệu

1. Mỗi mục có: hiện trạng (trích đúng code đang chạy), code thay thế **đầy đủ**, và test.
2. Dán thay nguyên khối, không sửa từng dòng — các khối được viết để thay thế trọn vẹn.
3. Sau mỗi mục, chạy đúng lệnh ở §5. Nếu đỏ, xem §6 (rollback) trước khi đi tiếp.
4. Đừng gộp 2 mục vào 1 commit: P1-02B là thay đổi lớn nhất và cần review riêng.

---

## 1. P1-31 — Transition phải đến từ plan đã duyệt

### 1.1. Hiện trạng

`workers/src/aivideo_workers/native_render.py`, trong `build_beats_from_plan`:

```python
    voice_texts = params.get("voice_texts") or {}
    cue_map = params.get("cues") or {}
    transitions = params.get("transitions") or {}
    photo_inserts = params.get("photo_inserts") or []
```

`transitions` chỉ đến từ **request**. Plan G4/G5 (sinh bởi `g4_core.approved_plan` /
`g5_final.approved_final_plan`) **không** có khoá `transitions`, tức là preview đã duyệt là
hard-cut. Nhưng renderer vẫn nhận `crossfade` từ request ⇒ timeline 4K khác timeline đã duyệt
(mặc dù hiện đã bị chặn bởi `PLAN_FRAME_MISMATCH` khi tổng frame lệch — nếu overlap bằng 0
thì vẫn lọt).

### 1.2. Thay thế

Thay 4 dòng đầu bằng:

```python
    voice_texts = params.get("voice_texts") or {}
    cue_map = params.get("cues") or {}
    photo_inserts = params.get("photo_inserts") or []

    # (P1-31) Transitions are part of the approved plan, not of the request. The G4 preview
    # is rendered as hard cuts, so a plan that declares no transitions must render hard cuts
    # and a request may never introduce one: otherwise the 4K render is a different timeline
    # from the one a human approved, even when the total frame count happens to match.
    planned_transitions = plan.get("transitions") or {}
    if not isinstance(planned_transitions, dict):
        raise NativeRenderError(
            "INVALID_PLAN_TRANSITIONS", "plan.transitions must be an object keyed by beat_id"
        )
    requested_transitions = params.get("transitions") or {}
    if not isinstance(requested_transitions, dict):
        raise ValueError("transitions must be an object keyed by beat_id")
    undeclared = sorted(set(requested_transitions) - set(planned_transitions))
    if undeclared:
        raise NativeRenderError(
            "TRANSITION_NOT_IN_PLAN",
            f"transitions for {undeclared} are not part of the approved plan",
            {"planned_beat_ids": sorted(planned_transitions), "requested": undeclared},
        )
    for requested_beat, spec in requested_transitions.items():
        planned = planned_transitions.get(requested_beat) or {}
        same_type = str((spec or {}).get("type") or "") == str(planned.get("type") or "")
        same_frames = int((spec or {}).get("frames", 0) or 0) == int(
            planned.get("frames", 0) or 0
        )
        if not (same_type and same_frames):
            raise NativeRenderError(
                "TRANSITION_MISMATCH",
                f"transition for {requested_beat} differs from the approved plan "
                f"(requested {spec}, planned {planned})",
                {"requested_beat_id": requested_beat},
            )
    transitions = requested_transitions
```

**Không** thêm `"transitions": {}` vào plan dict: plan SHA-256 là thứ được approval pin, nên
thêm khoá sẽ làm mọi approval đang có (và test fixture) đổi hash. Bỏ trống = "không cho
transition", đúng với preview hard-cut hiện tại. Khi nào G4 thật sự render crossfade thì lúc
đó plan mang `transitions` và phần so khớp trên tự cho phép.

### 1.3. Test

Tạo `tests/test_p31_transition_source.py`:

```python
"""
tests/test_p31_transition_source.py — Regression for audit P1-31 (2026-11-11).

The 4K renderer used to take its transition list from the request, so a caller could render
a crossfade timeline while the approved G4 preview was a hard-cut timeline. Transitions now
have to exist in the approved plan and match it exactly.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers import native_render
from aivideo_workers.native_render import NativeRenderError


def _plan(work: Path, *, transitions: dict | None = None) -> dict:
    clip = work / "clip.mp4"
    clip.write_bytes(b"video")
    voice = work / "voice.wav"
    voice.write_bytes(b"audio")
    plan = {
        "plan_sha256": "0" * 64,
        "total_frames": 96,
        "entries": [
            {
                "beat_id": "b1",
                "video_path": str(clip),
                "voice_path": str(voice),
                "duration_frames": 48,
                "video_sha256": "1" * 64,
                "voice_sha256": "2" * 64,
                "caption_text_sha256": native_render._sha256_bytes("Xin chào".encode()),
            },
            {
                "beat_id": "b2",
                "video_path": str(clip),
                "voice_path": str(voice),
                "duration_frames": 48,
                "video_sha256": "3" * 64,
                "voice_sha256": "4" * 64,
                "caption_text_sha256": native_render._sha256_bytes("Tạm biệt".encode()),
            },
        ],
    }
    if transitions is not None:
        plan["transitions"] = transitions
    return plan


VOICE = {"b1": "Xin chào", "b2": "Tạm biệt"}


class TestTransitionsComeFromThePlan(unittest.TestCase):
    def test_hard_cut_plan_rejects_any_transition(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            with self.assertRaises(NativeRenderError) as ctx:
                native_render.build_beats_from_plan(
                    _plan(work),
                    {"voice_texts": VOICE,
                     "transitions": {"b2": {"type": "crossfade", "frames": 8}}},
                    staging_root=work,
                )
        self.assertEqual(ctx.exception.code, "TRANSITION_NOT_IN_PLAN")

    def test_plan_transition_is_accepted_when_it_matches(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = _plan(work, transitions={"b2": {"type": "crossfade", "frames": 8}})
            plan["total_frames"] = 88
            beats, _ = native_render.build_beats_from_plan(
                plan,
                {"voice_texts": VOICE,
                 "transitions": {"b2": {"type": "crossfade", "frames": 8}}},
                staging_root=work,
            )
        self.assertEqual(native_render.expected_total_frames(beats), 88)

    def test_mismatched_frames_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = _plan(work, transitions={"b2": {"type": "crossfade", "frames": 8}})
            with self.assertRaises(NativeRenderError) as ctx:
                native_render.build_beats_from_plan(
                    plan,
                    {"voice_texts": VOICE,
                     "transitions": {"b2": {"type": "crossfade", "frames": 12}}},
                    staging_root=work,
                )
        self.assertEqual(ctx.exception.code, "TRANSITION_MISMATCH")

    def test_mismatched_type_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = _plan(work, transitions={"b2": {"type": "crossfade", "frames": 8}})
            with self.assertRaises(NativeRenderError) as ctx:
                native_render.build_beats_from_plan(
                    plan,
                    {"voice_texts": VOICE,
                     "transitions": {"b2": {"type": "dip_to_black", "frames": 8}}},
                    staging_root=work,
                )
        self.assertEqual(ctx.exception.code, "TRANSITION_MISMATCH")


if __name__ == "__main__":
    unittest.main()
```

> Lưu ý khi chạy: `tests/test_s20_native_render.py` có case dùng `transitions` (nếu có) sẽ
> phải cập nhật plan có `transitions` tương ứng. Chạy cả 2 suite sau khi sửa:
> `workers/.venv/bin/python3 tests/test_s20_native_render.py` và
> `workers/.venv/bin/python3 tests/test_p31_transition_source.py`.

---

## 2. P1-02A — `commitPublication`: băm ngoài transaction

### 2.1. Hiện trạng

`packages/AIVideoCore/Sources/Storage/ProjectStore.swift`, `commitPublication` (khoảng dòng
2237): `Self.fileSHA256(atPath:)` được gọi **bên trong** `withTransaction { ... }`, tức là
trong `BEGIN IMMEDIATE`.

### 2.2. Thay thế (toàn bộ hàm — dán đè được ngay)

```swift
    public func commitPublication(
        publicationId: UUID,
        jobId: UUID,
        attemptId: UUID,
        fencingToken: Int,
        canonicalPath: String,
        completeJob: Bool = true,
        idempotencyKey: String? = nil
    ) throws -> ArtifactPublicationRecord {
        // (P1-02) Measure the canonical bytes BEFORE the write lock. Hashing a 4K master
        // inside `BEGIN IMMEDIATE` blocked the single canonical writer — and therefore the
        // whole app — for the duration of the IO.
        guard let prePublication = try getPublicationInternal(id: publicationId) else {
            throw ProjectStoreError.publicationNotFound(publicationId)
        }
        guard let preExpectedHash = prePublication.sha256Hash, !preExpectedHash.isEmpty else {
            throw ProjectStoreError.integrityViolation(
                "Cannot commit publication \(publicationId): no verified sha256 recorded"
            )
        }
        guard FileManager.default.fileExists(atPath: canonicalPath) else {
            throw ProjectStoreError.integrityViolation(
                "Cannot commit publication \(publicationId): canonical file missing at \(canonicalPath)"
            )
        }
        let preMeasuredHash = try Self.fileSHA256(atPath: canonicalPath)
        guard preMeasuredHash == preExpectedHash else {
            throw ProjectStoreError.integrityViolation(
                "Cannot commit publication \(publicationId): bytes changed (expected \(preExpectedHash), found \(preMeasuredHash))"
            )
        }

        return try withTransaction {
            try verifyAttemptAuthorityInternal(jobId: jobId, attemptId: attemptId, fencingToken: fencingToken)
            guard var pub = try getPublicationInternal(id: publicationId) else {
                throw ProjectStoreError.publicationNotFound(publicationId)
            }

            // 2026-11-10 fix (P1-1): a publication may only be committed by the job/attempt
            // that created it.
            guard pub.jobId == jobId,
                  pub.attemptId == attemptId,
                  pub.fencingToken == fencingToken else {
                throw ProjectStoreError.integrityViolation(
                    "Publication \(publicationId) does not belong to job \(jobId) / attempt \(attemptId) / fencing \(fencingToken)"
                )
            }
            // The row must still describe the bytes that were measured outside the lock.
            guard let expectedHash = pub.sha256Hash, expectedHash == preExpectedHash,
                  preMeasuredHash == expectedHash else {
                throw ProjectStoreError.integrityViolation(
                    "Cannot commit publication \(publicationId): the publication changed while the commit was preparing"
                )
            }
            // A metadata check is constant-time and still catches a file deleted or replaced
            // in between; the bytes themselves were verified above, outside the write lock.
            if let onDisk = (try? FileManager.default.attributesOfItem(atPath: canonicalPath))?[.size] as? Int64,
               let recorded = pub.byteSize, recorded > 0, onDisk != recorded {
                throw ProjectStoreError.integrityViolation(
                    "Cannot commit publication \(publicationId): file size changed while committing"
                )
            }

            try pub.transitionToCommitted(canonicalPath: canonicalPath)

            guard let db = db else { throw ProjectStoreError.executionFailed("Database closed") }
            let sql = "UPDATE artifact_publications SET state = 'COMMITTED', canonical_path = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE publication_id = ? AND job_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw ProjectStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, canonicalPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, publicationId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, jobId.uuidString, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw ProjectStoreError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
            guard sqlite3_changes(db) == 1 else {
                throw ProjectStoreError.integrityViolation(
                    "Commit of publication \(publicationId) matched no row for job \(jobId)"
                )
            }

            let fullyPublished = try jobIsFullyPublishedInternal(jobId: jobId)
            if completeJob && !fullyPublished {
                // (P1-01) More artifacts are still owed by this job; completing it now would
                // report success for a partial result (e.g. an MP4 without its receipt).
                self.logPublicationDeferred(jobId: jobId, publicationId: publicationId)
            } else if completeJob {
                let attSql = "UPDATE job_attempts SET status = 'SUCCEEDED', finished_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE attempt_id = ?;"
                var attStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, attSql, -1, &attStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(attStmt) }
                    sqlite3_bind_text(attStmt, 1, attemptId.uuidString, -1, SQLITE_TRANSIENT)
                    _ = sqlite3_step(attStmt)
                }

                let jobSql = "UPDATE jobs SET status = 'SUCCEEDED', completed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE job_id = ?;"
                var jobStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, jobSql, -1, &jobStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(jobStmt) }
                    sqlite3_bind_text(jobStmt, 1, jobId.uuidString, -1, SQLITE_TRANSIENT)
                    _ = sqlite3_step(jobStmt)
                }
            }

            if let ikey = idempotencyKey {
                let idempSql = "INSERT OR REPLACE INTO idempotency_journal (operation_id, project_id, fencing_token, result_payload) VALUES (?, ?, ?, ?);"
                var idempStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, idempSql, -1, &idempStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(idempStmt) }
                    if let encoded = try? JSONEncoder().encode(pub),
                       let payloadStr = String(data: encoded, encoding: .utf8) {
                        sqlite3_bind_text(idempStmt, 1, ikey, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(idempStmt, 2, pub.projectId.uuidString, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_int(idempStmt, 3, Int32(fencingToken))
                        sqlite3_bind_text(idempStmt, 4, payloadStr, -1, SQLITE_TRANSIENT)
                        _ = sqlite3_step(idempStmt)
                    }
                }
            }

            return pub
        }
    }
```

`ArtifactPublicationRecord.byteSize` là `Int?` (đã có sẵn), nên nhánh `onDisk` biên dịch được
ngay. Nếu bạn muốn giữ đúng hành vi cũ (chỉ dựa vào hash) thì bỏ hẳn nhánh đó.

### 2.3. Test

Mở rộng `tests/test_p1_hashing_outside_transaction.swift`, thêm vào `main()` **trước** khối
`Task { await store.close() }`:

```swift
        // (P1-02A) commitPublication must hash before taking the write lock.
        let commitPub = UUID()
        try exec(handle, """
        INSERT INTO artifact_publications(
            publication_id, project_id, job_id, attempt_id, fencing_token, artifact_type,
            state, canonical_path, sha256_hash, byte_size)
        VALUES ('\(commitPub.uuidString)', '\(projectId.uuidString)', '\(jobId.uuidString)',
            '\(attemptId.uuidString)', 1, 'voice_wav', 'PREPARED', '\(artifact.path)',
            '\(sha(bytes))', \(bytes.count));
        """)
        do {
            _ = try await store.commitPublication(
                publicationId: commitPub, jobId: jobId, attemptId: attemptId,
                fencingToken: 1, canonicalPath: artifact.path
            )
            check(false, "commitPublication must refuse tampered bytes")
        } catch {
            check(true, "commitPublication refuses tampered bytes without taking the write lock for IO")
        }
```

(Ghi chú: `main()` hiện là `static func main() throws`, không `async`. Nếu cần `await`, đổi
thành `static func main() async throws` và gọi mọi chỗ bằng `try await`.)

---

## 3. P1-02B — G4: đo bằng chứng trên connection read-only trước transaction

Đây là phần lớn nhất. Nguyên tắc: **mọi** thao tác đọc file (băm, đọc JSON, ffprobe) chuyển
sang một lượt *pre-flight* trên connection `SQLITE_OPEN_READONLY`; transaction chỉ còn đọc
bảng, so sánh, và INSERT.

### 3.1. Thêm hàm pre-flight vào `G4S21Guard`

`packages/AIVideoCore/Sources/Storage/G4S21Guard.swift` — thêm vào `enum G4S21Guard` (đặt
ngay trước `static func verifyPreview`):

```swift
    /// (P1-02) Verify the whole S21 evidence set on a private read-only connection.
    ///
    /// Hashing the preview and a dozen dependencies inside `BEGIN IMMEDIATE` blocked the
    /// single canonical writer for seconds. This runs the same checks — G3 approval
    /// re-verification, dependency bytes, binding derivation, container header, ffprobe —
    /// before the write transaction opens, which afterwards only compares DB rows.
    static func verifyS21Evidence(
        databasePath: String,
        project: UUID,
        scriptRevisionId: String,
        candidate: [String: Any],
        manifest: [String: Any],
        dependencyIDs: [String],
        previewPublicationId: UUID,
        previewSHA: String,
        expectedFrames: Int
    ) throws {
        guard !databasePath.isEmpty else {
            throw reject("S21 verification needs the canonical database on disk")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            throw reject("Cannot open the canonical database read-only for S21 verification")
        }
        defer { sqlite3_close(db) }

        // 1. The G3 approval must still hold, measured against the published cut/WAV bytes.
        try G3ApprovalGuard.verify(
            db: db, projectId: project, scriptRevisionId: scriptRevisionId,
            candidate: candidate, manifest: manifest
        )

        // 2. Derive the dependency set from the approved cut, not from the RPC list.
        try verifyBindings(
            db: db, project: project, candidate: candidate,
            manifest: manifest, dependencyIDs: dependencyIDs
        )

        // 3. The preview must be a committed MP4 whose bytes are still the approved ones.
        guard let pub = try row(db, """
            SELECT state,artifact_type,sha256_hash,canonical_path,byte_size
            FROM artifact_publications WHERE publication_id=? AND project_id=?
            """, [previewPublicationId.uuidString, project.uuidString]),
            pub[0] == "COMMITTED", pub[1] == "g4_preview_mp4",
            pub[2] == previewSHA,
            let expectedSize = Int64(pub[4]), expectedSize > 1024 else {
            throw reject("G4 preview is not a committed S08 MP4")
        }
        let previewFile = URL(fileURLWithPath: pub[3])
        let previewHandle = try FileHandle(forReadingFrom: previewFile)
        let header = try previewHandle.read(upToCount: 16) ?? Data()
        try previewHandle.close()
        guard header.count >= 12,
              String(data: header[4..<8], encoding: .ascii) == "ftyp" else {
            throw reject("Published preview is not an MP4 container")
        }
        let (measuredSHA, measuredSize) = try measureFile(pub[3])
        guard measuredSHA == previewSHA, measuredSize == expectedSize else {
            throw reject("Published G4 preview bytes changed")
        }
        try verifyPreview(path: pub[3], expectedFrames: expectedFrames)
    }

    /// Streamed SHA-256 + size for one artifact.
    static func measureFile(_ path: String, maxBytes: Int64 = 4 * 1024 * 1024 * 1024) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            guard total <= maxBytes else { throw reject("Published artifact is too large") }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }
```

Nếu `row(...)` hoặc `reject(...)` là `private` trong file thì khối trên nằm **cùng file** nên
vẫn dùng được; nếu bạn tách file khác thì đổi thành `internal`.

### 3.2. Đọc input đã duyệt trên connection read-only

Thêm vào `G4S21Guard` (ngay trước `verifyS21Evidence`). Đây là bản sao 2 câu SELECT đang nằm
trong `approveG4Preview`, chỉ đổi connection:

```swift
    /// (P1-02) The approved script inputs, read once on a private read-only connection.
    struct ApprovedInputs {
        let scriptRevisionId: String
        let candidate: [String: Any]
        let manifest: [String: Any]
        let totalFrames: Int
    }

    static func readApprovedInputs(
        databasePath: String, projectId: UUID, g3ApprovalId: UUID
    ) throws -> ApprovedInputs {
        guard !databasePath.isEmpty else {
            throw reject("S21 verification needs the canonical database on disk")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            throw reject("Cannot open the canonical database read-only for S21 inputs")
        }
        defer { sqlite3_close(db) }
        guard let approval = try row(db, """
            SELECT a.manifest_sha256,a.script_revision_id,a.manifest_json,s.candidate_json
            FROM g3_approvals a JOIN g3_scripts s
              ON s.script_revision_id=a.script_revision_id
            JOIN g3_selected chosen ON chosen.project_id=a.project_id
              AND chosen.script_revision_id=a.script_revision_id
            WHERE a.project_id=? AND a.approval_id=?
            """, [projectId.uuidString, g3ApprovalId.uuidString]) else {
            throw reject("G3 approval is missing for this project")
        }
        guard let manifestData = approval[2].data(using: .utf8),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let candidateData = approval[3].data(using: .utf8),
              let candidate = try? JSONSerialization.jsonObject(with: candidateData) as? [String: Any],
              let totalFrames = manifest["total_frames"] as? Int, totalFrames > 0 else {
            throw reject("G3 approval payload is not readable JSON")
        }
        return ApprovedInputs(
            scriptRevisionId: approval[1], candidate: candidate,
            manifest: manifest, totalFrames: totalFrames
        )
    }
```

Nếu `JSONSerialization`/`Data` chưa import trong file thì thêm `import Foundation` ở đầu (file
hiện đã import, kiểm tra lại).

### 3.3. Thay body `approveG4Preview`

`packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift`.

**Giữ nguyên** từ đầu hàm đến hết guard `profile["color"] as? String == "bt709"` (khối kiểm
tra receipt thuần tuý).

**Xoá** toàn bộ từ dòng `return try g4Transaction { db in` cho tới hết các khối kiểm tra bên
trong (kết thúc ở `try G4S21Guard.verifyPreview(path: pub[3], expectedFrames: totalFrames)`),
tức là bỏ: khối `guard let approval`, `G3ApprovalGuard.verify`, vòng lặp dependencies, khối
`guard let pub`, `verifyBindings`, đọc header MP4, `G4SQL.fileSHA`, `verifyPreview`.

**Thay bằng:**

```swift
        guard let databasePath = dbURL?.path else {
            throw G3StoreError.diskStoreRequired
        }

        // (P1-02) Every file read — hashing the preview, hashing each dependency, reading
        // the cut/mapping JSON, ffprobe — happens here, before the write lock. Each of these
        // used to run inside `BEGIN IMMEDIATE`, blocking the single canonical writer (and
        // therefore the whole app) for seconds on a 4K preview.
        let inputs = try G4S21Guard.readApprovedInputs(
            databasePath: databasePath, projectId: projectId,
            g3ApprovalId: current.approvalId
        )
        try G4S21Guard.verifyS21Evidence(
            databasePath: databasePath,
            project: projectId,
            scriptRevisionId: inputs.scriptRevisionId,
            candidate: inputs.candidate,
            manifest: inputs.manifest,
            dependencyIDs: dependencies,
            previewPublicationId: previewPublicationId,
            previewSHA: previewSHA,
            expectedFrames: inputs.totalFrames
        )

        return try g4Transaction { db in
            // DB-only from here: re-read the rows this transaction pins and compare them with
            // what the pre-flight verified. No file IO may run inside the write lock.
            guard let approval = try G4SQL.row(db, """
                SELECT a.manifest_sha256,a.script_revision_id,a.workday_id,a.manifest_json,
                       s.candidate_json
                FROM g3_approvals a JOIN g3_scripts s
                  ON s.script_revision_id=a.script_revision_id
                JOIN g3_selected chosen ON chosen.project_id=a.project_id
                  AND chosen.script_revision_id=a.script_revision_id
                WHERE a.project_id=? AND a.approval_id=?
                """, [projectId.uuidString, current.approvalId.uuidString]),
                approval[0] == current.manifestSHA256,
                approval[1] == inputs.scriptRevisionId else {
                throw G3StoreError.conflict("G3 approval changed during G4 transaction")
            }
            guard let previewRow = try G4SQL.row(db, """
                SELECT state,artifact_type,sha256_hash,canonical_path,byte_size
                FROM artifact_publications WHERE publication_id=? AND project_id=?
                """, [previewPublicationId.uuidString, projectId.uuidString]),
                previewRow[0] == "COMMITTED", previewRow[1] == "g4_preview_mp4",
                previewRow[2] == previewSHA else {
                throw G3StoreError.blocked("G4 preview row changed during the transaction")
            }
            for depID in dependencies {
                guard let dep = try G4SQL.row(db, """
                    SELECT state,artifact_type,sha256_hash,byte_size
                    FROM artifact_publications WHERE publication_id=? AND project_id=?
                    """, [depID, projectId.uuidString]),
                    dep[0] == "COMMITTED", dep[2].count == 64,
                    let bytes = Int64(dep[3]), bytes > 0 else {
                    throw G3StoreError.blocked("G4 dependency row changed during the transaction")
                }
            }

            // ... phần `if let existing = try G4SQL.row(db, """SELECT approval_id,reviewed_by,...`
            //     cho tới hết hàm (INSERT g4_preview_approvals + artifact_pins + return) GIỮ NGUYÊN.
        }
```

Lưu ý quan trọng khi dán:

- `dependencies` và `previewSHA` là hai biến đã có sẵn từ khối kiểm tra receipt (không khai
  báo lại).
- Bạn **xoá** `let previewFile = ...` / `previewHandle` / `let measured = try G4SQL.fileSHA(...)`
  / `guard let totalFrames = ...` cũ; `totalFrames` nay là `inputs.totalFrames` và đã được
  dùng bên trong `verifyS21Evidence`.
- Nếu bạn còn `typeCounts` (đếm loại dependency) muốn giữ: nó là kiểm tra DB thuần, có thể
  đặt trong transaction; nhưng `verifyBindings` ở pre-flight đã kiểm chặt hơn, nên giữ lại
  không sai — chỉ đừng gọi `load(...)`/`fileSHA(...)` ở đó.

### 3.4. Test (bắt buộc)

Mở rộng `tests/test_g4_approval.swift` (hoặc file test G4 hiện có) bằng **test cấu trúc** —
đây là thứ chặn tái phát, vì test hành vi không quan sát được "đang giữ khoá":

```swift
    // (P1-02B) No file IO may happen inside the G4 write transaction.
    // The slice is bounded by the method's own braces: a plain "everything after" slice
    // would also cover `currentG4Preview`, which legitimately hashes the preview.
    static func testNoFileIOInsideG4Transaction() throws {
        let path = "packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift"
        let source = try String(contentsOfFile: path, encoding: .utf8)
        guard let methodStart = source.range(of: "public func approveG4Preview"),
              let txStart = source.range(of: "g4Transaction {",
                                         range: methodStart.upperBound..<source.endIndex) else {
            throw NSError(domain: "g4", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "approveG4Preview no longer opens a g4Transaction"
            ])
        }
        var depth = 0
        var index = txStart.lowerBound
        var end = source.endIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { end = source.index(after: index); break }
            }
            index = source.index(after: index)
        }
        let body = String(source[txStart.lowerBound..<end])
        for forbidden in ["fileSHA(", "verifyBindings(", "G3ApprovalGuard.verify(",
                          "verifyPreview(", "verifyS21Evidence(", "readApprovedInputs("] {
            if body.contains(forbidden) {
                throw NSError(domain: "g4", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "G4 write transaction still performs IO: \(forbidden)"
                ])
            }
        }
    }
```

Ý nghĩa: nếu ai đó (kể cả tôi) đưa lời gọi băm/ffprobe trở lại trong closure transaction, test
đỏ ngay.

---

## 4. Checklist áp dụng

- [ ] §1 P1-31: sửa `native_render.build_beats_from_plan`, thêm `tests/test_p31_transition_source.py`
- [ ] Chạy `tests/test_s20_native_render.py` + `tests/test_p31_transition_source.py` → xanh
- [ ] §2 P1-02A: sửa `commitPublication`, thêm case vào `tests/test_p1_hashing_outside_transaction.swift`
- [ ] §3 P1-02B: `verifyS21Evidence` + `measureFile` trong `G4S21Guard`; bước 1–3 trong `approveG4Preview`; test cấu trúc
- [ ] Chạy toàn bộ §5
- [ ] Cập nhật `docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`: đổi P1-02 và P1-31 từ "ĐÃ SỬA MỘT PHẦN" → "ĐÃ SỬA" (chỉ khi §5 xanh)
- [ ] Ghi 1 mục mới vào `progress.md` với số liệu thật của lần chạy
- [ ] Commit tách 2 lần: `fix(g4): measure S21 evidence outside the write lock (P1-02)` và `test(p31): transitions must come from the approved plan`

---

## 5. Lệnh kiểm chứng (chạy đúng thứ tự này)

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo

# 1. Python: suite mới + các suite bị ảnh hưởng
workers/.venv/bin/python3 tests/test_p31_transition_source.py
workers/.venv/bin/python3 tests/test_s20_native_render.py
workers/.venv/bin/python3 tests/test_p1_closure.py

# 2. Swift: riêng phần vừa sửa
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library \
  $(find packages/AIVideoCore/Sources -name '*.swift') \
  tests/test_p1_hashing_outside_transaction.swift -o /tmp/t_io && /tmp/t_io

# 3. App phải build
./tools/build_macos_app.sh

# 4. Toàn bộ Python + ma trận
workers/.venv/bin/python3 tools/run_python_tests.py   # hiện tại: 428 run, 0 fail, 4 NOT_RUN
./tools/run_tests.sh
```

Kỳ vọng:

- `tools/run_python_tests.py`: **số hiện tại + 4**, 0 FAIL, 0 ERROR (hiện tại 428 ⇒ sau khi thêm
  `test_p31_transition_source.py` phải là 432).
- `./tools/run_tests.sh`: **exit 0**, 23 khối, dòng cuối
  `ALL REGRESSION TEST SUITES EXECUTED SUCCESSFULLY`.
- `build_macos_app.sh`: `BUILD SUCCESSFUL`.

Nếu `run_tests.sh` báo lỗi biên dịch ở một suite Swift mà `build_macos_app.sh` vẫn xanh: kiểm
tra file mới đã nằm trong `packages/AIVideoCore/Sources/**` (script đã glob, không cần sửa
danh sách) và bạn không vô tình tạo file ngoài các thư mục đó.

---

## 6. Rollback

Mỗi mục độc lập, rollback bằng git:

```bash
git checkout -- workers/src/aivideo_workers/native_render.py            # P1-31
git checkout -- packages/AIVideoCore/Sources/Storage/ProjectStore.swift # P1-02A
git checkout -- packages/AIVideoCore/Sources/Storage/G4ProjectStore.swift \
                packages/AIVideoCore/Sources/Storage/G4S21Guard.swift    # P1-02B
rm -f tests/test_p31_transition_source.py
```

Không có migration DB nào trong 2 mục này ⇒ rollback không cần chạm dữ liệu.

---

## 7. Bẫy đã gặp thật trong repo này (đừng lặp lại)

1. **APFS không phân biệt hoa/thường.** `rm -rf .../Resources/workers` xoá luôn
   `Resources/Workers` (bản worker duy nhất). Đừng dùng rm theo đường dẫn "legacy"; assert
   thay vì xoá.
2. **`git stash` trên file untracked làm mất bài.** Một lần đã mất bản sửa
   `G5S22Guard.swift`. Muốn chứng minh "đỏ trước fix" thì copy sang `/tmp` rồi thử ở đó.
3. **Danh sách file Swift viết tay.** Trước P2-01, thêm một file `.swift` làm mọi suite Swift
   fail (`cannot find type`) trong khi app vẫn build. Nay cả `build_macos_app.sh` và
   `run_tests.sh` đều glob — đừng quay lại liệt kê tay.
4. **SDK.** `xcrun --show-sdk-path` trả MacOSX27, không build được với swiftc 6.3.3. Luôn dùng
   `-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`.
5. **Plan hash là thứ được approval pin.** Thêm khoá vào plan dict (ví dụ `"transitions": {}`)
   làm `plan_sha256` đổi ⇒ mọi approval và fixture đang có sẽ invalid. Vì vậy §1 chọn "thiếu
   khoá = không cho transition" thay vì thêm khoá rỗng.

---

## 8. Sau khi xong 2 mục này

Trạng thái audit sẽ là: **9/9 P0, 54/54 P1 đã sửa đầy đủ, 14/14 P2 đã xử lý**.
Điều duy nhất còn lại không phải là code: `fixtures/smoke` vẫn là title card tổng hợp, nên
`tools/check_readiness.py` phải tiếp tục trả **NO-GO (exit 2)** cho tới khi có footage thật và
nhãn do người gán (xem `docs/PLAYBOOK_KIEM_THU.md` mục corpus).
