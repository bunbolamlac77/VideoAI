# AIVideo v3.1 — Bảng điều khiển tiến trình

> **Cập nhật:** 2026-11-11 (sau khi đóng 9 P0 + 54 P1 + 14 nhóm P2).
> Bảng này chỉ ghi **trạng thái hiện tại**. Nhật ký bằng chứng theo phiên nằm ở
> [`progress.md`](progress.md); biên bản từng bước ở [`reports/progress/`](reports/progress/).

**Kiến trúc:** SwiftUI (native) + Swift core (`ProjectStore`, SQLite WAL, writer duy nhất) +
Python worker (stdio JSON-RPC, 42 method) + renderer ffmpeg native (mặc định), Resolve Studio
tuỳ chọn. **Máy mục tiêu:** Apple Silicon M1 Pro, 16 GB.
**Bất biến:** 100% local · Swift core độc quyền ghi DB · mọi kết luận có `sha256` + timecode ·
`Unknown` là hợp lệ.

## 1. Trạng thái gate

| Gate | Bước | Trạng thái | Vì sao |
|---|---|---|---|
| **G0** Nền tảng | S00–S03 | 🟢 DONE | `.app` arm64, worker stdio, bookmark/security-scope, Resolve spike 240 frame @24fps |
| **G1** Dữ liệu & phục hồi | S04–S09 | 🟢 DONE | single-writer WAL, snapshot, governor, 4-stage publication, backup/restore + migration tại chỗ |
| **G2** Phân tích | S10–S15 | 🟡 IN_REVIEW | pipeline + Qwen3-VL 4B chạy thật, **nhưng** chưa có field corpus: `fixtures/smoke` là title card 1,5 s, nhãn agent, 0 claim/0 event ⇒ preflight NO-GO |
| **G3** Kịch bản & thoại | S16–S19 | 🟢 DONE | story ràng buộc nguồn, Kokoro TTS + cổng nghe, `SEARCH-v1`, `G3ApprovalGuard` |
| **G4** Preview | S20–S21 | 🟢 DONE | preview 1080×1920 (native hoặc Resolve), QC tự động, `G4S21Guard` |
| **G5** Final & phát hành | S22–S26 | 🟡 IN_REVIEW | S22 guard có test; `g5.fault.run_suite` tự báo `SELF_TEST_ONLY`; manifest ký Ed25519 nhưng `s25_fault_evidence.certified=false` |

Ký hiệu: ⚪ NOT_STARTED · 🟡 IN_REVIEW/IN_PROGRESS · 🟢 DONE · 🔴 BLOCKED.

## 2. Điều kiện để đóng 2 gate còn mở

**G2 cần:** ≥5 clip Rec.709 thật + nhãn **người** (`labeler_type=human`,
`source_kind=field_footage`) + manifest ký Ed25519 + `corpus_scope.runs_sha256` khớp digest của
runs. Sau đó `tools/check_readiness.py` mới có thể GO.

**G5 cần:** một fault run thật trên DB canonical (không phải thư mục tạm). Hiện
`g5_release_audit.validate_real_fault_suite_evidence` từ chối mọi evidence tự khai.

## 3. 27 bước

### G0 — Nền tảng
- [x] S00 repo + tài liệu + sổ tiến độ — [`S00`](reports/progress/S00.md)
- [x] S01 môi trường & compatibility matrix — [`S01`](reports/progress/S01.md)
- [x] S02 app bundle + stdio JSON-RPC + bookmark + G0 smoke — [`S02`](reports/progress/S02.md)
- [x] S03 Resolve spike 2160×3840@24 — [`S03`](reports/progress/S03.md)

### G1 — Dữ liệu & phục hồi
- [x] S04 hợp đồng dữ liệu, schema, state machine — [`S04`](reports/progress/S04.md)
- [x] S05 import + băm + snapshot APFS — [`S05`](reports/progress/S05.md)
- [x] S06 `ProjectStore` actor, WAL, revision — [`S06`](reports/progress/S06.md)
- [x] S07 governor, scheduler, fencing — [`S07`](reports/progress/S07.md)
- [x] S08 publication 4 pha + reconciler — [`S08`](reports/progress/S08.md)
- [x] S09 backup/restore + migration — [`S09`](reports/progress/S09.md)

### G2 — Phân tích (mã xong, chứng nhận chờ corpus)
- [x] S10 media indexer VFR→CFR, proxy, Rec.709 — [`S10`](reports/progress/S10.md)
- [x] S11 model adapters + pin trọng số + registry — [`S11`](reports/progress/S11.md)
- [x] S12 pipeline full-frame + coverage + checkpoint — [`S12`](reports/progress/S12.md)
- [x] S13 brief parser, claim verifier, event graph — [`S13`](reports/progress/S13.md)
- [x] S14 review có bằng chứng + 6 lệnh giải quyết — [`S14`](reports/progress/S14.md)
- [x] S15 benchmark harness (`HARNESS_PASS`/`HARNESS_FAIL`) — [`S15`](reports/progress/S15.md)
- [ ] **Chứng nhận G2 trên field corpus** — chờ footage thật + nhãn người

### G3 — Kịch bản & thoại
- [x] S16 story sinh có provenance từng beat — [`S16`](reports/progress/S16.md)
- [x] S17 Kokoro-Vietnamese TTS + cổng nghe WAV — [`S17`](reports/progress/S17.md)
- [x] S18 `SEARCH-v1` (node budget tính cả lookahead) — [`S18`](reports/progress/S18.md)
- [x] S19 `G3ApprovalGuard` + scope revalidation — [`S19`](reports/progress/S19.md)

### G4 — Preview
- [x] S20 managed timeline / native render + caption — [`S20`](reports/progress/S20.md)
- [x] S21 QC preview + `G4S21Guard` — [`S21`](reports/progress/S21.md)

### G5 — Final & phát hành
- [x] S22 final 4K + provenance (`.drp` hoặc receipt native) — [`S22`](reports/progress/S22.md)
- [x] S23 nâng cấp có cổng năng lực trung thực — [`S23`](reports/progress/S23.md)
- [x] S24 UI 4K, IME, cache có giới hạn — [`S24`](reports/progress/S24.md)
- [x] S25 fault accounting + E0/E1 — [`S25`](reports/progress/S25.md)
- [x] S26 release manifest (Ed25519) — [`S26`](reports/progress/S26.md)
- [ ] **Fault run thật** (S25) — chờ chạy trên DB canonical

## 4. Bằng chứng hiện tại

```
workers/.venv/bin/python3 tools/run_python_tests.py
  → 428 run · 0 FAIL · 0 ERROR · 4 NOT_RUN (4 case model thật; heavy: 0 skip)

./tools/run_tests.sh
  → exit 0, 23 khối, "ALL REGRESSION TEST SUITES EXECUTED SUCCESSFULLY"

./tools/build_macos_app.sh
  → BUILD SUCCESSFUL, bundle 736K, đúng 1 worker

workers/.venv/bin/python3 tools/check_readiness.py
  → exit 2 / NO-GO (đúng: thiếu signed field corpus + app ad-hoc)
```
