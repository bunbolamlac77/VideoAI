# 07 — Thuật toán chất lượng, tìm cut có ràng buộc và vô hiệu hóa đúng phụ thuộc

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả sẵn sàng để triển khai; thuật toán và profile vẫn phải được benchmark, chưa có số đo tối ưu đã đạt.

Tài liệu này sở hữu `SEARCH-v1`, quy tắc ưu tiên tính toán, cache theo phụ thuộc và quyết định invalidation. Schema/claim policy theo [02-ANALYSIS-AND-DATA.md](02-ANALYSIS-AND-DATA.md); baseline phân tích theo [08-ACCURACY-FIRST.md](08-ACCURACY-FIRST.md); media profile theo [04-SCRIPT-AND-EDIT.md](04-SCRIPT-AND-EDIT.md). Cơ chế commit/fencing/recovery thuộc [05-ARCHITECTURE-AND-ROADMAP.md](05-ARCHITECTURE-AND-ROADMAP.md).

## 1. Ba bài toán phải tách

1. **Phân tích:** điều gì nhìn/nghe được, điều gì người dùng kể, điều gì chỉ suy luận hoặc chưa biết?
2. **Kể chuyện:** góc kể nào hữu ích và hấp dẫn trong tập khẳng định được phép sử dụng?
3. **Dựng:** tổ hợp shot/voice/chữ/âm thanh nào hiện thực hóa bản đã duyệt mà không làm sai nghĩa?

Điểm đẹp/hài không bù được claim sai. Có nhiều lượt model hơn không chứng minh hiểu tốt hơn. Chỉ giữ một tối ưu nếu nó cải thiện nhiệm vụ đo được và không phá hợp đồng bằng chứng, dữ liệu hoặc approval.

## 2. Baseline mọi frame và tối ưu hợp lệ

Mọi frame hợp lệ của source snapshot phải đi vào lượt chi tiết qua adapter có audit sau processor. Quét nhẹ, phát hiện cảnh/chuyển động và lấy mẫu thích ứng chỉ thêm thông tin, không thay baseline.

- Frame được decode, frame vào model và sự kiện được hiểu đúng là ba loại số đo khác nhau.
- Cửa sổ nhỏ có overlap để vừa RAM và bảo vệ biên; coverage dùng hợp frame ID duy nhất.
- Cấp frame/crop giữ chi tiết; cấp đoạn giữ hành động; cấp clip/workday giữ quan hệ dài hạn có evidence.
- Không để tổng quan hoặc brief áp đặt câu chuyện cho lượt quan sát hình/ASR đầu tiên.
- Context giữa batch gồm source ranges và observations có provenance, không chỉ một bản tóm tắt ngày càng ngắn.
- Cấu hình cửa sổ/pixel/token theo profile đã khóa ở tài liệu 03; không tự đổi để làm benchmark đẹp hơn.
- Clip im lặng/không audio vẫn có cùng nhánh thị giác và cơ hội vào danh mục shot.

## 3. Hợp nhất observations qua cửa sổ

Không gộp hai câu chỉ vì embedding hoặc chữ giống nhau. Bản ghi quan sát gốc luôn được giữ bất biến, còn event tổng hợp có revision và liên kết về các quan sát đó.

1. Tạo nhóm ứng viên theo source revision, vùng thời gian có liên quan và loại hành động/đối tượng.
2. Dùng overlap của khoảng có bất định, liên tục thị giác và ngữ cảnh trước/sau để đề xuất cùng event.
3. Kiểm sự khác nhau về chủ thể, lượt hành động, hướng chuyển động và session; cùng cảnh có thể chứa nhiều lần hành động giống nhau.
4. Hợp nhất chỉ khi policy đã chọn hỗ trợ; giữ phần ranh giới chưa chắc và mọi evidence quan trọng.
5. Nếu chưa đủ căn cứ, giữ hai event candidates với quan hệ chưa xác định, không ép một event cho gọn.
6. Các mô tả trái nhau trở thành conflict/alternative hypotheses; không lấy đa số câu trả lời để xóa thiểu số.
7. Đo cả lỗi trùng event và lỗi gộp hai event thật thành một trên fixture biên cửa sổ.

Ngưỡng temporal overlap/similarity là tham số development profile, phải khóa trước held-out. Similarity chỉ tạo ứng viên, không là bằng chứng hai sự kiện giống nhau về sự thật.

## 4. Phân tích theo giả thuyết và phản chứng

Mỗi claim quan trọng có câu hỏi kiểm chứng, source hỗ trợ, vùng đã tìm phản chứng và kết quả support theo tài liệu 02.

| Giả thuyết | Bằng chứng cần tìm | Điều chưa đủ |
|---|---|---|
| Đã lên phà | Chuỗi lên/xuống hoặc vị trí liên tục phù hợp | Chỉ thấy mặt nước |
| Đúng địa điểm X | Chữ đọc được, metadata có căn cứ hoặc user fact đúng phạm vi | Cảnh giống một địa điểm quen |
| Ảnh thuộc cú bấm này | Liên hệ sự kiện, thời gian có uncertainty, hình học/ngữ cảnh | Cùng trang phục hoặc tiếng click riêng lẻ |
| A gây ra B | Nguồn cho chính quan hệ nguyên nhân hoặc lời kể được xác nhận | Chỉ biết A xảy ra trước B |

Lượt soi lại có thể đổi crop, độ phân giải, vùng trước/sau, câu hỏi hoặc model đã qua cổng. Lặp câu hỏi với cùng nguồn không tự tăng confidence. Khi không có cách lấy thêm bằng chứng hữu ích, giữ unknown/review thay vì lặp vô hạn.

## 5. Ưu tiên compute và câu hỏi

Ưu tiên được tính từ tác động tới câu chuyện, mức chưa rõ, khả năng có bằng chứng mới và số artifact phụ thuộc. Đây là thứ tự xử lý, không là xác suất đúng.

- Claim cốt lõi có nguy cơ sai được ưu tiên trước chi tiết trang trí.
- Biên cửa sổ, chữ nhỏ, hành động ngắn và bằng chứng có thể phủ định concept được kiểm thêm.
- Mỗi lượt bổ sung ghi mục đích, vùng nguồn, phép kiểm và kết quả mới; không tạo văn bản lặp để trông có vẻ kỹ.
- Review gom vấn đề thật sự chung một nguyên nhân; không gộp những facts khác phạm vi chỉ để giảm số câu hỏi.
- “Không biết” đóng lượt hỏi đó nhưng không nâng support. Chỉ hỏi lại khi có evidence mới hoặc người dùng yêu cầu.
- Một issue chỉ chặn phần phụ thuộc; source analysis và các phương án không dùng claim đó tiếp tục.

Ngân sách số lượt là hữu hạn và có version. Hết ngân sách là lý do dừng kiểm tra, không là lý do ghi claim đạt. Không áp timeout ngắn để bỏ source bắt buộc.

## 6. Event graph và ghép ảnh có miền rõ

Chronology là thứ tự bộ phận. Graph phân biệt `before`, `overlaps`, `continues`, ứng viên cùng session và quan hệ nhân quả theo schema chung. Narrative order của bản dựng không ghi ngược thành chronology nguồn.

1. Metadata và embedding tạo top-k ứng viên trong scope đã khai báo.
2. Đo candidate recall; không giả ứng viên đầu tiên là đúng.
3. Đối chiếu thời gian/clock offset có uncertainty, chủ thể, bố cục và local feature matching khi có ý nghĩa.
4. Geometric verification thất bại ở hai góc nhìn khác không tự chứng minh khác sự kiện; giữ kết quả phù hợp mức evidence.
5. Kiểm nhiều buổi cùng địa điểm, quay lại con đường cũ, burst nhiều ảnh và đồng hồ trôi theo phiên.
6. Phát hiện chu trình quan hệ trước/sau; giữ cạnh và nguồn xung đột để review, không âm thầm xóa cạnh bất lợi.
7. Exact-photo chỉ dùng sau AI-07 và đánh giá support; khi chưa đạt thì illustrative hoặc none.

Không ép ghép ảnh một-một. Track ID là định danh kỹ thuật tạm, không là nhận diện danh tính thật. Xác nhận của người dùng có thể bổ sung quan hệ theo nguồn reported nhưng không đổi loại bằng chứng thị giác.

## 7. Danh mục shot và chống lặp

Mỗi shot lưu vector chất lượng: nét, sáng, bố cục, ổn định, chuyển động có chủ ý, giá trị câu chuyện, thông tin cần nhìn và khả năng crop. Shot rung nhưng có sự kiện quan trọng có thể cần dùng hơn cảnh đẹp vô nghĩa.

- Perceptual hash/embedding tạo nhóm gần trùng để xếp hạng, không xóa source.
- Không phạt clip chỉ vì không có lời.
- Phân biệt lặp vô ích với intentional callback đã có trong storyboard.
- MMR có thể cân bằng liên quan/đa dạng sau khi ứng viên vượt ràng buộc sự thật.
- Đánh giá khả năng crop theo thông tin cần giữ, không chỉ vị trí một bounding box khuôn mặt.
- Mọi lựa chọn cuối phải truy về source snapshot và mapping được kiểm, không chỉ thumbnail.

## 8. Phương án kịch bản và TTS trước search

Sinh nhiều outline, loại trùng/thiếu chứng cứ rồi phát triển tối đa ba script có góc kể khác nhau. Không tìm cách kéo nguồn cho đủ ba hoặc đủ 90 giây.

Trước khi đưa script ra chọn:

1. Chạy voice thử đúng profile, giữ tốc độ 1×.
2. Kiểm lời và đo audio thật; lưu WAV revision/hash.
3. Chia beat theo câu/cụm/pause đã đo, xác định cue và thời gian phải giữ.
4. Tạo tập phương án shot cho mỗi beat, gồm head/tail, crop và vai trò minh họa/chứng minh.
5. Chạy `SEARCH-v1`, sau đó validator độc lập trên lời giải.
6. Chỉ gắn nhãn dựng được khi đã có cut hợp lệ; trạng thái search chưa giải quyết phải hiện đúng bản chất.

Ranking LLM chỉ hỗ trợ chọn phương án. Model/prompt được chọn bằng đánh giá trên chuyến giữ lại và review mù, không bởi model tự chấm mình “rất hài”.

## 9. Miền tìm kiếm hữu hạn của `SEARCH-v1`

Trong một lần search, thứ tự beat và nội dung script revision cố định. Search không được tự sửa sự thật, rút lời hoặc thay voice đã duyệt.

Miền đầu vào gồm:

- Script/beat revisions, lịch voice/pause và các constraints của người dùng.
- Tập hữu hạn `candidate_option_ids` cho từng beat; một option có thể gồm nhiều shot.
- Source ranges đã được validate, CFR map, crop plan và số frame thực theo `M-24-SDR-v1`.
- Các quan hệ chronology/continuity đã đủ điều kiện dùng.
- Thời lượng tối đa và phần thời gian của transitions/overlap đã mô hình hóa theo track.
- Scoring profile, beam width, thứ tự thử, giới hạn mở rộng và chính sách fallback.
- Hash snapshot của toàn miền ứng viên và phiên bản evaluator/policy.

Không gọi một search trên top-k ứng viên là tối ưu trên toàn bộ video. Một claim vô nghiệm chỉ có thể nói về miền cụ thể đã được kiểm chứng.

## 10. Trạng thái, chuyển tiếp và ràng buộc cứng

Trạng thái logic:

```text
(beat_index, timeline_frame, last_option,
 used_source_ranges, covered_required_beats, continuity_state)
```

- `used_source_ranges` được biểu diễn bằng định danh range/interval index có version, không chỉ ID file.
- `continuity_state` giữ thông tin cần để đánh giá chuyển tiếp; không nén mất điều kiện có thể đổi tính hợp lệ của bước sau.
- Với script cố định, beat bắt buộc không được bỏ qua. Beat tùy chọn chỉ được bỏ nếu storyboard/constraints đã cho phép.
- Trạng thái chứa lịch sử dùng source có thể tăng nhanh; không tuyên bố DP có độ phức tạp nhỏ chỉ vì timeline ngắn.

Mỗi chuyển tiếp chỉ thêm một option vượt toàn bộ kiểm tra cứng:

1. Evidence/allowed-use còn hiệu lực và scope revalidation liên quan đã hoàn tất.
2. Source/hash/range/mapping tồn tại và đủ frame/head-tail.
3. Crop/conform giữ thông tin cần chứng minh.
4. Không vi phạm must-use/must-not-use, quy tắc lặp hoặc chronology đã quy định.
5. Không làm sai gán âm thanh/lời nói cho người hay sự kiện.
6. Timing voice/caption/cue và trần duration còn khả thi.

Forward checks có thể loại nhánh chắc chắn không đủ thời gian hoặc không còn option cho beat bắt buộc. Chỉ dùng lower bound thật; heuristic score không được giả làm bằng chứng vô nghiệm.

## 11. Điểm mềm và lưu giải thích

Trong tập hợp lệ, điểm gồm khớp ý, dễ quan sát thông tin, chất lượng hình, nhịp, transition và đa dạng. Mỗi thành phần có đơn vị/normalization, trọng số và policy revision.

- Không cộng “độ đúng” vào điểm để bù với cảnh đẹp: đạt điều kiện đúng là bước lọc trước.
- Chuẩn hóa theo beat/độ dài để không ưu tiên máy móc phương án có nhiều shot chỉ vì cộng nhiều điểm.
- Giá trị chưa đo có cờ thiếu dữ liệu; không mặc định confidence cao hoặc điểm hoàn hảo.
- Trọng số và beam width được chọn trên development set rồi khóa.
- Lưu score components, constraints bị vi phạm và lý do pruning để giải thích kết quả.
- User preference chỉ ảnh hưởng điểm trong tập hợp lệ; không override sự thật hoặc gate.

Với `L` beat, beam width `B`, tối đa `C` option/beat và chi phí check `K`, phần mở rộng điển hình có cỡ `O(L × B × C × K)` cho một lượt beam. Chi phí tạo ứng viên, range history, retrieval và semantic evaluation phải được đo riêng; biểu thức này không bảo đảm tổng pipeline rẻ hoặc tối ưu toàn cục.

## 12. Bốn trạng thái kết thúc bắt buộc

| Trạng thái | Ý nghĩa được phép nói | Điều không được suy ra |
|---|---|---|
| `SOLUTION_FOUND` | Có ít nhất một lời giải vượt hard constraints trong miền đã khai báo | Đã tìm tối ưu toàn cục hoặc video chắc chắn hay |
| `SEARCH_BUDGET_EXHAUSTED` | Chưa tìm được lời giải trong giới hạn beam/mở rộng/thời gian hợp lệ | Người dùng phải bỏ khóa hoặc bài toán vô nghiệm |
| `CANDIDATE_SET_EXHAUSTED` | Bộ tạo ứng viên hiện tại không còn phương án để thử theo policy, chưa có chứng minh đầy đủ | Không có footage nào có thể hỗ trợ câu chuyện |
| `PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN` | Exact checker đã chứng minh không có nghiệm trong đúng snapshot miền hữu hạn | Mọi ứng viên tiềm năng ngoài miền hoặc mọi script khác đều vô nghiệm |

Nếu beam từng loại trạng thái và sau đó hết đường, mặc định là `SEARCH_BUDGET_EXHAUSTED`, trừ khi exact checker độc lập đã có chứng minh. Không đổi sang “vô nghiệm” chỉ vì danh sách beam hiện rỗng.

`CANDIDATE_SET_EXHAUSTED` dùng khi truy xuất/mở rộng không còn tạo được option hợp lệ theo miền/policy hiện hành; báo rõ phạm vi đã tìm và những vùng chưa được thử. Nó không thay thế chứng minh tính không thể.

## 13. Ba fixture bắt buộc cho STORY-03

Hai beat dùng hai source ranges X và Y, với ràng buộc không lặp X. Mỗi option có thời lượng/evidence hợp lệ; các ràng buộc khác giữ cố định để cô lập hành vi tìm kiếm:

| Beat | Option | Range | Điểm minh họa |
|---|---|---|---:|
| 1 | A | X | 9 |
| 1 | B | Y | 8 |
| 2 | C | X | 1 |

Điểm A > B được khóa trong fixture, không phải scoring chuẩn đã đo. Mỗi ca lưu domain snapshot, cấu hình search và trace; phân biệt nhánh bị loại do ràng buộc với nhánh bị bỏ do giới hạn beam. Các cấu hình cô lập dưới đây không thay profile phát hành và không tắt kiểm tra hard constraints của option/chuyển tiếp thực được dùng.

### 13.1. `BEAM-PRUNING-v1` — Tái hiện mất nghiệm do beam hẹp

Lượt đầu dùng beam width 1; tắt forward check nhìn trước các beat sau, repair/backtracking, tự mở rộng beam/candidates và exact checker. Trace phải chứng minh A được giữ, B bị bỏ vì giới hạn beam, rồi A → C bị loại do lặp X. Lượt này trả `SEARCH_BUDGET_EXHAUSTED`, không báo vô nghiệm và không yêu cầu người dùng bỏ khóa.

Sau khi ghi kết quả lượt đầu, chạy lượt phục hồi với cùng miền ứng viên/constraints: mở rộng beam đủ giữ A và B hoặc dùng exact checker miền nhỏ. Lượt phục hồi phải tìm được B → C, qua validator độc lập và trả `SOLUTION_FOUND`.

### 13.2. `BEAM-FORWARD-v1` — Forward check tìm được nghiệm ngay

Dùng cùng A/B/C và beam width 1, bật forward check có căn cứ trước khi cắt beam: A khiến beat 2 không còn option hợp lệ vì C cũng dùng X, nên loại A theo constraint và giữ B. Khi B → C vượt validator, `SOLUTION_FOUND` ngay ở lượt đầu là PASS; không bắt tạo `SEARCH_BUDGET_EXHAUSTED` hoặc chạy fallback để giả lập thất bại.

### 13.3. `BEAM-UNSAT-v1` — Chứng minh vô nghiệm trong miền đã khai báo

Miền chỉ còn A ở beat 1 và C ở beat 2, vẫn cấm lặp X. Chỉ khi exact checker đã kiểm đầy đủ miền hữu hạn và constraints mới được trả `PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN`, kèm hash miền, phiên bản checker và bằng chứng kiểm. Checker hết budget hoặc beam hết đường không đủ cho kết luận này. Kết luận không áp sang miền A/B/C hay footage ngoài miền; danh sách lý do pruning không tự là “tập xung đột tối thiểu”.

## 14. Thứ tự phục hồi khi chưa tìm được cut

1. Kiểm output parser, candidate validity, timeline mapping và constraints có bị đọc sai không.
2. Chạy forward checks có chứng cứ và giữ thông tin branch đã bị prune.
3. Tăng beam theo những mức hữu hạn trong profile, không tăng vô hạn.
4. Mở rộng candidate retrieval theo query manifest; giữ cùng facts/constraints, tạo domain revision mới.
5. Với miền nhỏ trong giới hạn profile, chạy enumeration/solver chính xác để kiểm khả thi.
6. Solver hết ngân sách hoặc không encode đầy đủ constraints thì không được phát chứng nhận vô nghiệm.
7. Nếu vẫn chưa có nghiệm, báo trung thực trạng thái và bottleneck nghi ngờ; cho người dùng chọn thêm tư liệu, đổi beat/rút lời hoặc mở khóa có chủ đích.
8. Thay script/khóa tạo revision mới, invalidate đúng phần phụ thuộc và duyệt lại; không tự sửa bản đã duyệt.

Exact checker có thể dùng enumeration cho fixture nhỏ; nếu dùng constraint solver, phải lưu solver/version, miền đã encode và kết quả có thể kiểm. Chỉ khẳng định minimal conflict core khi đã chạy phép kiểm tối thiểu tương ứng; MVP không cần lời hứa đó.

## 15. Post-validation độc lập với search score

Lời giải được chọn phải đi qua validator không chỉ đọc tổng điểm do search trả về:

- Mở lại source hashes và media maps của những shot được dùng.
- Kiểm từng hard constraint trên edit plan cuối, gồm overlap track và duration thật.
- Kiểm các frame/crop bằng chứng quan trọng vẫn có mặt sau conform.
- Đối chiếu WAV/cue/voice revision với script được phép dùng.
- Kiểm provenance và scope-sensitive assessments còn hiệu lực.
- Xuất feasibility report có status, domain, constraints và danh sách checks.

Validator kỹ thuật không tự chứng minh ngữ nghĩa. Semantic evaluator và user approval giữ vai trò riêng; xem AI-05 và STORY-/MEDIA- trong tài liệu 09.

## 16. Cache theo nội dung và truy vấn bằng chứng

Cache key tối thiểu gồm source snapshot/hash, PTS/mapping, model/processor/runtime, prompt/policy, config, schema version và fingerprint đầu vào. Kết quả truy vấn/tổng hợp còn phụ thuộc `evidence_scope_revision_id` và `query_manifest_id`.

- Per-source observations bất biến có thể tái sử dụng khi thêm asset mới.
- Retrieval/ranking/negative findings phụ thuộc tập nguồn đã tìm, không chỉ những source cuối cùng được trích dẫn.
- Một câu “không tìm thấy ảnh phù hợp” cần scope/query manifest; thêm ảnh mới làm kết luận đó phải xét lại.
- Output có cùng cache key nhưng file thiếu/hash sai không được dùng.
- Artifact đã duyệt không phải cache có thể tùy ý tái sinh; giữ bytes đã được pin.

## 17. Clip mới và dependencies chưa từng có cạnh

DAG cũ không thể tự có cạnh tới một clip chưa tồn tại. Vì vậy mở rộng tập bằng chứng là một loại dependency riêng.

1. Source mới được acquire/seal và tạo source revision qua core.
2. Tăng evidence-scope revision của workday/phạm vi liên quan.
3. Đánh dấu assessment, graph relation, retrieval/ranking và concept nhạy với scope là chờ revalidation.
4. Phân tích asset mới; giữ observations của asset cũ, không quét lại mọi frame chỉ vì có clip mới.
5. Dùng reverse retrieval theo claim/event/time/session để tìm những kết luận có thể bị hỗ trợ hoặc phản bác.
6. Trường hợp query broad/negative/chronology không thu hẹp an toàn được phải revalidate toàn scope liên quan.
7. So kết quả mới với snapshot cũ; nếu no-impact, ghi impact decision có phạm vi/query/evidence để gỡ pending, giữ nguyên identity và snapshot approval cũ. Không sửa fingerprint cũ để làm như người dùng đã duyệt corpus mới. Nếu dependencies thực sự hoặc nội dung được dùng đổi, tạo revision và làm stale đúng artifact/approval dẫn xuất.
8. Trong lúc impact chưa giải quyết, chặn final phụ thuộc scope ấy; các job độc lập vẫn chạy.

Không “giữ approval vì clip mới chưa nằm trong dependency list”. Ngược lại, cũng không làm mọi project cũ stale khi thêm một asset ở workday hoàn toàn không liên quan.

Impact decision là bằng chứng revalidation bổ sung, không là một approval mới do AI tự cấp. Final gate kiểm cả approval gốc và chuỗi quyết định no-impact còn hợp lệ; khi có phản chứng mới, quyết định no-impact trước đó cũng phải được xét lại theo scope của nó.

## 18. Ma trận invalidation chuẩn

| Thay đổi | Phần phải xét lại | Phần có thể giữ |
|---|---|---|
| Brief/fact đổi nghĩa hoặc mức chắc chắn | Claims/support/conflicts, concept/script và dẫn xuất dùng fact | Quan sát source bất biến không phụ thuộc brief |
| Review resolution đổi | Allowed-use/assessment và artifact theo scope của resolution | Quyết định không liên quan |
| Thêm source/ảnh | Scope-sensitive retrieval/graph/omission/story ranking | Per-source observations cũ hợp lệ |
| Relink tới bytes khác | Source revision mới, mapping/evidence/artifact dùng source | Source revision cũ còn được pin |
| Sửa voice text | Claim/meaning, TTS, alignment, beat/cut/caption/mix/QC | Source analysis độc lập |
| Đổi voice/preset/phát âm | WAV, speech check, duration và mọi timing/cue dẫn xuất | Script wording nếu nghĩa không đổi |
| Đổi shot/crop | Evidence visibility, chronology, edit/preview/final/QC | Facts không phụ thuộc quyết định dựng |
| Đổi nhạc/style/font | Mix/layout/graphics/preview/final và duyệt tương ứng | Claim gốc nếu cách kể không đổi |
| Đổi model/processor/prompt | Lượt phân tích/synthesis bị ảnh hưởng và dẫn xuất | User edits/confirmations không tự bị ghi đè |
| Đổi profile màu/conform | Media map, crop/visibility, preview/final/QC | Source bytes và user facts |

Sửa một câu không có quy tắc chung “chỉ làm lại TTS”. Phụ thuộc phải bao phủ nghĩa, thời lượng, các track, chữ, SFX và mix thực tế.

## 19. Approval và tái tạo kỹ thuật

Approval gắn snapshot bất biến và đúng loại phạm vi. Lịch sử vẫn được giữ khi approval stale; không tái gắn approval cũ sang revision mới.

- Duyệt fact, chọn script, duyệt script và duyệt preview là các hành động khác nhau.
- Đổi nội dung/timing/nghe/nhìn đã được preview duyệt thì cần preview mới và phê duyệt phù hợp.
- Tái render từ chính approved WAV/graphics/edit plan có thể giữ approval nếu profile cho phép và final QC đạt.
- Sinh lại TTS hoặc graphic khác bytes không mặc định là “cache refresh”; phải xác minh ảnh hưởng và áp đúng revision/approval.
- Resolution/codec-only theo profile đã công bố là ngoại lệ có kiểm, không cho phép đổi layout/cut/âm.

## 20. Runtime, hủy và vòng tự sửa

Một global heavy lease, buffer hữu hạn và checkpoint theo cửa sổ/job theo tài liệu 03/05. Chạy tuần tự không tự giải quyết stale result, nên mọi attempt vẫn cần fencing token.

- Trước khi thay attempt, core revoke quyền publish của attempt cũ.
- Hủy job không làm mất facts/resolutions/approved artifacts; chỉ thu hồi công việc chưa commit hợp lệ.
- Mỗi vòng tự sửa có finding, phạm vi, revision trước/sau, lý do sửa và checks phải chạy lại.
- Sửa lỗi kỹ thuật xác định được không được làm đổi factual/story ngoài phạm vi được phép.
- Hết số vòng thì blocked/unknown/review; không báo đạt vì retry đã hết.
- Resolve side effects dùng intent journal/reconciliation; rollback DB không đồng nghĩa rollback timeline.
- Manual edits được bảo toàn theo nhánh riêng; không tự rebuild đè lên bản người dùng đang sửa.

## 21. Học gu local nhưng không học sai sự thật

Profile lưu preference rõ ràng, script được chọn, sửa câu/shot và preset được chọn. Chưa fine-tune weights trong MVP; dùng cấu hình và ví dụ truy xuất có scope.

- Một lần chọn là tín hiệu yếu: có thể thích concept nhưng không thích voice hoặc cut.
- Phân biệt preference về ý tưởng/lời/nhịp/hình/âm với confirmation về fact.
- Người dùng xem/sửa/reset/export được profile; project override không làm đổi gu mặc định âm thầm.
- Preference revision nằm trong fingerprint artifact mà nó ảnh hưởng.
- Preference chỉ xếp hạng trong tập hợp lệ, không đổi provenance/allowed-use hoặc vượt approval gate.

## 22. Cách chứng minh tối ưu có ích

So sánh cấu hình trên dữ liệu chia theo chuyến/ngày quay, khóa trước held-out. Đo đồng thời omission, claim/quan hệ sai, OCR, thời gian, ghép ảnh, khớp hình–lời, abstention và mức tải review.

Với search, so nghiệm beam với exact checker ở miền nhỏ; đo trường hợp bỏ lỡ nghiệm, status không trung thực, vi phạm hard constraints và khác biệt chất lượng thủ công. Không chỉ đo thời gian tìm được một timeline bất kỳ.

Với hệ thống, đo peak RAM/swap, dữ liệu trung gian, số lượt chạy lại, thời gian tới kết quả và resume của lượt dài nhất trong phạm vi hỗ trợ. Đây là số đo vận hành, không phải lý do giảm baseline âm thầm.

Tất cả mục tiêu số và requirement IDs thuộc [09-UPGRADES-AND-ACCEPTANCE.md](09-UPGRADES-AND-ACCEPTANCE.md), đặc biệt STORY-03/STORY-04, AI-01/AI-03/AI-04/AI-05/AI-07 và MEDIA-01. Chưa đo thì ghi chưa đo; chỉ triển khai tối ưu sau khi có fixture và exit gate theo [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md).
