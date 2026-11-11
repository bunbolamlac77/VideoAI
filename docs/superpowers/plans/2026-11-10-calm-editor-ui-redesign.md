# Calm Editor Workflow Redesign Implementation Plan

> ⚠️ **ẢNH CHỤP LỊCH SỬ — không phải trạng thái hiện tại.**
> Giữ nguyên nội dung để tra cứu quá trình; nguồn đúng hiện tại là
> [`README.md`](../../../README.md) và
> [`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](../../../docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).
> Sau ngày ghi trong tài liệu, dự án đã qua kiểm toán 2026-11-11 (9 P0 + 54 P1 + 14 nhóm P2) và
> một số chi tiết đã đổi: `fixtures/corpus` → `fixtures/smoke`, schema do Swift sở hữu,
> TTS là Kokoro-Vietnamese, Whisper chưa nối, gate G2/G5 vẫn IN_REVIEW.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chuyển đổi toàn bộ giao diện macOS từ 9 tab kỹ thuật rời rạc sang Quy trình biên tập 4 bước tuyến tính (Calm Editor Workflow) với dữ liệu liên kết ngầm tự động (Zero-UUID copy-paste).

**Architecture:** Bổ sung `WorkflowStep` tuyến tính và cơ chế auto-wiring (`currentDraftPublicationId`, `approvedCues`, `approvedBeats`) vào `AppState`. Tái cấu trúc thanh Sidebar thành 2 nhóm: nhóm chính 4 bước (Tư liệu → Kịch bản & Thoại → Xem trước Preview → Xuất bản Final) và nhóm công cụ kỹ thuật / chuẩn đoán (Diagnostics/Dev). Bổ sung thanh tiến trình Stepper trực quan và tự động đồng bộ tham chiếu giữa G3, G4 và G5.

**Tech Stack:** macOS Native SwiftUI (macOS 14+), Swift 6 strict concurrency, AppKit, SF Pro & SF Symbols, DaVinci Resolve scripting.

**Spec:** [docs/10-UI-UX-MACOS.md](file:///Users/phuthanh/APP_CaNhan/AIVideo/docs/10-UI-UX-MACOS.md), [GEMINI.md](file:///Users/phuthanh/APP_CaNhan/AIVideo/GEMINI.md), [aivideo-ui-designer](file:///Users/phuthanh/APP_CaNhan/AIVideo/.agents/skills/aivideo-ui-designer/SKILL.md).

## Global Constraints
- 100% Local Inference (Apple Silicon Metal MLX, Whisper large-v3, VieNeu-TTS offline).
- SQLite single-writer qua `ProjectStore` actor; không phá vỡ contracts dữ liệu S00–S26 và các Gate G0–G5.
- Tuân thủ palette màu Calm Editor: Deep Teal `#0F766E` (Light) / Mint Teal `#5EEAD4` (Dark).
- Giữ nguyên các chức năng cốt lõi và khả năng kiểm thử của G0–G5, chuyển các trường nhập liệu kỹ thuật (UUID, SHA-256, JSON thô) vào nhóm "Tùy chọn nâng cao / Debug".
- Tránh giật lag main actor; các tác vụ nặng (ffprobe, sha256 fingerprint, VLM) chạy background detached task.

## Review Focus
1. Tự động luân chuyển `mappingPublicationId` từ G3 sang G4 và G5 mà không bắt người dùng nhập tay.
2. Tự động chuyển các câu thoại (Beats) đã duyệt ở G3 thành phụ đề Cues mặc định ở G4 và G5.
3. Thanh Stepper 4 bước hiển thị đúng trạng thái hoàn thành (Badge / Checkmark) và hỗ trợ điều hướng 1-click.
4. Đảm bảo chế độ "Nâng cao / Debug" vẫn cho phép nhà phát triển kiểm tra RPC, test spike Resolve, hay xem JSON thô khi cần.
5. Biên dịch `swiftc -swift-version 6` không sinh cảnh báo hoặc lỗi data race / concurrency.

---

### Task 1: Cập nhật `AppState` để quản lý luồng 4 bước và liên kết dữ liệu tự động

**Files:**
- Modify: `apps/macos/Sources/AIVideoApp.swift:50-130`

**Interfaces:**
- Consumes: `AppState`, `MediaSourceItem`, `ProjectStore`, `ClaimRecord`, `TargetedReviewRecord`
- Produces: 
  - `enum WorkflowStep: String, CaseIterable, Identifiable { case assets, story, preview, export }`
  - `AppState.currentStep: WorkflowStep`
  - `AppState.latestG3PublicationId: String`
  - `AppState.latestG4PublicationId: String`
  - `AppState.cachedStoryBeats: [G3BeatItem]`
  - `AppState.cachedCaptionCues: [G4CaptionCue]`
  - `AppState.advanceToNextStep()`

- [ ] **Step 1: Định nghĩa `WorkflowStep` và các thuộc tính liên kết trong `AppState`**
  Thêm `WorkflowStep` với 4 bước trực quan:
  1. `.assets`: "1. Tư liệu" (Chọn folder, quét AI Qwen3-VL, trích xuất fact)
  2. `.story`: "2. Kịch bản & Thoại" (Duyệt fact, tạo storyboard, sinh giọng đọc VieNeu-TTS)
  3. `.preview`: "3. Xem trước (Preview)" (Dựng timeline 1080×1920 dọc có sub, kiểm tra QC)
  4. `.export`: "4. Xuất bản (Final 4K)" (Render 2160×3840 24fps, mở DaVinci Resolve)

- [ ] **Step 2: Thêm logic tự động đồng bộ (Auto-sync) khi duyệt S19**
  Khi G3 hoàn thành phê duyệt, cập nhật `latestG3PublicationId`, sao chép beats thành cues và bật cờ hoàn thành bước.

- [ ] **Step 3: Biên dịch kiểm tra cú pháp**
  Run: `./tools/build_macos_app.sh`
  Expected: PASS

---

### Task 2: Thiết kế thanh Stepper điều hướng & Tái cấu trúc Sidebar trong `AIVideoApp.swift`

**Files:**
- Modify: `apps/macos/Sources/AIVideoApp.swift:1240-1410`

**Interfaces:**
- Consumes: `AppState.currentStep`, `AppSection`
- Produces: 
  - `WorkflowStepperView`: Thanh tiến trình 4 bước đặt ở đầu trang chi tiết, có nút "Tiếp tục sang bước sau →"
  - Phân nhóm Sidebar mới:
    - "Quy trình dựng (POV Workflow)" (4 bước chính)
    - "Dữ liệu & Kiểm chứng" (Kiểm chứng G2, Dữ liệu & Backup)
    - "Hệ thống & Chẩn đoán" (Model Local, DaVinci Resolve, Năng lực RPC)

- [ ] **Step 1: Tạo `WorkflowStepperView`**
  Hiển thị 4 nốt tròn liên kết bằng đường kẻ, có icon, tên bước, trạng thái hiện tại (`active`), đã xong (`completed`), và chưa tới (`pending`).
  Có nút primary action ở góc phải: "Tiếp tục: [Tên bước tiếp theo] →".

- [ ] **Step 2: Cập nhật Sidebar trong `ContentView`**
  Ưu tiên hiển thị 4 bước chính nổi bật nhất. Người dùng chỉ cần click bước 1, 2, 3, 4 theo thứ tự tự nhiên. Các phần kỹ thuật được xếp vào nhóm phụ thu gọn bên dưới.

- [ ] **Step 3: Biên dịch kiểm tra giao diện**
  Run: `./tools/build_macos_app.sh`
  Expected: PASS

---

### Task 3: Tinh giản `G3ConsoleView.swift` & Tự động kết nối sang G4

**Files:**
- Modify: `apps/macos/Sources/G3ConsoleView.swift:170-380`

**Interfaces:**
- Consumes: `state.g1Claims`, `state.g2ReviewItems`
- Produces:
  - Tự động điền Fact Claim nguồn từ danh sách G2 đã duyệt.
  - Sau khi người dùng nghe thử TTS và bấm "Phê duyệt kịch bản S19": tự động lưu `publicationId` vào `state.latestG3PublicationId`, tự động chuyển beats sang `state.cachedStoryBeats`.
  - Đóng gói các thông số beam search (Forward Check, Node Budget, Beam Width) và JSON thô vào `DisclosureGroup("Tùy chọn nâng cao & Raw JSON")`.
  - Nút "Chuyển sang Bước 3: Xem trước bàn dựng →" xuất hiện ngay sau khi phê duyệt.

- [ ] **Step 1: Giấu các trường kỹ thuật không cần thiết**
  Đưa ô nhập SHA-256 hex 64 ký tự và Publication UUID vào chế độ tự động tính toán từ file âm thanh thực tế; người dùng chỉ cần bấm nút "Nghe thử" và tích "Đã nghe kiểm tra".

- [ ] **Step 2: Auto-wire kết quả sang AppState**
  Ghi nhận `latestG3PublicationId` để G4 tự động dùng mà không bắt user copy.

- [ ] **Step 3: Thêm nút chuyển bước**
  Sau khi duyệt kịch bản, hiển thị banner thành công và nút chuyển sang Preview.

- [ ] **Step 4: Biên dịch kiểm tra**
  Run: `./tools/build_macos_app.sh`
  Expected: PASS

---

### Task 4: Tinh giản `G4ConsoleView.swift` (Zero Manual UUID)

**Files:**
- Modify: `apps/macos/Sources/G4ConsoleView.swift:70-220`

**Interfaces:**
- Consumes: `state.latestG3PublicationId`, `state.cachedStoryBeats`
- Produces:
  - Tự động nhận `mappingPublicationId` từ G3 nếu có.
  - Tự động sinh danh sách cues phụ đề từ các câu thoại của kịch bản đã duyệt.
  - Bổ sung nút 1-click: "Dựng & Xem trước Timeline 1080×1920".
  - Giấu toàn bộ Raw JSON và asset list thô vào `DisclosureGroup`.
  - Nút "Chuyển sang Bước 4: Xuất bản Final 4K →".

- [ ] **Step 1: Auto-fill `mappingPublicationId` và `cues`**
  Khi mở G4, nếu `mappingPublicationId` trống, tự động nạp từ `state.latestG3PublicationId`.
  Nếu `cues` chưa có, tự động chuyển đổi từ các beats của kịch bản đã duyệt.

- [ ] **Step 2: 1-Click Preview Action**
  Tập trung vào 1 nút duy nhất "Dựng & Xem trước Timeline 1080×1920".

- [ ] **Step 3: Biên dịch kiểm tra**
  Run: `./tools/build_macos_app.sh`
  Expected: PASS

---

### Task 5: Tinh giản `G5ConsoleView.swift` (1-Click 4K & DaVinci Handoff)

**Files:**
- Modify: `apps/macos/Sources/G5ConsoleView.swift:70-200`

**Interfaces:**
- Consumes: `state.latestG3PublicationId`, `state.latestG4PublicationId`
- Produces:
  - Tự động nhận `mappingPublicationId` từ G4 (hoặc G3).
  - Tự động lấy danh sách cues đã chuẩn hóa.
  - Nút 1-Click: "Xuất video Final 4K (2160×3840 24fps)".
  - Nút 1-Click: "Mở trong DaVinci Resolve Studio".
  - Giấu Raw JSON và bảng mã hex vào disclosure group.

- [ ] **Step 1: Auto-fill và rút gọn giao diện**
  Tự động kế thừa các thông số đã duyệt từ các bước trước.

- [ ] **Step 2: Biên dịch và nghiệm thu tổng thể**
  Run: `./tools/build_macos_app.sh --install`
  Expected: Ứng dụng build thành công, ad-hoc codesign đạt, cài đặt vào `/Applications/AIVideo.app`.
