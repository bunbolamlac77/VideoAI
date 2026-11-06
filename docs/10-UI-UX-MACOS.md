# 10 — UI/UX macOS: bàn biên tập AIVideo

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả để triển khai; chưa phải giao diện đã được lập trình hoặc kiểm thử trên MacBook. Các target và fixture là điều kiện cần kiểm, không phải kết quả đã đạt.  
**Nền tảng mục tiêu:** ứng dụng macOS native bằng SwiftUI, core Swift và AppKit/AVKit khi cần; Python subprocess workers và DaVinci Resolve theo kiến trúc v3.1. M1 Pro 16 GB là cấu hình mục tiêu kế thừa, chưa phải máy đã được đo trong bản này; cần ghi nhận OS/toolchain/runtime trước khi chốt deployment target.

## 1. Vai trò của tài liệu

Tài liệu này bổ sung giao diện cho luồng cộng tác đã thống nhất: người dùng nhập dữ kiện ngày làm việc, bổ sung bối cảnh theo đoạn video, xử lý điểm chưa rõ, sửa và duyệt kịch bản, xem và duyệt preview. AI thực hiện phân tích và dựng theo những dữ liệu, ràng buộc và phiên bản được phép.

Đặt file này cạnh các tài liệu `01`–`09` và [11 — Quy trình lập trình](11-CODING-WORKFLOW-AND-CHECKLIST.md). Đọc cùng [sản phẩm](01-PRODUCT.md), [dữ liệu](02-ANALYSIS-AND-DATA.md), [kịch bản và dựng](04-SCRIPT-AND-EDIT.md), [kiến trúc](05-ARCHITECTURE-AND-ROADMAP.md), [tối ưu](07-OPTIMIZATION.md), [độ chính xác](08-ACCURACY-FIRST.md) và [nghiệm thu](09-UPGRADES-AND-ACCEPTANCE.md). Nếu dự án đặt các tài liệu này trong `docs/`, đặt toàn bộ bộ tài liệu cùng thư mục đó.

Các hợp đồng về provenance, revision, sealed source snapshots, evidence scope, giới hạn RAM và các cổng duyệt trong v3.1 có hiệu lực ở mọi màn hình. Giao diện không được tự đổi lời người dùng thành bằng chứng thị giác, tự xác nhận dữ kiện hoặc tự kế thừa approval sang nội dung đã thay đổi. Core Swift/ProjectStore giữ dữ liệu có thẩm quyền; worker không ghi SQLite canonical hoặc tự cấp approval. Khi gặp mâu thuẫn đặc tả, ghi thành quyết định thiết kế và sửa đúng tài liệu sở hữu; không sửa backend chỉ để làm nút trên giao diện hoạt động.

**Cách hiểu mức yêu cầu:** “Bắt buộc/P0” là điều kiện phát hành; “Nên/P1” là phần hoàn thiện sau khi luồng lõi đạt; “P2” là mở rộng. Các kích thước/màu là đề xuất thiết kế cần kiểm trên máy thật. Tài liệu 09 sở hữu metric, target v0.1 và ID nghiệm thu; mục 20 ở đây diễn giải chúng theo tác vụ UI. Không có ô nào được coi là đã đạt vì một màn hình mock đã hiện được.

## 2. Định hướng thiết kế

### 2.1. Một bàn biên tập bình tĩnh, tập trung vào câu chuyện

Chọn giao diện có sidebar gọn, vùng làm việc lớn và vùng thông tin chi tiết mở theo nhu cầu. Video, lời kể và bằng chứng là nội dung nổi bật nhất. Dùng cửa sổ, toolbar, menu, hộp chọn file và hành vi bàn phím quen thuộc của macOS. Đây là lựa chọn thiết kế cho AIVideo, phù hợp với nguyên tắc nền tảng trong [Apple HIG — Designing for macOS][S1].

Không đặt biểu đồ trang trí, điểm “AI thông minh”, nhiều thẻ thống kê hoặc một chatbox toàn màn hình vào trung tâm sản phẩm. Mỗi màn hình trả lời được ba câu hỏi: **tôi đang xem gì, còn điều gì cần quyết định, hành động tiếp theo là gì**.

Màn hình chính có một hành động ưu tiên theo ngữ cảnh. Các hành động sửa, xem nguồn, so sánh và hoàn tác luôn tìm được nhưng không cạnh tranh thị giác với nhau. Tình trạng tác vụ nền hiện gọn ở đáy sidebar và mở rộng khi người dùng muốn xem.

### 2.2. Ngôn ngữ hình ảnh

| Thành phần | Đặc tả đề xuất | Quy tắc sử dụng |
|---|---|---|
| Appearance | Theo hệ thống là mặc định; có Sáng và Tối | Lưu lựa chọn của người dùng; không buộc nền tối |
| Bề mặt | Nền trung tính từ màu semantic của macOS | Nội dung đọc dài nằm trên bề mặt ổn định, ít nhiễu |
| Màu nhấn | Xanh ngọc đậm ở chế độ sáng; xanh ngọc nhạt ở chế độ tối | Chủ yếu cho lựa chọn và hành động chính; không đồng nghĩa mọi trạng thái đều “đúng” |
| Chữ | Font hệ thống; nội dung 14 pt, nhãn phụ 12 pt, tiêu đề màn 22 pt semibold, tiêu đề nhóm 15 pt | Quan trọng không được nhét vào chữ nhỏ; hỗ trợ tăng cỡ chữ |
| Số và thời gian | Monospaced digits cho timecode, số lượng và duration | Không dùng font monospace cho toàn bộ lời kể |
| Khoảng cách | Thang 4, 8, 12, 16, 24, 32 pt | Cùng loại nội dung dùng cùng khoảng cách |
| Khung nội dung | Bo góc khoảng 8–12 pt cho panel tự thiết kế | Control hệ thống giữ kích thước và hình dạng do hệ thống quản lý |
| Biểu tượng | SF Symbols có nhãn hoặc tooltip khi thích hợp | Có fallback cho symbol không có trên OS tối thiểu |
| Trạng thái | Chữ + biểu tượng + màu semantic | Không dùng màu làm dấu hiệu duy nhất |
| Chuyển động | Ngắn, có mục đích; bỏ chuyển động lớn khi Reduce Motion bật | Không có nền động, shimmer hoặc hiệu ứng liên tục trong màn đọc |

Palette nhận diện gợi ý: nút xanh `#0F766E` với chữ trắng ở chế độ sáng; nền nhấn `#5EEAD4` với chữ `#062C28` ở chế độ tối. Đây là cặp màu cho bề mặt tùy chỉnh dạng đặc. Nếu dùng control native, để hệ thống giải quyết foreground và tương phản; không ép tất cả control mang hai màu này. Màu nền, separator, selection, text và error lấy semantic colors thay vì một bảng hex cố định cho mọi chế độ.

Liquid Glass, nếu OS/SDK hỗ trợ, chỉ xuất hiện hợp lý ở lớp điều hướng hoặc control native. Không phủ hiệu ứng kính lên trang kịch bản, bảng dữ kiện và vùng đọc bằng chứng. Apple hướng dẫn dùng vật liệu này cho lớp điều khiển và điều hướng, đồng thời kiểm tra appearance và accessibility; việc dùng API mới phải theo target thực tế. [S2]

Thiết kế subtitle trong video là cấu hình sản phẩm khác. Đổi font hoặc appearance của ứng dụng không được đổi font phụ đề, màu grade hay nội dung video đã duyệt.

## 3. Cấu trúc điều hướng

Sidebar có bộ chọn dự án ở trên, năm khu vực làm việc ở giữa và trạng thái tác vụ ở dưới:

| Khu vực | Mục đích chính | Thông tin cần nhìn thấy ngay |
|---|---|---|
| **Tư liệu** | Nhập, tạo bản chụp tư liệu, xem, phân nhóm và liên kết lại video/ảnh | Trạng thái nhận/kiểm nguồn, dung lượng, lỗi và phần chưa phân tích |
| **Ngày làm việc** | Viết ghi chú, kiểm tra dữ kiện trích xuất, đặt ràng buộc | Ghi chú đang lưu hay đã lưu; bao nhiêu dữ kiện cần xem |
| **Cần làm rõ** | Giải quyết từng câu hỏi gắn với bằng chứng | Câu hỏi nào ảnh hưởng kịch bản đang chọn |
| **Kịch bản** | So sánh, sửa lời, kiểm nguồn, chọn và duyệt phương án | Phiên bản hiện tại, thời lượng đo, trạng thái duyệt |
| **Dựng & xuất** | Xem preview, xử lý QC, duyệt, xuất và bàn giao Resolve | Bản nào đang xem/đã duyệt; final QC; nhánh tự động hay thủ công |

Badge ở “Cần làm rõ” đếm câu hỏi đang mở, không đếm mọi thông báo. Bộ lọc ngày/buổi luôn có tên rõ; đổi bộ lọc chỉ đổi nội dung đang xem, không âm thầm đổi phạm vi job đã chạy. Settings mở theo quy ước macOS bằng menu ứng dụng và `⌘,`.

Toolbar chứa tên dự án, ngữ cảnh ngày/buổi khi cần, tìm kiếm theo màn và hành động ưu tiên. Không đặt tất cả nút của năm khu vực lên cùng một toolbar. Inspector hiển thị chi tiết đối tượng đang chọn; mở từ nút có nhãn, có thể đóng và nhớ lựa chọn phù hợp với kích thước cửa sổ.

MVP có một cửa sổ chỉnh sửa cho mỗi project. Mở lại project đang mở sẽ đưa đúng cửa sổ lên trước, không tạo writer thứ hai cho cùng project. Các project khác có cửa sổ riêng trong cùng app process; resource governor và heavy lease dùng chung toàn app. Mỗi cửa sổ giữ đúng selection, menu context và revision của chính nó. Nếu project đã có một phiên ghi có thẩm quyền khác, báo trạng thái đang mở và cách chuyển tới phiên đó; không tự mở thêm quyền ghi.

## 4. Bố cục thích ứng với MacBook

### 4.1. Đo bằng diện tích nội dung cửa sổ

Mọi kích thước UI trong tài liệu là **logical points**, không phải pixel của video hoặc độ phân giải vật lý màn hình. Quyết định layout dựa trên vùng nội dung khả dụng sau khi trừ chrome và các vùng hệ thống. Không suy kích thước màn hình từ chip M1 Pro.

| Chiều rộng nội dung đề xuất | Bố cục | Hành vi bắt buộc |
|---|---|---|
| Từ 1440 pt | Sidebar 200–240 pt; nội dung linh hoạt; inspector 280–360 pt khi mở | Không để nội dung chính hẹp đến mức không đọc được |
| 1180–1439 pt | Sidebar khoảng 216 pt; nội dung chính lớn; inspector đóng mặc định | Mở chi tiết theo nhu cầu; có thể đưa chi tiết thành màn riêng nếu thiếu chỗ |
| 960–1179 pt | Chủ động thu gọn sidebar; ưu tiên một vùng làm việc | Review xếp dọc; chi tiết có nút quay lại rõ ràng; không ép ba cột |
| Hẹp hơn hoặc cỡ chữ tăng | Chế độ một vùng, cuộn dọc, điều hướng bằng toolbar/menu | Không mất nút lưu/duyệt hoặc yêu cầu kéo cửa sổ vượt màn hình |

Đây là breakpoint khởi đầu. Lập trình viên phải kiểm tra nội dung thực, nhãn tiếng Việt dài và app text size, rồi chỉnh các ngưỡng. Không dùng breakpoint như lý do để cắt chữ hay giấu hành động quan trọng.

Ưu tiên `NavigationSplitView` hai cột cho shell và inspector khi phù hợp. Điều chỉnh visibility bằng state theo chính sách cửa sổ đã định; không giả định mô tả tự collapse ở compact size class trên thiết bị khác sẽ tự giải quyết mọi cửa sổ macOS. Chiều rộng khai báo cho split view là ưu tiên bố cục, cần kiểm thử thực tế. [S3]

### 4.2. Quy tắc chống vỡ layout

- Cửa sổ đầu tiên và cửa sổ khôi phục được giới hạn trong vùng hiển thị khả dụng của màn hiện tại. Khi rút màn ngoài, cửa sổ phải trở về vùng có thể thao tác.
- Tại 1280×800 pt, luồng nhập brief → review → duyệt script → xem preview phải dùng được đầy đủ. Thêm ca thử 960×640 pt và 1440×900 pt; đây là kích thước nội dung thử, không phải yêu cầu mua màn hình.
- Không ép một minimum window size lớn hơn vùng làm việc thực tế. Nếu một công cụ phức tạp cần thêm chỗ, chuyển sang trình bày tuần tự hoặc màn chi tiết.
- Panel chứa văn bản cuộn riêng hợp lý; nút hành động cuối màn không che dòng cuối. Tránh nhiều vùng cuộn lồng nhau cùng hướng khi không cần thiết.
- Player dùng fit để quan sát đủ khung hình. Preview dọc không bị kéo méo để lấp đầy panel. Crop xuất video phải là hành động sửa riêng và tạo revision khi có ảnh hưởng.
- Chỉ timeline hoặc bảng so sánh thực sự cần mới cuộn ngang; trang ghi chú và trang kịch bản không có thanh cuộn ngang.
- Thay đổi sidebar/inspector, full screen hoặc appearance không làm mất văn bản đang gõ, caret, item đang chọn và vị trí review.

## 5. Màn hình Tư liệu

### 5.1. Lần đầu mở và nhập nguồn

Empty state có tiêu đề “Thêm tư liệu cho câu chuyện”, nút **Thêm video và ảnh**, vùng thả file và câu giải thích ngắn về nơi lưu dự án. Chọn nguồn bằng hộp thoại native; có thể thêm thư mục hoặc file. Nơi dự án đang hoạt động phải là APFS local được hỗ trợ; giải thích ngay khi chọn network share hoặc thư mục đang đồng bộ cloud. Không yêu cầu cấu hình mọi model trước khi người dùng biết mình đang tạo dự án gì, nhưng không khởi chạy phân tích khi setup chưa đủ.

Sau khi chọn nguồn, hiển thị manifest tăng dần cùng trạng thái chờ nhận/đang sao chụp/đang kiểm tra/sẵn sàng/lỗi. Chỉ source snapshot đã niêm phong và kiểm tính nhất quán mới sẵn sàng cho phân tích có thẩm quyền. Từng file có tên, loại, thumbnail, duration nếu có, ngày/buổi đã gán và trạng thái. Không biến EXIF, giờ hệ thống hoặc tên file thành thời điểm sự kiện chắc chắn. Cho sửa nhóm ngày làm việc; nhóm nguồn của một buổi có thể vượt qua nửa đêm.

### 5.2. Làm việc với tư liệu

- Có chế độ danh sách và thumbnail grid, bộ lọc lỗi/chưa phân tích/video/ảnh/ngày, tìm theo tên và ghi chú.
- Chọn một asset để xem player hoặc ảnh, thông tin source và các đoạn đã đánh dấu; thông số codec, model hay hash nằm trong phần chi tiết nâng cao.
- Cho thêm ghi chú vào cả asset hoặc khoảng source được chọn; UI phải nêu rõ phạm vi trước khi lưu.
- “Không dùng trong bản dựng” là ràng buộc nội dung; “Gỡ khỏi dự án” tạo thay đổi manifest/evidence scope. Hai hành động khác nhau. Gỡ không xóa bản gốc; snapshot còn pin/tham chiếu không bị dọn như cache. App không đưa thao tác xóa file gốc vào luồng biên tập thông thường.
- “Liên kết lại nguồn gốc” xử lý vị trí/quyền của original; snapshot còn khỏe vẫn dùng được cho project hiện hành. “Khôi phục bản chụp tư liệu” xử lý snapshot thiếu/hỏng. Kiểm danh tính/hash; không tự nối sang file khác chỉ vì trùng tên hoặc dùng approval cũ cho nội dung mới.
- Menu ngữ cảnh có “Hiện trong Finder”, “Thêm vào ngày làm việc”, “Thêm ghi chú” và các hành động đúng trạng thái.

Thumbnail không tự chạy như nhiều video nhỏ. Một player hoạt động tại một thời điểm là mặc định của MVP. Clip không âm thanh vẫn có preview hình và trạng thái phân tích riêng, không bị đánh dấu là tư liệu vô dụng.

### 5.3. Dung lượng và bản chụp tư liệu

Trước khi nhận tư liệu, hiển thị tổng bytes/thời lượng/asset đã đọc được, nơi lưu và dự trù snapshot, proxy, evidence, voice, render tạm/final và backup. “Bản chụp tư liệu” là bản nội dung cố định dùng cho phân tích/dựng; người dùng không cần hiểu các bước transaction bên trong để quyết định nơi lưu.

Nếu dùng APFS clone trên volume được hỗ trợ, giải thích ngắn rằng dung lượng dùng thêm có thể tăng khi nội dung thay đổi. Không hiện “0 GB cần thiết” như bảo đảm lâu dài; không bỏ dự trù copy-on-write. Nếu cần sao chép đầy đủ, báo đúng bytes và tiến trình đọc/ghi/kiểm tra; không gán 100% cho bước copy rồi gọi cả acquisition hoàn tất.

Thiếu SSD phải có lựa chọn đổi vị trí dự án hợp lệ, giảm phạm vi hoặc tạm dừng. Không tự thay bằng chế độ đọc trực tiếp original. Nguồn đổi giữa lúc copy/hash thì nêu “Tư liệu đã thay đổi trong lúc nhận. Chưa tạo được bản chụp nhất quán”, giữ các asset khác đã sẵn sàng và cho thử lại đúng file.

Original chỉ đọc và snapshot của dự án là hai danh tính rõ ràng. “Hiện trong Finder” cần menu phân biệt nguồn gốc với bản sao dự án khi cả hai đều có thể mở. Source content revision/hash có trong inspector kỹ thuật; màn chính dùng tên file và trạng thái dễ hiểu.

### 5.4. Profile hỗ trợ và source đến muộn

E0/E1 và ma trận format có badge **Chưa nghiệm thu**, **Đã kiểm trong phạm vi này** hoặc **Ngoài phạm vi đã kiểm**, lấy từ capability manifest. Các giới hạn chuẩn thuộc tài liệu 01; không tự khai thêm “hỗ trợ 1.000 clip” vì grid cuộn được 1.000 asset.

Khi vượt thời lượng/số asset/profile format đã phát hành, báo trước khi chạy lượt nặng; cho chia project hoặc chọn profile thử nghiệm có nhãn rõ nếu bản app thực sự cung cấp. Không giấu giới hạn dưới một thông báo “AI không hiểu video”. HDR thiếu metadata hoặc pipeline chưa đạt phải nêu trạng thái xử lý format, không preview sai màu như thể bình thường.

Thêm tư liệu sau script/preview không lập tức phá mọi bản duyệt. Hiển thị **“Có tư liệu mới · Đang đối chiếu tác động”** cho phạm vi liên quan; final chịu ảnh hưởng chưa được phép xuất cho tới khi revalidation xong. Khi không có tác động, giữ bản đã duyệt; khi có, đưa diff và chính xác các phần cần xem lại. Không quét lại mọi frame cũ chỉ để cập nhật badge.

## 6. Màn hình Ngày làm việc

### 6.1. Ghi chú tự do là điểm bắt đầu

Đây là một trang ghi chép dễ đọc: tên buổi/ngày, ô văn bản lớn và các gợi ý mở thêm khi cần. Placeholder gợi đúng nội dung: công việc hôm đó, người liên quan, điều xảy ra ngoài camera, điều nhớ chưa chắc và điều không muốn kể. Không bắt người dùng điền một biểu mẫu dài trước khi phân tích.

Các trường gợi ý gồm mục tiêu, mốc thời gian, nhân vật/cách gọi, diễn biến, ảnh muốn dùng, chi tiết chưa chắc và giới hạn nội dung. Mỗi trường tùy chọn có thể trở về ghi chú tự do. Ràng buộc như “đừng dùng cảnh này” được hiển thị riêng với dữ kiện về sự kiện.

Ví dụ minh họa, không phải dữ kiện của dự án: “Rời nhà khoảng 3 giờ sáng; có quay lại một đoạn nhưng tôi chưa nhớ rõ lý do.” AI có thể đề xuất hai dữ kiện nháp và một điểm cần làm rõ; không được tự tạo nguyên nhân hoặc biến “khoảng” thành giờ chính xác.

### 6.2. Ghi chú và dữ kiện là hai vùng riêng

Vùng ghi chú luôn thể hiện revision và trạng thái lưu. Vùng “Dữ kiện AI đề xuất” thể hiện nguồn đoạn ghi chú, phạm vi, mức chắc chắn và trạng thái review của từng mục. Có thể đặt dưới ghi chú hoặc trong panel cạnh bên khi đủ rộng.

Mỗi mục cần các thao tác **Sửa**, **Xác nhận**, **Không dùng**, **Xem nguồn**. Dữ kiện nháp có thể được xác nhận nhiều mục bằng checkbox, nhưng nút phải ghi đúng số lượng và chỉ bao phủ tập nội dung/revision người dùng đã có thể đọc đầy đủ. Không đưa những mục mới xuất hiện do job nền vào thao tác xác nhận đang thực hiện.

Microcopy chuẩn:

- “Ghi chú v3 · Đã lưu.”
- “Đề xuất từ ghi chú v2 · Cần cập nhật.”
- “Đã lưu ghi chú · Dữ kiện chưa được xác nhận.”
- “Xác nhận 4 dữ kiện đã chọn.”
- “Áp dụng cho: Buổi chụp 05/11.”

Người dùng có thể tiếp tục gõ trong lúc AI trích xuất. Kết quả từ bản ghi chú cũ phải nằm trong vùng đề xuất có nhãn đúng phiên bản; không ghi đè văn bản mới, không tự chuyển con trỏ và không tự xác nhận các mục sửa lại.

## 7. Màn hình Cần làm rõ — trọng tâm chất lượng

### 7.1. Tập trung một câu hỏi tại một thời điểm

Ở cửa sổ rộng, hiển thị player/bằng chứng và phần câu hỏi cạnh nhau. Ở cửa sổ hẹp, đặt player phía trên, câu hỏi và trả lời phía dưới. Danh sách câu hỏi dùng panel gọn hoặc chuyển màn; không ép một sidebar phụ, player, editor và inspector cùng tồn tại.

Một review item bắt buộc có:

1. Câu hỏi trung tính, không gợi một nguyên nhân chưa có chứng cứ.
2. Bằng chứng liên quan: clip/ảnh/audio hoặc đoạn ghi chú đúng phiên bản. Với media có thời gian, hiển thị tên nguồn, khoảng source và nút xem rộng hơn trước/sau; với ảnh, hiển thị ảnh và thông tin nguồn. Dữ kiện ngoài camera có thể chỉ có nguồn brief; không gán một clip minh họa thành bằng chứng còn thiếu.
3. Dữ kiện/quan hệ đang chưa rõ cùng nguồn lời kể nếu có.
4. Ảnh hưởng dễ hiểu: “Cần cho câu mở đầu của phương án A” hoặc “Không chặn phương án B”.
5. Ô trả lời hoặc lựa chọn phù hợp; hành động **Lưu câu trả lời**, **Tôi chưa rõ**, **Không kể chi tiết này**.

Ví dụ hỏi “Bạn quay đầu ở đoạn này vì lý do gì?” thay vì “Bạn quay lại vì quên máy ảnh đúng không?”. Khi có mâu thuẫn, trình bày hai nguồn và điều chưa khớp; không kết luận người dùng sai chỉ vì camera không quay được sự kiện.

### 7.2. Ưu tiên và giải quyết

Sắp câu hỏi theo tác động lên tính đúng, chronology, nguyên nhân, nhân vật và phương án đang chọn. Có bộ lọc “Ảnh hưởng bản đang chọn”, “Mọi câu hỏi” và “Đã xử lý”. Giữ câu hỏi đang đọc ổn định dù hệ thống nhận thêm mục mới.

Lưu câu trả lời chỉ lưu một review resolution/dữ kiện nháp theo hợp đồng v3.1. Nếu muốn đồng thời xác nhận dữ kiện được suy ra, UI phải hiển thị nội dung và phạm vi cụ thể rồi dùng hành động xác nhận rõ ràng. Một nút “Tiếp” không được thay cả hai việc.

“Tôi chưa rõ” là câu trả lời hợp lệ; phần phụ thuộc có thể giữ unknown, bỏ chi tiết hoặc diễn đạt phù hợp. Nếu chi tiết cốt lõi vẫn cần thiết thì chỉ kịch bản/job phụ thuộc bị chặn. Những clip và công việc độc lập vẫn tiếp tục. Không hiện chuỗi modal bắt trả lời mọi câu hỏi trước khi làm việc khác.

Cho mở lại một câu đã xử lý, xem câu trả lời cũ và sửa thành revision mới. Lịch sử giúp hiểu thay đổi; không hỏi lại cùng một vấn đề trên cùng dữ liệu nếu không có lý do mới.

Nếu revalidation phát hiện source mới có thể thay đổi câu trả lời cũ, câu hỏi phải nêu rõ **bằng chứng mới là gì** và **phạm vi nào được xem lại**. Không đơn giản mở lại mọi review đã đóng. Đang có nguồn đối chiếu không đồng nghĩa đã kết luận người dùng sai.

## 8. Màn hình Kịch bản

### 8.1. So sánh được rồi đọc sâu

Hiển thị 1–3 phương án thực sự khả thi. Thanh chọn A/B/C chỉ xuất hiện theo số bản có thật; không tạo chỗ trống để ép đủ ba. Mỗi phương án có tên góc kể, mô tả ngắn, thời lượng từ TTS thử, số beat và điểm cần lưu ý. Không hiện điểm “chắc chắn hay 95%”.

So sánh bằng bảng ngắn về góc kể, sự kiện chính, giọng kể và tư liệu cần dùng. Khi chọn một bản, mở một trang kịch bản dễ đọc; không trình bày ba kịch bản dài trong ba cột nhỏ.

### 8.2. Cấu trúc trang kịch bản

Mỗi beat có lời voice, khoảng thời gian dựng dự kiến đã kiểm bằng TTS, thumbnail/shot hoặc ảnh, cách dùng nguồn và ghi chú cần xử lý. Click câu mở được bằng chứng; click shot làm nổi câu đang dùng shot đó. Giữ lựa chọn bằng ID ổn định, không bằng vị trí hàng.

Cho sửa lời trực tiếp, thay shot từ tập phù hợp, thêm ghi chú, ghim/khóa câu, shot, ảnh hoặc điểm cắt. Phân biệt rõ “Bắt buộc dùng”, “Không dùng” và “Ưu tiên dùng”. Khi ràng buộc xung đột với bằng chứng hoặc thời lượng, app nêu phần xung đột và yêu cầu chỉnh đúng chỗ, không tự mở khóa.

Trạng thái search phải trung thực: **Đã tìm được phương án**, **Chưa tìm thấy trong lượt tìm hiện tại**, **Cần thêm phương án shot** hoặc **Không có nghiệm trong miền đã kiểm đầy đủ**. Trường hợp beam bị cắt hẹp không được hiện “Các khóa của bạn làm video không thể dựng”. Cho xem giới hạn tìm kiếm và lựa chọn chạy mở rộng hoặc xem bottleneck; chỉ gọi xung đột đã chứng minh khi checker có đủ bằng chứng trong miền được nêu.

AI đề xuất sửa nằm trong diff hoặc vùng đề xuất. Người dùng chọn áp dụng từng phần hoặc cả tập đã xem. Không thay nội dung đang gõ, không làm mất sửa tay và không báo vẫn được duyệt khi nội dung phụ thuộc đã đổi.

Đổi câu chữ có thể làm thay đổi thời lượng: UI hiển thị “Cần kiểm lại giọng đọc và nhịp dựng” cho tới khi các kiểm tra cần thiết hoàn tất. Không tái dùng duration cũ như số liệu của lời mới.

### 8.3. Chọn và duyệt tách biệt

“Đang chọn · Kịch bản v5” chỉ thể hiện lựa chọn. Nút **Duyệt kịch bản v5** là hành động riêng, hiển thị ngắn những phần sẽ được duyệt: lời, storyboard và snapshot phụ thuộc. Nếu còn vấn đề chặn, hiển thị lý do và đường dẫn đến đúng mục cần xử lý.

Nếu dữ liệu đổi trong lúc người dùng đọc hoặc click, backend từ chối duyệt snapshot khác với snapshot đang hiển thị. Thông báo: “Có thay đổi mới. Xem bản v6 trước khi duyệt.” Không tự lấy revision mới nhất rồi gắn approval của thao tác cũ.

## 9. Màn hình Dựng & xuất

### 9.1. Preview có thể kiểm chứng

Player dọc là trọng tâm; bên cạnh hoặc bên dưới là danh sách beat và lỗi QC có thể nhảy tới đoạn liên quan. Thanh beat đơn giản hỗ trợ định vị, đánh dấu đoạn cần sửa và đối chiếu lời/nguồn. Việc dựng sâu vẫn dùng Resolve; MVP không cần sao chép toàn bộ timeline nhiều track của một NLE.

Hiển thị tên bản, revision script liên quan, trạng thái QC, trạng thái duyệt và nhánh **Dựng tự động**. Có **Nghe lại đoạn này**, **Xem nguồn**, **Yêu cầu sửa đoạn này** và **Tạo bản để sửa trong Resolve** khi capability sẵn sàng. Vùng ghi nhận sửa có phạm vi theo beat hoặc khoảng timeline, không chỉ một chat không liên kết với thời gian.

Cho bật lớp hướng dẫn vùng an toàn của khung hình để xem thử. Bật/tắt lớp hướng dẫn chỉ đổi hiển thị trong app. Nếu sửa crop, caption, voice, nhạc, timing hoặc nội dung bản dựng, tạo revision và làm mất hiệu lực đúng approval phụ thuộc.

Preview 1080×1920 và final preset 2160×3840/24 fps là các artifact khác nhau. Nhãn “4K” chỉ mô tả kích thước đầu ra, không chứng nhận nguồn có chi tiết 4K thật. App phải QC chính file final, không dùng kết quả preview thay thế.

### 9.2. Các hành động cuối

1. Khi preview đủ điều kiện, người dùng xem/nghe và bấm **Duyệt preview v3**.
2. Nút **Xuất bản cuối** chỉ hoạt động khi approvals đúng snapshot, scope revalidation liên quan đã xong, managed timeline không drift và các cổng cần thiết còn hiệu lực.
3. Sau render, hiển thị “Đang kiểm tra file cuối”; chưa báo hoàn tất chỉ vì Resolve báo render xong.
4. Khi final đạt QC, hiển thị file video, báo cáo ngắn và project Resolve/backup có thể mở lại. Nút chính là **Hiện thành phẩm trong Finder**.

Nếu file cuối đã tồn tại từ một bản trước nhưng dữ kiện mới làm bản đó cần xem lại, vẫn cho truy cập lịch sử và ghi đúng trạng thái. Không xóa thành phẩm cũ hoặc âm thầm gọi nó là bản hiện tại đã được duyệt.

### 9.3. Phân biệt nhánh tự động và bản chỉnh thủ công

**Dựng tự động** là project/timeline do app quản lý theo edit-plan revision, dùng cho preview approval và final QC. **Bản chỉnh thủ công** là bản bàn giao riêng được tạo từ một revision rõ ràng. UI giải thích ngay tại hành động bàn giao: “Bạn có thể sửa bản này trong Resolve. Phiên bản hiện tại chưa nhập ngược các sửa đổi đó vào AIVideo.”

Không yêu cầu người dùng hiểu “roundtrip” để quyết định. Tên timeline/project bàn giao chứa nhãn thủ công và revision nguồn; không dùng hai bản cùng tên khó phân biệt. Sau khi bàn giao thành công và kiểm export, cho mở Resolve. Nếu chưa tạo được bản sao, không mở một managed timeline như thể đó là bản dành cho sửa tay.

Khi phát hiện nhánh tự động bị chỉnh ngoài app, giữ nguyên thay đổi và hiển thị **“Bản dựng trong Resolve đã khác bản được duyệt”**. Chặn export tự động; cho **Giữ thành bản chỉnh thủ công** hoặc **Tạo bản dựng tự động mới**. Nêu rõ bản mới tạo riêng và cần QC/duyệt theo phần bị ảnh hưởng; không có hành động một chạm ghi đè mọi sửa tay.

Trạng thái **“Đang đối chiếu Resolve”** hoặc **“Chưa xác nhận được kết quả thao tác”** khác với lỗi chắc chắn. Khi mất ACK hoặc API không đọc lại đủ hiệu ứng, không kích hoạt nút Retry mù. Chỉ cho retry/rebuild khi core cung cấp hành động hợp lệ từ journal/capability probe.

Các file do người dùng render từ nhánh thủ công có thể được ghi nhận là file ngoài pipeline, nhưng không tự mang badge **Final đã QC của AIVideo**. Chữ raster và giới hạn chỉnh sửa được giải thích ở phần bàn giao, đi cùng text/style nguồn cần để tái sinh.

## 10. Ngôn ngữ về nguồn, thời gian và độ chắc chắn

### 10.1. Nhãn phải giữ đúng nghĩa dữ liệu

| Điều người dùng cần hiểu | Nhãn UI gợi ý | Điều không được suy ra |
|---|---|---|
| Dữ kiện do người dùng kể | **Bạn cung cấp** | Camera đã chứng minh |
| Người dùng đã xác nhận một bản | **Bạn đã xác nhận · v2** | Tự xác nhận mọi bản sửa sau |
| Nội dung lấy từ hình ảnh | **Từ hình ảnh** | Mọi diễn giải hoặc nguyên nhân đều đúng |
| Nội dung đã đối chiếu đủ theo quy tắc | **Đã đối chiếu nguồn** | Chắc chắn tuyệt đối hoặc không cần provenance |
| Lời nghe trong audio | **Lời nói trong nguồn** | Sự kiện được nói tới đã xảy ra |
| Suy luận chưa trực tiếp | **AI suy luận · Cần làm rõ** | Được kể như một sự thật quan sát được |
| Chưa đủ dữ kiện | **Chưa rõ** | Người dùng đã đồng ý ngầm |
| Nguồn xung đột | **Cần đối chiếu** | App được tự bỏ một nguồn cho đẹp câu chuyện |
| Ảnh ghép ứng viên | **Ứng viên cần đối chiếu** | Đã tìm đúng ảnh của cú bấm máy |
| Ảnh dùng để gợi bối cảnh | **Dùng làm ảnh minh họa** | Ảnh là bằng chứng chính xác của sự kiện |

UI có thể hiện nguồn và trạng thái review thành hai nhãn cạnh nhau. Không gộp `origin`, `epistemic_status`, `review_status`, `support_status` và `allowed_use` thành một tick xanh duy nhất. Những trường kỹ thuật này nằm trong dữ liệu/inspector nâng cao; người dùng thấy ngôn ngữ tự nhiên ở bảng trên. Nguồn và cách dùng một mệnh đề trong câu chuyện vẫn là hai việc khác nhau.

Không hiển thị confidence của model dưới dạng xác suất đúng khi chưa có hiệu chuẩn phù hợp. Nếu cần dữ liệu chẩn đoán, đặt trong mục kỹ thuật và ghi rõ ý nghĩa; không dùng số đó để bỏ qua review.

### 10.2. Ba loại thời gian

Ví dụ minh họa phải được ghi nhãn khác nhau:

- **Nguồn · IMG_0123.MOV · 00:12.600–00:19.000**: khoảng trong file gốc.
- **Bản dựng v4 · 00:23.000**: vị trí trên timeline thành phẩm.
- **Giờ sự kiện: khoảng 03:00 · Bạn cung cấp**: thời gian thực do người dùng kể.

Đổi thứ tự kể không đổi chronology nguồn. Backend giữ PTS/mapping chính xác; giao diện không bắt người dùng hiểu PTS. Khi nhảy tới một đoạn, phải dùng mapping của đúng artifact và revision, không lấy timecode dựng để seek trực tiếp vào source.

## 11. So sánh thay đổi và giữ quyền chỉnh sửa

Có trang hoặc panel **Thay đổi gần đây** cho brief, dữ kiện, script và preview. Mỗi thay đổi cho biết người/AI tạo, nội dung trước–sau và artifact chịu ảnh hưởng. Hiển thị tác động theo dependency thực, không đánh dấu mọi thứ trong dự án là lỗi.

Phân biệt **Đang đối chiếu tác động của tư liệu mới** với **Bản này đã lỗi thời**. Trạng thái đầu là một đánh giá phạm vi chưa hoàn tất; trạng thái sau đòi có căn cứ dependency cụ thể. Source observations bất biến còn hợp lệ được giữ. Diff cho thấy source mới, claim/quan hệ bị xét lại và kết quả đánh giá; không hiện hàng nghìn frame cũ như hàng nghìn thay đổi nội dung.

Microcopy gợi ý: “Bạn sửa lý do quay lại. Hai câu trong kịch bản v5 cần xem lại; phân tích các clip khác được giữ.” Hoặc: “Đã lưu thay đổi · Preview v4 cần duyệt lại.”

Chỉnh sửa đã commit tạo revision mới. Sửa đang gõ có draft riêng. Kết quả job AI phải kèm revision đầu vào; chỉ áp dụng vào đúng nền dữ liệu nếu còn hợp lệ. Nếu không, giữ thành đề xuất có nhãn cũ và cho người dùng so sánh.

Undo/redo hỗ trợ chỉnh sửa của người dùng, nhưng không tự phục hồi approval bằng cách bật lại một cờ. Việc phục hồi nội dung phải đi qua kiểm tra revision/dependency. Lịch sử các lần duyệt vẫn tồn tại để truy nguyên.

WAV/graphics/edit plan đã duyệt có danh tính bytes được giữ ở core. UI không nói “đã khôi phục bản cũ” khi chỉ chạy lại cùng prompt/seed mà tạo audio mới. Tái render dùng approved media có thể tiếp tục đúng policy; tái sinh làm đổi timing/nội dung phải hiện thay đổi và yêu cầu cổng duyệt thích hợp.

## 12. Trạng thái, tiến trình và thông báo

### 12.1. Mọi màn hình phải có trạng thái đầy đủ

| Trạng thái | Ví dụ nội dung UI | Hành động phù hợp |
|---|---|---|
| Chưa có dữ liệu | “Chưa có tư liệu cho ngày này” | Thêm tư liệu / đổi ngày |
| Đang tải | Placeholder ổn định và tên phần đang tải | Cho rời màn; không xóa nội dung đang gõ |
| Đang nhận tư liệu | “Đã sao chụp 8/12 file · Đang kiểm tra nội dung” | Xem từng file / tạm dừng; chưa gán đã phân tích |
| Có một phần kết quả | “Đã xử lý 8/12 clip; 1 clip cần liên kết lại” | Xem phần sẵn sàng / xử lý nguồn thiếu |
| Chờ tài nguyên | “Đang chờ Resolve giải phóng bộ nhớ” | Xem hàng đợi / tạm dừng công việc |
| Chờ người dùng | “Phương án A cần làm rõ một mốc thời gian” | Mở câu hỏi / chọn phương án hợp lệ khác |
| Cần cập nhật | “Kết quả dùng ghi chú v2; hiện tại là v3” | Xem thay đổi / chạy lại phần bị ảnh hưởng |
| Chờ đối chiếu tác động | “Có tư liệu mới ảnh hưởng phạm vi câu chuyện” | Xem nguồn mới / đợi hoặc tiếp tục phần độc lập |
| Đang đối chiếu Resolve | “Đang kiểm tra thao tác dựng đã hoàn tất chưa” | Xem chi tiết; chỉ dùng hành động core cho phép |
| Lưu thất bại | “Chưa lưu được thay đổi vào dự án” | Thử lại / lưu bản khôi phục |
| Lỗi tác vụ | Lý do cụ thể, phạm vi và bước đã hoàn tất | Thử lại từ checkpoint / xem chi tiết |
| Hoàn tất đúng phạm vi | “Phân tích 12/12 clip; còn 2 câu hỏi” | Xử lý câu hỏi / xem kịch bản đủ điều kiện |

Không thay lỗi chặn bằng toast biến mất vài giây. Dùng thông báo inline cạnh phần liên quan, banner khi ảnh hưởng toàn màn và hộp thoại khi phải ra quyết định trước khi tiếp tục. Thành công thông thường không cần liên tục bật modal.

### 12.2. Trung tâm tác vụ

Mỗi job có tên dễ hiểu, phạm vi, giai đoạn, số lượng thực đã xử lý, thời gian đã chạy, trạng thái chờ/lỗi và hành động pause/resume/cancel phù hợp. “Đang tạm dừng…” nghĩa là yêu cầu đã nhận, chưa có nghĩa worker đã dừng tại checkpoint.

Mất heartbeat không đồng nghĩa worker đã thoát. UI có thể hiện **“Đang kiểm tra tác vụ chưa phản hồi”**, vẫn giữ quyền biên tập và không cho nút Chạy lại khởi động model nặng thứ hai. Job đã hủy không được quay lại thành hoàn tất vì kết quả cũ tới muộn. Attempt IDs/fencing tokens nằm trong chẩn đoán nâng cao, không biến màn chính thành bảng log kỹ thuật.

Không dùng “Đã hiểu 100% video”. Có thể hiển thị “Quét xong 12/12 clip” và riêng “Còn 2 câu hỏi cần làm rõ”. Coverage, mức hoàn tất tác vụ, tính đúng của phân tích và chất lượng câu chuyện không dùng chung một phần trăm.

Không đưa ETA giả khi chưa có dữ liệu ước lượng. Throttle thông báo tiến trình ở mức khởi đầu 5–10 lần/giây hoặc thấp hơn theo phép đo; đây là tốc độ cập nhật UI, không phải tốc độ phân tích video. Lỗi, chuyển giai đoạn và phản hồi thao tác phải được chuyển kịp thời, không bị bỏ vì throttle.

## 13. Nhập tiếng Việt, bàn phím và focus

Ưu tiên text control native; chỉ bridge `NSTextView` khi có nhu cầu đã được chứng minh, như quản lý selection hoặc annotation mà control đang dùng không đáp ứng. Không tự viết editor phức tạp trong MVP.

Bắt buộc kiểm tra Telex, VNI nếu hỗ trợ bằng bộ gõ cài trên máy, bộ gõ tiếng Việt hệ thống, emoji, paste dài, nhiều dòng, chọn chữ, copy/paste và undo/redo. Không thay toàn bộ binding văn bản hoặc chạy formatter khi input method còn marked text; API `NSTextInputClient` cung cấp trạng thái này cho phần tích hợp AppKit. [S6]

| Thao tác | Phím dự kiến | Phạm vi |
|---|---|---|
| Tạo / mở dự án | `⌘N` / `⌘O` | Cửa sổ dự án |
| Lưu ngay draft | `⌘S` | Chờ xác nhận ghi thành công; không duyệt dữ kiện |
| Thêm tư liệu | `⇧⌘I` | Dự án đang active; kiểm tra xung đột với menu |
| Tìm kiếm | `⌘F` | Màn hình/editor có focus |
| Settings | `⌘,` | Ứng dụng |
| Undo / redo | `⌘Z` / `⇧⌘Z` | Đúng editor/đối tượng đang thao tác |
| Phát / dừng video | `Space` | Chỉ khi player hoặc thanh beat có focus |
| Đi qua control | `Tab` / `⇧Tab` | Focus nhìn thấy, theo thứ tự hợp lý |

Nếu thêm J/K/L hoặc I/O, chỉ nhận khi player/timeline có focus. Khi người dùng gõ ghi chú, Space vẫn là dấu cách và Return vẫn xuống dòng. Không có phím đơn toàn cục vô tình duyệt kịch bản hoặc xuất video. Button đang được focus vẫn phải kích hoạt được bằng bàn phím theo hành vi native, với tên và phiên bản rõ ràng.

Không tự cướp focus khi có kết quả AI, khi mở notification hoặc khi danh sách review đổi thứ tự. Sau khi giải quyết một câu hỏi, chuyển focus có chủ đích và giữ khả năng quay lại câu vừa xử lý.

## 14. Lưu dữ liệu, revision và chống duyệt nhầm

### 14.1. Autosave có xác nhận ghi

Draft lưu nền với debounce khởi đầu khoảng 300–700 ms khi phù hợp; không can thiệp quá trình ghép ký tự của bộ gõ. Khi rời editor, chuyển project hoặc duyệt nội dung, flush phần thay đổi cần lưu và chờ acknowledgement của nơi lưu có thẩm quyền.

Ba trạng thái bắt buộc: **Đang lưu**, **Đã lưu**, **Lưu lỗi**. Chỉ hiển thị “Đã lưu” sau khi nhận xác nhận commit thành công. Autosave không đồng nghĩa xác nhận dữ kiện, duyệt script hoặc duyệt preview. Bản đang gõ chưa được lưu có thể mất nếu tiến trình bị kill đột ngột; thiết kế phải giảm cửa sổ mất mát và báo trạng thái trung thực, không hứa chưa gõ xong cũng đã an toàn.

Nếu không ghi được do ổ đầy/quyền truy cập, giữ buffer và hiển thị cách khôi phục hoặc lưu bản sao ở nơi được phép. Không đóng app tự động làm mất thay đổi chưa lưu. Checkpoint dữ liệu quan trọng trong quá trình làm việc; không chờ tới lúc Quit mới ghi cả dự án.

### 14.2. Lệnh UI phải gắn revision

Lệnh sửa/xác nhận/duyệt mang project ID, entity ID, revision đã xem, idempotency key của logical command và tập revision/scope phụ thuộc cần thiết. Core Swift/ProjectStore kiểm trong transaction canonical rồi mới commit. Worker chỉ trả typed results qua IPC, không được ghi trạng thái chuẩn hoặc cấp approval. UI không tự sửa cờ approval trong bộ nhớ và coi đó là dữ liệu chuẩn.

Nếu expected revision không còn đúng, trả trạng thái conflict có nội dung dễ hiểu. Hiển thị diff để người dùng xem bản mới. Nhấn nút hai lần hoặc retry sau IPC mất phản hồi không được tạo hai approval hoặc hai render job; các lệnh cần khóa chống gửi trùng và khóa idempotency ở core theo kiến trúc v3.1.

## 15. Đáp ứng và bộ nhớ trên M1 Pro 16 GB

### 15.1. UI vẫn dùng được trong lúc AI làm việc lâu

Main actor chỉ phục vụ cập nhật UI và state nhẹ. Decode, hash, đọc source lớn, truy vấn/ghi DB nặng, inference, FFmpeg và chờ Resolve thực hiện ngoài đường xử lý UI. Viết `async` hoặc `Task {}` không tự chứng minh công việc đã rời main actor; phải kiểm tra isolation và đo đúng toolchain. Apple hướng dẫn giữ phần xử lý đồng bộ cho một tương tác rời rạc trên main thread dưới khoảng 100 ms, đồng thời kiểm tra hangs/hitches trên thiết bị thực. [S4]

Mục tiêu v0.1 trong tài liệu 09: `ui_light_action_latency_p95_ms` không quá 100 ms cho phản hồi nhìn thấy của chọn hàng, nhận lệnh pause và đổi focus trên fixture/tải đã công bố. Đây là mục tiêu cần đo, không phải cam kết mọi màn hình tải xong hoặc mọi worker dừng xong trong 100 ms. Nhiệm vụ dài phải phản hồi trạng thái sớm và cho tiếp tục công việc độc lập; khi thay target, cập nhật tài liệu 09 và phép thử trước.

Orchestrator/resource governor toàn app kiểm soát tổng tài nguyên của UI, workers và Resolve qua mọi project. Heavy lease bao phủ inference/render/media nặng theo policy; không chạy Resolve render cùng model nặng. Mở tab hoặc thumbnail không được kích hoạt thêm model ngoài hàng đợi. Decode nhẹ vẫn có buffer/quota và không được làm UI treo vì tạo quá nhiều việc.

### 15.2. Hạn chế tăng RAM vô ích

- Thumbnail tạo bất đồng bộ đúng kích thước hiển thị; đặt `maximumSize` khi dùng `AVAssetImageGenerator`, vì giá trị mặc định zero cho ảnh ở kích thước gốc. [S5]
- Dùng cache có quota và eviction; mức khởi đầu đề xuất là 128 MiB cho thumbnail UI, sau đó đo và điều chỉnh trong ngân sách chung. Đây không phải quota cho model, proxy hay toàn app.
- Danh sách lớn tải theo nhu cầu và có ID ổn định. Hủy công việc tải thumbnail không còn cần khi phù hợp; không decode đồng loạt cả thư viện.
- Không tạo mới `AVPlayer` mỗi lần SwiftUI tính `body`. Quản lý vòng đời player, time observer, observer khác và task; giải phóng khi rời phạm vi sử dụng.
- Một yêu cầu seek/source mới phải làm kết quả yêu cầu cũ không thể ghi đè selection mới. Không trình bày frame cũ cùng nhãn source mới.
- Giới hạn buffer log, IPC và danh sách progress. Không append vô hạn mọi dòng worker vào state hiển thị.
- LRU/cache xem trước có thể dọn theo quota; evidence, revisions, source và artifact đã cam kết không bị xóa như cache tạm.

Không đặt lời hứa “app dùng tối đa 2 GB” khi chưa đo. Báo cáo riêng RAM tiến trình UI, worker và Resolve; kiểm tra memory pressure và xu hướng tăng sau nhiều vòng thao tác.

## 16. Quyền file, đóng app và phục hồi gián đoạn

### 16.1. Nguồn và thư mục dự án

Dùng file/folder picker hệ thống, giữ original chỉ đọc, source snapshot được core quản lý và nơi xuất có quyền riêng. Kiểm nơi project active là APFS local được hỗ trợ, không network share hoặc thư mục live cloud sync. Nếu phân phối bản sandbox, xử lý security-scoped bookmarks, stale bookmark và cân bằng vòng truy cập tài nguyên. Phải kiểm chứng quyền của worker đóng gói ngay ở G0; truyền pathname không tự giải quyết quyền tiến trình con. Các cơ chế này theo hướng dẫn App Sandbox của Apple. [S7]

Khi original bị dời nhưng snapshot còn khỏe, ghi **Nguồn gốc đã đổi vị trí · Bản chụp dự án vẫn sẵn sàng**, không chặn vô cớ pipeline hiện tại. Khi thiếu snapshot/quyền nơi dự án, hiển thị **Cần khôi phục tư liệu** hoặc **Cần cấp lại quyền** theo nguyên nhân, với asset và hành động cụ thể. Không hiện traceback trên màn chính. Relink/nhận lại phải kiểm identity/hash; nội dung khác tạo source revision mới và impact review.

### 16.2. Đóng cửa sổ, thoát ứng dụng

- `⌘W` khi không có dữ liệu chưa lưu hoặc quyết định job cần xử lý có thể đóng cửa sổ bình thường.
- Nếu người dùng chọn tiếp tục xử lý khi đóng cửa sổ, app vẫn sống và có cách mở lại trung tâm tác vụ; UI giải thích rõ lựa chọn này. Đóng cửa sổ không ngầm hủy hoặc nhân đôi job.
- `⌘Q` xử lý draft chưa lưu và đưa job về checkpoint/trạng thái an toàn theo chính sách. Không để Python worker mồ côi hoặc treo cửa sổ vô thời hạn trong lúc chờ.
- Nếu dùng cơ chế trì hoãn termination của AppKit, phải hoàn tất giao thức phản hồi. Không chỉ đặt code lưu dự án trong `applicationWillTerminate`. [S8]
- Lần mở sau khôi phục project, vùng làm việc và draft đã lưu; UI state restoration không thay cho độ bền dữ liệu của database.

### 16.3. Sleep/wake, ổ ngoài và Resolve

Checkpoint đều trong quá trình xử lý. Sleep/wake là một gián đoạn có thể xảy ra; không hứa phân tích sẽ tiếp tục khi gập máy. Sau wake, kiểm snapshot đang dùng, quyền nơi project/source đang acquire, worker/attempt, ngân sách tài nguyên và kết nối Resolve trước khi resume. Không bắt original còn cùng đường dẫn khi sealed snapshot vẫn hợp lệ. Nếu dùng `NSWorkspace.didWakeNotification`, đăng ký qua notification center tương ứng của workspace. [S9]

Không khởi chạy lại thao tác append timeline hoặc render chỉ vì UI chưa thấy kết quả; đối chiếu job/checkpoint và trạng thái Resolve để tránh thao tác trùng. Rút ổ nguồn, Resolve đóng hoặc worker crash phải có lý do chờ/lỗi và hành động phục hồi cụ thể.

Mặc định tôn trọng chính sách ngủ của hệ thống. Nếu sau này thêm tùy chọn giữ máy thức khi render, đó phải là lựa chọn rõ ràng, có phạm vi và kết thúc khi tác vụ xong; không thay đổi cấu hình nguồn điện toàn hệ thống.

### 16.4. Backup và restore có phạm vi rõ

Menu dự án có **Sao lưu**, **Xem các bản sao lưu** và **Khôi phục thành dự án mới**. Mỗi bản ghi rõ thời điểm, revision, trạng thái kiểm tra và loại. Không gọi bản checkpoint là “toàn bộ dự án mang sang máy khác” khi thiếu source/model.

| Loại | Nội dung người dùng cần hiểu | Câu chữ gợi ý |
|---|---|---|
| `checkpoint_backup` | Giữ trạng thái và manifest nhất quán; có thể cần tư liệu/model còn ở kho đã ghi | “Bản khôi phục trạng thái · Cần các tư liệu được liệt kê” |
| `portable_backup` | Gồm sealed media được tham chiếu, artifact cần thiết và export Resolve | “Bản dự án có tư liệu · Xem runtime/model cần để tiếp tục AI” |
| Bundle weights tùy chọn | Thêm đúng bộ model/runtime artifact đã chọn nếu được phép bundle | Hiển thị bytes, revision và quyền dùng; không tải/gộp ngầm |

Mục tiêu backup user state khoảng 15 phút hoạt động, tại cổng duyệt và trước migration theo tài liệu 05/09. UI báo **Đang tạo**, **Đang kiểm**, **Sẵn sàng** hoặc **Sao lưu lỗi**; chưa xác minh manifest/hash thì chưa báo thành công. Sao lưu lỗi không làm các thay đổi DB đã commit biến thành chưa lưu, nhưng cần nêu đúng rủi ro khôi phục và đường thử lại.

Trước restore, kiểm schema, dung lượng, manifest/hash và prerequisites; hiển thị thiếu gì với hành động chọn nguồn/runtime đúng revision. Restore vào thư mục mới, không ghi đè project đang mở. Sau kiểm thành công, cho mở bản khôi phục và đối chiếu revision với bản gốc. Không tự cấp lại approvals nếu bytes/dependency đã khác.

### 16.5. Phiên bản dữ liệu và chẩn đoán

Khi cần migration, báo ngắn **“Đang chuẩn bị bản sao an toàn trước khi nâng dữ liệu dự án”**. Nếu thiếu SSD/backup không đạt thì giữ project cũ và hướng dẫn xử lý. Migration gián đoạn phải có trạng thái khôi phục từ core; không cho UI tự sửa schema để bỏ qua lỗi.

App cũ mở schema mới hiện **“Dự án này cần phiên bản ứng dụng mới hơn”**, cho đường mở chỉ đọc nếu core thực sự hỗ trợ hoặc hướng dẫn dùng bản phù hợp. Không downgrade âm thầm. Báo cáo chẩn đoán do người dùng chủ động xuất có build, policy và lỗi cần thiết; tránh đưa nội dung brief/ảnh cá nhân vào báo cáo nếu không cần.

## 17. Accessibility và độ dễ đọc

Các thông tin về nguồn, độ chắc, lỗi, khóa và approval phải đọc được bằng chữ; icon và màu là hỗ trợ. VoiceOver cần label/value/hint hợp lý cho player, thanh beat, progress và các nút duyệt. Thứ tự đọc review là câu hỏi → nội dung liên quan → bằng chứng → hành động.

Tôn trọng Reduce Motion, Reduce Transparency, Increased Contrast và appearance hệ thống. Với SwiftUI dùng environment/API phù hợp deployment target, ví dụ `accessibilityReduceMotion` và `colorSchemeContrast`; không tự đặt tên một API chưa kiểm chứng. [S10]

Cho tăng cỡ chữ nội dung trong app theo các mức phù hợp, tối thiểu kiểm thử mặc định, 125% và 150%. Không giả định cơ chế cỡ chữ trên iOS tự áp dụng nguyên trạng cho mọi màn macOS. Khi chữ lớn, đổi layout hoặc cho cuộn; không chỉ co chữ lại để khớp panel.

Mục tiêu tương phản cho bề mặt tùy chỉnh: ít nhất 4.5:1 cho chữ thông thường và 3:1 cho chữ lớn theo định nghĩa liên quan; kiểm cả trạng thái disabled/selected và các bề mặt thật. Đây là mục tiêu thiết kế tham chiếu WCAG, không phải tuyên bố chứng nhận accessibility của app. [S13]

Kiểm tra bằng Accessibility Inspector và thao tác VoiceOver thực tế. Audit tự động chỉ là một phần; người kiểm phải thực hiện được các bước cốt lõi, thấy focus, hiểu lý do nút chưa dùng được và phục hồi sau lỗi. [S11]

## 18. Thành phần triển khai và tương thích macOS

| Vai trò | Lựa chọn nền tảng ưu tiên | Điều kiện |
|---|---|---|
| App shell và điều hướng | SwiftUI `WindowGroup`, `NavigationSplitView` | Target hỗ trợ; visibility theo chính sách cửa sổ |
| Inspector | API inspector native nếu có; detail view native nếu cần fallback | Có cùng nội dung và hành động, không mất chức năng trên OS tối thiểu |
| Thư viện tư liệu | `Table`/`List` hoặc grid theo nhu cầu | Selection ổn định; tải thumbnail có giới hạn |
| Ghi chú/kịch bản | Native text control; AppKit bridge có lý do | Đạt ca gõ tiếng Việt, selection, undo, focus |
| Media | AVKit/AVFoundation player/thumbnail | Lựa chọn API theo nhu cầu source, observer và quyền |
| Menu và lệnh | `Commands`, keyboard shortcuts, focus theo ngữ cảnh | Không dùng handler phím toàn cục để chiếm thao tác gõ |
| Chọn file | Native importer hoặc `NSOpenPanel` | Đạt ca quyền file trên bản app đóng gói |
| State hiển thị | Store có kiểu trạng thái rõ, ID/revision/scope ổn định | Không sao chép business truth thành cờ độc lập trong từng view |
| Lưu nghiệp vụ | Core Swift/ProjectStore ghi SQLite canonical; export JSON theo revision | Settings/UI restoration và worker outputs không thay nguồn chuẩn |
| Worker IPC | JSON-RPC 2.0 qua UTF-8 JSON Lines stdio theo tài liệu 05 | Stdout chỉ protocol; logs stderr có giới hạn; UI không tự gọi inference |

Trước khi viết UI hoàn chỉnh, ghi vào ma trận hỗ trợ: phiên bản macOS thực tế, deployment target, Xcode/Swift/SDK, kiến trúc arm64, Resolve và runtime model đã kiểm chứng. Minimum OS là giao điểm các yêu cầu đã xác minh của app và runtime. Không chọn OS mới nhất chỉ để lấy hiệu ứng hình ảnh.

Kiểm availability cho API và SF Symbols, dùng `#available` cùng fallback tương đương khi cần. Không ghi một phiên bản macOS tối thiểu bằng suy đoán hoặc tuyên bố hỗ trợ mọi MacBook. Apple có hướng dẫn kiểm platform/OS availability; kết quả build và chạy thật mới quyết định phạm vi hỗ trợ. [S12]

Thiết kế view state nên phân biệt loading, ready, partial, blocked, error và stale. Giao diện nhận dữ liệu có revision từ core; business validation ở core. Tách feature theo Tư liệu/Brief/Review/Script/Render và dùng chung các thành phần như SourceBadge, SaveStatus, RevisionBanner, EvidenceViewer, IssueList. Tên module có thể đổi, hợp đồng hành vi không đổi.

## 19. Các nâng cấp nên ưu tiên

| Mức | Nâng cấp | Giá trị với chất lượng video |
|---|---|---|
| P0 | Review đặt bằng chứng theo loại nguồn cạnh câu hỏi và dữ kiện | Giảm trả lời sai ngữ cảnh; làm rõ phần thực sự ảnh hưởng câu chuyện |
| P0 | Liên kết câu kể ↔ beat ↔ source | Người dùng kiểm lời và hình ngay tại nơi biên tập |
| P0 | Revision/diff và tác động thay đổi | Sửa dữ kiện mà vẫn biết bản dựng nào cần xem lại |
| P0 | Phân biệt nguồn, review và approval | Tránh nhầm lời kể với bằng chứng; tránh duyệt nhầm bản |
| P0 | Ghi chú tự do, đề xuất facts tách riêng | Nhập bối cảnh thuận tiện mà giữ quyền xác nhận |
| P0 | UI đáp ứng, autosave, recovery và layout thích ứng | Bảo vệ công sức chỉnh sửa và dùng được khi AI chạy lâu |
| P0 | Snapshot/disk preflight, impact pending và phân biệt nhánh Resolve | Tránh dùng source thay đổi, xuất khi chưa đối chiếu và ghi đè sửa tay |
| P0 | Kiểu backup, restore và migration có trạng thái thật | Người dùng hiểu phần đã an toàn và phần cần khôi phục |
| P1 | So sánh kịch bản gọn và nghe từng beat | Chọn góc kể bằng nội dung và nhịp thực tế |
| P1 | Bộ lọc “Ảnh hưởng bản đang chọn” | Giảm số câu hỏi phải xem mà không bỏ qua câu hỏi cốt lõi |
| P1 | Trình duyệt lịch sử nâng cao và quản lý profile gu thuận tiện | Backend giữ lịch sử/khóa là P0; P1 chỉ là giao diện tra cứu và tiện ích thêm |
| P2 | Workspace tùy biến, cửa sổ tham chiếu riêng | Chỉ làm sau khi luồng lõi ổn định và có nhu cầu thật |

P0 ở đây là mức ưu tiên của yêu cầu UI khi phần nghiệp vụ tương ứng được triển khai. Không có nghĩa bỏ qua các benchmark lõi trong roadmap hiện có để làm giao diện trước.

## 20. Ma trận nghiệm thu trước khi gọi là ổn định

### 20.1. Môi trường và fixture

Ghi build commit, cấu hình app, phiên bản OS/Resolve/runtime/SQLite, máy, RAM, màn hình, scale, chế độ nguồn, profile E0/E1 và dữ liệu thử. Kiểm bản Release arm64 đã đóng gói trên M1 Pro 16 GB mục tiêu và phiên bản OS thấp nhất app công bố hỗ trợ; nếu thêm OS/máy khác vào tuyên bố hỗ trợ thì thêm dòng kiểm tương ứng. Mỗi lần chạy có fixture hash, requirement ID và evidence; chưa chạy ghi NOT_RUN, không ghi đạt dựa trên screenshot.

Fixture đề xuất: một project thực đại diện và một project stress có 1.000 asset, 300 dữ kiện, 100 review item, ghi chú tiếng Việt khoảng 30.000 ký tự, tên file dài/Unicode, MOV/H.265/VFR, HEIC, clip im lặng, snapshot thiếu/hỏng, nguồn gốc bị dời, một số mâu thuẫn và dữ kiện thay đổi sau duyệt. Đây là bộ thử UI/khả năng phục hồi; không thay benchmark độ đúng của model, chất lượng kịch bản hoặc mở rộng giới hạn E0/E1. Thêm fixture manual Resolve branch, source mới làm đổi evidence scope, thiếu SSD và checkpoint/portable backup có prerequisites khác nhau.

### 20.2. Checklist bắt buộc

ID và điều kiện có thẩm quyền ở mục 10 của tài liệu 09. Bảng dưới gồm 28 ca UI đã thống nhất; mọi dòng đều cần kết quả chạy thật và đường dẫn chứng cứ.

| ID | Ca kiểm | Điều kiện đạt |
|---|---|---|
| UI-01 | 960×640, 1280×800, 1440×900 pt; resize, sidebar, inspector, full screen | Thao tác cốt lõi truy cập được; không mất nội dung, selection hoặc nút |
| UI-02 | Sáng/Tối/Theo hệ thống; contrast, giảm motion/transparency | Chữ, focus và trạng thái đọc được; video đã duyệt không đổi |
| UI-03 | Cỡ chữ mặc định, 125%, 150%; nhãn dài | Không chồng, cắt nội dung quyết định hoặc ép chữ nhỏ trở lại |
| UI-04 | Gõ tiếng Việt, emoji, paste dài; job cập nhật liên tục | Không mất dấu, nhảy caret, mất selection hoặc trộn undo với progress |
| UI-05 | Bàn phím và VoiceOver qua luồng chính | Focus hợp lý; nguồn, câu hỏi, lỗi và nút duyệt đọc được |
| UI-06 | Lưu brief rồi chạy extraction | Fact còn nháp cho tới xác nhận đúng phạm vi; nguồn brief không đổi |
| UI-07 | Kết quả AI cũ về khi người dùng đang sửa | Không ghi đè sửa mới; kết quả có nhãn revision đúng |
| UI-08 | Xác nhận nhiều mục khi có mục mới từ worker | Chỉ xác nhận tập nội dung/revision đã xem và chọn |
| UI-09 | Hai thao tác sửa/duyệt cạnh nhau; click hai lần; retry IPC | Không duyệt sai snapshot, không sinh lệnh commit hoặc job trùng |
| UI-10 | Chọn script; duyệt script; duyệt preview | Ba hành động riêng; không tự xác nhận fact ngoài phạm vi |
| UI-11 | Sửa fact, lời, shot, crop hoặc mix sau duyệt | Đánh dấu đúng artifact phụ thuộc cần xem lại; lịch sử duyệt giữ nguyên |
| UI-12 | Review chỉ có nguồn brief; chọn “Tôi chưa rõ” hoặc bỏ chi tiết | Không ép gán media làm bằng chứng; không thành đồng ý ngầm; việc độc lập vẫn chạy |
| UI-13 | Click câu/shot và seek nhanh qua nhiều source | Hình, lời, nhãn thời gian và revision luôn cùng đối tượng |
| UI-14 | Cuộn fixture lớn; đổi preview ít nhất 50 vòng | Player/observer được thu hồi; RAM không tăng theo số vòng vô hạn |
| UI-15 | Inference/render đang chạy; gõ, cuộn, nhận lệnh pause | UI đáp ứng theo ngưỡng đã đo; không chạy việc nặng trên main actor |
| UI-16 | Ổ đầy, mất quyền khi autosave, đường dẫn chứa Unicode | Không báo “Đã lưu” sai; giữ buffer và có cách phục hồi |
| UI-17 | Cmd+W/Cmd+Q khi gõ, phân tích, render; mở lại | Draft đã commit còn đúng; job không trùng; worker không mồ côi |
| UI-18 | Sleep/wake; rút ổ; Resolve đóng; worker crash | Trạng thái rõ; phân biệt snapshot khỏe với original bị dời; resume đúng, không nhân đôi timeline |
| UI-19 | Mở lại app, stale bookmark, source đổi cùng tên, snapshot hỏng | Quyền/identity/hash được kiểm; không dùng approval cho nội dung mới; restore/relink đúng trường hợp |
| UI-20 | Mở hai project hoặc mở lại project đang mở | Menu/toolbar/selection đúng cửa sổ; tài nguyên vẫn có governor chung |
| UI-21 | Rút màn ngoài, đổi scale, khôi phục cửa sổ | Cửa sổ và hộp thoại nằm trong vùng có thể thao tác |
| UI-22 | Final render xong nhưng QC thất bại | Chưa báo hoàn tất; có lỗi theo đoạn và đường sửa đúng phạm vi |
| UI-23 | Offline sau setup; thiếu runtime/model hoặc phiên bản không phù hợp | Không tự gọi cloud; phát hiện phần thiếu và hướng dẫn xử lý rõ |
| UI-24 | Clone/copy snapshot; disk preflight; COW growth; hết chỗ | Hiển thị đúng giai đoạn/chi phí; không hứa clone 0 bytes hoặc đổi sang direct-read |
| UI-25 | Managed timeline drift; tạo và sửa manual handoff | Nhánh tự động/thủ công rõ; không ghi đè sửa tay, giả roundtrip hoặc gán final QC sai |
| UI-26 | Checkpoint/portable backup, restore, migration lỗi | Phạm vi/prerequisites rõ; restore vào nơi mới; không phá dữ liệu schema mới |
| UI-27 | Source đến muộn làm đổi scope; input vượt E0/E1 | Impact pending và đúng phần bị chặn; không làm stale mọi thứ hoặc giấu giới hạn hỗ trợ |
| UI-28 | Workday thật do người dùng thao tác không cần hướng dẫn trực tiếp | Đo active time/questions; hiểu đúng nguồn/approval/nhánh thủ công; xử lý lỗi hiểu critical |

Đo responsiveness bằng Instruments và kiểm lỗi vòng đời/bộ nhớ bằng công cụ phù hợp. Dùng kiểm thử trạng thái cho revision/approval và UI automation cho luồng gõ, điều hướng, lưu, phục hồi; kiểm thủ công thêm player, VoiceOver, bộ gõ và sleep/wake. Screenshot đẹp không thay các ca này.

Chạy một phiên sử dụng kéo dài đại diện, tối thiểu hai giờ trong vòng nghiệm thu ban đầu, gồm phân tích, sửa, review và preview; ghi memory pressure, RAM theo tiến trình, hangs, lỗi lưu và job resume. Mở rộng đến lượt dài nhất trong envelope định phát hành và khi có rủi ro cụ thể; hai giờ không chứng nhận một job chạy dài hơn. Không dùng thời lượng chạy như bằng chứng app tuyệt đối không lỗi.

### 20.3. Cổng phát hành

Các lỗi chặn gồm: mất dữ liệu đã commit, ghi sai trạng thái lưu, duyệt nhầm revision, source identity/mapping sai, ghi đè chỉnh tay, xuất khi impact scope chưa rõ, crash/treo cản trở luồng chính, mất khả năng tiếp cận hành động bắt buộc và phục hồi tạo job/timeline trùng. Không phát hành khi còn lỗi chặn chưa xử lý trong ma trận/phạm vi E0/E1 đã công bố. E0 pilot phải mang nhãn E0; không mượn kết quả đó để công bố đã đạt E1.

Biên bản nghiệm thu phải có ca đã chạy, kết quả, cấu hình máy và hạn chế còn lại. Cách công bố đúng: **“Đã vượt ma trận nghiệm thu trên các cấu hình được liệt kê; không còn lỗi chặn đã biết trong phạm vi đó.”** Không dùng câu “không lỗi trên mọi MacBook”.

### 20.4. Kiểm người dùng hiểu đúng và công sức biên tập

Cho người dùng thực hiện một workday đại diện: nhập brief, xử lý câu hỏi, sửa một câu, duyệt script/preview, thêm source mới, tạo bản sửa thủ công và khôi phục backup. Quan sát chỗ người dùng ngập ngừng hoặc hiểu nhầm; không hướng dẫn trước câu trả lời đúng rồi tính thao tác thành công.

Đo `active_review_minutes_per_project`, `duplicate_question_rate`, `useful_question_rate` đúng định nghĩa/mẫu số tài liệu 09. Tách thời gian chờ máy và thời gian thao tác; không coi người dùng rời máy là UI chậm. Không đặt một trần câu hỏi tùy ý để làm báo cáo đẹp. Lỗi hiểu critical, như nghĩ ảnh minh họa là chứng cứ hoặc nghĩ bản thủ công đã được app QC, cần sửa câu chữ/bố cục rồi kiểm lại.

## 21. Thứ tự triển khai

1. **G0 — shell đóng gói tối thiểu:** chốt OS/SDK/runtime và chạy đường `.app` thật, worker/quyền file/offline/Resolve 10 giây. Dựng menu/sidebar/resize; dữ liệu mock phải có nhãn. Không đợi UI hoàn thiện mới phát hiện helper không chạy được.
2. **G1 — dữ liệu và an toàn thao tác:** editor tiếng Việt, source snapshots/disk, save ACK, ProjectStore, revision-aware commands, pause/cancel, backup/restore/migration. Dùng state fixture để thử stale approval, mất ACK và crash ngay khi chưa có AI hoàn chỉnh.
3. **G2 — brief và review thật:** fact drafts, evidence player, câu hỏi có scope, corpus revalidation và các trạng thái chưa rõ. Kết nối phân tích đã vượt benchmark của giai đoạn tương ứng.
4. **G3/G4 — script và preview:** lời/shot/khóa/diff, TTS thử, script approval, managed Resolve, manual handoff, preview QC và approval. Không làm cơ chế giữ sửa tay sau cùng.
5. **G5 — final và nghiệm thu phạm vi:** final QC, restore/portable backup, appearance/accessibility, Instruments, offline và soak trên bản Release. Chỉ mở rộng P2 khi rủi ro P0 đã xử lý; capability chưa đạt phải hiện đúng giới hạn.

Các bước UI chạy cùng G0–G5 trong tài liệu 05 và checklist từng bước ở tài liệu 11. Không bỏ benchmark phân tích/kịch bản chỉ vì prototype giao diện đã đẹp. Target/requirement IDs lấy từ tài liệu 09; không đặt một bộ điều kiện dễ hơn riêng cho UI.

## 22. Yêu cầu bàn giao cho người hoặc AI lập trình

Bàn giao tối thiểu phải gồm shell native macOS, các màn chính với mọi trạng thái lỗi/chờ/stale/impact pending, design tokens, thành phần dùng lại, focus/shortcut, revision-aware commands, UI snapshots/backup/Resolve handoff, tài liệu build và biên bản nghiệm thu. Định nghĩa rõ phần nào đang mock, đã nối backend, đã kiểm trên máy nào và capability nào chưa đạt. Không dùng checkbox hoàn thành để biểu thị mới viết xong mô tả.

Đoạn giao việc có thể sao chép:

```text
Đọc README.md, 01-PRODUCT.md đến 10-UI-UX-MACOS.md và
11-CODING-WORKFLOW-AND-CHECKLIST.md trước khi triển khai UI AIVideo v3.1.

Tạo ứng dụng native macOS bằng SwiftUI; dùng AppKit/AVKit có chủ đích.
Core Swift/ProjectStore là writer canonical; worker Python không ghi SQLite.
IPC dùng JSON-RPC 2.0 qua UTF-8 JSON Lines stdio theo tài liệu 05.
Trước tiên kiểm macOS, Xcode/Swift/SDK, Resolve và runtime thực tế để chốt
deployment target và fallback. Không tự yêu cầu nâng OS chỉ vì hiệu ứng UI.

Ưu tiên 5 màn: Tư liệu, Ngày làm việc, Cần làm rõ, Kịch bản, Dựng & xuất.
Giữ layout thích ứng, nhập tiếng Việt ổn định và UI đáp ứng khi worker chạy.
Hiển thị đúng snapshot/dung lượng, impact pending, kiểu backup và các nhánh
Resolve tự động/thủ công. Không giả đồng bộ chỉnh tay trở lại app trong MVP.
Ghi chú, fact confirmation, chọn script, script approval và preview approval
là các hành động khác nhau; tất cả lệnh ghi phải kiểm đúng revision/phạm vi.

Không ghi đè chỉnh tay bằng kết quả AI; giữ nguồn bằng chứng, mức chưa chắc,
ràng buộc khóa và dependency invalidation. Không thay định nghĩa dữ liệu để
né lỗi UI. Mọi nút chưa hoạt động phải thể hiện đúng trạng thái, không giả thành công.

Triển khai theo mục 21 và tài liệu 11; nghiệm thu UI-01 đến UI-28 và các
invariant liên quan ở tài liệu 09. Đưa .app/worker/quyền file spike lên G0,
đưa lưu/phục hồi lên G1. Báo phần đã làm, test evidence, cấu hình đã chạy,
envelope đã kiểm và hạn chế còn lại. Chưa chạy bản Release trên Mac mục tiêu
thì không tuyên bố app ổn định hoặc không lỗi. Không đánh dấu [x] nếu chưa làm.
```

## 23. Nguồn kỹ thuật tham chiếu

Các nguồn dưới đây hỗ trợ nguyên tắc và API nền tảng. Thiết kế màn hình, breakpoint, quota, fixture, câu chữ và mức ưu tiên trong tài liệu là đề xuất riêng cho AIVideo. Đối chiếu availability bằng SDK/toolchain thực tế khi triển khai; URL tài liệu không thay kết quả thử nghiệm.

- [S1 — Apple Human Interface Guidelines: Designing for macOS][S1]
- [S2 — Apple: Adopting Liquid Glass][S2]
- [S3 — Apple: Navigation và NavigationSplitView][S3]
- [S4 — Apple: Improving app responsiveness][S4]
- [S5 — Apple: AVAssetImageGenerator.maximumSize][S5]
- [S6 — Apple: NSTextInputClient.hasMarkedText()][S6]
- [S7 — Apple: Accessing files from the macOS App Sandbox][S7]
- [S8 — Apple: NSApplicationDelegate và vòng đời ứng dụng][S8]
- [S9 — Apple: NSWorkspace.didWakeNotification][S9]
- [S10 — Apple: Accessible appearance trong SwiftUI][S10]
- [S11 — Apple: Accessibility Inspector][S11]
- [S12 — Apple: Running code on a specific platform or OS version][S12]
- [S13 — W3C: Understanding SC 1.4.3, Contrast Minimum][S13]

[S1]: https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/
[S2]: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
[S3]: https://developer.apple.com/documentation/swiftui/navigation
[S4]: https://developer.apple.com/documentation/xcode/improving-app-responsiveness
[S5]: https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/maximumsize
[S6]: https://developer.apple.com/documentation/appkit/nstextinputclient/hasmarkedtext()
[S7]: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
[S8]: https://developer.apple.com/documentation/appkit/nsapplicationdelegate
[S9]: https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification
[S10]: https://developer.apple.com/documentation/swiftui/accessible-appearance
[S11]: https://developer.apple.com/documentation/accessibility/accessibility-inspector
[S12]: https://developer.apple.com/documentation/xcode/running-code-on-a-specific-version
[S13]: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html
