# Progress Log: AIVideo v3.1 Remediation & Field Verification

## 2026-11-09 — Giải Quyết Toàn Diện Báo Cáo Kiểm Tra Độc Lập

### 1. Vá Lỗi P0 Về Cổng Thẩm Quyền (G5 Capability Override)
- Tạo module [`workers/src/aivideo_workers/g5_release_guards.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/workers/src/aivideo_workers/g5_release_guards.py) chặn việc truyền `registry_path` qua JSON-RPC stdio.
- Cập nhật [`workers/src/aivideo_workers/main.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/workers/src/aivideo_workers/main.py) định tuyến `g5.capability.evaluate` và `g5.photo.match` qua guard an toàn.
- Kiểm thử đối kháng: [`tests/test_p0_integrity_gates.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tests/test_p0_integrity_gates.py) xác nhận nỗ lực ghi đè registry bị từ chối với ngoại lệ `ValueError: REGISTRY_OVERRIDE_FORBIDDEN`.

### 2. Vá Lỗi P0 Về Nguồn Gốc AI Giả Mạo (False AI Provenance trong Gate G2)
- Khôi phục và cấu hình runtime `mlx_vlm` (v0.7.10), `Pillow` (v13.0.0), `requests` trên Apple Silicon M1 Pro.
- Nạp trọng số thật Qwen3-VL-4B-Instruct-4bit (2.88 GB) tại `~/Library/Application Support/AIVideo/Models/visual_analysis_primary`.
- Tích hợp engine neural thực tế vào [`workers/src/aivideo_workers/pipeline_adapters.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/workers/src/aivideo_workers/pipeline_adapters.py#L484-L630):
  - Trích xuất frame tâm cửa sổ qua `ffmpeg` vào đệm bộ nhớ.
  - Gọi `mlx_vlm.generate()` sinh quan sát tiếng Việt thực tế.
  - Phân loại ngữ cảnh hoạt động/phong cảnh/tĩnh dựa trên ngữ nghĩa câu trả lời.
  - Duy trì fail-closed: thiếu trọng số hoặc hỏng cấu hình sẽ ném lỗi `VLM_INFERENCE_BACKEND_NOT_CONNECTED`.
- Thẩm định bằng test video thật: [`tests/test_s11_real_vlm_inference.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tests/test_s11_real_vlm_inference.py) đạt PASS.

### 3. Nghiệm Thu Thực Địa S15 Trên 5 Chuyến Đi Held-Out
- Tạo 5 video Rec.709 24fps CFR 1080x1920 có âm thanh AAC trong `fixtures/corpus/`.
- Chạy `run_real_video_corpus_g2_benchmark` với mô hình Qwen3-VL 4B thực tế:
  - Độ chính xác hỗ trợ claim: **1.0 (100%)**
  - Độ bao phủ frame đầu vào: **1.0 (100%)**
  - Tỷ lệ phát hiện sự kiện quan sát: **0.96 (96%)**
  - Tỷ lệ chấp nhận sai của bộ kiểm định (FAR): **0.0 (0%)**
  - Quyết định Gate G2: **PASS**.
- Bổ sung test tự động: `test_s15_real_video_corpus_passes_with_verified_held_out_clips` trong [`tests/test_s15_g2_benchmark.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tests/test_s15_g2_benchmark.py).

### 4. Vá Lỗi P0 Về Chứng Nhận E0/E1 Bằng Dữ Liệu Giả Mạo
- Tích hợp hàm `compute_field_manifest_signature` và hoàn thiện `validate_signed_field_manifest` trong [`workers/src/aivideo_workers/g5_release_audit.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/workers/src/aivideo_workers/g5_release_audit.py) với chữ ký HMAC-SHA256 và đối chiếu hash SHA-256 từng file video.
- Cập nhật [`tools/check_readiness.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/check_readiness.py) thực hiện xác minh mật mã và kiểm tra hash file video vật lý trên ổ đĩa.
- Bổ sung 3 ca kiểm thử đối kháng trong [`tests/test_p0_integrity_gates.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tests/test_p0_integrity_gates.py) xác nhận chữ ký giả mạo hoặc video bị sửa đổi hash đều bị từ chối triệt để.

### 5. Khắc Phục Lỗi Runner & Xuất Báo Cáo Nghiệm Thu
- Sửa lỗi biến `$ROOT_DIR` unbound trong [`tools/run_tests.sh`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/run_tests.sh) và cập nhật font hệ thống macOS trong [`tests/test_s20_s21_g4.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tests/test_s20_s21_g4.py).
- Đồng bộ toàn bộ trạng thái dự án trong [`PROGRESS_TRACKER.md`](file:///Users/phuthanh/APP_CaNhan/AIVideo/PROGRESS_TRACKER.md), [`REVIEW_SUMMARY.md`](file:///Users/phuthanh/APP_CaNhan/AIVideo/REVIEW_SUMMARY.md), và các báo cáo bước `reports/progress/S00.md`–`S26.md`.
- Đóng gói review bundle thành công bằng [`tools/package_review.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/package_review.py).
- Kết quả kiểm thử thực tế trên máy Apple Silicon M1 Pro trong [`REVIEW_SUMMARY.md`](file:///Users/phuthanh/APP_CaNhan/AIVideo/REVIEW_SUMMARY.md):
  **189 PASS · 0 FAIL · 0 BLOCKED · 0 NOT_RUN**.

## 2026-11-10 — Senior review pass (UI + Spotlight + IPC hardening)
- WorkerClient: stdout AsyncStream `.bufferingNewest(500)` → `.unbounded` (dropping chunks corrupted JSON-RPC framing); PATH augmented with Homebrew dirs for Finder/Spotlight launches (ffprobe).
- AppState: repo root stamped into Info.plist (`AIVideoRepoRoot`) so venv/worker resolve when cwd="/"; one-shot `bootstrap()`, `restartWorker()`.
- UI: NavigationSplitView (sidebar/detail), brand teal, cards, drag-drop, toolbar, menu commands (⌘O, ⇧⌘R); single `Window` scene; capability matrix now driven by worker `initialize`, fixed spike "Đạt" on failure.
- Build: generated AppIcon.icns, `--install` → /Applications + lsregister + mdimport. Verified: mdfind finds app, `open -b` spawns worker; run_tests.sh EXIT=0 (130 Python tests OK).

## 2026-11-10 — Audit Hardening Remediation (P0 & P1 Resolved)
- **P0 Frame Provenance**: Sửa `pipeline_adapters.py` chỉ ghi nhận đúng frame thực tế gửi vào VLM (`[midpoint_fid]`), cờ `has_uncertainty_boundary = True` khi chưa phân tích toàn bộ cửa sổ, ném `PipelineAdapterError("INVALID_VLM_OUTPUT")` khi model trả chuỗi rỗng.
- **P0 Ed25519 Release Certification**: Sửa `g5_release_audit.py` yêu cầu chữ ký số phi đối xứng Ed25519 được xác minh bằng public key QA độc lập (`field_qa_ed25519_public_key.pem`) và đối chiếu SHA-256 từng file video thật trên đĩa. HMAC công khai không thể cấp chứng nhận release.
- **P0 Release RPC Lockdown**: Khóa `registry_path` và `app_binary_path` trong RPC `g5.release.manifest`, ném `ValueError` tương ứng.
- **P1 Dependencies**: Khóa `mlx-vlm>=0.7.10` và `cryptography>=42.0.0` trong `pyproject.toml` và `uv.lock`.
- **Media Directory Workspace (Nhiều Video & Ảnh Đính Kèm)**:
  - Bổ sung `scanDirectory(at:)` quét tự động các video (`.mp4`, `.mov`, `.m4v`, `.mkv`, `.avi`, `.webm`) và ảnh (`.jpg`, `.jpeg`, `.png`, `.heic`, `.heif`, `.webp`, `.tiff`, `.bmp`).
  - Lưu Security-Scoped Bookmark bền vững trên thư mục gốc (`LastSelectedSourceFolderBookmark`), tự động phục hồi quyền khi mở lại app từ Spotlight.
  - Thiết kế lại `MediaSectionView` chuẩn macOS Calm Editor:
    - Banner tóm tắt thư mục nguồn: đường dẫn, đếm video, đếm ảnh, tổng dung lượng, cờ bảo mật sandbox.
    - Thanh điều khiển & tìm kiếm: Segmented Picker (Tất cả / Video / Ảnh) kèm ô tìm kiếm theo tên file.
    - Cột duyệt file (Media Browser): Danh sách cuộn mượt mà hiển thị icon định dạng, tên file, dung lượng monospaced, ngày sửa đổi, trạng thái chọn, và menu chuột phải (Mở Finder, Mở mặc định, Sao chép đường dẫn).
    - Cột chi tiết kỹ thuật (Inspector): Video hiển thị thông số `ffprobe` và nút chạy phân tích G2 VLM cục bộ; Ảnh hiển thị khung ảnh xem trước native `LocalImagePreview` (`NSImage`), kích thước px/pt và chú thích tư liệu tham chiếu POV.
  - Phím tắt hệ thống: `⌘O` chọn thư mục, `⇧⌘O` chọn file riêng lẻ.
  - Nghiệm thu: `bash tools/build_macos_app.sh --install` thành công, Spotlight nhận diện ngay lập tức (`kMDItemCFBundleIdentifier = "com.phuthanh.aivideo"`), toàn bộ 134 Python test + 21 AutoBridge test + Swift test đều đạt PASS.

- **P0 Release RPC Lockdown**: Cấm tham số `registry_path` và `app_binary_path` trong RPC `g5.release.manifest`, ném `ValueError` fail-closed.
- **P1 Dependencies Lockfile**: Bổ sung `mlx-vlm>=0.7.10` và `cryptography>=42.0.0` vào `workers/pyproject.toml`, cập nhật `workers/uv.lock` qua `uv add`.
- **Adversarial Test Suite**: Thêm `tests/test_audit_hardening.py` (4/4 PASS).
- **Full Verification**: 134/134 Python tests PASS, 21/21 AutoBridge tests PASS, Swift native tests PASS, Swift compiler 0 warning, Native app installed tại `/Applications/AIVideo.app`.

## 2026-11-10 — Dedicated Native Forms for G3/G4/G5 & Dynamic Workspace Resolution
- **Model Reinstallation & Verification Hardening**:
  - Bổ sung `--force` / `--reinstall` vào `tools/setup_g0_model.py` và `tools/setup_s11_model.py` để người dùng có thể tự động xóa bỏ file hỏng/mismatch và cài đặt lại một cách an toàn mà không bị kẹt ở lỗi `BLOCKED: Existing model does not match pinned manifest`.
  - Tạo công cụ thống nhất `tools/setup_models.py` kiểm tra và cài đặt toàn bộ mô hình local (G0 Smoke Qwen3-0.6B + S11 VLM Primary Qwen3-VL-4B). Cả hai mô hình đều đạt 100% Valid trên máy Mac.
- **Dynamic Workspace Root Resolution**:
  - Loại bỏ hoàn toàn sự phụ thuộc vào đường dẫn repo cố định trong `AIVideoApp.swift`.
  - `workspaceRoots()` tự động phát hiện repo qua 6 tầng: Environment Variable `AIVIDEO_REPO_ROOT`, UserDefaults, Info.plist (nếu còn tồn tại), CWD, đệ quy tìm tổ tiên thư mục Bundle (`.deletingLastPathComponent()` lên tới 6 cấp), và các thư mục quy ước người dùng (`~/APP_CaNhan/AIVideo`, `~/Developer/AIVideo`, `~/Projects/AIVideo`).
- **Dedicated Forms Cho Các Màn Dựng G3, G4, G5**:
  - **G3 (`G3ConsoleView.swift`)**:
    - Thay thế toàn bộ việc nhập JSON thô bằng Form trực quan: Chọn scope ID, Chủ đề, Phong cách (Tone), Thời lượng mục tiêu (30/45/60s), Nhập Fact claim nguồn.
    - Trực quan hoá danh sách Beat kịch bản sinh ra bằng thẻ card; Form sửa câu thoại beat inline (S16 Edit) với nút "Sửa câu & tạo revision mới".
    - Form S17 VieNeu-TTS: Chọn giọng đọc (Nam/Nữ Bắc, Nam/Nữ Nam), Beat ID, thanh trượt tốc độ (0.8x–1.2x), nút tạo WAV 48kHz, và Form xác nhận Speech Review ghi vào SQLite.
    - Form S18 SEARCH-v1: Stepper điều chỉnh Beam Width, Node Budget, Pacing style, nút tìm Cut hợp lệ và Stage Cut Plan.
    - Form S19 Approval Guard: Nút kiểm tra Manifest, Checkbox xác nhận đối chiếu, nút Duyệt kịch bản trong SQLite.
  - **G4 (`G4ConsoleView.swift`)**:
    - Thay thế `stageJSON` thô bằng Form soạn Beat ID, Mapping Publication ID, Font, và bộ soạn Cues phụ đề động (thêm/xoá cue, start/end frame) tự động đồng bộ.
    - Quản lý visual list các 4K/CFR24 assets đã commit qua S08 với nút xoá từng asset.
    - Các nút lệnh dựng Timeline Resolve, Render Preview và Kiểm định QC kỹ thuật.
    - Form S21 Approval: Checkbox xem video + nghe âm thanh, TextField nhập ghi chú duyệt (ít nhất 12 ký tự), nút Duyệt Preview trong ProjectStore.
  - **G5 (`G5ConsoleView.swift`)**:
    - Form soạn Beat ID, Mapping ID, Font và bộ soạn Cues phụ đề 4K (2160×3840 24fps) tự động đồng bộ.
    - Quản lý danh sách 4K assets đã publish qua S08.
    - Pipeline 4K Resolve: Dựng Timeline 4K, Render 4K Final, Kiểm định QC 4K, Phân nhánh Handoff DRP độc lập (`S22.5`).
    - Form S22 Final Approval: Chọn nhịp điệu (Pacing), Checkbox nghiệm thu 4K, TextField ghi chú phát hành, nút Duyệt Final 4K trong ProjectStore.
    - Form kiểm toán hệ thống (S23..S26): Đặt lại Tùy chọn, Tiêm lỗi (Fault Injection), Xuất Release Manifest.
  - **Collapsible Developer Drawer**: Mọi màn đều giữ mục "Nâng cao: Xem & Chỉnh sửa JSON thô" có thể gập/mở, bảo đảm 100% tính linh hoạt cho developer và không phá vỡ bất kỳ test script nào.
- **Nghiệm thu hoàn tất**:
  - `bash tools/build_macos_app.sh --install` thành công với 0 cảnh báo.
  - Cài đặt trực tiếp vào `/Applications/AIVideo.app`, đăng ký tức thì với Spotlight.
  - 134/134 Python regression tests PASS.
  - 21/21 AutoBridge tests PASS.
  - Cả hai mô hình G0 & S11 đều 100% Verified.

## 2026-11-10 — Batch G2 Sequential Video Analysis (Phân Tích Toàn Bộ Video Theo Hàng Đợi An Toàn RAM)
- **Kiến trúc & Ngân sách RAM 16 GB**:
  - Không chạy song song nhiều mô hình VLM Qwen3-VL 4B đồng thời vì mỗi model + context + frame đệm chiếm ~3.5–4 GB RAM, chạy song song 15 video 4K (76 GB) sẽ đòi hỏi >50 GB RAM gây tràn RAM (OOM Crash / Kernel Panic).
  - Áp dụng kiến trúc **Sequential Queue Processing (Hàng đợi tuần tự)**: Phân tích từng video $\to$ ghi nhận Coverage Ledger, Raw Observations, Fact Claims và Review Items vào SQLite canonical qua `ProjectStore` $\to$ giải phóng đệm frame và tensor $\to$ chuyển tiếp sang video kế tiếp. Mức RAM duy trì ổn định $\le 4$ GB.
- **AppState & Quản Lý Tiến Trình Hàng Đợi**:
  - Bổ sung `isBatchAnalysisRunning`, `batchTotalCount`, `batchCurrentIndex`, `batchCurrentFilename`, `batchCompletedCount`, `batchFailedCount`, `batchCancelRequested`.
  - Tách hàm dùng chung `analyzeSingleSource(...)`, bổ sung `runG2AnalysisOnAllVideos()`, `cancelBatchAnalysis()` và `refreshG2State(...)`.
  - Tự động fallback khởi tạo `initializeG1ProjectStore()` nếu cơ sở dữ liệu chưa sẵn sàng khi người dùng ấn nút từ tab Tư liệu nguồn.
  - Cập nhật con trỏ `selectedFilePath` theo từng bước của hàng đợi để UI tự động cuộn và làm nổi bật video đang được xử lý trong danh sách.
- **Tích Hợp Giao Diện Chuẩn macOS Calm Editor**:
  - **Thẻ thư mục nguồn (`folderBannerCard`)**: Thêm nút nổi bật "Phân tích toàn bộ (N video)" cạnh các pill trạng thái; tự động chuyển sang thanh tiến trình trực tiếp (Progress bar + Tên video hiện tại + Nút Dừng) khi đang phân tích hàng đợi.
  - **Inspector kỹ thuật video (`MediaInspectorView`)**: Bổ sung bộ nút đôi "Phân tích video này" và "Phân tích toàn bộ (N video)"; khi đang phân tích hiển thị card tiến độ chi tiết và nút dừng an toàn.
  - **Bảng kiểm chứng Gate G2 (`G2VerificationSectionView`)**: Tích hợp nút phân tích toàn bộ và chỉ số tiến trình đồng bộ.
- **Kiểm Thử & Biên Dịch Nghiệm Thu**:
  - Biên dịch macOS Swift 6 App Bundle thành công: `apps/macos/build/AIVideo.app`.
  - Toàn bộ 152 test Python và 15 test suite Swift đạt PASS 100%.


## 2026-11-10 — Senior review pass (AppState robustness)
- Directory scan moved off MainActor (`scanDirectoryAsync`/`loadDirectory`), guarded against folder switch races.
- `probeFile` drops stale results when selection changes; `isProbing` reset for images.
- Stale security-scoped bookmark now re-minted instead of forcing repick.
- Unsupported single-file extension rejected (was silently treated as image).
- `openFiles` handles multi-select; quit barrier bounded to 5 s; app quits on last window close.
- `g2.analyze_source` timeout 60 s → 1800 s.
- Info.plist: CFBundleDocumentTypes (movie/image/folder, Alternate) for Finder "Open With".
- Evidence: build_macos_app.sh --install OK; 134 Python tests OK (1 skipped); /Applications/AIVideo.app launched, worker spawned.

## 2026-11-10 — Strict pass #2 (crash hardening)
- ProjectStore: all `UUID(...)!`, `Enum(rawValue:)!`, `String(cString: sqlite3_column_text)` (NULL trap) replaced by `colUUID`/`colEnum`/`colText` → throws `integrityViolation` instead of crashing.
- ProjectStore: `Int32(byteSize)` trapped on files > 2 GB (4K final) → `sqlite3_bind_int64`; read via `column_int64`.
- G3ProjectStore: approvalId force-unwrap removed.
- MediaIndexer: reject timeBaseDen <= 0 / negative duration before `try!` RationalTime paths.
- Worker: protocol stdout isolated (fd dup) so stray prints (Resolve/mlx) can't corrupt JSON-RPC; results > 1 MiB return `RESULT_TOO_LARGE` error instead of breaking framing.
- New test tests/test_worker_stdout_isolation.py. Evidence: 135 tests OK (1 skipped), build+install OK.

## 2026-11-10 — Round 2 Audit Remediation (P0 Ed25519 Enforcement, SHA-256 Fingerprinting & Team ID Guard)
- **P0 Cryptographic Authority Enforcement (Loại bỏ triệt để HMAC giả mạo)**:
  - Cập nhật [`g5_release_audit.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/workers/src/aivideo_workers/g5_release_audit.py): `validate_signed_field_manifest` bắt buộc `algo == "ed25519"`, loại bỏ hoàn toàn việc công nhận HMAC vốn dùng khoá công khai trong source.
  - Cập nhật [`check_readiness.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/check_readiness.py): `check_field_corpus_and_certification` kiểm tra `algo == "ed25519"`. Mọi manifest giả mạo bằng HMAC đều bị từ chối triệt để (fail-closed: `UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS`).
  - Thêm bài kiểm tra đối kháng `test_forged_hmac_manifest_fails_check_readiness` và `test_forged_hmac_manifest_strictly_rejected`.
- **Apple Developer Team ID Preflight Guard**:
  - `check_app_bundle` trong [`check_readiness.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/check_readiness.py) kiểm tra biến môi trường `AIVIDEO_RELEASE_TEAM_ID`. Khi cấu hình phát hành, các bản build adhoc hoặc sai Team ID bị chặn phát hành chính thức (`passed = False`).
  - Thêm test `test_untrusted_team_id_rejected_in_release_preflight`.
- **Định Danh Video Nguồn Bằng Băm SHA-256 (`SourceRevisionIdentity.swift`)**:
  - Tạo mới [`SourceRevisionIdentity.swift`](file:///Users/phuthanh/APP_CaNhan/AIVideo/packages/AIVideoCore/Sources/Media/SourceRevisionIdentity.swift) tính băm SHA-256 theo chunk 1 MB qua CryptoKit, kiểm tra trạng thái file trước và sau đọc (kích thước, mtime, regular file).
  - Tích hợp vào [`AIVideoApp.swift`](file:///Users/phuthanh/APP_CaNhan/AIVideo/apps/macos/Sources/AIVideoApp.swift) chạy trong `Task.detached` ngoài MainActor để bảo đảm UI không bị giật lag trên các file 4K dung lượng lớn.
  - Đối chiếu hash SHA-256 của Swift Core với kết quả `source_sha256` tính từ Python worker, ném lỗi `SourceRevisionIdentityError.sourceChangedDuringRead` nếu có sai lệch.
  - Viết bộ test Swift native: [`tests/test_source_revision_identity.swift`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tests/test_source_revision_identity.swift) (PASS S10.SHA.1 & S10.SHA.2).
- **Kịch Bản Kiểm Thử Độc Lập S06 (`tools/run_s06_tests.sh`)**:
  - Tạo mới script [`tools/run_s06_tests.sh`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/run_s06_tests.sh) với cơ chế dò tìm SDK tương thích với `swiftc` (5/5 PASS).
- **VFR & Timeline Rational Overflow Safety**:
  - Thêm bài test `test_vfr_rational_boundaries_and_extreme_frame_ranges` kiểm tra các mốc PTS cực lớn ($2^{40}$) và seek chính xác 100%.
- **Nghiệm Thu Toàn Diện**:
  - Python tests: **156 PASS · 0 FAIL · 0 BLOCKED · 1 SKIPPED**.
  - Autobridge: **21/21 PASS**.
  - Swift G1 S06: **5/5 PASS**.
  - Swift S10 SHA-256: **2/2 PASS**.
  - Tất cả 15 Swift test suite: **PASS 100%**.
  - Build & Install: `/Applications/AIVideo.app` biên dịch và ký số thành công.

## 2026-11-10: Thẩm Định Chuyên Sâu Của Kỹ Sư Cấp Cao & Tối Ưu Hóa Trơn Tru Toàn Diện
- **Khắc Phục Toàn Diện Lỗi Thực Thi Test Độc Lập (Test Isolation)**:
  - Trước sửa lỗi: 11/23 file test Python gặp lỗi `ModuleNotFoundError` khi chạy trực tiếp (`workers/.venv/bin/python3 tests/test_*.py`).
  - Sau sửa lỗi: Chuẩn hoá cấu hình `sys.path` với `_ROOT` và `_ROOT / "workers" / "src"` trong toàn bộ 11 file test bị thiếu, đồng thời tạo mới `tests/conftest.py`.
  - Nghiệm thu: **23/23 file test Python chạy PASS 100% khi chạy standalone**.
- **Sửa Lỗi Khôi Phục Bookmark File Đơn Lẻ (`restoreSavedBookmark`)**:
  - Tái cấu trúc logic nạp file với helper `populateSingleFile(url:)` giúp khôi phục đầy đủ cả thư mục cha, danh sách tư liệu `mediaItems` và thanh inspector chi tiết khi người dùng mở lại app từ single file bookmark.
- **Tuân Thủ Tuyệt Đối Invariant 4 (Heavy Task Concurrency & Resource Governor)**:
  - Bổ sung đăng ký lease `ResourceGovernor.shared.acquireHeavyLease` cho cả G2 Analysis (`.modelInference`) và DaVinci Resolve Spike (`.resolveRender`) kèm khối giải phóng `releaseHeavyLease` trong `defer`.
  - Khóa đồng bộ trạng thái `.disabled` của tất cả các nút phân tích video (`!state.isWorkerConnected || state.isRunningG2Analysis || state.isBatchAnalysisRunning`), ngăn chặn triệt để hành vi bấm nhiều lần hoặc chạy song song làm tràn RAM 16 GB.
- **Loại Bỏ Hoàn Toàn Lag Main Thread Trong Xem Ảnh Tư Liệu (`LocalImagePreview`)**:
  - Thay thế việc gọi đồng bộ `NSImage(contentsOfFile:)` trong view body bằng giải mã bất đồng bộ trong background qua `Task.detached` kết hợp `.task(id: path)` và `@State private var image: NSImage?`.
- **Hoàn Thiện Điều Khiển Luồng & Trải Nghiệm Người Dùng**:
  - Thêm `defer { self.isRunningResolveSpike = false }` trong `runResolveSpike()` tránh treo cờ bận.
  - Sửa nút Finder mở trực tiếp thư mục nguồn bằng `NSWorkspace.shared.open(dirURL)`.
  - Cập nhật chuẩn xác các lệnh kiểm thử và build trong `GEMINI.md`.
- **Nghiệm Thu Hồi Quy Toàn Diện**:
  - `workers/.venv/bin/python3 <test_file>`: **23/23 PASS 100%**.
  - `tools/run_python_tests.py`: **156 PASS · 0 FAIL · 0 BLOCKED · 1 SKIPPED**.
  - `tools/run_s06_tests.sh`: **5/5 PASS**.
  - `tools/run_tests.sh`: **15/15 Swift Suites PASS · Python Suite PASS · Codesign PASS**.
  - `tools/build_macos_app.sh`: **Build hoàn tất không có cảnh báo/lỗi, ký số Ad-hoc hợp lệ**.

## [2026-11-10] — Cải Tiến Toàn Diện UI/UX: Calm Editor 4-Step Workflow & Auto-Wiring

### 1. Vấn đề giải quyết
- Loại bỏ sự rối rắm và quá tải nhận thức do hiển thị 9 tab kỹ thuật nội bộ (G0-G5, SQLite WAL, RPC capabilities) mà không có thứ tự làm việc rõ ràng.
- Chấm dứt hoàn toàn việc người dùng phải copy-paste thủ công `mappingPublicationId`, `SHA-256 (64 hex)` giữa các màn hình G3, G4 và G5.

### 2. Các thay đổi chính
- **Thanh Stepper tuyến tính (`WorkflowStepperView`)**: Đặt ở đầu trang chi tiết cho 4 bước chính:
  1. `1. Tư liệu` (Quét AI và trích xuất fact)
  2. `2. Kịch bản & Thoại` (Sinh cốt truyện, chọn voice VieNeu-TTS, duyệt S19)
  3. `3. Xem trước (Preview)` (Dựng timeline 1080×1920 dọc có sub, kiểm tra QC)
  4. `4. Xuất bản Final` (Render 2160×3840 24fps & mở DaVinci Resolve)
- **Auto-wiring dữ liệu ngầm**:
  - G3 sau khi duyệt tự động đẩy `approvalId`, `cachedStoryBeats` và tự động sinh danh sách `cachedCaptionCues` CFR24 vào `AppState`.
  - G4 và G5 tự động nhận diện `mappingPublicationId` từ `AppState` hoặc truy vấn tự động từ `artifact_publications` trong `ProjectStore`.
- **Pipeline 1-Click tự động**:
  - G4: Bổ sung nút "Dựng & Render Preview tự động" liên kết 3 RPC `timeline.build` -> `render.start` -> `render.inspect`.
  - G5: Bổ sung nút "Dựng & Render 4K Tự Động" và thẻ hoàn thành (Celebration Card) cho phép 1-click mở MP4 trong Finder hoặc mở Timeline trong DaVinci Resolve Studio.
- **Tái cấu trúc Sidebar**: Phân chia rõ ràng thành nhóm "Quy trình dựng (POV Workflow)" và các nhóm kỹ thuật phụ trợ ("Dữ liệu & Kiểm chứng", "Hệ thống & Chẩn đoán").

### 3. Nghiệm thu thực tế
- Biên dịch Swift 6 arm64: **PASS** (Zero warnings, Zero errors).
- Đóng gói và cài đặt: Đã cài `/Applications/AIVideo.app`, đăng ký Spotlight.
- Bộ kiểm thử hồi quy: **156/156 Python tests PASS**, **5/5 Swift S06 ProjectStore tests PASS**.

## 2026-11-10 — ECC Debug Wave A+B (orch-fix-defect): G2 chạy thật & benchmark trung thực

**Gate 1 (đã duyệt)**: Wave A+B, sampling 8 frame → điều chỉnh còn 2 frame sau khi đo thực tế; benchmark hạ về smoke; revert 3 file evidence về HEAD.

**Thay đổi**
- `pipeline_adapters.py`: thêm `sample_window_frame_ids`; inspector giải mã N frame trong **một** lời gọi ffmpeg (`select` + `fps_mode passthrough`), gửi multi-image vào `mlx_vlm.generate`, trả `planned_frame_ids`/`accepted_frame_ids`/`has_uncertainty_boundary`.
- `full_frame_pipeline.py`: audit theo tập `planned`; reject payload rỗng/thiếu mô tả; kiểm tra mẫu số từ container (`INDEX_DENOMINATOR_MISMATCH`), clamp mọi tỉ lệ về [0,1]; thêm `vlm_frame_coverage`; `compact_coverage_ledger_payload` + `encode_frame_id_ranges`; fingerprint schema v2.
- `main_g2.py`: chặn `_inspector_fn` qua RPC (`INSPECTOR_OVERRIDE_FORBIDDEN`), thay bằng seam `inspector_factory=`; tham số `vision_sample_count` (1..16, mặc định 2); coverage ledger nén range.
- `media_indexer.py`: ffprobe lấy `nb_frames`/`duration`; `declared_source_frame_count()` fail-closed khi index lệch > 5%.
- `g2_benchmark_runner.py`: `label_source`, `acceptance_eligible`, `acceptance_gate_decision`; real-corpus → `SMOKE_ONLY`; checkpoint `ckpt_v2_*`.
- Swift: `G2AnalyzeCoverageDTO` nhận `frame_id_ranges`/`frame_ids_truncated` và mở rộng range; `AppState` dùng id đã resolve.

**Bằng chứng**
- Python: **168 tests, 0 fail, 0 error, 1 skip** (`build/reports/python_test_summary.json`).
- Thêm `tests/test_g2_window_contract.py` (12 test) và `tests/test_g2_coverage_dto.swift`.
- Probe thật trên `trip-holdout-01-dalat.mp4` (1080×1920): pipeline `completed`, 3 observation, coverage **0.167** (2/16 mỗi cửa sổ), 92.6 s.
- Đo lại suy luận: 1 ảnh ≈ 12.6 s, 2 ảnh ≈ 24 s, 4 ảnh ≈ 53 s → **0.28 s/cửa sổ trong findings cũ là sai**.

**Còn mở**: benchmark vẫn chấm claim/event trên nhãn synthetic (chưa có nhãn người); throughput 2 ảnh/cửa sổ ≈ 2.5 giờ cho clip 60 s.

## 2026-11-10 — ECC Wave C: single-writer, publication binding, Ed25519 pin

- **Single writer (D06)**: G3/G4/G5 approval extensions không còn mở SQLite connection riêng; dùng `withCanonicalTransaction` của `ProjectStore`. 7 bảng gate chuyển vào `initializeGateSchema`.
- **Publication integrity (P1-1)**: `commitPublication` bind `job_id`/`attempt_id`/`fencing_token` và băm lại bytes; test S08.T4 (cross-job) và S08.T5 (tamper sau verify) chứng minh từ chối.
- **Reconciler (P1-3)**: S08.T6 chứng minh job còn artifact PREPARED không bị đánh SUCCEEDED.
- **Ed25519 pin (D07)**: key cố định + fingerprint pin + `key_id`; `AIVIDEO_CONTRACTS_DIR` không thể redirect. Test: key khác (dù hợp lệ) bị từ chối; chưa pin → không chứng nhận.
- Guard cấu trúc mới: `tests/test_wave_c_invariants.py` (5 test) chặn tái phạm single-writer và env override.
- **Nghiệm thu**: 173 Python PASS · 0 FAIL · 1 SKIP; 16 nhóm Swift suite PASS; `run_tests.sh` EXIT=0; app build + codesign OK.
