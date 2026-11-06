# 02 — Dữ liệu, bằng chứng, snapshot nguồn và quyền sử dụng thông tin

**Phiên bản đặc tả:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả để triển khai theo cổng kiểm chứng; chưa phải mã nguồn, ứng dụng đã chạy hoặc kết quả benchmark.

Tài liệu này là nguồn chuẩn cho ý nghĩa dữ liệu, quan hệ bằng chứng, phạm vi xác nhận và điều kiện dùng một khẳng định trong câu chuyện. [05-ARCHITECTURE-AND-ROADMAP.md](05-ARCHITECTURE-AND-ROADMAP.md) quy định quyền ghi, giao thức worker, publication và phục hồi. [04-SCRIPT-AND-EDIT.md](04-SCRIPT-AND-EDIT.md) quy định dựng/timebase; [09-UPGRADES-AND-ACCEPTANCE.md](09-UPGRADES-AND-ACCEPTANCE.md) giữ mã yêu cầu và cổng nghiệm thu. Thứ tự triển khai nằm trong [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md).

## 1. Những quy tắc nền không được thay bằng suy đoán

1. SQLite của project là dữ liệu nghiệp vụ chuẩn; JSON, báo cáo và giao diện là các cách trình bày của revision cụ thể.
2. Chỉ `ProjectStore` thuộc Swift core được commit dữ liệu chuẩn. Worker gửi đề xuất/kết quả có kiểu; không trực tiếp sửa database hoặc cấp approval.
3. Nguồn phân tích và dựng là **snapshot nội dung đã được niêm phong**, có hash; đường dẫn file gốc của người dùng không phải một phiên bản nội dung bất biến.
4. Ghi chú đã lưu, fact đã xác nhận, script đã chọn, script đã duyệt và preview đã duyệt là năm sự kiện khác nhau.
5. Một thông tin do người dùng xác nhận vẫn có nguồn người dùng. Video phù hợp có thể bổ sung evidence riêng; không sửa lịch sử để biến lời kể thành quan sát thị giác.
6. Liên kết mở được tới một file chưa chứng minh file đó hỗ trợ khẳng định. Kiểm cấu trúc, kiểm thời gian và kiểm ngữ nghĩa là ba lớp riêng.
7. `unknown`, thiếu bằng chứng và từ chối sử dụng một chi tiết là kết quả hợp lệ. Chúng không được biến thành “đã kiểm chứng” khi hết thời gian hoặc retry.
8. Thêm tư liệu có thể thay đổi một kết luận dựa trên toàn tập nguồn, ngay cả khi kết luận cũ không có cạnh tới file mới.
9. Tác vụ hoàn tất không đồng nghĩa phân tích đúng. Coverage, support, chất lượng kể và approval không dùng chung một trạng thái hoặc phần trăm.
10. Ví dụ JSON trong tài liệu là blueprint chưa chạy; migration/schema đầu tiên phải được hiện thực và kiểm thử trước dữ liệu thật.

## 2. Project, workday và phạm vi thời gian

### 2.1. Phạm vi nghiệp vụ

- `project` là đơn vị lưu trữ, quyền ghi và khôi phục. Mỗi project có một database chuẩn và một kho artifact được quản lý.
- `workday` là ngày/buổi/chuyến do người dùng tổ chức; một workday có thể qua nửa đêm, có nhiều chặng và nhiều nguồn.
- Metadata cùng ngày không tự chứng minh hai file thuộc cùng chuyến. Việc gán asset vào workday có lịch sử và có thể cần người dùng xác nhận.
- `camera_session` là phạm vi đồng hồ/thiết bị được dùng để hiệu chỉnh thời gian. Nó không đồng nghĩa workday; đổi thiết bị, đặt lại đồng hồ hoặc mất tính liên tục có thể tạo session mới.
- Một asset có thể liên quan nhiều sự kiện; một sự kiện có thể được nhiều asset ghi lại. Quan hệ này không phải một-một.
- Các giới hạn thử nghiệm E0/E1 và ma trận định dạng nằm ở [06-DECISIONS-AND-RISKS.md](06-DECISIONS-AND-RISKS.md). Chúng không làm thay đổi sự thật của dữ liệu ngoài phạm vi được hỗ trợ.

### 2.2. Ba hệ thời gian phải được phân biệt

| Hệ thời gian | Trường chuẩn | Cách dùng |
|---|---|---|
| Media nguồn có thời gian | `source_revision_id`, `stream_index`, `time_base_num`, `time_base_den`, `start_pts`, `end_pts` | Mở đúng bằng chứng trong snapshot video/audio nguồn |
| Timeline thành phẩm | `edit_plan_revision_id`, `timeline_start_frame`, `timeline_end_frame`, `timeline_fps_num`, `timeline_fps_den` | Xác định cut, voice, chữ và cue trên bản dựng |
| Thời gian sự kiện đời thực | `local_date`, `timezone`, `reported_time_text`, `time_precision`, nguồn của từng cận | Kể chronology của ngày làm việc khi có cơ sở |

Mọi khoảng media nội bộ dùng **`[start, end)`**: lấy đầu, không lấy cuối. Timebase/fps là số hữu tỉ với mẫu dương; PTS và số frame là số nguyên có kiểm tràn. PTS âm được giữ khi nguồn hợp lệ có offset âm; không ép về zero rồi làm mất quan hệ audio/video.

Asset ảnh tĩnh và brief không bắt buộc có khoảng thời gian media. Mở chúng bằng source revision của ảnh hoặc brief revision/span tương ứng; frame trích từ video vẫn giữ mapping thời gian về snapshot video gốc. Không tạo PTS/timecode giả cho nguồn không có trục thời gian media.

`time_precision=exact|approximate|range|date_only|unknown`. “Khoảng 3 giờ” không tự thành một thời điểm chính xác, không tự thành ±15 phút và không tự xác định sáng/chiều. Lưu nguyên văn, mức chắc chắn, timezone IANA nếu biết và nguồn của các cận. Nếu thiếu timezone, giữ trạng thái thiếu; không dùng timezone máy để giả vờ đã biết timezone sự kiện.

Thứ tự kể có thể khác thứ tự sự kiện. Một lần đổi thứ tự dựng không được ghi lại chronology nguồn như thể sự kiện đã xảy ra theo thứ tự mới.

## 3. Dữ kiện ngày làm việc và xác nhận có phạm vi

### 3.1. Chu trình brief → facts

1. Người dùng nhập văn bản tự do, thêm ghi chú theo clip/khoảng nguồn hoặc sửa một bản đã lưu.
2. Core lưu nguyên văn vào `brief_revisions`; không sửa mất lịch sử. Draft đang gõ khác revision đã commit.
3. AI trích `fact_revisions` dự thảo, giữ chủ thể, phủ định, mức chắc chắn, phạm vi thời gian và span trong brief gốc.
4. Tách thông tin về sự kiện, sở thích và ràng buộc sử dụng. “Tôi thích nhạc vui” không trở thành fact rằng một sự kiện vui đã diễn ra.
5. Giao diện cho sửa/gộp/bỏ và xác nhận đúng **nội dung + phạm vi + revision**. Có thể xác nhận một nhóm đã hiển thị; không xác nhận ngầm facts AI sẽ trích trong tương lai.
6. Confirmation được lưu thành resolution/decision có người thực hiện, thời điểm và danh sách fact revisions chính xác.
7. Nếu một câu trả lời review tạo thông tin mới, tạo fact revision mới; không âm thầm sửa báo cáo phân tích cũ.
8. Phân tích độc lập của source tiếp tục khi brief còn nháp. Kịch bản chỉ sử dụng facts đã đủ điều kiện theo bảng quyết định ở mục 6.

### 3.2. Nội dung có thể nhập

Mục tiêu, tuyến dự kiến/thực tế, mốc thời gian, tên địa điểm người dùng biết, vai trò của người/vật, diễn biến ngoài camera, ảnh ưu tiên, điều không muốn kể và gu dựng đều là dữ kiện có ích. Không trường nào buộc AI điền bằng suy đoán cho đủ form.

Lượt quan sát hình và ASR ban đầu không nhận câu chuyện kỳ vọng từ brief. Lượt xem có hướng dẫn từ brief được ghi vai trò riêng; nó có thể bổ sung hoặc phản bác, không ghi đè quan sát ban đầu để làm nguồn khớp câu chuyện.

Xác nhận một câu như “Tôi khởi hành lúc 3 giờ sáng” chỉ xác nhận lời kể và phạm vi mà người dùng đã xem. Nó không xác nhận mọi timestamp trong project, mọi lần xuất hiện của địa điểm hoặc động cơ của những người khác.

## 4. Các trục trạng thái độc lập

| Thuộc tính | Giá trị chuẩn | Ý nghĩa |
|---|---|---|
| `origin` | `user`, `visual_model`, `asr`, `audio_detector`, `ocr`, `metadata`, `derived` | Nguồn tạo thông tin; không đổi chỉ vì được review |
| `epistemic_status` | `observed`, `reported`, `inferred`, `unknown` | Quan sát trực tiếp, được kể lại, suy luận hoặc chưa biết |
| `review_status` | `unreviewed`, `auto_checked`, `needs_review`, `confirmed`, `rejected`, `superseded` | Review của đúng revision; không thay support |
| `support_status` | `supported`, `contradicted`, `insufficient`, `disputed` | Kết quả đánh giá claim theo evidence và phạm vi cụ thể |
| `allowed_use` | `direct_claim`, `attributed_or_qualified`, `illustrative_only`, `exclude` | Quyền sử dụng trong lần kể/dựng cụ thể |

- `observed` vẫn là một quan sát có thể sai. Không có giá trị enum nào chứng nhận sự thật tuyệt đối.
- `origin=user`, `epistemic_status=reported`, `review_status=confirmed` là bộ trạng thái đúng cho một user fact đã xác nhận.
- Nghe câu “Tôi đã lên phà” hỗ trợ claim có người nói câu đó. Nó chưa tự hỗ trợ claim sự kiện lên phà đã xảy ra.
- Review `confirmed` không tự đặt `support_status=supported` cho mọi quan hệ suy ra từ fact.
- `support_status` thuộc một assessment có phiên bản, không phải thuộc tính vĩnh viễn của câu chữ claim.
- `allowed_use` thuộc decision có input revisions và policy revision. Không cho frontend hoặc LLM tự đổi giá trị để vượt gate.
- `confidence_raw`, nếu lưu, chỉ là tín hiệu ưu tiên. Không hiển thị như xác suất đúng khi chưa hiệu chuẩn độc lập.

`narrative_type=observed|reported_by_user|inferred|nonliteral_commentary` thuộc **mỗi lần dùng claim trong câu/beat**. Một claim có nhiều lần dùng có thể cần nhiều use decisions. Lời ví von không được dùng để cài thêm một tiền đề factual chưa được hỗ trợ.

Trạng thái hiệu lực được suy từ revisions và các gate: dữ liệu có thể đúng schema nhưng assessment đang chờ đánh giá lại hoặc approval đã stale. Không nhét mọi điều đó vào `review_status`.

## 5. Claim, evidence và quan hệ ngữ nghĩa

### 5.1. Đơn vị khẳng định

Tách các mệnh đề factual và quan hệ trước/sau, nguyên nhân/kết quả thành các claim kiểm được riêng. Một câu có ba mệnh đề không được đạt chỉ vì một evidence hỗ trợ một mệnh đề.

Mỗi claim revision giữ tối thiểu: nội dung, chủ thể/đối tượng khi xác định được, scope, trạng thái tri thức, loại claim, nguồn tạo, các claim thành phần và mức ảnh hưởng tới câu chuyện. Mức ảnh hưởng cốt lõi (`critical`) phải đi qua policy ở tài liệu 09; không nhầm nó với confidence.

| Loại evidence | Tham chiếu bắt buộc | Không được suy ra tự động |
|---|---|---|
| Hình/video | Snapshot nguồn, crop nếu có, input manifest thực; video/frame trích từ video thêm stream và khoảng PTS, asset ảnh tĩnh không bắt buộc khoảng thời gian | Ý định, danh tính thật hoặc nguyên nhân ngoài khung hình |
| Audio/ASR | Snapshot nguồn, stream, khoảng PTS, transcript/audio revision | Nội dung lời nói chắc chắn đã xảy ra ngoài đời |
| OCR | Frame/crop nguồn và tọa độ, text, processor revision | Chữ mờ đúng theo điều brief mong muốn |
| Metadata | Trường đọc được, decoder/extractor revision, độ tin cậy | Đồng hồ máy luôn đúng hoặc mọi file cùng ngày là cùng chuyến |
| Người dùng | `fact_revision_id`, brief revision/span hoặc review resolution nguồn, scope và confirmation liên quan | Video đã chứng minh điều người dùng kể |
| Quan hệ suy luận | Claims/evidence thành phần, phép kiểm, giới hạn, policy | Xảy ra trước đồng nghĩa gây ra |

`claim_evidence.role=supports|contradicts|context_only`. Bằng chứng phản bác được giữ cùng nguồn hỗ trợ; không xóa vì bất tiện cho kịch bản.

### 5.2. Assessment bắt buộc có đầu vào tái kiểm được

Một `support_assessment` lưu `claim_revision_id`, evidence revisions, query manifest nếu có tìm kiếm, evaluator/model/prompt/policy revisions, `support_status`, lý do và giới hạn. Nếu chỉ dựa lời người dùng thì ghi đúng phạm vi đó.

Một `use_decision` lưu assessment đang dùng, `allowed_use`, narrative type, beat/use scope, criticality, ràng buộc người dùng và các review resolutions cần thiết. Đây là kết quả core kiểm theo policy, không phải một lời nhắc để model tự tuân thủ.

Validator deterministic kiểm schema, FK, source/hash, khoảng media, revisions và gate. Semantic evaluator đánh giá mức hỗ trợ của nội dung và quan hệ; năng lực của nó phải được đo false accept riêng. Hai model đồng ý không tạo một nguồn sự thật độc lập hoặc nhân các confidence với nhau.

## 6. Bảng quyết định quyền sử dụng

Áp dụng các dòng theo thứ tự. Nếu một điều kiện chặn ở trên đúng, dòng thuận lợi bên dưới không được ghi đè. Chính sách này mang `decision_policy_revision` và phải có fixture cho từng nhánh.

| Điều kiện của lần dùng | Quyết định chuẩn | Bước tiếp theo |
|---|---|---|
| Schema/source/hash/timecode không hợp lệ, dependency thiếu hoặc không đọc được | `exclude` | Chặn artifact phụ thuộc; sửa dữ liệu/nguồn trước đánh giá ngữ nghĩa |
| Assessment hoặc query scope đang chờ revalidation có ảnh hưởng | Tạm không cấp một use decision hiệu lực | Hoàn tất kiểm tác động; không tái dùng quyết định cũ để final |
| Claim bị phản bác hoặc còn mâu thuẫn trọng yếu chưa xử lý | `exclude` | Tạo review đúng phạm vi, bỏ claim hoặc đổi concept |
| Fact do AI trích từ brief chưa được xác nhận đúng revision | `exclude` cho lời kể factual dựa fact đó | Cho người dùng sửa/xác nhận hoặc không sử dụng |
| Quan sát trực tiếp được hỗ trợ đúng phạm vi, không còn xung đột chặn, review đủ điều kiện | `direct_claim` | Có thể kể đúng nội dung đã hỗ trợ; crop/dựng vẫn phải giữ evidence |
| User fact đã xác nhận, assessment hỗ trợ theo nguồn người dùng, không còn xung đột chặn | `attributed_or_qualified` | Có thể kể tự nhiên ở ngôi thứ nhất; giữ provenance, không trình B-roll như bằng chứng trực tiếp |
| Nguồn audio chứng minh một phát ngôn, chưa chứng minh sự kiện được kể | `direct_claim` chỉ cho claim về phát ngôn | Muốn kể sự kiện phải có claim/assessment riêng |
| Suy luận có các tiền đề đủ hỗ trợ và giới hạn được policy cho phép | `attributed_or_qualified` | Nêu đúng mức suy luận; quan hệ cốt lõi chưa đủ thì review hoặc bỏ |
| Media chỉ khớp bối cảnh, chưa đủ xác nhận đúng sự kiện/cú bấm | `illustrative_only` | Chỉ dùng làm minh họa; không phát biểu hoặc dựng ngầm rằng đó là đúng thời điểm |
| Thiếu bằng chứng cho claim cốt lõi | `exclude` | Review có mục tiêu hoặc tạo câu chuyện không phụ thuộc claim |
| Thiếu bằng chứng cho chi tiết phụ | `exclude` cho khẳng định đó | Bỏ chi tiết, giữ unknown; không hỏi bắt buộc nếu không cần cho câu chuyện |
| Lời bình phi nghĩa đen không thêm tiền đề factual và không vi phạm ràng buộc | Duyệt cách dùng theo các claim nền hợp lệ | Kiểm lại nghĩa ngầm; nhãn “đùa” không miễn kiểm sự thật |

`illustrative_only` không cấp quyền đọc một mệnh đề chưa có căn cứ thành lời kể chắc chắn. Cũng không dùng từ “có vẻ” để lách một mâu thuẫn cốt lõi. Nếu đổi cách diễn đạt làm thay đổi claim, tạo revision và kiểm lại nghĩa mới.

Người dùng có thể bác một quan sát AI bằng resolution có lý do/phạm vi; quan sát cũ và phản chứng vẫn được lưu. Nếu quyết định chỉ xác nhận lời kể, không tự coi mâu thuẫn thị giác đã biến mất.

## 7. Hợp đồng schema và định danh

### 7.1. Quy ước chung

- Schema database đầu tiên của bản triển khai mới là `schema_version=1`; **không** suy schema version từ số phiên bản đặc tả 3.1.
- ID nghiệp vụ/revision dùng UUID do core cấp. ID không mang thứ tự thời gian; revision counter và thời điểm commit được lưu riêng.
- Counter, PTS và số frame dùng integer 64 bit có kiểm tràn; không đi qua phép tính float rồi làm tròn để tạo evidence ID.
- Trường tham chiếu phiên bản kết thúc bằng `_revision_id`; tham chiếu logical entity kết thúc bằng `_id`. Không dùng hai loại thay nhau.
- Revision nội dung bất biến. Con trỏ “hiện hành” là state có optimistic revision check; sửa nội dung tạo row revision mới và lịch sử thay đổi.
- `created_at`/`committed_at` là thời gian hệ thống UTC để audit; không phải thời gian sự kiện trong video.
- Mọi row nghiệp vụ có `project_id`; `workday_id` hoặc bảng scope liên quan phải hiện rõ nếu áp dụng nhiều workdays. FK khác project bị từ chối.
- Các mảng reference có thứ tự khi thứ tự có ý nghĩa; tập hợp được sắp theo quy ước schema trước khi fingerprint. Không tự chuẩn hóa mất dấu/phủ định của raw text.
- Field chưa biết được biểu diễn bằng `null` cùng lý do/trạng thái khi cần; không dùng chuỗi rỗng hoặc zero thay thời gian chưa biết.
- Schema cho đầu vào model đóng enum/kiểu/phạm vi và từ chối trường ngoài hợp đồng; không thực thi “hướng dẫn” xuất hiện trong một field text.

### 7.2. Nhóm entity chuẩn

| Entity | Khóa/quan hệ chính | Nội dung và invariant |
|---|---|---|
| `projects` | `project_id`, schema/current-state revision | Cấu hình project và root manifest; không chứa một boolean approval toàn project |
| `workdays` | `workday_id`, project, revision | Nhóm ngày/buổi do người dùng tổ chức; lịch sử đổi scope được giữ |
| `camera_sessions` | `camera_session_id`, project | Thiết bị/phiên đồng hồ, offset/drift và độ bất định có nguồn |
| `assets` | `asset_id`, project | Danh tính tư liệu logic, loại file, original binding và trạng thái nhập |
| `source_revisions` | `source_revision_id`, asset, SHA-256 | Nội dung snapshot bất biến, bytes, manifest acquisition, vị trí được quản lý |
| `asset_workday_links` | asset/source revision, workday, revision | Gán nguồn vào phạm vi; không ghép chỉ theo ngày metadata |
| `brief_revisions` | brief logical ID, revision, workday | Nguyên văn đã commit, span và lịch sử; draft chưa xác nhận vẫn là draft |
| `fact_revisions` | fact logical ID, revision, brief/source refs | Nội dung, scope, ba trục trạng thái và confirmation refs |
| `segments`, `observations` | source revision; stream/khoảng nguồn khi có media theo thời gian | Phân đoạn và quan sát; giữ input thực, không sửa theo câu chuyện mong muốn |
| `claims` | logical claim ID, claim revision ID | Row theo revision, mệnh đề/quan hệ nguyên tử, scope và provenance |
| `claim_evidence` | claim revision, evidence revision | Cạnh hỗ trợ/phản bác/ngữ cảnh; evidence có thể là source hoặc user fact |
| `support_assessments` | claim revision, evaluator/policy, inputs | Kết quả hỗ trợ theo một tập bằng chứng cụ thể |
| `claim_uses`, `use_decisions` | claim revision, script/beat/use revision | Narrative type và quyền dùng đúng lần xuất hiện |
| `events`, `event_relations` | event revisions, evidence refs | Sự kiện, chronology bộ phận và quan hệ có nguồn |
| `photo_matches` | photo source revision, event/source candidate | Ứng viên, mức hỗ trợ, cách dùng riêng; không ép ghép một-một |
| `media_maps` | source/proxy/timeline revisions | PTS/frame mapping, frame lặp/bỏ, rotation/crop và policy conform |
| `coverage_records` | source revision, processor/run manifest | Coverage thực, tập frame duy nhất và vùng lỗi/thiếu |
| `evidence_scope_revisions` | scope logical ID, revision | Tập nguồn/điều kiện tìm kiếm cụ thể của workday hoặc nhiều workdays |
| `query_manifests` | scope revision, index/model/policy refs | Truy vấn, nguồn đã xét, candidates, giới hạn và kết quả không tìm thấy |
| `impact_revalidations` | old/new scope revisions, target refs | Công việc xét tác động thêm/sửa nguồn; không phải approval người dùng |
| `review_items`, `review_resolutions` | claim/fact revisions, scope | Vấn đề, bằng chứng, quyết định, ảnh hưởng và lịch sử xử lý |
| `scripts`, `shot_candidates`, `beat_cues` | script/edit revisions, nguồn | Kịch bản, lựa chọn hình và nhịp; khóa người dùng có revision |
| `preference_events`, `preference_profiles` | user/project scope, revision | Gu có nguồn; không phải fact hoặc ground truth về sự kiện |
| `artifact_revisions`, `artifact_dependencies` | artifact revision, input fingerprint, SHA-256 | Kết quả bất biến, dependencies và metadata; bytes khác là artifact khác |
| `blob_inventory`, `gc_operations` | content hash, inventory generation, GC operation ID | Vị trí/availability của bytes, reservation `gc_pending` và journal xóa; không sửa nội dung revision |
| `approvals` | loại, actor, scope, artifact/input revisions | Duyệt rõ snapshot; không tự hồi sinh approval bằng Undo |
| `job_runs`, `job_attempts` | job/attempt IDs, fencing token | Đầu vào, checkpoint, quyền publish và kết quả theo tài liệu 05 |
| `artifact_publications`, `resolve_operations` | intent/operation IDs, job attempt | Journal publication và side effect; không đồng nhất hai hệ trạng thái |
| `backup_manifests`, `artifact_pins` | root revision/hash, owner ref | Khôi phục và giữ dữ liệu còn được tham chiếu |
| `audit_findings`, `render_revisions` | artifact/edit/approval refs | Findings và render đúng revision; final gate không dựa một cờ trôi nổi |

### 7.3. Ràng buộc bắt buộc trong store

1. Unique cho `(logical_entity_id, revision)`; một revision không được ghi đè nội dung sau commit.
2. FK và kiểm project/scope cho mọi reference; SQLite bật `foreign_keys` trên từng connection theo tài liệu 05.
3. Unique cho idempotency key trong phạm vi lệnh; cùng key nhưng payload/fingerprint khác trả conflict.
4. Evidence media phải tham chiếu source revision đã seal. Với video/audio hoặc frame trích từ video, khoảng `[start,end)` phải tồn tại trong stream/mapping được khai báo; với asset ảnh tĩnh, kiểm snapshot/crop tương ứng, không bắt buộc khoảng thời gian media.
5. Một approval chỉ trỏ artifact `COMMITTED` đủ gate và các input revisions đã được người dùng xem.
6. Output từ attempt hết quyền không thể trở thành dữ liệu chuẩn dù file có vẻ hợp lệ.
7. GC không được xóa blob/source còn reference hoặc pin bởi approval, backup hay job đang hợp lệ. Reservation `gc_pending` được commit cùng kiểm zero-reference/zero-pin; reference/pin mới không được vượt qua reservation trong lúc filesystem unlink đang xử lý.
8. Cổng final kiểm cả approvals, pending impact, source/media integrity và QC của chính final revision.

## 8. Nhập nguồn và tạo snapshot bất biến

### 8.1. Manifest nhập

Quét các định dạng trong capability matrix: MOV/MP4/M4V và JPG/HEIC/PNG là ứng viên, không phải mọi biến thể đều đã hỗ trợ. Bỏ qua file hệ thống; không di chuyển, sửa hoặc xóa file gốc. Ghi lỗi decode/quyền/định dạng theo asset để nhánh độc lập tiếp tục.

Manifest nguồn giữ original binding/bookmark, danh tính file quan sát được, kích thước, thời điểm acquisition, source revision, SHA-256, chế độ clone/copy, đường dẫn snapshot tương đối, kết quả verify và policy revision. Metadata media được đọc từ snapshot nhất quán sau acquisition.

### 8.2. Acquisition chuẩn

1. Core kiểm quyền, định dạng dự kiến, vùng lưu local APFS được hỗ trợ và ngân sách disk cho clone/copy cùng các bước tiếp theo.
2. Đọc danh tính/metadata file trước acquisition; giữ cùng đối tượng nguồn khi sao chép, không mở lại một pathname rồi giả định vẫn là file cũ.
3. Ưu tiên APFS clone chỉ trên đường đã qua capability fixture; ngoài trường hợp đó tạo full copy vào thư mục tạm của kho đích.
4. Hash bytes, kiểm copy/clone và đối chiếu tính ổn định của nguồn trong cửa sổ acquisition. Thay thế/ghi nối/ghi đè nguồn giữa chừng phải bị phát hiện hoặc bị coi chưa chứng minh tính nhất quán, rồi retry/pause.
5. Không trộn metadata đọc từ một lần mở nguồn với bytes thuộc revision khác. Hash/verify snapshot độc lập trước khi seal.
6. Core publish snapshot theo giao thức ở tài liệu 05, ghi source revision và thiết lập quyền đọc trong kho app quản lý.
7. Mọi phân tích, preview và render có thẩm quyền đọc snapshot đó; source gốc chỉ phục vụ provenance/relink/import revision mới.

Không dùng hardlink làm bảo đảm bất biến. Không coi clone là “không tốn disk”: preflight tính cả metadata, copy-on-write growth, proxy, artifact tạm và final. Không đủ chỗ thì pause; không âm thầm chuyển sang đọc trực tiếp file gốc yếu hơn hợp đồng.

App-private/read-only bảo vệ hành vi bình thường của ứng dụng, không phải lời hứa chống tiến trình có quyền hệ điều hành cố ý sửa dữ liệu. Gate sử dụng/final vẫn kiểm hash và phát hiện corruption. Nguồn bị đổi bên ngoài không được thay bytes của một revision đã được duyệt.

### 8.3. Relink và thay nguồn

- Original bị dời nhưng snapshot còn nguyên: project vẫn có thể dùng snapshot; cập nhật binding gốc sau khi xác minh danh tính, không đổi evidence revision.
- Relink tới bytes giống hệt: giữ content revision và lịch sử binding phù hợp; không tạo một “nguồn mới” chỉ vì tên/đường dẫn đổi.
- Relink tới bytes khác: tạo source revision mới, giữ revision cũ còn pin và mở impact revalidation; không tái dùng approval cũ như nguồn không đổi.
- Snapshot thiếu/hỏng: chặn phần phụ thuộc, phục hồi từ backup/nguồn được verify hoặc acquisition lại đúng bytes. Không tự thay bằng một file gần giống.
- User loại asset khỏi cách dựng: lưu ràng buộc/scope revision; không xóa source hoặc lịch sử để thực hiện thao tác loại.

## 9. Pipeline phân tích mỗi asset

| Bước | Đầu ra bắt buộc | Giới hạn diễn giải |
|---|---|---|
| Kiểm kê | Streams, codec, rotation, timebase, PTS index, lỗi decode | File mở được chưa có nghĩa toàn stream giải mã được |
| Proxy/audio | Proxy revision, audio revision, mapping về snapshot | Proxy không thay source chuẩn cho chi tiết nhỏ |
| Quét tín hiệu hình | Chuyển động, cảnh, nét/sáng, đối tượng/chi tiết ứng viên | Chỉ điều hướng, chưa chứng minh ý nghĩa câu chuyện |
| Quan sát độc lập | Hình/ASR ban đầu không nhận câu chuyện kỳ vọng | Giữ kết quả và giới hạn riêng với lượt xem theo brief |
| Chi tiết toàn frame | Input manifest sau processor, batch có chồng lấn, coverage | Mọi frame hợp lệ đi vào lượt chi tiết; không đồng nghĩa hiểu đúng |
| Lượt chuyên biệt | OCR/crop/hành động/chi tiết/âm thanh theo nhiệm vụ | Không dùng upscale sinh chi tiết để xác nhận bằng chứng |
| Tổng hợp | Claims/events/relations với source/fact revisions | Không chỉ chuyển một bản tóm tắt ngắn cho bước viết |
| Bỏ sót/phản chứng | Findings, nguồn đã soi lại, bất định còn lại | Không chỉ đọc lại báo cáo model đã viết |
| Review | Câu hỏi có nguồn, scope và artifact chịu ảnh hưởng | Chỉ hỏi phần thay đổi sự thật/góc kể/lựa chọn dựng đáng kể |

Chi tiết streaming, cửa sổ, pixels/tokens và profile toàn-frame nằm ở [07-OPTIMIZATION.md](07-OPTIMIZATION.md), [08-ACCURACY-FIRST.md](08-ACCURACY-FIRST.md). Adaptive refinement bổ sung cho baseline, không thay baseline bằng lấy mẫu thưa mà vẫn báo đạt.

Không có audio stream trả `no_audio`; có audio nhưng không nhận ra lời trả `no_speech`. Hai trạng thái này không tắt nhánh hình. Sound-event detector là capability riêng; ASR không tự chứng nhận tiếng click/còi. Thiếu detector đạt gate thì giữ năng lực đó chưa được chứng minh.

Mỗi asset theo dõi `visual_scan`, `detailed_pass`, `audio_analysis`, `semantic_analysis`, `omission_audit` riêng. Một vùng lỗi giữ nguyên trong denominator/báo cáo; không xóa khỏi tập cần xử lý để tạo coverage 100% giả.

## 10. Coverage và input thực tế

Coverage record giữ source revision, stream, PTS/frame index thực đã decode, frame thực đến processor, frame/token input sau processor, kích thước/crop, cửa sổ, run/attempt và vùng lỗi. Nếu backend tự chọn/bỏ frame, manifest phải thể hiện điều đó và gate toàn-frame chưa đạt.

- Tính hợp các frame/khoảng duy nhất; không cộng chồng lấn hai lần.
- Tách coverage decode, coverage model input, coverage thời gian và coverage kiểm chứng.
- Một frame đi vào model không được chuyển thành “đã hiểu frame này đúng”.
- Frame valid/invalid có lý do decoder; không đổi nhãn để che tài nguyên hoặc giới hạn model.
- Source không giải mã được đầy đủ có thể được loại khỏi concept theo quyết định có scope; UI vẫn báo rõ nguồn lỗi/chưa phân tích.
- Bằng chứng dùng trong câu chuyện phải truy ngược về snapshot, không chỉ về caption/proxy/ảnh do app đã tạo.

## 11. Corpus revision và tìm kiếm có phạm vi

### 11.1. Snapshot của tập bằng chứng

`evidence_scope_revision_id` xác định tập source revisions, workday membership, trạng thái loại/được xét và các điều kiện truy vấn. Nó không phải số lượng file hoặc thời điểm quét thư mục. Các fact/brief/policy revisions liên quan vẫn là dependencies riêng; không giấu chúng trong một tên scope.

Một `query_manifest` giữ tối thiểu:

- Scope revision, mục tiêu claim/event/shot và câu hỏi tìm kiếm.
- Danh sách source revisions đã được lập chỉ mục/xét; nguồn chưa index hoặc lỗi được ghi rõ.
- Index/embedding/model/processor/prompt/policy revisions và cấu hình lọc/top-k.
- Các ứng viên được truy xuất, kết quả bị loại, giới hạn tìm kiếm và lý do.
- Kết quả “không tìm thấy” cùng phạm vi đã tìm; không biến thành “không tồn tại trong đời thực”.
- `scope_sensitive`: kết quả có phụ thuộc việc toàn bộ tập nguồn hiện hành đã được xét hay không.

Assessment về thiếu bằng chứng, lựa chọn shot tốt nhất trong tập, quan hệ xuyên source, omission audit và concept tổng hợp thường có phụ thuộc scope. Quan sát trực tiếp của một frame bất biến có thể chỉ phụ thuộc source/processor của frame đó.

### 11.2. Khi thêm, thay hoặc đổi phạm vi nguồn

1. Commit membership/source revision mới và tạo evidence scope revision mới.
2. Đánh dấu các assessment/ranking/query có phạm vi liên quan **pending revalidation**. Các quan sát bất biến của clip cũ được giữ.
3. Phân tích nguồn mới; chạy reverse retrieval/đối chiếu vào claims/events/concepts và các kết luận “chưa tìm thấy” thuộc scope đó.
4. Ghi impact result có bằng chứng: `no_material_change`, `material_change` hoặc `unresolved`; đây là enum riêng của `impact_revalidations`.
5. `no_material_change` cho phép giữ artifact/approval còn đúng snapshot theo policy; thêm impact decision liên kết scope cũ/mới và lý do. Giữ nguyên approval identity, snapshot và fingerprint đã duyệt; không viết lại fingerprint cũ để tự kế thừa sang scope mới.
6. `material_change` tạo assessment/decision revision mới và làm stale đúng artifact/approval phụ thuộc. Không tự sửa bản đã duyệt.
7. `unresolved` chặn final phụ thuộc phạm vi đang xét; nhánh phân tích độc lập vẫn chạy.

Không chỉ đi theo các cạnh DAG cũ: clip mới chưa tồn tại nên chưa thể có cạnh cũ tới nó. Đồng thời không làm stale mọi approval chỉ vì thêm một file không liên quan. Khi chưa xác định được liên quan, giữ pending ở scope cần kiểm thay vì tuyên bố “không ảnh hưởng”.

Gỡ pending bằng một `no_material_change` decision có thẩm quyền không có nghĩa người dùng đã duyệt nguồn mới. Nếu nội dung hoặc một dependency thực được dùng thay đổi, phải tạo artifact revision mới và stale approval phù hợp, dù kết quả nhìn qua có vẻ giống.

Final gate kiểm approval gốc cùng chuỗi impact decisions còn hiệu lực tới scope cần xét. Có scope/phản chứng mới thì decision no-impact cũ không tự áp dụng cho nguồn mới; phải revalidate lại đúng phạm vi.

Nếu corpus thay đổi trong lúc render, file có thể hoàn tất về mặt kỹ thuật nhưng final gate phải chờ impact check tương ứng. Không báo `done` chỉ vì encoder đã xong.

## 12. Review có mục tiêu và giải quyết mâu thuẫn

`review_item` có một vấn đề chính, câu hỏi ngắn, claim/fact revisions, evidence mở được đúng loại và revision, lý do cần hỏi, mức ảnh hưởng và dependencies.

- Với video/audio liên quan, hiển thị tên nguồn, khoảng source và ngữ cảnh trước/sau trong phạm vi nguồn có sẵn; không chỉ đưa thumbnail rời làm người dùng mất ngữ cảnh.
- Với asset ảnh tĩnh, hiển thị đúng snapshot ảnh, crop nếu có và thông tin nguồn; không bắt có video hoặc khoảng thời gian media. Frame trích từ video vẫn mở được về đúng video/range gốc.
- Với brief hoặc câu trả lời đã lưu, mở đúng brief revision/span hoặc review resolution cùng fact revisions liên quan. Review chỉ có ảnh hoặc chỉ có brief là hợp lệ; không bắt người dùng cung cấp clip để điền trường không áp dụng.
- Không gán clip/ảnh minh họa thành bằng chứng còn thiếu. Nếu hiển thị tư liệu chỉ để gợi bối cảnh, giữ vai trò `context_only`; nó không tự hỗ trợ claim đang cần làm rõ.

Các resolution được hỗ trợ:

| Hành động | Dữ liệu phải ghi | Hệ quả |
|---|---|---|
| Xác nhận lời kể | Fact revisions, scope, actor, thời điểm | Nguồn vẫn là người dùng |
| Sửa thông tin | Revision mới, liên kết revision bị thay | Xét lại claim/script/approval phụ thuộc |
| Bác quan sát AI | Observation/claim revisions và lý do/phạm vi | Giữ lịch sử/evidence cũ; đánh giá lại support |
| Chưa biết | Issue revision đã xử lý, uncertainty còn lại | Đóng lượt hỏi, không cấp quyền khẳng định |
| Bỏ chi tiết/claim | Phạm vi loại và concept/beat bị ảnh hưởng | Không giữ cùng tiền đề dưới dạng một câu đùa |
| Bổ sung tư liệu | Source/scope revision mới | Chạy impact revalidation trước khi dùng |

Không hỏi lặp cùng vấn đề sau “chưa biết” nếu không có bằng chứng mới hoặc yêu cầu mới của người dùng. Một unresolved critical issue chỉ chặn các phương án/artifact cần claim ấy; có thể chuyển góc kể. Không biến review thành yêu cầu người dùng xem lại toàn bộ source.

## 13. Event graph, ảnh và shot

Chronology là thứ tự bộ phận. Có thể biết A trước B mà chưa biết A trước/sau C; không ép tổng thứ tự bằng tên file. Cạnh `before`, `overlaps`, `continues`, `same_session_candidate` và quan hệ nhân quả phải có evidence/uncertainty riêng.

Kiểm vòng mâu thuẫn trước/sau, lặp địa điểm ở ngày khác, quay lại cùng đường, lệch/trôi đồng hồ và cảnh giống nhau. Track ID của đối tượng là liên kết kỹ thuật tạm giữa frame, không phải nhận diện danh tính thật.

Ghép ảnh dùng metadata/embedding để tạo ứng viên, rồi kiểm ngữ cảnh/thời gian/hình học khi phù hợp. Đo recall của bước top-k; không giả định ứng viên đầu đúng. Có thể nhiều ảnh cho một burst/event; không ép một-một hoặc bắt tiếng click phải tồn tại.

`match_status=exact_candidate|contextual_match|unmatched` mô tả ứng viên. `use_mode=exact|illustrative|none` mô tả cách dùng và không thay support assessment. `exact_candidate` chưa phải xác nhận; `exact` cần vượt gate riêng ở tài liệu 09, có provenance và không còn mâu thuẫn trọng yếu. Nếu chưa vượt gate, chỉ dùng minh họa phù hợp hoặc không dùng.

Shot lưu riêng nét, sáng, bố cục, độ ổn định, chuyển động có chủ ý, giá trị câu chuyện, độ mới, crop feasibility và liên quan beat. Clip im lặng không bị trừ điểm vì thiếu lời; shot rung nhưng có tình tiết không tự bị loại.

## 14. Revision, cache và artifact bất biến

### 14.1. Fingerprint đầu vào khác hash đầu ra

`input_fingerprint` mô tả source/fact/scope/policy/model/processor/runtime/prompt/config/schema/media-map revisions mà job sử dụng. `content_sha256` mô tả bytes artifact thực tế. Hai thứ không được thay nhau.

Cùng seed, model và prompt không chứng minh cùng WAV hoặc cùng hình. Voice/graphics/edit plan đã được duyệt được giữ nguyên bytes và pin. Rerender dùng những bytes đó; tái sinh làm thay audio/timing/nội dung phải tạo artifact revision và duyệt lại đúng phạm vi.

Fingerprint dùng một serializer canonical được khóa và kiểm fixture Swift/Python; không hash JSON pretty-print tùy thư viện. Schema fingerprint cấm giá trị không hữu hạn, định nghĩa thứ tự tập hợp và lưu số thời gian chính xác. Raw notes được giữ nguyên; bản chuẩn hóa dùng cho tìm kiếm là artifact dẫn xuất riêng.

### 14.2. Những dependency phải thể hiện

| Thay đổi | Phạm vi xét lại tối thiểu |
|---|---|
| Brief/fact/confirmation đổi nghĩa | Claims, support/use decisions, conflicts và câu chuyện dùng chúng |
| Thêm/thay source hoặc membership | Corpus/query impact; event/claim/ranking/concept liên quan |
| Sửa lời kể | Claim entailment, TTS, duration, cut, caption, cue, mix và approvals liên quan |
| Đổi voice/phát âm | WAV, speech check, alignment, timing và các artifact nghe/nhìn phụ thuộc |
| Đổi crop/style/nhạc | Evidence còn quan sát được, layout/mix, preview/final và gate phù hợp |
| Đổi model/processor/prompt | Phân tích theo cấu hình đó; không ghi đè quyết định người dùng |
| Đổi source→proxy→timeline mapping | Cut, seek, crop/caption/timing và QC liên quan |
| Đổi policy support/search/render | Những decision/artifact dùng policy cũ theo phạm vi thay đổi |

Không phân tích lại mọi frame khi chỉ sửa style. Không áp quy tắc “chỉ làm lại TTS” khi lời thay đổi. User locks `must_use`, `must_not_use`, `preferred` có revision và phải được đưa vào fingerprint của bước chọn/dựng.

## 15. Approval và final gate ở tầng dữ liệu

- Fact confirmation ghi đúng facts/scope; không phải approval toàn project.
- Script approval gắn script, claim/fact use decisions, storyboard, constraints và voice thử liên quan đã được hiển thị.
- Preview approval gắn preview/edit plan và bytes voice/graphics, timing, crop, chữ, mix cùng render profile tương ứng.
- Approval không cần ID của artifact tương lai chưa sinh; phải mô tả đúng snapshot giai đoạn đó đã được duyệt.
- Rebuild kỹ thuật chỉ giữ approval khi dùng đúng media bytes/snapshot đã được phép và không đổi nội dung/timing; vẫn phải QC.
- Final khác resolution/codec chỉ được phép theo profile final đã khai báo và QC chính final. Thay layout/cut/voice/mix ngoài phạm vi đó cần revision/duyệt lại.
- Approval hết hiệu lực giữ lại trong lịch sử, không bị xóa hoặc tự bật lại khi Undo. Core tính hiệu lực từ snapshot và gate hiện hành.

Điều kiện `done` phải tham chiếu **final artifact revision** cụ thể: committed bytes, đúng snapshot, approvals hiệu lực, không còn impact/review/finding chặn, QC final đạt và các đầu ra bắt buộc tồn tại. Một job `succeeded` không đủ điều kiện này.

## 16. Bố cục lưu trữ và an toàn dữ liệu

```text
Project.aivideo/
  project.json          # locator/schema metadata; không thay database chuẩn
  data.sqlite           # canonical store; WAL/backup theo tài liệu 05
  sources/              # sealed source blobs và acquisition manifests
  artifacts/            # immutable voice, plans, graphics, evidence, preview/final
  manifests/            # input/query/media/backup manifests có revision
  attempts/             # đầu ra tạm riêng từng attempt; không được duyệt trực tiếp
  cache/                # thumbnail/proxy có thể tái tạo theo policy
  resolve/              # managed project/timeline export và manual handoff manifest
  reports/              # report theo revision; dữ liệu chuẩn vẫn ở store
  backups/              # manifest/checkpoint hoặc vị trí backup đã cấu hình
```

Tên thư mục là hợp đồng vai trò, không là lời hứa đã có cấu trúc app. Blob lớn không nằm trong SQLite BLOB. Đường dẫn artifact là reference đã đăng ký dưới project root; core kiểm path traversal, symlink vượt root, loại file và hash trước chấp nhận worker output.

Quota cache chỉ dọn dữ liệu tái tạo được. Snapshot nguồn, approved artifacts, raw notes, facts, resolutions, approvals và backup refs phải giữ theo pin/reference. Nếu proxy trở thành phần cần thiết để tái tạo chính xác một revision đã duyệt, manifest phải pin nó hoặc mô tả cách tái tạo được chứng minh tương đương.

OCR, transcript, metadata, tên file và brief là **dữ liệu**. Không thực thi code/lệnh hệ thống lấy từ chúng; gọi công cụ bằng argument có kiểu và quyền hạn hẹp. Ràng buộc kể chuyện của người dùng đi qua schema cấu hình/review. Không gửi dữ liệu project ra API AI ngoài; thiếu runtime thì pause theo tài liệu 03.

## 17. Ví dụ hợp đồng rút gọn

Ví dụ hư cấu dưới đây minh họa một user fact và một observation riêng. ID không trỏ tới tư liệu thật; không phải kết quả đã phân tích. Payload thực phải qua schema đầy đủ, FK, source manifest và các gate.

```json
{
  "schema_version": 1,
  "project_id": "00000000-0000-4000-8000-000000000001",
  "workday_id": "00000000-0000-4000-8000-000000000002",
  "user_fact": {
    "fact_revision_id": "00000000-0000-4000-8000-000000000003",
    "text": "Tôi khởi hành lúc 3 giờ sáng để đi chụp rước dâu.",
    "origin": "user",
    "epistemic_status": "reported",
    "review_status": "confirmed",
    "confirmation_id": "00000000-0000-4000-8000-000000000004"
  },
  "visual_claim": {
    "claim_revision_id": "00000000-0000-4000-8000-000000000005",
    "text": "Xe quay đầu trong đoạn video này.",
    "origin": "visual_model",
    "epistemic_status": "observed",
    "review_status": "auto_checked",
    "source_revision_id": "00000000-0000-4000-8000-000000000006",
    "stream_index": 0,
    "time_base_num": 1,
    "time_base_den": 90000,
    "start_pts": 1134000,
    "end_pts": 1710000,
    "interval_convention": "[start,end)"
  },
  "unresolved_relation": {
    "text": "Quay đầu vì đi lạc.",
    "support_status": "insufficient",
    "allowed_use": "exclude"
  }
}
```

Việc xe quay đầu không tự chứng minh “đi lạc”. Giờ khởi hành là thông tin người dùng kể; observation quay đầu không xác nhận giờ đó. Muốn kể nguyên nhân phải có claim quan hệ và nguồn/xác nhận đúng phạm vi.

## 18. Kiểm chứng bắt buộc của hợp đồng dữ liệu

| Nhóm nghiệm thu | Kết quả cần chứng minh |
|---|---|
| `DATA-01` | Nguồn thay bytes/cùng tên/đang acquisition không thay snapshot đã seal; thiếu disk không chuyển chế độ âm thầm |
| `DATA-03`, `DATA-04` | Worker không ghi DB; lưu/duyệt đúng revision; retry/double click không tạo hai quyết định |
| `DATA-05` | Thêm clip phản chứng hoặc bổ sung bằng chứng “chưa tìm thấy” làm xét lại đúng scope |
| `DATA-08` | Cache/GC không xóa source/artifact còn pin; relink khác nội dung không kế thừa approval |
| Nhóm `AI-*` | Decision table tách cấu trúc/ngữ nghĩa; false accept và omission đo riêng |
| Nhóm `STORY-*` | User facts giữ nguồn; unsupported causal claim không lọt dưới dạng câu đùa hoặc minh họa |
| Nhóm `MEDIA-*` | PTS/mapping và khoảng nguồn thật mở được; crop không làm mất bằng chứng quan trọng |
| Nhóm `REL-*` | Khôi phục giữ facts, resolutions, scopes và approvals; schema không trôi giữa runtime |

Fixture phải có brief đúng/sai/mơ hồ, phủ định, thời gian ước lượng, nhiều ngày cùng địa điểm, clip im lặng/không audio, metadata sai, nguồn được bổ sung muộn và sửa fact sau duyệt. Thêm review chỉ có ảnh và review chỉ có brief: mở đúng nguồn/revision, không sinh timecode giả hoặc gán clip minh họa thành evidence hỗ trợ. Tách phát triển/held-out theo chuyến/ngày quay.

Ít claim sai nhưng bỏ toàn bộ sự kiện khó thành unknown không đủ đạt. Đo cùng lúc support precision, recall sự kiện quan trọng quan sát được, mức từ chối, hiệu quả câu hỏi và tỷ lệ project đủ điều kiện hoàn tất. Mẫu, denominator, mục tiêu và kết quả thực giữ tại tài liệu 09; khi chưa đo phải ghi “chưa đo”.
