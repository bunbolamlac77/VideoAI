# AIVideo v3.1 — ứng dụng dựng video POV tiếng Việt trên macOS

**Trạng thái:** đã triển khai và có test chạy thật trên Apple Silicon (macOS 26.7.1, Swift
6.3.3, Python 3.12). Chưa phát hành: thiếu footage hiện trường để chứng nhận Gate G2 (xem §7).

Tài liệu này mô tả **ứng dụng đang chạy trong repo này**, không phải bản đặc tả đề xuất. Bộ
đặc tả gốc 01–11 vẫn nằm trong [`docs/`](docs/) và ở gốc repo (hai bản phải giống nhau từng
byte — có test canh); khi đặc tả và README khác nhau về *trạng thái triển khai*, README này và
[`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md)
là nguồn đúng.

## 1. Chạy nhanh

```bash
cd <repo>
./tools/setup_g0_model.py --install          # Python runtime + ffmpeg (idempotent)
workers/.venv/bin/python3 tools/check_readiness.py   # preflight: NO-GO là ĐÚNG khi thiếu corpus
./tools/build_macos_app.sh                   # build apps/macos/build/AIVideo.app
open apps/macos/build/AIVideo.app            # hoặc mở từ Finder
```

Kiểm thử (đây là những lệnh tôi thật sự chạy để lấy bằng chứng):

```bash
workers/.venv/bin/python3 tools/run_python_tests.py    # 428 case
./tools/run_tests.sh                                   # 23 khối: build + 17 suite Swift + Python
AIVIDEO_RUN_HEAVY_G2=1 AIVIDEO_RUN_HEAVY_STORY=1 AIVIDEO_RUN_HEAVY_TTS=1 \
  workers/.venv/bin/python3 tools/run_python_tests.py  # bật 4 case model thật
```

Kết quả mong đợi ở lần chạy gần nhất: Python **428 chạy · 0 FAIL · 0 ERROR · 4 NOT_RUN**
(heavy: 0 skip); `run_tests.sh` **exit 0**; `build_macos_app.sh` **BUILD SUCCESSFUL**.

## 2. Kiến trúc (thực tế trong repo)

```
apps/macos/Sources/      SwiftUI shell + AppState (4 bước + màn chẩn đoán)
packages/AIVideoCore/    Swift core: SQLite, gate store/guard, IPC, publisher, backup
workers/src/aivideo_workers/  Python: model offline, pipeline G2, engine G3, renderer ffmpeg, G4/G5
contracts/               JSON/SQL contract + model registry lock
fixtures/smoke/          5 clip title-card tổng hợp (smoke), KHÔNG phải field corpus
tests/                   Python + Swift suite (JSONL record)
tools/                   runner, build, preflight, package review, historical/
```

Nguyên tắc bất biến (đều có test canh):

1. **Swift core là writer duy nhất của SQLite.** Python/gate store chỉ đọc (connection
   `SQLITE_OPEN_READONLY`); `tests/test_single_writer_invariants.py` chặn mọi write handle khác.
2. **Một nguồn schema:** Swift tạo 23 bảng và stamp `PRAGMA user_version = 2`; cột thêm về sau
   do `ProjectStore.migrateAdditiveColumns` áp tại chỗ. File SQL trong
   `contracts/migrations/fixtures/` chỉ là fixture test — xem
   [`contracts/migrations/README.md`](contracts/migrations/README.md).
3. **Mọi kết luận phải truy được về bằng chứng:** claim/cut/approval đều gắn `sha256` + timecode
   + publication id; `Unknown` là giá trị hợp lệ.
4. **100% local:** không gọi API AI đám mây; model lấy từ model registry có pin.
5. **Một bản worker trong bundle:** `Resources/Workers/aivideo_workers` (script build còn assert
   đúng 1 `main.py`).

## 3. Bốn bước người dùng

1. **Tư liệu** — chọn folder/video/ảnh, ffprobe, chạy G2 (một video hoặc cả batch; "Dừng" huỷ
   RPC đang chạy, không chỉ đặt cờ).
2. **Kịch bản & Thoại** — brief một ô, kịch bản qua S19, thử giọng, tìm cut `SEARCH-v1`.
   Độ dài cue lấy từ WAV đã đo; không đoán theo số từ.
3. **Preview** — render native ffmpeg 1080×1920 (hoặc Resolve), nghe/nhìn rồi mới duyệt.
4. **Final 4K** — 2160×3840 @ 24 fps + provenance (`.drp` **hoặc** receipt native), duyệt tay.

Màn chẩn đoán (Kiểm chứng G2 / Dữ liệu / Model / Resolve / Năng lực) nằm trong nhóm "Nâng cao".

## 4. RPC (42 method, stdio JSON-RPC 2.0)

Nhóm chính: `initialize`, `media.probe`, `media.index_and_proxy`, `ai.model_status`,
`ai.local_infer_test`, `g2.analyze_source`, **`g2.get_raw_observations`** (phân trang
observation của một lần phân tích), `g3.*` (story/voice/cut/approval), `g4.*`, `g5.*`,
`resolve.*`.

Tham số **bị từ chối** (fail-closed, không phải tuỳ chọn):

| Tham số | Lý do |
|---|---|
| `checkpoint_dir` | worker tự sở hữu checkpoint root |
| `models_root_dir`, env `AIVIDEO_MODELS_ROOT` | model root do app cấp, không do request |
| `registry_path`, `app_binary_path` | registry/binary phải là bản pin |
| `staging_root` | render root do `AIVIDEO_RENDER_ROOT` (app) cấp |
| `allow_overwrite` | không ghi đè artifact đã duyệt qua RPC |
| `inspector_factory` qua RPC | chỉ là seam của test, không qua IPC |

Env do app cấp cho worker: `AIVIDEO_APP_RESOURCES`, `AIVIDEO_APP_SUPPORT` (profile, gồm model
root), `AIVIDEO_G3_STAGING_ROOT`, `AIVIDEO_G4_WORK_ROOT`, `AIVIDEO_G5_WORK_ROOT`,
`AIVIDEO_RENDER_ROOT`. `AIVIDEO_CONTRACTS_DIR` **bị từ chối** — contract resolve theo vị trí
package/bundle.

## 5. Dữ liệu & bằng chứng

- DB: `~/Library/Application Support/AIVideo/…/project_store.db` (WAL). Chỉ đọc bằng
  `sqlite3 -readonly`.
- Báo cáo test: `build/reports/python_test_records.jsonl`, `build/reports/swift_*_records.jsonl`;
  lần chạy trước được giữ ở `build/reports/previous/` (ma trận không xoá bằng chứng cũ).
- Đóng gói review: `tools/package_review.py` chỉ báo DONE khi có record PASS; đỏ ⇒ exit ≠ 0.
- Preflight: `tools/check_readiness.py` (thêm `--allow-adhoc` nếu bạn cố ý chấp nhận bản dev
  chưa ký Developer ID).

## 6. Trạng thái gate

| Gate | Trạng thái | Ghi chú |
|---|---|---|
| G0 | 🟢 DONE | app bundle, worker stdio, Resolve spike |
| G1 | 🟢 DONE | single-writer WAL, backup/restore, governor, publication cycle |
| G2 | 🟡 IN_REVIEW | pipeline + model chạy thật; **chưa có field corpus** (5 clip smoke là title card 1,5 s, nhãn do agent) |
| G3 | 🟢 DONE | story/voice/cut + `G3ApprovalGuard` |
| G4 | 🟢 DONE | Resolve/native preview 1080×1920 + `G4S21Guard` |
| G5 | 🟡 IN_REVIEW | S22 guard có test; S25 fault suite tự báo `SELF_TEST_ONLY` |

`tools/check_readiness.py` trả **NO-GO (exit 2)** là hành vi đúng cho tới khi có footage thật +
nhãn người: đây là điều kiện để tránh tuyên bố chất lượng không có bằng chứng.

## 7. Việc còn lại (không giấu)

- **Chỉ còn điều kiện dữ liệu, không còn lỗi mã đã biết:** 9/9 P0, 54/54 P1 (kể cả P1-02 nhánh
  G4/`commitPublication` và P1-31 transition) và 14/14 nhóm P2 đã đóng, mỗi mục có test.
- **Field corpus**: cần footage Rec.709 thật + nhãn người + manifest ký để chuyển G2 và S25 sang
  DONE. Trước đó `tools/check_readiness.py` phải tiếp tục NO-GO.
- Biên bản áp dụng P1-02/P1-31: [`docs/PROPOSED_REMAINING_FIXES.md`](docs/PROPOSED_REMAINING_FIXES.md)
  (đã áp dụng; giữ để giải thích lý do và danh sách bẫy).
- Lịch sử kiểm toán: [`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).

## 8. Bản đồ tài liệu

| File | Vai trò |
|---|---|
| `README.md` | trạng thái + cách chạy (file này) |
| `docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md` | kiểm toán mới nhất, trạng thái từng lỗi |
| `docs/PLAYBOOK_KIEM_THU.md` | playbook kiểm thử theo tầng A/B/C/D |
| `docs/PROPOSED_REMAINING_FIXES.md` | code đề xuất cho 2 mục còn sửa một phần |
| `docs/01`–`docs/11` | đặc tả sản phẩm/kỹ thuật gốc (giữ nguyên nội dung, xem mục "trạng thái" đầu mỗi file) |
| `progress.md` | nhật ký bằng chứng theo phiên |
| `task_plan.md` | kế hoạch gate, ghi rõ mục nào còn mở |
| `reports/progress/S*.md` | báo cáo từng bước S00–S26 (ảnh chụp lịch sử) |
