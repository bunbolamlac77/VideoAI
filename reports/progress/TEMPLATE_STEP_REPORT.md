# Báo Cáo Đoạn Code Triển Khai: Bước Sxx — [Tên Bước]

> **Dành cho:** Người dùng & AI Độc lập (External Reviewer) đánh giá chéo  
> **Dự án:** AIVideo v3.1 (macOS Native POV Video Assistant)  
> **Tài liệu đặc tả liên quan:** `docs/README.md`, `docs/11-CODING-WORKFLOW-AND-CHECKLIST.md` và các file `01-10`.

---

## 1. Thông Tin Phiên Làm Việc

- **Bước thực hiện:** Sxx — [Tiêu đề bước]
- **Gate:** G0 / G1 / G2 / G3 / G4 / G5
- **Trạng thái bước:** `DONE` / `IN_PROGRESS` / `BLOCKED` / `IN_REVIEW`
- **Môi trường thực tế:**
  - Máy / Chip / RAM: Apple Silicon M1 Pro, 16 GB Unified Memory
  - Hệ điều hành: macOS [Phiên bản]
  - Công cụ: Xcode [Version], Swift [Version], Python [Version], DaVinci Resolve [Version]
- **Tài liệu hợp đồng sở hữu:** [Liệt kê tài liệu, ví dụ: 05-ARCHITECTURE-AND-ROADMAP.md]
- **Thời điểm tạo báo cáo:** YYYY-MM-DD HH:mm:ss

---

## 2. Tóm Tắt Mục Tiêu & Yêu Cầu Kỹ Thuật

- **Đầu vào (Inputs):** [Liệt kê dữ liệu, artifact hoặc trạng thái trước khi code đoạn này]
- **Đầu ra kỳ vọng (Expected Outputs):** [Liệt kê artifacts, files, APIs, database tables cần đạt]
- **Ràng buộc cốt lõi (Core Invariants):**
  - [Ví dụ: Không gọi Cloud AI, Swift Core là nơi duy nhất commit SQLite WAL, worker không cấp approval...]

---

## 3. Chi Tiết Những Gì Đã Code & Triển Khai Thực Tế

### 3.1. Danh mục files được tạo mới hoặc chỉnh sửa
| STT | Đường dẫn file | Thao tác (Tạo/Sửa) | Vai trò trong hệ thống |
|---|---|---|---|
| 1 | `packages/AIVideoCore/...` | Tạo mới | Core actor quản lý trạng thái |
| 2 | `...` | ... | ... |

### 3.2. Điểm nhấn kiến trúc & Mã nguồn chính
- **Cấu trúc dữ liệu & Interfaces:**
  ```swift
  // Code snippet trích xuất interface chính
  ```
- **Xử lý bất đồng bộ & Actor Concurrency:**
  [Giải thích cách đảm bảo Thread-safety, Fencing token, chống zombie task]
- **Xử lý ngoại lệ & Biên độ an toàn:**
  [Cách xử lý lỗi: crash-recovery, rollback, không làm hỏng dữ liệu gốc]

---

## 4. Kết Quả Kiểm Thử Thực Tế (Verification & Evidence)

> *Ghi chú bắt buộc: Không dùng mock để giả mạo thành công; ghi nhận đúng output thực thi.*

### 4.1. Ma trận ca kiểm thử (Test Matrix)
| Mã kiểm thử (ID) | Mô tả ca kiểm | Lệnh chạy | Kết quả (PASS / FAIL / BLOCKED) |
|---|---|---|---|
| `Sxx.T1` | Kiểm tra... | `swift test --filter ...` | **PASS** |
| `Sxx.T2` | Kiểm tra... | `pytest ...` | **PASS** |

### 4.2. Trích xuất Log chạy thực tế (Terminal Output)
```text
=== CHỨNG CỨ CHẠY TEST THỰC TẾ TRÊN MÁY ===
[Dán raw log từ terminal tại đây]
```

---

## 5. Những Gì Chưa Làm / Giới Hạn Còn Lại

- [ ] Hạng mục chưa triển khai trong bước này (nếu có):
- [ ] Sự phụ thuộc cần giải quyết ở bước tiếp theo:
- [ ] Rủi ro tiềm ẩn cần theo dõi:

---

## 6. Prompt Dành Cho AI Khác Xem Và Đánh Giá (Audit Prompt)

*Người dùng có thể copy toàn bộ đoạn prompt dưới đây cùng file này gửi cho AI khác (như Claude 3.7 Sonnet, ChatGPT o3-mini/GPT-4o) để nhận xét, phản biện:*

```text
Bạn là Chuyên gia Đánh giá Mã nguồn (Senior Software Architect & Code Auditor).
Hãy đọc kỹ báo cáo triển khai bước Sxx của dự án AIVideo v3.1 dưới đây và đánh giá độc lập:

1. Tính đúng đắn so với đặc tả:
   - Đoạn code và kiến trúc triển khai có tuân thủ nguyên tắc: 100% Local, Swift Core quản lý ProjectStore duy nhất ghi DB, worker Python cách ly qua JSON-RPC stdio không?
   - Có vi phạm bất biến nào về bảo vệ nguồn tư liệu người dùng không?

2. Chất lượng kỹ thuật & Biên an toàn:
   - Cơ chế xử lý lỗi, timeout, crash-recovery và fencing token có chặt chẽ không?
   - Có nguy cơ rò rỉ bộ nhớ (memory leak), race conditions trên Swift Concurrency hoặc orphan subprocess không?

3. Giá trị của kiểm thử:
   - Các bài test có kiểm tra được các ca biên (edge cases), dữ liệu hỏng, file thiếu quyền hay chỉ là test luồng thuận (happy path)?
   - Log chạy test có đủ thuyết phục để kết luận bước này hoàn thành (DONE) chưa?

4. Chấm điểm & Khuyến nghị:
   - Cho điểm trên thang 10 (Chất lượng, An toàn, Tuân thủ).
   - Chỉ ra 2-3 điểm cần hoàn thiện hoặc cảnh báo trước khi tiến sang bước tiếp theo.
```
