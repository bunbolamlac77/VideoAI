# AIVideo — Antigravity Engineering Guidelines & Rules

Dự án: **AIVideo v3.1** — Trợ lý phân tích và dựng video POV tiếng Việt trên macOS.
Kiến trúc: **SwiftUI (Native macOS)** + **Swift Core (`ProjectStore`, SQLite WAL)** + **Python Workers (stdio JSON-RPC)** + **DaVinci Resolve Studio**.
Mục tiêu phần cứng: **Apple Silicon M1 Pro, 16 GB Unified RAM**.

---

## 1. Nguyên Tắc Cốt Lõi Bất Di Bất Dịch (Core Invariants)

1. **100% Local Inference**: Toàn bộ mô hình AI (VLM Qwen3-VL 4B, VieNeu-TTS, Whisper large-v3) và xử lý media chạy offline cục bộ trên máy Mac. **Tuyệt đối không gọi Cloud AI API** hoặc cloud fallback trong bất kỳ tình huống nào.
2. **Swift Core Độc Quyền Ghi Database (Single-Writer)**:
   - Chỉ Swift actor `ProjectStore` được quyền ghi/sửa SQLite canonical database (WAL mode).
   - Python Worker chỉ đọc dữ liệu hoặc nhận task qua JSON-RPC stdio và trả về kết quả tính toán; **không bao giờ mở kết nối write trực tiếp tới SQLite chuẩn**.
3. **Bằng Chứng Nguồn Minh Bạch (Provenance & Evidence First)**:
   - Mọi fact, claim, cut, shot selection trong kịch bản phải truy vết được nguồn: hash nội dung file media, timecode (IN/OUT frames) hoặc brief revision.
   - `Unknown` là trạng thái hợp lệ; nếu thiếu tư liệu, báo rõ `Unknown` thay vì bịa đặt (hallucinate).
4. **Ngân Sách RAM 16 GB & Heavy Lease Governor**:
   - Tuân thủ nghiêm ngặt Resource Governor: Không bao giờ chạy đồng thời các tác vụ nặng (VLM inference + TTS batch + DaVinci 4K render). Luôn yêu cầu Lease trước khi cấp phát tài nguyên.
5. **Tiêu Chuẩn Video & DaVinci Resolve**:
   - Định dạng mặc định: Video dọc (9:16). Preview 1080×1920; Final 2160×3840 (4K), chuẩn **24/1 fps**, audio tiếng Việt 1×.
   - DaVinci Resolve scripting chạy headless/offline qua IPC hoặc DaVinci Resolve MCP.

---

## 2. Tích Hợp 5 Bộ Công Cụ & Kỹ Năng (Installed Skills & Tools)

### ① `planning-with-files` (Quản Lý Tiến Độ Bằng File)
- **Tập tin trạng thái**: Mọi phiên làm việc phức tạp hoặc dài hạn phải duy trì 3 file cốt lõi trong repository:
  - `task_plan.md`: Lộ trình công việc, các phase, checklist bước hiện tại (đồng bộ với `PROGRESS_TRACKER.md` và các bước S00–S26).
  - `findings.md`: Các phát hiện kỹ thuật, thông số mô hình, giới hạn benchmark, cấu hình thực tế.
  - `progress.md`: Nhật ký những gì đã hoàn thành, kết quả test chạy thật, bằng chứng nghiệm thu.
- **Quy tắc**: Cập nhật `progress.md` và `task_plan.md` ngay sau mỗi bước chỉnh sửa lớn; không tuyên bố hoàn thành khi chưa thỏa mãn điều kiện nghiệm thu.

### ② `ui-ux-pro-max` (Thiết Kế UI/UX Chuẩn macOS)
- **Công cụ tra cứu**: Sử dụng script tra cứu thiết kế nội bộ:
  ```bash
  python3 ~/.gemini/config/plugins/ui-ux-pro-max/skills/ui-ux-pro-max/scripts/search.py "<query>" --stack swiftui
  ```
- **Quy chuẩn giao diện (theo `10-UI-UX-MACOS.md`)**:
  - Giao diện "Bàn biên tập bình tĩnh" (Calm Editor): Sidebar tinh gọn, Canvas preview lớn, Inspector bên phải.
  - Hỗ trợ đầy đủ Light Mode & Dark Mode sử dụng macOS Semantic Colors.
  - Bảng màu nhận diện: Primary Teal `#0F766E` (Light) / `#5EEAD4` (Dark), kết hợp SF Pro & SF Symbols native.
  - Monospaced digits (`.monospacedDigit()`) cho toàn bộ timecode, duration và chỉ số kỹ thuật.
  - Kích thước chạm/click tối thiểu: 44×44 pt; spacing tuân thủ thang 4, 8, 12, 16, 24, 32 pt.

### ③ `superpowers` (Quy Trình Kỹ Sư & TDD)
- **Test-Driven Development (TDD Red/Green/Refactor)**:
  - Viết test trước khi thêm logic mới: Swift test (`swift test`) cho Core / Store; Python test (`pytest tests/`) cho Worker.
  - Chạy test kiểm chứng trước khi xác nhận hoàn thành bất kỳ task nào.
- **Systematic Debugging**: Luôn tái hiện lỗi bằng minimal reproduction test, phân tích root cause trước khi sửa code; không sửa tạm hoặc đoán mò.
- **Subagent-Driven Execution**: Tự động chia nhỏ task theo bước S00–S26 và ủy nhiệm thực thi có kiểm soát.

### ④ `Anthropic Skills` (Bộ Kỹ Năng Tài Liệu, Kiểm Thử & Chuyên Môn)
- Sử dụng `webapp-testing` và `skill-creator` khi tạo quy trình kiểm thử mới hoặc mở rộng kỹ năng.
- Sử dụng `pdf`, `docx`, `pptx`, `xlsx` khi xử lý trích xuất tài liệu nguồn, xuất báo cáo QC và biên bản nghiệm thu Gates G0–G5.

### ⑤ `SKILL.md` (Chuẩn Kỹ Năng Dự Án)
- Mọi skill mới của dự án được lưu tại `.agents/skills/<skill-name>/SKILL.md` với đầy đủ frontmatter YAML (`name`, `description`).

---

## 3. Lệnh Kiểm Thử & Nghiệm Thu Thường Dùng

```bash
# Chạy toàn bộ test Python của workers và contracts (hỗ trợ chạy độc lập từng file)
for t in tests/test_*.py; do
  echo "Running $t..."
  workers/.venv/bin/python3 "$t"
done

# Chạy test suite Python với báo cáo JSONL có cấu trúc
workers/.venv/bin/python3 tools/run_python_tests.py

# Chạy test cụ thể theo từng Gate (ví dụ Gate G1, G2, G3)
workers/.venv/bin/python3 tests/test_g1_contracts.py
workers/.venv/bin/python3 tests/test_s10_media_indexer.py
workers/.venv/bin/python3 tests/test_s16_to_s19_g3.py

# Kiểm tra Swift Core package (biên dịch trực tiếp qua swiftc với SDK tương thích)
./tools/run_s06_tests.sh

# Chạy toàn bộ ma trận kiểm thử hồi quy Swift + Python + Codesign
./tools/run_tests.sh

# Đóng gói và cài đặt ứng dụng macOS vào /Applications
./tools/build_macos_app.sh --install
```
