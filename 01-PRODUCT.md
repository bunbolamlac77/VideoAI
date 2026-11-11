# 01 — Sản phẩm, phạm vi hỗ trợ và luồng cộng tác

> **Trạng thái triển khai (2026-11-11):** đặc tả dưới đây đã được hiện thực hoá và kiểm thử;
> xem [`README.md`](../README.md) để biết trạng thái hiện tại và
> [`AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md) cho các
> lỗi đã đóng. Chỗ nào đặc tả khác mã đang chạy, mã + audit là nguồn đúng.

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả để triển khai; chưa phải ứng dụng đã xây dựng, chưa có kết quả benchmark hoặc nghiệm thu. Các phạm vi E0/E1 và ngưỡng chất lượng là mục tiêu kiểm chứng, không phải năng lực đã đạt.

Liên quan: [dữ liệu và bằng chứng](02-ANALYSIS-AND-DATA.md), [model và tài nguyên](03-MODELS-AND-RESOURCES.md), [kịch bản và dựng](04-SCRIPT-AND-EDIT.md), [kiến trúc và phục hồi](05-ARCHITECTURE-AND-ROADMAP.md), [nghiệm thu](09-UPGRADES-AND-ACCEPTANCE.md), [UI macOS](10-UI-UX-MACOS.md), [quy trình lập trình](11-CODING-WORKFLOW-AND-CHECKLIST.md).

## 1. Mục tiêu sản phẩm

AIVideo giúp người dùng biến video POV, ảnh và dữ kiện ngày làm việc thành một câu chuyện tiếng Việt có hình, lời và nhịp dựng phù hợp. Người dùng cung cấp điều camera không biết, xử lý các câu hỏi có ảnh hưởng và duyệt bản thực tế. AI phân tích tư liệu, đề xuất cách kể, ghép shot, tạo âm thanh/phụ đề, dựng và kiểm tra trong phạm vi được phép.

Chất lượng phân tích, tính đúng của câu chuyện và chất lượng dựng quan trọng hơn tốc độ. Chấp nhận chạy lâu không loại bỏ yêu cầu bảo vệ dữ liệu, phục hồi gián đoạn, quản lý dung lượng và phản hồi UI. Không cam kết mọi bộ tư liệu đều tạo được video hay, đúng gu hoặc gây cười.

Đầu ra mặc định hướng đến video dọc dài 45–90 giây; ít tư liệu có thể làm 15–30 giây. Giới hạn cứng là dưới 180 giây. Voice tiếng Việt chạy ở tốc độ 1×. Preview 1080×1920; preset final 2160×3840, chính xác 24/1 fps theo profile media đã nghiệm thu. Chữ “4K” mô tả kích thước xuất, không chứng nhận độ chi tiết gốc sau crop.

Ứng dụng giữ kiến trúc native macOS SwiftUI, core Swift, worker Python và DaVinci Resolve. Không đổi sang Rust/Tauri trong đặc tả này. Suy luận và xử lý media chạy local sau pha cài đặt riêng. Máy M1 Pro 16 GB là cấu hình mục tiêu kế thừa, cần đọc lại môi trường và đo trước khi công bố hỗ trợ.

## 2. Phạm vi kiểm chứng E0 và E1

E0/E1 là hai bộ điều kiện sẽ dùng để kiểm chứng. Trước khi vượt cổng tương ứng, giao diện và tài liệu bàn giao phải ghi **“chưa được nghiệm thu”**. Không suy ra app hỗ trợ chỉ vì file được import hoặc model nạp thành công.

| Thuộc tính | E0 — pilot | E1 — ứng viên phát hành |
|---|---|---|
| Ngày/buổi làm việc | 1 workday | 1–3 workday |
| Tổng thời lượng video | Tối đa 30 phút | Tối đa 120 phút |
| Tổng asset video + ảnh | Tối đa 30 | Tối đa 100 |
| Thời lượng một clip | Không vượt tổng 30 phút của E0 | Tối đa 30 phút |
| Phiên camera | Phạm vi một workday đã khai báo | Tối đa 2 phiên camera đã khai báo |
| Nguồn hình | Tới 4K60 trong ma trận codec/format đã kiểm | Tới 4K60 trong ma trận codec/format đã kiểm |
| Nơi đặt dự án đang hoạt động | APFS local được app kiểm tra | APFS local được app kiểm tra |
| Thời gian xử lý | Đo và báo cáo; chưa hứa tốc độ | Đo cả lượt dài nhất trong phạm vi hỗ trợ |

“Phiên camera” là một chuỗi nguồn từ một thiết bị/phiên ghi có quan hệ đồng hồ được khai báo; hai phiên không mặc nhiên đồng bộ thời gian. Ảnh, tên file và EXIF không tự chứng minh chronology.

Nguồn gốc có thể nằm trên ổ ngoài. Cơ sở dữ liệu dự án đang hoạt động không được đặt trên network share hoặc thư mục đang đồng bộ cloud. App dùng bản chụp nội dung đã niêm phong của source cho phân tích và render; cơ chế lưu trữ nằm ở mục 9 và tài liệu 05.

File nằm ngoài ma trận format đã kiểm phải có trạng thái không được hỗ trợ và hành động xử lý cụ thể. HDR chỉ được nhận khi metadata và đường chuyển sang SDR Rec.709 đã qua fixture; không âm thầm giải mã sai màu. Tên codec được hỗ trợ phải lấy từ capability manifest, không từ danh sách mong muốn.

Nếu bộ tư liệu vượt profile đã phát hành, preflight thông báo trước tác vụ tốn tài nguyên: chia project, giảm phạm vi hoặc dùng một profile thử nghiệm có nhãn rõ. Không giả đó là lỗi hiểu nội dung của AI. Mở rộng giới hạn cần quyết định thiết kế có phiên bản và bộ kiểm tra mở rộng. Fixture UI 1.000 asset không nâng E1 thành hỗ trợ phân tích 1.000 asset.

## 3. Năng lực được mở theo cổng

Core lưu capability manifest có phiên bản; UI chỉ bật hành động khi năng lực thực tế và điều kiện dự án đều đạt. “Có model trong thư mục” và “có module trong mã nguồn” không phải bằng chứng đã đạt.

| Năng lực | Điều kiện bật | Hành vi khi chưa đạt |
|---|---|---|
| Phân tích local có bằng chứng | G0–G2 và profile phân tích đã khóa | Báo phần chưa sẵn sàng; không giả kết quả AI |
| Tạo kịch bản đã kiểm khả thi | G3 với lời, nguồn, TTS thử và shot/time thật | Giữ bản nháp có nhãn đang kiểm; không gọi đã dựng được |
| Dựng managed preview/final | Resolve capability probe, G4/G5 tương ứng | Giữ script/artifact đã có; nêu lỗi tích hợp |
| Ghép ảnh như đúng cú bấm máy | Cổng `AI-07` riêng và bằng chứng của từng lần dùng | Chỉ dùng ảnh minh họa phù hợp hoặc không dùng |
| Âm thanh hiện trường có nhãn sự kiện | Detector đã benchmark cho vai trò tương ứng | Không gán tên âm thanh chắc chắn từ transcript/hình |
| HDR → SDR | Pipeline chuyển màu đã đạt `MEDIA-03` | Báo cần xử lý định dạng; không đổi màu ngầm |
| Học gu | Profile local có nguồn, revision và khả năng reset | Dùng preference người dùng nhập rõ và preset đã chọn |
| Sửa sâu trong Resolve | Tạo bản bàn giao thủ công riêng | Không nhập ngược chỉnh sửa thủ công vào pipeline tự động |

Sáu nâng cấp vẫn là thiết kế mục tiêu: ghép ảnh, event graph, tìm bỏ sót, học gu, review thành phẩm và nhịp hài. Bản phát hành phải công bố năng lực nào đã vượt cổng. Năng lực chưa đạt vẫn để trạng thái mở; chế độ minh họa không được báo là đã hoàn thành ghép ảnh chính xác.

MVP dùng một tập preset đã kiểm nhỏ: giọng, style chữ, profile màu và xuất. Không cần xây NLE nhiều track trong app. Không bỏ provenance, khóa của người dùng, checkpoint hoặc cổng duyệt để thu nhỏ phạm vi.

## 4. Luồng chuẩn từ tư liệu đến thành phẩm

| Bước | Người dùng và ứng dụng | Điều kiện chuyển bước |
|---|---|---|
| 1. Tạo dự án | Chọn nguồn và nơi lưu; xem profile E0/E1, ma trận format và dự trù SSD | Dự án local hợp lệ; bản chụp source đã kiểm bytes/hash hoặc có lỗi rõ |
| 2. Dữ kiện ngày làm việc | Viết tự do, thêm gợi ý nếu muốn | Giữ raw brief revision; lưu ghi chú không xác nhận fact |
| 3. Phân tích | Quét hình của mọi source hợp lệ, audio nếu có, ảnh và metadata | Theo dõi frame thực sau processor; vùng thiếu/lỗi không biến thành đã hiểu |
| 4. Làm rõ có bằng chứng | Trả lời, sửa, bổ sung tư liệu, chọn chưa rõ hoặc bỏ chi tiết | Chỉ chặn các phần phụ thuộc; các job độc lập tiếp tục |
| 5. Xác nhận dữ kiện | Kiểm nội dung và phạm vi các fact sẽ dùng, xử lý mâu thuẫn trọng yếu | Fact đúng revision và cách dùng đủ điều kiện theo tài liệu 02 |
| 6. Phương án kịch bản | Xem 1–3 phương án có shot, nguồn và thời lượng từ TTS thử | Đủ tư liệu để dựng; không bịa để đủ ba phương án |
| 7. Chọn, chỉnh, duyệt | Chọn bản, sửa lời/shot, duyệt revision đang xem | Approval gắn đúng snapshot; không còn chặn liên quan hoặc impact review chưa xong |
| 8. Dựng và QC preview | App dựng managed timeline, render preview, tự kiểm có giới hạn | Preview đúng script/edit plan và media đã khóa; không tự đổi nghĩa |
| 9. Duyệt preview | Xem/nghe, yêu cầu sửa hoặc duyệt revision cụ thể | Approval preview đúng snapshot, source scope và kết quả QC |
| 10. Xuất cuối | Render từ dữ liệu đã duyệt; QC chính file final | Final đúng profile, nội dung và approvals; lưu MP4, báo cáo và project/backup |

Chọn kịch bản, duyệt script và duyệt preview là ba hành động khác nhau. Duyệt nội dung không xác nhận ngầm các fact chưa được xác nhận. UI phải phản hồi lệnh sớm nhưng chỉ báo “Đã lưu” sau commit ACK; không coi nút đã bấm là giao dịch thành công.

Khi đang chạy, người dùng vẫn có thể sửa ghi chú và làm các việc độc lập. Kết quả AI từ revision cũ không ghi đè văn bản mới. Hủy một job thu hồi quyền công bố kết quả của attempt đó; kết quả về muộn không được xuất hiện như kết quả hiện hành.

## 5. Dữ kiện ngày làm việc: viết tự do trước

Mỗi workday có brief riêng và source được liên kết rõ; không tự gom một chuyến chỉ vì tên file hoặc ngày metadata giống nhau. Một buổi có thể vượt qua nửa đêm. Không bắt điền mọi trường mới được phân tích.

| Nhóm | Điều nên lưu | Khi thiếu/chưa chắc |
|---|---|---|
| Ngày và mốc giờ | Ngày, múi giờ, độ chính xác của từng mốc | Giữ “khoảng”, khoảng thời gian, chỉ biết ngày hoặc chưa rõ |
| Mục tiêu và tuyến | Việc định làm, tuyến dự định, điều thực tế nhớ được | Kế hoạch không phải bằng chứng việc đã xảy ra |
| Nhân vật | Tên gọi và vai trò do người dùng cung cấp | Không nhận diện danh tính bằng khuôn mặt |
| Diễn biến | Sự kiện và quan hệ trước/sau | Không lấy thứ tự file làm chronology |
| Ngoài khung hình | Điều không quay được, lý do người dùng biết | Giữ nguồn lời kể; không giả có shot chứng minh |
| Chắc/chưa chắc | Sự thật cần giữ, ký ức mơ hồ, nguồn mâu thuẫn | Không đổi “có lẽ” thành khẳng định |
| Ảnh/khoảnh khắc | Ảnh muốn dùng và quan hệ người dùng biết | Ảnh minh họa không tự thành ảnh đúng cú bấm |
| Giới hạn | Cảnh/người/tên không dùng, điều không suy đoán | Là ràng buộc dựng, không phải fact sự kiện |
| Phong cách | Tone, mức hài, voice, nhạc có quyền, độ dài | Profile có revision và project override |

Ví dụ minh họa, không phải dữ kiện thật của dự án:

> “Tôi rời nhà khoảng 3 giờ sáng để đi chụp rước dâu. Có quay lại một đoạn nhưng chưa nhớ rõ lý do. Đừng kể đó là do GPS nếu chưa có bằng chứng.”

AI đề xuất fact drafts gắn đoạn văn và brief revision. Người dùng sửa hoặc xác nhận một nhóm đã chọn khi UI hiển thị đủ giá trị, mức chắc chắn và phạm vi. Không đưa fact mới từ worker vào tập đang được xác nhận. Một câu trả lời không xóa nguồn cũ hoặc tự giải quyết mọi mâu thuẫn.

## 6. Ghi chú theo đoạn và ràng buộc biên tập

Người dùng chọn asset, event hoặc khoảng source để ghi “đây là lúc quay về”, “âm thanh này không thuộc sự kiện”, “đoạn này không dùng”. Lưu đối tượng/revision nguồn, tác giả, thời điểm ghi và phạm vi; khoảng source áp dụng cho media có thời gian. Ảnh hoặc event không có media tương ứng không bị ép tạo timecode. Ghi chú cấp đoạn không áp ngầm cho cả workday.

Hiển thị riêng thời gian trong source, thời gian trên bản dựng và giờ sự kiện. Khi xem một đoạn, cho mở rộng trước/sau để kiểm ngữ cảnh. Thông tin source đang hiển thị phải khớp frame/audio hiện tại, kể cả khi seek nhanh hoặc worker trả kết quả trễ.

Phân biệt các hành động:

- Bổ sung hoặc sửa fact về sự kiện.
- Sửa cách diễn đạt mà không cố ý thay nghĩa.
- Sửa quan hệ giữa các sự kiện.
- Đặt ràng buộc dựng hoặc sở thích.

`must_use` và `must_not_use` là khóa cứng có revision; `preferred` là ưu tiên xếp hạng. Khóa không làm tăng độ chắc của fact. AI không tự bỏ khóa để dựng dễ hơn. Nếu beam search chưa tìm ra phương án, UI phải nói đúng trạng thái tìm kiếm; không gọi đó là “không thể dựng” hoặc yêu cầu mở khóa như thể xung đột đã được chứng minh.

## 7. Review có mục tiêu, không trả công việc phân tích cho người dùng

Mỗi review có câu hỏi trung tính, lý do hỏi, claim/event liên quan, bằng chứng, revision và phương án bị ảnh hưởng. Đưa clip/frame/ảnh/audio hoặc đoạn brief đến ngay chỗ ra quyết định, không giao một danh sách source dài để người dùng tự tìm. Source range chỉ bắt buộc cho media có thời gian; ảnh hoặc đoạn brief là nguồn hợp lệ theo đúng revision, không cần timecode giả.

Ưu tiên sự thật cốt lõi, chronology, nhân quả, nhân vật và punchline. Gộp câu hỏi trùng; không hỏi lại một vấn đề trên cùng bằng chứng khi đã nhận “Tôi chưa rõ”. Các lựa chọn hợp lệ gồm trả lời, sửa, thêm tư liệu, chưa rõ hoặc không kể chi tiết đó.

Thiếu hình không chứng minh người dùng sai. Khi nguồn mâu thuẫn, trình bày cả hai và context. Chi tiết chưa giải quyết phải được bỏ, diễn đạt đúng giới hạn hoặc chặn phần thực sự phụ thuộc. Không biến một câu đùa thành đường vòng để đưa tiền đề sai vào video.

Không đặt trần số câu hỏi bằng phỏng đoán về sức kiên nhẫn. Đo thời gian thao tác chủ động, câu hỏi trùng, độ hữu ích và mức hiểu đúng nhãn nguồn trong nghiệm thu UX. Tối ưu những số này trong khi vẫn giữ tính đúng.

## 8. Nguồn, cách kể và phê duyệt là các chiều riêng

| Cách kể | Ý nghĩa cho người dùng | Điều kiện |
|---|---|---|
| `observed` | Tư liệu hỗ trợ trực tiếp đúng khẳng định | Evidence đúng khoảng và đầy đủ mệnh đề/quan hệ cần nói |
| `reported_by_user` | Người dùng kể điều mình biết | Fact revision được xác nhận, giữ độ chắc và nguồn người dùng |
| `inferred` | Một suy luận được phép diễn đạt có giới hạn | Không khẳng định chắc một điều chưa được hỗ trợ |
| `nonliteral_commentary` | Lời bình hoặc hài không mang nghĩa đen | Không chứa tiền đề sai về sự kiện/người thật |

Đây là cách sử dụng claim trong câu/beat. Schema `origin`, `epistemic_status`, `review_status`, `support_status` và `allowed_use` thuộc tài liệu 02; không gộp thành một tick xanh. Liên kết nguồn không tự chứng minh toàn bộ câu. Những quan hệ “vì”, “nên”, “sau đó”, “lại” cũng phải được kiểm.

Approval lưu snapshot bất biến của phần đã xem. Sửa fact, lời, shot, voice, crop, chữ hoặc mix tạo revision và xét lại đúng phụ thuộc. Undo không tự phục hồi một approval bằng cờ boolean. Lịch sử bản đã duyệt vẫn tồn tại.

Thêm tư liệu còn có thể thay đổi **phạm vi bằng chứng** dù một artifact cũ chưa từng liên kết với file mới. App lưu corpus/evidence scope revision và query manifest. Phần đánh giá/xếp hạng phụ thuộc phạm vi chuyển sang chờ đối chiếu; chặn final có liên quan trong lúc chưa xác định tác động. Sau revalidation, chỉ artifact thực sự bị ảnh hưởng cần cập nhật/duyệt lại. Không quét lại mọi frame cũ và không vô hiệu mọi approval vô điều kiện.

Audio, graphics và edit plan đã duyệt được giữ theo hash. Cùng model, seed hoặc cấu hình không bảo đảm TTS sinh lại giống hệt. Rerender dùng lại đúng bytes đã duyệt; tái sinh thay nội dung hoặc timing phải quay lại cổng thích hợp.

## 9. Bảo vệ nguồn và giải thích dung lượng

File người dùng chọn luôn là nguồn gốc chỉ đọc. App tạo **bản chụp tư liệu của dự án**: ưu tiên APFS clone đã kiểm trên cùng volume được hỗ trợ; nếu không, sao chép đầy đủ qua file tạm, kiểm tính nhất quán/hash rồi niêm phong. Không dùng hardlink làm bằng chứng bất biến. Mọi phân tích và render có thẩm quyền đọc snapshot đã niêm phong.

Preflight cho biết tổng source, cách tạo snapshot, dự trù copy/clone và khả năng tăng dung lượng khi copy-on-write, proxy, evidence, audio, render tạm, final và backup. Không hứa clone tốn 0 bytes lâu dài. Không đủ chỗ thì tạm dừng, cho đổi nơi dự án hợp lệ hoặc thay phạm vi; không âm thầm quay về đọc trực tiếp nguồn đang thay đổi.

Nếu nguồn thay đổi trong lúc nhận tư liệu, không ghép một phần bytes cũ với metadata mới: acquisition bị từ chối và cho thử lại. Sau khi đã có snapshot hợp lệ, nguồn gốc bị dời không tự làm hỏng bản dựng hiện hành. Nếu người dùng muốn nhận nội dung mới, đó là source revision mới và cần impact review.

“Liên kết lại” không nối tới file khác chỉ vì trùng tên. Snapshot mất/hỏng thì chặn phần phụ thuộc và hướng dẫn khôi phục hoặc nhận lại nguồn rồi kiểm hash. Snapshot chỉ đọc trong vùng app quản lý bảo vệ hành vi thông thường; không tuyên bố chống được chỉnh sửa có chủ ý bằng quyền hệ điều hành. Core kiểm hash tại các cổng sử dụng/công bố quan trọng.

Cache tái tạo được có thể dọn theo quota. Source snapshots, evidence đã giữ, WAV/graphics đã duyệt, revisions, notes và approvals có pin/tham chiếu không được xóa như cache. Người dùng luôn biết hành động dọn nào có thể cần tái tạo và hành động nào làm mất khả năng phục hồi.

## 10. Dựng tự động và bàn giao Resolve thủ công

App quản lý một project/timeline được định danh theo edit-plan revision. Đây là nhánh **Dựng tự động**, dùng cho QC, preview approval và final của pipeline. Các thao tác Resolve được ghi intent và đối chiếu kết quả; retry không append/render mù.

Hành động **Tạo bản để sửa trong Resolve** tạo bản bàn giao riêng có tên và revision nguồn rõ ràng. Người dùng chỉnh sâu ở đó. MVP không tự đồng bộ chỉnh sửa thủ công trở lại script, evidence graph hoặc managed timeline. Bản render thủ công không tự nhận nhãn “Final đã QC của AIVideo”.

Nếu managed timeline bị chỉnh ngoài app, chặn export tự động và giữ nguyên chỉnh sửa. Đưa hai lựa chọn có nội dung rõ: giữ nó thành nhánh thủ công; hoặc tạo một managed revision mới từ input đã niêm phong để xem/QC/duyệt theo phạm vi cần thiết. Không ghi đè nhánh thủ công. Nếu API không đọc lại được một hiệu ứng để chứng minh trạng thái, app phải báo hạn chế và dùng quy trình rebuild cô lập đã qua cổng năng lực.

Project bàn giao giữ clip/audio/cut trên track riêng. Chữ native/Fusion chỉ được gọi là sửa trực tiếp khi backend thực sự hỗ trợ; overlay raster phải kèm text/style nguồn và nhãn “cần tái sinh để sửa nội dung chữ”.

## 11. Lưu, backup và phục hồi

Ghi chú, fact, review và quyết định được lưu có ACK. “Đang lưu”, “Đã lưu” và “Lưu lỗi” là ba trạng thái khác nhau. Nếu lỗi ổ đầy/quyền truy cập, giữ buffer và cung cấp cách lưu bản khôi phục; không để nút đóng app làm mất thay đổi chưa được xử lý.

| Loại bản sao | Có gì | Điều cần hiểu |
|---|---|---|
| `checkpoint_backup` | Snapshot DB nhất quán, manifest, revision/hash và các artifact bắt buộc theo manifest | Có thể cần source/model còn tại vị trí hoặc kho đã khai báo; không gọi là bản đầy đủ mang sang máy khác |
| `portable_backup` | DB, manifest, sealed media được tham chiếu, artifact cần thiết và export Resolve | Runtime/model manifest luôn có; weights chỉ gồm khi người dùng chọn bundle rõ ràng |

Mục tiêu chính sách là backup user state ở các cổng duyệt quan trọng, khoảng 15 phút hoạt động biên tập và trước migration. Đây chưa phải hành vi đã triển khai. Core đảm bảo snapshot DB và tập artifact có thể đối chiếu nhất quán; app không sao chép tùy tiện một file SQLite đang dùng rồi gọi đó là backup.

Khôi phục vào thư mục mới, kiểm DB, schema, foreign keys, manifest/hash và prerequisites trước khi cho tiếp tục. Không ghi đè dự án đang làm. Bản app cũ gặp schema mới không được tự sửa xuống; mở chỉ đọc nếu thật sự hỗ trợ an toàn hoặc giải thích và chặn.

Pause/resume, sleep/wake và worker crash có trạng thái thật. “Đang tạm dừng” chưa nghĩa là tiến trình đã dừng. Job cũ còn sống không cho phép nạp thêm một model nặng vào ngân sách chỉ vì mất heartbeat. Mặc định tôn trọng sleep; không hứa tiếp tục phân tích khi gập máy.

## 12. Điều kiện hoàn thành sản phẩm

Một project chỉ ở trạng thái hoàn tất khi final đúng revision đã qua QC, approvals cần thiết còn hiệu lực, phạm vi bằng chứng không còn revalidation liên quan chưa giải quyết và artifact/backup bắt buộc kiểm được. Chỉ render xong hoặc có file MP4 chưa đủ.

Bộ nghiệm thu có thẩm quyền ở tài liệu 09. Các yêu cầu sản phẩm tối thiểu cần truy vết tới:

- `INV-*`: nguồn, sự thật, quyền duyệt và trạng thái hoàn tất.
- `DATA-01`, `DATA-04`, `DATA-05`: snapshot nguồn, revision và phạm vi bằng chứng.
- `RES-03`: không ghi đè sửa thủ công trong Resolve.
- `AI-03`, `AI-04`, `STORY-01`–`STORY-04`: support, sự kiện, script dựng được và trạng thái tìm kiếm trung thực.
- `UI-01`–`UI-28`: thao tác, nhập tiếng Việt, accessibility, lưu/phục hồi và hiểu đúng phạm vi.
- `OFF-*`, `REL-*`: offline, phạm vi được kiểm và bằng chứng phát hành.

Không đánh dấu đạt bằng việc viết xong tài liệu. Bản bàn giao phải có build, môi trường, fixture, trường hợp đã chạy, kết quả thực và hạn chế còn lại. Trình tự công việc và các bước coding agent nằm ở tài liệu 11.

## 13. Ngoài phạm vi bản đầu

Tự đăng TikTok, đồng bộ cloud, gọi API AI đám mây trong project, tự lấy trend, tự tải nhạc không rõ quyền, nhận diện danh tính từ khuôn mặt, tạo hình/sự kiện giả, bảo đảm viral, cover/caption mạng xã hội và tự fine-tune model không thuộc MVP.

Không có roundtrip tự động cho sửa thủ công trong Resolve; không hỗ trợ mọi MacBook, mọi codec hoặc mọi lượng tư liệu bằng một tuyên bố chung. Mỗi phạm vi mới chỉ được mở khi có quyết định thiết kế, capability manifest và nghiệm thu phù hợp.
