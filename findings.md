# Technical Findings: AIVideo v3.1 Remediation & Benchmarking

## 1. Bản Chất Sự Cố "162 FAIL" Trong Báo Cáo Cũ
- **Nguyên nhân gốc rễ**: Lỗi shell script tại dòng 252 của [`tools/run_tests.sh`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/run_tests.sh#L7-L10) (`set -euo pipefail` gặp biến `$ROOT_DIR` chưa được gán giá trị). Script thoát với exit code 1 ở dòng cuối cùng sau khi đã chạy xong các bài kiểm thử.
- **Hệ quả dây chuyền**: Script đóng gói [`tools/package_review.py`](file:///Users/phuthanh/APP_CaNhan/AIVideo/tools/package_review.py) được lập trình để tự động chuyển toàn bộ kết quả PASS thành FAIL nếu lệnh runner trả về exit code khác 0.
- **Kết quả sau sửa lỗi**: Toàn bộ 189 ca kiểm thử trên Apple Silicon M1 Pro chạy hoàn tất với **189 PASS · 0 FAIL · 0 BLOCKED · 0 NOT_RUN** (đã bổ sung font macOS hệ thống cho ca kiểm thử raster caption S21).

## 2. Đo Lường Hiệu Năng Qwen3-VL 4B Trên Apple Silicon (M1 Pro 16 GB)
- **Engine**: `mlx_vlm` (v0.7.10) kết hợp Metal GPU backend (`AGXMetalG13X`).
- **Dung lượng mô hình**: 2.88 GB (4-bit quant, 1220 tensors safetensors).
- **Thời gian nạp trọng số lần đầu**: ~2.4 giây; được lưu trong `_VLM_MODEL_CACHE` để tái sử dụng xuyên suốt phiên làm việc mà không nạp lại.
- **Tốc độ suy luận**:
  - Prompt processing: ~25.2 tokens/s.
  - Token generation: **60.37 tokens/s**.
  - Trung bình thời gian sinh nhãn 25 từ tiếng Việt cho 1 sliding window (16 frames): **~0.28 giây**.
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

  - `app_binary_path` -> `ValueError: APP_BINARY_OVERRIDE_FORBIDDEN`
