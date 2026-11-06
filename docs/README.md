# AIVideo v3.1 — Bộ đặc tả triển khai và nghiệm thu

**Phiên bản tài liệu:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** thiết kế nâng cấp để triển khai; chưa phải ứng dụng đã được lập trình, benchmark hoặc nghiệm thu.  
**Đối tượng:** người phát triển ứng dụng, coding agent và người kiểm thử trên Mac mục tiêu.

## 1. Đọc gì trước và dùng bộ này như thế nào

Bắt đầu bằng [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md). File đó chứa **27 bước S00–S26**, checklist công việc, kiểm thử có ý nghĩa, điều kiện chuyển bước, đầu ra phải giữ và prompt giao việc cho coding agent. Tất cả ô được để trống vì ứng dụng chưa được kiểm chứng trong lần nâng cấp tài liệu này.

Đọc README để hiểu các quyết định chung; sau đó mở tài liệu sở hữu hợp đồng của bước đang làm. Không giao toàn bộ hệ thống cho coding agent trong một lượt rồi đánh dấu hoàn thành chỉ vì có nhiều file code. Mỗi bước cần commit hoặc định danh phiên bản tương đương, kết quả kiểm thử và hạn chế còn lại.

Bộ ZIP có **12 file Markdown đầy đủ**: `README.md` và các tài liệu `01`–`11`. Tên file đã chuẩn hóa, không có hậu tố tải xuống `(2)` hoặc `(3)`. Đây là bộ thay thế hoàn chỉnh, không phải các đoạn bổ sung cần ghép vào tài liệu cũ. Có thể đặt cả 12 file trong thư mục `docs/` của repository; các liên kết tương đối hoạt động khi chúng nằm cạnh nhau.

> Tài liệu v3.1 thay thế các bộ v2/v3.0 cho công việc triển khai tiếp theo. Những ví dụ dữ liệu, profile thử và ngưỡng nghiệm thu là thiết kế hoặc mục tiêu, không phải dữ liệu thật hay thành tích đã đạt của ứng dụng.

### 1.1. Thay bộ tài liệu cũ

1. Giải nén `AIVideo-MD-v3.1.zip`; mở thư mục `AIVideo-MD-v3.1` bên trong.
2. Đặt đủ 12 file Markdown của thư mục này vào vị trí tài liệu đang dùng trong dự án, thay bộ Markdown cũ. Giữ các tên chuẩn ở bảng mục 5; không để hai phiên bản khác nhau cùng mang vai trò đặc tả hiện hành.
3. Mở `README.md`, sau đó dùng `11-CODING-WORKFLOW-AND-CHECKLIST.md` để bắt đầu hoặc đối chiếu tiến độ. Những bước chưa có bằng chứng vẫn để trống; cập nhật tài liệu không làm một bước triển khai tự hoàn thành.

### 1.2. Các chỉnh sửa được thống nhất trong v3.1

- **Review theo đúng loại nguồn:** câu hỏi có thể dựa trên video, audio, ảnh hoặc đoạn brief đúng revision. Khoảng source và ngữ cảnh trước/sau chỉ áp dụng khi có media theo thời gian; không ép gắn clip minh họa cho một dữ kiện ngoài camera. Hợp đồng dữ liệu, chính sách phân tích, UI và checklist dùng cùng quy tắc.
- **Fixture beam search tái hiện đúng điều cần kiểm:** tách ca cố ý để beam prune mất nghiệm, ca forward check tìm được nghiệm ngay và ca exact checker chứng minh vô nghiệm trong miền đã khai báo. Không bắt thuật toán báo hết ngân sách khi nó đã tìm được cut hợp lệ. Tài liệu 07, 09 và bước S18 được đồng bộ.
- **Bộ thay thế đồng nhất:** đủ 12 tài liệu, ngày/phiên bản được cập nhật, tên file và liên kết được chuẩn hóa. Stack SwiftUI + Swift core + Python + Resolve, model candidates, baseline toàn frame, profile media/search và các ngưỡng chất lượng tiếp tục theo các hợp đồng đã chốt.

Phiên bản tài liệu **3.1** không tự đổi phiên bản model, artifact, database schema hoặc protocol. Ví dụ `VieNeu v3`, `large-v3`, “Ghi chú v3” và “Duyệt preview v3” vẫn giữ đúng ý nghĩa riêng của chúng.

## 2. Sản phẩm cần xây

AIVideo là trợ lý phân tích và dựng video POV tiếng Việt trên macOS. Người dùng nhập tư liệu và dữ kiện ngày làm việc, bổ sung thông tin theo đoạn, giải quyết câu hỏi có bằng chứng, chỉnh và duyệt kịch bản, rồi xem và duyệt preview. AI thực hiện phần phân tích, đề xuất, dựng và kiểm tra trong phạm vi đã được cho phép.

Chất lượng hiểu tư liệu, tính đúng của câu chuyện, tiếng Việt tự nhiên và khả năng sửa bản dựng được ưu tiên hơn tốc độ. Người dùng không phải xem lại toàn bộ source. Yêu cầu chỉ hai thao tác đã được loại khỏi luồng hiện hành.

Đầu ra mặc định:

- Video dọc, thường 45–90 giây; tư liệu ít có thể ngắn hơn; thời lượng file cuối luôn **dưới 180 giây**.
- Preview 1080×1920; final 2160×3840, **24/1 fps** theo profile đã nghiệm thu.
- Giọng tiếng Việt 1×; phụ đề, ảnh và âm thanh có chủ đích.
- Project Resolve, nguồn text/style cần thiết, manifest và báo cáo QC; mức chỉnh sửa được phải ghi đúng bản chất.
- Suy luận và xử lý media local sau pha cài đặt. Không gọi API AI đám mây làm phương án dự phòng trong project.

Kích thước 4K không chứng nhận nguồn có lượng chi tiết 4K dọc. Video hay, hài hoặc hợp gu vẫn cần mẫu đánh giá và sự quyết định của người dùng.

## 3. Luồng chuẩn

1. Tạo project, chọn nguồn, kiểm quyền, định dạng và dung lượng.
2. Tạo bản chụp nguồn có phiên bản nội dung để phân tích; giữ nguyên file người dùng.
3. Nhập brief ngày/buổi; lưu nguyên văn, tách fact nháp và ràng buộc.
4. Phân tích hình, lời, âm thanh và ảnh; ghi độ phủ đầu vào thực tế, lỗi và nguồn kết luận.
5. Rà câu hỏi có ảnh hưởng; người dùng sửa, xác nhận theo phạm vi, giữ chưa rõ hoặc bỏ chi tiết.
6. Tạo 1–3 kịch bản thực sự dựng được, có TTS thử, shot và nguồn cho các mệnh đề.
7. Người dùng chọn, sửa và duyệt đúng script revision.
8. Dựng preview từ edit plan có phiên bản; QC kỹ thuật và nội dung.
9. Người dùng xem/nghe và duyệt đúng preview revision.
10. Render final từ các artifact đã được duyệt, QC chính file cuối, lưu kết quả và bản Resolve bàn giao.

Một câu hỏi chưa giải quyết chỉ chặn phần phụ thuộc. Các công việc độc lập tiếp tục chạy trong giới hạn tài nguyên. Không có phương án đủ điều kiện thì báo rõ phần thiếu, giữ phân tích và cho bổ sung; không tạo sự kiện để vượt cổng.

## 4. Những quyết định v3.1 khép các khoảng trống đánh giá

| Khoảng trống | Quyết định triển khai v3.1 | Nơi sở hữu chi tiết |
|---|---|---|
| Quyền ghi nghiệp vụ chưa rõ | Swift core có `ProjectStore` cho từng project; worker không ghi SQLite chuẩn, không cấp approval. | 05 |
| IPC còn nhiều lựa chọn | MVP dùng JSON-RPC 2.0 qua UTF-8 JSON Lines/stdin–stdout; có handshake, giới hạn payload và định danh lần chạy. | 05 |
| Worker cũ trả kết quả muộn | Fencing token, attempt identity và kiểm quyền công bố trước commit; thu hồi quyền không đồng nghĩa tiến trình đã chết. | 05 |
| DB và file có thể lệch khi crash | Công bố artifact theo PREPARED → MATERIALIZED → VERIFIED → COMMITTED; startup reconciler xử lý từng điểm gián đoạn. | 05 |
| File nguồn thay đổi bên ngoài | Phân tích và render từ managed source snapshot theo content revision; clone/copy được kiểm, không dùng hardlink như bằng chứng bất biến. | 02, 05 |
| Thêm clip nhưng dependency cũ không biết | Version của phạm vi bằng chứng và query manifest; đánh giá lại phần chịu tác động, giữ cache quan sát nguồn cũ. | 02, 07 |
| Beam search thất bại bị hiểu thành vô nghiệm | Phân biệt chưa tìm ra, hết ứng viên/ngân sách và vô nghiệm đã chứng minh trong miền xác định. | 07 |
| Cùng config bị hiểu thành cùng output | Giữ nguyên bytes của WAV/graphics/artifact đã duyệt; tái sinh có thay đổi phải có revision và duyệt phù hợp. | 04, 05 |
| Sửa trực tiếp Resolve làm lệch bản duyệt | Timeline managed và nhánh bàn giao thủ công riêng; phát hiện drift thì chặn, giữ bản sửa tay; MVP chưa đồng bộ hai chiều. | 04, 05 |
| VFR/HDR/màu chỉ mới là yêu cầu | Profile conform có version, timebase hữu tỷ, khoảng `[start,end)`, mapping frame; SDR Rec.709 là đầu ra MVP. | 04, 07 |
| Backup chưa chứng minh restore | Snapshot DB nhất quán + manifest + artifact pins; phân biệt backup checkpoint và portable; restore thử vào nơi mới. | 05 |
| Đóng gói để quá muộn | Gate G0 có `.app` tối thiểu, worker, quyền file, model local, offline và Resolve spike 10 giây. | 05, 11 |
| Có checklist nhưng chưa có hợp đồng đo | 09 định nghĩa ID ca thử, đơn vị, mẫu số, target v0.1, phạm vi và bằng chứng; không biến target thành kết quả. | 09 |

## 5. Bản đồ tài liệu và quyền sở hữu

| File | Trách nhiệm chuẩn | Khi nào cần đọc |
|---|---|---|
| [01-PRODUCT.md](01-PRODUCT.md) | Người dùng, phạm vi, luồng, mức hỗ trợ và hành vi sản phẩm. | Trước khi mở rộng tính năng hoặc thay luồng. |
| [02-ANALYSIS-AND-DATA.md](02-ANALYSIS-AND-DATA.md) | Schema nghiệp vụ, nguồn, claims, scope, revisions, snapshots và quyết định được phép kể. | Trước khi tạo/sửa model dữ liệu hoặc validator. |
| [03-MODELS-AND-RESOURCES.md](03-MODELS-AND-RESOURCES.md) | Model/runtime candidates, cài đặt offline, profile và ngân sách máy. | Trước khi nạp model, tăng batch hoặc đóng gói phụ thuộc. |
| [04-SCRIPT-AND-EDIT.md](04-SCRIPT-AND-EDIT.md) | Kịch bản, TTS, caption, edit plan, preview/final và artifact đã duyệt. | Khi xây đường từ câu chuyện sang video. |
| [05-ARCHITECTURE-AND-ROADMAP.md](05-ARCHITECTURE-AND-ROADMAP.md) | Core, IPC, scheduler, quyền ghi, publication, Resolve side effects, backup và migration. | Trước khi code orchestration hoặc persistence. |
| [06-DECISIONS-AND-RISKS.md](06-DECISIONS-AND-RISKS.md) | Quyết định kiến trúc, lý do, giới hạn và các rủi ro cần chứng minh. | Khi cần thay quyết định hoặc đánh giá mức sẵn sàng. |
| [07-OPTIMIZATION.md](07-OPTIMIZATION.md) | Coverage, truy xuất, invalidation, tìm kiếm shot và tối ưu có ràng buộc. | Khi thay thuật toán, cache hay search policy. |
| [08-ACCURACY-FIRST.md](08-ACCURACY-FIRST.md) | Chính sách quan sát, phản chứng, mức chưa biết, verifier và điều kiện dừng. | Khi sửa prompt hoặc cách kết luận từ bằng chứng. |
| [09-UPGRADES-AND-ACCEPTANCE.md](09-UPGRADES-AND-ACCEPTANCE.md) | Registry tiêu chí nghiệm thu, fixture, metric, target và release gates. | Trước khi đánh dấu một năng lực hoặc mốc đã đạt. |
| [10-UI-UX-MACOS.md](10-UI-UX-MACOS.md) | Hành vi UI native, layout, nhập tiếng Việt, accessibility và kiểm thử UI. | Khi tạo/sửa màn hình và điều khiển. |
| [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md) | Thứ tự code S00–S26, công việc, bằng chứng, checklist và prompt. | File theo dõi tiến độ hằng ngày. |

Schema version, IPC protocol version, model revision, media-profile version và phiên bản bộ tài liệu là các định danh riêng. Số `3.1` của bộ này không bắt buộc database có schema version 3.

Khi có mâu thuẫn, dừng quyết định phụ thuộc, ghi ADR và sửa tài liệu sở hữu cùng các tham chiếu. Không tự chọn đoạn thuận lợi để bỏ qua yêu cầu. 11 điều phối tiến độ; nó không thay schema của 02 hoặc ngưỡng nghiệm thu của 09.

## 6. Phạm vi hỗ trợ cần được chứng minh

Máy mục tiêu được kế thừa là **Apple M1 Pro, 16 GB unified memory**. Chưa có benchmark của v3.1 trên máy này. Phiên bản macOS, Xcode/Swift, Resolve, API, runtime và dung lượng hiện tại phải được ghi lại ở G0; không lấy snapshot cũ làm môi trường đã được xác nhận.

Hai profile dưới đây là **phạm vi dự kiến để nghiệm thu**, chỉ trở thành mức hỗ trợ được công bố khi vượt gate tương ứng:

| Profile | Phạm vi dự kiến | Mục đích |
|---|---|---|
| E0 | Một workday; tối đa 30 phút video tổng; tối đa 30 asset; nguồn tới 4K60 trong ma trận codec đã kiểm. | Chứng minh vòng xử lý đầy đủ và khả năng phục hồi ban đầu. |
| E1 | 1–3 workday; tối đa 120 phút video tổng; tối đa 100 asset; một clip tối đa 30 phút; tối đa hai phiên camera; nguồn tới 4K60 trong ma trận đã kiểm. | Nghiệm thu release candidate trong tải được công bố. |

Định nghĩa phiên camera, tổng asset, định dạng được hỗ trợ và cách tính phạm vi theo 01/06/09. Các giới hạn là phạm vi kiểm chứng ban đầu, không phải số đo khả năng tối đa của M1 Pro. Muốn công bố hỗ trợ lớn hơn phải mở rộng profile và bộ thử.

Fixture UI 1.000 asset chỉ kiểm hành vi giao diện/tải dữ liệu và phục hồi UI. Nó không chứng nhận pipeline AI đã xử lý một project 1.000 asset.

Ứng dụng phải hiển thị rõ khi đầu vào vượt phạm vi bản phát hành đã kiểm. Một lỗi môi trường, hết RAM hoặc codec chưa hỗ trợ không được trình bày thành kết luận “tư liệu không có câu chuyện”.

## 7. Sáu cổng triển khai

| Gate | Bước trong 11 | Bằng chứng phải có |
|---|---|---|
| G0 — Nền tảng | S00–S03 | Bản `.app` tối thiểu, worker thực, quyền file, model local, offline và timeline Resolve thử. |
| G1 — Dữ liệu và phục hồi | S04–S09 | Contract, source snapshot, revision store, fencing, công bố artifact, restore/migration đã thử. |
| G2 — Phân tích và bằng chứng | S10–S15 | Media mapping, profile model, độ phủ frame, claims, review và bộ đo đã khóa. |
| G3 — Kịch bản dựng được | S16–S19 | Outline hợp lệ, WAV thật, cut có nghiệm, ràng buộc và script approval đúng snapshot. |
| G4 — Preview được duyệt | S20–S21 | Timeline managed, QC preview, xử lý drift và preview approval. |
| G5 — Final và phát hành | S22–S26 | Final QC, năng lực được bật đúng gate, UI, fault injection, tải đại diện và bản Release có hồ sơ nghiệm thu. |

Các bước có thể phát triển nhánh độc lập nếu phụ thuộc đã ổn định, nhưng không được đánh dấu gate hoàn thành khi còn yêu cầu bắt buộc chưa đạt. Capability tùy chọn chưa đạt phải giữ tắt và ghi rõ; không dùng việc tắt mọi năng lực khó để đạt chỉ số chất lượng đẹp.

## 8. Nguyên tắc không được phá vỡ

- Nguồn, trạng thái tri thức, trạng thái review và cách kể là các chiều riêng.
- Lời bạn xác nhận vẫn là lời bạn cung cấp; không tự biến thành quan sát thị giác.
- Chọn kịch bản, duyệt script và duyệt preview không xác nhận ngầm mọi fact.
- Mọi frame hợp lệ vẫn thuộc baseline phân tích chi tiết; không âm thầm giảm xuống lấy mẫu thưa.
- Độ phủ nguồn không phải độ hiểu đúng; không hiển thị confidence chưa hiệu chuẩn thành xác suất sự thật.
- Không biết là trạng thái hợp lệ; lỗi trọng yếu chặn đúng phần phụ thuộc.
- Worker và LLM không có quyền sửa trạng thái duyệt hoặc thực thi lệnh từ OCR/transcript/metadata.
- Không thay lời, shot có ý nghĩa, giọng hoặc mix đã duyệt mà giữ approval cũ.
- Retry không được tạo hiệu ứng Resolve trùng; chưa đối chiếu được thì phải chặn đúng trạng thái.
- Không xóa nguồn người dùng hoặc dữ liệu biên tập để giải quyết quota cache.
- Mọi kết quả kiểm thử được ghi đúng build, môi trường, dataset và phạm vi; chưa đo thì ghi chưa đo.

## 9. Phân biệt tài liệu đã có và ứng dụng đã làm

**Có trong gói này:** hợp đồng sản phẩm, cấu trúc dữ liệu, quyết định kỹ thuật, thuật toán, kế hoạch kiểm thử, UI và lộ trình code.

**Cần tạo khi triển khai:** repository code, JSON schema thực thi, migrations, `.app`, runtime đã pin, fixtures có quyền sử dụng, báo cáo benchmark, log fault injection, video mẫu và project Resolve thực tế. Các đường dẫn code hoặc lệnh trong 11 là cấu trúc đích cần xây, không phải file đã nằm trong ZIP.

Quy trình tiến độ: đọc bước → triển khai phạm vi đó → chạy các ca bắt buộc → lưu bằng chứng → review → tích checkbox. Chưa chạy trên Mac hoặc chưa xác minh kết quả thì giữ bước mở, ngay cả khi code đã compile.

## 10. Ngoài phạm vi

Tự đăng lên mạng xã hội, gọi cloud AI khi chạy project, lấy trend trực tuyến, tự tải nhạc không rõ quyền, tạo ảnh giả làm tư liệu sự kiện, cam kết viral, nhận diện danh tính từ khuôn mặt và tự động đồng bộ chỉnh sửa Resolve hai chiều không thuộc MVP.

Cover/caption mạng xã hội, nhiều phong cách và workspace nâng cao chỉ mở sau khi vòng lõi và cổng tương ứng đạt. Sáu nâng cấp phân tích/dựng được giữ trong kế hoạch tại 09, triển khai theo capability có thể nghiệm thu.

## 11. Tham chiếu kỹ thuật

Các URL nền tảng nằm trong từng tài liệu chuyên môn. Khi cài hoặc nâng cấp, pin revision đã kiểm chứng và đối chiếu tài liệu chính thức theo phiên bản thực. Một URL hiện hành, file weights có sẵn hoặc một ảnh screenshot không thay thế kết quả chạy thử trên cấu hình được công bố.

**Điểm bắt đầu tiếp theo:** mở [bước S00 trong lộ trình code](11-CODING-WORKFLOW-AND-CHECKLIST.md), tạo nơi ghi bằng chứng và chốt môi trường trước khi triển khai các module AI lớn.
