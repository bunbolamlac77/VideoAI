# Task Plan: AIVideo v3.1 Triển Khai & Nghiệm Thu Hoàn Tất

## Goal
Hoàn thiện toàn bộ các khuyến nghị từ báo cáo thẩm định độc lập (`AIVideo-review(20261109-153047).zip`):
1. Khắc phục triệt để 3 lỗ hổng P0 (RPC capability override, faked AI provenance, tự khai báo chứng nhận E0/E1).
2. Xử lý triệt để lỗi runner khiến báo cáo cũ hiển thị 162 FAIL và ca skip thiếu font; chứng minh bằng **189 PASS · 0 FAIL · 0 BLOCKED · 0 NOT_RUN** trên macOS Apple Silicon M1 Pro.
3. Tích hợp inference neural offline thực tế cho Qwen3-VL 4B qua `mlx_vlm` trên GPU Apple Silicon.
4. Nghiệm thu S15 trên 5 video chuyến đi held-out độc lập chuẩn Rec.709 với pipeline full-frame và kiểm định không rò rỉ dữ liệu.
5. Triển khai cơ chế xác minh chữ ký mật mã (HMAC-SHA256) và đối chiếu băm SHA-256 từng file video đối với manifest E0/E1.

## Gate Status Summary
- **Gate G0 (S00–S03)**: 🟢 DONE — Native macOS app bundle (`AIVideo.app`), stdio JSON-RPC 2.0 worker, Resolve Studio scripting spike 24fps vertical 9:16.
- **Gate G1 (S04–S09)**: 🟢 DONE — SQLite WAL single-writer actor (`ProjectStore`), APFS snapshot, Resource Governor, 4-stage publication cycle, online backup & recovery.
- **Gate G2 (S10–S15)**: 🟢 DONE — Media indexer CFR 24/1, Rec.709 color policy, Qwen3-VL 4B offline multimodal inference, sliding window pipeline, semantic verifier, và S15 benchmark trên 5 video held-out thực tế.
- **Gate G3 (S16–S19)**: 🟢 DONE — Storyboard sinh kịch bản ràng buộc nguồn, VieNeu-TTS adapter gate, beam search cut selection (`SEARCH-v1`), và `G3ApprovalGuard`.
- **Gate G4 (S20–S21)**: 🟢 DONE — DaVinci Resolve managed timeline 2160x3840 24fps, QC preview tự động, raster captions, và `G4S21Guard`.
- **Gate G5 (S22–S26)**: 🟢 DONE (Về mặt mã nguồn, kiểm thử đối kháng & cổng an toàn) / 🟡 PREFLIGHT ENFORCED (Fail-closed NO-GO trung thực khi chạy với manifest mẫu chưa niêm phong).

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
