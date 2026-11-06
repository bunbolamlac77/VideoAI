# 08 — Hợp đồng chất lượng phân tích và kiểm chứng có thể kiểm toán

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả sẵn sàng để triển khai; chưa phải chứng nhận độ chính xác, độ ổn định hoặc khả năng chạy trên M1 Pro 16 GB.

Ưu tiên là hiểu đúng tư liệu và tạo câu chuyện dùng được. Người dùng cung cấp Dữ kiện ngày làm việc, xử lý câu hỏi có bằng chứng và duyệt sáng tạo; app vẫn có trách nhiệm phân tích toàn bộ nguồn đã chọn, không giao lại việc xem hết video cho người dùng.

Schema và decision table thuộc [02-ANALYSIS-AND-DATA.md](02-ANALYSIS-AND-DATA.md). Runtime/profile thuộc [03-MODELS-AND-RESOURCES.md](03-MODELS-AND-RESOURCES.md). Thuật toán tối ưu/impact thuộc [07-OPTIMIZATION.md](07-OPTIMIZATION.md). Requirement IDs, mục tiêu số và cách nghiệm thu thuộc [09-UPGRADES-AND-ACCEPTANCE.md](09-UPGRADES-AND-ACCEPTANCE.md).

## 1. Năm yêu cầu chất lượng độc lập

| Yêu cầu | Nghĩa trong sản phẩm | Một cách đạt giả cần ngăn |
|---|---|---|
| Đúng | Lời, chữ, hình và trình tự không khẳng định vượt nguồn được phép dùng | Có citation nhưng nguồn không hỗ trợ câu |
| Đủ | Không bỏ sự kiện quan trọng/cảnh đẹp chỉ vì im lặng, ngắn hoặc khó thấy | Chỉ phân tích clip có lời |
| Có ích | Phân tích giúp quyết định góc kể, shot và nhịp | Viết nhiều mô tả lặp nhưng không thêm quyết định |
| Biết giới hạn | Giữ uncertainty, conflict và phạm vi không thể biết | Chuyển unknown thành fact để workflow chạy tiếp |
| Lần lại được | Mỗi kết luận quan trọng mở được đúng snapshot/range/fact revision | Pointer còn tồn tại nhưng trỏ sang bytes đã thay |

Ba việc khác nhau: đã decode frame, đã đưa frame tới model và đã hiểu đúng nội dung. Không dùng hai việc đầu để chứng nhận việc thứ ba. Một approval ghi quyết định của người dùng, không phải bằng chứng mọi claim đều đúng.

## 2. Nguồn chuẩn trước khi phân tích

- Video/ảnh được acquire thành source snapshot có content revision theo tài liệu 05.
- Ưu tiên verified APFS clone khi được hỗ trợ, nếu không copy đầy đủ rồi seal; không coi hardlink là bất biến.
- Không phân tích/render trực tiếp một original có thể thay đổi rồi giả nó là cùng source revision.
- Hash/metadata lúc acquire phải nhất quán; phát hiện original đổi giữa chừng thì retry có phạm vi, không trộn metadata cũ với bytes mới.
- Originals của người dùng không bị sửa, di chuyển hoặc xóa.
- Relink tới bytes khác tạo source revision và impact review; không thay nội dung cũ âm thầm.
- Nguồn/bằng chứng còn được approvals hoặc backup tham chiếu phải được pin theo chính sách lưu trữ.

App-private snapshot không phải tuyên bố chống được người có toàn quyền sửa đĩa. Hash được kiểm ở các cổng dùng nguồn/final; phát hiện corruption thì chặn phụ thuộc và phục hồi đúng chính sách.

## 3. Baseline mọi frame vẫn bắt buộc

Mọi frame hợp lệ của mỗi video trong scope phải đi vào lượt xem chi tiết mặc định, theo cửa sổ nhỏ có timestamp, full-frame context và overlap. Ảnh tĩnh là asset độc lập cần được phân tích.

- Không thay baseline bằng sparse sampling, chỉ xem đoạn chuyển động, chỉ xem có speech hoặc chỉ xem thumbnail.
- Adaptive refinement bổ sung lượt soi sâu; nó không làm phần chưa xem trở thành đã xem.
- Không phải lưu mọi frame 4K ra SSD hoặc nạp cả clip vào RAM.
- Source được giải mã theo luồng; hàng đợi và buffer có giới hạn trong runtime profile.
- Giữ source snapshot, PTS index, observations, manifests và frame/crop bằng chứng; tái trích phần khác khi cần.
- Một crop nhỏ không đại diện cho full-frame context. Full-frame thu nhỏ cũng không chứng minh chữ nhỏ đã đọc được.
- `must_not_use` trong bản dựng không tự có nghĩa bỏ phân tích asset. Bỏ asset khỏi project là thao tác scope riêng, làm rõ ảnh hưởng.

Baseline là cam kết xử lý nguồn, không phải chứng minh cấu hình mọi-frame hiểu tốt nhất. Thay baseline cần nghiên cứu so sánh, mô tả trade-off, quyết định sản phẩm và chấp thuận phù hợp; không được tự thay trong lúc chạy project.

## 4. Sổ coverage và đơn vị đúng

Coverage ledger giữ riêng những loại bằng chứng sau; không gom thành một progress percentage “AI hiểu 100%”.

| Lớp | Đơn vị chuẩn | Điều chứng minh được |
|---|---|---|
| Kiểm kê/decode | Source revision, stream, frame ID, PTS/time base, vùng lỗi | Frame nào được decoder đọc hợp lệ |
| Input model | Frame ID sau processor, cửa sổ, transforms, tensor/token-group mapping | Frame nào thật sự tham gia input |
| Chuyên biệt | OCR/action/audio/crop jobs và range của chúng | Nhiệm vụ chuyên biệt nào đã chạy |
| Semantic assessment | Claim/evidence/evaluator/policy revision | Claim được đánh giá thế nào, không phải chân lý tuyệt đối |
| Omission audit | Scope/query manifest, checklist, findings | Vùng/giả thuyết nào được tìm lại |

Coverage frame là hợp các frame ID duy nhất, không là tổng frame của mọi batch. Overlap, temporal padding hoặc frame cuối bị lặp không được làm mẫu số/tử số phình ra.

Nếu decode chưa xác định đầy đủ frame ở một vùng, phải hiển thị vùng lỗi cùng độ bất định. Có thể báo coverage trên tập frame hợp lệ đã biết, nhưng không được dùng con số ấy để tuyên bố toàn source đã hoàn tất khi vẫn có vùng chưa kiểm kê.

## 5. Audit sau processor

Đường video mặc định của thư viện có thể lấy mẫu, giới hạn frame hoặc đổi kích thước. Adapter phải chứng minh input thực tế, không chỉ ghi danh sách dự định gửi.

1. Tạo manifest frame/range từ sealed source và profile đã khóa.
2. Ghi version/config của decoder, processor, tokenizer, template và backend.
3. Sau processor, ghi frame IDs còn hiện diện, kích thước full-frame/crop, thứ tự và transforms.
4. Ghi temporal patch/merge/padding với ánh xạ về từng frame nguồn; một patch không tự bằng một frame nguồn.
5. Kiểm số lượng/identity/range bị sampling hoặc truncate; thiếu frame thì chạy bù có phạm vi hoặc báo lỗi.
6. Không coi parser output lỗi/truncated là “không có sự kiện”. Giữ raw output và trạng thái cần xử lý.
7. Nếu không thể quan sát đủ mapping sau processor, capability all-frame chưa đạt cho backend đó.
8. Chỉ đánh dấu lượt chi tiết hoàn tất khi coverage và các lỗi thuộc scope đã được xử lý đúng hợp đồng.

Manifest có thể giữ hash và metadata thay vì toàn tensor lâu dài. Khả năng tái trích phải dựa trên snapshot được giữ, không dựa trên đường original có thể mất.

## 6. Fixture riêng cho coverage adapter

AI-01 cần kiểm những lỗi có thể tạo báo cáo đủ giả:

- Clip số frame chẵn/lẻ, padding theo temporal factor và batch cuối ngắn.
- Cửa sổ có overlap để bảo đảm frame trùng chỉ được đếm một lần.
- Processor cố tình lấy mẫu hoặc cap frame mặc dù caller truyền danh sách dài hơn.
- VFR với PTS không cách đều, rotation và frame index không thể suy từ fps trung bình.
- Một frame rất ngắn có dấu hiệu quan trọng ở đúng biên cửa sổ.
- Clip không có audio stream hoặc có audio nhưng không có speech.
- Decode hỏng giữa clip, file truncated và missing source snapshot.
- Resume sau crash không bỏ khoảng chưa xử lý hoặc ghi coverage của attempt stale.

Fixture tổng hợp có frame IDs/PTS đã biết giúp kiểm adapter, nhưng không thay thế POV thật để đo hiểu nội dung. Kiểm model có nhắc đến một số trên frame không phải cách duy nhất chứng minh frame đã vào tensor.

## 7. Quan sát đầu tiên không bị brief dẫn dắt

Lượt quan sát hình và ASR đầu tiên chỉ nhận dữ liệu cần cho nhiệm vụ, profile và ngữ cảnh media phù hợp; không nhận câu chuyện kỳ vọng trong brief.

- Dùng ID kỹ thuật khi có thể để tên file có ý nghĩa không trở thành gợi ý không được kiểm.
- Thông tin ngôn ngữ/profile ASR chung không được biến thành transcript mong muốn theo brief.
- Giữ output quan sát đầu tiên và metadata của lượt chạy bất biến.
- Sau đó mới đối chiếu brief đã xác nhận, dùng câu hỏi có mục tiêu hoặc từ điển tên riêng ở lượt có vai trò rõ.
- Lượt được brief hướng dẫn có provenance riêng; không ghi đè OCR mơ hồ thành tên địa điểm user đã nhập rồi gọi là quan sát độc lập.
- User fact có thể giúp hiểu cảnh nhưng không chứng minh rằng model đã tự nhìn ra điều đó.

Ví dụ: brief nói có biển “A”; ảnh chỉ đọc được vài nét. Kết quả hợp lệ là giữ chữ chưa rõ, source crop và thông tin reported. Kết quả không hợp lệ là sửa OCR thành “A” rồi dùng chính OCR ấy xác nhận brief.

## 8. Ngữ cảnh ba thang và hợp nhất

| Thang | Nhiệm vụ | Phải giữ |
|---|---|---|
| Frame/cửa sổ ngắn | Chữ nhỏ, bàn tay, hành động nhanh, cú bấm | Frame/range/crop, timestamp, ranh giới chưa chắc |
| Đoạn/clip | Diễn biến, trước/sau, lần hành động lặp | Event intervals, observations nguồn, hypotheses cạnh tranh |
| Workday/project | Chặng, callback, quan hệ xuyên source | Partial-order graph, scope, user facts và conflicts |

Cửa sổ nhỏ giải giới hạn bộ nhớ, không giải hoàn toàn ngữ cảnh. Cấp tổng hợp truy xuất lại evidence khi quyết định quan trọng; không chỉ đọc tóm tắt của tóm tắt.

Quy tắc hợp nhất observations tại tài liệu 07 giữ bản gốc và chỉ tạo liên kết event khi có căn cứ. Không ép hai động tác gần giống thành cùng một event; không dùng số lượt model đồng ý làm bằng chứng độc lập.

## 9. Các lượt chuyên biệt

1. **Hành động:** xem trước/sau, tách sự bắt đầu/kết thúc và phương án giải thích khác.
2. **OCR:** dùng source crop, tìm frame lân cận rõ hơn; giữ chuỗi chưa chắc. Không dùng upscale sinh chi tiết để xác nhận chữ.
3. **Người/vật:** track ID tạm để giữ liên tục; tên/vai trò do người dùng cung cấp có provenance riêng, không nhận diện danh tính từ khuôn mặt.
4. **Shot đẹp:** đánh giá hình độc lập với lời, giữ cảnh im lặng và ảnh tĩnh có giá trị.
5. **Ảnh/cú bấm:** đối chiếu candidates, clock uncertainty và chuỗi ngữ cảnh; exact-photo có gate riêng.
6. **ASR:** nhận lời và uncertainty; lời được nói không tự chứng minh nội dung kể đã xảy ra.
7. **Âm thanh hiện trường:** detector riêng sau benchmark; không gán click/còi bằng khả năng ASR giả định.
8. **Crop/alignment:** backend phải qua fixture trước khi tự động tạo quyết định làm mất thông tin hoặc đổi timing.

Khi một capability chưa đạt, giữ trạng thái đúng thực tế: illustrative, unknown, fit hoặc cần review theo đúng vai trò. Không lấy fallback làm cách giảm baseline mọi frame.

## 10. Dữ kiện người dùng và ba trục độc lập

Brief tự do được lưu nguyên văn thành revision, tách fact drafts, rồi người dùng sửa/xác nhận đúng nội dung, scope và revision. Lưu ghi chú không tự xác nhận fact.

- `origin` giữ ai/công cụ tạo thông tin.
- `epistemic_status` giữ observed/reported/inferred/unknown.
- `review_status` giữ trạng thái kiểm tra của đúng revision.
- `support_status` và `allowed_use` là đánh giá/decision có phiên bản, không thay thế ba trục trên.
- `narrative_type` thuộc lần dùng claim trong câu/beat; không ghi đè nguồn gốc claim.
- User-confirmed vẫn là reported. Nếu hình bổ sung chứng cứ, tạo observation/claim/link riêng.
- Facts về sự kiện, preference và ràng buộc “không dùng cảnh này” không bị gộp thành cùng loại dữ liệu.

Mức “khoảng”, “có lẽ”, phạm vi thời gian và timezone phải được giữ; không tự tạo phút chính xác hoặc một khoảng ± tùy tiện để form đủ ô. Workday qua nửa đêm không bị tự tách/gộp sai theo ngày file.

## 11. Từ claim tới quyền kể

Decision table chuẩn ở tài liệu 02 là nguồn duy nhất cho phép chuyển tổ hợp nguồn, support, review/confirmation, criticality và conflict thành `allowed_use`.

Pipeline bắt buộc:

1. Tách mệnh đề nguyên tử cùng quan hệ trước/sau/nguyên nhân/ý định.
2. Truy xuất evidence đúng scope và lưu query manifest.
3. Kiểm deterministic: schema, references, hashes, revisions, ranges và quyền dùng.
4. Kiểm semantic: evidence có hỗ trợ đúng mệnh đề, phạm vi và quan hệ không?
5. Tìm phản chứng hoặc giải thích thay thế phù hợp mức quan trọng.
6. Ghi support assessment, evaluator/policy revision và lý do.
7. Áp decision table; không để LLM tự gán approval hoặc lách gate bằng văn phong.
8. Khi câu/beat thay đổi, kiểm lại lần dùng claim và implications của hình–lời.

Một claim “được hỗ trợ” có nghĩa đáp ứng policy nguồn/cách kể, không là xác suất đúng tuyệt đối. Không hiển thị confidence_raw như phần trăm đúng khi chưa hiệu chuẩn trên tập độc lập.

## 12. Đánh giá verifier riêng

Verifier là một thành phần có thể sai. Cho generator và verifier cùng nhìn một mô tả sai có thể tạo đồng thuận giả; benchmark phải kiểm trực tiếp false acceptance.

Fixture AI-05 cần có:

- Pointer mở được nhưng chứa sự kiện khác.
- Câu nhiều mệnh đề chỉ có evidence cho một phần.
- Source xác nhận hành động nhưng không xác nhận nguyên nhân/ý định.
- Cùng địa điểm/trang phục ở hai buổi khác nhau.
- User fact đúng phạm vi nhưng bị đổi thành observed.
- Claim bị phủ định ở đoạn trước/sau crop đang trích.
- Text “phi nghĩa đen” mang tiền đề factual sai.
- J-cut/B-roll tạo hàm ý sai dù từng câu transcript riêng lẻ không sai.
- Claim không thể biết từ nguồn, cần trả insufficient/unknown thay vì chọn đáp án có vẻ hợp lý.

Đo generator và verifier riêng, cùng kết quả cuối sau review. Đổi model lớn hơn hoặc thêm model cùng họ chưa chứng minh verifier tốt hơn; cần giữ nguyên protocol so sánh và báo cáo lỗi tương quan.

## 13. Tìm bỏ sót và claim âm tính

Sau tổng hợp, quay lại source theo checklist: cảnh đẹp không lời, sự kiện ngắn, chữ, thao tác tay, ảnh/cú bấm, chi tiết hài, biên cửa sổ và vùng có lỗi/bất định.

- Mỗi audit có câu hỏi, scope/query manifest, nguồn đã xem và findings; không chỉ đọc lại báo cáo do model tự viết.
- Kiểm cả giả thuyết được ủng hộ và giả thuyết thay thế.
- “Không thấy ở vùng đã kiểm” không tự thành “không xảy ra trong chuyến đi”.
- Negative finding phải giữ scope; thêm source mới làm nó chờ revalidation khi có liên quan.
- Audit không thể chứng minh không bỏ sót gì chỉ vì checklist đã được tick.
- Hết cách thu thập bằng chứng mới thì dừng unknown/review; không nâng độ chắc vì đã chạy nhiều lần.

## 14. Review có mục tiêu

Một review item có một vấn đề chính, lý do cần hỏi, mức ảnh hưởng, bằng chứng đúng loại/revision và fact/claim revisions liên quan. Chỉ với media theo thời gian mới bắt buộc khoảng source và ngữ cảnh trước/sau trong phạm vi nguồn có sẵn. Với asset ảnh tĩnh, hiển thị đúng snapshot ảnh/crop và thông tin nguồn; với brief hoặc câu trả lời đã lưu, mở đúng revision/span hoặc resolution nguồn theo tài liệu 02. Câu trả lời lưu thành resolution đúng scope; fact mới tạo revision riêng.

Review chỉ có ảnh hoặc chỉ có brief là hợp lệ. Không tạo timecode giả hoặc gán clip minh họa thành bằng chứng cho thông tin ngoài camera; tư liệu chỉ gợi bối cảnh giữ vai trò `context_only`.

| Tình huống | Trình bày cho người dùng | Hành vi sau câu trả lời |
|---|---|---|
| Cần nguyên nhân ngoài camera | Hỏi ngắn, mở đoạn brief/câu trả lời nguồn hoặc media liên quan nếu có | User fact reported nếu được xác nhận; không thêm visual proof giả |
| Hai nguồn có vẻ mâu thuẫn | Hiện cả hai đúng loại/revision và uncertainty | Sửa/bác quan sát/giữ unknown/bỏ claim, giữ lịch sử |
| Chi tiết phụ không cần cho chuyện | Cho bỏ hoặc giữ chưa rõ | Loại claim phụ thuộc, không dừng toàn pipeline |
| Chi tiết cốt lõi chưa rõ | Nêu concept/beat bị ảnh hưởng | Chặn đúng nhánh hoặc chọn concept khác |
| Người dùng không biết | Chấp nhận câu trả lời | Không hỏi lại vô cớ, không biến thành đồng ý |

Không bắt xác nhận mọi frame hoặc mọi quan sát phụ. Nhóm facts được xác nhận hàng loạt phải được hiển thị đủ nội dung/phạm vi; không xác nhận mục ẩn. Lựa chọn script không thay cho review resolution hoặc fact confirmation.

## 15. Tránh chất lượng giả bằng từ chối mọi thứ

Độ đúng phải đi cùng mức sử dụng và tỷ lệ hoàn tất. Một hệ thống chỉ nói unknown không được gọi là tốt vì không có claim sai.

- Báo số claim được chấp nhận, bị sửa, bị loại và giữ unknown theo workday.
- Precision không có mẫu số phải ghi không xác định/chưa có dữ liệu; không gán 100% khi không chấp nhận claim nào.
- Recall sự kiện nhìn thấy được tách khỏi sự kiện ngoài camera chỉ có thể biết từ brief.
- Mức hoàn tất project ghi cả blocked_resource, blocked_review, source lỗi và capability thiếu; không loại các ca khó khỏi mẫu số âm thầm.
- Đo thời gian người dùng thật sự review, câu hỏi trùng, câu hỏi hữu ích và số lần phải sửa sự thật.
- Không đặt giới hạn số câu hỏi tùy tiện rồi bỏ lỗi trọng yếu để đạt UX đẹp.

## 16. Nhận bằng chứng mới mà không làm lại mọi thứ

Thêm clip/ảnh/brief tạo thay đổi evidence scope hoặc fact revision. Chính sách impact tại tài liệu 07 là bắt buộc:

- Giữ observations bất biến của nguồn cũ.
- Phân tích nguồn mới và xét lại assessments/queries/rankings nhạy với scope.
- Tìm claim có thể bị phản bác dù trước đây chưa có cạnh tới source mới.
- Chặn final phụ thuộc khi revalidation quan trọng chưa xong.
- Sau revalidation chỉ invalidate artifact thực sự bị ảnh hưởng; không xóa approvals không liên quan.
- Một user edit không được dùng làm ground truth cho mọi chuyến về sau.

Điều kiện “source mới chưa nằm trong manifest cũ” không phải lý do bỏ qua nó. Ngược lại, thêm asset ở scope độc lập không buộc quét lại mọi video của project khác.

## 17. Bốn cổng chất lượng và quyền duyệt

1. **Dữ kiện:** snapshot facts/conflicts/cách dùng đủ điều kiện; unresolved core chỉ chặn phần phụ thuộc.
2. **Kịch bản:** 1–3 phương án có evidence, TTS thật và cut khả thi; người dùng duyệt đúng revision.
3. **Preview:** QC kỹ thuật và nội dung, xem/nghe thực; người dùng duyệt đúng preview/edit-plan snapshot.
4. **Final:** render từ approved bytes/plan, kiểm chính file cuối và mọi approvals còn hiệu lực.

Đổi sự thật/cách kể sau duyệt quay lại cổng script. Đổi hình/âm/timing ảnh hưởng preview tạo preview mới. Đổi resolution/codec theo profile đã công bố vẫn đòi final QC; không tự đổi câu hoặc giọng trong bước render cuối.

## 18. Quality gate và hành vi lỗi

| Phát hiện | Hành vi bắt buộc |
|---|---|
| Frame bị bỏ sau processor | Job bù hoặc scoped failure; không gắn coverage đủ |
| Semantic claim chưa đủ hỗ trợ | Decision table → review/qualified use/exclude phù hợp |
| Candidate chỉ giống bề ngoài | Giữ candidate hoặc illustrative, không cấp exact tự động |
| Search chưa tìm ra cut | Giữ đúng status SEARCH-v1, không báo vô nghiệm giả |
| Crop/conform mất bằng chứng | Đổi phương án/fit hoặc chặn, không giữ claim như cũ |
| TTS làm đổi nội dung | Sửa/tái sinh revision, kiểm lại, duyệt đúng phạm vi |
| Input hoặc approval stale | Reject publish/final phụ thuộc, giữ lịch sử |
| RAM/SSD thiếu | Checkpoint/pause theo governor, không giảm coverage/model âm thầm |
| Source/artifact corruption | Chặn phụ thuộc, restore/rebuild theo policy và hash |
| Resolve managed drift | Bảo toàn manual edits, reconcile hoặc tạo nhánh mới |

Lỗi ở một nhánh không tự chặn mọi job. Cũng không cho job phụ thuộc vượt gate chỉ vì một nhánh khác đã xong.

## 19. Độ ổn định là điều kiện của chất lượng

Một phân tích đúng bị publish vào sai revision vẫn là lỗi sản phẩm. Vì vậy các invariant của tài liệu 05 nằm trong hợp đồng accuracy-first:

- Worker không ghi canonical DB hoặc cấp approval.
- Result có request/job/attempt/fencing identity và expected revisions.
- Hủy attempt revoke quyền publish trước khi thay; result đến muộn bị từ chối.
- Artifact phải qua PREPARED → MATERIALIZED → VERIFIED → COMMITTED; không trỏ DB sang bytes chưa xác minh.
- Crash/retry không ghi đè user facts, resolutions, approved WAV hoặc timeline thủ công.
- Snapshot/backup/restore giữ đủ manifest để chứng minh source và revision mà kết luận dựa vào.
- Hệ thống không báo done khi final còn finding chặn hoặc dependency còn pending revalidation.

Chi tiết giao dịch không được chuyển thành gánh nặng UI; người dùng cần thấy vấn đề, phạm vi và hành động tiếp tục rõ ràng.

## 20. Protocol dữ liệu và chống rò rỉ đánh giá

Tách development và held-out theo chuyến/ngày quay, không chia ngẫu nhiên frame cùng clip thành hai tập rồi gọi là độc lập.

- Dataset manifest ghi nguồn có quyền dùng, scope/workday, cấu hình nguồn và những ca khó.
- Nhãn phân biệt điều nhìn thấy, điều được kể và điều không thể suy ra.
- Người gán nhãn có hướng dẫn về event quan trọng, claim nguyên tử và lỗi quan hệ; bất đồng được lưu/giải quyết có quy trình.
- Model/prompt/profile được chốt trước held-out; có học từ lỗi held-out thì bộ đó trở thành dữ liệu phát triển.
- Báo denominator, phân nhóm khó, khoảng bất định và sự tương quan theo workday.
- Nhiều frame cùng clip không thay nhiều bối cảnh độc lập.
- Fixture nhỏ ban đầu giúp kiểm luồng; không chứng nhận chất lượng cho mọi tư liệu.

Cỡ mẫu và thresholds đề xuất v0.1 ở tài liệu 09 là mục tiêu kỹ thuật chưa đo. Không thay chúng sau khi biết kết quả để làm test đang thất bại thành đạt mà không có ADR và holdout mới.

## 21. Đánh giá sáng tạo và tiếng Việt

Chất đúng, chất voice và chất dựng phải được chấm riêng để biết vấn đề nằm ở đâu. Review mù trên cùng nguồn/script constraints giúp so lựa chọn model/prompt/cut có ý nghĩa hơn một điểm tự chấm của LLM.

- So góc kể, rõ ý, tự nhiên tiếng Việt, nhịp và mức phù hợp gu.
- Nghe phát âm số/tên, ngắt nghỉ và punchline trên WAV thật.
- Xem cả hình/âm/chữ sau render ở kích thước đọc thực tế.
- Ghi preference rõ ràng cùng chỉnh sửa có ngữ cảnh; không học quá mức từ một lần chọn.
- Không coi nhiều hiệu ứng, 4K hoặc nhiều kịch bản là bằng chứng video hay.
- Không hứa viral hoặc “hài hay nhất”; tư liệu nghèo có thể cần video ngắn hơn hoặc đổi trọng tâm.

## 22. Điều kiện dừng và công bố năng lực

Một lượt kiểm dừng khi có kết quả đủ điều kiện theo policy, không còn cách thu thập evidence mới có ích, hoặc chạm giới hạn vận hành được khai báo. Hai tình huống sau không tự trở thành pass.

- Không đạt chất lượng thì giữ unknown/review/blocked cùng phạm vi và lý do.
- Không đạt resource/capability thì báo hạn chế vận hành đúng loại, không giả model hiểu xong.
- Chỉ công bố profile E0/E1 hoặc capability đã vượt bộ kiểm tương ứng.
- Báo cáo phải gắn runtime/data/policy versions và các ca chưa đạt.
- Phần trăm chính xác, độ ổn định hoặc mức cải thiện chỉ được viết sau số đo; không suy từ độ dài tài liệu.

Nền tảng triển khai nằm ở [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md). Mục tiêu của v3.1 là làm mọi cam kết chất lượng trở thành yêu cầu có thể kiểm chứng, không tự tuyên bố sản phẩm đã đạt vì đặc tả đầy đủ hơn.
