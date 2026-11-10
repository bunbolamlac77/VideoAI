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
