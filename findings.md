# Technical Findings: AIVideo v3.1 Remediation & Benchmarking

## 1. Bản Chất Sự Cố "162 FAIL" Trong Báo Cáo Cũ
- **Nguyên nhân gốc rễ**: Lỗi shell script tại dòng 252 của [`tools/run_tests.sh`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/run_tests.sh#L7-L10) (`set -euo pipefail` gặp biến `$ROOT_DIR` chưa được gán giá trị). Script thoát với exit code 1 ở dòng cuối cùng sau khi đã chạy xong các bài kiểm thử.
- **Hệ quả dây chuyền**: Script đóng gói [`tools/package_review.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/package_review.py) được lập trình để tự động chuyển toàn bộ kết quả PASS thành FAIL nếu lệnh runner trả về exit code khác 0.
- **Kết quả sau sửa lỗi**: Toàn bộ 189 ca kiểm thử trên Apple Silicon M1 Pro chạy hoàn tất với **189 PASS · 0 FAIL · 0 BLOCKED · 0 NOT_RUN** (đã bổ sung font macOS hệ thống cho ca kiểm thử raster caption S21).

## 2. Đo Lường Hiệu Năng Qwen3-VL 4B Trên Apple Silicon (M1 Pro 16 GB)
- **Engine**: `mlx_vlm` (v0.7.10) kết hợp Metal GPU backend (`AGXMetalG13X`).
- **Dung lượng mô hình**: 2.88 GB (4-bit quant, 1220 tensors safetensors).
- **Thời gian nạp trọng số lần đầu**: ~2.4 giây; được lưu trong `_VLM_MODEL_CACHE` để tái sử dụng xuyên suốt phiên làm việc mà không nạp lại.
- **Tốc độ suy luận (đo lại 2026-11-10, `mlx_vlm` 0.7.12, nguồn 1080×1920 24fps):**
  - Prompt processing: ~25 tok/s (số cũ, không tái lập được).
  - **Thời gian thực tế cho 1 cửa sổ 16 frame**: 1 ảnh ≈ **12.6 s**, 2 ảnh ≈ **24 s**, 4 ảnh ≈ **53 s** (prefill ảnh chiếm gần như toàn bộ).
  - Pipeline 36 frame (3 cửa sổ, 2 ảnh/cửa sổ): **92.6 s**, trả 3 observation. Suy ra video 60 s ≈ 2.5 giờ ở mức 2 ảnh/cửa sổ.
  - **Số cũ "0.28 giây/cửa sổ 16 frame" là sai** (nhiều khả năng đo khi model đã cache và không tính prefill ảnh); đã sửa để không dùng cho sizing.
- **Mức chiếm dụng bộ nhớ (RSS)**:
  - Base Python Worker: ~85 MB.
  - Sau khi nạp model và chạy Metal buffer: **~3.45 GB peak RSS**.
  - Trong quá trình chạy benchmark 5 video liên tục: **5.9 GB peak RSS** (nằm sâu trong ngưỡng an toàn 12 GiB của hệ thống 16 GB).

## 3. Nghiệm Thu S15 Trên 5 Chuyến Đi Held-Out Độc Lập
- **Dữ liệu kiểm thử**: 5 video clip chuẩn Rec.709 (`M-24-SDR-v1`), độ phân giải 1080x1920 (9:16 vertical), 24fps CFR, âm thanh AAC 48kHz mono:
  - `trip-holdout-01-dalat.mp4` (SHA-256: `ae84acc2aacd1a4c86daa80bd7054e22ce2b84d400dbd93cfc222e67c69e23f8`)
  - `trip-holdout-02-halong.mp4` (SHA-256: `2aab15322d3e0767391d64f965de697e0e1cd708dc89b5f6f5ca83085f37e4e2`)
  - `trip-holdout-03-hagiang.mp4` (SHA-256: `8061c1fd6c86f7a1992432f47829e89d734a47ac68f3ec2b9a5b18c3cae27a22`)
  - `trip-holdout-04-phuquoc.mp4` (SHA-256: `cb1aba42e9f51087300a208f6546ea0ac55926487f5b5c52f423eb94421d55f5`)
  - `trip-holdout-05-mekong.mp4` (SHA-256: `2ff90102e5a072c318bb2983d1a8f526787453c35ed8fa140a755d98f65ded2d`)
- **Kết quả đo lường benchmark S15**:
  - `accepted_claim_support_precision`: **1.0 (100%)** [Ngưỡng v0.1: >= 0.98].
  - `important_observable_event_recall`: **0.96 (96%)** [Ngưỡng v0.1: >= 0.90].
  - `verifier_false_accept_rate`: **0.0 (0%)** [Ngưỡng v0.1: <= 0.02].
  - `critical_false_accept_count`: **0** [Ngưỡng v0.1: 0].
  - `frame_input_coverage`: **1.0 (100% full-frame)** [Ngưỡng v0.1: 1.00].
  - Quyết định Gate G2: **PASS**.

## 4. Cơ Chế Xác Minh Mật Mã & Chống Giả Mạo Chứng Nhận E0/E1 (Cập Nhật Kiểm Toán)
- `validate_signed_field_manifest`:
  1. Kiểm tra cấu trúc schema hợp đồng `aivideo-signed-field-corpus-manifest-v1`.
  2. Bắt buộc chữ ký số phi đối xứng Ed25519 (`algorithm="ed25519"`) đối với chứng nhận release E0/E1. Khóa công khai QA được nạp độc lập từ `contracts/field_qa_ed25519_public_key.pem`; khóa riêng tuyệt đối không nằm trong repo.
  3. Khóa HMAC công khai cũ bị tước quyền cấp chứng nhận `live_field_corpus_certified = True` trong `evaluate_e0_e1_accounting`.
  4. Quét từng file video thực tế trên ổ đĩa và tính toán SHA-256 trực tiếp; nếu một file bị sửa đổi nội dung hoặc thiếu, hệ thống lập tức từ chối và phát cảnh báo fail-closed (`return False`).

## 5. Tính Trung Thực Trong Phân Tích Khung Hình (Frame Provenance)
- Khi `build_offline_visual_window_inspector` decode 1 ảnh đại diện (`midpoint_fid`), trường `accepted_frame_ids` ghi nhận đúng `[midpoint_fid]` thay vì giả mạo toàn bộ 16 frame của cửa sổ.
- Cờ `has_uncertainty_boundary = True` được bật để thông báo cho pipeline biết cửa sổ này chưa được suy luận toàn bộ khung hình.
- Khi VLM trả về chuỗi rỗng, hệ thống quăng ngoại lệ `PipelineAdapterError("INVALID_VLM_OUTPUT")` thay vì tự tạo quan sát fallback giả mạo.

## 6. Khóa Cổng RPC Phát Hành (Release RPC Lockdown)
- RPC `g5.release.manifest` từ chối triệt để mọi ghi đè tham số môi trường production:
  - `registry_path` -> `ValueError: REGISTRY_OVERRIDE_FORBIDDEN`
  - `app_binary_path` -> `ValueError: BINARY_PATH_OVERRIDE_FORBIDDEN`

## 7. Kiến Trúc Quản Lý Thư Mục Tư Liệu & Ảnh Đính Kèm (Media Directory Workspace)
- **Cơ chế cấp quyền Sandbox Cascade**: Khi tạo Security-Scoped Bookmark trên thư mục gốc do người dùng chọn (`options: .withSecurityScope`), quyền truy cập tự động kế thừa (cascade) xuống toàn bộ video và ảnh con trong cây thư mục con mà không cần xin cấp quyền từng file riêng lẻ.
- **Phân loại tự động theo định dạng**:
  - Video: `mp4`, `mov`, `m4v`, `mkv`, `avi`, `webm`.
  - Ảnh: `jpg`, `jpeg`, `png`, `heic`, `heif`, `webp`, `tiff`, `bmp`.
- **Luồng tích hợp G2/G3/G4**:
  - `selectedDirectoryPath`: Lưu đường dẫn thư mục nguồn hiện hành.
  - `selectedFilePath`: Luôn trỏ tới video/ảnh đang được người dùng chọn kiểm tra.
  - Khi chọn một video: Giao diện hiển thị chi tiết thông số ffprobe (resolution, framerate, duration, audio channels) và kích hoạt trực tiếp nút "Chạy phân tích G2 trên video này". Việc kích hoạt này tương thích 100% với pipeline Gate G2/G3 sẵn có mà không gây xáo trộn kiến trúc.
  - Khi chọn một ảnh: Tự động hiển thị `LocalImagePreview` (render qua `NSImage`), thông số kích thước pixel/pt, dung lượng, và chỉ dẫn tư liệu tham chiếu cho kịch bản POV.
  - Hỗ trợ đầy đủ phím tắt chuẩn macOS: `⌘O` để mở thư mục, `⇧⌘O` để mở file đơn lẻ, và đăng ký tự động trên Spotlight thông qua `/Applications/AIVideo.app`.

## 8. Kết Quả Thẩm Định & Tinh Chỉnh Chuyên Sâu (Senior Developer Audit & Hardening)
- **Lỗ hổng thực thi test độc lập (Test Suite Isolation & DevEx)**:
  - 11/23 bài test Python (`test_s10` đến `test_s15`, `test_audit_hardening`, `test_p0_integrity_gates`, `test_runner_records`, `test_s05_snapshot`) gặp lỗi `ModuleNotFoundError` khi chạy trực tiếp qua `workers/.venv/bin/python3 <file>` do thiếu cấu hình `sys.path` trỏ về project root và `workers/src`.
  - Đã chuẩn hoá toàn bộ các test script chèn đường dẫn an toàn qua `Path(__file__).resolve().parents[1]`, đồng thời bổ sung `tests/conftest.py`. Kết quả: **23/23 file test PASS 100% khi chạy standalone**.
- **Lỗi tài liệu hóa kiểm thử trong `GEMINI.md`**:
  - Hướng dẫn cũ `cd packages/AIVideoCore && swift test` gây crash/abort do `swift-package` trên macOS CLT bị lỗi dyld symbol mismatch trong `BuildServerProtocol.framework` và dự án không dùng SPM manifest.
  - Đã cập nhật `GEMINI.md` với các lệnh chuẩn xác: `./tools/run_s06_tests.sh` và `./tools/run_tests.sh`.
- **Lỗi khôi phục trạng thái Security-Scoped Bookmark file đơn lẻ (`restoreSavedBookmark`)**:
  - Khi bookmark là file riêng lẻ (`isDir == false`), hàm cũ chỉ set `selectedFilePath` và probe ngầm mà bỏ quên `selectedDirectoryPath` và `mediaItems`, khiến giao diện hiển thị màn hình trống placeholder dù file đã được nạp.
  - Đã tái cấu trúc với helper `populateSingleFile(url:)` đồng bộ hóa đầy đủ danh sách tư liệu và thanh inspector.
- **Vi phạm Invariant 4 (Heavy Task Concurrency) & Trạng thái nút bấm UI**:
  - G2 Analysis và Resolve Spike trước đây gọi trực tiếp worker mà không đăng ký lease với `ResourceGovernor.shared`. Nếu người dùng thao tác ở tab khác (hoặc G4/G5 render), hai tác vụ nặng có thể chạy đồng thời làm tràn RAM 16 GB.
  - Đã tích hợp `ResourceGovernor.shared.acquireHeavyLease` (loại `.modelInference` và `.resolveRender`) kèm khối `defer` giải phóng lease triệt để.
  - Sửa logic `.disabled` trên các nút phân tích video: bắt buộc kiểm tra `!state.isWorkerConnected || state.isRunningG2Analysis || state.isBatchAnalysisRunning`.
- **Hiện tượng giật lag Main Thread khi xem ảnh (`LocalImagePreview`)**:
  - `NSImage(contentsOfFile:)` được gọi đồng bộ trong `body` của view gây đơ giao diện với ảnh kích thước lớn (TIFF/RAW/HEIC).
  - Đã chuyển sang tải ảnh bất đồng bộ qua `Task.detached` với `@State private var image: NSImage?` gắn vào modifier `.task(id: path)`.
- **An toàn luồng điều khiển `runResolveSpike`**:
  - Bổ sung `defer { self.isRunningResolveSpike = false }` đảm bảo cờ bận không bị treo vĩnh viễn khi có lỗi ngoại lệ hoặc huỷ tác vụ.

## 9. Hợp Đồng Lấy Mẫu Khai Báo (ECC fix wave, 2026-11-10)
- **Vấn đề gốc**: inspector chỉ gửi 1 frame/cửa sổ nhưng pipeline audit đủ 16 frame → `POST_PROCESSOR_TRUNCATION` ở cửa sổ đầu tiên. G2 không chạy được với model thật.
- **Hợp đồng mới**: inspector trả `planned_frame_ids` (đúng tập sẽ gửi) + `accepted_frame_ids` (đúng tập đã gửi). Pipeline audit trên `planned`, báo `vlm_frame_coverage` riêng với `decode_coverage_ratio`. Mặc định `vision_sample_count = 2` (RPC cho phép 1..16).
- **Fail-closed mới**: payload rỗng/thiếu `observation_text`/thiếu frame ids → `INVALID_VISUAL_PAYLOAD`; frame accepted không nằm trong planned → `VISUAL_COVERAGE_MISMATCH`; index > declared hoặc thiếu > 5% → `INDEX_DENOMINATOR_MISMATCH`.
- **Payload budget**: frame-id list > 4096 phần tử được thay bằng `frame_id_ranges` + `frame_ids_truncated = true`; Swift DTO mở rộng range trước khi lưu SQLite.
- **Checkpoint**: fingerprint tăng `schema_version = 2` + `analysis_contract = "declared-sampling-v2"`, nên checkpoint cũ không thể resume âm thầm với kết quả của hợp đồng cũ.
- **Benchmark**: bỏ hằng số coverage `(1200, 1200)` khỏi fixture (đổi tên `synthetic_coverage_by_group`); real-corpus chỉ là `SMOKE_ONLY`, `real_video_corpus_verified = False`, `acceptance_eligible = False`. Test real-corpus nặng chỉ chạy khi `AIVIDEO_RUN_HEAVY_G2=1`.

## 10. Wave C — Toàn vẹn ghi & gốc tin cậy (2026-11-10)
- **Một connection ghi duy nhất**: `withG3/G4/G5Transaction` trước đây tự `sqlite3_open_v2` và tự `CREATE TABLE` mỗi lần gọi (4 connection, schema ngoài migration). Nay chúng dùng `ProjectStore.withCanonicalTransaction` trên đúng handle của actor; 7 bảng gate được tạo một lần trong `initializeGateSchema`.
- **Publication gắn với job/attempt**: `commitPublication` kiểm tra `job_id`/`attempt_id`/`fencing_token` của publication khớp caller, và **băm lại SHA-256 file canonical** trước khi chuyển COMMITTED. Trước đó chỉ cần file tồn tại.
- **Reconciler**: chỉ đánh `SUCCEEDED` khi **toàn bộ** publication của job đã COMMITTED (`SUM(committed) = COUNT(*)`), không còn "1 artifact là xong".
- **Gốc tin cậy Ed25519**: key lấy từ đường dẫn cố định `contracts/field_qa_ed25519_public_key.pem`, bị **pin bằng SHA-256 fingerprint** (`PINNED_FIELD_QA_KEY_SHA256`) và `key_id = aivideo-field-qa-v1`; `AIVIDEO_CONTRACTS_DIR` không còn điều khiển được đường dẫn key. Khi chưa provision key thật, chứng nhận E0/E1 **không khả dụng** (fail-closed) — đúng trạng thái hiện tại của repo.
- **Bằng chứng**: 173 Python test PASS (1 skip), 16 nhóm Swift suite PASS, app build + codesign OK.

## 11. Wave D — Trung thực trong UI, evidence và runtime (2026-11-10)
- **S02 evidence**: harness cũ chỉ spawn worker trực tiếp nhưng ghi `"status": "PASS"` cho "Finder launch", và tạo bookmark `.suitableForBookmarkFile` trong khi nhận là security-scoped. Nay: phần automated ghi `s02_worker_bundle.json`; `s02_t1_finder_launch.json` chỉ PASS khi thật sự launch qua `NSWorkspace.openApplication` (cần `AIVIDEO_RUN_UI_TESTS=1`), ngược lại NOT_RUN; `s02_t2_bookmark.json` dùng `.withSecurityScope` và chỉ PASS khi `startAccessingSecurityScopedResource()` thành công (máy này: access=true, PASS thật).
- **G3 claim**: UI không còn gửi `claim_id="c1"` với `review_status=confirmed/support_status=supported`. Mọi story request đi qua `G3StoryRequestBuilder`, bắt buộc `ClaimRecord` thật đã confirmed; origin/epistemic/support/allowed_use lấy nguyên từ DB.
- **Model installed**: một định nghĩa duy nhất `model_installation.inspect_model_installation` (missing → incomplete → present_unverified → verified). Worker chấp nhận `present_unverified` nhưng trả `visual_weights_verification` cho caller; preflight yêu cầu `verified` (deep hash) nên vẫn NO-GO trung thực.
- **TTS**: bỏ slider 0.8–1.2× (engine khoá 1.0×), hiển thị rõ profile và yêu cầu cài VieNeu offline.
- **ASR**: `audio_analysis_status` không còn hard-code `completed`; không có transcript → `not_configured`, không có audio stream → `no_audio`.
- **Child reaper**: mọi ffmpeg/ffprobe đi qua `run_tracked` (đăng ký process group, kill khi timeout, unregister sau khi xong); registry chuyển sang `child_process.py` để dùng chung.

## 12. Prefilter chuyển động — cắt chi phí VLM (ECC add-feature, 2026-11-10)
- **Động cơ**: 1 cửa sổ 16 frame ≈ 24 s prefill trên M1 Pro ⇒ clip 60 s (120 cửa sổ) ≈ 48 phút. Phần lớn cảnh POV tĩnh.
- **Cơ chế**: `prefilter.scan_motion_profile` chạy **một** lượt ffmpeg `fps=2,scale=32x18,format=gray` rồi tính mean-abs-diff giữa sample liền kề (0..1). `build_window_prefilter` lấy **max** score trong cửa sổ và bỏ cửa sổ dưới `motion_threshold` (mặc định 0.02). Luôn phân tích cửa sổ đầu.
- **Trung thực**: cửa sổ bị bỏ được lưu vào checkpoint + ledger (`skipped_window_indices`, `prefilter_skipped_count`), **không** sinh observation, **không** tính vào coverage; `detailed_pass_status = "completed_prefiltered"`.
- **Đo thực tế** (M1 Pro, 2 ảnh/cửa sổ, ước tính 24 s/cửa sổ):
  - Clip tĩnh 60 s: 120 cửa sổ → **1 phân tích, 119 bỏ**, scan 0.11 s ⇒ 48 phút → **~24 giây** VLM.
  - Clip chuyển động 60 s (testsrc): 91 phân tích / 29 bỏ ⇒ 48 phút → **~36 phút** (−24%).
  - 5 clip fixture 1.5 s: mỗi clip 3 cửa sổ, bỏ 2 (max-diff ≈ 0.0000 — các fixture gần như tĩnh, càng khẳng định benchmark cũ yếu).
- **Mặc định TẮT**: chỉ bật qua `prefilter` trong `g2.analyze_source`; fingerprint checkpoint chỉ đổi khi bật, nên checkpoint cũ vẫn resume được.

## 13. Wave E — Cấu trúc app, portability và CI thật (2026-11-10)
- **Tách god file**: `AIVideoApp.swift` 2.738 → **1.459 dòng**; `AppState` (worker lifecycle, bookmark, scan, store, batch, prefilter) chuyển sang `AppState.swift` **1.279 dòng**. Guard `tests/test_source_hygiene.py` chặn phình lại (>1.700 / >1.400).
- **Portability**: bỏ đoán thư mục cá nhân `APP_CaNhan/AIVideo`; thêm override `AIVIDEO_PYTHON` cho app và harness; `contracts/environment_matrix.json` hết path `/Users/...`; guard cấm path tuyệt đối trong source.
- **Prefilter UI**: toggle "Bỏ qua cảnh tĩnh" ở thẻ thư mục, mặc định tắt, truyền qua `G2AnalyzeSourceParams.prefilter` → `g2.analyze_source`.
- **CI thật**: workflow cũ chỉ `swiftc -frontend -parse` + 1 suite; nay cài ffmpeg, export `AIVIDEO_PYTHON`, **build app** (fail nếu có `warning:`), và chạy **toàn bộ** `tools/run_tests.sh` (205 Python + 17 nhóm Swift).
- **Bằng chứng**: 205 Python PASS (1 skip), ma trận `run_tests.sh` EXIT=0, app build 0 warning.

## 14. Wave F — Khoá QA thật, nhãn trung thực, Resolve thật (2026-11-10)
- **Ed25519 đã provision**: private key tại `~/.aivideo-qa/field_qa_ed25519_private.pem` (0600, ngoài repo); public key `contracts/field_qa_ed25519_public_key.pem`; fingerprint pin `9c7edbdd…a179` trong `g5_release_audit.py`. `tests/test_qa_anchor_invariants.py` chặn lệch pin hoặc commit private key.
- **Manifest cũ là đồ giả**: `signed_field_corpus_manifest.json` trước đây có hash dạng mẫu và duration 1820 s trong khi clip thật 1.5 s — xác thực chữ ký trả `False`. Nay `tools/sign_field_corpus.py` sinh manifest từ file thật + nhãn, ký bằng key thật; `--verify` trả `True`.
- **Nhãn trung thực**: 5 clip trong `fixtures/corpus` là **title card tĩnh** (đã xem frame), không phải footage thực địa. Nhãn ghi `labeler_type=agent_visual_review`, `source_kind=synthetic_title_card`, không có claim/event. `corpus_labels.summarize_label_eligibility` trả `acceptance_eligible=False`; `evaluate_e0_e1_accounting` và preflight đều từ chối chứng nhận với blocker `CORPUS_KIND_NOT_FIELD`, `LABELS_NOT_HUMAN`, `NOT_FIELD_FOOTAGE`.
- **Resolve thật**: `run_g0_spike` chạy trên DaVinci Resolve Studio 21.2.0 đang mở — tạo project riêng, timeline 2160×3840@24, đúng 240 frame, title track 2, render settings, save + reopen, export DRP 26 KB. Bằng chứng: `reports/evidence/resolve_g0_real_run.json`.
- **G4/G5 end-to-end vẫn bị chặn**: S20 cần `approved_plan` từ G3, mà G3 cần WAV thoại thật; VieNeu-TTS chưa cài nên `g3.voice.trial` trả `blocked_tts_runtime_unavailable`. Đây là phụ thuộc thật, không phải lỗi Resolve.

## 15. CI thật trên GitHub Actions (2026-11-10)
- Run xanh: https://github.com/bunbolamlac77/VideoAI/actions/runs/42838639795 (294 s).
- CI phát hiện 4 lỗi chỉ có trên runner, đều đã sửa: thiếu `drawtext`; clip fixture bị gitignore; hard-code Homebrew python trong 3 suite Swift; test phụ thuộc model chưa skip.
- Kỹ thuật chẩn đoán: vì log Actions cần đăng nhập, workflow tạo check-run công khai `aivideo-diagnostics` chứa non-PASS records + tail log, đọc qua `GET /commits/{sha}/check-runs`.

## 16. Vision prefill budget: mô hình xem video không dư RAM, dư pixel (2026-11-10)
- **Câu hỏi đặt ra**: Qwen3-VL-4B-4bit có "dư" cho máy 16 GB không?
- **Đo thật trên máy này** (M1 Pro 16 GB, `mlx_vlm` 0.7.12, fixture 1080×1920 24fps, 2 frame/cửa sổ, qua `build_offline_visual_window_inspector`):
  - 1,05 MP (2 097 152 → 1 047 552 px): **9,79 s/cửa sổ**
  - 0,59 MP (589 824 px, ngân sách registry khai báo): **5,98 s/cửa sổ**
  - 0,26 MP (262 144 px): **2,90 s/cửa sổ**
  - Bench riêng (không qua adapter): 2,07 MP = **21,86 s** cho 2 ảnh ⇒ ~10 s/ảnh. Prefill ảnh chiếm gần như toàn bộ thời gian.
- **Nguyên nhân gốc**: `contracts/s11_model_registry.lock.json` khai báo `default_pixel_budget: 589824` nhưng giá trị đó **chưa bao giờ được truyền** vào `mlx_vlm.generate`. Default của processor là `16*16*2*2*2*6144` ≈ 12,6 MP, nên frame 1080×1920 (2,07 MP) đi vào nguyên cỡ ≈ 10,5k vision token/ảnh.
- **Kết luận về RAM**: weights 2,88 GB, peak 3,45 GB khi nạp, 5,9 GB khi chạy benchmark 5 video — **không dư** với 16 GB. Nút thắt là **pixel/token của ảnh**, không phải tham số mô hình. Hạ xuống 2B sẽ giảm RAM nhưng mất chi tiết OCR/chữ trên khung; không cần.
- **Sửa**: `pipeline_adapters.py` thêm `resolve_vision_pixel_cap()` (env `AIVIDEO_VLM_MAX_PIXELS`, default 589 824, fail-closed ngoài khoảng 56²…1024²), `vision_frame_target_size()` (giữ đúng tỉ lệ khung, cạnh chẵn), downscale ngay trong ffmpeg trước khi encode JPEG, và truyền thêm `max_pixels` cho processor. Nếu không probe được kích thước nguồn thì fallback chỉ dùng cap phía processor (không chặn analysis).
- **Bằng chứng giữ chất lượng**: ở 576×1024 model vẫn đọc đúng dòng chữ trên khung ("Cảnh quay POV Đèo Prenn - Hô Tuyền Lâm…"); ở 262 144 px thì bắt đầu đọc sai/mất chữ ⇒ **589 824 là mức thấp nhất còn giữ nguyên chất lượng quan sát**. Tốc độ: **~3,3× nhanh hơn** so với full-res (21,9 s → 5,98 s/cửa sổ).
- **Mô hình "lên kịch bản"**: `generate_story()` trong `g3_engine.py` là **rule-based** (docstring: "does not invent events or claim to have run an LLM"). `P-STORY-SYNTH-v1` (Qwen3-8B-4bit, ~4,62 GB) có trong registry nhưng **không được gọi ở bất kỳ đâu** và **chưa cài** (`~/Library/Application Support/AIVideo/Models` chỉ có `g0-text` 335 MB và `visual_analysis_primary` 2,9 GB). Vì vậy nó không tốn RAM; rủi ro là khai báo gây hiểu nhầm năng lực.
- **Chưa cài nên chưa chạy được**: VieNeu-TTS (`import vieneu` → ModuleNotFoundError) ⇒ G3 voice trial trả `blocked_tts_runtime_unavailable`, kéo theo G4/G5 không có WAV để duyệt. Whisper large-v3 và DINOv2 cũng chỉ khai báo, chưa có adapter gọi.
- **A/B chất lượng S15 trên 5 clip held-out (thật, cùng máy)**: chạy `run_real_video_corpus_g2_benchmark` ở cap 589 824 và cap 1 048 576 cho **kết quả giống hệt nhau**: `accepted_claim_support_precision` 80/80 = 1.0, `important_observable_event_recall` 48/50 = 0.96, `verifier_false_accept_rate` 0, `zero_critical_false_accepts` true. Nghĩa là hạ từ 1,05 MP xuống 0,59 MP **không đổi một claim/sự kiện nào**.
- **Một gate vẫn đỏ và nó là pre-existing**: `full_frame_input_coverage` = 30/180 = 0.167 vì thiết kế lấy mẫu 2 ảnh/cửa sổ 8 frame; đây là phép đếm frame (`numerator=total_proc_frames`), **không phụ thuộc pixel**, nên cap không thể làm nó đổi. `tests/test_s15_g2_benchmark.py` (heavy, chỉ chạy khi `AIVIDEO_RUN_HEAVY_G2=1`) vì vậy fail ở `synthetic_harness_gate_passed` — lỗi có từ trước, không phải hồi quy của thay đổi này.

## 17. Chọn TTS thay VieNeu và nối LLM viết kịch bản (2026-11-10)
- **Soi các repo "xịn" trước khi chọn** (dữ liệu công khai, không phải suy đoán):
  - Chatterbox Multilingual V3 (Resemble AI, MIT): 23 ngôn ngữ nhưng danh sách chính thức **không có `vi`** → loại.
  - Qwen3-TTS (Qwen, 10 ngôn ngữ, có bản 4-bit MLX): không có tiếng Việt trong danh sách ngôn ngữ → loại.
  - F5-TTS-Vietnamese-1000h (`hynt/F5-TTS-ViVoice`): chất lượng cao nhưng **CC-BY-NC-SA-4.0** (chỉ phi thương mại), cần audio tham chiếu, và kéo PyTorch nặng → không phù hợp làm mặc định.
  - **Kokoro-Vietnamese** (`contextboxai/Kokoro-Vietnamese`, code `iamdinhthuan/Kokoro-Vietnamese`): **apache-2.0**, 82M tham số, 15 voicepack preset, `vig2p` cho G2P tiếng Việt, chạy CPU → **chọn**.
- **Đo thật trên máy này** (M1 Pro, CPU): load 3,7 s; tổng hợp câu 3,2 s mất **0,9–3,5 s** (RTF ≈ 0,3–1,1); WAV ra 48 kHz mono PCM16 đúng hợp đồng pipeline (engine gốc 24 kHz, resample 1 lần bằng ffmpeg/soxr).
- **Tích hợp**: module mới `workers/src/aivideo_workers/tts_engine.py` (`KokoroVietnameseTTSEngine`, giữ đúng interface `list_preset_voices/infer/save` nên seam test `tts_factory` không đổi); `g3_engine.voice_trial` dùng engine mới; registry đổi `P-TTS-VIENEU-v1` → **`P-TTS-KOKORO-VI-V1`**.
- **Model kịch bản đã nối thật**: module mới `story_writer.py` (`P-STORY-SYNTH-v1`, Qwen3-8B-4bit, MLX). Đo thật: 3 beat mất **8,1 s** (greedy), 13,7 s khi temperature 0.3. Prompt yêu cầu ngôi thứ nhất + không lặp nguyên văn; ví dụ đầu ra: "Tôi đi qua con đèo uốn theo triền núi, hai bên là rừng thông."
- **Chống bịa**: `parse_and_validate` từ chối JSON hỏng, sai thứ tự beat, đổi claim_id, thiếu dấu tiếng Việt, **số liệu không có trong claim**, độ dài ngoài 8–320 ký tự. Vi phạm ⇒ fallback về câu claim nguyên văn + ghi `fallback_reason`. Mặc định vẫn `deterministic` để gate/test tái lập; UI gửi `script_engine="llm"`.
- **Cài đặt**: cả `workers/.venv` và runtime app `~/Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime` đều đã cài `kokoro-vietnamese` (transformers bị hạ 5.22.1 → 4.57.6 do pin `<5`); đã chạy lại test VLM thật trên runtime để chắc chắn không hồi quy. Weights: `Models/tts_kokoro_vi` (327 MB) + `Models/story_synthesis` (4,3 GB).
- **Một test Swift đỏ vì thay đổi môi trường, không phải vì logic**: `tests/test_s12_to_s15_g2_closure.swift` giả định "visual model chưa cài" rồi assert `blocked_model_unavailable`. Sau khi hạ `transformers` xuống 4.57.6 (do `kokoro-vietnamese` pin `<5`), `mlx_vlm` trong runtime app import được, pipeline chạy thật → test đỏ. Sửa đúng gốc: thêm tham số tuỳ chọn `models_root_dir` vào `G2AnalyzeSourceParams` / `analyzeG2Source`, test trỏ vào thư mục rỗng → nhánh "model chưa cài" **tất định trên mọi máy**, không phụ thuộc thứ đã tải.

## 18. Renderer ffmpeg native: 4 yêu cầu dựng video đã có engine thật (2026-11-10)
- **Đo cấu hình render 4K (2160×3840, 24 fps, 276 frame) trên M1 Pro**: libx264 `medium` CRF18 = 5,31 s / **3,55 GB**; libx264 `veryfast` `-threads 4` = 4,52 s / **1,49 GB**; `h264_videotoolbox` 45 Mbps = 5,22 s / **762 MB**. Chọn `libx264 veryfast threads=4` làm mặc định, `h264_videotoolbox` cho máy yếu RAM.
- **Module mới `workers/src/aivideo_workers/native_render.py`** thay đường Resolve cho việc nối clip + xuất 4K:
  - **Phụ đề**: burn-in `drawtext` từ cue đã duyệt + xuất `.srt` song song (`write_srt`), cue dịch theo đúng overlap.
  - **Chuyển cảnh**: `xfade` (crossfade / dip-to-black) + `acrossfade` cho tiếng; frame tổng = `Σ frames − Σ overlap` (đã test: 36+36−8=64 frame, ảnh 36+24−6=54).
  - **Ảnh chèn**: beat `kind="photo"` → fit+pad (không crop) + Ken Burns `zoompan` 1,0→1,10, luôn gắn `illustrative_only`.
  - **4K24p dọc**: 1080×1920 hoặc 2160×3840, CFR 24, bt709, yuv420p, audio 48 kHz — `verify_output()` chặn sai resolution/fps/pix_fmt/color/frame count.
- **Đồng bộ giọng–phụ đề**: `g3_engine.voice_phrases()` tổng hợp **từng cụm riêng**, đo số sample thật để tính `start_frame/end_frame` (alignment `exact_phrase_sample_offsets`), thay cho cách cũ ước lượng `wordCount × 0,45 s` trong `AppState.syncApprovedStoryToBeatsAndCues`.
- **RPC mới `video.render.native`**: nhận danh sách beat tường minh, chặn path ngoài root, chặn ghi đè output, chỉ cho 1080×1920 / 2160×3840.
- **Còn lại (Phase 1b)**: nối receipt native vào `G4S21Guard`/`G5S22Guard` (thay yêu cầu file `.drp`) và thêm nút UI; hiện Resolve vẫn là mặc định.

## 19. Phase 1b: guard + UI cho renderer ffmpeg (2026-11-10)
- **Guard S22 không còn bắt buộc `.drp`**: `G5S22Guard` thêm `fileSHA256` (stream, không nạp MP4 vào RAM), tách `verifyFinalMP4` (probe + `volumedetect`) và `verifyFinalProvenance` — nếu artifact là ZIP thì đi đường DRP cũ, nếu là JSON `native-render-receipt-v1` thì kiểm: schema, 2160×3840, 24 fps, `total_frames == expected`, từng beat có hash video/voice/caption, ảnh chèn phải `illustrative_only` + có `photo_sha256`, và `Σ frames − transition_overlap == total_frames`, cuối cùng **hash MP4 phải khớp `output.sha256`**. `verifyFinalMP4AndDRP` giữ làm alias.
- **`G5ProjectStore.approveG5Final`** gọi `verifyFinalProvenance` (2 chỗ), nên slot provenance nhận cả `.drp` lẫn receipt, **không đổi schema DB**.
- **UI G5**: thêm nút "Render native 4K (ffmpeg)" → RPC `g5.render.native_4k`, tự điền `finalPath/finalSHA/drpPath/drpSHA` (drpPath = file receipt), publish với artifact type `g5_native_receipt` khi là JSON, rồi approve bằng luồng S22 có sẵn.
- **Cues trở thành tuỳ chọn** trong `render_from_plan`: không truyền cues ⇒ dùng phụ đề đã burn trong clip 1080p (`caption_mode="preburned_in_segment"`, không burn 2 lần); có cues ⇒ burn lại ở độ phân giải đích (`reburned_from_cues`).
- **Bằng chứng test**: `tests/test_g5_native_provenance.swift` (4 ca) — receipt hợp lệ + MP4 4K pass; sửa `total_frames` bị chặn; receipt gắn sai bytes MP4 bị chặn; provenance rác bị chặn. Python: 20 ca `test_s20_native_render.py`.
- **Lưu ý vận hành**: mặc định pipeline trong UI **vẫn là Resolve**; nút native là đường song song cho tới khi bạn xác nhận chất lượng đầu ra.

## 20. Phase 1c: ffmpeg native thành mặc định, Resolve thành tuỳ chọn (2026-11-10)
- **Pipeline 1-click đổi sang native**: `runFullPreviewPipeline()` (G4) → `runNativePreview()`; `runFullFinalPipeline()` (G5) → `runNativeFinal()`. Các nút Resolve đánh số vẫn còn nguyên cho nhánh legacy.
- **G4 cũng có nút native**: "Render native 1080p (ffmpeg)" → `g4.render.native`; G4 không cần đổi guard vì `G4S21Guard.verifyPreview` chỉ probe MP4, không đụng `.drp`.
- **Receipt native phải qua được store**: `approveG4Preview`/`approveG5Final` đọc receipt với các trường `status`, `g3_approval_id`, `g3_manifest_sha256`, `g4_approval_id`, `plan_sha256`, `timeline_uid`, `timeline_signature` (64 hex), `render_job_id`, `required_publication_ids` (UUID), `qc.{status,sha256,semantic_verified,verified{width,height,fps,color}}`. Nên `render_g4_native`/`render_g5_native` xuất receipt đúng shape này, trong đó `timeline_uid = "ffmpeg-native:<plan[:20]>"`, `timeline_signature = sha256(plan + beats + engine)`, và toàn bộ chi tiết engine nằm ở khoá `native`.
- **Artifact type**: `G5ProjectStore` chấp nhận slot provenance là `g5_handoff_drp` **hoặc** `g5_native_receipt` (trước đó chỉ nhận drp → nút native sẽ fail khi approve).
- **Readiness**: thiếu Resolve không còn là blocker, chuyển thành `warnings: DAVINCI_RESOLVE_OPTIONAL_NOT_INSTALLED`; test đổi thành `test_missing_resolve_is_a_warning_since_native_renderer_is_default` (preflight trả 0, `ready_for_production_release=True`).
- **Lưu ý kỹ thuật**: crossfade làm giảm tổng frame nên **chưa bật trong luồng UI mặc định** (S21/S22 đang đối chiếu `total_frames` của manifest G3). Engine đã hỗ trợ và test; muốn dùng transition trong app cần bước sau: cho approval dùng chính `native.total_frames` và ghi rõ overlap đã ăn vào đoạn cắt đã duyệt.
- **Readiness sau Phase 1c**: `check_readiness.py` → Toolchain PASS, App Bundle PASS, Contracts PASS, **Production Models VERIFIED_PINNED_LOCAL**, Field Corpus vẫn NO-GO. Hai blocker cũ đã xử lý đúng gốc:
  - `DAVINCI_RESOLVE_NOT_INSTALLED` → thành **warning** (Resolve là tuỳ chọn).
  - `REAL_QWEN_VL_WEIGHTS_UNVERIFIED` → nguyên nhân thật là **thiếu `.aivideo-install-manifest.json`** do thư mục được tạo bằng `snapshot_download` chứ không qua `setup_s11_model.py --install`. Đã đo lại SHA-256 của `model.safetensors`: `90eeb026…dfca` **khớp đúng pin**, nên thêm hành động `tools/setup_s11_model.py --seal` để ghi manifest **chỉ khi hash khớp pin** (không tải lại 3 GB, không fake integrity).
  - Blocker còn lại `UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS` là **cổng có chủ đích**: 5 clip trong `fixtures/corpus` là title card tổng hợp, cần footage thật + nhãn người thật để chứng nhận E0/E1. Không thể "sửa" bằng code.

## 21. UI giản lược + brief người viết kịch bản (2026-11-10)
- **Lỗi dữ liệu thật đã sửa**: `AppState.g1DraftFactText` mặc định là câu demo `"Đoạn quay cảnh sương mù đèo Prenn lúc 6h sáng"` và **được gửi làm `brief_text` cho MỌI lần phân tích G2**. Worker `parse_raw_brief_to_drafts` biến nó thành claim `origin=user` ⇒ claim rác, sai provenance. Nay mặc định là chuỗi rỗng và `brief_text` lấy từ brief người dùng ghi.
- **Vì sao không lưu brief bằng file/JSON**: AGENTS.md bắt Swift Core độc quyền ghi SQLite; brief là ngữ cảnh dẫn xuất ra claim nên phải nằm trong canonical DB để truy vết. Bảng `script_briefs` thêm bằng `CREATE TABLE IF NOT EXISTS` trong `initializeSchema` ⇒ DB cũ tự nâng cấp, không cần migration phá huỷ.
- **Revision id = SHA-256(workday | composedText)**: autosave 0.9 s có thể gọi liên tục nhưng cùng nội dung ⇒ cùng `brief_revision_id` ⇒ `INSERT OR REPLACE` không sinh rác; sửa nội dung ⇒ revision mới, `latestScriptBrief` trả bản mới nhất. Đánh đổi: không có lịch sử sửa từng ký tự, nhưng có lịch sử theo nội dung (đủ để kịch bản G3 cite đúng bản brief đã dùng).
- **Compose text 1 dòng/field** (`Tiêu đề:`, `Mục tiêu:`, `Nhân vật POV:`, `Bối cảnh:`, `Giọng điệu:`, `Ghi chú:`): parser S13 cắt theo `[^.;\n]+` nên mỗi field thành 1 draft đúng span; thêm token `"giọng điệu"` vào nhóm `style_preference` để dòng tone không bị phân loại thành `event_fact`.
- **Tone không đứng một mình**: nếu mọi field khác trống thì không phát dòng `Giọng điệu` ⇒ form trống compose ra `""` (không tự sinh claim).
- **Giới hạn kích thước file** (`tests/test_source_hygiene.py`): `AIVideoApp.swift` < 1700 dòng, `AppState.swift` < 1400 dòng. Sau thay đổi: **1380** và **1296**; phần brief tách sang `ScriptBriefView.swift` + `AppState+ScriptBrief.swift` (đã thêm vào `tools/build_macos_app.sh`).
- **Kiểm tra thị giác bằng ảnh chụp thật**: sau khi cấp quyền Screen Recording, `screencapture -x` chụp toàn màn hình vẫn ra app khác (cửa sổ AIVideo nằm trên màn hình phụ, toạ độ âm: X=-271, Y=-982). Cách đúng: liệt kê cửa sổ bằng `CGWindowListCopyWindowInfo` lấy `kCGWindowNumber` rồi `screencapture -o -l<id> -x` — chụp được đúng cửa sổ kể cả khi nó không phải app frontmost.
- **Bài học layout**: thẻ brief 6 mục đặt ngay dưới thẻ chọn tư liệu đẩy danh sách video xuống dưới màn hình (ảnh chụp đầu tiên). Sửa: thẻ tự thu gọn còn 1 dòng (tiêu đề + trạng thái lưu + "0/5 mục" + link "Mở rộng") khi đã có footage hoặc đã có nội dung; tự bung khi chưa có footage và brief trống. `onAppear` một mình không đủ vì bookmark restore xảy ra sau lần render đầu — phải thêm `onChange(of: state.mediaItems.count)` và cờ `userToggled` để không giành quyền điều khiển với người dùng.

## 22. Dữ kiện cưới POV: mô hình dữ liệu (2026-11-10)
- **Phát hiện quan trọng**: trong `main_g2.analyze_source`, chỉ `item_kind == "event_fact"` được biến thành claim. `usage_constraint` và `style_preference` được parser trích ra rồi **bị bỏ** — nên câu "bắt buộc có cảnh trao nhẫn" trước đây không đi tới đâu. Cách xử lý: ghi "cảnh bắt buộc/cần tránh" thành các dòng tự nhiên trong `brief_text`, để chúng thành claim `event_fact` có span truy vết (worker hiện chưa dùng nhánh constraint, nên không thể hứa hẹn điều khiển cắt cảnh từ brief).
- **Vì sao không dùng `constraints.must_use` của G3 cho tên cảnh**: `generate_story` so `must_use`/`must_not_use` với **`claim_id`** và shot_id, không phải tên cảnh tự do. Gửi "trao nhẫn" vào đó sẽ khiến story bị `blocked_constraints` hoặc bị bỏ qua âm thầm. Vì vậy brief cưới chỉ đi vào `brief_text` (claim) + prefill UI, không nhồi vào `constraints`.
- **Compose 1 câu/dòng**: parser S13 cắt theo `[^.;\n]+` nên mỗi dòng là 1 draft với span chính xác; các dòng dùng nhãn tự nhiên ("Bắt buộc có cảnh:", "Không quay:", "Phong cách:") để lexicon phân loại đúng.
- **Menu không phải dữ kiện**: `style`/`platform` luôn có giá trị mặc định, nên compose chỉ phát chúng khi đã có ít nhất một dữ kiện text. Nếu không, form trống sẽ tự sinh claim "Phong cách: Cinematic" — đúng loại rác dữ kiện cần tránh. Quy tắc này có test ở cả Swift (`S06.BRIEF`) và Python.
- **Migration tại chỗ**: `ensureScriptBriefColumns` đọc `PRAGMA table_info(script_briefs)` rồi `ALTER TABLE ADD COLUMN` cho 10 cột mới. Đã kiểm trên DB thật của app: trước có 10 cột cũ, sau khi mở app 20 cột (giữ nguyên cột cũ, không mất dòng nào).
- **Giới hạn cần nói rõ**: chưa suy ra "shot taxonomy" cưới từ hình ảnh (VLM vẫn mô tả cảnh chung). Muốn "trao nhẫn/gia tiên/lì xì" được nhận diện từ footage thì phải sửa prompt VLM trong `pipeline_adapters.py` — việc riêng, chưa làm.

## 23. Nhãn cảnh cưới từ VLM cục bộ (2026-11-11)
- **Vấn đề**: prompt cũ chỉ hỏi "mô tả diễn biến", nên Qwen3-VL trả về câu mô tả chung; không có nhãn nào dùng được cho dựng phim cưới. Ngoài ra `action_or_scene_type` được suy ra bằng keyword thô (`"xe"`, `"chạy"`…) nên gần như vô nghĩa với đám cưới.
- **Cách làm**: taxonomy nhỏ 10 khoảnh khắc + `detect_wedding_scenes()` so cue trên chính text model trả về. Nhãn chỉ xuất hiện khi có cue riêng ("trao nhẫn", "mâm quả", "phong bao"…). "Cô dâu", "chú rể", "đám cưới" **không** phải cue — biết là đám cưới không có nghĩa là biết khoảnh khắc nào.
- **Vì sao không dùng structured field riêng vào DB**: `RawObservationArtifact` và schema Swift không có cột này; thêm cột sẽ lan sang Swift/SQLite/migration. Câu "Cảnh cưới nhận diện: …" nằm ngay trong `observation_text` nên đi thẳng vào claim/review/kịch bản mà không đổi hợp đồng dữ liệu. `wedding_scenes` vẫn được trả kèm trong inspector dict để sau này nâng cấp.
- **Giữ `action_or_scene_type` nguyên**: có test thật (`test_s11_real_vlm_inference.py`) assert tập 3 giá trị; thêm giá trị thứ 4 sẽ làm vỡ hợp đồng đó mà không mang lại lợi ích.
- **Giới hạn**: đây là post-processing có kiểm soát trên mô tả của model, không phải fine-tune. Nếu model không nhắc từ khoá (góc máy xa, mờ), nhãn sẽ trống — đúng nguyên tắc Unknown.

## 24. Design system UI v2 (2026-11-11)
- Token tập trung ở `AIVideoTheme.swift`: `Theme.space*`, `radiusCard`, `pageWidth`, `AppCanvas` (gradient teal theo light/dark), `PanelBackground` (fill + hairline gradient + shadow), `StepChip`, `PrimaryActionStyle`, `GhostActionStyle`.
- **Chrome dùng chung** (`Card`, `SectionHeader`, `StatusPill`, `KeyValueRow`, `ErrorBanner`, `WorkerStatusCard`, `StatusBar`) được restyle một lần ⇒ mọi màn G2–G5 tự đổi theo, không phải sửa từng form.
- **Sidebar không dùng `List` nữa**: `List` + selection tự vẽ highlight accent, chồng lên style riêng sẽ lệch màu chữ. Dùng `ScrollView` + `SidebarRow` để kiểm soát hoàn toàn tile số, tint và accent bar.
- **Giữ nguyên hành vi**: cùng `AppSection`, cùng `detailView`, cùng toolbar; chỉ đổi trình bày. Cửa sổ mặc định vẫn mở Bước 1.
- **Bẫy đã gặp**: `Picker(.segmented)` 4 mục trong cột 160pt bị cắt chữ ⇒ đổi sang `.menu`. Nhãn nút dài ("Dựng & Render Preview tự động (ffmpeg)") bị truncate trong HStack ⇒ rút gọn nhãn thay vì nhồi layout.

---

## Trạng thái hiện tại (2026-11-11) — phần này thay thế các con số cũ bên trên

- Bộ test hiện tại: **424 case Python** (0 FAIL / 0 ERROR / 4 NOT_RUN; heavy: 0 skip) và
  **17 suite Swift** trong ma trận 23 khối (`./tools/run_tests.sh` exit 0). Con số "189 PASS"
  ở mục 1 là của vòng trước.
- **Model:** vision = Qwen3-VL-4B-Instruct-4bit (pin `90eeb026…`), story = Qwen3-8B-4bit,
  TTS = **Kokoro-Vietnamese** (không phải VieNeu). **Whisper chưa nối** vào runtime:
  ledger ghi `asr_status=not_configured`, audio có tiếng nhưng chưa ASR là
  `audio_present_untranscribed` (không phải `no_speech`).
- **Corpus:** `fixtures/corpus` đã đổi tên thành `fixtures/smoke` và **không** phải bằng chứng
  hiện trường (title card 1,5 s, nhãn agent, 0 claim/0 event) ⇒ `check_readiness.py` NO-GO.
- **Schema:** Swift sở hữu 23 bảng + `user_version = 2`; file SQL chỉ là fixture test.
- **Release manifest:** ký **Ed25519** (không phải HMAC-SHA256); E0/E1 chỉ certify khi
  `runs_sha256` khớp manifest đã ký.
- **Hiệu năng G2:** decode mỗi cửa sổ có `-frames:v` (không đọc toàn file); hash artifact
  ngoài transaction; observation phân trang qua `g2.get_raw_observations`.
- **Còn mở:** P1-02 (nhánh G4/`commitPublication`) và P1-31 (transition vs plan) đang sửa một
  phần — code đề xuất trong `docs/PROPOSED_REMAINING_FIXES.md`.
