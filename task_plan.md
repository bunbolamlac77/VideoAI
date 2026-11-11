# Task Plan: AIVideo v3.1 — triển khai & nghiệm thu

## Goal (cập nhật 2026-11-11)

Đưa dự án từ "đã chạy được" tới "chứng nhận được", và không tuyên bố gì vượt quá bằng chứng:

1. Đóng **9 P0 + 54 P1 + 14 nhóm P2** của kiểm toán 2026-11-11, mỗi lỗi có test hồi quy.
2. Giữ đúng bất biến: single-writer SQLite, một nguồn schema (Swift), mọi kết luận có
   `sha256` + timecode, 100% local.
3. Chỉ đóng Gate G2 và S25 khi có **footage thật + nhãn người** và **fault run thật**; trước đó
   ghi 🟡 IN_REVIEW dù mã đã xong.
4. Bằng chứng phải tái lập được bằng lệnh, không phải bằng lời kể.

Trạng thái bằng chứng gần nhất: Python **428 run · 0 FAIL · 0 ERROR · 4 NOT_RUN**
(heavy: 0 skip); `./tools/run_tests.sh` **exit 0, 23 khối**; `build_macos_app.sh`
**BUILD SUCCESSFUL**; `check_readiness.py` **exit 2 / NO-GO** (đúng).

## Gate Status Summary

- **G0 (S00–S03)**: 🟢 DONE — app bundle arm64, worker stdio, bookmark/security-scope, Resolve spike.
- **G1 (S04–S09)**: 🟢 DONE — `ProjectStore` single-writer WAL, snapshot, governor, publication 4 pha,
  backup/restore, migration tại chỗ (`user_version = 2`).
- **G2 (S10–S15)**: 🟡 IN_REVIEW — media indexer CFR 24/1, Rec.709, Qwen3-VL 4B và pipeline cửa sổ
  chạy thật. **Chưa có benchmark hiện trường**: `fixtures/smoke/` là 5 title card 1,5 s
  (1080×1920, 36 frame), nhãn do agent, 0 claim/0 event. Preflight NO-GO tới khi có signed field corpus.
- **G3 (S16–S19)**: 🟢 DONE — story ràng buộc nguồn, Kokoro-Vietnamese TTS + cổng nghe WAV,
  `SEARCH-v1` (node budget tính cả lookahead), `G3ApprovalGuard` + scope revalidation.
- **G4 (S20–S21)**: 🟢 DONE — preview 1080×1920 (native ffmpeg hoặc Resolve), QC tự động,
  `G4S21Guard`.
- **G5 (S22–S26)**: 🟡 IN_REVIEW — guard S22 có test; `g5.fault.run_suite` tự báo `SELF_TEST_ONLY`;
  release manifest ký **Ed25519**, `s25_fault_evidence.certified = false` cho tới khi có real fault run.

## Việc còn mở (không giấu)

| Việc | Điều kiện đóng | Ghi chú |
|---|---|---|
| Chứng nhận G2 | footage Rec.709 thật + nhãn người + manifest ký + `runs_sha256` khớp | `tools/check_readiness.py` sẽ GO khi xong |
| Fault run S25 | chạy thật trên DB canonical | evidence tự khai bị từ chối (`validate_real_fault_suite_evidence`) |
| ~~P1-02 nhánh G4 + `commitPublication`~~ | ✅ đã áp dụng: `verifyS21Evidence`/`readApprovedInputs` + băm trước transaction | `test_p1_hashing_outside_transaction.swift` 5/5, `S21.P1_02B` |
| ~~P1-31 transition so với plan~~ | ✅ đã áp dụng: transition phải khớp `plan.transitions` | `tests/test_p31_transition_source.py` 4/4 |

## Nhật ký công việc


## Milestones & Checklist
- [x] **P0 - RPC Capability Override Guard**: Tạo [`g5_release_guards.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/workers/src/aivideo_workers/g5_release_guards.py) và khóa RPC endpoint `g5.capability.evaluate` / `g5.photo.match`.
- [x] **P0 - Real Local Qwen3-VL 4B VLM Inference**: Nạp model offline 2.88 GB qua `mlx_vlm`, chạy suy luận trực tiếp trên GPU Metal, trả nhãn quan sát tiếng Việt trung thực.
- [x] **P0 - Honest Frame Provenance in VLM Inspector**: Sửa `pipeline_adapters.py` chỉ ghi nhận đúng frame thực tế được đưa vào model (`[midpoint_fid]`), kích hoạt `has_uncertainty_boundary = True`, không gian lận 16 frame, ném `PipelineAdapterError("INVALID_VLM_OUTPUT")` khi model trả rỗng thay vì bịa đặt fallback text.
- [x] **P0 - Cryptographic Manifest & Ed25519 QA Verification**: Khóa hàm `validate_signed_field_manifest` với Ed25519 độc lập, đối chiếu hash SHA-256 từng file video trong corpus, loại bỏ quyền cấp chứng nhận release bằng khóa HMAC công khai.
- [x] **P0 - Release RPC Override Lockdown**: Cấm tham số `registry_path` và `app_binary_path` trong RPC `g5.release.manifest`, ném `ValueError` tương ứng.
- [x] **P1 - Dependencies Lockfile**: Bổ sung `mlx-vlm>=0.7.10` và `cryptography>=42.0.0` vào `workers/pyproject.toml`, cập nhật lockfile `workers/uv.lock` qua `uv add`.
- [x] **P1 - UI macOS & Spotlight**: Refactor UI sang giao diện NavigationSplitView chuẩn macOS Calm Editor, bộ màu nhận diện Brand Teal `#0F766E` / `#5EEAD4`, icon vector macOS squircle, đóng gói app bundle đăng ký Spotlight tự động.
- [x] **Adversarial Audit Hardening Suite**: Thêm [`tests/test_audit_hardening.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tests/test_audit_hardening.py) (4/4 PASS đối kháng).
- [x] **Full Regression Matrix**: 134/134 Python Unit/Regression Tests PASS · 21/21 AutoBridge Tests PASS · Swift Native Tests PASS · Build & Codesign PASS.
- [x] **Honest Release Preflight**: [`tools/check_readiness.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/check_readiness.py) báo cáo trạng thái chuẩn xác, bảo đảm tính fail-closed (NO-GO khi thiếu signed field corpus với khóa Ed25519).
- [x] **Media Directory Workspace (Multi-Video & Attached Photos)**: 
  - Hỗ trợ chọn nguyên thư mục chứa nhiều video và ảnh đính kèm (tuỳ biến có/không).
  - Tự động đệ quy/quét file theo định dạng chuẩn (Video: mp4, mov, m4v, mkv, avi, webm; Ảnh: jpg, jpeg, png, heic, heif, webp, tiff, bmp).
  - Security-Scoped Bookmark bền vững trên thư mục gốc cho phép truy cập toàn bộ file con trong sandbox macOS.
  - UI Calm Editor phân chia rõ rệt: Thẻ thư mục với video/image count & dung lượng, segmented filter (Tất cả / Video / Ảnh), ô tìm kiếm nhanh, danh sách scrollable có highlight & context menu, và inspector panel hiển thị thông số ffprobe + nút "Chạy phân tích G2 trên video này" (khi chọn video) hoặc khung xem ảnh native `LocalImagePreview` kèm thông tin kích thước và ghi chú bối cảnh (khi chọn ảnh).
  - Tích hợp phím tắt `⌘O` (Mở thư mục) và `⇧⌘O` (Mở file riêng lẻ), đăng ký Spotlight `/Applications/AIVideo.app`.
- [x] **Batch G2 Sequential Video Analysis (Phân Tích Toàn Bộ Video)**:
  - Giải quyết bài toán phân tích hàng loạt video trong thư mục mà không làm tràn bộ nhớ 16 GB Unified RAM của Apple Silicon M1 Pro.
  - Xử lý hàng đợi tuần tự (Sequential Queue): Tự động duyệt qua từng video, suy luận VLM Qwen3-VL 4B local, trích xuất quan sát, lập Coverage Ledger và đối chiếu claim vào SQLite canonical qua `ProjectStore`.
  - Cập nhật live giao diện: Thẻ thư mục (`folderBannerCard`), Inspector (`MediaInspectorView`) và Tab Kiểm chứng G2 (`G2VerificationSectionView`) với nút "Phân tích toàn bộ (N video)", hiển thị tiến trình đang chạy (video thứ k/N + tên video), và nút "Dừng" an toàn.
- [x] **Round 2 Audit Hardening Remediation**:
  - [x] P0: Bắt buộc Ed25519 cho chứng nhận nghiệm thu thực địa, loại bỏ hoàn toàn việc công nhận chữ ký HMAC công khai.
  - [x] P0: Bổ sung định danh video nguồn bằng băm SHA-256 nội dung file thực tế (`SourceRevisionIdentity.swift`), xử lý ngoài MainActor và đối chiếu với worker.
  - [x] P1: Bổ sung script kiểm thử độc lập S06 ProjectStore (`tools/run_s06_tests.sh`) với dò tìm SDK tương thích.
  - [x] P1: Bổ sung kiểm tra Apple Team ID cho các bản release chính thức trong preflight.
  - [x] Nghiệm thu: 156 Python regression PASS, 21 Autobridge PASS, 15 Swift suite PASS, build & codesign PASS.
- [x] **Round 3 Senior Developer Rigorous Audit & Full Stability Hardening**:
  - [x] Khắc phục triệt để lỗi thực thi test cô lập: 23/23 file test Python chạy standalone đạt 100% PASS mà không phụ thuộc `PYTHONPATH`.
  - [x] Tạo `tests/conftest.py` và chuẩn hóa lệnh kiểm thử trong `GEMINI.md`.
  - [x] Sửa lỗi khôi phục trạng thái Security-Scoped Bookmark file đơn lẻ trong `AppState.restoreSavedBookmark()`.
  - [x] Tích hợp `ResourceGovernor.shared.acquireHeavyLease` cho G2 Analysis và Resolve Spike (bảo vệ Invariant 4).
  - [x] Khóa trạng thái nút bấm phân tích video khi đang chạy tác vụ nặng (loại bỏ nguy cơ gọi VLM đồng thời).
  - [x] Chuyển đổi `LocalImagePreview` sang giải mã bất đồng bộ, loại bỏ hoàn toàn giật lag Main Thread.
  - [x] Bổ sung khối `defer` trong `runResolveSpike()` và hoàn thiện hành vi mở thư mục trong Finder.
  - [x] Nghiệm thu toàn diện: 23/23 Standalone PASS · 156/156 Python Structured PASS · 15/15 Swift Suites PASS · Build & Codesign PASS.
- [x] **Calm Editor UI Redesign (Quy Trình 4 Bước Tuyến Tính & Auto-Wiring)**:
  - [x] Tinh gọn Sidebar thành 2 nhóm rõ rệt: "Quy trình dựng (POV Workflow)" (4 bước chính: 1. Tư liệu nguồn → 2. Kịch bản & Thoại → 3. Xem trước Preview → 4. Xuất bản Final 4K) và nhóm phụ trợ "Dữ liệu & Kiểm chứng", "Hệ thống & Chẩn đoán".
  - [x] Thêm thanh tiến trình `WorkflowStepperView` ở đầu trang chi tiết cho 4 bước chính với trạng thái hoàn thành và nút điều hướng "Tiếp tục sang bước tiếp theo →".
  - [x] Triệt tiêu hoàn toàn việc copy-paste UUID / SHA-256 thủ công giữa các màn hình G3, G4, G5: Tự động kết nối dữ liệu ngầm (`mappingPublicationId`, `cachedStoryBeats`, `cachedCaptionCues`) qua `AppState`.
  - [x] Tích hợp pipeline 1-Click tự động dựng và render preview trong G4 (`runFullPreviewPipeline()`) và final 4K trong G5 (`runFullFinalPipeline()`).
  - [x] Thêm thẻ thông báo hoàn thành (Celebration Card) cho phép mở file MP4 4K trong Finder hoặc mở Timeline trong DaVinci Resolve Studio chỉ với 1 click.
  - [x] Đóng gói và cài đặt phiên bản mới nhất vào `/Applications/AIVideo.app`.
- [x] **TTS engine swap (G3/S17)**: `P-TTS-VIENEU-v1` → `P-TTS-KOKORO-VI-V1` (`contextboxai/Kokoro-Vietnamese`, Apache-2.0, 82M, 15 preset voices, CPU). Adapter `tts_engine.py`, registry/docs/UI updated, weights in `Models/tts_kokoro_vi`, real synthesis verified 48 kHz PCM16.
- [x] **LLM script writer (G3/S16)**: `P-STORY-SYNTH-v1` (Qwen3-8B-4bit MLX) wired into `generate_story(script_engine="llm")` with faithfulness validation, deterministic fallback and provenance meta; Swift payload sends `script_engine`.
- [x] **Verification**: 241 Python (0 FAIL, 3 SKIP) · full Swift matrix EXIT=0 (0 FAIL) · VLM/TTS/story re-verified on the app runtime python · `/Applications/AIVideo.app` rebuilt and reinstalled.
- [x] **Phase 1a — ffmpeg native renderer (song song Resolve)**: `native_render.py` render preview 1080×1920 / final 2160×3840 với caption burn-in + `.srt`, crossfade/dip-to-black (frame math `Σ − overlap`), ảnh chèn Ken Burns (`illustrative_only`), `verify_output()` giữ QC; RPC `video.render.native` có path guard. Đồng bộ giọng–phụ đề bằng `g3.voice.phrases` (offset = sample thật). 260 Python test PASS.
- [x] **Phase 1b — guard + UI native**: `G5S22Guard.verifyFinalProvenance` nhận `.drp` hoặc `native-render-receipt-v1` (kiểm frame accounting + hash MP4), `G5ProjectStore` dùng hàm mới, nút "Render native 4K (ffmpeg)" trong G5 console, receipt JSON ghi cạnh MP4. Test Swift 4 ca + Python 20 ca.
- [x] **Phase 1c — native là mặc định**: pipeline 1-click của G4/G5 render bằng ffmpeg, receipt native đúng shape store yêu cầu, `G5ProjectStore` nhận `g5_native_receipt`, Resolve chỉ là warning trong preflight. Còn lại (tuỳ chọn): bật crossfade trong luồng UI cần cho S21/S22 dùng `native.total_frames`.


- [x] **UI Giản Lược + Brief Cho Người Viết Kịch Bản (2026-11-10)**:
  - [x] Sidebar còn 4 bước chính; "Kiểm chứng G2 / Dữ liệu / Model / Resolve / Năng lực" gom vào nhóm `Nâng cao & Chẩn đoán` thu gọn (tự mở khi điều hướng vào mục nâng cao).
  - [x] Bỏ `WorkflowStepperView` (trùng lặp với sidebar + thêm một tầng điều hướng thứ ba).
  - [x] Bước 1 thêm thẻ **"Thông tin cho người viết kịch bản"** — 6 mục: tiêu đề, mục tiêu, nhân vật POV, bối cảnh/địa điểm, giọng điệu, ghi chú; tự lưu sau 0.9 s và lưu bắt buộc ngay trước khi phân tích.
  - [x] Bảng `script_briefs` + `ScriptBriefRecord` trong `ProjectStore` (Swift single-writer); `brief_revision_id = SHA-256(workday | nội dung)` ⇒ lưu lặp là idempotent, sửa nội dung sinh revision mới (provenance trung thực).
  - [x] Bỏ brief demo hardcode trong `g1DraftFactText`; G2 nhận `brief_text` đúng những gì người dùng ghi (form trống ⇒ chuỗi rỗng, worker bỏ qua).
  - [x] G3 hiển thị thẻ "Brief từ Bước 1" và prefill chủ đề / giọng điệu (không ghi đè nếu người dùng đã sửa).
  - [x] Dọn trùng lặp: inspector chỉ còn 1 hành động chính "Phân tích video này"; prefilter + security badge vào "Tuỳ chọn nâng cao"; toolbar còn 1 nút mở thư mục; empty state không lặp lại 2 nút lớn.
  - [x] **Nghiệm thu**: `tools/build_macos_app.sh` PASS (build + codesign); `tools/run_s06_tests.sh` **6/6 PASS** (thêm ca `S06.BRIEF`); `tests/test_script_brief_parser.py` 4/4 OK; `tools/run_tests.sh` **EXIT=0** — Python **272 test OK (4 skip)**, toàn bộ Swift suite PASS.

- [x] **Dữ kiện cưới (wedding POV data model) — 2026-11-10**:
  - [x] Brief đổi từ 6 trường chung sang **dữ kiện cưới**: cặp đôi, loại lễ (đám hỏi/vu quy/thành hôn/tiệc/cả ngày), ngày-giờ, địa điểm, vai POV của người quay, phong cách (fine-art/cinematic/documentary/truyền thống/vui nhộn), **cảnh bắt buộc phải có**, **cảnh cần tránh**, nền tảng đăng (TikTok/Reels/Shorts/YouTube) + thời lượng mục tiêu, ghi chú.
  - [x] `composedText` phát **câu tiếng Việt tự nhiên, 1 câu/dòng** thay vì nhãn `Trường: giá trị`, để claim G2 đọc như dữ kiện thật.
  - [x] Parser S13 hiểu từ vựng cưới: "Bắt buộc có cảnh" → `must_use`, "Không quay/tránh quay" → `must_not_use`, "Phong cách/Cinematic/fine-art" → `style_preference`.
  - [x] G3 prefill: chủ đề = "Cặp đôi — Loại lễ", tone suy ra từ phong cách, thời lượng suy ra từ nền tảng (`topicLine`, `suggestedTone`, `suggestedSeconds`).
  - [x] DB: bảng `script_briefs` có cột mới; **migrate tại chỗ** bằng `PRAGMA table_info` + `ALTER TABLE` (không mất dữ liệu, DB cũ đã được nâng cấp thật trên máy).
  - [x] **Nghiệm thu**: `run_s06_tests.sh` 6/6 PASS (ca `S06.BRIEF` kiểm 8 dòng compose, round-trip, idempotent, revision mới, reopen WAL, `topicLine`); `test_script_brief_parser.py` 4/4 OK; build + install PASS; ma trận đầy đủ EXIT=0.

- [x] **VLM nhận diện cảnh cưới (2026-11-11)**:
  - [x] Module `wedding_scenes.py`: taxonomy 10 khoảnh khắc (đám hỏi, mẹ chải tóc, rước dâu, lạy gia tiên, thánh lễ, trao nhẫn, lì xì, chụp hình, tiệc cưới, nhảy mở màn) + matcher theo cue, **không suy đoán** khi thiếu cue.
  - [x] Prompt Qwen3-VL 4B có `prompt_guide()`: yêu cầu nêu đúng tên cảnh cưới nếu thấy rõ, không thì im lặng.
  - [x] Observation ghi thêm câu "Cảnh cưới nhận diện: …" + khoá `wedding_scenes`; không đổi `action_or_scene_type` (giữ hợp đồng cũ).
  - [x] Test `tests/test_wedding_scenes.py` 7 ca (đúng cue, không false-positive với "cô dâu/chú rể", thứ tự/khử trùng, NFD, rỗng, câu render, prompt guide).
  - [x] **Nghiệm thu**: 7/7 PASS; các suite pipeline cũ (S12, G2 window contract, prefilter, real VLM) vẫn PASS.

- [x] **Redesign UI toàn app (2026-11-11)**:
  - [x] Design system `AIVideoTheme.swift`: canvas gradient teal nhẹ, panel 16pt có hairline + shadow, spacing 4/8/12/16/24/32, chip bước, button styles.
  - [x] Sidebar mới: tile số thứ tự, dòng chọn có accent bar + tint teal, nhóm "NÂNG CAO & CHẨN ĐOÁN" thu gọn.
  - [x] Page header mới: chip "BƯỚC n / 4", tiêu đề rounded 30pt, subtitle, icon tile.
  - [x] Card/StatusPill/KeyValueRow/ErrorBanner/WorkerStatusCard/StatusBar restyle đồng bộ.
  - [x] Bỏ banner lặp ở G3/G4/G5, thay bằng 1 dòng quy tắc; sửa picker thời lượng bị cắt; rút gọn nhãn nút dài.
  - [x] **Nghiệm thu**: build + codesign PASS; chụp thật cả 4 bước (Media/G3/G4/G5) trên bản cài; ma trận EXIT=0; `test_source_hygiene` PASS (AIVideoApp 1547, AppState 1301).

## Cập nhật 2026-11-11 (sau khi vá P0 + toàn bộ P1)
- 9/9 lỗi P0 và 45/47 lỗi P1 đã vá, mỗi lỗi có test hồi quy (chi tiết: `progress.md`).
- Còn mở: **P1-23** (kiểm nội dung `.drp`), **P1-25** (phân trang observation >1 MiB),
  **P1-02** mới sửa một phần (S22; G4/S21 và `commitPublication` vẫn băm trong transaction).
- Gate G2 vẫn 🟡 IN_REVIEW: `fixtures/smoke` là title card tổng hợp, cần footage thật để chứng nhận corpus hiện trường.
- Bằng chứng: `python tools/run_python_tests.py` 379 PASS/0 FAIL; `./tools/run_tests.sh` exit 0 (23 khối).
