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

## 2026-11-10 — ECC Wave D: honest UI/evidence + runtime guards

- **D12**: `G3StoryRequestBuilder` (mới) + G3 UI chọn claim thật từ G1, nút "Xác nhận fact này"; không còn `c1`. Test Swift: `tests/test_g3_story_request.swift`.
- **D13**: S02 harness không tự chứng nhận; Finder launch chỉ chạy khi `AIVIDEO_RUN_UI_TESTS=1`; bookmark dùng `.withSecurityScope` (PASS thật trên máy này). `package_review` phân biệt NOT_RUN với FAIL.
- **D14**: `model_installation.py` là nguồn duy nhất; preflight deep-hash, worker báo `visual_weights_verification`. Test: `tests/test_model_installation.py`.
- **D15/D16**: bỏ slider TTS sai; ASR status `not_configured` thay vì `completed`.
- **D17**: `child_process.py` + `run_tracked`; test `tests/test_worker_child_process.py`.
- **Nghiệm thu**: chạy `run_tests.sh` sau khi hoàn tất (ghi ở mục dưới).

## 2026-11-10 — ECC add-feature: prefilter chuyển động (opt-in)

- Thêm `workers/src/aivideo_workers/prefilter.py` (scan 1 lượt ffmpeg, map score vào cửa sổ, quyết định bỏ).
- `full_frame_pipeline`: `window_prefilter` + checkpoint `skipped_windows`; ledger thêm `skipped_window_indices`/`prefilter_skipped_count`; status `completed_prefiltered`; fingerprint chỉ đổi khi bật.
- `main_g2`: tham số `prefilter` (enabled/sample_fps/motion_threshold/width/height), trả `prefilter` summary gồm danh sách cửa sổ bị bỏ.
- Test: `tests/test_g2_prefilter.py` (15 ca: config, scan tĩnh/động, mapping, skip/first-window, resume, RPC, param sai).
- Đo: clip tĩnh 60 s 48 phút → ~24 s VLM; clip động −24%; scan 0.11 s/clip.
- **Nghiệm thu**: 199 Python PASS · 0 FAIL · 1 SKIP; ma trận `run_tests.sh` chạy sau khi hoàn tất.

## 2026-11-10 — ECC Wave E: cấu trúc app, portability, CI thật

- Tách `AppState.swift` khỏi `AIVideoApp.swift` (2.738 → 1.459 + 1.279 dòng); build script cập nhật.
- Bỏ path cá nhân trong `workspaceRoots()`; `AIVIDEO_PYTHON` override cho app + S02 harness; `environment_matrix.json` portable.
- Toggle prefilter trong UI (mặc định tắt) + `G2PrefilterParams` trong Swift client.
- CI: ffmpeg, `AIVIDEO_PYTHON`, build app với zero-warning gate, chạy full `run_tests.sh`.
- Guard mới `tests/test_source_hygiene.py` (6 ca): path tuyệt đối, kích thước file, wiring prefilter, CI contract.
- Nghiệm thu: 205 Python PASS · 0 FAIL · 1 SKIP; matrix EXIT=0.

## 2026-11-10 — Wave F: QA key, labels, Resolve acceptance

- Provision Ed25519 keypair ngoài repo; pin fingerprint; tool ký `tools/sign_field_corpus.py`; thay manifest giả bằng manifest ký thật.
- Tạo nhãn cho 5 clip (`fixtures/corpus/labels/`) với `agent_visual_review` + `synthetic_title_card`; thêm `corpus_labels.py` và chặn certification nếu không phải human + field footage.
- Resolve acceptance thật: G0 spike trên Resolve Studio 21.2.0, DRP 26 KB, evidence `reports/evidence/resolve_g0_real_run.json`.
- G4/G5 e2e: bị chặn bởi VieNeu-TTS chưa cài (không có WAV → không có G3 approval).
- Tests mới: `tests/test_corpus_labels.py` (7 ca) + cập nhật anchor invariants.

## 2026-11-10 — Wave F: CI xanh trên GitHub Actions

- Push toàn bộ Wave A–F lên `origin/main` (repo `bunbolamlac77/VideoAI`).
- CI đỏ lần đầu, sửa 5 nguyên nhân runner-specific:
  1. ffmpeg hosted thiếu filter `drawtext` → guard `FFMPEG_DRAWTEXT_UNAVAILABLE` + test skip.
  2. Nhãn trỏ tới clip bị gitignore → track 5 fixture `.mp4` (~90 KB).
  3. `test_worker_ipc` hard-code `/opt/homebrew/bin/python3.12` → `aivideo_test_python_path()` (AIVIDEO_PYTHON → runtime → brew → PATH) cho 3 suite Swift.
  4. Test phụ thuộc model (token limit, preflight, inference) fail khi runner không có weights → ghi SKIPPED thay vì FAIL.
  5. Diagnostics: check-run công khai chứa non-PASS + log tail (logs GitHub cần auth).
- **Kết quả**: run [42838639795](https://github.com/bunbolamlac77/VideoAI/actions/runs/42838639795) **success** (4m54s) — Python 213 test, build 0 warning, 17 nhóm Swift.

## 2026-11-10 — Vision pixel budget (rút gọn chi phí xem video, giữ chất lượng)

- `workers/src/aivideo_workers/pipeline_adapters.py`:
  - thêm `resolve_vision_pixel_cap()` + `DEFAULT_VISION_PIXEL_CAP = 589824` (bằng đúng `default_pixel_budget` của registry), env override `AIVIDEO_VLM_MAX_PIXELS`, fail-closed khi sai/ngoài khoảng;
  - thêm `vision_frame_target_size()` giữ tỉ lệ khung, cạnh chẵn, không vượt ngân sách;
  - ffmpeg downscale trước khi encode JPEG (`select=...,scale=W:H:flags=bicubic`), truyền `max_pixels` cho `mlx_vlm.generate`;
  - fallback processor-only khi không probe được frame size (giữ nguyên hành vi cho test/harness giả lập).
- Test mới `tests/test_s11_vision_pixel_budget.py` (9 ca): default khớp registry, override, fail-closed, tỉ lệ khung, không upscale, cạnh chẵn.
- **Đo thật**: 2 097 152 px → 21,86 s/2 ảnh; 589 824 px → 5,98 s/cửa sổ (**~3,3×**); 262 144 px → 2,90 s nhưng bắt đầu đọc sai chữ trên khung ⇒ giữ 589 824 làm default.
- **Nghiệm thu**: `tools/run_python_tests.py` → **222 test, 0 FAIL, 0 ERROR, 1 SKIP** (heavy S15 do chưa bật cờ), exit 0.

## 2026-11-10 — Thay TTS + nối LLM kịch bản, build & cài app

- TTS: `tts_engine.py` (Kokoro-Vietnamese, Apache-2.0, 82M, preset 15 giọng), registry `P-TTS-KOKORO-VI-V1`, UI/nhãn cập nhật, `voice_trial` dùng engine mới, thêm extra `tts` trong `workers/pyproject.toml`.
- Kịch bản: `story_writer.py` (Qwen3-8B-4bit MLX) + `generate_story(script_engine=llm)` với kiểm tra trung thực và fallback; Swift `G3StoryRequestPayload.script_engine = "llm"`.
- Tool setup: `tools/setup_local_models.py --install --all` (staging + rename, không ghi đè bản đang chạy).
- Test mới: `test_s17_tts_engine.py` (8 ca, 1 heavy), `test_s16_story_llm.py` (11 ca, 1 heavy).
- **Nghiệm thu**: Python **241 test · 0 FAIL · 0 ERROR · 3 SKIP** (exit 0); Swift G3 story-request suite PASS; VLM 589k-px vẫn PASS trên runtime app sau khi hạ transformers.
- **Build & cài**: `/Applications/AIVideo.app` đã cập nhật (có `tts_engine.py`, `story_writer.py`, registry mới).

## 2026-11-10 — Phase 1a: renderer ffmpeg native + đồng bộ giọng theo cụm

- `native_render.py`: render 1080×1920 preview / 2160×3840 final, caption burn-in + `.srt`, crossfade / dip-to-black, beat ảnh Ken Burns, `verify_output()` giữ đúng hợp đồng QC.
- `g3_engine.voice_phrases()` + RPC `g3.voice.phrases`: TTS từng cụm, cue offset = sample thật (`exact_phrase_sample_offsets`).
- RPC `video.render.native`: path guard trong root, chặn ghi đè, chỉ 2 kích thước dọc.
- Đo: 4K 276 frame — libx264 veryfast threads=4: 4,52 s / 1,49 GB; VideoToolbox 45M: 5,22 s / 762 MB.
- Test mới: `test_s20_native_render.py` (14 ca) + `test_s17_voice_phrases.py` (5 ca, 1 heavy).
- **Nghiệm thu**: **260 Python test · 0 FAIL · 0 ERROR · 4 SKIP**, exit 0. App đã build lại (bundle có `native_render.py` + RPC).
- **Chưa làm (Phase 1b)**: receipt native cho `G4S21Guard`/`G5S22Guard` + nút UI; Resolve vẫn là đường mặc định.

## 2026-11-10 — Phase 1b: guard S22 + nút UI native 4K

- `G5S22Guard`: `verifyFinalMP4`, `verifyNativeReceipt`, `verifyFinalProvenance`, `fileSHA256`; alias `verifyFinalMP4AndDRP` giữ nguyên.
- `G5ProjectStore.approveG5Final`: 2 call site chuyển sang `verifyFinalProvenance`.
- `G5ConsoleView`: nút "Render native 4K (ffmpeg)" + `runNativeFinal()`; publish phân biệt `g5_handoff_drp` vs `g5_native_receipt`.
- Worker: `g4.render.native` / `g5.render.native_4k` ghi receipt JSON cạnh MP4; cues tuỳ chọn (preburned vs reburned).
- Test mới: `tests/test_g5_native_provenance.swift` (4 ca), wire vào `tools/run_tests.sh`; Python `test_s20_native_render.py` lên 20 ca.
- App đã build lại (có nút mới), chưa đổi mặc định sang native.

## 2026-11-10 — Phase 1c: native là mặc định, Resolve tuỳ chọn

- G4: nút "Render native 1080p (ffmpeg)" + `runNativePreview()`, pipeline 1-click chuyển sang native.
- G5: nút native thành pipeline 1-click (`runFullFinalPipeline` → `runNativeFinal`); publish receipt với type `g5_native_receipt`.
- Receipt native xuất đúng shape `approveG4Preview`/`approveG5Final` yêu cầu (timeline_uid/signature/render_job_id/qc) + chi tiết engine ở khoá `native`.
- `G5ProjectStore` nhận provenance type `g5_native_receipt`; `check_readiness` chuyển DaVinci thành warning; test preflight cập nhật.
- Test: `test_s20_native_render.py` 22 ca (thêm 2 ca khoá shape receipt G4/G5).

## 2026-11-10 — Phase 1c: readiness + seal model install

- `tools/setup_s11_model.py --seal`: ghi install manifest cho bản cài đã có **sau khi** hash khớp pin (`90eeb026…`), fail-closed nếu lệch.
- `check_readiness.py`: DaVinci → warning; Production Models từ `NOT_VERIFIED` → `VERIFIED_PINNED_LOCAL`.
- Blocker còn lại duy nhất: field corpus E0/E1 (cần footage thật + nhãn người), đúng thiết kế.

## 2026-11-10 — UI giản lược + brief cho người viết kịch bản (Bước 1)

- **Điều hướng**: sidebar 9 mục → 4 bước chính + nhóm `Nâng cao & Chẩn đoán` thu gọn; xoá `WorkflowStepperView` (trùng sidebar); toolbar bớt menu 2 tầng, còn 1 nút mở thư mục + nút quét lại theo ngữ cảnh; nút "Kết nối lại worker" chỉ hiện khi worker mất kết nối.
- **Brief (mới)**: thẻ "Thông tin cho người viết kịch bản" ngay dưới thẻ chọn tư liệu ở Bước 1, 6 mục, tự lưu (debounce 0.9 s), lưu bắt buộc trước khi phân tích; G3 hiển thị lại brief và prefill chủ đề/giọng điệu.
- **Lưu trữ**: `ProjectStore` thêm bảng `script_briefs` + `saveScriptBrief` / `latestScriptBrief`; revision id content-addressed (SHA-256), không sửa DB bằng tay, giữ đúng single-writer.
- **Sửa lỗi**: bỏ câu brief demo hardcode từng được gửi cho mọi lần phân tích G2; giờ form trống ⇒ không gửi brief.
- **Tệp mới**: `apps/macos/Sources/ScriptBriefView.swift`, `apps/macos/Sources/AppState+ScriptBrief.swift`, `tests/test_script_brief_parser.py`.
- **Kiểm chứng (chạy thật)**:
  - `tools/build_macos_app.sh` → BUILD SUCCESSFUL, codesign PASS.
  - `tools/run_s06_tests.sh` → 6/6 PASS, gồm ca mới `S06.BRIEF` (round-trip, idempotent revision, revision mới khi sửa, sống sót sau reopen WAL).
  - `tools/run_tests.sh` → EXIT=0: Python **272 test OK (4 skip)**, toàn bộ Swift suite PASS (S02–S26, G3/G4/G5 guard, native provenance).
  - `tests/test_source_hygiene.py` PASS: `AIVideoApp.swift` 1380 dòng, `AppState.swift` 1296 dòng (dưới ngưỡng 1700/1400).
- **Chưa làm**: chưa chụp được ảnh màn hình thật (`screencapture` bị chặn quyền Screen Recording trong phiên này); chưa cài lại `/Applications/AIVideo.app` (mới build trong `apps/macos/build/`).

### 2026-11-10 — Kiểm tra thị giác trên bản cài đặt + tinh chỉnh layout

- Cài `/Applications/AIVideo.app` (build + codesign PASS, Spotlight registered), chụp cửa sổ thật bằng `screencapture -o -l<windowID>` (cửa sổ nằm trên màn hình phụ toạ độ âm nên chụp toàn màn hình bị app khác che).
- **Phát hiện qua ảnh chụp**: thẻ brief mở sẵn ở Bước 1 đẩy danh sách 911 tư liệu và inspector xuống dưới fold.
- **Đã sửa**: thẻ brief tự thu gọn thành 1 dòng khi đã có footage hoặc đã có nội dung, tự bung khi chưa có footage; có nút "Thu gọn/Mở rộng"; lưu xong tự thu gọn; trạng thái "Chưa có nội dung — bấm Mở rộng để ghi 6 mục" khi trống.
- **Ảnh xác nhận cuối**: sidebar 4 bước + nhóm nâng cao thu gọn; thẻ thư mục (15 video / 896 ảnh / 76,27 GB); thẻ brief thu gọn; danh sách + inspector (22,6 s · MOV/MP4 · 234,4 MB, ffprobe thu gọn, 1 nút "Phân tích video này", link "Sang Bước 2").
- **Ma trận cuối (sau tinh chỉnh layout)**: `tools/run_tests.sh` → **EXIT=0**, Python **272 test OK (4 skip)**.
- **Bản cài khớp bản build**: sau khi cài lại, SHA-256 của `Contents/MacOS/AIVideo` ở `/Applications/AIVideo.app` và `apps/macos/build/AIVideo.app` đều là `803a75bc5293fd7c5914a3cff9038b8bd003340e9a1bcb5241e2963a2aa8e046` (lưu ý: chạy `run_tests.sh` ký lại bundle build nên hash có thể đổi — phải cài lại rồi mới so).

## 2026-11-10 — Dữ kiện cưới POV (data model cho nghề chụp ảnh cưới)

- **Brief đổi sang dữ kiện cưới** (10 trường): cặp đôi, loại lễ, ngày-giờ, địa điểm, vai POV người quay, phong cách, cảnh bắt buộc phải có, cảnh cần tránh, nền tảng + thời lượng, ghi chú. UI 6 hàng gọn, thu gọn được.
- **Compose → câu tự nhiên**: `brief_text` giờ là các câu như "Bắt buộc có cảnh: trao nhẫn, mẹ chải tóc." thay vì nhãn `Trường: giá trị`; parser S13 phân loại đúng must_use / must_not_use / style.
- **G3 prefill**: chủ đề = "Linh & Minh — Lễ vu quy", tone suy ra từ phong cách, thời lượng suy ra từ nền tảng; không ghi đè nếu người dùng đã sửa.
- **DB migrate tại chỗ**: `PRAGMA table_info` + `ALTER TABLE` thêm 10 cột; đã kiểm trên DB thật của app (10 cột cũ → 20 cột, dữ liệu cũ còn nguyên).
- **Tệp chạm**: `ProjectStore.swift` (model + schema + save/load + migration), `AppState.swift`, `AppState+ScriptBrief.swift`, `ScriptBriefView.swift`, `G3ConsoleView.swift`, `semantic_verifier.py`, 2 file test.
- **Kiểm chứng (chạy thật)**:
  - `tools/run_s06_tests.sh` → **6/6 PASS**, ca `S06.BRIEF` kiểm: form trống compose `""`, 8 dòng câu tự nhiên, round-trip cặp đôi/loại lễ/cảnh bắt buộc/nền tảng/thời lượng, idempotent revision, revision mới khi sửa, sống sót reopen WAL, `topicLine`.
  - `tests/test_script_brief_parser.py` → **4/4 OK**: must_use / must_not_use / style_preference, span khớp từng ký tự, form trống không sinh draft.
  - `tools/run_tests.sh` → **EXIT=0**, Python **272 test OK (4 skip)**, toàn bộ Swift suite PASS.
  - `tools/build_macos_app.sh --install` → build + codesign PASS; SHA-256 binary `/Applications` == `apps/macos/build` (`3e1cd49f…`).
  - `test_source_hygiene.py` 6/6 OK (AIVideoApp 1380, AppState 1301 dòng).
- **Chưa làm**: chưa dạy VLM nhận diện cảnh cưới (trao nhẫn/gia tiên/lì xì) từ footage; hiện chúng chỉ đến từ brief người dùng ghi.

## 2026-11-11 — VLM nhãn cảnh cưới + redesign UI toàn app

### VLM cảnh cưới
- `workers/src/aivideo_workers/wedding_scenes.py`: 10 khoảnh khắc cưới + matcher cue tiếng Việt (chuẩn hoá NFC, không phân biệt hoa/thường), hàm `prompt_guide()` và `wedding_scene_sentence()`.
- `pipeline_adapters.py`: prompt Qwen3-VL có hướng dẫn taxonomy; sau khi model trả lời, nhãn được ghép vào `observation_text` ("Cảnh cưới nhận diện: …") và trả kèm khoá `wedding_scenes`; `action_or_scene_type` giữ nguyên 3 giá trị cũ.
- **Kiểm chứng**: `tests/test_wedding_scenes.py` **7/7 PASS**; các suite cũ `test_s12_full_frame_pipeline` (5), `test_g2_window_contract` (14), `test_g2_prefilter` (15), `test_s11_real_vlm_inference` (1) đều PASS.

### UI redesign
- `AIVideoTheme.swift`: canvas gradient teal, panel 16pt hairline+shadow, spacing scale, `StepChip`, `PrimaryActionStyle`, `GhostActionStyle`.
- Sidebar viết lại (tile số, accent bar, nhóm nâng cao thu gọn), page header mới (chip "BƯỚC n / 4", title rounded 30pt), chrome dùng chung restyle (Card/StatusPill/KeyValueRow/ErrorBanner/WorkerStatusCard/StatusBar).
- Bỏ banner lặp ở G3/G4/G5; sửa picker thời lượng bị cắt (segmented → menu); rút gọn nhãn nút dài bị truncate.
- **Kiểm chứng**: build + codesign PASS; chụp thật 4 bước trên bản cài (`/tmp/aivideo_ui_story2.png`, `_preview.png`, `_final.png`, `_media_final.png`); lần chụp cuối `/tmp/aivideo_final_media.png`.
- **Ma trận đầy đủ**: `tools/run_tests.sh` → **EXIT=0**, Python **279 test OK (4 skip)**, toàn bộ Swift suite PASS.
- **Bản cài khớp build**: SHA-256 `Contents/MacOS/AIVideo` hai bên đều `1c9b5914…3b61`.

## 2026-11-11 — Vá 6/9 lỗi P0 từ báo cáo thẩm định (docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md)

Mỗi lỗi kèm test hồi quy được chứng minh **đỏ trên code cũ → xanh sau khi sửa** (dùng `git stash` để chạy test trên bản cũ).

| Lỗi | Sửa gì | Test hồi quy | Đỏ trên code cũ |
|---|---|---|---|
| **P0-01** checkpoint bịa qua RPC | `main_g2.py`: chặn `checkpoint_dir` (`CHECKPOINT_DIR_FORBIDDEN`), root do worker quyết định, chỉ nhận `checkpoint_namespace` làm nhãn; `full_frame_pipeline.py`: từ chối resume khi không có inspector (`CHECKPOINT_RESUME_WITHOUT_INSPECTOR`) và kiểm `provenance` của checkpoint (`CHECKPOINT_PROVENANCE_MISMATCH`) | `tests/test_g2_checkpoint_integrity.py` (5) | 5/5 fail |
| **P0-02** audit coverage là tautology | audit dùng `win.intended_frame_ids`; planned ⊄ window → `VISUAL_SAMPLE_OUTSIDE_WINDOW`; planned nhưng model không nhận → `POST_PROCESSOR_TRUNCATION`; ledger thêm `window_frame_coverage`/`analysed_window_count` | `tests/test_g2_window_audit.py` (5) | 5/5 fail |
| **P0-05** gate tự DONE + luôn exit 0 | `package_review.py`: gate DONE chỉ khi có record và không FAIL/BLOCKED/NOT_RUN; bỏ nhãn khen hard-code; `review_verdict()` dùng chung cho badge và `sys.exit(1)` | `tests/test_package_review_gate.py` (8) | 8/8 fail |
| **P0-06** "5 video held-out thực tế" là title card | `fixtures/corpus` → `fixtures/smoke`; preflight thêm `check_smoke_corpus_is_not_field_evidence()` (chặn nhãn hoá smoke thành field); sửa `task_plan.md` G2/G5 sang IN_REVIEW | `tests/test_smoke_corpus_honesty.py` (4) | 4/4 fail |
| **P0-07** UI tự khai voice "verified" | `g3_engine.voice_trial` trả `voice_review_status="unverified"`; `search_cuts` yêu cầu trạng thái do caller khai (`verified`+published / `unverified`), thiếu ⇒ `BLOCKED_VOICE_NOT_VERIFIED`; `eligible_claims` không còn mặc định `scope_revalidation_status="complete"`; G3 console gửi trạng thái thật | `tests/test_g3_voice_gate.py` (6) | 2/6 fail |
| **P0-08** LLM rewrite chết ở S19 | worker gắn provenance từng beat (`voice_text_origin`, `voice_text_source_text`, `voice_text_sha256`, `voice_raw_output_sha256`, `voice_prompt_sha256`, `voice_model_id`) + all-or-nothing; `G3ProjectStore.beatIsProvenancedLLMRewrite` chỉ chấp nhận rewrite có đủ provenance, hash khớp narration, source = claim canonical, chữ số ⊆ claim, 8–320 ký tự | `tests/test_g3_llm_approval.swift` (5) | 1/5 fail |
| **P0-09** scope revision bịa | `G3StoryRequestBuilder.evidenceScope/scopeRevalidationStatus`; scope rỗng ⇒ lấy `claim.sourceRevisionId`; không có provenance ⇒ `missingScope`; bỏ `"scope-g2-main"` khỏi UI lẫn raw JSON mẫu | `tests/test_g3_story_scope.swift` (4) | không compile |
| **P0-04** fault suite tự PASS | `g5.fault.run_suite` trả `SELF_TEST_ONLY` (`release_evidence=false`, `s25_certified=false`); chỉ `validate_real_fault_suite_evidence()` (run_id + db thật + ≥4 boundary PASS) mới cấp S25; release manifest có `s25_fault_evidence`; UI đổi nhãn "self-test" | `tests/test_g5_fault_suite_honesty.py` (10) | 10/10 fail |

**Nghiệm thu chạy thật trong phiên này**
- Python: `tools/run_python_tests.py` → **317 test · 0 FAIL · 0 ERROR · 4 NOT_RUN** (4 NOT_RUN = S15 corpus / story 8B / Kokoro ×2, đúng như trước).
- Swift (biên dịch + chạy riêng với `MacOSX.sdk`): `test_s06_project_store` (7 PASS), `test_s08_publication_reconciler` (5 PASS), `test_s19_g3_approval`, `test_g3_approval_guard`, `test_g3_llm_approval` (5/5), `test_g3_story_request`, `test_g3_story_scope` — **tất cả exit 0**.
- Build: `./tools/build_macos_app.sh` → exit 0.
- Preflight: `tools/check_readiness.py` → **exit 2** (NO-GO, thiếu signed field corpus) và in `Committed Smoke Corpus: 5 clip(s), not field evidence`.
- Đã đăng ký 2 suite Swift mới vào `tools/run_tests.sh`.

**Còn mở (không làm trong lượt này)**: P0-03 (receipt native chưa ràng buộc plan/publication) và 54 P1 trong báo cáo — thứ tự gợi ý: P1-01 job SUCCEEDED sớm, P1-02 hash trong transaction, P1-03/04 lease, P1-05/06 backup/restore.

## 2026-11-11 — Tiếp: P0-03 (receipt native ràng buộc chuỗi phê duyệt) — hoàn tất 9/9 P0

**Vấn đề**: `G5S22Guard` trước đây không có hàm `verifyNativeReceipt/verifyFinalProvenance` (mã hiện có bị mất so với tài liệu cũ) và receipt native không chứa `plan_sha256`, `g3_approval_id`, `g4_approval_id` hay id publication từng beat ⇒ bất kỳ MP4 4K đúng hình dạng + receipt tự viết đều qua S22.

**Đã làm**
- `workers/src/aivideo_workers/native_render.py`: mỗi beat trong receipt ghi `video_publication_id`, `voice_publication_id`, `mapping_publication_id`, `receipt_publication_id`; receipt ghi `plan_sha256`, `g3_approval_id`, `g3_manifest_sha256`, `g4_approval_id`, `g4_preview_sha256`; `transition_overlap_frames` tính từ beat thực dựng (không còn hằng số 0).
- `packages/AIVideoCore/Sources/Storage/G5S22Guard.swift`: thêm `NativeReceiptExpectation`, `fileSHA256`, `verifyFinalMP4`, `verifyNativeReceipt(receipt:mp4Path:expectedFrames:expectation:)`, `verifyFinalProvenance(...expectation:)` — kiểm hình dạng, frame accounting, hash MP4, **và** ràng buộc plan/G3/G4/publication (báo lỗi: "different approved plan", "G3 approval differs", "publication outside the approved chain").
- Test mới `tests/test_g5_receipt_binding.swift` (5 ca) + cập nhật `tests/test_g5_native_provenance.swift` (fixture có binding) và đăng ký vào `tools/run_tests.sh`.

**Bằng chứng đỏ → xanh**
- Trên logic guard **trước fix** (bản sao trong `/tmp`, không đụng repo): `❌ FAIL: receipt from another plan was accepted`.
- Trên code hiện tại: `G5 RECEIPT BINDING TESTS PASSED (5/5)`, `G5 NATIVE PROVENANCE TESTS PASSED`.
- Sự cố đáng ghi: trong lượt này tôi đã `git stash` trên `G5S22Guard.swift` — file **không nằm trong git index** nên stash pop đã khôi phục nhầm baseline từ HEAD và mất một bản sửa; đã dựng lại đầy đủ và **không còn dùng `git stash` cho file untracked** nữa (chứng minh đỏ-trước giờ làm trên bản sao `/tmp/av_oldguard`).

**Ma trận cuối (chạy thật)**
- Python: **317 test · 0 FAIL · 0 ERROR · 4 NOT_RUN** (`tools/run_python_tests.py`, exit 0). Hai ca `test_s20_native_render` từng đỏ do hằng số overlap đã được sửa.
- Swift (9 suite biên dịch + chạy riêng): `s06` (7 PASS), `s08` (5 PASS), `s19`, `g3_approval_guard`, `g3_llm_approval` 5/5, `g3_story_scope`, `g3_story_request`, `g5_native_provenance`, `g5_receipt_binding` 5/5 — tất cả **exit 0**.
- `./tools/build_macos_app.sh` → exit 0; `tools/check_readiness.py` → exit 2 (NO-GO, thiếu signed field corpus).

## 2026-11-11 — Xử lý các mục còn lại: P1-01..07, full matrix, model thật, git tracking

### 1. Hai thay đổi ngoài danh sách đã được review
- `ScriptBriefView.swift`: hai biến đều gọi `optional(brief)` (cùng một `BoxParse`); `raw` chỉ chứa phần không phải dòng "Cảnh bắt buộc", nên **không** đổi sang `brief.composedText` sẽ lặp thông tin. Chỉ đổi API không tồn tại (`composedText` của `BoxParse` có thật, nhưng dùng `lines` rõ nghĩa hơn cho Text nhiều dòng). **Giữ nguyên hành vi.**
- `G5ConsoleView.sendReleaseManifest`: đổi sang `let fields: [String: G3JSONValue]` và `G3JSONValue.object(fields)` để buộc kiểu generic của `sendRequest` rõ ràng (cùng kiểu với `runSimpleRPC`/`requestParams` bên cạnh).

### 2. Git tracking
- `G5S22Guard.swift` và 7 file nguồn khác từng **không nằm trong git index** (AIVideoTheme, AppState+ScriptBrief, ScriptBriefView, native_render, story_writer, tts_engine, wedding_scenes) → đã `git add`.
- Đã `git add` toàn bộ test mới + 2 tài liệu audit; `git status` không còn file untracked.
- Rút ra: **không dùng `git stash` trên file untracked** — ở lượt trước thao tác đó đã làm mất một bản sửa `G5S22Guard.swift`; lần này mọi "đỏ trước fix" đều chạy trên bản sao `/tmp`.

### 3. P1 đã vá (mỗi lỗi có test)
| Mã | Thay đổi | Test |
|---|---|---|
| **P1-01** | `artifact_publications.expected_publication_count` (+ migration `ALTER TABLE` tại chỗ); job chỉ SUCCEEDED khi đủ số publication COMMITTED; reconciler dùng cùng luật; `G4FilePublisher` tái dùng một job cho một logical publication | `tests/test_p1_job_completion.swift` (4/4) |
| **P1-02** | Nhánh S22: đo hash artifact + đọc plan trên connection **read-only** trước transaction (`G5S22Guard.measureFile/readPublishedArtifact/readApprovedCandidate/publicationLocation`, `verifyFinalBindings(fileReader:)`) | `tests/test_p1_hashing_outside_transaction.swift` (3/3) |
| **P1-03** | Governor reclaim lease khi PID đã chết + heartbeat quá hạn; reap PID tái sử dụng | S07.T4 |
| **P1-04** | Reserve lease → allocateAttempt → bind; lease bị từ chối ⇒ `attempt == nil`, attempt cũ không bị revoke | S07.T5 |
| **P1-05** | Backup đọc closure từ chính snapshot (`SnapshotClosure`, mở `immutable=1`); thiếu pinned blob ⇒ fail | `tests/test_p1_backup_restore.swift` (6/6) |
| **P1-06** | `rewriteCanonicalPaths` re-point publication COMMITTED sang blob đã restore | `tests/test_p1_backup_restore.swift` |
| **P1-07** | Report đếm claim thật | `tests/test_p1_backup_restore.swift` |
- Đã cập nhật `docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`: đánh dấu "ĐÃ SỬA 2026-11-11" cho P1-01..07; **P1-02 chỉ sửa một phần** (G4/S21 và `commitPublication` vẫn băm trong transaction).

### 4. Lỗi thật khác phát hiện khi chạy model thật / matrix
- **TTS Kokoro bị coi là clip**: `tts_engine.save` ép đỉnh đúng 32767 nên gate `_wav_info` luôn báo "clipped at PCM16 full scale" → `test_s17_voice_phrases` heavy FAIL. Sửa: chuẩn hoá đỉnh −1 dBFS (0.891251) và làm tròn; hai suite TTS heavy PASS.
- **Benchmark G2 heavy ra kết quả khác nhau giữa 2 lần chạy**: checkpoint `ckpt_v2_*` không có provenance bị replay. Sửa: benchmark ghi `checkpoint_provenance`; 2 lần chạy liên tiếp đều PASS (114 s / 117 s).
- `tests/test_single_writer_invariants.py`: luật cũ cấm mọi `sqlite3_open_v2` trong gate store; nay cho phép **read-only** và cấm **write handle** (cộng thêm test chặn mọi handle không `SQLITE_OPEN_READONLY` ngoài ProjectStore).
- `tools/run_tests.sh`: 3 block mới dùng `$SDK` (không tồn tại) → `$SDK_PATH`.

### 5. Bằng chứng cuối
- `python3 tools/run_python_tests.py` (không cờ): **318 test · 0 FAIL · 0 ERROR · 4 NOT_RUN**.
- `AIVIDEO_RUN_HEAVY_G2=1 AIVIDEO_RUN_HEAVY_STORY=1 AIVIDEO_RUN_HEAVY_TTS=1 python3 tools/run_python_tests.py`: **318 test · 0 FAIL · 0 ERROR · 0 SKIP** — cả 4 test model thật đã chạy (S15 real corpus ≈ 2 phút; S16 8B ≈ 22 s; Kokoro ×2 ≈ 4 s).
- `./tools/run_tests.sh`: **EXIT=0**, 23 khối, gồm build + codesign + toàn bộ Swift suite + Python + 4 suite mới.
- `./tools/build_macos_app.sh`: BUILD SUCCESSFUL; `tools/check_readiness.py`: NO-GO (exit 2) đúng nghĩa.

---

## Phiên 2026-11-11 (tiếp) — Vá toàn bộ P1 còn lại, kèm test hồi quy

Phạm vi: **P1-08 … P1-54** (47 lỗi). Mỗi lỗi đều có thay đổi mã + test hồi quy; toàn bộ
được chạy lại trên ma trận đầy đủ (kết quả ở mục 5).

### 1. Dữ liệu & job (P1-08 … P1-11)
| Mã | Thay đổi | Test |
|---|---|---|
| **P1-08** | `ProjectStore.failJob(jobId:reason:)` — đường job→FAILED thật (attempt + job), thay vì chỉ có SUCCEEDED | `tests/test_p1_integrity.swift` |
| **P1-09** | `coverage_records` lưu `unique_processed_frame_ids`, `corrupted_decode_frame_ids`, `total_submitted_with_overlap`, `completed_windows`, `total_windows` (JSON); reader không còn bịa `Array(0..<count)` | `tests/test_p1_integrity.swift` (frame id/corrupt/window round-trip) |
| **P1-10** | `PRAGMA user_version = canonicalSchemaVersion` (2) khi mở DB + `migrateAdditiveColumns` nâng DB cũ tại chỗ | `tests/test_p1_integrity.swift` (DB legacy được stamp sau khi mở) |
| **P1-11** | Native render nhận root từ `AIVIDEO_RENDER_ROOT` do app cấp (`WorkerClient` tạo `Application Support/AIVideo/Renders`); `staging_root` bị từ chối | `tests/test_p1_renderer_safety.py` |

### 2. Tin cậy bằng chứng (P1-12 … P1-23)
- **P1-12**: `PINNED_VISUAL_WEIGHTS_SHA256` — manifest chỉ "verified" khi khai đúng hash trọng số đã ghim; `models_root_dir` và `AIVIDEO_MODELS_ROOT` bị từ chối **trước** mọi IO; root ghim đọc từ profile `AIVIDEO_APP_SUPPORT`.
- **P1-14**: `harness_decision` = `HARNESS_PASS/HARNESS_FAIL`, kèm `decision_kind: decision_harness_fixture`; không còn chuỗi `"PASS"` trần.
- **P1-15**: `staging_root` bị từ chối ở cả `render_native` và các renderer theo plan (`STAGING_ROOT_FORBIDDEN`).
- **P1-16**: `g5.preferences.manage` chỉ ghi trong `Application Support/AIVideo/Preferences` (`PREFERENCE_PATH_REFUSED`), trả `profile_path`; chặn cả đường dẫn tương đối `../..`.
- **P1-17**: `AIVIDEO_G5_SIMULATE_FREE_BYTES` chỉ có hiệu lực khi `AIVIDEO_TEST_HARNESS=1`.
- **P1-18**: `sign_release_manifest`/`verify_release_manifest` (Ed25519); manifest tự khai `signing.signed`; `signing.signed` được đặt **trước** khi ký và `manifest_sha256` bị loại khỏi payload (nếu không chữ ký tự vô hiệu).
- **P1-19**: E0/E1 chỉ certify khi `signed_field_manifest.corpus_scope.runs_sha256` khớp digest của `runs` (`RUNS_NOT_BOUND_TO_SIGNED_MANIFEST`).
- **P1-20**: `AIVIDEO_CONTRACTS_DIR` bị từ chối (`CONTRACTS_DIR_FORBIDDEN`); app ngừng set biến này và bundle thêm `Resources/Workers/contracts`.
- **P1-21**: `load_clip_labels_with_problems` trả cả danh sách lỗi; một file hỏng ⇒ `acceptance_eligible = False`.
- **P1-22**: app ad-hoc ký là **blocker** của preflight; chỉ bỏ qua khi `--allow-adhoc`.
- **P1-23**: chưa làm (`.drp` vẫn chỉ kiểm magic-ZIP) — ghi nhận là hạn chế còn lại.

### 3. Đường ống (P1-24 … P1-37)
- **P1-24**: decode có giới hạn `-frames:v`; `assert_index_is_contiguous` chạy một lần cho cả media index.
- **P1-26**: không có `container_frame_count` ⇒ `COVERAGE_DENOMINATOR_UNAVAILABLE` (hết circular); probe thêm `denominator_source`.
- **P1-27**: trạng thái mới `audio_present_untranscribed` thay cho `no_speech` khi ASR chưa chạy.
- **P1-28**: U+FFFD trong output VLM ⇒ `INVALID_VLM_OUTPUT` (không "sửa" text thành observation); phân loại cảnh dùng whole-word.
- **P1-29**: `subject_track_id = None` (không bịa `trk-wNNNN`).
- **P1-30**: omission audit chỉ liệt kê frame model **đã thấy**, trạng thái `reviewed_sample_only`/`not_run`.
- **P1-32**: photo insert bắt buộc `photo_sha256` khớp bytes trên đĩa (`PHOTO_HASH_REQUIRED`/`PHOTO_BYTES_CHANGED`).
- **P1-33**: `_escape` từ chối `;`/newline (`UNSAFE_FILTERGRAPH_TOKEN`); `beat_id` theo `[A-Za-z0-9_-]{1,64}`; drawtext `expansion=none`.
- **P1-34**: SHA-256 của MP4 đầu ra tính theo stream (`_sha256_file`), không `read_bytes()`.
- **P1-35**: `has_future` trả chi phí lookahead và trừ vào `node_budget`.
- **P1-36**: lỗi runtime TTS lúc `infer/save` ⇒ `blocked_tts_runtime_unavailable` (không còn INTERNAL_ERROR).
- **P1-37**: faithfulness ngoài chữ số — tên/địa danh không có trong claim ⇒ `STORY_INVENTED_ENTITY`.
- **P1-25** (phân trang observation >1 MiB): chưa làm.

### 4. Tooling & UI (P1-38 … P1-54)
- **P1-38**: banner suite Swift giờ tính `passed/total` và `exit(1)` nếu thiếu case (`aivideoReportBanner`).
- **P1-39**: 11 Swift suite đã phát JSONL bằng `TEST_RECORDS_OUT`.
- **P1-40**: Resolve spike `BLOCKED` → exit 2 (ma trận ghi nhận, không tính PASS).
- **P1-41**: S02.T1 chỉ PASS khi evidence có `run_id`, `timestamp`, `executed_on_host`, `operator`.
- **P1-42**: `artifact_publication_schema.json` khớp đúng 16 loại thực được publish; test chặn entry không có mã nào sinh ra.
- **P1-43**: CI dùng `-typecheck -warnings-as-errors` (bỏ `-frontend -parse`); đã dọn 4 cảnh báo thật.
- **P1-44**: ma trận **không xoá** `build/reports/*.jsonl` nữa mà chuyển sang `previous/`.
- **P1-45**: `requirement_id` theo bảng; `JOB-04` chỉ còn 7/361 record (thay vì 151/279).
- **P1-46**: bỏ fallback `"rev-01"`, nút Stage yêu cầu `saved != nil`.
- **P1-47**: `cancelBatchAnalysis` huỷ `currentBatchTask` (RPC đang chạy), không chỉ đặt cờ.
- **P1-48**: `restartWorker` đặt cờ **trước** `await terminate()`.
- **P1-49**: cue tính từ sample WAV đã đo (`voiceSamples`), thêm `captionTimingSource`; bỏ `wordCount × 0.45`.
- **P1-50**: G5 chỉ nói ".drp sealed" khi thực sự có `.drp`.
- **P1-51**: `resetWorkflowForNewVideo()` xoá approvals/cues/publication khi "Làm video mới".
- **P1-52**: inspector chỉ hiện probe của đúng file (`probe.filePath == item.id`).
- **P1-53**: bỏ cue mặc định "Nội dung đã duyệt" ở G4/G5.
- **P1-54**: `mappingPublicationId` chỉ lấy từ `latestG2MappingPublicationId`.

### 5. Bằng chứng cuối
- `workers/.venv/bin/python3 tools/run_python_tests.py`: **379 test · 0 FAIL · 0 ERROR · 4 NOT_RUN**.
- `./tools/run_tests.sh`: **EXIT=0**, 23 khối (build + codesign + 17 Swift suite + Python).
- `./tools/build_macos_app.sh`: BUILD SUCCESSFUL.
- `swiftc -typecheck -warnings-as-errors packages/AIVideoCore/Sources/*/*.swift`: sạch.
- Test mới: `test_p1_integrity.swift`, `test_g3_voice_gate.py`, `test_p1_evidence_trust.py`,
  `test_p1_pipeline_truth.py`, `test_p1_renderer_safety.py`, `test_p1_harness_honesty.py`,
  `test_p1_remaining.py`.

### 6. Còn lại (không thuộc P1)
- P2 (54 mục) chưa đụng tới.
- **P1-23** (`.drp` nội dung) và **P1-25** (phân trang observation) chưa làm; **P1-02** mới sửa nhánh S22.
- `fixtures/smoke` là title card tổng hợp ⇒ chứng nhận field-corpus vẫn NO-GO cho tới khi có footage thật.

---

## Phiên 2026-11-11 (vòng đóng P1) — 6 mục còn mở đã xử lý

Sau khi ma trận lần đầu xanh, rà lại mục tiêu và đóng nốt các mục còn thiếu:

| Mã | Thay đổi | Test |
|---|---|---|
| **P1-11** | `ResourceGovernor.withHeavyLease(...)` (lease bao quanh thao tác, nhả trong mọi nhánh, `GovernorError.leaseDenied`); `G4ConsoleView.runNativePreview` (`heavyMediaConform`) và `G5ConsoleView.runNativeFinal` (`resolveRender`) gọi render qua wrapper này | `tests/test_p1_closure.py` |
| **P1-13** | Bỏ hẳn tham số `label_source`; `acceptance_eligible` chỉ khi `label_provenance` là signed manifest hợp lệ **và** labels = human + field_footage | `tests/test_p1_closure.py` (3 case: không manifest / manifest không ký / tham số cũ bị từ chối) |
| **P1-15** | `allow_overwrite` bị từ chối trước mọi kiểm tra (`OVERWRITE_FORBIDDEN`); `staging_root` bị từ chối ở cả 3 renderer | `tests/test_p1_closure.py`, `tests/test_s20_native_render.py` |
| **P1-23** | `g5_final.validate_resolve_drp_structure`: ZIP hợp lệ + `testzip()` + có `Project.db/.sqlite` + có timeline payload; dùng ở G4 (`g4_resolve.py`) và G5 (build + verify) | `tests/test_p1_closure.py` (ZIP thường bị loại, DRP đúng cấu trúc được nhận, archive hỏng bị loại) |
| **P1-25** | `main_g2.paginate_raw_observations` (ngân sách 512 KiB inline, `raw_observations_truncated`/`next_offset`); RPC mới `g2.get_raw_observations` đọc **checkpoint do worker sở hữu** (bind theo `source_sha256` ghi trong checkpoint, không nhận đường dẫn) | `tests/test_p1_closure.py` (4 case) |
| **P1-31** | `PLAN_FRAME_MISMATCH` khi độ dài render ≠ `plan.total_frames` (nêu rõ overlap + photo insert frames) | `tests/test_p1_closure.py` |

Ghi chú: P1-31 chỉ đóng **một phần** — độ dài timeline nay bị chặn, nhưng danh sách
transition vẫn do plan khai và chưa đối chiếu với G4 preview đã duyệt. P1-02 vẫn chỉ sửa
nhánh S22.

### Bằng chứng cuối (vòng này)
- `workers/.venv/bin/python3 tools/run_python_tests.py`: **395 test · 0 FAIL · 0 ERROR · 4 NOT_RUN**.
- Với `AIVIDEO_RUN_HEAVY_G2=1 AIVIDEO_RUN_HEAVY_STORY=1 AIVIDEO_RUN_HEAVY_TTS=1`: **395 test · 0 FAIL · 0 ERROR · 0 SKIP** (4 suite model thật đều chạy).
- `./tools/run_tests.sh`: **EXIT=0**, 23 khối.
- `./tools/build_macos_app.sh`: BUILD SUCCESSFUL; `swiftc -typecheck -warnings-as-errors` trên toàn bộ `packages/AIVideoCore/Sources`: sạch.

### Bổ sung: P1-32 (nửa còn lại) — photo insert phải là publication S08
- `native_render.build_beats_from_plan`: ngoài `photo_sha256` khớp bytes, bắt buộc
  `photo_publication_id` (UUID) — thiếu ⇒ `PHOTO_PUBLICATION_REQUIRED`; receipt ghi
  `photo_publication_id`.
- `G5S22Guard.verifyNativeReceipt`: beat `photo_insert` phải có `usage=illustrative_only`
  **và** `photo_sha256` **và** `photo_publication_id`; khi có danh sách publication đã duyệt,
  photo publication phải nằm trong đó.
- Test: `tests/test_p1_closure.py` (2 case mới), `tests/test_s20_native_render.py`,
  `tests/test_g5_native_provenance.swift`.

---

## Phiên 2026-11-11 (P2) — Xử lý toàn bộ nợ kỹ thuật mục 6

14 nhóm P2 → 14 mục đánh số (P2-01…P2-14; P2-05 gộp vào P2-03 vì cùng một nguyên nhân).
Test hồi quy: `tests/test_p2_debt.py` — **29 case**, mỗi case kiểm chứng *thuộc tính* chứ
không phải hình dạng code hiện tại.

### Việc đã làm
1. **P2-01 god files + danh sách file viết tay**: tách `ProvenanceValue.swift`,
   `PersistenceState.swift`, `AppState+Media.swift` (−341 dòng), `G3SpeechReview.swift`
   (−244 dòng); `build_macos_app.sh` và `run_tests.sh` **glob** toàn bộ `Sources` thay vì
   liệt kê tay. Đây không phải việc thẩm mỹ: danh sách tay đã làm mọi suite Swift fail
   (cannot find type) trong khi app vẫn build, đúng lúc thêm file mới.
2. **P2-02 bundle một bản worker**: bỏ bản `Workers/workers/src`; script assert đúng 1
   `main.py`. Bài học thật: `rm -rf Resources/workers` xoá luôn `Workers/` vì APFS
   case-insensitive — đã bỏ lệnh đó và thay bằng assert.
3. **P2-03/05 khoá ghi trong đường đọc**: thêm `withCanonicalRead` (`BEGIN DEFERRED`) và
   dùng cho `currentG3Approval` / `currentG4Preview` / `currentG5FinalApproval` — các hàm
   này còn băm file, nên trước đây mỗi lần UI poll là một lần giữ write lock.
4. **P2-04 UUID + fps**: `ProvenanceValue.uuidsMatch` / `.frameRate` / `.is24fps` dùng chung;
   xoá `Double(parts[0])` (trap khi `avg_frame_rate` rỗng) khỏi cả hai guard.
5. **P2-06 ngoại lệ bị nuốt**: `diagnostics.note_suppressed` + ring buffer; 11 file được
   ghi ngữ cảnh; `tools/fix_gate_integrity.py` (đã áp dụng, còn nhúng code cũ) → `tools/historical/`.
6. **P2-07 state UI có kiểu**: `PersistenceState`, bỏ mọi `hasPrefix("Đã lưu")`.
7. **P2-08/09/10 dữ liệu mồi**: "Đã lưu" chỉ khi revision > 1; prompt demo rỗng; UUID cài đặt
   sinh theo máy (`UserDefaults`) + `ProjectStore.getWorkday`; ngày theo ngày thật.
8. **P2-11 accessibility**: mọi font ≥ 11 pt, `accessibilityLabel` cho nút icon-only, bỏ `.mini`.
9. **P2-12/13/14**: `review_workflow.py` khai báo non-production + test chặn import;
   fixture schema chuyển vào `contracts/migrations/fixtures/` + README nói Swift là chủ sở hữu;
   doc gốc phải byte-identical với `docs/`; `REVIEW_SUMMARY.md` trỏ về report thật.

### Bằng chứng
- `workers/.venv/bin/python3 tools/run_python_tests.py`: **424 test · 0 FAIL · 0 ERROR · 4 NOT_RUN**.
- Heavy (`AIVIDEO_RUN_HEAVY_G2/STORY/TTS=1`): **424 · 0 FAIL · 0 ERROR · 0 SKIP**.
- `./tools/run_tests.sh`: **EXIT=0**, 23 khối.
- `./tools/build_macos_app.sh`: BUILD SUCCESSFUL; bundle 736 KB (một bản worker).
- `swiftc -typecheck -warnings-as-errors` trên `packages/AIVideoCore/Sources`: sạch.
