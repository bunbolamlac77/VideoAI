# PLAYBOOK KIỂM THỬ — AIVideo v3.1

**Cập nhật:** 2026-11-11, sau khi đóng 9 P0 + 54 P1 + 14 nhóm P2.
**Trạng thái code:** mọi case trong tài liệu này đã được kiểm chứng trên cây hiện tại; những
case từng là "lỗi đang tồn tại" nay là **test hồi quy** (nếu ai làm hỏng lại, test đỏ).

Tài liệu liên quan: [`README`](../README.md) · [kiểm toán 2026-11-11](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md) ·
[đề xuất còn lại](PROPOSED_REMAINING_FIXES.md).

## PHẦN 0 — CÁCH DÙNG PLAYBOOK

1. Chạy tầng A trước (tự động). Tầng A xanh mới có nghĩa để chạy tầng B/C.
2. Kết quả ghi theo mẫu ở PHẦN 7: PASS / FAIL / NOT_RUN / BLOCKED + bằng chứng (đường dẫn file,
   đoạn log, mã lỗi).
3. **Luật vàng:** một case chỉ PASS khi *bạn đã cố tình làm hỏng* điều kiện của nó ít nhất một
   lần và thấy nó FAIL. Không có cách làm nó FAIL ⇒ đó là test trang trí, phải viết lại.

Ký hiệu: ✅ tự động hoá · 🖐 cần thao tác tay · 🕐 chậm (> 2 phút).

## PHẦN 1 — CHUẨN BỊ

### 1.1. Tiên quyết

| ID | Kiểm tra | Lệnh | Kỳ vọng |
|---|---|---|---|
| E-01 | Swift + SDK đúng | `swiftc --version` và `ls /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` | Swift 6.3.x; SDK này phải tồn tại (**không** dùng `xcrun --show-sdk-path`, nó trả MacOSX27 và build sẽ fail) |
| E-02 | Python runtime của worker | `workers/.venv/bin/python3 -V` | 3.12.x |
| E-03 | ffmpeg/ffprobe | `ffmpeg -version \| head -1` | 7.x; nằm trong PATH mà app nhìn thấy (`/opt/homebrew/bin`) |
| E-04 | Model đã cài | `workers/.venv/bin/python3 -c "from aivideo_workers.model_installation import inspect_model_installation as i; print(i(deep=True))"` | `state=verified`, có `pinned_weights_sha256` |
| E-05 | ASR | `workers/.venv/bin/python3 -c "import mlx_whisper"` | **FAIL** là đúng hiện trạng: ASR chưa nối vào runtime |

### 1.2. Biến môi trường

| Biến | Ý nghĩa | Ai đặt |
|---|---|---|
| `AIVIDEO_PYTHON` | python cho app + harness | bạn / CI |
| `AIVIDEO_REPO_ROOT` | trỏ app về checkout | bạn (khi chạy app build) |
| `AIVIDEO_APP_SUPPORT` | profile dir; **model root** = `<dir>/Models` | app / test |
| `AIVIDEO_RENDER_ROOT` | root cho renderer ffmpeg | app (P1-15) |
| `AIVIDEO_G3_STAGING_ROOT`, `AIVIDEO_G4_WORK_ROOT`, `AIVIDEO_G5_WORK_ROOT` | staging theo gate | app |
| `AIVIDEO_RELEASE_TEAM_ID` | Team ID bắt buộc khi release | CI |
| `AIVIDEO_RUN_HEAVY_G2` / `_STORY` / `_TTS` | bật 4 case model thật | bạn |
| `AIVIDEO_TEST_HARNESS=1` | chỉ khi đó `AIVIDEO_G5_SIMULATE_FREE_BYTES` mới có hiệu lực | test |

**Bị từ chối có chủ đích:** `AIVIDEO_CONTRACTS_DIR`, `AIVIDEO_MODELS_ROOT` (worker raise
`CONTRACTS_DIR_FORBIDDEN` / `MODELS_ROOT_FORBIDDEN`). Đừng "sửa" bằng cách export chúng.

### 1.3. Fixture

| Thứ cần | Đường dẫn | Ghi chú |
|---|---|---|
| Smoke clips | `fixtures/smoke/*.mp4` | **title card 1,5 s tổng hợp** (1080×1920, 36 frame), nhãn do agent — chỉ để smoke, **không** phải field corpus |
| Checkpoint cũ | `fixtures/smoke/ckpt_trip-holdout-*.json` | bị `.gitignore` cho `ckpt_v2_*`; phục vụ test resume |
| Field corpus thật | bạn tự chuẩn bị | cần ≥5 clip Rec.709 + nhãn người + manifest ký Ed25519 |

## PHẦN 2 — TẦNG A: TỰ ĐỘNG

### 2.1. Python (428 case)

| ID | Mục tiêu | Lệnh | Kỳ vọng |
|---|---|---|---|
| A-PY-01 ✅ | Toàn bộ Python | `workers/.venv/bin/python3 tools/run_python_tests.py` | `428 run · 0 fail · 0 error · 4 NOT_RUN` |
| A-PY-02 ✅ | Record khớp summary | đọc `build/reports/python_test_summary.json` và đếm dòng `python_test_records.jsonl` | số dòng = `tests_run`; 4 record `NOT_RUN` là 4 case model thật |
| A-PY-03 ✅ | 4 case model thật chạy được | thêm `AIVIDEO_RUN_HEAVY_G2=1 AIVIDEO_RUN_HEAVY_STORY=1 AIVIDEO_RUN_HEAVY_TTS=1` | `skipped=0`, 0 fail (S15 ≈ 110 s, S16 ≈ 11 s, TTS ≈ 4 s/case) |
| A-PY-04 ✅ | Chạy lẻ từng file | `for t in tests/test_*.py; do workers/.venv/bin/python3 "$t" \|\| echo "FAIL $t"; done` | không dòng `FAIL` |
| A-PY-05 ✅ | Traceability | `python3 -c "import json,collections;rows=[json.loads(l) for l in open('build/reports/python_test_records.jsonl')];print(collections.Counter(r['requirement_id'] for r in rows).most_common(3))"` | `JOB-04` ≤ 7 (không còn 151 record rơi vào mặc định) |

### 2.2. Swift (17 suite trong ma trận)

| ID | Mục tiêu | Lệnh | Kỳ vọng |
|---|---|---|---|
| A-SW-01 ✅ | Build app | `./tools/build_macos_app.sh` | `BUILD SUCCESSFUL`; bundle có **đúng 1** `Workers/aivideo_workers/main.py`; không còn `Resources/workers` |
| A-SW-02 ✅ | Typecheck chặt | `swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library -typecheck -warnings-as-errors $(find packages/AIVideoCore/Sources -name '*.swift')` | không lỗi, không cảnh báo |
| A-SW-03 ✅ | Suite lẻ | `swiftc -sdk … $(find packages/AIVideoCore/Sources -name '*.swift') tests/<suite>.swift -o /tmp/x && /tmp/x` | exit 0; banner `ALL … (n/n)` với `n` = số case thật |
| A-SW-04 ✅ | Banner không tautology | đổi 1 assertion thành no-op rồi chạy lại | banner báo `n-1/n` và exit ≠ 0 |

### 2.3. Ma trận gộp

| ID | Lệnh | Kỳ vọng |
|---|---|---|
| A-ALL-01 🕐 ✅ | `./tools/run_tests.sh` | **exit 0**, 23 khối, dòng cuối `ALL REGRESSION TEST SUITES EXECUTED SUCCESSFULLY`; không có `[FAIL]` thật (dòng `print("❌ FAIL…")` in ra từ source là bình thường) |
| A-ALL-02 ✅ | Record được giữ lại | `ls build/reports/previous/*.jsonl \| wc -l` ≥ 1 — ma trận không xoá bằng chứng cũ |
| A-ALL-03 ✅ | Resolve spike | nếu Resolve đóng: script ghi `BLOCKED` và exit 2, ma trận vẫn exit 0 nhưng **không** tính PASS cho S03 |

### 2.4. Preflight & đóng gói

| ID | Lệnh | Kỳ vọng |
|---|---|---|
| A-PF-01 ✅ | `workers/.venv/bin/python3 tools/check_readiness.py; echo $?` | **exit 2** với blocker `UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS` và `APP_BUNDLE_NOT_VERIFIED` (app ký ad-hoc) |
| A-PF-02 ✅ | `AIVIDEO_RELEASE_TEAM_ID=ABCDE12345 workers/.venv/bin/python3 tools/check_readiness.py` | vẫn fail: app ad-hoc ≠ Team ID (P1-22) |
| A-PF-03 ✅ | `--allow-adhoc` | `… --allow-adhoc` ⇒ hết blocker chữ ký nhưng **vẫn** NO-GO vì corpus |
| A-PF-04 ✅ | `python3 tools/package_review.py /tmp/review.zip; echo $?` | xanh ⇒ 0; xoá 1 record PASS ⇒ DONE biến NOT_RUN và **exit ≠ 0** (P0-05/P1-41) |

## PHẦN 3 — TẦNG B: ĐƯỜNG WORKER (JSON-RPC trực tiếp)

Gọi qua `workers/src/aivideo_workers/main.py` với stdio; hoặc dùng `WorkerClient` trong test.

### 3.1. Wire protocol

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| B-01 ✅ | `initialize` | `protocolVersion 2.0`, `capabilities` gồm 42 method |
| B-02 ✅ | Method lạ | lỗi `-32601` |
| B-03 ✅ | Params sai kiểu | lỗi `-32602`, không có stack trace ra stdout |
| B-04 ✅ | Log lẫn stdout | stdout chỉ có JSON; log đi stderr |
| B-05 ✅ | `ping` | `pong` + `server_time` |

### 3.2. Media & phân tích G2

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| B-10 ✅ | `media.probe` với `fixtures/smoke/trip-holdout-01-dalat.mp4` | 1080×1920, `24/1`, 36 frame |
| B-11 ✅ | `g2.analyze_source` với `checkpoint_dir=/tmp/x` | **từ chối** `CHECKPOINT_DIR_FORBIDDEN` (P0-01) |
| B-12 ✅ | `g2.analyze_source` với `models_root_dir` hoặc env `AIVIDEO_MODELS_ROOT` | **từ chối** `MODELS_ROOT_FORBIDDEN` **trước** mọi IO (P1-12) |
| B-13 ✅ | Tự viết `g2_ckpt_*.json` có `raw_observations` bịa, gọi lại khi model bị chặn | `blocked_model_unavailable`, **không** trả observation (P0-01) |
| B-14 ✅ | Checkpoint có provenance lạ | `CHECKPOINT_PROVENANCE_MISMATCH` (P0-01) |
| B-15 🕐 ✅ | Phân tích clip dài, sample 2/16 | `window_coverage` < 1.0; ledger có `denominator_source`; `VISUAL_SAMPLE_OUTSIDE_WINDOW` không xuất hiện (P0-02, P1-26) |
| B-16 ✅ | Clip không có `nb_frames` và `duration` | `COVERAGE_DENOMINATOR_UNAVAILABLE` — **không** lấy index làm mẫu số (P1-26) |
| B-17 🕐 ✅ | Clip dài (7200 cửa sổ) | response **không** vượt 1 MiB; `raw_observations_truncated=true` + `raw_observations_next_offset`; gọi `g2.get_raw_observations` để lấy trang tiếp (P1-25) |
| B-18 ✅ | `g2.get_raw_observations` với `source_revision_id="../../etc/passwd"` | `ValueError` — không nhận đường dẫn (P1-25) |
| B-19 ✅ | Inspector trả 1/16 frame | `window_frame_coverage = 1/16`, `truncation_detected=false`; trả 0 frame ⇒ raise (P0-02) |
| B-20 ✅ | Audio | không audio ⇒ `no_audio`; **có audio nhưng chưa ASR** ⇒ `audio_present_untranscribed` (P1-27); `asr_status=not_configured` |

### 3.3. G3 — kịch bản, thoại, cut, duyệt

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| B-30 ✅ | `g3.voice.trial` khi chưa nghe WAV | `voice_review_status="unverified"` (P0-07) |
| B-31 ✅ | `g3.cut.search` với `voice_review_status="unverified"` | tách biệt `verified` / `unverified` trong kết quả, không trộn (P0-07) |
| B-32 ✅ | `eligible_claims` khi thiếu scope revalidation | lý do `missing_scope_revalidation`, **không** mặc định "hoàn tất" (P0-09) |
| B-33 ✅ | LLM narration không có provenance đầy đủ | từ chối (P0-08): cần `voice_text_origin`, `voice_text_sha256`, `voice_prompt_sha256`, `voice_model_id` |
| B-34 ✅ | LLM thêm địa danh không có trong claim ("Đà Lạt") | `STORY_INVENTED_ENTITY` (P1-37) |
| B-35 ✅ | LLM thêm chữ số không có trong claim | `STORY_INVENTED_FACT` |
| B-36 ✅ | TTS runtime chết ở `infer` | `blocked_tts_runtime_unavailable`, **không** `-32603` (P1-36) |
| B-37 ✅ | `g3.cut.search` với `node_budget=500` và `forward_check=true` | dừng trong vài giây; `nodes_visited` ≤ ngân sách × hằng số nhỏ (P1-35) |
| B-38 ✅ | `stage_cut_plan` với `script_revision_id` không tồn tại | từ chối; UI còn chặn nút Stage khi chưa lưu revision (P1-46) |

### 3.4. Render native & G4/G5

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| B-50 ✅ | `video.render.native` không có `AIVIDEO_RENDER_ROOT` | `blocked_untrusted_render_root` |
| B-51 ✅ | Gửi `staging_root` / `allow_overwrite` | `STAGING_ROOT_FORBIDDEN` / `OVERWRITE_FORBIDDEN` (P1-15) |
| B-52 ✅ | Caption chứa `%{pts}` | burn nguyên văn (`expansion=none`) (P1-33) |
| B-53 ✅ | `beat_id` chứa `;` hoặc newline | `INVALID_BEAT_ID` / `UNSAFE_FILTERGRAPH_TOKEN` (P1-33) |
| B-54 ✅ | `plan.total_frames` khác độ dài render | `PLAN_FRAME_MISMATCH` (P1-31) |
| B-55 ✅ | Photo insert thiếu `photo_sha256` / `photo_publication_id` | `PHOTO_HASH_REQUIRED` / `PHOTO_PUBLICATION_REQUIRED` (P1-32) |
| B-56 ✅ | Photo insert có bytes khác hash đã khai | `PHOTO_BYTES_CHANGED` (P1-32) |
| B-57 ✅ | `g4.preview.technical_qc` với hash sai | FAIL |
| B-58 ✅ | Receipt native có `plan_sha256` khác plan đã duyệt | `G5S22Guard.verifyNativeReceipt` throw (P0-03) |
| B-59 ✅ | `.drp` chỉ là ZIP thường (không có `Project.db`) | `DRP_STRUCTURE_INVALID` (P1-23) |
| B-60 ✅ | `g5.fault.run_suite` trên DB canonical | tự báo `SELF_TEST_ONLY`, manifest ghi `certified=false` (P0-04) |

## PHẦN 4 — TẦNG C: ỨNG DỤNG macOS

### 4.1. Khởi động

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-01 🖐 | Mở app từ Finder | kết nối worker; không phụ thuộc PATH terminal |
| C-02 🖐 | Bấm "Kết nối lại" 2 lần thật nhanh | **chỉ** một worker được spawn (P1-48) |
| C-03 🖐 | Lần đầu mở app | trạng thái là "CSDL đã mở · chưa có thay đổi nào được lưu", **không** "Đã lưu" (P2-08) |
| C-04 🖐 | Chưa ghi gì, xem prompt model | ô prompt **rỗng** (không còn prompt demo) (P2-09) |

### 4.2. BƯỚC 1 — Tư liệu

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-10 🖐 | Chọn folder có video + ảnh | đếm đúng, inspector hiện thông số **của file đang chọn** (P1-52) |
| C-11 🖐 | Kéo nhanh qua nhiều file | inspector không hiện số của file trước |
| C-12 🖐 | Phân tích 1 video | coverage + review items ghi vào DB; đọc lại thấy |

### 4.3. BƯỚC 2 — Kịch bản & Thoại

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-20 🖐 | Lưu brief | trạng thái chuyển `saving → saved` và **chỉ** khi đã có revision |
| C-21 🖐 | Sửa brief khi đang gõ tiếng Việt (IME) | không mất ký tự; sync hoãn tới khi commit |
| C-22 🖐 | Sinh kịch bản rồi Stage cut khi **chưa** lưu revision | nút Stage bị vô hiệu (P1-46) |

### 4.4. BƯỚC 3 — Preview

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-30 🖐 | Render preview native | tiến trình có; nếu đang có lease heavy khác ⇒ báo "giải phóng lease" |
| C-31 🖐 | Mở editor phụ đề khi chưa có cue | **trống**, không có câu "Nội dung đã duyệt" (P1-53) |
| C-32 🖐 | Bấm Dừng khi đang phân tích batch 5 video | dừng trong ≤ 2 s, kể cả video đang chạy (P1-47) |

### 4.5. BƯỚC 4 — Final 4K

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-40 🖐 | Duyệt final khi chưa xem | bị chặn (cần `watchedVideoAndListenedToAudio`) |
| C-41 🖐 | Dùng nhánh native (không có `.drp`) | UI **không** nói ".drp đã niêm phong" (P1-50) |
| C-42 🖐 | Bấm "Làm video mới" sau khi đã duyệt | toàn bộ approval/cue/publication bị xoá (P1-51) |
| C-43 🖐 | Trường `mappingPublicationId` không có G2 mapping | để trống, **không** tự điền id G3/G4 (P1-54) |

### 4.6. Accessibility

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-80 🖐 | VoiceOver qua toolbar + hàng asset | mọi nút icon-only đọc được tên (P2-11) |
| C-81 🖐 | Tăng text size | không còn chữ < 11 pt để tràn/không đọc được |
| C-82 🖐 | Chỉ bàn phím | ⌘O, ⇧⌘O, ⇧⌘R, ⌘↩ hoạt động; focus ring rõ |

## PHẦN 5 — TẦNG D: BẢO VỆ CHỐNG TÁI PHÁT

Mỗi case đã có test thật trong repo. Cột "Test" là nơi nó sống — nếu ai xoá, đó là hồi quy.

| ID | Bảo vệ điều gì | Test |
|---|---|---|
| D-01 | Checkpoint không bịa được; resume cần provenance | `tests/test_g2_checkpoint_integrity.py` |
| D-02 | Audit coverage không tautology | `tests/test_g2_window_audit.py` |
| D-03 | Job chỉ SUCCEEDED khi đủ publication | `tests/test_p1_job_completion.swift` |
| D-04 | Governor reclaim lease khi worker chết | `tests/test_s07_scheduler_fencing.swift` |
| D-05 | Receipt ràng buộc plan/G3/G4/publication | `tests/test_g5_native_provenance.swift`, `tests/test_g5_receipt_binding.swift` |
| D-06 | Release manifest ký Ed25519 | `tests/test_p1_remaining.py::TestReleaseManifestIsSigned` |
| D-07 | Schema artifact khớp code | `tests/test_p1_harness_honesty.py::TestArtifactSchemaMatchesCode` |
| D-08 | Mọi suite Swift phát JSONL | `build/reports/swift_*_records.jsonl` (≥ 13 file) |
| D-09 | Banner đếm thật | `aivideoReportBanner` trong mọi suite Swift |
| D-10 | BLOCKED ⇒ exit 2 | `tests/test_resolve_spike.swift` |
| D-11 | LLM narration duyệt được khi có provenance | `tests/test_g3_llm_approval.swift` |
| D-12 | UI không tự khai "verified" | `tests/test_p1_remaining.py::test_mapping_publication_is_a_g2_mapping`, `test_p1_evidence_trust.py` |
| D-13 | Scope revision phải thật | `tests/test_g3_story_scope.swift` |
| D-14 | `package_review` chặn khi thiếu record | `tests/test_package_review_gate.py` |
| D-15 | Fault suite trung thực | `tests/test_g5_fault_suite_honesty.py` |
| D-16 | Escape filtergraph | `tests/test_p1_renderer_safety.py` |
| D-17 | Không có "verified" tự khai cho model | `tests/test_p1_evidence_trust.py::TestModelIdentityIsPinned` |
| D-18 | P2: bundle 1 worker, glob source, không handler im lặng, a11y, schema 1 nguồn | `tests/test_p2_debt.py` |
| D-19 | Không hash/ffprobe trong write transaction (S22, G4/S21, `commitPublication`) | `tests/test_p1_hashing_outside_transaction.swift` (5/5), `test_g4_approval.swift::S21.P1_02B` |
| D-20 | Transition phải đến từ plan đã duyệt | `tests/test_p31_transition_source.py` (4/4) |

## PHẦN 6 — KIỂM TRA BẰNG CHỨNG SAU MỖI LẦN CHẠY

### 6.1. Test

```bash
python3 - <<'PY'
import json
s = json.load(open('build/reports/python_test_summary.json'))
print(s['tests_run'], s['failures'], s['errors'], s['skipped'], s['successful'])
PY
ls build/reports/*.jsonl | wc -l                    # kỳ vọng ≥ 13
grep -L '"status": "PASS"' build/reports/*.jsonl    # phải rỗng (trừ record NOT_RUN có chủ đích)
```

### 6.2. Model

```bash
workers/.venv/bin/python3 tools/check_readiness.py | head -20
workers/.venv/bin/python3 - <<'PY'
from aivideo_workers.model_installation import inspect_model_installation
status = inspect_model_installation(deep=True)
print(status["state"], status.get("pinned_weights_sha256"))
PY
```

`state` phải là `verified` **và** `pinned_weights_sha256` khớp
`tools/setup_s11_model.py::S11_PINNED_WEIGHTS_SHA256`.

### 6.3. DB (chỉ đọc)

```bash
DB="$HOME/Library/Application Support/AIVideo"
find "$DB" -name "project_store.db" | head -1
sqlite3 -readonly "<db>" "PRAGMA user_version; PRAGMA journal_mode; SELECT COUNT(*) FROM artifact_publications WHERE state='COMMITTED';"
sqlite3 -readonly "<db>" "SELECT status, COUNT(*) FROM jobs GROUP BY status;"
```

`user_version` phải là `2` (canonical schema), `journal_mode` = `wal`. Không có job nào
`RUNNING` sau khi app thoát sạch.

### 6.4. Render

```bash
ffprobe -v error -count_frames -show_streams -show_format -of json <file.mp4> | \
  python3 -c "import json,sys; d=json.load(sys.stdin); v=[s for s in d['streams'] if s['codec_type']=='video'][0]; print(v['width'], v['height'], v['avg_frame_rate'], v.get('nb_read_frames'))"
```

Final: `2160 3840 24/1`; preview: `1080 1920 24/1`; số frame khớp `plan.total_frames`.

### 6.5. Tệp & bundle

```bash
find apps/macos/build/AIVideo.app -name "main.py" -path "*aivideo_workers*" | wc -l   # 1
du -sh apps/macos/build/AIVideo.app/Contents/Resources/Workers                          # ~736K
codesign --verify --deep --strict apps/macos/build/AIVideo.app && echo "signature ok (ad-hoc)"
```

## PHẦN 7 — MẪU GHI KẾT QUẢ

```
| ID | Trạng thái | Thời điểm | Bằng chứng | Ghi chú |
|----|-----------|-----------|------------|---------|
| A-PY-01 | PASS | 2026-11-11T09:57+07 | build/reports/python_test_summary.json: 424/0/0/4 | heavy: 0 skip |
| B-17 | PASS | … | record jsonl + offset | truncation đúng |
| C-32 | NOT_RUN | … | — | chưa thao tác tay |
```

## PHẦN 8 — THỨ TỰ ƯU TIÊN

1. `A-PF-01` (preflight) — biết ngay máy có đủ điều kiện không.
2. `A-PY-01`, `A-SW-01/02`, `A-ALL-01` — nền tảng.
3. `B-11…B-20` — đường phân tích (nơi từng có lỗi nặng nhất).
4. `B-30…B-38` → `B-50…B-60` — kịch bản/thoại rồi render.
5. `C-*` — chỉ sau khi B xanh; C cần người ngồi trước máy.
6. `D-*` — không chạy tay: chúng là test trong repo, chạy cùng ma trận.

## PHẦN 9 — ĐIỀU KHÔNG ĐƯỢC LÀM KHI KIỂM THỬ

- Không sửa DB bằng `sqlite3` ghi (chỉ `-readonly`): Swift core là writer duy nhất.
- Không export `AIVIDEO_CONTRACTS_DIR` / `AIVIDEO_MODELS_ROOT` để "cho qua" — đó là lỗi bị chặn.
- Không coi `fixtures/smoke` là bằng chứng chất lượng: nó là title card tổng hợp.
- Không dùng `git stash` trên file untracked (đã từng làm mất bản sửa).
- Không `rm -rf` đường dẫn "legacy" trong bundle: APFS không phân biệt hoa/thường.
- **Không chạy `./tools/build_macos_app.sh` song song với `./tools/run_tests.sh`.** Ma trận tự
  build app ở khối [4/5]; script build `rm -rf` bundle trước khi dựng lại, nên một lần build
  chen ngang sẽ làm codesign báo `apps/macos/build/AIVideo.app: No such file or directory`.
  Đã gặp thật một lần; chạy lại khi không có tiến trình khác là xanh.
