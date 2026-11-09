# AIVideo v3.1 — Bảng Điều Khiển Tiến Trình Triển Khai (Progress Tracker)

> **Phiên bản tài liệu cơ sở:** 3.1 · **Ngày khởi tạo:** 06/11/2026  
> **Cấu hình máy mục tiêu:** Apple Silicon M1 Pro, 16 GB Unified Memory (macOS)  
> **Kiến trúc lõi:** SwiftUI (Native macOS) + Swift Core (`ProjectStore`, SQLite WAL) + Python Worker (JSON-RPC stdio) + DaVinci Resolve  
> **Nguyên tắc bất di bất dịch:** Chạy 100% Local (Không Cloud AI fallback) · Swift Core độc quyền ghi DB chuẩn · Bằng chứng nguồn rõ ràng (Provenance) · Unknown là trạng thái hợp lệ.

---

## 1. Trạng Thái Tổng Thể Các Cổng Triển Khai (Gates G0 – G5)

| Cổng | Tên cổng | Bước bao hàm | Trạng thái hiện tại | Điều kiện tiên quyết |
|---|---|---|---|---|
| **G0** | Nền tảng chạy thật | S00 – S03 | 🟢 **DONE (Đóng Gate G0: S00–S03 PASS 100%, bao gồm S02.T1/T2 có bằng chứng)** | Build `.app` arm64, worker thật, file sandbox/bookmark, model local, offline, Resolve spike |
| **G1** | Dữ liệu và phục hồi | S04 – S09 | 🟢 **DONE (Đóng Gate G1: Hoàn thành 100% S04 – S09, đạt toàn bộ tiêu chí dữ liệu, publication và phục hồi)** | Single-writer `ProjectStore`, snapshot bất biến, publication state machine, crash recovery |
| **G2** | Phân tích và bằng chứng | S10 – S15 | 🔵 **IN_REVIEW (Hoàn thành 100% logic/contracts/unit tests S10–S15; chờ cài đặt model sản phẩm S11 & chạy benchmark 5 chuyến video thật S15 để đóng Gate G2)** | Media mapping, full-frame coverage, claim verifier, corpus benchmark |
| **G3** | Kịch bản dựng được | S16 – S19 | ⚪ Chưa bắt đầu (Chuẩn bị S16 Storyboard & Script Outline) | Outline hợp lệ, TTS thật, beam search shot selection, script approval snapshot |
| **G4** | Preview được duyệt | S20 – S21 | ⚪ Chưa bắt đầu | Managed timeline Resolve, QC preview tự động, preview approval |
| **G5** | Final và phát hành | S22 – S26 | ⚪ Chưa bắt đầu | Final QC 2160x3840 24fps, nghiệm thu E0/E1, fault-injection, đóng gói release |

*Ký hiệu:* ⚪ Chưa bắt đầu (`NOT_STARTED`) · 🟡 Đang thực hiện (`IN_PROGRESS`) · 🟢 Đã hoàn thành (`DONE`) · 🔴 Bị chặn (`BLOCKED`) · 🔵 Chờ đánh giá (`IN_REVIEW`).

---

## 2. Danh Sách 27 Bước Triển Khai Chi Tiết (S00 – S26)

### G0 — Nền tảng chạy thật
- [x] **S00** — Khởi tạo Repository, cấu trúc thư mục chuẩn, bộ tài liệu và sổ tiến độ.  
  *Biên bản:* [`reports/progress/S00.md`](reports/progress/S00.md) · *Trạng thái:* `DONE`
- [x] **S01** — Khảo sát môi trường máy thật (macOS, Xcode, Python, FFmpeg, Resolve, Models) và lập compatibility matrix.  
  *Biên bản:* [`reports/progress/S01.md`](reports/progress/S01.md) · *Trạng thái:* `DONE`
- [x] **S02** — Bản `.app` macOS tối thiểu, IPC JSON-RPC qua stdio, kiểm tra quyền truy cập file/security-scoped bookmark và một lượt inference local model thật (G0 smoke test).  
  *Biên bản:* [`reports/progress/S02.md`](reports/progress/S02.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Finder launch, Unicode path, Bookmark lifecycle, Non-blocking IPC, 100% PASS)
- [x] **S03** — DaVinci Resolve spike 10 giây (timeline 2160x3840 24fps), xác nhận chạy hoàn toàn offline và đóng Gate G0.  
  *Biên bản:* [`reports/progress/S03.md`](reports/progress/S03.md) · *Trạng thái:* `DONE` (Live Resolve Studio spike 240 frames @ 24fps, V2 title, atomic DRP export, offline 100%)

### G1 — Dữ liệu và phục hồi
- [x] **S04** — Hợp đồng dữ liệu JSON Schema, IPC contracts và định nghĩa các state machines.  
  *Biên bản:* [`reports/progress/S04.md`](reports/progress/S04.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: snake_case & ISO-8601 Codable, Golden tests hai chiều, SQLite WAL disk test, JSON-RPC schema strictness)
- [x] **S05** — Import nguồn, băm nội dung (content hash) và cơ chế snapshot nguồn niêm phong trên APFS.  
  *Biên bản:* [`reports/progress/S05.md`](reports/progress/S05.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Two-phase copy atomic, content-addressed blob, manifest verifier, disk preflight, 50/50 test PASS)
- [x] **S06** — Triển khai `ProjectStore` actor trong Swift core, SQLite WAL, quản lý revision và transaction ngắn.  
  *Biên bản:* [`reports/progress/S06.md`](reports/progress/S06.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: ProjectStore Swift actor, SQLite WAL trên disk, revision conflict detection, idempotency journal, 5/5 test PASS)
- [x] **S07** — Resource Governor, Task Scheduler, Fencing tokens và hủy attempt trễ.  
  *Biên bản:* [`reports/progress/S07.md`](reports/progress/S07.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Global Heavy Lease toàn app, chặn worker zombie chưa thoát, fencing token chặn attempt trễ, 3/3 test PASS)
- [x] **S08** — Chu trình công bố artifact (`PREPARED` → `MATERIALIZED` → `VERIFIED` → `COMMITTED`) và Startup Reconciler.  
  *Biên bản:* [`reports/progress/S08.md`](reports/progress/S08.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: 5 fault hooks ranh giới DB/FS, Startup Reconciler, bảo vệ pin khỏi GC, phát hiện hỏng blob sau commit, 3/3 test PASS)
- [x] **S09** — Cơ chế Backup, Restore sang thư mục mới, Schema Migration và đóng Gate G1.  
  *Biên bản:* [`reports/progress/S09.md`](reports/progress/S09.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Online SQLite Backup API trong write barrier, checkpoint vs portable backup, restore sang thư mục mới, safe migration và đóng Gate G1, 3/3 test PASS)

### G2 — Phân tích và bằng chứng
- [x] **S10** — Media indexer, VFR frame mapping, tạo proxy và profile màu SDR Rec.709.  
  *Biên bản:* [`reports/progress/S10.md`](reports/progress/S10.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Rational PTS indexer, ánh xạ VFR→CFR 24/1 `M-24-SDR-v1`, sinh proxy CFR 24fps thật + SHA-256 mapping, bảo vệ frame bằng chứng ngắn, audio 48 kHz & màu SDR Rec.709/HDR Mobius, 100% PASS)
- [x] **S11** — Model adapters (Qwen-VL, Whisper, VieNeu-TTS, DINOv2) và setup offline local.  
  *Biên bản:* [`reports/progress/S11.md`](reports/progress/S11.md) · *Trạng thái:* `IN_REVIEW` (Hoàn thành adapter contracts, preflight offline, Post-Processor frame truncation audit, khóa chính sách RAM 16 GB chặn 32B & Capability Registry; model sản phẩm đang ở trạng thái `NOT_INSTALLED`)
- [x] **S12** — Pipeline phân tích toàn frame (full-frame baseline), checkpointing và theo dõi độ phủ thực.  
  *Biên bản:* [`reports/progress/S12.md`](reports/progress/S12.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Cửa sổ trượt 16f/overlap 4f, chặn `blocked_model_unavailable` khi thiếu visual model không sinh observation/coverage giả, đo dung lượng SSD thật, cô lập `raw_independent` khỏi brief, nhánh audio không chặn hình & checkpointing nguyên tử, 100% PASS)
- [x] **S13** — Xử lý brief/facts, trích xuất claims, xây dựng event graph và verifier độc lập.  
  *Biên bản:* [`reports/progress/S13.md`](reports/progress/S13.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Brief parser giữ span/time_precision, tách mệnh đề nhân quả & đa mệnh đề, bảng quyết định 12 dòng Mục 6, đồ thị sự kiện phát hiện chu trình & revalidation theo scope, 100% PASS)
- [x] **S14** — Giao diện/luồng review có bằng chứng (evidence-backed review) và xử lý biến động tư liệu.  
  *Biên bản:* [`reports/progress/S14.md`](reports/progress/S14.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Gỡ bỏ dữ liệu mẫu giả lập, hiển thị đủ 6 lệnh review thật nối với Worker RPC `g2.analyze_source` & `ProjectStore` SQLite, `answer_unknown` không thành đồng ý, cô lập nhánh bị chặn & lọc batch confirmation, 100% PASS)
- [x] **S15** — Benchmark phân tích trên tập dữ liệu và đóng Gate G2.  
  *Biên bản:* [`reports/progress/S15.md`](reports/progress/S15.md) · *Trạng thái:* `IN_REVIEW` (Hoàn thành bộ máy thống kê Wilson 95% CI, Group Bootstrap 10.000 vòng, chống rò rỉ dữ liệu & kiểm thử logic trên fixture `G2-FROZEN-EVAL-v1`; chờ chạy trên 5 chuyến video thực địa sau khi cài model S11 để đóng chính thức Gate G2)

### G3 — Kịch bản dựng được
- [ ] **S16** — Trình tạo outline kịch bản (1–3 phương án), gắn nguồn từng mệnh đề và khóa chỉnh sửa.  
  *Biên bản:* [`reports/progress/S16.md`](reports/progress/S16.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S17** — TTS thử với VieNeu-TTS, đo duration audio thật và căn chỉnh nhịp câu.  
  *Biên bản:* [`reports/progress/S17.md`](reports/progress/S17.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S18** — Thuật toán Beam Search chọn shot có ràng buộc và bộ chẩn đoán thất bại (phân biệt prune vs vô nghiệm).  
  *Biên bản:* [`reports/progress/S18.md`](reports/progress/S18.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S19** — Script approval gắn chặt revision snapshot và đóng Gate G3.  
  *Biên bản:* [`reports/progress/S19.md`](reports/progress/S19.md) · *Trạng thái:* `NOT_STARTED`

### G4 — Preview được duyệt
- [ ] **S20** — DaVinci Resolve Adapter, Operation Journal và dựng Managed Timeline tự động.  
  *Biên bản:* [`reports/progress/S20.md`](reports/progress/S20.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S21** — Render Preview 1080x1920, QC kỹ thuật/nội dung tự động, xử lý drift và Preview Approval. Đóng Gate G4.  
  *Biên bản:* [`reports/progress/S21.md`](reports/progress/S21.md) · *Trạng thái:* `NOT_STARTED`

### G5 — Final và phát hành
- [ ] **S22** — Render Final 2160x3840 24fps, QC file xuất cuối cùng và bàn giao project Resolve (.drp).  
  *Biên bản:* [`reports/progress/S22.md`](reports/progress/S22.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S23** — Kiểm định 6 tính năng nâng cấp và hiển thị trung thực trạng thái capability.  
  *Biên bản:* [`reports/progress/S23.md`](reports/progress/S23.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S24** — Hoàn thiện UI macOS native, gõ tiếng Việt, phím tắt và Accessibility.  
  *Biên bản:* [`reports/progress/S24.md`](reports/progress/S24.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S25** — Fault injection testing, kiểm thử ngắt điện/crash, chạy tải E0 (30m) & E1 (120m).  
  *Biên bản:* [`reports/progress/S25.md`](reports/progress/S25.md) · *Trạng thái:* `NOT_STARTED`
- [ ] **S26** — Đóng gói Release (.app), ký số/notarization, lập hồ sơ nghiệm thu cuối và đóng Gate G5.  
  *Biên bản:* [`reports/progress/S26.md`](reports/progress/S26.md) · *Trạng thái:* `NOT_STARTED`

---

## 3. Quy Trình Báo Cáo Đoạn Code (Dành Cho AI Khác Đánh Giá)

Khi Antigravity hoàn thành bất kỳ đoạn code/module/bước nào, Antigravity **BẮT BUỘC** thực hiện 3 hành động:

1. **Cập nhật file tiến trình tổng này (`PROGRESS_TRACKER.md`)**:
   - Chuyển trạng thái checkbox của bước đó.
   - Ghi lại commit hash hoặc timestamp cập nhật.
2. **Tạo 1 file Markdown riêng lẻ tại `reports/progress/Sxx_[TênBước].md`**:
   - Sử dụng chuẩn theo mẫu [`reports/progress/TEMPLATE_STEP_REPORT.md`](reports/progress/TEMPLATE_STEP_REPORT.md).
   - Trình bày toàn diện: Mục tiêu, file đã tạo/sửa, giải pháp kiến trúc, kết quả chạy kiểm thử thực tế (terminal logs), các giới hạn chưa làm, và **Prompt dành riêng cho AI bên ngoài kiểm tra/đánh giá (External Reviewer Audit Prompt)**.
3. **Thông báo cho người dùng**:
   - Dẫn link trực tiếp tới file báo cáo vừa tạo để người dùng sao chép hoặc chuyển tiếp cho AI khác (như ChatGPT, Claude, v.v.) đánh giá chéo.
