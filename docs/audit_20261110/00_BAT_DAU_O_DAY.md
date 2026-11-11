# AIVideo v3.1 — BẮT ĐẦU TỪ ĐÂY (bản kiểm toán ngày 10/11/2026)

> ⚠️ **ẢNH CHỤP LỊCH SỬ — không phải trạng thái hiện tại.**
> Giữ nguyên nội dung để tra cứu quá trình; nguồn đúng hiện tại là
> [`README.md`](../../README.md) và
> [`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](../../docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).
> Sau ngày ghi trong tài liệu, dự án đã qua kiểm toán 2026-11-11 (9 P0 + 54 P1 + 14 nhóm P2) và
> một số chi tiết đã đổi: `fixtures/corpus` → `fixtures/smoke`, schema do Swift sở hữu,
> TTS là Kokoro-Vietnamese, Whisper chưa nối, gate G2/G5 vẫn IN_REVIEW.

> **Trạng thái: BẢN VÁ ĐÃ VƯỢT QUA KIỂM THỬ CÓ THỂ THỰC HIỆN TRONG LINUX; CHƯA ĐỦ ĐIỀU KIỆN TUYÊN BỐ PRODUCTION READY.**
> Tất cả đường dẫn trong ZIP đều tương đối với thư mục dự án; KHÔNG tự động áp dụng bất kỳ thay đổi nào trên Mac của bạn.

## 1. Trong ZIP có những gì?

- `00_BAT_DAU_O_DAY.md`: tài liệu này.
- `01_BAO_CAO_KIEM_TOAN.md`: đánh giá kỹ thuật, nguyên nhân gốc, mức độ P0/P1/P2, thay đổi đã áp dụng, rủi ro còn lại.
- `02_LENH_CHO_AI_LOCAL.md`: **bản giao nhiệm vụ rất chi tiết, dán nguyên văn cho AI local để rà soát, tích hợp, kiểm thử và hoàn thiện G0–G5**.
- `03_BANG_KIEM_NGHIEM_THU.md`: bảng nghiệm thu có thứ tự và lệnh chạy trên macOS M1 Pro 16 GB.
- `CHANGESET.patch`: unified Git patch chỉ chứa các sửa đổi so với ZIP nguồn người dùng gửi.
- `EVIDENCE/`: nhật ký thực thi, kết quả test và metadata bản chụp được kiểm toán.
- `SOURCE_CODE/`: mã nguồn **đầy đủ đã áp dụng bản vá** (không chứa model hàng GB, venv, cache, video người dùng hoặc app binary).

## 2. Cách đưa cho AI local (khuyến nghị)

1. Giải nén **ZIP này** vào một thư mục riêng, không giải nén đè dự án hiện đang chạy.
2. Cho AI local đọc `02_LENH_CHO_AI_LOCAL.md` rồi `01_BAO_CAO_KIEM_TOAN.md`, cuối cùng đối chiếu trực tiếp `SOURCE_CODE/` với repository đang dùng. Yêu cầu AI báo rõ commit hiện tại, mọi xung đột, các file ghi đè, kế hoạch backup.
3. Nếu mã nguồn trên máy **khớp với snapshot** đã kiểm toán, AI có thể áp dụng `CHANGESET.patch` trên một nhánh mới. Nếu mã nguồn đã thay đổi, AI cần gộp bản vá ở mức ý nghĩa và chạy lại tất cả test; không được ghi đè các thay đổi mới.
4. Dùng `03_BANG_KIEM_NGHIEM_THU.md` để đóng từng yêu cầu. Chỉ công bố “GO” sau khi đã chạy ứng dụng và Resolve trên macOS, có xác nhận từ kết quả thật.

## 3. Lệnh an toàn cho Mac của bạn

```bash
# Đầu tiên: mở thư mục GỐC dự án trên Mac (đổi đường dẫn nếu cần).
cd "$HOME/APP_CaNhan/AIVideo"

git status --short
git rev-parse HEAD

# Backup bằng Git hoặc một bản ZIP độc lập trước khi tích hợp.
# KHÔNG tự xóa model, database, file gốc, ảnh, video hoặc dữ liệu DaVinci.
# Tạo nhánh riêng nếu working tree sạch:
git switch -c audit-safety-20261110

# Nếu file bản vá nằm bên cạnh thư mục SOURCE_CODE/:
# thay /duong/dan/giai-nen bằng thư mục vừa giải nén.
git apply --check /duong/dan/giai-nen/CHANGESET.patch
# Chỉ chạy lệnh sau khi --check thành công và đã có backup:
git apply /duong/dan/giai-nen/CHANGESET.patch

# Chạy kiểm thử nhanh không phụ thuộc model thật:
python3 tools/run_python_tests.py
python3 -m unittest discover -s tools/autobridge/tests -p 'test_*.py' -v

# Kiểm tra model S11 trên đĩa; đây là KIỂM TRA LOCAL, không tải model:
python3 tools/setup_s11_model.py --verify

# Trên macOS M1 Pro (không chạy ở môi trường container Linux):
bash tools/build_macos_app.sh
python3 tools/check_readiness.py
```

> Nếu `git switch` không cho tạo nhánh do working tree đang có thay đổi, **không dùng `git reset --hard`**. Commit hoặc sao lưu phần đang làm, sau đó tạo nhánh. Nếu `git apply --check` thất bại, dừng ngay và yêu cầu AI local giải quyết từng xung đột bằng so sánh 3 chiều.

## 4. Điều đã xác minh và điều chưa thể xác minh

**Đã xác minh tại thời điểm đóng gói:** 152 bài test Python PASS (3 skipped), 21 test autobridge PASS, `compileall` PASS, parse cú pháp toàn bộ Swift PASS, 5/5 G1 Swift contracts PASS trên Linux, `bash -n` cho installer PASS, readiness trả `NO-GO` trung thực trong môi trường kiểm toán.

**Chưa xác minh:** SwiftUI arm64 app build và chạy thật trên Mac, DaVinci Resolve Studio tích hợp, thư viện MLX Metal và model Qwen/Whisper/TTS cài tại máy người dùng, ngân sách RAM 16 GB, E0/E1 5 video held-out thật, code signing phát hành/notarization, CI GitHub Actions của branch sau khi tích hợp.

## 5. Quy tắc tuyệt đối

- **Không gửi GitHub commit/push** khi chưa được chủ dự án xác nhận.
- Không tự tải model khi chạy `--verify`, không dùng cloud AI fallback, không tự tạo “bằng chứng” khống.
- Không làm sai bất biến dữ liệu: **Swift Core là writer duy nhất của SQLite canonical**; worker chỉ gửi kết quả qua JSON-RPC; mỗi claim phải có provenance; trạng thái `unknown` hợp lệ.
- Trước `--force`, sao lưu model hiện hữu. Hai lần rename ở bước thay model KHÔNG có nghĩa là một transaction đa thư mục bất khả phân khi máy mất điện; kiểm tra backup còn sót sau crash.
- Giữ nguyên project/timeline/video nguồn của người dùng. Lệnh build và test không được thay bằng hành động xóa tất cả dữ liệu.

**Câu lệnh mở đầu đề xuất:** “Đọc `02_LENH_CHO_AI_LOCAL.md`, kiểm tra commit Git hiện tại và so sánh với `SOURCE_CODE/`. Báo cáo danh sách thay đổi và kế hoạch backup. Áp dụng `CHANGESET.patch` ở nhánh riêng, chạy toàn bộ test thực tế rồi đi tiếp theo từng gate. Không tự khẳng định 100% khi thiếu bằng chứng.”
