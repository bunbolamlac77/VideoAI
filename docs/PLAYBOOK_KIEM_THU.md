# PLAYBOOK KIỂM THỬ — AIVideo v3.1

**Mục đích:** Danh mục đầy đủ mọi **chức năng**, **đường đi**, **thao tác** và **lệnh** cần thực hiện để test dự án, kèm **kỳ vọng** và **cách phát hiện lỗi**.
**Đi kèm:** [AUDIT_20261111_REVIEW_AND_TEST_PLAN.md](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md) — mỗi mã `P0-xx`/`P1-xx` dưới đây trỏ về mục phát hiện tương ứng trong báo cáo.
**Môi trường đã đo trong phiên đánh giá:** macOS 26.7.1 (arm64), Swift 6.3.3, ffmpeg 7.1.1 (có `drawtext`), Python venv 3.12.11, model Qwen3-VL 4B + Qwen3-8B-4bit + Kokoro-Vietnamese đã cài tại `~/Library/Application Support/AIVideo/Models/`.

---

## PHẦN 0 — CÁCH DÙNG PLAYBOOK

1. Chạy **Tầng A** (static/unit) trước — nó là hàng rào rẻ nhất.
2. Mỗi case có: **ID · Mục tiêu · Thao tác/Lệnh · Kỳ vọng · Cách chứng minh lỗi**.
3. Kết quả ghi theo mẫu cuối tài liệu (PASS/FAIL/NOT_RUN/BLOCKED + bằng chứng).
4. **Luật vàng:** một case chỉ PASS khi *bạn đã cố tình làm hỏng* điều kiện của nó ít nhất một lần và thấy nó FAIL. Nếu không có cách nào làm nó FAIL, nó là test trang trí.

Ký hiệu: ✅ = có thể tự động hoá; 🖐 = cần thao tác tay trên app; 🕐 = chậm (>2 phút).

---

## PHẦN 1 — CHUẨN BỊ MÔI TRƯỜNG

### 1.1. Kiểm tra tiên quyết

| # | Thao tác | Kỳ vọng |
|---|---|---|
| E-01 | `sw_vers` | macOS ≥ 14 (máy tham chiếu: 26.7.1) |
| E-02 | `swiftc --version` và `ls /Library/Developer/CommandLineTools/SDKs/` | Swift 6.x + SDK **tương thích** (không dùng `xcrun --show-sdk-path` nếu trả `MacOSX27` — không build được, đã xác nhận trong phiên này) |
| E-03 | `ffmpeg -version \| head -1` và `ffmpeg -hide_banner -filters \| grep drawtext` | Có ít nhất 1 dòng `drawtext`. Thiếu ⇒ render caption phải báo `FFMPEG_DRAWTEXT_UNAVAILABLE`, không được crash |
| E-04 | `workers/.venv/bin/python3 -V` | 3.x ≤ 3.12 (venv hiện tại 3.12.11) |
| E-05 | `ls "$HOME/Library/Application Support/AIVideo/Models"` | Phải có `visual_analysis_primary`, `story_synthesis`, `tts_kokoro_vi`, `g0-text` |
| E-06 | `workers/.venv/bin/python3 -c "import mlx_vlm, mlx_whisper"`* | (*nếu dự kiến) ASR chưa có — kỳ vọng **FAIL import mlx_whisper** và đây là sự thật hiện trạng, không phải lỗi máy |
| E-07 | `sqlite3 --version`, `/opt/homebrew/bin/ffprobe` | Có |

### 1.2. Biến môi trường

| Biến | Ý nghĩa | Dùng ở đâu |
|---|---|---|
| `AIVIDEO_PYTHON` | Đường dẫn python cho app + harness Swift | `AppState`, `run_tests.sh`, CI |
| `AIVIDEO_APP_SUPPORT` | Gốc dữ liệu app | DB, models, runtimes |
| `AIVIDEO_RUN_HEAVY_G2=1` / `_STORY=1` / `_TTS=1` | Bật 4 test model thật (đang NOT_RUN) | `tests/test_s15*`, `test_s16_story_llm`, `test_s17_*` |
| `AIVIDEO_RUN_UI_TESTS=1` | Cho phép S02 launch app qua Finder | `test_s02_manual_verification.swift` |
| `AIVIDEO_RELEASE_TEAM_ID` | Team ID bắt buộc cho release | `tools/check_readiness.py` |
| `AIVIDEO_VLM_MAX_PIXELS` | Ngân sách pixel cho VLM (mặc định 589824) | `pipeline_adapters.py` |
| `AIVIDEO_G4_WORK_ROOT` / `AIVIDEO_G5_WORK_ROOT` / `AIVIDEO_RENDER_ROOT` | Root render (do Swift đặt) | `g4_resolve`, `g5_final`, `native_render` |
| `AIVIDEO_G3_STAGING_ROOT` | Root staging G3 | `g3_engine` |
| `AIVIDEO_G5_SIMULATE_FREE_BYTES` | **Hook test** — nên bị gỡ khỏi production (P1-17) | `g5_final.py` |

### 1.3. Bộ fixture cần chuẩn bị thủ công (chưa có trong repo)

| Fixture | Mục đích | Lệnh tạo |
|---|---|---|
| `spec-medium.mp4` 60 s 1080×1920, có nói | Đo end-to-end thật | `ffmpeg -f lavfi -i testsrc2=size=1080x1920:rate=24:duration=60 -f lavfi -i sine=frequency=440:duration=60 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac /tmp/spec-medium.mp4` |
| `spec-long.mp4` 10 phút | Kiểm payload > 1 MiB (P1-25) | như trên, `duration=600` |
| `vfr-no-nbframes.mkv` | Kiểm mẫu số coverage (P1-26) | `ffmpeg -f lavfi -i testsrc2=size=640x360:rate=30:duration=10 -c:v libx265 -x265-params vfr=1 /tmp/vfr.mkv` |
| `cup-cap3.mov` 4K30, 3 phút | Đo decode mỗi cửa sổ (P1-24) | `ffmpeg -f lavfi -i testsrc2=size=3840x2160:rate=30:duration=180 /tmp/spec-4k.mov` |
| `title có nháy.mp4` và thư mục `/tmp/aiv;b` | Kiểm escape filtergraph (P1-33 ảnh hưởng) | `cp /tmp/spec-medium.mp4 "/tmp/title có nháy.mp4"; mkdir -p "/tmp/aiv;b"` |
| Folder ảnh cưới 5–10 ảnh | Kiểm photo insert `illustrative_only` | dùng ảnh JPEG cá nhân bất kỳ |

---

## PHẦN 2 — TẦNG A: KIỂM THỬ TĨNH & UNIT (tự động hoá)

### 2.1. Bộ Python (279 case)

| ID | Mục tiêu | Lệnh | Kỳ vọng |
|---|---|---|---|
| A-PY-01 ✅ | Toàn bộ test Python | `workers/.venv/bin/python3 tools/run_python_tests.py` | `tests_run=279, failures=0, errors=0, skipped=4, exit 0` |
| A-PY-02 ✅ | Đếm JSONL khớp summary | `wc -l build/reports/python_test_records.jsonl` | 279 |
| A-PY-03 ✅ | 4 case model thật phải chạy | `AIVIDEO_RUN_HEAVY_G2=1 AIVIDEO_RUN_HEAVY_STORY=1 AIVIDEO_RUN_HEAVY_TTS=1 workers/.venv/bin/python3 tools/run_python_tests.py` | `skipped=0`; nếu FAIL ⇒ model thật chưa đáp ứng pipeline |
| A-PY-04 ✅ | Chạy từng file độc lập (không phụ thuộc PYTHONPATH) | `for t in tests/test_*.py; do workers/.venv/bin/python3 "$t" \|\| echo "FAIL $t"; done` | Không dòng `FAIL` |
| A-PY-05 ✅ | Test riêng từng gate | `workers/.venv/bin/python3 tests/test_g1_contracts.py`, `test_s10_media_indexer.py`, `test_s16_to_s19_g3.py`, `test_s20_native_render.py`, `test_s22_to_s26_g5.py` | Mỗi file exit 0 |

### 2.2. Bộ Swift (21 file, cần SDK đúng)

Biến `SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`. Mẫu chạy một suite:

```bash
swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift tests/test_g2_coverage_dto.swift \
  -o /tmp/t_g2dto && TEST_RECORDS_OUT=/tmp/t_g2dto.jsonl /tmp/t_g2dto
```

| ID | Suite | Nguồn Swift cần biên dịch | Điều phải kiểm |
|---|---|---|---|
| A-SW-01 ✅ | `test_worker_ipc` (S02) | DomainModels, WorkerClient | Banner phải in `passed/total` thật (P1-38) |
| A-SW-02 ✅ | `test_resolve_spike` (S03) | như trên | Nếu BLOCKED ⇒ **exit ≠ 0** (P1-40) |
| A-SW-03 ✅ | `test_g1_contracts` | DomainModels, DataContracts | 5 case |
| A-SW-04 ✅ | `test_s06_project_store` | DataContracts, G2AnalysisAndReviewEngine, ProjectStore | 6 case + ca `S06.BRIEF` |
| A-SW-05 ✅ | `test_s07_scheduler_fencing` | + ResourceGovernor | Governor brick (P1-03) |
| A-SW-06 ✅ | `test_s08_publication_reconciler` | + ArtifactPublisher | Reconciler + job sibling (P1-01) |
| A-SW-07 ✅ | `test_s09_backup_restore_migration` | + BackupRestoreService | Restore path (P1-06) |
| A-SW-08 ✅ | `test_s10_s11_g2_foundations` | MediaIndexer, SourceRevisionIdentity, ModelAdapterContracts | — |
| A-SW-09 ✅ | `test_source_revision_identity` | SourceRevisionIdentity | **Phải phát JSONL** (P1-39) |
| A-SW-10 ✅ | `test_g2_coverage_dto` | DomainModels | range expansion |
| A-SW-11 ✅ | `test_g3_story_request` | DataContracts, G3StoryRequest | scope id thật (P0-09) |
| A-SW-12 ✅ | `test_s12_to_s15_g2_closure` | + WorkerClient | 4 case |
| A-SW-13 ✅ | `test_s19_g3_approval` | + G3ProjectStore, G3ApprovalGuard, ArtifactPublisher | 3 case |
| A-SW-14 ✅ | `test_g3_approval_guard` | như trên | 2 case |
| A-SW-15 ✅ | `test_g4_approval` | + G4ProjectStore, G4S21Guard, G4FilePublisher | 4 case |
| A-SW-16 ✅ | `test_g5_final_and_release` | + G5ProjectStore, G5S22Guard | 6 case (cần ffmpeg) |
| A-SW-17 ✅ | `test_g5_native_provenance` | toàn bộ `packages/AIVideoCore/Sources/**/*.swift` | receipt native — phải phát JSONL (P1-39) |

### 2.3. Ma trận gộp + build

| ID | Lệnh | Kỳ vọng |
|---|---|---|
| A-ALL-01 🕐 ✅ | `./tools/run_tests.sh` | exit 0 **và** đọc lại log: không banner giả, không BLOCKED |
| A-ALL-02 ✅ | `./tools/build_macos_app.sh` | exit 0, `apps/macos/build/AIVideo.app` tồn tại |
| A-ALL-03 ✅ | `./tools/run_s06_tests.sh` | exit 0 (hoặc 2 = NOT_RUN khi thiếu SDK, **không phải PASS**) |
| A-ALL-04 ✅ | `codesign --verify --deep --strict apps/macos/build/AIVideo.app` | không lỗi |
| A-ALL-05 ✅ | `du -sh apps/macos/build/AIVideo.app/Contents/Resources/Workers/*` | Phát hiện 2 bản worker trùng (P2) |
| A-ALL-06 ✅ | `bash -n tools/*.sh` | không lỗi cú pháp |

### 2.4. Preflight & đóng gói

| ID | Lệnh | Kỳ vọng |
|---|---|---|
| A-PF-01 ✅ | `workers/.venv/bin/python3 tools/check_readiness.py; echo $?` | **exit 2** + blocker `UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS` |
| A-PF-02 ✅ | `AIVIDEO_RELEASE_TEAM_ID=ABCDE12345 workers/.venv/bin/python3 tools/check_readiness.py` | Phải **thất bại** vì app ký ad-hoc (kiểm P1-22) |
| A-PF-03 ✅ | `workers/.venv/bin/python3 tools/package_review.py /tmp/review.zip; echo $?` | Hiện tại luôn `0` — **fail case**: đổi 1 test sang FAIL rồi chạy lại phải trả ≠ 0 (P0-05) |
| A-PF-04 ✅ | Xoá `build/reports/swift_s12_s15_records.jsonl` → `package_review.py` | S12–S15 phải là NOT_RUN, **không** DONE (P0-05) |

---

## PHẦN 3 — TẦNG B: KIỂM THỬ ĐƯỜNG WORKER (JSON-RPC trực tiếp)

Mẫu gọi RPC (stdin JSON Lines, một dòng/một request):

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo
RPC() { printf '%s\n' "$1" | PYTHONPATH=workers/src workers/.venv/bin/python3 -m aivideo_workers.main_g2; }
```

### 3.1. Hệ thống & wire protocol

| ID | Request | Kỳ vọng |
|---|---|---|
| B-01 ✅ | `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` | `capabilities` liệt kê 32 method; policy rõ |
| B-02 ✅ | `system.ping` | `pong` cùng `id` |
| B-03 ✅ | JSON hỏng (thiếu `jsonrpc`) | trả `-32600 INVALID_REQUEST`, không crash |
| B-04 ✅ | Request > 1 MiB | `-32010` / `messageTooLarge`; worker **vẫn sống** với request kế tiếp |
| B-05 ✅ | Method không tồn tại | `-32601 METHOD_NOT_FOUND` |
| B-06 ✅ | In ra stderr bất kỳ (`print(..., file=sys.stderr)`) | Không làm hỏng stdout JSONL |

### 3.2. Media & phân tích G2

| ID | Request / thao tác | Kỳ vọng | Bắt lỗi |
|---|---|---|---|
| B-10 ✅ | `media.probe` với `fixtures/corpus/trip-holdout-01-dalat.mp4` | width 1080, height 1920, fps `24/1`, 36 frame | — |
| B-11 ✅ | `media.probe` với file không tồn tại / file rác | lỗi rõ ràng, không traceback | — |
| B-12 ✅ | `g2.analyze_source` với `_inspector_fn` | `INSPECTOR_OVERRIDE_FORBIDDEN` | — |
| B-13 ✅ | `g2.analyze_source` với `checkpoint_dir=/tmp/g2probe` rồi xem file checkpoint | **Kỳ vọng đúng: RPC phải TỪ CHỐI `checkpoint_dir`.** Hiện tại nó chấp nhận ⇒ **FAIL (P0-01)** | Đọc `checkpoint_dir` |
| B-14 ✅ | Tự viết `g2_ckpt_<rev>_<sha>.json` có `raw_observations` bịa, gọi lại với model bị chặn | **Phải trả `blocked_model_unavailable`, không được trả observation.** Hiện tại trả `completed` ⇒ **FAIL (P0-01)** | Resume path |
| B-15 🕐 ✅ | `g2.analyze_source` trên `/tmp/spec-medium.mp4` | `status=completed`; `window_coverage` phải < 1.0 nếu sample 2/16 (kỳ vọng mới); ledger ghi `denominator_source` | P0-02, P1-26 |
| B-16 ✅ | Như B-15 nhưng `vision_sample_count=2` và `=16` | Response phải echo `vision_sample_count`; coverage phải khác nhau đúng tỉ lệ | — |
| B-17 🕐 ✅ | `g2.analyze_source` trên `/tmp/spec-long.mp4` | Không được `RESULT_TOO_LARGE`; nếu có ⇒ **FAIL (P1-25)** | payload size |
| B-18 ✅ | Đo decode mỗi cửa sổ | `ffmpeg -benchmark -i clip -vf "select='eq(n,0)'" …` vs thêm `-frames:v 1`: thời gian phải ~1/30. Nếu chênh lớn ⇒ **P1-24** | |
| B-19 ✅ | `g2.analyze_source` trên `/tmp/vfr.mkv` (thiếu nb_frames/duration) | Ledger phải ghi `denominator_source=index_fallback` và **từ chối** chấm coverage (P1-26) | |
| B-20 ✅ | Clip không audio | `audio_branch_state` phải là `no_audio`; clip **có** audio chưa ASR phải là `audio_present_untranscribed`, **không** `no_speech` (P1-27) | |
| B-21 ✅ | `models_root_dir=/tmp/fake` tự tạo + manifest khớp size | **Phải từ chối** (P1-12) | |
| B-22 ✅ | `AIVIDEO_VLM_MAX_PIXELS=abc` | fail-closed ngay, không dùng default ngầm | |
| B-23 ✅ | Kill worker giữa chừng khi đang decode | Không còn tiến trình `ffmpeg` mồ côi: `pgrep -fl ffmpeg` | |

### 3.3. G3 — kịch bản, thoại, cut, đề xuất duyệt

| ID | Request | Kỳ vọng | Bắt lỗi |
|---|---|---|---|
| B-30 ✅ | `g3.story.generate` với `claims: []` | `blocked_no_eligible_claims` | — |
| B-31 ✅ | Claim `origin=visual_model` thiếu `evidence_sha256` | Vào `excluded` với lý do rõ | — |
| B-32 ✅ | Claim không có `review_status` | **Phải** bị loại hoặc `needs_review`; hiện có thể lọt (P2) | — |
| B-33 ✅ | `script_engine="llm"` với 3 claim thật | `script_engine` trả trong `candidates[].script_engine`; nếu fallback deterministic phải có cờ cảnh báo (P2) | P0-08 |
| B-34 ✅ | Text LLM có địa danh không có trong claim ("Đà Lạt", "buổi sáng") | **Phải** bị `faithfulness` chặn; hiện chỉ kiểm chữ số ⇒ **FAIL (P1-37)** | — |
| B-35 ✅ | `g3.voice.trial` khi `AIVIDEO_TTS_MODEL_DIR` trống | `blocked_tts_runtime_unavailable` | — |
| B-36 ✅ | `g3.voice.trial` khi **import** kokoro hỏng (`sys.modules['kokoro_vietnamese']=None`) | **Phải** `blocked_tts_runtime_unavailable`; hiện ⇒ `-32603` (P1-36) | — |
| B-37 ✅ | `g3.voice.phrases` 3 câu | `combined_wav` + offset theo sample thật; lệch tổng mẫu ⇒ ValueError | — |
| B-38 ✅ | `g3.cut.search` **không** truyền voice verification | `BLOCKED_VOICE_NOT_VERIFIED` | P0-07 |
| B-39 🕐 ✅ | `g3.cut.search` 8 beat × 64 option, `beam_width=8`, `node_budget=5000`, `forward_check=true` | Wall-clock phải **tỉ lệ** với `node_budget`; chênh nhiều bậc ⇒ P1-35 | |
| B-40 ✅ | `g3.cut.search` (`shot_id` hỗn hợp int/str) | Phải trả lỗi nghiệp vụ, không `-32603` (P2) | |
| B-41 ✅ | `g3.cut.stage` với `script_revision_id="rev-01"` không tồn tại | Phải `blocked_*` rõ (UI không được gửi — P1-46) | |
| B-42 ✅ | `g3.approval.propose` thiếu `cut_publication_id` | `blocked_cut_not_published_by_core` | — |
| B-43 ✅ | `g3.approval.propose` với manifest đúng | `ready_for_core_reverification_not_approved` + `manifest_sha256` 64 hex | — |
| B-44 ✅ | `g3.metrics.script_ready` | Phải trả `DESCRIPTIVE_PASS_NOT_GATE_EVIDENCE` khi không có nhãn người | — |

### 3.4. Render native & G4/G5

| ID | Request | Kỳ vọng | Bắt lỗi |
|---|---|---|---|
| B-50 ✅ | `video.render.native` 1 beat 48 frame | MP4 1080×1920, `nb_read_frames=48`, có `.srt` | — |
| B-51 ✅ | Caption chứa `Anh nói: "Đừng 'thử' \\ ; %{pts}"` | Burn đúng nguyên văn, `%{pts}` **không** bị expand (P1-33) | |
| B-52 ✅ | `beat_id="x;nullsrc"` hoặc staging root `/tmp/aiv;b` | Phải bị từ chối trước khi gọi ffmpeg (P1-33) | |
| B-53 ✅ | `g4.render.native` với `allow_overwrite=true` | **Phải bị từ chối** (P1-15) | |
| B-54 ✅ | `g4.render.native` với `staging_root=/tmp/evil` | **Phải bị từ chối** nếu ngoài managed root (P1-15) | |
| B-55 ✅ | `g4.render.native` có crossfade | Receipt `total_frames` phải bằng `plan.total_frames` sau khi cộng overlap; nếu lệch ⇒ guard G4 chặn (P1-31) | |
| B-56 ✅ | Photo insert ngoài root | `blocked` (đã có test) | — |
| B-57 ✅ | `g4.preview.technical_qc` với hash sai | FAIL | — |
| B-58 ✅ | `g5.render.native_4k` với `AIVIDEO_G5_SIMULATE_FREE_BYTES=999` | **Phải bị bỏ qua trong production** (P1-17) | |
| B-59 ✅ | `g5.fault.run_suite` khi worker chạy ở thư mục không có DB | Phải **không** PASS khi môi trường thật không tồn tại (P0-04) | |
| B-60 ✅ | `g5.release.manifest` rồi sửa `version` trong output rồi tính lại hash | Phải phát hiện chữ ký sai; hiện chưa ký (P1-18) | |
| B-61 ✅ | `g5.eval.e0_e1_accounting` với `runs` bịa + manifest thật đã ký | **Không được** `CERTIFIED` (P1-19) | |
| B-62 ✅ | `g5.preferences.manage` với `profile_path=/tmp/footprint.json` | **Phải bị chặn** (P1-16) | |
| B-63 ✅ | `g5.capability.evaluate` với `registry_path` | Bị chặn (đã có test) | — |

---

## PHẦN 4 — TẦNG C: KIỂM THỬ ỨNG DỤNG macOS (thao tác tay)

Khởi động: mở `apps/macos/build/AIVideo.app` (hoặc bản đã cài `/Applications/AIVideo.app`).

### 4.1. Khởi động & worker

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-01 🖐 | Mở app | Sidebar 4 bước chính + nhóm "Nâng cao & Chẩn đoán" thu gọn; status bar "Worker sẵn sàng" |
| C-02 🖐 | ⇧⌘R (Worker ▸ Khởi động lại) bấm **2 lần liên tiếp cực nhanh** | Chỉ 1 worker mới; `pgrep -fl aivideo_workers` ra đúng 1 PID (P1-48) |
| C-03 🖐 | Tạm đổi tên `workers/.venv` → mở app | Banner nêu **rõ** thiếu Python + nút "Kết nối lại worker"; không vòng quay vô hạn |
| C-04 🖐 | Menu Worker ▸ "Kiểm tra lại model", "Làm mới DaVinci Resolve" | Cập nhật trạng thái; không treo UI |

### 4.2. BƯỚC 1 — Tư liệu nguồn

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-10 🖐 | ⌘O chọn thư mục có 2 video + 1 ảnh | Pill "2 video / 1 ảnh"; danh sách có segmented filter + ô tìm kiếm |
| C-11 🖐 | ⇧⌘O chọn 1 file lẻ | Chỉ file đó vào danh sách; inspector hiện thông số |
| C-12 🖐 | Chọn video A rồi **đổi ngay** sang video B, quan sát 1 giây đầu | Thông số phải là "Đang probe…", **không** hiện duration của A (P1-52) |
| C-13 🖐 | "Thông tin cho người viết kịch bản": để trống → "Lưu dữ kiện" | Nút disabled |
| C-14 🖐 | Nhập cặp đôi + loại lễ + "cảnh bắt buộc" → chờ 0,9 s | Trạng thái "Đã lưu · rev…"; thoát app, mở lại → form khôi phục |
| C-15 🖐 | Chọn **ảnh** trong danh sách | Inspector hiện preview ảnh + kích thước; nút "Phân tích video này" disabled |
| C-16 🖐 | Bấm "Phân tích video này" khi chưa chọn video | Bị chặn hoặc báo lỗi rõ |
| C-17 🖐 | "Phân tích toàn bộ (N video)" với 2 video | Chạy tuần tự, hiện "video thứ k/N + tên" |
| C-18 🖐 | Double-click "Phân tích toàn bộ" | Không có 2 batch song song |
| C-19 🖐 | Trong batch 5 video, bấm "Dừng" ở video 3 | Phải dừng **trong ≤ 2 s**; hiện chạy hết video 3 ⇒ **FAIL (P1-47)** |
| C-20 🖐 | Sau khi phân tích xong | Tab "Kiểm chứng G2": coverage %, số observation, claim, review |
| C-21 🖐 | Kéo cửa sổ nhỏ lại 800×600 | Không tràn/cắt nút; inspector cuộn được |
| C-22 🖐 | Chuyển Light/Dark Mode | Màu theo semantic color; teal `#0F766E` / `#5EEAD4` |

### 4.3. BƯỚC 2 — Kịch bản & Thoại

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-30 🖐 | Chưa có claim nào → "Tạo kịch bản từ Claim đã kiểm chứng" | **Disabled** (hiện có thể bật — P2) |
| C-31 🖐 | Xác nhận 1 fact ở màn "Dữ liệu & Backup" → quay lại Bước 2 | Claim hiện trong picker |
| C-32 🖐 | Chọn claim → "Tạo kịch bản…" | Candidate JSON hiện; nếu `script_engine` fallback phải có cảnh báo |
| C-33 🖐 | Bấm "Tìm Cut hợp lệ (SEARCH-v1)" **trước khi** nghe WAV | Hiện tại gửi `voice_review_status="verified"` ⇒ **FAIL (P0-07)**; đúng ra phải bị chặn |
| C-34 🖐 | "Tạo WAV 48 kHz" | WAV thật; SHA-256 tự điền; nghe được trong Finder |
| C-35 🖐 | "Ghi nhận Speech Review vào SQLite" | `g3_voice_reviews` có dòng mới (xem §6.3) |
| C-36 🖐 | "Stage Cut Plan để S08 Publish" **trước khi lưu revision** | **Phải disabled**; hiện gửi `rev-01` (P1-46) |
| C-37 🖐 | "Kiểm tra Manifest đề nghị duyệt" | Manifest + `ready_for_core_reverification_not_approved`; hiển thị `scope revision` thật, **không** `scope-g2-main` (P0-09) |
| C-38 🖐 | Sửa 1 câu → "Sửa câu & tạo revision" → "Lưu revision bất biến vào SQLite" → "Duyệt kịch bản (S19 Guard)" | Phải duyệt được khi narration hợp lệ |
| C-39 🖐 | **Đường quan trọng**: dùng LLM (`script_engine=llm`) rồi duyệt | Hiện bị chặn "Narration differs from validated claim" ⇒ **FAIL (P0-08)**; đây là đường mặc định |
| C-40 🖐 | Chỉnh narration ở bước duyệt để khớp claim | Phải duyệt được (kiểm fail-closed đúng chỗ) |
| C-41 🖐 | Duyệt xong, sang Bước 3 | Cue phải là câu thoại thật, **không** "Nội dung đã duyệt" (P1-53) |

### 4.4. BƯỚC 3 — Preview

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-50 🖐 | "Thêm Cue" (sửa text, thời điểm) | Danh sách cue cập nhật |
| C-51 🖐 | "Stage + S08 Publish Beat này" với mỗi beat | Asset JSON xuất hiện; `artifact_publications` có `g4_*` COMMITTED |
| C-52 🖐 | "S08 Publish Preview MP4" trước khi render | Disabled |
| C-53 🖐 | "Dựng & render tự động" (native 1080p) | MP4 1080×1920 @24, có `.srt`, receipt JSON cạnh file |
| C-54 🖐 | **Đồng thời**: đang chạy "Phân tích toàn bộ" ở Bước 1, sang Bước 3 bấm render native | **Phải bị chặn bởi governor**; hiện không xin lease ⇒ **FAIL (P1-11)** |
| C-55 🖐 | Phát preview trong app | Đúng nội dung, phụ đề burn đúng thời điểm (sai ⇒ P1-49) |
| C-56 🖐 | "S21: Phê duyệt Preview" với notes < 12 ký tự | Disabled |
| C-57 🖐 | Phê duyệt hợp lệ | `g4_preview_approvals` có dòng; Bước 4 mở khoá |

### 4.5. BƯỚC 4 — Final 4K

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-60 🖐 | Chưa duyệt G3/G4 gì → bấm Stage/Download 4K | **Phải chặn** (P2) |
| C-61 🖐 | "Dựng & render 4K" | MP4 2160×3840 @24, receipt `native-render-receipt-v1`; đo bằng `ffprobe` ở §6.4 |
| C-62 🖐 | Sau khi xong, đọc card thành công | Nhãn phải khớp nhánh: nhánh native ghi **receipt**, không ghi ".drp đã niêm phong" (P1-50) |
| C-63 🖐 | "Mở trong DaVinci Resolve" ở nhánh native | Phải đổi tên nút thành "Mở receipt"; hiện mở file JSON (P1-50) |
| C-64 🖐 | "S22: Phê duyệt Final 4K" | Ghi `g5_final_approvals`; sửa file MP4 sau đó thì duyệt lại phải fail |
| C-65 🖐 | "Làm video mới (Về Bước 1)" | Phải reset toàn bộ trạng thái đã duyệt (P1-51) — hiện giữ nguyên |
| C-66 🖐 | Chạy quy trình lần 2 với video thứ hai trong cùng ngày | Không được kế thừa "đã duyệt" của video 1 |

### 4.6. Màn hình chẩn đoán

| ID | Màn | Thao tác | Kỳ vọng |
|---|---|---|---|
| C-70 🖐 | Kiểm chứng G2 | mở | Coverage, claim, review item đồng bộ với DB |
| C-71 🖐 | Dữ liệu & Backup | "Tạo bản sao lưu" | Bundle + manifest; restore thử vào thư mục mới rồi mở artifact (kiểm P1-06) |
| C-72 🖐 | Model local | "Kiểm tra" | Model ID + verification; không báo "verified" khi weights bị sửa (P1-12) |
| C-73 🖐 | DaVinci Resolve | mở khi Resolve đóng | Trạng thái "không kết nối", không treo, không báo Mã lỗi nội bộ |
| C-74 🖐 | Năng lực hệ thống | mở | Đọc từ `initialize`, không hard-code |
| C-75 🖐 | G5 ▸ "S25: Tiêm lỗi" | bấm | Hiện kết quả; nhãn phải là self-test, không phải bằng chứng release (P0-04) |

### 4.7. Accessibility

| ID | Thao tác | Kỳ vọng |
|---|---|---|
| C-80 🖐 | Bật VoiceOver, Tab qua toolbar + các hàng asset | Mọi nút icon-only đọc được tên (P2) |
| C-81 🖐 | Tăng text size hệ thống | Chữ log G3/G4 phải giãn theo (hiện fix 9–11 pt) |
| C-82 🖐 | Chỉ dùng bàn phím | ⌘O, ⇧⌘O, ⇧⌘R, ⌘↩ hoạt động; focus ring hiện rõ |

---

## PHẦN 5 — TẦNG D: KIỂM THỬ HỒI QUY & BẢO MẬT (viết test mới, chạy được)

Mỗi case dưới đây là một test **phải viết** vì hiện chưa có. Chúng được thiết kế để *đỏ trên cây hiện tại* và *xanh sau khi sửa*.

| ID | Mục tiêu | Cách viết | Kỳ vọng hiện tại |
|---|---|---|---|
| D-01 | Checkpoint không bịa được | `tests/test_g2_checkpoint_integrity.py`: gọi `handle_g2_analyze_source` với `checkpoint_dir` ⇒ assert raise/`INVALID_PARAMS`; gọi lại không có inspector ⇒ `blocked_model_unavailable` | **FAIL** (P0-01) |
| D-02 | Audit không tautology | `tests/test_g2_window_audit.py`: inspector trả 1/16 frame ⇒ `window_coverage == 1/16`, `truncation_detected == False`, và đổi thành trả 0 frame ⇒ raise | **FAIL** (P0-02) |
| D-03 | Job SUCCEEDED chỉ khi đủ artifact | Mở rộng `test_s08_publication_reconciler.swift`: 2 publication, commit 1 ⇒ `job.status == running` | **FAIL** (P1-01) |
| D-04 | Lease reclaim | Mở rộng `test_s07_scheduler_fencing.swift`: acquire(pid) → release(confirmedDead:false) → acquire lần 2 phải `granted` (sau TTL) | **FAIL** (P1-03) |
| D-05 | Receipt ràng buộc plan | `test_g5_native_provenance.swift`: receipt với `plan_sha256` khác plan ⇒ `verifyFinalProvenance` throw | **FAIL** (P0-03) |
| D-06 | Release manifest có chữ ký | Thay 1 byte manifest ⇒ verify fail | **FAIL** (P1-18) |
| D-07 | Schema artifact khớp code | `tests/test_artifact_schema_matches_db.py`: mọi `artifact_type` ghi bởi code+test phải nằm trong enum schema | **FAIL** (P1-42) |
| D-08 | Mọi suite Swift phát JSONL | Thêm `TEST_RECORDS_OUT` cho 5 suite còn thiếu và assert số record > 0 | **FAIL** (P1-39) |
| D-09 | Banner đếm thật | Sửa 1 assertion thành no-op ⇒ banner phải báo `5/6` và exit ≠ 0 | **FAIL** (P1-38) |
| D-10 | BLOCKED ⇒ exit ≠ 0 | `test_resolve_spike` khi Resolve đóng | **FAIL** (P1-40) |
| D-11 | LLM narration duyệt được | `test_g3_llm_rewrite_to_approval.swift` (hoặc Python E2E) | **FAIL** (P0-08) |
| D-12 | UI không tự khai verified | Test Swift parse `buildAndSendCutSearch` payload ⇒ không chứa `"verified"` hằng số | **FAIL** (P0-07) |
| D-13 | Scope revision thật | `test_g3_story_request`: `scopeRevisionId` rỗng/không tồn tại ⇒ throw | **FAIL** (P0-09) |
| D-14 | `package_review` chặn | Xoá 1 record ⇒ DONE biến NOT_RUN, exit ≠ 0 | **FAIL** (P0-05) |
| D-15 | Fault suite trung thực | `g5.fault.run_suite` với DB thật hỏng ⇒ không PASS | **FAIL** (P0-04) |
| D-16 | Escape filtergraph | Caption `%{pts}` burn nguyên văn; `beat_id` có `;` bị từ chối | **FAIL nếu chưa fix** (P1-33) |

---

## PHẦN 6 — KIỂM TRA BẰNG CHỨNG (sau mỗi lần chạy)

### 6.1. Bằng chứng test

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo
python3 - <<'PY'
import json
s=json.load(open('build/reports/python_test_summary.json'))
print(s['tests_run'], s['failures'], s['errors'], s['skipped'], s['successful'])
PY
ls build/reports/*.jsonl | wc -l            # kỳ vọng ≥ 13 (thêm 5 nếu D-08 xong)
grep -L '"status": "PASS"' build/reports/*.jsonl   # phải rỗng sau khi D-08 xong
```

### 6.2. Bằng chứng model

```bash
workers/.venv/bin/python3 tools/check_readiness.py; echo "exit=$?"
shasum -a 256 "$HOME/Library/Application Support/AIVideo/Models/visual_analysis_primary/model.safetensors"
# so với pin trong tools/setup_s11_model.py
```

### 6.3. Bằng chứng DB (chỉ đọc!)

> Theo bất biến của dự án: **không bao giờ ghi DB từ sqlite3 hay Python**. Chỉ dùng `-readonly`.

```bash
DB="$HOME/Library/Application Support/AIVideo/Projects/DefaultG1Project/project_store.db"   # nguồn: AppState.swift:885
sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"   # đã đo trong phiên đánh giá: user_version=0, 23 bảng (P1-10)
sqlite3 -readonly "$DB" "SELECT state, COUNT(*) FROM artifact_publications GROUP BY state;"
sqlite3 -readonly "$DB" "SELECT status, COUNT(*) FROM jobs GROUP BY status;"
sqlite3 -readonly "$DB" "SELECT * FROM g3_voice_reviews ORDER BY rowid DESC LIMIT 3;"
sqlite3 -readonly "$DB" "SELECT * FROM g3_approvals; SELECT * FROM g4_preview_approvals; SELECT * FROM g5_final_approvals;"
sqlite3 -readonly "$DB" "SELECT canonical_path FROM artifact_publications WHERE state='COMMITTED' LIMIT 5;"   # kiểm path còn tồn tại
```

### 6.4. Bằng chứng render

```bash
OUT=/path/to/final.mp4   # MP4 do app render, xem output trên màn Final 4K
ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,width,height,avg_frame_rate,pix_fmt,color_primaries,color_transfer \
  -of json "$OUT" | python3 -c "import json,sys;d=json.load(sys.stdin)['streams'][0];print(d)"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"
ffmpeg -hide_banner -nostdin -i "$OUT" -vn -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
shasum -a 256 "$OUT"; cat "${OUT%.mp4}.receipt.json" | python3 -m json.tool | head -30
```
Kỳ vọng: `width=2160, height=3840, avg_frame_rate=24/1`, `nb_read_frames` = Σ frames − Σ overlap (khớp receipt), `|duration − frames/24| ≤ 1/24 + 0.03`, `max_volume < -0.01 dB`, `output.sha256` trong receipt = `shasum` thật.

### 6.5. Bằng chứng file system

```bash
ls -la "$HOME/Library/Application Support/AIVideo/Renders"       # MP4 + .srt + receipt
find ~/Library/Application\ Support/AIVideo/Renders -name "*.receipt.json" | head
pgrep -fl aivideo_workers        # 1 PID khi app mở
pgrep -fl ffmpeg                 # 0 khi app không render
```

---

## PHẦN 7 — MẪU GHI KẾT QUẢ

| ID | Mô tả | Trạng thái | Bằng chứng (lệnh + output/log/screenshot) | Ghi chú |
|---|---|---|---|---|
| A-PY-01 | Python suite | PASS | `tests_run=279 …` (`python_test_summary.json`) | 4 NOT_RUN = 4 test model thật |
| C-19 | Dừng batch | FAIL | video 3 chạy hết 5 phút sau khi bấm Dừng | P1-47 |
| B-13 | `checkpoint_dir` qua RPC | FAIL | RPC chấp nhận, ghi `/tmp/g2probe/g2_ckpt_*.json` | P0-01 |

**Trạng thái hợp lệ:** `PASS` · `FAIL` · `BLOCKED` (thiếu môi trường) · `NOT_RUN` (không chạy, phải ghi lý do).
**Không dùng** `PASS` cho case chưa từng thấy nó FAIL.

---

## PHẦN 8 — THỨ TỰ ƯU TIÊN (chạy cái gì trước)

| Đợt | Case | Thời gian | Mục đích |
|---|---|---|---|
| 1 | A-PY-01, A-PY-02, A-SW-01..17, A-ALL-02, A-PF-01 | ~5 phút | Chốt hiện trạng tĩnh |
| 2 | B-13, B-14, D-01, D-02 | ~30 phút | Chứng minh "bịa" còn/không |
| 3 | C-30..C-41 | ~1–2 giờ | Toàn bộ Bước 2 (chỗ gãy nặng nhất: P0-08) |
| 4 | C-10..C-20 | ~1 giờ | Bước 1 (batch, brief, dừng) |
| 5 | C-50..C-66 + §6.4 | ~2 giờ | Render & duyệt 3/4 |
| 6 | A-PF-03, A-PF-04, B-59, B-60, B-61 | ~1 giờ | Chuỗi release |
| 7 | C-80..C-82, B-51, B-52 | ~1 giờ | Accessibility & an toàn render |
