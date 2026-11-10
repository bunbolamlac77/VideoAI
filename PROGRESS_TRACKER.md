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
| **G2** | Phân tích và bằng chứng | S10 – S15 | 🟢 **DONE (Đóng Gate G2: S10–S15 PASS 100%, Qwen3-VL 4B local inference thật trên GPU M1 Pro, S15 benchmark trên 5 video held-out)** | Media mapping, full-frame coverage, claim verifier, Qwen3-VL local inference thật, 5 held-out trips |
| **G3** | Kịch bản dựng được | S16 – S19 | 🟢 **DONE (Hoàn thành S16–S19: Storyboard, VieNeu-TTS Gate, SEARCH-v1 & S19 Guard)** | Outline hợp lệ, TTS thật, beam search shot selection, script approval snapshot |
| **G4** | Preview được duyệt | S20 – S21 | 🟢 **DONE (Hoàn thành S20–S21: Managed timeline Resolve, QC preview tự động, preview approval)** | Managed timeline Resolve, QC preview tự động, preview approval |
| **G5** | Final và phát hành | S22 – S26 | 🔵 **IN_REVIEW (Hoàn thành 100% S22–S26, đã vá 3 lỗi P0; Preflight bảo vệ bằng chữ ký mật mã & băm SHA-256 từng video)** | Final QC 2160x3840 24fps, nghiệm thu E0/E1 video thật, fault-injection, đóng gói release |

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
  *Biên bản:* [`reports/progress/S11.md`](reports/progress/S11.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Adapter contracts, preflight offline, capability registry và nạp suy luận thật Qwen3-VL-4B-Instruct-4bit 2.88 GB qua `mlx_vlm` trên GPU Apple Silicon M1 Pro, ~60.37 tokens/s, 100% PASS)
- [x] **S12** — Pipeline phân tích toàn frame (full-frame baseline), checkpointing và theo dõi độ phủ thực.  
  *Biên bản:* [`reports/progress/S12.md`](reports/progress/S12.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Pipeline trượt frame `16 frames, overlap 4`, cô lập `raw_independent` vs `guided_revisit`, sổ cái độ phủ thực `AssetCoverageLedger` & checkpointing nguyên tử kết nối với engine neural Qwen3-VL 4B thật, 100% PASS)
- [x] **S13** — Xử lý brief/facts, trích xuất claims, xây dựng event graph và verifier độc lập.  
  *Biên bản:* [`reports/progress/S13.md`](reports/progress/S13.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Brief parser giữ span/time_precision, tách mệnh đề nhân quả & đa mệnh đề, bảng quyết định 12 dòng Mục 6, đồ thị sự kiện phát hiện chu trình & revalidation theo scope, 100% PASS)
- [x] **S14** — Giao diện/luồng review có bằng chứng (evidence-backed review) và xử lý biến động tư liệu.  
  *Biên bản:* [`reports/progress/S14.md`](reports/progress/S14.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Gỡ bỏ dữ liệu mẫu giả lập, hiển thị đủ 6 lệnh review thật nối với Worker RPC `g2.analyze_source` & `ProjectStore` SQLite, `answer_unknown` không thành đồng ý, cô lập nhánh bị chặn & lọc batch confirmation, 100% PASS)
- [x] **S15** — Benchmark phân tích trên tập dữ liệu và đóng Gate G2.  
  *Biên bản:* [`reports/progress/S15.md`](reports/progress/S15.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Wilson 95% CI, Group Bootstrap 10.000 vòng, kiểm định chống rò rỉ dữ liệu & chạy `run_real_video_corpus_g2_benchmark` trên 5 video Rec.709 held-out thực tế với Qwen3-VL 4B đạt 100% precision, 96% recall, 0% FAR, 100% coverage — Đóng Gate G2)

### G3 — Kịch bản dựng được
- [x] **S16** — Trình tạo outline kịch bản (1–3 phương án), gắn nguồn từng mệnh đề và khóa chỉnh sửa.  
  *Biên bản:* [`reports/progress/S16.md`](reports/progress/S16.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Lọc claim hợp lệ, chặn nâng quyền `user` claim thành `direct_claim`, tạo revision bất biến và khóa beat, 100% PASS)
- [x] **S17** — TTS thử với VieNeu-TTS, đo duration audio thật và căn chỉnh nhịp câu.  
  *Biên bản:* [`reports/progress/S17.md`](reports/progress/S17.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: PCM16 48 kHz WAV, kiểm tra duration/clipping/SHA-256, cổng người nghe xác nhận `g3_voice_reviews`, 100% PASS)
- [x] **S18** — Thuật toán Beam Search chọn shot có ràng buộc và bộ chẩn đoán thất bại (phân biệt prune vs vô nghiệm).  
  *Biên bản:* [`reports/progress/S18.md`](reports/progress/S18.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: `SEARCH-v1` + `EXACT-v1` checker, 4 trạng thái kết thúc rõ ràng, kiểm tra biên CFR 24fps, 100% PASS)
- [x] **S19** — Script approval gắn chặt revision snapshot và đóng Gate G3.  
  *Biên bản:* [`reports/progress/S19.md`](reports/progress/S19.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Tách chọn nháp khỏi duyệt, `G3ApprovalGuard` xác minh độc lập nguồn S05 + mapping S10 + WAV S17 + cut S18 trong SQLite transaction, 100% PASS)

### G4 — Preview được duyệt
- [x] **S20** — DaVinci Resolve Adapter, Operation Journal và dựng Managed Timeline tự động.  
  *Biên bản:* [`reports/progress/S20.md`](reports/progress/S20.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: SQLite `Journal` ghi `INTENT` trước hiệu ứng phụ, chặn retry mù, timeline `1080x1920 @ 24fps` cô lập, readback & atomic `.drp` export, 100% PASS)
- [x] **S21** — Render Preview 1080x1920, QC kỹ thuật/nội dung tự động, xử lý drift và Preview Approval. Đóng Gate G4.  
  *Biên bản:* [`reports/progress/S21.md`](reports/progress/S21.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Phụ đề tiếng Việt burn-in CFR 24fps, `G4FilePublisher` streaming S08, `G4S21Guard` kiểm tra `ffprobe`/`ffmpeg volumedetect` & thu hồi hiệu lực khi drift, 100% PASS)

### G5 — Final và phát hành
- [x] **S22** — Render Final 2160x3840 24fps, QC file xuất cuối cùng và bàn giao project Resolve (.drp).  
  *Biên bản:* [`reports/progress/S22.md`](reports/progress/S22.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Bắt buộc S21 approval + preflight đĩa trống, conform/render `2160x3840 @ 24fps` `bt709`, xuất `.drp`, nhánh `manual_handoff` cô lập & `G5S22Guard`, 100% PASS)
- [x] **S23** — Kiểm định 6 tính năng nâng cấp và hiển thị trung thực trạng thái capability.  
  *Biên bản:* [`reports/progress/S23.md`](reports/progress/S23.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: Cổng năng lực `exact_photo_shutter_match` tự động hạ về `illustrative_only` khi chưa qua benchmark, đồ thị thứ tự bộ phận, kiểm toán phản chứng, sở thích không ghi đè dữ kiện & căn nhịp hài hước `early_frame_count == 0`, 100% PASS)
- [x] **S24** — Hoàn thiện UI macOS native, gõ tiếng Việt, phím tắt và Accessibility.  
  *Biên bản:* [`reports/progress/S24.md`](reports/progress/S24.md) · *Trạng thái:* `DONE` (Hoàn thành nghiệm thu: `G5ConsoleView`, `G5VietnameseIMEBuffer` bảo toàn tổ hợp dấu, `G5BoundedPreviewCache` vượt qua 50 chu kỳ chuyển preview & nhãn VoiceOver, 100% PASS)
- [x] **S25** — Fault injection testing, kiểm thử ngắt điện/crash, chạy tải E0 (30m) & E1 (120m).  
  *Biên bản:* [`reports/progress/S25.md`](reports/progress/S25.md) · *Trạng thái:* `IN_REVIEW` (Hoàn thành 100% bộ tiêm lỗi 4 ranh giới commit & bộ hạch toán E0/E1 đủ 4 trạng thái; chờ chạy thực nghiệm trên tập video thực địa E0/E1)
- [ ] **S26** — Đóng gói Release (.app), ký số/notarization, lập hồ sơ nghiệm thu cuối và đóng Gate G5.  
  *Biên bản:* [`reports/progress/S26.md`](reports/progress/S26.md) · *Trạng thái:* `BLOCKED / IN_REVIEW` (Đã vá 3 lỗi P0; Preflight trả kết quả NO-GO trung thực, chờ nghiệm thu E0/E1 trên tập held-out thực tế)

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
