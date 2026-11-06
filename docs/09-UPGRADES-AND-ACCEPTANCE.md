# 09 — Nâng cấp, hợp đồng đo và nghiệm thu

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả để triển khai; chưa có ca kiểm nào được tuyên bố đã chạy hoặc đã đạt.  
**Bộ mục tiêu:** `acceptance-targets-v0.1` — mục tiêu kỹ thuật đề xuất, cần khóa sau pilot phát triển và trước khi mở kết quả held-out. Đây không phải tỷ lệ chính xác đã đo.

Liên quan: [sản phẩm và E0/E1](01-PRODUCT.md), [schema và quyền dùng claim](02-ANALYSIS-AND-DATA.md), [model/tài nguyên](03-MODELS-AND-RESOURCES.md), [script/media/Resolve](04-SCRIPT-AND-EDIT.md), [kiến trúc/phục hồi](05-ARCHITECTURE-AND-ROADMAP.md), [thuật toán](07-OPTIMIZATION.md), [accuracy-first](08-ACCURACY-FIRST.md), [UI](10-UI-UX-MACOS.md), [triển khai từng bước](11-CODING-WORKFLOW-AND-CHECKLIST.md).

## 1. Quyền sở hữu và cách dùng

Tài liệu này sở hữu ID yêu cầu nghiệm thu, định nghĩa metric, mẫu số, mục tiêu số và cổng đạt/trượt. Tài liệu 02 sở hữu ngữ nghĩa dữ liệu; 05 sở hữu commit/recovery; 07 sở hữu tìm kiếm và dependency; 04 sở hữu profile media. Không sao chép một ngưỡng khác vào từng module rồi để chúng lệch nhau.

Mỗi test result phải mang: requirement ID, case ID, build commit, cấu hình/môi trường, fixture revision/hash, profile/model/runtime/prompt revision, dữ liệu đo, log/artifact liên quan và kết quả. Nhãn hợp lệ cho kết quả test là `NOT_RUN`, `PASS`, `FAIL`, `BLOCKED`, `NOT_APPLICABLE`; đây là trạng thái của báo cáo kiểm thử, không thay enum nghiệp vụ trong database.

`NOT_APPLICABLE` cần lý do và capability bị vô hiệu tương ứng. Không dùng nhãn này để bỏ qua các invariant lõi, giấu lỗi trên E0/E1 đã công bố hoặc cho qua một format vẫn xuất hiện trong danh sách hỗ trợ.

“Không có vi phạm trong bộ ca đã chạy” là một kết quả có phạm vi. Không diễn giải thành không thể lỗi trên mọi máy hoặc mọi tư liệu. Danh sách bên dưới là công việc cần làm, không phải biên bản đã nghiệm thu.

## 2. Các cổng phát triển

| Cổng | Phạm vi cần chứng minh | Nhóm ID chủ yếu | Bằng chứng bắt buộc |
|---|---|---|---|
| G0 — nền tảng | `.app` tối thiểu, worker đóng gói, quyền source, offline, model nhỏ và Resolve 10 giây | `RES-01`, `OFF-*`, `REL-01` | Build chạy trên máy mục tiêu; capability manifest; log môi trường/quyền/bytes thực |
| G1 — dữ liệu và phục hồi | Single writer, snapshot, publication, revisions, fencing, backup/migration | `INV-*`, `DATA-*`, `JOB-*` | Schema/IPC hợp lệ; fault injection; restore project sạch vào thư mục mới |
| G2 — phân tích/bằng chứng | Độ phủ frame, source independence, event/claim/review, phản chứng | `AI-01`–`AI-06`, `AI-09`, `DATA-05` | Corpus phát triển/held-out đã khóa; metric `analysis_eligible` cùng mẫu số và bất định |
| G3 — câu chuyện | 1–3 phương án khả thi, TTS thử, search đúng trạng thái, script approval | `STORY-*`, `AI-08`, `INV-03` | Script/shot/WAV manifest, fixture beam, review mù và thử duyệt sai revision |
| G4 — preview | Managed Resolve, voice/caption/crop/mix, QC, preview approval | `RES-*`, `MEDIA-*`, `UI-*` | Preview thật, kiểm nội dung, mapping, hash và tình huống sửa sau duyệt |
| G5 — final/phát hành | Final QC, restore/backup, offline, soak, phạm vi E0/E1 đã công bố và capability disclosure | `REL-*`, `OFF-*`, `DATA-06`, `MEDIA-08` | Final + `.drp`/backup mở lại, test report, ma trận hỗ trợ và hạn chế còn lại |

G0 không cần UI đẹp, nhưng phải dùng đường chạy của bản `.app` thật. Thành công từ terminal không thay phép thử worker, file access và runtime của bản đóng gói. G1 không chờ đến cuối dự án mới thử crash và restore.

Một capability bổ sung có thể ở trạng thái chưa đạt trong khi luồng cơ bản hoạt động. Khi đó phải tắt cách dùng phụ thuộc capability đó và nói đúng giới hạn. Ví dụ không đạt ghép ảnh chính xác thì ảnh chỉ dùng minh họa; không đánh dấu cổng `AI-07` đã hoàn tất.

### 2.1. Yêu cầu theo giai đoạn và capability

Không hiểu tên family trong bảng cổng là phải có mọi màn hình/renderer trước G2. Áp phép kiểm đúng artifact và năng lực hiện có; phần chưa đến giai đoạn giữ NOT_RUN, không coi nó là thiếu sót đã được miễn vĩnh viễn.

| Phạm vi | Bắt buộc ở thời điểm nào | Phần không được giả đã chứng minh |
|---|---|---|
| State/revision/invariant | G1 kiểm bằng harness và giao dịch thật; kiểm lại tích hợp ở các cổng sau | Harness không chứng nhận final media chưa dựng |
| Hiểu video, claim-use assessment, review | G2 với AI-01–AI-06/AI-09 trong profile core | Chưa chấm script_ready, final hoặc project completion |
| TTS lời đọc và duration cơ bản | AI-08 ở G3 với WAV thật; kiểm lại G4/G5 | Cảm xúc/giọng nâng cao hoặc SED chưa đạt phải tắt; không chặn G2 vì chưa có TTS |
| Ghép ảnh exact | AI-07 chỉ mở khi bộ kiểm riêng đạt; có thể sau pilot core | Chế độ illustrative đạt không đồng nghĩa exact đã đạt |
| Media/Resolve | G0 spike khả năng; G4 preview; G5 final profile thật | Clip 10 giây không chứng nhận mọi source/profile hoặc final quality |
| UI | Kiểm các màn đã nối ở từng cổng; toàn bộ các ca áp dụng cho bản phát hành ở G5 | Mock/screenshot và UI stress không chứng nhận AI/throughput |
| E0/E1 và completion | G5/end-to-end cho đúng envelope định công bố | E0 đạt không nâng thành E1; feature tắt không được quảng bá là có |

Capability tắt phải có test `REL-06` chứng minh UI/core không cho cách dùng chưa đạt, nhưng cổng năng lực đó vẫn được ghi chưa hoàn thành. Các invariant nguồn, dữ liệu và quyền duyệt luôn có hiệu lực trong mọi đường đã triển khai.

## 3. Corpus, nhãn và đóng băng phép thử

### 3.1. Phân chia dữ liệu

Bộ phát triển khởi đầu có khoảng 20 clip POV thật, ảnh, brief và nhãn từ ít nhất 3 workday. Đây là dữ liệu để sửa prompt, window, crop, processor, policy và tham số search. Nó không phải tập chứng minh tổng quát.

Bộ held-out khởi đầu có ít nhất 5 workday thuộc các chuyến/phiên sự kiện độc lập, ít nhất 100 cơ hội quyết định claim đã gán nhãn và ít nhất 50 sự kiện quan trọng quan sát được. Đây vẫn là bộ khởi đầu nhỏ; phải báo bất định và mở rộng trước khi đưa tuyên bố rộng.

Một chuyến dài được chia thành nhiều file hoặc nhiều workday không tự tạo nhiều mẫu độc lập. Group theo chuyến/sự kiện và nguồn gốc tư liệu; tất cả clip, ảnh, brief, gần trùng và phần tiếp nối của group phải cùng một split. Không đưa frame khác của cùng video sang held-out. Báo số workday và số group độc lập riêng.

“Cơ hội quyết định claim” là một mệnh đề nguyên tử có ngữ cảnh sử dụng cụ thể, nguồn có thể đối chiếu và nhãn hỗ trợ/không hỗ trợ; bao gồm claim có quan hệ trước/sau, nhân quả, danh xưng hoặc mốc giờ. Bộ cơ hội chuẩn kiểm tra quyết định dùng/từ chối. Metric precision còn phải chấm mọi claim thực tế app đưa ra ngoài bộ cơ hội đó; không bỏ claim mới hoặc claim sai do model tự sinh khỏi mẫu số.

### 3.2. Ma trận tình huống tối thiểu

- Ngày/đêm, rung, chuyển động nhanh, chữ nhỏ, cảnh yên và cảnh đẹp không lời.
- Không audio stream, audio im lặng, lời nhỏ/ồn, giọng có tên riêng/số và âm thanh không đủ nhận diện.
- H.265/MOV, VFR, rotation, HEIC và format thực sự định công bố; file lỗi được thử như ca lỗi riêng.
- Nhiều buổi/camera, đồng hồ lệch, quay lại cùng đường, tên file xáo trộn, ảnh giống nhưng khác buổi.
- Brief đúng, thiếu, sai, có phủ định hoặc “khoảng/có lẽ”; sự kiện ngoài camera; source đến muộn.
- Một chuyện đủ tư liệu, tư liệu nghèo, claim trọng yếu không thể giải quyết và ràng buộc khóa không thuận lợi.
- Project sát giới hạn E0/E1; không dùng project nhỏ để chứng nhận giới hạn 120 phút/100 asset.

Mỗi format/profile trong capability manifest cần fixture tương ứng. Fixture không có quyền sử dụng hoặc không thể giữ ổn định không được là nền của một báo cáo có thể tái chạy.

### 3.3. Gán nhãn và mức trọng yếu

Nhãn ghi rõ source revision, khoảng PTS, frame quyết định, nội dung được thấy/nghe và phần không thể kết luận. Fact ngoài camera được gán nhãn nguồn người dùng; không đưa vào mẫu số recall sự kiện nhìn thấy.

`critical` là claim/lỗi có thể thay đổi sự thật cốt lõi, nhân vật được quy kết, nguyên nhân, trình tự quan trọng, đúng/sai sự kiện hoặc ý nghĩa cảnh dùng làm bằng chứng. Danh sách critical được xác định trước khi xem đầu ra model. Lỗi thẩm mỹ phụ không tự thành critical; lỗi nguồn hoặc quan hệ có thể critical dù câu vẫn nghe tự nhiên.

Các claim critical và các trường hợp bất đồng cần hai lượt đánh giá độc lập rồi phân xử có lý do. Người chấm semantic không chỉ đọc lời tự giải thích của model. Với hình/audio, người chấm được xem source nguyên vẹn quanh đoạn liên quan. Lưu nhãn trước phân xử và lý do thống nhất để kiểm độ ổn định của nhãn.

Event recall chỉ tính các sự kiện đã đánh dấu quan trọng và quan sát được trước khi chạy. Một detection phải đúng hành động/chủ thể theo vai trò, workday và source; evidence phải chứa các frame quyết định. Theo policy khởi đầu, khoảng evidence không dài quá `max(2 × thời lượng sự kiện gán nhãn, 2 giây)`, trừ sự kiện được gán nhãn là cần context dài và có giới hạn ghi trước. Không trả cả clip như bằng chứng cho mọi event rồi tính là đã định vị đúng.

### 3.4. Đóng băng trước held-out

Khóa split/group, nhãn, criticality, rubric, target version và các cấu hình thuộc **giai đoạn đang đo** trước lượt held-out của giai đoạn đó. G2 khóa profile phân tích được chọn từ `P-VISION-DEV-v1`, model/runtime/processor/prompt và claim-use policy; G3 khóa thêm story/TTS, `SEARCH-v1` và beam/candidate budget; G4/G5 khóa cấu hình dựng/xuất `M-24-SDR-v1` cùng integration settings. Phần chưa triển khai ghi chưa đo, không làm G2 phải chờ search/renderer tương lai. Chỉ profile thắng trên development được vào lượt held-out chính.

Không chọn model tốt nhất bằng cách chạy nhiều ứng viên trên cùng held-out rồi chỉ báo điểm cao nhất. Nếu dùng kết quả held-out để điều chỉnh, tập đó trở thành dữ liệu phát triển; vòng xác nhận tiếp theo cần group độc lập mới, kể cả khi chuyển từ G2 sang G3/G5. Có thể giữ các bộ regression đã biết lỗi, nhưng không tiếp tục gọi chúng là dữ liệu chưa từng dùng để phát triển. Nếu báo nhiều checkpoint trên cùng group, không cộng chúng thành nhiều lần quan sát độc lập.

Một thay đổi ngưỡng cần quyết định thiết kế có lý do, version mới và phép thử mới phù hợp. Không nới tiêu chí sau khi biết một ca thất bại để đổi báo cáo thành đạt. Sửa nhãn sai cần audit và đánh giá lại toàn bộ phần chịu ảnh hưởng, không chỉ xóa các ví dụ bất lợi.

### 3.5. Mẫu số, khoảng bất định và tương quan

Mỗi metric báo tử số, mẫu số, số workday, số group độc lập, phân bố theo group và profile. Không lấy hàng trăm frame/claim từ một chuyến làm hàng trăm thử nghiệm độc lập.

Với tỷ lệ nhị phân, có thể báo Wilson 95% để mô tả dữ liệu đếm, nhưng phải ghi đây không phải cách sửa tương quan trong cùng chuyến. Báo thêm bootstrap theo **group chuyến/workday độc lập**: lấy lại toàn bộ group, giữ các claim/event trong group cùng nhau; dùng 10.000 lần lấy mẫu với seed lưu trong báo cáo. Không bootstrap từng frame như mẫu độc lập.

Khi chỉ có 5 group, khoảng ước lượng có thể rất không ổn định. Báo thêm metric từng group và min/max; không dùng một khoảng hẹp do xử lý sai tương quan để tuyên bố độ chính xác cao. Trường hợp 0 lỗi vẫn cần ghi số cơ hội xuất hiện lỗi và giới hạn phạm vi.

Các target v0.1 bên dưới áp cho ước lượng điểm trên suite đã khai báo, đồng thời bắt buộc báo bất định. Không giả rằng cận dưới 95% đã vượt target nếu chưa đủ mẫu. Không có mẫu số hoặc không có trường hợp dương tính cần thiết thì kết quả là chưa đủ bằng chứng, không phải 100%.

## 4. Hợp đồng metric và target v0.1

### 4.1. Hiểu đúng và kiểm chứng

| Metric ổn định | Tử số / mẫu số và đơn vị | Target v0.1 |
|---|---|---|
| `accepted_claim_support_precision` | Số claim được phép dùng có đầy đủ hỗ trợ đúng nguồn/cách kể / mọi claim app đưa ra như có thể dùng | ≥ 0,98 trên suite đã khóa; báo theo giai đoạn |
| `critical_false_accept_count` | Số claim critical không đủ hỗ trợ nhưng vẫn được phép dùng; đơn vị claim sử dụng | 0 trên mọi suite critical đã khai báo |
| `important_observable_event_recall` | Event quan trọng được tìm đúng theo quy tắc matching / mọi event quan trọng quan sát được đã gán nhãn | ≥ 0,90 |
| `verifier_false_accept_rate` | Claim biết là sai/thiếu hỗ trợ mà verifier cho dùng / mọi claim sai/thiếu hỗ trợ trong bộ thử verifier riêng | ≤ 0,02; riêng critical vẫn 0 false accept |
| `frame_input_coverage` | Số frame source hợp lệ duy nhất thực sự qua detailed processor / tổng frame hợp lệ phải xử lý trong scope | 1,00 cho scope báo đã phân tích đầy đủ; lỗi decode/bỏ frame báo riêng |
| `exact_photo_use_precision` | Lần dùng ảnh ở chế độ exact được nhãn độc lập xác nhận / mọi lần app chọn dùng exact | 1,00 trên suite ban đầu và 0 ghép exact sai; không suy thành bảo đảm tổng quát |

Claim được chấm theo checkpoint riêng: **G2 `analysis_eligible`** dùng harness đánh giá claim cùng ngữ cảnh cách kể theo decision table của tài liệu 02; **G3 `script_ready`** chấm mọi phương án trình chọn; **G5 `final`** chấm câu/hình/âm trên bản thực tế. Harness G2 không giả đã tạo được script hoặc video. Không trộn mẫu số/điểm giữa các stage, không chỉ chấm phương án tốt nhất hoặc bản đã được người dùng sửa hết lỗi. Báo riêng trước và sau thao tác review của người dùng. Thao tác xác nhận fact chuẩn trong fixture được ghi lại, không giả AI tự biết sự kiện ngoài camera.

Một câu nhiều mệnh đề phải tách thành claim và quan hệ. Phần factual ẩn trong lời hài vẫn được tính. Mệnh đề cùng nghĩa/ngữ cảnh lặp qua nhiều phương án trong một project được thống kê một đơn vị độc lập cho precision, đồng thời báo số lần dùng; không nhân bản câu đúng để tăng mẫu số. Thay nguồn, chronology, chủ thể hoặc cách kể tạo ngữ cảnh sử dụng khác cần chấm riêng.

Một claim “đúng theo lời người dùng” chỉ được tính hỗ trợ khi revision đã xác nhận, scope hợp lệ và cách kể giữ nguồn người dùng. Dùng cùng nội dung như thể camera chứng minh là sai về provenance. Liên kết tới một source chỉ hỗ trợ một nửa câu không được tính là hỗ trợ đầy đủ.

Bộ verifier riêng có ít nhất 50 claim sai/thiếu hỗ trợ, gồm ít nhất 20 critical, cộng một nhóm claim được hỗ trợ để đo việc từ chối nhầm. Bao gồm citation không liên quan, đảo trước/sau, nhân quả tưởng tượng, lời nói bị gán nhầm người và “user-confirmed” bị đổi thành “observed”. Không chỉ cho verifier kiểm lại chính báo cáo do nó vừa tạo.

Độ phủ frame tính trên danh tính source revision + chỉ số frame giải mã + PTS; PTS trùng nhau không làm hai frame thành một. Đếm frame sau processor, không đếm số đường dẫn đã gửi vào API. Nếu decoder không xác định được tổng hợp lệ vì file hỏng, ghi phạm vi không xác định và trạng thái partial/error; không loại ngầm phần khó khỏi mẫu số để báo 100%.

Gate ghép ảnh exact có dataset riêng khóa trước: ít nhất 50 cặp đúng, 50 ca âm/near-duplicate/khác buổi và ít nhất 5 group độc lập. Để bật năng lực, cần ít nhất 50 quyết định exact đã chấm trên tập kiểm cố định đã đủ lớn, không có false exact và báo precision/recall/từ chối cùng CI. Nếu số quyết định exact quá ít, giữ capability chưa đạt; không chọn thêm vài mẫu dễ sau khi thấy kết quả. Mỗi lần dùng exact thực tế vẫn phải qua support gate theo tài liệu 02.

### 4.2. Hoàn thành và từ chối

| Metric ổn định | Định nghĩa | Target/chính sách |
|---|---|---|
| `eligible_project_completion_rate` | Project đủ điều kiện có final đạt đúng pipeline / tất cả project đủ điều kiện đã cố định trước chạy | ≥ 0,80 |
| `project_abstention_rate` | Project đủ điều kiện mà app chủ động từ chối kể/xuất vì không có phương án đạt / cùng mẫu số project đủ điều kiện | Bắt buộc báo; không giấu để nâng precision |
| `blocked_project_rate` | Project đủ điều kiện còn blocked tại thời điểm chốt báo cáo / cùng mẫu số | Bắt buộc báo và phân loại nguyên nhân |
| `project_failure_rate` | Project đủ điều kiện lỗi không phục hồi được trong quy trình thử / cùng mẫu số | Bắt buộc báo; lỗi invariant chặn phát hành |

Eligibility được gán trước theo E0/E1, format đã công bố, setup và tài nguyên dự kiến đủ, source hợp lệ, và ít nhất một câu chuyện phù hợp có thể dựng theo nhãn độc lập. Không loại một project khỏi mẫu số chỉ vì AI không giải quyết được nó. Bộ tình huống thực sự thiếu chuyện vẫn được kiểm riêng về khả năng từ chối đúng, không ép thành video giả.

Tại thời điểm chốt đã định trước, mọi project đủ điều kiện thuộc đúng một trạng thái: completed, abstained, blocked, failed hoặc still_running. Báo đầy đủ các số; tổng bằng mẫu số. Thời gian chưa xong không phải pass, và timeout không làm một phân tích trở thành đúng. Cho chạy lâu là chính sách sản phẩm; phép thử vẫn phải có mốc báo cáo để không bỏ mất job chưa kết thúc.

Completed đòi final QC đạt, user approvals đúng snapshot, source scope không còn impact pending, backup/artifact cần thiết mở lại được và không bypass gate. File do người dùng tự hoàn thiện trên nhánh Resolve thủ công không được tính là app tự hoàn thành pipeline.

`eligible_project_completion_rate` và các tỷ lệ project cùng mẫu số chỉ chấm tại G5/end-to-end. Ở G2/G3 chưa có final thì ghi `NOT_RUN` cho metric này; không làm gate phân tích phụ thuộc vào một renderer chưa triển khai. G2 vẫn báo việc dùng/từ chối claim và event coverage theo đúng đơn vị của nó, không gọi chúng là project completion.

### 4.3. Media, đồng bộ và UI

| Metric/điều kiện | Cách đo | Target v0.1 |
|---|---|---|
| `cut_boundary_error_frames` | Frame thực đầu/cuối shot so với edit plan + CFR map đã khóa, trên fixture có frame ID | 0 frame |
| `av_sync_abs_error_ms` | Sai lệch tuyệt đối cue audio/visual được gán nhãn độc lập tại đầu/giữa/cuối sau decode final | Tối đa `1000/24` ms, khoảng 41,667 ms |
| `av_sync_drift_ms` | Trị tuyệt đối của sai lệch cuối trừ sai lệch đầu trên cùng fixture | ≤ `1000/24` ms |
| `caption_phrase_boundary_abs_error_ms` | Sai lệch boundary cụm từ so với marker của WAV cuối được gán nhãn; báo start/end | p95 ≤ 100 ms; max ≤ 200 ms |
| `caption_punchline_early_frame_count` | Frame mà chữ/ảnh tiết lộ punchline trước cue được duyệt | 0 ở beat yêu cầu giữ bất ngờ |
| Final hình và thời lượng | Decode + metadata/profile + presentation timestamps của mọi stream | 2160×3840; 24/1 fps; dưới 180 giây |
| Audio canonical | Kiểm WAV nguồn timeline và mapping samples | 48.000 Hz; voice 1×; media final theo profile đã khóa |
| `ui_light_action_latency_p95_ms` | Từ event tới phản hồi nhìn thấy của chọn hàng, focus, nhận pause dưới tải công bố | ≤ 100 ms |

Tại 24/1 fps, video dưới 180 giây có tối đa 4.319 frame. Điều này không thay kiểm duration thực của audio/container, priming/padding và timestamp sau export. Không cho audio dài hơn giới hạn hoặc lệch frame được đi qua chỉ vì số frame video đúng.

Đồng bộ A/V đo trên cue có thời gian chuẩn, không dùng sự đồng ý giữa hai ASR làm chuẩn. Mốc nguồn có offset chủ ý phải được khai báo trong fixture; không đổi offset sau khi thấy lỗi. Caption có pause/cue cố ý được so với cue đã duyệt, không bị tính như lệch lời. Caption timing đạt không thay kiểm thiếu/lặp từ hoặc đọc sai nghĩa.

100 ms là mục tiêu phản hồi thao tác nhẹ, không phải thời gian load toàn dự án, hoàn tất inference hoặc dừng worker. Báo số lần đo, tải, màn hình, power state, p50/p95/max và các thao tác chậm. Scroll/hitch kiểm bằng Instruments và trải nghiệm thực, không suy từ p95 của nút bấm.

### 4.4. Công sức người dùng

| Metric ổn định | Mẫu số/đơn vị |
|---|---|
| `active_review_minutes_per_project` | Phút thực thao tác brief/fact/review/script/preview; tách thời gian chờ máy và thời gian rời app |
| `duplicate_question_rate` | Câu hỏi lặp cùng vấn đề/phạm vi/revision không có bằng chứng mới / mọi câu hỏi đã trình |
| `useful_question_rate` | Câu hỏi được người chấm xác nhận làm rõ fact/cách dùng/nhánh kể quan trọng / mọi câu hỏi đã trình |

Giữ cả câu chưa trả lời, bị bỏ và trả lời chưa rõ trong log mẫu số. Câu “chưa rõ” có thể hữu ích nếu giúp loại một claim hoặc đổi cách kể đúng. Chưa đặt trần thời gian hoặc số câu hỏi theo phỏng đoán; dùng pilot thực để chọn target cho phiên bản sau, không đổi target trên held-out đã biết.

## 5. Invariant bắt buộc

Các invariant có mục tiêu **0 vi phạm trong toàn bộ ca bắt buộc đã khai báo**. Một vi phạm vẫn chặn cổng liên quan dù điểm AI hoặc thẩm mỹ cao.

| ID | Yêu cầu và phép kiểm đạt/trượt |
|---|---|
| `INV-01` | Original sources không bị app sửa/xóa/di chuyển. Hash và metadata theo phạm vi kiểm trước/sau; mọi phân tích/render dùng sealed source revisions được chỉ rõ. Bất kỳ ghi sai vào original là FAIL. |
| `INV-02` | Nguồn người dùng, quan sát, suy luận và âm/ảnh app sinh không bị đổi nguồn lẫn nhau. Fixture brief gây hiểu nhầm và caption tự khẳng định không được tạo observed fact. |
| `INV-03` | Xác nhận fact, chọn script, duyệt script, duyệt preview độc lập và đúng snapshot. Click lặp, stale revision, retry sau mất ACK không duyệt sai hoặc nhân đôi lệnh. |
| `INV-04` | Chỉnh tay và khóa cứng của người dùng không bị AI ghi đè. Kết quả cũ chỉ có thể thành đề xuất có nhãn hoặc bị từ chối; không âm thầm mở khóa. |
| `INV-05` | Done chỉ khi final đúng snapshot đã QC, approvals hợp lệ và không có revalidation/issue chặn liên quan. Job xong, hết retry hoặc người dùng bỏ qua lỗi không tự tạo done. |

## 6. Registry dữ liệu và runtime

| ID | Ca kiểm chính | Điều kiện đạt |
|---|---|---|
| `DATA-01` | Acquire clone/copy, original đổi trong lúc nhận, hết SSD, rút ổ, source mới cùng tên | Chỉ seal dữ liệu nhất quán đã kiểm hash; không hardlink; lỗi không âm thầm đổi sang direct-read; không dùng nội dung khác dưới revision cũ |
| `DATA-02` | Crash qua PREPARED → MATERIALIZED → VERIFIED → COMMITTED | COMMITTED chỉ tham chiếu bytes bất biến đã kiểm và tồn tại; orphan/pending/temp được đối chiếu; không công bố attempt cũ |
| `DATA-03` | Nhiều worker trả kết quả, hai cửa sổ, DB busy, mất ACK | ProjectStore là đường ghi canonical duy nhất; transaction ngắn; expected revision được kiểm; UI chỉ báo lưu sau ACK |
| `DATA-04` | Sửa fact/script/voice/crop; undo; approval cũ; tái render | Giữ lịch sử; invalidation đúng phụ thuộc; dùng approved bytes; không coi cùng seed là cùng artifact |
| `DATA-05` | Thêm source có phản chứng mà artifact cũ chưa có link tới nó | evidence scope/query manifest đổi; revalidation đúng phạm vi; final liên quan bị chặn trong lúc chưa rõ tác động; không cần quét lại mọi source cũ |
| `DATA-06` | Backup đang có sửa, checkpoint/portable restore, thiếu prerequisites | Snapshot nhất quán; pinned refs đủ; restore vào thư mục mới; integrity/FK/hash đạt; thiếu source/weights được báo đúng loại backup |
| `DATA-07` | Migration gián đoạn, disk full, app cũ mở schema mới | Có backup trước migration, journal/version rõ; không nửa schema; không downgrade ghi bừa; khôi phục được |
| `DATA-08` | Dọn cache, retention backup, artifact được approval tham chiếu, pin đến muộn sau GC check | Reservation/tombstone và pin được điều phối nguyên tử; không có pin mới hợp lệ trỏ tới file đã unlink; dọn cache không mất facts/reviews/approval/media đã duyệt |
| `JOB-01` | Attempt cũ trả kết quả sau cancel/retry/session mới | Fencing token và input revisions được kiểm tại publish; stale result không vào canonical state |
| `JOB-02` | Mất heartbeat nhưng worker còn sống; mở hai project; render + AI | Không cấp heavy lease mới khi process cũ chưa xác nhận kết thúc; chỉ một tác vụ nặng theo governor chung |
| `JOB-03` | Pause/cancel/resume khi đang decode/infer/materialize | Checkpoint hợp lệ; cancel thu hồi quyền publish; thu hồi process group/lease; không bỏ frame đã bắt buộc hoặc nhân đôi job |
| `JOB-04` | JSON-RPC sai version, JSONL quá giới hạn, stdout bị log lẫn, IPC mất phản hồi | Handshake/type/size validation; lỗi có mã và scope; bounded buffers; binary qua artifact refs được kiểm; không treo UI |
| `JOB-05` | RAM pressure, SSD thấp, Resolve còn chiếm bộ nhớ | Pause/checkpoint rõ; không tự đổi model/voice, giảm bằng chứng, xóa snapshot hoặc gọi cloud để vượt lỗi |

Tất cả test DB chạy đúng SQLite/runtime version đã khóa, WAL, foreign keys và chính sách durability đã công bố. WAL không được coi là giao dịch nguyên tử giữa DB, filesystem và Resolve. Test ghi lỗi phải bao gồm DB và artifact filesystem ở các mốc khác nhau.

## 7. Registry Resolve và bàn giao

| ID | Ca kiểm chính | Điều kiện đạt |
|---|---|---|
| `RES-01` | Bản `.app` tạo/import/render/export timeline 10 giây trên API thực | Query được capability/settings; frame bounds, codec, quyền worker và `.drp` mở lại đúng; unsupported capability chặn đúng phần |
| `RES-02` | Crash trước/sau append hoặc submit render, mất ACK, restart app | Intent journal có trước side effect; đối chiếu IDs/signature đã probe; chứng minh đã/chưa làm trước retry; không duplicate |
| `RES-03` | Sửa managed timeline bên ngoài; sửa manual handoff; tạo revision mới | Không ghi đè manual branch; drift managed chặn export; UI phân biệt rõ; không tự roundtrip chỉnh sửa vào core |
| `RES-04` | Managed timeline thay đổi trong khi render; effect readback không đủ | Kiểm trước/sau; kết quả không đúng snapshot bị từ chối. Không giả signature đã bao phủ hiệu ứng không quan sát được; dùng rebuild cô lập đã qua gate hoặc blocked |
| `RES-05` | Mở project/backup trên môi trường được khai báo và kiểm các lớp chỉnh sửa | Clip/audio/cut riêng; title native đúng khả năng; raster overlay có text/style nguồn và giới hạn rõ; không gọi file flatten là timeline chỉnh sâu |

“Không chứng minh được side effect đã xảy ra chưa” là trạng thái reconciling/blocked, không phải lý do chạy lại lệnh. Nếu phải rebuild, tạo managed revision/project/timeline cô lập từ input đã niêm phong; không xóa timeline người dùng vừa sửa.

## 8. Registry AI và câu chuyện

| ID | Ca kiểm chính | Điều kiện đạt |
|---|---|---|
| `AI-01` | Clip im lặng, không audio, sự kiện ngắn, ranh giới batch; processor bỏ frame | frame_input_coverage đúng mẫu số/log sau processor; thiếu frame bị phát hiện; không lấy audio làm điều kiện phân tích hình |
| `AI-02` | Brief gợi ý sai biển/động cơ; raw observation trước hypothesis review | Quan sát đầu không bị viết lại để khớp chuyện; raw evidence và nguồn brief riêng; review có cả hai khi cần |
| `AI-03` | Câu nhiều mệnh đề, fact ngoài camera, suy luận và quan hệ | accepted_claim_support_precision và critical_false_accept_count đạt target đúng stage; unknown không thành fact |
| `AI-04` | Important events đã gán nhãn, gồm cảnh không lời và các khoảng rất ngắn | important_observable_event_recall đạt, định vị đúng; báo bỏ sót và lý do theo group |
| `AI-05` | Bộ verifier độc lập có lỗi chủ ý | Đo false accept/false reject riêng; critical false accept bằng 0; hai model đồng ý không tự tăng confidence |
| `AI-06` | File xáo trộn, nhiều buổi, cùng đường, lệch đồng hồ, cạnh chronology có vòng | Không ghép sai chuyến; quan hệ có source/revision; phát hiện mâu thuẫn và giữ unknown nếu chưa giải được |
| `AI-07` | Cặp ảnh đúng/sai gần giống/khác buổi/lệch đồng hồ; detector không chắc | Gate exact riêng đạt mới bật; exact_candidate không tự thành exact; nếu thiếu chứng cứ dùng illustrative/none |
| `AI-08` | TTS thiếu/lặp từ, đọc sai số/tên, alignment và audio hiện trường | Lỗi đổi nghĩa được phát hiện hoặc chặn để review; dùng WAV thật; ASR không tự chứng nhận ngữ điệu hay detector âm thanh |
| `AI-09` | Người dùng trả lời chưa rõ, không muốn kể, thêm clip hoặc sửa fact | Review có scope và revision; chỉ chặn nhánh phụ thuộc; không hỏi lại vô ích hoặc dùng claim đã bỏ như chuyện thật |
| `STORY-01` | Outline/script dùng quan hệ không có bằng chứng hoặc lời hài có tiền đề sai | Hard constraints về sự thật/cách dùng được kiểm trước điểm hấp dẫn; claim sai không được điểm đẹp bù |
| `STORY-02` | Tư liệu chỉ đủ một chuyện; 1–3 bản trình chọn với TTS thử | Mỗi bản thực sự dựng được theo WAV/shot/time; không ép ba, không dựa số chữ để chứng nhận duration |
| `STORY-03` | `BEAM-PRUNING-v1`, `BEAM-FORWARD-v1`, `BEAM-UNSAT-v1` và so với exact checker trên miền nhỏ | Phân biệt pruning failure, tìm được nghiệm ngay và vô nghiệm có chứng minh; không buộc solver thất bại giả hoặc suy vô nghiệm từ beam hẹp |
| `STORY-04` | Hết beam/candidate budget, tập candidate thiếu, miền hữu hạn vô nghiệm | Phân biệt bốn trạng thái search; không gọi bottleneck phỏng đoán là xung đột đã chứng minh |
| `STORY-05` | must_use/must_not_use/preferred, sửa câu hoặc khóa sau duyệt | Giữ khóa cứng và revision; không tự sửa bản đã duyệt; preference chỉ xếp hạng trong tập hợp lệ |
| `STORY-06` | Review mù script/video và profile gu qua nhiều project | Tách đúng, rõ, góc kể, tiếng Việt, nhịp và dựng; không dùng điểm tự chấm LLM làm chứng nhận chất hài; profile reset/export được |

### 8.1. Ba fixture beam bắt buộc

Fixture có hai beat, cấm dùng lại cùng source range X; mỗi lựa chọn có thời lượng hợp lệ và evidence đầy đủ. Những ràng buộc khác giữ cố định để chỉ kiểm tìm kiếm.

| Beat | Candidate | Range dùng | Điểm mềm |
|---|---|---|---:|
| 1 | A | X | 9 |
| 1 | B | Y | 8 |
| 2 | C | X | 1 |

Điểm A > B và cấu hình từng ca phải được khóa để tái hiện đúng hành vi; đây là cấu hình fixture, không phải thay đổi profile phát hành. Giữ hard constraints khi kiểm option/chuyển tiếp, kể cả ở ca tắt forward check nhìn trước. Contract chi tiết thuộc mục 13 của tài liệu 07.

| Fixture | Cấu hình tái hiện | Điều kiện PASS |
|---|---|---|
| `BEAM-PRUNING-v1` | A/B/C, beam width 1; lượt đầu tắt forward check nhìn trước, repair/backtracking, tự mở rộng beam/candidates và exact checker | Trace ghi giữ A, bỏ B do beam rồi từ chối A → C vì lặp X; lượt đầu trả `SEARCH_BUDGET_EXHAUSTED`, không báo vô nghiệm/đòi mở khóa. Sau đó widen beam hoặc exact checker trên cùng miền/constraints tìm B → C, qua validator và trả `SOLUTION_FOUND` |
| `BEAM-FORWARD-v1` | Cùng A/B/C, beam width 1; bật forward check có căn cứ trước khi cắt beam | Forward check loại A vì beat 2 chỉ còn C dùng X, giữ B và tìm B → C. `SOLUTION_FOUND` ngay sau validator là PASS; không yêu cầu thất bại trước hoặc fallback không cần thiết |
| `BEAM-UNSAT-v1` | Miền chỉ A ở beat 1 và C ở beat 2, cấm lặp X; exact checker kiểm đầy đủ miền/constraints | Chỉ trả `PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN` với domain snapshot/hash, phiên bản checker và bằng chứng kiểm. Hết budget hoặc beam hết đường không là chứng minh; kết luận không áp sang A/B/C hay footage ngoài miền |

Evidence run phải lưu cấu hình, trace và kết quả riêng từng lượt/fixture. Ba ca trên là yêu cầu cần chạy, không phải kết quả đã đạt; không tự tuyên bố một danh sách pruning là tập xung đột tối thiểu.

`SOLUTION_FOUND` có edit plan được validator độc lập kiểm lại. `SEARCH_BUDGET_EXHAUSTED` nghĩa còn giới hạn tìm kiếm. `CANDIDATE_SET_EXHAUSTED` báo nguồn candidate hiện có không cho phương án, chưa chứng minh mọi cách tạo candidate đã được xét. Không tự tuyên bố tối ưu toàn cục hoặc tập xung đột nhỏ nhất.

### 8.2. Chấm sáng tạo và cá nhân hóa

So sánh mù trên source/brief cùng điều kiện, ẩn tên model và thứ tự A/B được đảo. Chấm riêng tính đúng, rõ câu chuyện, tiếng Việt, nhịp giọng, phù hợp hình/lời, readability và gu. Giữ cả lý do không chọn và chỉnh sửa cụ thể.

Đối với sản phẩm cá nhân, lựa chọn của chính người dùng là tín hiệu gu quan trọng nhưng không thay kiểm chứng source. Một lựa chọn không thành preference chắc chắn. Profile local cần xem/sửa/reset/export, project override và revision trong dependency fingerprint; không gửi dữ liệu ra mạng và không fine-tune weights trong MVP.

## 9. Registry media

| ID | Ca kiểm chính | Điều kiện đạt |
|---|---|---|
| `MEDIA-01` | VFR, PTS không đều/trùng, rotation, clip boundary, Resolve inclusive/exclusive | Internal [start,end), mapping nguồn/proxy/timeline được kiểm bằng frame ID; không nhân ms với fps trung bình; dropped/repeated frames có log |
| `MEDIA-02` | Preview/final export và file có metadata đúng nhưng stream sai | Kiểm decode; final 2160×3840, 24/1, dưới 180 giây kể cả stream thực; codec/profile đúng capability đã khóa |
| `MEDIA-03` | SDR, HDR metadata đúng/thiếu/mâu thuẫn, full/limited range | SDR Rec.709 theo M-24-SDR-v1; HDR chỉ qua pipeline đã kiểm; sai/thiếu tags không âm thầm convert; không tạo chi tiết giả làm evidence |
| `MEDIA-04` | Cue audio/visual ở đầu/giữa/cuối, clip VFR dài, xuất codec cuối | av_sync_abs_error_ms và drift đạt target sau decode; không chỉ so metadata |
| `MEDIA-05` | Chữ tiếng Việt, hai dòng, dấu, crop, punchline, cụm dài | Boundary/cue đạt; không cắt mất chữ; đọc được trên kích thước hiển thị thực; chữ bình luận tách khỏi lời thật |
| `MEDIA-06` | Crop mất biển/tay/người liên quan; ảnh minh họa sai nhãn; ảnh quá ngắn | Evidence critical vẫn nhìn được; dùng fit/layout phù hợp khi cần; người chấm hiểu đúng vai trò ảnh, không ép crop đẹp bằng mọi giá |
| `MEDIA-07` | WAV canonical, TTS lỗi, ducking, hiện trường, silence có chủ ý | 48 kHz; voice 1×; không thiếu/lặp từ đổi nghĩa; không clipping ngoài điều kiện nguồn được khai báo; im lặng có chủ ý không tự bị xóa |
| `MEDIA-08` | Regenerate TTS cùng seed, rerender codec/resolution, final khác preview | Approved WAV/graphics/edit plan được pin và dùng lại bytes; đổi nội dung/timing tạo revision; QC final thật; không tự kế thừa approval |

Không sử dụng optical flow hoặc nội suy sinh hình trong MVP. CFR map được version hóa, ghi rõ frame bị lặp/bỏ và kiểm việc mất một chi tiết quyết định. Một biển chỉ thấy trong frame bị bỏ không được coi là còn thấy trong final chỉ vì evidence nguồn tồn tại.

SFX/voice/caption do app tạo không được quay ngược vào source evidence. Âm thanh gây hiểu sai ai nói hoặc điều gì đã xảy ra là lỗi nội dung, không chỉ lỗi mix. Nhạc và asset phải có nguồn/quyền đã ghi trong manifest.

## 10. Registry UI macOS

Giữ nguyên ý nghĩa ID UI-01–UI-23 từ đặc tả trước; mở rộng ca theo snapshot và core v3.1. Mô tả layout/hành vi chi tiết ở tài liệu 10, nhưng điều kiện đạt chuẩn thuộc bảng này.

| ID | Ca kiểm | Điều kiện đạt |
|---|---|---|
| `UI-01` | 960×640, 1280×800, 1440×900 pt; resize, sidebar/inspector/full screen | Hành động cốt lõi truy cập được; không mất nội dung, selection, trạng thái lưu hoặc nút |
| `UI-02` | Sáng/Tối/Theo hệ thống; contrast, giảm motion/transparency | Chữ/focus/trạng thái rõ; appearance app không đổi video đã duyệt |
| `UI-03` | Cỡ chữ mặc định/125%/150%; nhãn dài | Không chồng/cắt nội dung quyết định; không tự ép chữ nhỏ |
| `UI-04` | Gõ tiếng Việt/emoji/paste dài trong lúc job cập nhật | Không mất dấu, nhảy caret, mất selection hoặc trộn undo với progress |
| `UI-05` | Bàn phím và VoiceOver qua luồng chính | Focus đúng; nguồn/câu hỏi/lỗi/approval đọc được; thao tác được mà không dùng chuột |
| `UI-06` | Lưu brief rồi trích fact | Fact còn nháp cho tới xác nhận đúng scope; nguồn brief không đổi |
| `UI-07` | Kết quả AI cũ về khi đang sửa | Không ghi đè sửa mới; nhãn revision và đề xuất đúng |
| `UI-08` | Xác nhận nhiều mục khi worker thêm mục | Chỉ xác nhận tập content/revision người dùng đã xem/chọn |
| `UI-09` | Sửa/duyệt sát nhau, double click, IPC retry | Không duyệt nhầm snapshot hoặc tạo command/job trùng |
| `UI-10` | Chọn script, duyệt script, duyệt preview | Ba hành động riêng; không ngầm xác nhận fact |
| `UI-11` | Sửa fact/lời/shot/crop/mix sau duyệt | Đúng artifact phụ thuộc cần xem lại; giữ lịch sử |
| `UI-12` | Review chỉ có brief, chọn chưa rõ/không kể | Không gán media giả làm chứng cứ; không đồng ý ngầm; nhánh độc lập tiếp tục |
| `UI-13` | Seek nhanh và đổi source/shot | Hình, audio, nhãn thời gian, source revision cùng đối tượng; kết quả cũ không lấn kết quả mới |
| `UI-14` | Fixture lớn và đổi preview ít nhất 50 vòng | Player/observer/tasks thu hồi; số tài nguyên sống có giới hạn, không tăng theo mỗi vòng |
| `UI-15` | Inference/render chạy; gõ/cuộn/nhận pause | Latency đạt mục tiêu đã công bố; UI main actor không làm việc nặng; pause hiển thị đúng giai đoạn |
| `UI-16` | Ổ đầy/mất quyền lúc autosave; Unicode | Không báo Đã lưu sai; giữ buffer và có cách khôi phục |
| `UI-17` | Cmd+W/Cmd+Q khi gõ/phân tích/render rồi mở lại | Draft đã commit đúng; job không trùng; worker không mồ côi |
| `UI-18` | Sleep/wake, rút ổ, Resolve đóng, worker crash | Phân biệt snapshot còn dùng được với source cần nhận lại; resume đúng và không duplicate |
| `UI-19` | Stale bookmark, source đổi cùng tên, snapshot hỏng | Kiểm identity/hash; không gán approval cũ cho content mới; hướng dẫn relink/restore đúng trường hợp |
| `UI-20` | Hai project hoặc mở lại project đang mở | Menu/selection/revision đúng cửa sổ; governor chung; không tạo hai writer cho cùng project |
| `UI-21` | Rút màn ngoài, đổi scale, restore cửa sổ | Cửa sổ và modal ở vùng thao tác được |
| `UI-22` | Render xong nhưng final QC fail | Chưa báo hoàn tất; finding có đoạn và hành động phù hợp |
| `UI-23` | Offline sau setup, thiếu artifact/runtime/preset | Không tự gọi cloud/tải ngầm; nói rõ phần thiếu và giữ công việc đã có |
| `UI-24` | Clone/copy snapshot, disk preflight, COW growth, thiếu chỗ | Hiển thị tiến trình/chi phí thật; không coi clone luôn 0 bytes; không âm thầm direct-read |
| `UI-25` | Managed timeline drift và tạo manual handoff | Người dùng hiểu nhánh nào app kiểm; sửa thủ công được giữ; không giả roundtrip hoặc final certified |
| `UI-26` | Chọn checkpoint/portable backup, restore, migration lỗi | Rõ prerequisites/phạm vi; restore vào nơi mới; bản app cũ không làm hỏng schema mới |
| `UI-27` | Thêm tư liệu đổi evidence scope; vượt E0/E1 | Impact pending rõ; chỉ chặn đúng phần; profile vượt giới hạn không bị gọi là AI lỗi chất lượng |
| `UI-28` | Người dùng thực hiện một workday mà không hướng dẫn trực tiếp | Đo active time/duplicates/usefulness; hiểu đúng nhãn nguồn, approval và manual branch; lỗi hiểu critical chặn nghiệm thu UX |

Fixture UI giữ một project thực và stress project có 1.000 asset, 300 facts, 100 review items, brief khoảng 30.000 ký tự, tên dài/Unicode và trạng thái lỗi/mâu thuẫn. Stress project kiểm UI và vòng đời bộ nhớ; không thay bộ benchmark AI hoặc mở rộng envelope.

Đo latency trên bản Release arm64 đóng gói, dưới tải inference/render đã ghi, ở máy mục tiêu và OS tối thiểu định công bố. Kiểm Instruments, Accessibility Inspector và VoiceOver thực tế. Bộ gõ cần thử trên các input methods có trong ma trận; không tự ghi đạt Telex/VNI khi chưa chạy.

## 11. Ma trận fault injection tại ranh giới commit

Mỗi dòng dưới là nhóm ca cần triển khai bằng fixture riêng, lưu trước/sau, process/attempt identity và mốc crash. Bắn lỗi một lần ngẫu nhiên không thay coverage các ranh giới có chủ đích.

| Vị trí gây lỗi | Trạng thái mong đợi sau mở lại/đối chiếu | ID |
|---|---|---|
| Trước khi intent PREPARED durable | Không có side effect được xem đã commit; không mất user state đã ACK | `DATA-02`, `INV-05` |
| Sau PREPARED, trước tạo temp | Nhận ra công việc pending; resume/cancel có quyền đúng attempt; không báo artifact tồn tại | `DATA-02`, `JOB-01` |
| Đang ghi temp; disk full hoặc worker bị kill | Temp không được tham chiếu như final; giữ source/DB; cleanup theo policy có kiểm | `DATA-01`, `DATA-02` |
| Sau MATERIALIZED (temp đã đóng), trước VERIFIED | Core kiểm manifest/hash temp rồi mới chứng nhận; file chưa được xem như artifact canonical | `DATA-02` |
| Sau VERIFIED, trước atomic rename | Journal đã có kết quả kiểm nhưng final path chưa được công bố; chỉ tiếp tục nếu quyền attempt/input còn hợp lệ | `DATA-02`, `DATA-04` |
| Sau rename vật lý, trước canonical COMMITTED; journal còn VERIFIED | Phát hiện bytes orphan theo manifest, kiểm hash/quyền attempt; không tự adopt output stale hoặc báo đã commit | `DATA-02`, `JOB-01` |
| DB commit xong, ACK về UI bị mất | Retry cùng logical command trả kết quả cũ; không tạo revision/approval thứ hai | `DATA-03`, `UI-09` |
| Worker cũ xong sau cancel và attempt mới | Token cũ không được publish; output cũ không ghi đè mới | `JOB-01`, `JOB-03` |
| Heartbeat im nhưng process nặng vẫn sống | Governor không cấp lease thứ hai; xác định/thu hồi process trước khi chạy tiếp | `JOB-02` |
| Core/UI bị kill khi đang nhập draft | Đã ACK thì còn; chưa ACK giữ đúng phạm vi cam kết và trạng thái trước crash; không giả đã lưu | `UI-16`, `UI-17` |
| User state thay đổi trong lúc backup | DB snapshot, manifest và pinned artifacts cùng một revision boundary; restore không pha hai thời điểm | `DATA-06` |
| Migration lỗi trước/sau transaction boundary | Không còn nửa schema; journal cho biết tiến độ; backup trước migration mở được | `DATA-07` |
| Cache GC chạy cùng backup/approval; pin tới sau eligibility check nhưng trước unlink | Reservation/tombstone làm pin bị từ chối/retry hoặc pin hợp lệ ngăn delete; không có canonical ref mới trỏ vào bytes đã xóa | `DATA-08` |
| Resolve intent chưa durable | Adapter chưa gọi mutation; không có thao tác ngoài journal | `RES-02` |
| Append thành công nhưng process chết trước ACK | Readback IDs/signatures chứng minh effect hoặc blocked; không append lại mù | `RES-02` |
| Submit render xong nhưng mất render job ID/ACK | Đối chiếu job/timeline/profile; chưa chứng minh được thì reconciling/blocked | `RES-02`, `RES-04` |
| Sửa managed timeline trong lúc render | Output không được công bố như snapshot đã duyệt; giữ sửa tay và đưa hướng xử lý | `RES-03`, `RES-04` |
| API không đọc lại được hiệu ứng cần xác thực | Capability gate hoặc rebuild cô lập có kiểm; không giả fingerprint bao trùm mọi hiệu ứng | `RES-01`, `RES-04` |
| Nguồn gốc đổi/rút ổ khi đang acquire | Từ chối snapshot chưa nhất quán; không seal nửa file; retry có source revision đúng | `DATA-01` |
| Nguồn gốc bị dời sau khi snapshot đã seal | Job dùng snapshot khỏe tiếp tục; relink original không thay content đã duyệt | `DATA-01`, `UI-18` |
| Sealed bytes mất hoặc hash khác | Đánh dấu corruption; chặn dependents; restore hoặc rebuild theo approval policy | `DATA-02`, `DATA-06` |
| Source mới đến sau approval nhưng trước final publish | Đối chiếu corpus revision; final phụ thuộc impact chưa rõ không thành done | `DATA-05`, `INV-05` |
| Final render đúng metadata nhưng sai cut/chữ/âm | Final gate fail; finding đúng đoạn; không xóa chứng cứ lỗi rồi báo đạt | `MEDIA-02`, `MEDIA-08` |

Thử `kill -9` chứng minh một phần recovery khi tiến trình chết, không tự chứng minh chịu mọi kiểu cắt điện hoặc hỏng phần cứng. Báo riêng các điều kiện durability filesystem/flush/rename đã kiểm trên APFS hỗ trợ. Nếu không chứng minh được điều kiện bắt buộc cho publish bền vững thì cổng tương ứng chưa đạt; không dùng lời hứa tuyệt đối thay chứng cứ.

Kiểm fault injection trên bản sao fixture cô lập. Không cần làm hỏng tư liệu người dùng thật để thử. Mỗi lần thử phải đối chiếu invariant user state, approval, manifest, frame mapping và số side effect; chỉ “app mở lại không crash” chưa đủ.

## 12. Nghiệm thu tích hợp sáu nâng cấp

### 12.1. Ghép ảnh với khoảnh khắc bấm máy

Candidate bằng embedding/local features và thời gian chỉ là bước tìm kiếm. Kiểm ảnh khác góc, gần giống, khác buổi và đồng hồ lệch. `exact_candidate` không tự cấp `use_mode=exact`. Gate `AI-07` và support decision của mỗi use cùng phải đạt; nếu chưa đạt, dùng illustrative/none với lời kể không khẳng định đó là đúng cú bấm.

Người dùng có thể xác nhận quan hệ từ ký ức, nhưng nguồn vẫn là người dùng. Không yêu cầu ảnh khác góc giống pixel, không bắt buộc có click audio và không dùng chữ trong caption do app sinh làm chứng cứ ghép ảnh.

### 12.2. Event graph xuyên source

Kiểm chronology bộ phận, cùng địa điểm chưa chắc cùng sự kiện, quan hệ nhân quả và source khác ngày. Mỗi cạnh có evidence/revision; loop trước/sau không bị âm thầm bỏ nguồn bất tiện. Source mới làm đổi scope phải được revalidate trước final liên quan, kể cả graph cũ chưa tham chiếu source mới.

### 12.3. Tìm bỏ sót và phản chứng

Audit phải quay lại nguồn, xem ngắn/dài/crop và ranh giới batch; không chỉ đọc lại summary. Đo event recall và claim precision riêng, cùng số lượt thêm thực sự mang bằng chứng mới. Không cộng confidence vì hai model cùng họ đồng ý hoặc cùng model lặp lại kết luận.

### 12.4. Học gu local

Preference không được sửa sự thật, mở khóa, đổi nguồn hoặc đi qua cổng duyệt. Một lần chọn script không chứng minh người dùng thích mọi chi tiết. Thử lưu qua restart, reset/export, project override, revision impact và khả năng không học từ một hành động xác nhận fact.

### 12.5. QC thành phẩm đối chiếu nguồn

Fixture cố ý gồm hình sai lời, thiếu media, crop mất bằng chứng, chữ sai thời điểm, im lặng đúng chủ ý và lỗi chỉ xuất hiện ở final. QC deterministic và semantic có báo cáo riêng. Tự sửa hữu hạn, có revision và chạy lại checks chịu ảnh hưởng; hết retry chưa đạt thì blocked.

### 12.6. Nhịp hài

Timing dùng WAV cuối, pause/cut/ảnh/SFX/chữ có cue. Kiểm không lộ punchline sớm, không thêm SFX mọi từ, ảnh đủ để hiểu và tiếng Việt đủ dấu. Các beat có thể không hài; không buộc mọi project có twist. Review mù về nhịp và chất kể bổ sung cho metric kỹ thuật, không thay cho kiểm sự thật.

## 13. Các tình huống xuyên hệ thống bắt buộc

| Tình huống | Kết quả đủ để PASS | Liên kết |
|---|---|---|
| Lưu brief “khoảng 3 giờ”, AI parse xong | Fact còn nháp, giữ độ ước lượng; xác nhận đúng revision mới cấp cách dùng | `INV-02`, `UI-06` |
| Brief gợi sai nội dung biển mờ | Raw observation không bị sửa cho khớp; có uncertainty và review đúng phạm vi | `AI-02`, `AI-03` |
| Dữ kiện critical mâu thuẫn video | Giữ cả nguồn; hỏi/bỏ claim/đổi concept; chỉ chặn phần liên quan | `AI-09`, `STORY-01` |
| Người dùng bỏ một chi tiết phụ | Không còn tiền đề đó trong lời thường hoặc lời đùa; nhánh khác tiếp tục | `AI-09`, `INV-05` |
| Thêm clip phản chứng sau script approval | Scope pending; kiểm tác động, stale đúng artifact khi cần; không giữ approval bằng lý do “file mới chưa có link” | `DATA-05` |
| Thêm ảnh không ảnh hưởng câu chuyện đã duyệt | Revalidation ghi kết quả không tác động; giữ approval hợp lệ, không làm lại mọi source | `DATA-05`, `UI-27` |
| Sửa một câu sau approval | Kiểm ngữ nghĩa/evidence; WAV/caption/cut/mix phụ thuộc cập nhật; bản cũ không cấp phép bản mới | `DATA-04`, `MEDIA-08` |
| TTS cùng seed sinh bytes khác | Artifact mới; không dùng kết quả đó như approved WAV cũ | `MEDIA-08` |
| `BEAM-PRUNING-v1`: beam width 1 bỏ B ở lượt cô lập | Báo `SEARCH_BUDGET_EXHAUSTED`; widen/exact trên cùng miền tìm B → C, không đòi mở khóa | `STORY-03` |
| `BEAM-FORWARD-v1`: forward check loại A và tìm B → C ngay | `SOLUTION_FOUND` qua validator là PASS, không ép thất bại giả | `STORY-03` |
| `BEAM-UNSAT-v1`: miền chỉ A/C, cấm lặp X | Chỉ exact checker đầy đủ mới cho chứng minh vô nghiệm trong miền đã khai báo | `STORY-03` |
| Người dùng sửa manual handoff trong Resolve | Chỉnh sửa được giữ; managed branch không tự thay; UI nói rõ không roundtrip | `RES-03`, `UI-25` |
| SQLite đã ACK nhưng app chết ngay | User state còn đúng khi mở lại; không double command | `DATA-03`, `UI-17` |
| Restore checkpoint thiếu source snapshot | Không gọi bản sao đầy đủ; trình đúng prerequisites; không nối file trùng tên để lấp thiếu | `DATA-06`, `UI-26` |
| Restore portable đầy đủ | DB/FK/hash và `.drp` hợp lệ trên môi trường đã công bố; có thể tiếp tục đúng revision | `DATA-06`, `RES-05` |
| Format/giới hạn ngoài profile phát hành | Phát hiện trước lượt nặng; nêu profile chưa hỗ trợ và lựa chọn cụ thể | `REL-01`, `UI-27` |
| Mất mạng sau setup | Không phát sinh tải/fallback cloud; kết quả và lỗi tương đương đường local được khai báo | `OFF-01`, `OFF-02` |
| Ổ đầy trong render hoặc backup | Không mất source/notes/approvals đã commit; không báo final/backup thành công sai | `DATA-02`, `DATA-06`, `JOB-05` |

## 14. Offline, phát hành và bằng chứng

| ID | Ca kiểm/cổng | Điều kiện đạt |
|---|---|---|
| `OFF-01` | Ngắt mạng sau setup trong toàn pipeline | Không gọi AI cloud, không tải ngầm; log/kiểm soát kết nối xác nhận đúng phạm vi; không giả completed khi thiếu artifact |
| `OFF-02` | Thiếu model graph/tokenizer/phonemizer/font/preset, checksum sai | Báo dependency cụ thể, phase setup riêng; giữ công việc; không đổi model/voice ngầm |
| `OFF-03` | Mở `.app` ngoài terminal, môi trường sạch theo ma trận | Không phụ thuộc PATH/venv ngẫu nhiên của shell; quyền helper/runtime đúng; có hướng dẫn cài và lỗi actionable |
| `REL-01` | Công bố E0/E1 và ma trận OS/SDK/Resolve/codec | Chỉ phạm vi đã chạy và đạt được đánh dấu hỗ trợ; fixture UI không thay envelope pipeline |
| `REL-02` | Completion/abstention/blocked/failure trên held-out | Tất cả project giữ trong mẫu số; completion đạt target; không dùng từ chối để giấu khó |
| `REL-03` | Hồ sơ phát hành và không còn blocker đã biết trong phạm vi | Có build, config, test/metric/CI, log, artifact và hạn chế; không còn vi phạm invariant hoặc lỗi chặn luồng chính |
| `REL-04` | Stress, UI soak và phiên chạy dài nhất được hỗ trợ | Tối thiểu 2 giờ vòng đầu, mở rộng tới lượt dài nhất; báo memory pressure/RAM/hang/recovery, không tăng tài nguyên vô hạn |
| `REL-05` | Usability workday thật và accessibility | Người dùng thực hiện luồng chính; lỗi hiểu nguồn/approval critical được xử lý; có số đo active time/questions |
| `REL-06` | Mở/tắt sáu capability và khả năng fallback đã công bố | Chưa đạt thì không giả đã có; fallback giữ đúng nguồn/phạm vi; cổng chưa hoàn thành vẫn để mở |

Không chọn minimum macOS bằng suy đoán. Ma trận cần máy, OS, Xcode/Swift/SDK, arm64, SQLite, Python/runtime, Resolve/API, model/processor và profile actual. Nâng dependency cần regression theo phần ảnh hưởng; không tự cập nhật `main` rồi giữ nguyên kết quả nghiệm thu.

Soak 2 giờ là khởi đầu của vòng nghiệm thu UI, không chứng minh một pipeline chạy lâu hơn sẽ ổn. Phiên đại diện phải bao gồm phân tích, biên tập, review, preview và ít nhất các đường phục hồi đã khai báo. Ghi xu hướng bộ nhớ sau mỗi vòng; cache có quota có thể tăng tới mức giới hạn rồi ổn định, không bắt mọi số RAM trở về đúng một byte ban đầu.

Lỗi chặn gồm mất dữ liệu đã commit, ghi sai trạng thái lưu, duyệt nhầm revision, source mutation/identity sai, duplicate Resolve, sử dụng claim critical sai, source mapping sai, final không đúng snapshot, crash/treo cản luồng chính và không tiếp cận được thao tác bắt buộc.

### 14.1. Mẫu bản ghi — minh họa, chưa phải kết quả

```json
{
  "example_not_test_result": true,
  "requirement_id": "AI-03",
  "case_id": "heldout-claims-profile-e0",
  "target_version": "acceptance-targets-v0.1",
  "metric": "accepted_claim_support_precision",
  "checkpoint": "script_ready",
  "build_commit": null,
  "fixture_manifest_hash": null,
  "independent_group_count": null,
  "numerator": null,
  "denominator": null,
  "observed_value": null,
  "interval_method": "group-bootstrap-and-descriptive-wilson",
  "interval_95": null,
  "target": {"operator": ">=", "value": 0.98},
  "result": "NOT_RUN",
  "evidence_refs": []
}
```

Báo cáo cuối cần có cả các ca không chạy được, format bị loại, capability chưa đạt và giới hạn statistical. Không để `null` thành số 0 hoặc hiểu danh sách evidence rỗng là đã kiểm mà không thấy lỗi.

### 14.2. Checklist cổng phát hành

- [ ] G0–G5 có bằng chứng theo phạm vi phiên bản định phát hành.
- [ ] Không còn invariant/blocker thất bại trong ma trận bắt buộc.
- [ ] Model/quality metrics có mẫu số, split theo group và khoảng bất định.
- [ ] E0/E1, format và runtime được hỗ trợ khớp capability manifest.
- [ ] Manual Resolve branch, source snapshots và kiểu backup được giải thích đúng.
- [ ] Final thực và project/backup đã mở lại, kiểm hash/revision/phụ thuộc.
- [ ] Bản `.app` Release đã chạy offline, bộ gõ, VoiceOver, sleep/wake và recovery.
- [ ] Tính năng chưa đạt vẫn tắt/ghi hạn chế; không đánh dấu xong vì có tài liệu hoặc tên module.

Cách công bố sau khi có chứng cứ: **“Đã vượt các ca nghiệm thu được liệt kê trên cấu hình và phạm vi dữ liệu được công bố; không còn lỗi chặn đã biết trong phạm vi đó.”** Không dùng “không lỗi trên mọi MacBook” hoặc “AI chính xác 99%” từ pilot nhỏ.

## 15. Nguồn nền tảng và phạm vi các con số

Các target, envelope và fixture trong tài liệu là quyết định kỹ thuật của AIVideo, chưa phải kết quả đo và không phải thông số Apple/SQLite bảo đảm cho ứng dụng này.

- [Apple — Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness): cơ sở giữ công việc nặng khỏi main thread và đo responsiveness trên thiết bị.
- [Apple — Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox): quyền file, bookmark và chia sẻ quyền giữa process khi dùng sandbox.
- [SQLite — WAL](https://www.sqlite.org/wal.html): đặc tính WAL cần xét theo runtime được khóa; không thay protocol artifact/Resolve.
- [SQLite — Online Backup API](https://www.sqlite.org/backup.html): cơ sở backup database nhất quán; tính đầy đủ của backup media/artifact vẫn là trách nhiệm ứng dụng.
