# 11 — Quy trình code AIVideo và checklist theo từng bước

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** kế hoạch triển khai; tất cả công việc bên dưới chưa được xác nhận hoàn thành.  
**Mục đích:** biết chính xác đang code đến đâu, cần làm gì tiếp, bằng chứng nào cho phép tích một mục.

## 1. Cách dùng checklist

Mỗi bước S00–S26 có phụ thuộc, đầu ra, công việc code, kiểm tra và điều kiện hoàn thành. Tích các ô con khi đã làm và có bằng chứng; chỉ tích ô tổng của bước khi toàn bộ mục bắt buộc của bước đạt. Một bước đang bị chặn phải ghi nguyên nhân và bước xử lý, không đổi tiêu chí để làm nó trông đã xong.

Không dùng việc file đã được tạo, app đã compile hoặc coding agent nói “đã triển khai” làm bằng chứng thay cho hành vi cần kiểm. Một bài test mock không chứng minh model/Resolve/codec/quyền file thật hoạt động. Màn mock phải có nhãn dữ liệu mẫu và chỉ dùng để phát triển UI.

Tất cả các đường dẫn code trong tài liệu này là **cấu trúc đích cần tạo trong repository**, không phải mã nguồn đã có sẵn trong bộ Markdown. Các lệnh mẫu chỉ chạy sau khi target và công cụ tương ứng được triển khai trên môi trường phù hợp. Linux/container không thay việc thử bản macOS Release trên máy mục tiêu.

### 1.1. Quy tắc hoàn thành một bước

Một bước chỉ được đánh dấu xong khi có đủ:

1. Đầu ra đúng phạm vi và đúng tài liệu sở hữu hợp đồng.
2. Các kiểm thử hành vi quan trọng đạt trên đúng tầng; phần cần thiết bị/API thật đã chạy thật.
3. Không còn lỗi chặn thuộc bước; hạn chế khác được ghi rõ và không bị che bằng mock/fallback ngầm.
4. Có commit hoặc định danh bản code, môi trường, câu lệnh/cách thử và kết quả lưu được.
5. Người review xem được kết quả; sửa sau review làm chạy lại những kiểm tra chịu ảnh hưởng.

Các thay đổi thuần trình bày nhỏ không cần tạo unit test mô phỏng chính dòng code đó. Ưu tiên test ràng buộc, thay đổi trạng thái, crash windows, dữ liệu sai và đường đi người dùng thực sự cần.

### 1.2. Mẫu bằng chứng cho mỗi bước

Lưu biên bản ở `reports/progress/Sxx.md` và artifact kiểm thử trong thư mục tương ứng. Đây là file sẽ được tạo khi code; nội dung tối thiểu:

```text
Bước: Sxx
Trạng thái: NOT_STARTED | IN_PROGRESS | BLOCKED | IN_REVIEW | DONE
Build/commit:
Working tree diff hash, nếu chưa sạch:
Máy / macOS / Xcode / Swift:
Resolve / runtime / model manifest hash:
Schema / IPC / media / search / policy versions:
Dataset và fixture manifest hash:
Các yêu cầu nghiệm thu đã chạy:
Lệnh hoặc thao tác thử:
Kết quả từng ca: PASS | FAIL | NOT_RUN | BLOCKED
Đường dẫn log, ảnh, video, .xcresult hoặc báo cáo:
Lỗi/hạn chế còn lại:
Người review và ngày:
Quyết định chuyển bước và lý do:
```

Không ghi thông tin bí mật, toàn bộ video riêng tư hoặc token vào Git. Manifest fixture có thể chứa ID, hash và metadata đã làm sạch; media kiểm thử đặt ở vùng được phép và có quyền sử dụng.

### 1.3. Khi bị lỗi hoặc thay đổi thiết kế

- Nếu test trượt, giữ bước mở và mô tả hành vi thực tế; sửa nguyên nhân trước khi thử lại phạm vi liên quan.
- Nếu thiếu môi trường, đánh `BLOCKED`, ghi phần đã kiểm ở máy hiện tại và phép thử phải chuyển sang Mac.
- Nếu thay yêu cầu, tạo ADR theo [06](06-DECISIONS-AND-RISKS.md), sửa tài liệu sở hữu và đánh giá lại những bước bị ảnh hưởng.
- Nếu sửa prompt/model/profile sau khi xem kết quả holdout, không tiếp tục gọi cùng holdout là dữ liệu giữ kín cho quyết định đó.
- Nếu năng lực tùy chọn chưa đạt, giữ capability tắt, ghi trạng thái; không đánh dấu năng lực đạt vì fallback đã chạy.
- Những bước đã xong có thể cần mở lại khi dependency thay đổi. Lịch sử kết quả cũ vẫn giữ, không sửa để mang danh build mới.

## 2. Bảng tiến độ tổng

### G0 — Nền tảng chạy thật

- [ ] **S00** — Repository, bộ tài liệu và nơi lưu bằng chứng.
- [ ] **S01** — Khảo sát máy, ma trận hỗ trợ và manifest công cụ.
- [ ] **S02** — `.app` tối thiểu, worker và quyền file.
- [ ] **S03** — Resolve spike 10 giây và chạy offline.

### G1 — Dữ liệu và phục hồi

- [ ] **S04** — Hợp đồng dữ liệu, IPC và state machines.
- [ ] **S05** — Import, định danh và snapshot nguồn.
- [ ] **S06** — ProjectStore, revision, autosave và kiểm điều kiện ghi.
- [ ] **S07** — Scheduler, worker fencing và tài nguyên chung.
- [ ] **S08** — Công bố artifact và startup reconciliation.
- [ ] **S09** — Backup, restore, migration và dữ liệu đã commit.

### G2 — Phân tích và bằng chứng

- [ ] **S10** — Media index, VFR mapping, proxy và profile màu.
- [ ] **S11** — Model adapters, profile tài nguyên và setup offline.
- [ ] **S12** — Phân tích toàn frame, checkpoint và kiểm độ phủ.
- [ ] **S13** — Brief/facts, claims, event graph và verifier.
- [ ] **S14** — Review có bằng chứng và thay đổi phạm vi tư liệu.
- [ ] **S15** — Benchmark phân tích và khóa cấu hình G2.

### G3 — Kịch bản dựng được

- [ ] **S16** — Outline, script có nguồn, sửa tay và khóa.
- [ ] **S17** — TTS thử, speech check và căn thời gian.
- [ ] **S18** — Chọn shot có ràng buộc và chẩn đoán thất bại tìm kiếm.
- [ ] **S19** — Script approval theo đúng snapshot.

### G4 — Preview được duyệt

- [ ] **S20** — Resolve adapter, operation journal và timeline managed.
- [ ] **S21** — Preview, QC và preview approval.

### G5 — Final và phát hành

- [ ] **S22** — Final, QC sau render và project bàn giao.
- [ ] **S23** — Sáu nâng cấp và trạng thái capability trung thực.
- [ ] **S24** — Hoàn thiện UI macOS và accessibility.
- [ ] **S25** — Fault injection, tải dài và nghiệm thu E0/E1.
- [ ] **S26** — Release đóng gói, hồ sơ nghiệm thu và bàn giao.

Các mục trên theo dõi tiến độ tổng, không thay các ô con bên dưới. S23 phân biệt phần nền bắt buộc và capability nâng cao; một capability nâng cao bị hoãn phải hiện trong hồ sơ phát hành, không được tính là đã triển khai.

## 3. Cấu trúc repository đích

| Vị trí dự kiến | Nội dung |
|---|---|
| `docs/` | Bộ README và 01–11, giữ đúng tên để liên kết hoạt động. |
| `apps/macos/AIVideo.xcodeproj` | Target `.app`, schemes, UI tests, packaging và entitlements đã chọn. |
| `packages/AIVideoCore/` | Swift package cho ProjectStore, domain models, scheduler, IPC, dependencies và approval gates. |
| `workers/pyproject.toml` | Môi trường Python đã khóa, entrypoint worker và nhóm dependency theo khả năng. |
| `workers/src/aivideo_workers/` | Media, model, audio, Resolve adapter; không ghi canonical DB. |
| `contracts/` | JSON Schema, RPC schema và phiên bản policy thực thi. |
| `migrations/` | Migration có version, fixture database cũ và hướng dẫn recovery. |
| `fixtures/` | Manifest dữ liệu phát triển/giữ kín và fixture tổng hợp; không mặc định chứa media riêng tư trong Git. |
| `tests/` | Contract, integration, regression và fault-injection harness dùng chung. |
| `tools/qa/` | Validator và công cụ xuất báo cáo; tạo khi bước tương ứng cần. |
| `reports/progress/` | Biên bản S00–S26 và quyết định chuyển gate. |
| `reports/acceptance/` | Kết quả theo requirement ID, build và dataset. |

Tên module con có thể điều chỉnh bằng ADR khi có lý do. Quyền ghi, schema, semantics và bằng chứng nghiệm thu không thay chỉ vì đổi tổ chức thư mục. SQLite binding, Python packager và phiên bản dependency cụ thể phải được chọn sau phép thử G0, khóa bằng lockfile và ghi lý do; không cài theo `latest` mỗi lần chạy.

## 4. Prompt chung cho coding agent

Dùng prompt này trước prompt riêng của bước:

```text
Bạn đang triển khai AIVideo theo docs/README.md và bộ đặc tả v3.1.
Đọc bước Sxx trong docs/11-CODING-WORKFLOW-AND-CHECKLIST.md,
các tài liệu sở hữu hợp đồng của bước đó và trạng thái repository hiện tại.

Chỉ triển khai phạm vi bước được giao cùng thay đổi phụ thuộc cần thiết.
Giữ SwiftUI + Swift core + Python worker + SQLite + Resolve.
Core là nơi commit chuẩn; worker không duyệt artifact hay ghi canonical DB.
Không sửa nguồn người dùng, không giảm baseline toàn frame, không gọi cloud AI.
Không ghi đè chỉnh sửa của người dùng hoặc dùng lại approval sai revision.

Trước khi sửa: nêu ngắn đầu vào, đầu ra, rủi ro và phép kiểm có ý nghĩa.
Sau khi sửa: chạy kiểm tra đúng tầng, ghi kết quả thực và cập nhật biên bản Sxx.
Đánh dấu rõ mock, chưa chạy và blocked; không tạo PASS giả hoặc tự nới gate.
Đọc các quyết định đã chốt trước khi hỏi lại lựa chọn triển khai thông thường.
Nếu cần thay hợp đồng, mô tả xung đột và ADR; không tự đổi semantics để test pass.
Kết thúc bằng: đã làm gì, đã kiểm gì, bằng chứng ở đâu, còn thiếu gì,
và bước đã đủ điều kiện hoàn thành hay chưa.
```

## 5. G0 — Chứng minh nền tảng trước khi xây hệ thống lớn

### S00 — Tạo repository và sổ tiến độ

**Phụ thuộc:** chưa có. **Đọc:** README, 01, 05, 06 và tài liệu này.

**Đầu ra:** repository có bố cục khởi đầu, bộ v3.1 ở `docs/`, `reports/progress/S00.md`, quy tắc giữ media riêng tư và phạm vi E0 dự kiến.

**Công việc code/tổ chức**

- [ ] S00.1 — Kiểm tra repository hiện có và các sửa đổi chưa commit; chọn nhánh/worktree phù hợp, không ghi đè công việc đang có.
- [ ] S00.2 — Đặt đủ 12 tài liệu cạnh nhau; chọn tên app/bundle ID dùng cho bản thử, ghi đây là cấu hình dự án cần pin.
- [ ] S00.3 — Tạo bố cục đích và `.gitignore` cho model weights, media riêng tư, cache, build outputs và logs chứa dữ liệu cá nhân.
- [ ] S00.4 — Tạo mẫu biên bản bước, báo cáo nghiệm thu và quy tắc review trước khi đánh dấu DONE.

**Kiểm tra bắt buộc**

- [ ] S00.T1 — Mở được mọi liên kết nội bộ trong README và 11; không lẫn đặc tả v2 làm mặc định song song.
- [ ] S00.T2 — `git status` không chứa media/model/cache vô ý đưa vào; chưa có dòng báo ứng dụng đã đạt khi mới tạo tài liệu.
- [ ] S00.T3 — Một người khác/coding agent đọc được cách xác định bước hiện tại, hợp đồng sở hữu và nơi lưu bằng chứng.

**Điều kiện xong**

- [ ] S00.G — Có trạng thái repository có thể tiếp tục an toàn và biên bản S00; chưa tích các bước triển khai chưa chạy.

**Prompt bước:** “Thiết lập nền làm việc cho AIVideo v3.1 và sổ tiến độ. Kiểm tra trước các file đang có, giữ nguyên thay đổi của người dùng; chỉ tạo cấu trúc cần cho G0 và báo phần chưa triển khai.”

### S01 — Khảo sát môi trường và chốt ma trận thử

**Phụ thuộc:** S00. **Đọc:** 03, 05, 06, 09. **Requirement:** REL-01 và các điều kiện nền tảng của G0.

**Đầu ra:** `reports/progress/S01.md`, manifest máy/công cụ và ma trận capability ban đầu; mọi mục chưa thử mang trạng thái chưa xác nhận.

**Công việc**

- [ ] S01.1 — Ghi máy, RAM, phiên bản macOS, Xcode/Swift/SDK, Resolve/edition/API, dung lượng bytes thực và nơi đặt project.
- [ ] S01.2 — Chọn minimum OS theo giao điểm yêu cầu đã xác minh; ghi lý do, không chọn chỉ để có hiệu ứng UI.
- [ ] S01.3 — Kiểm FFmpeg/ffprobe, Python/ARM64, MLX/ONNX/whisper.cpp và model candidates theo config thật; chọn và khóa revision/checksum của ứng viên dùng cho smoke test G0 (g0-text-smoke-v1: mlx-community/Qwen3-0.6B-4bit); danh mục model cho pipeline giữ tại S11.
- [ ] S01.4 — Chọn chính sách đóng gói/phân phối thử local và sandbox hay không; nếu dự định phân phối ngoài máy cá nhân, ghi đường ký/notarization sẽ nghiệm thu ở S26.
- [ ] S01.5 — Chọn fixture E0 có quyền sử dụng; tính tổng thời lượng, asset, độ phân giải/fps và ngân sách snapshot/proxy/render/backup.

**Kiểm tra**

- [ ] S01.T1 — Bằng chứng môi trường lấy từ máy thật; không dùng Resolve 21.1.2, 117 GiB hoặc thư mục weights lịch sử làm số đo mới.
- [ ] S01.T2 — Dependency lock/manifest chỉ đến artifact thật có thể lấy trước; license/quyền dùng cần thiết được ghi nguồn.
- [ ] S01.T3 — Báo cáo rõ capability chưa xác minh và phép thử tiếp theo; không mặc định có detector âm thanh hoặc alignment chỉ vì có ASR.

**Điều kiện xong**

- [ ] S01.G — Có ma trận môi trường đủ để build spike; những phần chặn được xử lý hoặc ghi BLOCKED đúng lý do.

**Prompt bước:** “Khảo sát môi trường macOS thật, lập manifest và compatibility matrix cho G0. Phân biệt installed, callable và verified; chưa đo thì giữ chưa đo. Không tự nâng OS hay đổi model để che lỗi tương thích.”

### S02 — Bản `.app` tối thiểu, IPC và quyền file

**Phụ thuộc:** S01. **Đọc:** 05 mục IPC/authority, 10 mục file access/lifecycle. **Requirement:** JOB-04, UI-16..UI-19, OFF family.

**Đầu ra:** `.app` arm64 chạy từ Finder, worker được đóng gói theo phương án đã chọn, bằng chứng đọc nguồn và một lượt inference local nhỏ. Đây là spike dùng hợp đồng tối thiểu, sẽ hoàn thiện ở S04–S08.

**Công việc**

- [ ] S02.1 — Tạo shell native có project picker, nút chọn file và một màn tác vụ; mock hiển thị rõ, không giả tiến trình AI.
- [ ] S02.2 — Spawn Python worker không dựa vào shell startup/PATH cá nhân; triển khai handshake JSON-RPC/JSON Lines, stdout chỉ chứa protocol.
- [ ] S02.3 — Đọc video qua worker/ffprobe từ file picker; giữ/bookmark quyền theo chính sách đóng gói đã chọn và kiểm vòng đời quyền.
- [ ] S02.4 — Chạy một suy luận model local thật từ .app (G0 text smoke: Qwen3-0.6B-4bit trên MLX-LM); tách lỗi runtime, thiếu file, sai hash và thiếu quyền thành trạng thái khác nhau trên UI.
- [ ] S02.5 — Thoát app có thu hồi worker; chưa có feature nào được phép để worker chạy mồ côi vô hạn.

**Kiểm tra**

- [ ] S02.T1 — Mở từ Finder, không mở terminal chuẩn bị môi trường; kiểm đường dẫn Unicode và nguồn trên ổ ngoài phù hợp.
- [ ] S02.T2 — Thoát/mở lại rồi đọc nguồn đã chọn; stale bookmark hoặc mất quyền có hành động chọn lại rõ ràng.
- [ ] S02.T3 — Worker lỗi hoặc ghi dòng stdout sai định dạng không làm app giả thành công, không treo main actor.
- [ ] S02.T4 — Khởi động/chạy lại khi offline sau setup, ngắt mạng rồi lặp phép thử inference/ffprobe; không tải ngầm và không fallback cloud; phát hiện đúng thiếu artifact/runtime.

**Điều kiện xong**

- [ ] S02.G — Có `.app` tối thiểu và log chạy thật; quyết định đóng gói/IPC khả thi đã được ghi trước khi đầu tư UI lớn.

**Prompt bước:** “Làm spike `.app` native đọc được source qua worker đóng gói và chạy một model local. Chứng minh launch từ Finder, reopen quyền file và offline; không lấy chạy terminal thay kết quả bản app.”

### S03 — Resolve spike và đóng Gate G0

**Phụ thuộc:** S02. **Đọc:** 04, 05, 09. **Requirement:** RES-01, RES-05, OFF family.

**Đầu ra:** project/timeline thử 10 giây, preview/final thử, `.drp`, bảng API và codec thật sự hỗ trợ. Spike không được gắn nhãn là pipeline hoàn chỉnh.

**Công việc**

- [ ] S03.1 — Kết nối API Resolve thật từ worker trong `.app`; ghi version/API/thiết lập local scripting đang có.
- [ ] S03.2 — Tạo timeline 2160×3840, 24/1 trước khi thêm clip; query lại setting và ghi hành vi inclusive/exclusive in/out bằng fixture biết frame.
- [ ] S03.3 — Thêm video, voice và một title/overlay; render thử preview 1080 và final 2160 với codec/preset có thật.
- [ ] S03.4 — Export/mở lại `.drp`, ghi lớp nào sửa native được và lớp nào cần tái sinh từ text/style.
- [ ] S03.5 — Thử đọc lại ID/tracks/items/settings/render jobs cần cho reconciliation; ghi giới hạn API và fallback isolated rebuild khi không chứng minh được effect.

**Kiểm tra**

- [ ] S03.T1 — Frame đầu/cuối và audio offset đúng fixture; preset thực đúng kích thước/fps, không chỉ setter trả true.
- [ ] S03.T2 — Resolve chưa mở, mất kết nối hoặc codec không có trả lỗi có phạm vi; không dùng UI automation hoặc retry mù để giả API đã hỗ trợ.
- [ ] S03.T3 — Mở lại project và chạy lại từ `.app` khi offline; kiểm voice/title/media còn đủ để tái dựng.

**Điều kiện xong**

- [ ] S03.G — G0 có đủ bằng chứng máy, `.app`, worker, quyền file, inference, Resolve và offline. Mọi đường chưa hỗ trợ được khóa trong capability matrix.

**Prompt bước:** “Tạo Resolve spike 10 giây từ `.app`, đo chính xác mapping và mức sửa được, lưu capability report. Nếu một effect không query được, ghi giới hạn và phương án kiểm chứng, không giả định operation ID tự giải quyết idempotency.”

## 6. G1 — Xây nền dữ liệu có thể phục hồi

### S04 — Hợp đồng dữ liệu và state machines

**Phụ thuộc:** G0. **Đọc:** 02, 05, 06, 09. **Requirement:** DATA-04, JOB-04 và INV family.

**Đầu ra:** JSON Schemas thực thi, typed Swift/Python DTOs hoặc mapping được kiểm, SQL migrations khởi đầu, transition/decision tables và contract fixtures.

**Công việc**

- [ ] S04.1 — Chốt IDs/revisions, project/workday scope và các trục origin/epistemic/review/support/allowed-use đúng 02; narrative_type nằm ở lần dùng claim.
- [ ] S04.2 — Định nghĩa RPC envelope, schema/protocol versions, expected revision, attempt/fencing và đường dẫn artifact được phép.
- [ ] S04.3 — Viết state machine cho job/attempt/artifact/approval; kiểm trạng thái không hợp lệ thay vì cho UI tự đổi boolean.
- [ ] S04.4 — Biên dịch bảng quyết định được phép kể thành policy có version; phân biệt validator cấu trúc với semantic verifier.
- [ ] S04.5 — Tạo fixture JSON đúng/sai, claim nhiều mệnh đề, reported fact và approval sai scope; thêm công cụ contract validation.

**Kiểm tra**

- [ ] S04.T1 — Cùng payload được Swift và Python hiểu cùng nghĩa; trường/enum sai hoặc version không hỗ trợ bị từ chối rõ.
- [ ] S04.T2 — User-confirmed không đổi thành observed; chọn script không xác nhận fact; expired approval không được dùng cho revision khác.
- [ ] S04.T3 — Text từ OCR/filename/brief chứa chuỗi giống lệnh vẫn là dữ liệu; validator không phát sinh shell/code execution.

**Điều kiện xong**

- [ ] S04.G — Contract có test chạy được và owner rõ; các enum trong code khớp 02/05, không tồn tại hai nguồn chuẩn mâu thuẫn.

**Prompt bước:** “Hiện thực contracts và máy trạng thái của 02/05, kèm fixture chống nhầm nguồn/approval. Hãy kiểm các transition bị cấm và payload sai; không chỉ test serialize rồi deserialize chính đối tượng vừa tạo.”

### S05 — Import và snapshot nguồn theo content revision

**Phụ thuộc:** S04. **Đọc:** 02, 03, 05. **Requirement:** DATA-01, DATA-08, UI-24.

**Đầu ra:** manifest import, source revisions, snapshot store và preflight dung lượng có trạng thái.

**Công việc**

- [ ] S05.1 — Quét source được phép, ghi streams/metadata/lỗi; không di chuyển, sửa hoặc xóa original.
- [ ] S05.2 — Tạo bản snapshot bằng clone APFS đã kiểm hoặc copy xác minh; temp nằm trên filesystem đích; không dùng hardlink như bản bất biến.
- [ ] S05.3 — Ghi SHA-256, nguồn gốc và acquisition metadata; chỉ công bố snapshot sau kiểm ổn định nội dung theo 02/05.
- [ ] S05.4 — Deduplicate theo content identity và scope đúng; file trùng tên khác nội dung tạo source revision khác.
- [ ] S05.5 — Tính dung lượng thực/cần thiết, kể cả copy và rủi ro COW; thiếu chỗ thì pause và hướng dẫn, không âm thầm bỏ snapshot.

**Kiểm tra**

- [ ] S05.T1 — Original không đổi hash trước/sau import; Unicode, nguồn dời và file hỏng có xử lý đúng phạm vi.
- [ ] S05.T2 — Thay original sau khi seal không đổi bytes snapshot; thay trong lúc acquisition không dẫn đến snapshot được công bố với metadata trộn.
- [ ] S05.T3 — Kill/ổ đầy khi copy tạo bản tạm có thể dọn/reconcile; không ghi asset ready trỏ vào file thiếu.

**Điều kiện xong**

- [ ] S05.G — Mọi phân tích authoritative có thể đọc sealed source revision; chưa snapshot hợp lệ thì chưa cấp phép phân tích/render authoritative.

**Prompt bước:** “Làm import có source snapshot và content identity. Thử cả clone và fullcopy theo capability thực; giữ original an toàn, kiểm thay nguồn giữa chừng và thiếu SSD trước khi báo ready.”

### S06 — ProjectStore, revision và ghi có xác nhận

**Phụ thuộc:** S04–S05. **Đọc:** 02, 05, 10. **Requirement:** DATA-03, DATA-04, UI-07..UI-11, UI-16.

**Đầu ra:** canonical store, migration khởi đầu, save/confirmation commands và revision history; giao diện editor tối thiểu dùng store thật.

**Công việc**

- [ ] S06.1 — Tạo ProjectStore actor có quyền commit duy nhất cho project; worker không nhận connection hoặc quyền ghi DB chuẩn.
- [ ] S06.2 — Bật các SQLite pragmas đã chốt, giữ transaction ngắn; xử lý busy/storage failure, không chặn main actor bằng DB work.
- [ ] S06.3 — Lưu raw brief/draft và immutable revisions; lưu fact confirmation, script selection và approval thành các hành động khác nhau.
- [ ] S06.4 — Command sửa/duyệt kiểm expected revision và scope trong transaction; idempotency chống nhấn lặp và IPC mất ACK.
- [ ] S06.5 — UI hiển thị Đang lưu/Đã lưu/Lưu lỗi dựa ACK thật; flush trước chuyển project/duyệt; giữ buffer khi lỗi.

**Kiểm tra**

- [ ] S06.T1 — Hai command sửa/duyệt cạnh nhau không duyệt snapshot chưa xem; retry cùng command không nhân đôi dữ kiện/approval.
- [ ] S06.T2 — Result extraction từ brief cũ không ghi đè brief mới hoặc tự confirm fact mới.
- [ ] S06.T3 — Ổ đầy/quyền lỗi không báo đã lưu; dữ liệu đã commit còn đúng sau restart, phần chưa commit được báo trung thực.

**Điều kiện xong**

- [ ] S06.G — Có một authority commit rõ, revision history truy được và test race/ACK thật; view không giữ một business truth độc lập.

**Prompt bước:** “Xây ProjectStore và revision-aware commands. Kiểm interleaving sửa/duyệt/retry, lưu lỗi và AI trả kết quả cũ; tuyệt đối không coi autosave là fact confirmation hoặc artifact approval.”

### S07 — Scheduler, fencing và resource governor

**Phụ thuộc:** S06. **Đọc:** 03, 05, 10. **Requirement:** JOB-01..JOB-05.

**Đầu ra:** durable job queue, attempt lifecycle, global resource governor và process supervisor.

**Công việc**

- [ ] S07.1 — Persist logical job và từng attempt với input fingerprint, fencing token, session/lease identity và trạng thái được phép.
- [ ] S07.2 — Hủy/restart thu hồi quyền publish trước khi thay attempt; kiểm quyền lần nữa tại canonical commit.
- [ ] S07.3 — Giám sát worker bằng heartbeat/process handle; heartbeat mất chỉ là nghi vấn, không chứng minh bộ nhớ đã được giải phóng.
- [ ] S07.4 — Global heavy lease dùng chung mọi cửa sổ/project; không cấp lease nặng mới khi tiến trình cũ chưa được thu hồi hoặc reconcile.
- [ ] S07.5 — Giới hạn stdout/stderr/IPC/buffers và tiến trình con; pause/checkpoint do RAM/SSD có lý do, không dùng timeout làm kết luận AI đã đạt.

**Kiểm tra**

- [ ] S07.T1 — Hủy attempt A, chạy B rồi A gửi result muộn: A không được commit hoặc sửa approval.
- [ ] S07.T2 — Mở hai project, yêu cầu inference/render đồng thời: vẫn tuân global heavy lease và UI tiếp tục nhận thao tác.
- [ ] S07.T3 — Worker treo, mất IPC hoặc sống sau core restart không tạo worker mồ côi/nạp model trùng; recovery giải thích được trạng thái.

**Điều kiện xong**

- [ ] S07.G — Scheduler chạy qua các interleaving rủi ro có log job/attempt/lease; mọi đường publish đều kiểm fencing.

**Prompt bước:** “Triển khai durable scheduler và process supervision. Dùng các ca worker cũ trả muộn, IPC mất ACK, hai project và heavy process chưa chết để chứng minh quyền publish và lease không bị lẫn.”

### S08 — Công bố artifact và reconcile sau crash

**Phụ thuộc:** S05–S07. **Đọc:** 05, 02. **Requirement:** DATA-02, DATA-08, RES-02 phần intent nền.

**Đầu ra:** artifact publication service, durable intent journal, startup reconciler và fault hooks theo từng ranh giới.

**Công việc**

- [ ] S08.1 — Persist intent/manifest trước công việc; ghi output vào thư mục riêng của attempt, không đè artifact đã commit.
- [ ] S08.2 — Thực hiện PREPARED → MATERIALIZED → VERIFIED → COMMITTED; checksum, durable flush và rename trên đúng filesystem theo 05.
- [ ] S08.3 — Chỉ transaction canonical mới gắn artifact vào revision; kiểm attempt authority và dependency fingerprint trước commit. Khi đủ output, commit job completion/idempotency/checkpoint trong cùng transaction theo 05.
- [ ] S08.4 — Reconcile temp dở, file final chưa được DB tham chiếu, intent pending, stale attempt và artifact mất/hỏng.
- [ ] S08.5 — Pins giữ evidence/WAV/graphics đã duyệt và file backup tham chiếu; quota cache không xóa chúng.

**Kiểm tra**

- [ ] S08.T1 — Chèn crash trước/sau từng ranh giới, restart và xác minh một kết quả hợp lệ hoặc trạng thái blocked rõ; không có COMMITTED trỏ tới bytes thiếu. Artifact đã commit nhưng checkpoint còn cũ phải được đối chiếu để phục hồi completion, không chạy lại mù.
- [ ] S08.T2 — Cùng logical job retry không ghi đè artifact đang được approval dùng; kết quả orphan không tự được coi là đã duyệt.
- [ ] S08.T3 — Làm hỏng artifact sau commit bị phát hiện và chặn phần phụ thuộc; không tái sinh audio khác rồi giữ approval cũ.

**Điều kiện xong**

- [ ] S08.G — Có bảng crash windows với expected/observed và bằng chứng từng ca; không chỉ chứng minh happy path.

**Prompt bước:** “Hiện thực protocol publication của 05 và startup reconciler. Đặt fault hooks ở các ranh giới thật giữa DB và filesystem; chứng minh recovery giữ canonical state đúng thay vì chỉ bắt exception.”

### S09 — Backup, restore và migration; đóng G1

**Phụ thuộc:** S08. **Đọc:** 05, 06, 09. **Requirement:** DATA-06, DATA-07, DATA-08, UI-26.

**Đầu ra:** backup modes, manifest/pins, restore tool hoặc UI tối thiểu, migration journal và báo cáo phục hồi vào thư mục mới.

**Công việc**

- [ ] S09.1 — Thiết lập ranh giới snapshot nhất quán trước khi chọn root, tính toàn bộ references và pins; DB backup, manifest và tập artifact phải thuộc cùng snapshot theo 05. Không copy lẻ DB đang có WAL rồi coi đủ.
- [ ] S09.2 — Phân biệt checkpoint_backup và portable_backup; khai báo source/runtime/model nào cần có để restore và chạy lại offline.
- [ ] S09.3 — Tạo backup trước migration, tại approval boundaries và theo lịch active-editing đã công bố; retry backup lỗi không xóa bản tốt cuối.
- [ ] S09.4 — Restore vào nơi mới, kiểm database/foreign keys/hash/refs và quyền source; chỉ cho mở khi kết quả nhất quán.
- [ ] S09.5 — Migration có preflight, trạng thái và đường phục hồi; app cũ gặp schema mới không tự sửa/hạ schema.

**Kiểm tra**

- [ ] S09.T1 — Restore giữ brief, facts, resolutions, approvals, edit plan và bytes đã pin; kiểm nội dung và revision, không chỉ mở DB thành công. Cho commit cạnh tranh với backup để chứng minh DB không chứa reference mới ngoài manifest/pins của snapshot.
- [ ] S09.T2 — Kill giữa migration/backup và hết SSD: project gốc hoặc bản phục hồi vẫn có đường mở hợp lệ, lỗi được báo.
- [ ] S09.T3 — Portable backup thiếu source hoặc checkpoint backup thiếu runtime nêu đúng prerequisite; không hứa khôi phục đầy đủ từ dữ liệu không có.

**Điều kiện xong**

- [ ] S09.G — G1 đạt bằng chứng commit/recovery/restore/migration và các invariants liên quan; chưa mở rộng AI khi nền dữ liệu còn mất trạng thái.

**Prompt bước:** “Xây backup/restore theo 05 và thử restore thật sang thư mục mới. Ghi rõ mức portable và các prerequisite; kiểm cả migration gián đoạn, checksum sai và dữ liệu đã duyệt.”

## 7. G2 — Hiểu nguồn và giữ bằng chứng đúng

### S10 — Chỉ mục media, VFR mapping và profile màu

**Phụ thuộc:** G1. **Đọc:** 02, 04, 07, 09. **Requirement:** MEDIA-01 và MEDIA family.

**Đầu ra:** PTS index, proxy/conform mapping có version, profile `M-24-SDR-v1` và fixture timecode/audio/màu có đáp án độc lập.

**Công việc**

- [ ] S10.1 — Decode source snapshot theo presentation order; giữ stream/timebase/PTS và rotation thực, không suy frame bằng fps trung bình.
- [ ] S10.2 — Chuẩn hóa khoảng `[start,end)` và phép chuyển tới inclusive/exclusive của API đã probe; lưu rounding và mapping source→proxy→timeline.
- [ ] S10.3 — Tạo proxy có thông tin đối chiếu, không dùng proxy mờ làm bằng chứng chữ nhỏ; audio canonical 48 kHz có mapping offset rõ.
- [ ] S10.4 — Conform 24/1 có quy tắc chọn/lặp/bỏ frame xác định và được hiện thực trong artifact media có hash/mapping để Resolve dùng. Native conform chỉ được bật khi fixture chứng minh cùng mapping theo 04; không optical-flow/interpolation sinh thêm nội dung trong MVP.
- [ ] S10.5 — Áp SDR Rec.709 output; chỉ nhận HDR khi metadata và tone-map path đã qua fixture, nguồn không rõ trả unsupported/needs decision.

**Kiểm tra**

- [ ] S10.T1 — CFR/VFR, nguồn 29.97/30/60 fps và rotation cho đúng frame boundary trên fixture; so với PTS đã giải mã độc lập.
- [ ] S10.T2 — Flash/cử chỉ ngắn chứa bằng chứng không bị mất khỏi shot được dùng; nếu conform làm mất, phải đổi phương án có revision hoặc chặn.
- [ ] S10.T3 — Sync đầu/cuối, drift và màu theo tolerance MEDIA trong 09; kiểm pixel/render thật, không chỉ metadata.
- [ ] S10.T4 — Seek tới source từ timeline dùng đúng mapping/revision; thay proxy không trộn PTS với millisecond hiển thị.

**Điều kiện xong**

- [ ] S10.G — Có mapping tái truy xuất được và báo cáo ca media khó; các định dạng chưa đạt nằm ngoài capability công bố.

**Prompt bước:** “Xây timebase/media mapping từ PTS thực và profile M-24-SDR-v1. Kiểm bằng clip có số frame, flash và audio marker đã biết; chứng minh quy ước biên cắt, drift và xử lý HDR thay vì chỉ kiểm file xuất mở được.”

### S11 — Model adapters và profile tài nguyên

**Phụ thuộc:** S10 và G0. **Đọc:** 03, 05, 08. **Requirement:** JOB-02, JOB-05, OFF family.

**Đầu ra:** adapters model/ASR/TTS/embedding có typed outputs, installation manifest đầy đủ, runtime profile khóa và memory trace của các lượt thử.

**Công việc**

- [ ] S11.1 — Tạo interfaces riêng cho vision, text, ASR, TTS và embedding; capability chưa có backend không giả dữ liệu trả về.
- [ ] S11.2 — Chuẩn bị đủ model, weights, processor, tokenizer, codec, phonemizer, preset và dependencies cho toàn bộ các adapter phục vụ pipeline E0; verify checksum và local paths, không tải lúc chạy project.
- [ ] S11.3 — Đo grid profile phát triển của 03 trên source thật; ghi frame/pixel/token thực sau processor, peak RAM/swap và memory pressure.
- [ ] S11.4 — Đóng process trả bộ nhớ giữa pha AI/Resolve; chỉ kích hoạt profile đã qua ngân sách chung, không ép model 32B trên 16 GB.
- [ ] S11.5 — Capability registry phân biệt candidate/validated/disabled; SED/alignment/tracker chưa đạt có fallback đúng nghĩa đã đặc tả.

**Kiểm tra**

- [ ] S11.T1 — Ngắt mạng sau setup, kiểm offline từng adapter cần cho E0 (Qwen-VL, Whisper, VieNeu-TTS, DINOv2); artifact thiếu gây lỗi cụ thể, không cloud fallback.
- [ ] S11.T2 — Backend truncate/sample frame bị phát hiện qua post-processor audit; không báo đủ coverage từ danh sách định gửi.
- [ ] S11.T3 — Lặp nạp/thoát model và AI↔Resolve phases; kiểm process/lease/memory thực, không chỉ MLX allocator statistic.
- [ ] S11.T4 — Lỗi output JSON/schema hoặc tiếng Việt không hợp lệ không được ghi thành claim/voice đạt.

**Điều kiện xong**

- [ ] S11.G — Có profile phát triển đo được và runtime manifest pin; trạng thái đạt chất lượng nhiệm vụ chỉ cấp sau benchmark tương ứng.

**Prompt bước:** “Hiện thực model adapters và setup offline theo 03. Đo memory toàn hệ thống, xử lý input processor thật và vòng giải phóng process; giữ mọi thông số chưa đo là chưa đo, không suy từ dung lượng weights.”

### S12 — Phân tích mọi frame và checkpoint theo cửa sổ

**Phụ thuộc:** S10–S11. **Đọc:** 02, 07, 08. **Requirement:** AI frame coverage/omission và JOB-03.

**Đầu ra:** pipeline nhiều thang thời gian, observation/evidence artifacts, coverage records và resume trên cửa sổ đã commit.

**Công việc**

- [ ] S12.1 — Quét tổng quan và lượt chi tiết toàn frame với batch nhỏ chồng lấn; queue/buffer hữu hạn, không lưu toàn bộ frame 4K ra SSD.
- [ ] S12.2 — Ghi frameID/PTS/crop/resolution thực vào model; hợp các ID duy nhất để tính coverage, không cộng trùng overlap.
- [ ] S12.3 — Giữ quan sát đầu tiên độc lập với câu chuyện kỳ vọng trong brief; guided revisit lưu vai trò riêng, không viết đè quan sát ban đầu.
- [ ] S12.4 — Merge cửa sổ dựa trên source/interval/đối tượng có uncertainty; truy xuất context dài, không chỉ nối các bản tóm tắt.
- [ ] S12.5 — ASR/audio chạy theo nhánh riêng; no_audio/no_speech không chặn hình; omission audit quay lại nguồn và các biên batch.
- [ ] S12.6 — Checkpoint sau đơn vị đã commit; resume dùng đúng profile/input revisions, phần lỗi decode giữ interval và mẫu số báo cáo trung thực.

**Kiểm tra**

- [ ] S12.T1 — Clip im lặng/khôngaudio, hành động ngắn, chữ nhỏ và sự kiện ở biên cửa sổ được xử lý đúng; coverage và hiểu đúng báo riêng.
- [ ] S12.T2 — Kill giữa hai cửa sổ rồi resume: không mất vùng, không cộng duplicate thành coverage cao hơn, không lẫn profile cũ/mới.
- [ ] S12.T3 — Dùng brief cố gợi sai tên biển mờ: lượt quan sát gốc không bị sửa để khớp lời gợi ý.
- [ ] S12.T4 — Working-set RAM, hàng đợi và log buffer trong bộ nhớ có giới hạn. PTS index, coverage, observations và audit log trên đĩa được phép tăng theo tư liệu nhưng phải được dự trù/quản lý; thiếu tài nguyên trả blocked_resource và checkpoint phù hợp.

**Điều kiện xong**

- [ ] S12.G — Coverage thực được kiểm toán, lỗi có phạm vi và resume đúng; chưa gọi “hiểu 100%” khi mới đủ frame.

**Prompt bước:** “Xây pipeline toàn frame với coverage sau processor và checkpoint. Dùng clip im lặng, biên cửa sổ và brief gợi sai để kiểm; phân biệt đủ input, job xong và hiểu đúng trong cả dữ liệu lẫn UI.”

### S13 — Facts, claims, event graph và semantic verifier

**Phụ thuộc:** S12; có thể phát triển schema/policy fixture sớm sau S04. **Đọc:** 02, 07, 08. **Requirement:** AI-03..AI-05, DATA-04, DATA-05.

**Đầu ra:** parser brief, fact drafts, atomic claims, evidence relations, event graph và verifier assessments theo policy version.

**Công việc**

- [ ] S13.1 — Tách facts, preferences và constraints từ raw brief; giữ source spans, workday/time precision, phủ định và từ “khoảng/chưa chắc”.
- [ ] S13.2 — Tách mệnh đề và quan hệ trước/sau/nhân quả; evidence hỗ trợ từng phần, context_only không thành supports ngầm.
- [ ] S13.3 — Thực thi decision table 02 với criticality, user confirmation, contradictory evidence và allowed_use có version.
- [ ] S13.4 — Tạo partial-order event graph, phát hiện chu trình/mâu thuẫn và ứng viên same-session; không gộp theo tên file/trang phục.
- [ ] S13.5 — Lưu evidence_scope_revision và query manifests; thêm source làm scope-sensitive assessments pending revalidation, không xóa quan sát cũ.
- [ ] S13.6 — Đánh giá verifier bằng oracle có nguồn độc lập; lưu lý do accepted/qualified/excluded và phản chứng đã kiểm.

**Kiểm tra**

- [ ] S13.T1 — “Quay đầu vì GPS” bị tách và chặn nhân quả nếu chỉ có hình quay đầu; lời người dùng xác nhận vẫn reported.
- [ ] S13.T2 — Một câu nhiều mệnh đề có evidence cho một phần không vượt gate toàn câu; thêm citation hợp lệ không tự nâng support.
- [ ] S13.T3 — Thêm clip phản bác hoặc bổ sung evidence mới làm xét lại đúng scope; không chỉ đi theo cạnh tới asset cũ.
- [ ] S13.T4 — Hai ngày cùng địa điểm, đồng hồ lệch và quan hệ before có vòng được giữ mơ hồ/review thay vì tự chọn chronology thuận câu chuyện.

**Điều kiện xong**

- [ ] S13.G — Kết luận truy được về snapshot/revisions và policy; false accepts/unknown được ghi thật, chưa dùng confidence chưa hiệu chuẩn để vượt gate.

**Prompt bước:** “Hiện thực facts/claims/event graph và bảng allowed_use của 02. Kiểm counterevidence, causal claims, user-confirmed và thêm source mới vào phạm vi tìm kiếm; ưu tiên false acceptance hơn việc tạo nhiều đoạn phân tích đẹp.”

### S14 — UI review có bằng chứng và cập nhật đúng scope

**Phụ thuộc:** S13 và store thật S06. **Đọc:** 01, 02, 10. **Requirement:** DATA-05, UI-06..UI-13, UI-27 và phần thao tác review của UI-28. Nghiệm thu toàn workday, final/manual handoff và restore của UI-28 thực hiện ở G5.

**Đầu ra:** màn Ngày làm việc/Cần làm rõ dùng dữ liệu thật, resolution commands và impact view theo dependencies.

**Công việc**

- [ ] S14.1 — Hiển thị ghi chú, fact drafts và trạng thái lưu tách biệt; batch confirmation chỉ áp tập revisions đã hiển thị/chọn.
- [ ] S14.2 — Mỗi câu hỏi có nguồn đúng loại/revision và ảnh hưởng lên phương án; ngữ cảnh trước/sau theo thời gian chỉ áp cho video/audio. Review từ ảnh dùng ảnh/vùng liên quan, review chỉ từ brief dùng đoạn chữ và scope tương ứng; câu hỏi trung tính, không gợi nguyên nhân chưa biết.
- [ ] S14.3 — Hỗ trợ trả lời, sửa, unknown, bỏ claim hoặc loại asset khỏi dựng; lưu resolution không tự xác nhận mọi fact phát sinh.
- [ ] S14.4 — Giữ item/focus đang đọc khi có kết quả nền; câu trả lời cùng revision không bị hỏi lặp vô ích.
- [ ] S14.5 — Khi corpus đổi, hiển thị đang đối chiếu lại phần liên quan; tiếp tục job độc lập, giữ bản duyệt lịch sử đúng nhãn.

**Kiểm tra**

- [ ] S14.T1 — Trả lời không biết không thành đồng ý; core issue chỉ chặn nhánh phụ thuộc và có phương án bỏ/đổi góc kể khi hợp lệ.
- [ ] S14.T2 — Review từ ảnh hoặc chỉ từ brief dùng đúng ảnh/vùng hoặc đoạn chữ và revision, không bị ép có timecode/clip minh họa làm evidence; khi có media theo thời gian, source time và timeline time luôn phân biệt.
- [ ] S14.T3 — Vừa gõ tiếng Việt vừa nhận result cũ không mất dấu/caret/nội dung; confirm nhóm không lẫn item mới xuất hiện.
- [ ] S14.T4 — Đo câu hỏi trùng, độ hữu ích và thời gian thao tác thực; chưa áp một ngưỡng tải review do phỏng đoán.

**Điều kiện xong**

- [ ] S14.G — Người dùng có thể xử lý một workday thật mà không phải tự tìm toàn bộ source; mọi resolution/confirmation có scope rõ.

**Prompt bước:** “Nối màn brief/review với core thật. Kiểm gõ tiếng Việt khi job cập nhật, confirm batch thay đổi nền, unknown, thêm clip và review chỉ từ ảnh/brief đúng revision; UI phải nói đúng trạng thái mà backend đã commit.”

### S15 — Benchmark phân tích và đóng G2

**Phụ thuộc:** S10–S14. **Đọc:** 06, 08, 09. **Requirement:** AI-03 tại `analysis_eligible`, AI-04, AI-05 và REL-01. REL-02 completion chỉ nghiệm thu ở G5 khi có pipeline đầy đủ.

**Đầu ra:** dataset manifests, labeling guide, frozen evaluation policy, runner/report và quyết định đạt/trượt G2.

G2 dùng claim-use assessment harness theo bảng quyết định 02 để kiểm checkpoint `analysis_eligible`; đây chưa phải chất lượng kịch bản. G3 đo `script_ready`, G5 đo final và completion. Báo tách từng checkpoint; chỉ số chưa đến giai đoạn đo ghi `NOT_RUN` có kế hoạch, không làm G2 phụ thuộc vòng vào final chưa được code.

**Công việc**

- [ ] S15.1 — Tách development và holdout theo chuyến/workday; nhóm frame/clip cùng ngữ cảnh không chia ngẫu nhiên để tạo test dễ.
- [ ] S15.2 — Gán nhãn sự kiện quan trọng quan sát được, atomic claim/use, mâu thuẫn và điều không thể biết; có quy trình giải quyết bất đồng.
- [ ] S15.3 — Đo profile trên development, khóa model/prompt/media/thresholds và manifest trước đánh giá holdout theo 09.
- [ ] S15.4 — Báo precision hỗ trợ claim tại `analysis_eligible`, critical false accepts, recall sự kiện, verifier false accepts, coverage, unknown và mức sử dụng trong harness; giữ đúng mẫu số và checkpoint.
- [ ] S15.5 — Báo cỡ mẫu và uncertainty theo workday độc lập; các ngưỡng v0.1 là mục tiêu, chưa chạy không ghi PASS.

**Kiểm tra**

- [ ] S15.T1 — Runner phát hiện một fixture cố tình sai nhãn nguồn/quan hệ và không cho qua chỉ vì schema đúng.
- [ ] S15.T2 — Harness từ chối gần hết không được báo chất lượng tốt chỉ bằng precision; báo số claim/event được dùng, unknown và từ chối. Completion/abstention cấp project để `NOT_RUN` tới phép thử end-to-end G5.
- [ ] S15.T3 — Không có data leakage qua prompt examples, preference profile hoặc cached summaries từ holdout vào tuning.
- [ ] S15.T4 — Mọi lỗi quan trọng có evidence tái mở được và được đưa vào quyết định gate, không loại mẫu khó khỏi tập sau khi thấy fail.

**Điều kiện xong**

- [ ] S15.G — G2 đạt các ca đúng giai đoạn theo 09 trên phạm vi đã công bố hoặc giữ BLOCKED với nguyên nhân. Các gate script/TTS/photo-exact/final chưa đến giai đoạn không được báo đã đạt. Thay policy sau khi xem holdout đòi quy trình đánh giá mới.

**Prompt bước:** “Tạo và chạy benchmark G2 theo 09, khóa cấu hình trước holdout. Báo đầy đủ mẫu số, false accepts, recall, unknown và uncertainty; nếu fail hãy nêu nguyên nhân và bước sửa, không điều chỉnh ngưỡng để hợp kết quả đã thấy.”

## 8. G3 — Kịch bản có thể dựng và được duyệt đúng bản

### S16 — Outline, script có nguồn và quyền sửa tay

**Phụ thuộc:** G2. **Đọc:** 01, 02, 04, 07. **Requirement:** STORY family, DATA-04.

**Đầu ra:** story candidates/script revisions có schema, câu–claim–beat–shot liên kết, constraint store và trang chỉnh script. Ở bước này phương án chưa đủ TTS/cut phải mang nhãn đang kiểm khả thi.

**Công việc**

- [ ] S16.1 — Lập allowed fact/evidence set theo scope và policy; sinh outline có khác biệt thật, lọc giả định/nhân quả thiếu hỗ trợ.
- [ ] S16.2 — Phát triển 1–3 script; tư liệu chỉ đủ một thì giữ một, không tạo cao trào để đủ số lượng/thời lượng.
- [ ] S16.3 — Mỗi câu liên kết atomic claims/narrative_type, mỗi beat liên kết shot candidates và vai trò chứng minh/minh họa.
- [ ] S16.4 — Chỉnh lời/fact/quan hệ tạo đúng revision/dependencies; AI proposal thành diff, không ghi đè phần đang gõ.
- [ ] S16.5 — Lưu must_use/must_not_use/preferred và callback có chủ ý; profile gu rõ ràng không ghi đè sự thật hoặc khóa.

**Kiểm tra**

- [ ] S16.T1 — Tư liệu nghèo cho một script hợp lệ hoặc báo thiếu; “hài” không đưa thêm động cơ/sự cố như thật.
- [ ] S16.T2 — Chỉnh fact trong editor không chỉ đổi chuỗi UI mà cập nhật knowledge revision và invalidation liên quan.
- [ ] S16.T3 — Câu lời bình khôngliteral có tiền đề factual sai bị phát hiện; B-roll không bị trình bày như bằng chứng chính xác.

**Điều kiện xong**

- [ ] S16.G — Script có đủ hợp đồng để S17/S18 kiểm khả thi; không gắn nhãn đã duyệt hoặc có thể dựng trước các gate đó.

**Prompt bước:** “Xây story/script pipeline có nguồn theo 04. Kiểm tư liệu nghèo, câu nhiều mệnh đề, sửa tay và khóa; AI được sáng tạo cách kể trong tập hợp lệ nhưng không bổ sung sự kiện để đạt cấu trúc.”

### S17 — TTS thử, speech check và alignment

**Phụ thuộc:** S16, adapter S11. **Đọc:** 03, 04, 07. **Requirement:** STORY/AI/MEDIA nhóm speech và timing.

**Đầu ra:** WAV thật cho từng phương án đủ điều kiện, speech-check findings, alignment và duration gắn script/voice revision.

**Công việc**

- [ ] S17.1 — Chọn preset thực có trong revision đã pin; tốc độ 1×, số/tên/viết tắt xử lý theo pronunciation policy giữ nguyên nghĩa.
- [ ] S17.2 — Tổng hợp audio thử, đo duration/pause thật; không dùng số chữ để chứng nhận thời lượng dựng.
- [ ] S17.3 — Kiểm mất/lặp từ, số, tên riêng, clipping và phát âm; ASR đối chiếu là công cụ tìm lỗi, không tự chứng nhận đúng.
- [ ] S17.4 — Căn phrase/word theo WAV cuối và nhãn kiểm độc lập; giữ caption/beat cues theo audio revision.
- [ ] S17.5 — Lưu WAV theo content hash; đổi text/preset/pronunciation làm stale các timing/cut/caption/mix phụ thuộc.

**Kiểm tra**

- [ ] S17.T1 — Fixture bỏ/lặp từ, đọc sai số/tên tạo finding hoặc review đúng đoạn; không pass chỉ vì có audio stream.
- [ ] S17.T2 — Một câu sửa làm lại đúng audio/timing downstream; duration cũ không được gắn cho lời mới.
- [ ] S17.T3 — Artifact voice đã được dùng trong snapshot được pin; thử tái sinh cùng config không mặc định được kế thừa approval.
- [ ] S17.T4 — Audio dài vượt giới hạn tạo đề nghị sửa script để duyệt, không cắt câu hoặc tăng tốc ngầm.

**Điều kiện xong**

- [ ] S17.G — Các phương án chuyển sang chọn cut có WAV đã kiểm và timing có nguồn; đoạn chưa chắc vẫn có review/block rõ.

**Prompt bước:** “Hiện thực TTS trial và speech/alignment checks bằng WAV thật. Giữ giọng 1×, tên/số đúng nghĩa và artifact bytes có hash; không dùng ASR đồng ý làm bằng chứng giọng hoàn hảo.”

### S18 — Tìm cut có ràng buộc, phân biệt lý do thất bại

**Phụ thuộc:** S16–S17. **Đọc:** 07 mục search, 04, 09. **Requirement:** STORY-03 và MEDIA mapping.

**Đầu ra:** finite candidate generator, `SEARCH-v1`, solver trace, edit-plan candidates và lý do kết thúc đúng bản chất.

**Công việc**

- [ ] S18.1 — Tạo tập shot/in-out/crop/role hợp lệ theo source snapshots và voice schedule; tính sốframe timeline, overlap và chuyển cảnh đúng.
- [ ] S18.2 — Áp hard constraints trước scoring: claim support, khóa, source range, chronology, thông tin cần nhìn thấy và duration.
- [ ] S18.3 — Triển khai beam với state/cost/beamwidth/budget và cấu hình forward check/repair/fallback có version; log pruning theo constraint hay giới hạn beam cùng thành phần điểm, không tự nhận tối ưu toàn cục.
- [ ] S18.4 — Trả các trạng thái SOLUTION_FOUND/SEARCH_BUDGET_EXHAUSTED/CANDIDATE_SET_EXHAUSTED/PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN đúng 07.
- [ ] S18.5 — Có mở rộng ứng viên/beam hoặc kiểm khả thi trên miền nhỏ; khóa cấu hình ba fixture STORY-03 theo 07/09 để tách lượt pruning, forward check và exact proof. Chỉ nói ràng buộc chắc chắn xung đột khi có chứng cứ tương ứng; cấu hình cô lập fixture không tắt hard constraints hoặc đổi profile phát hành.

**Kiểm tra**

- [ ] S18.T1 — `BEAM-PRUNING-v1`: A/B/C theo 07/09, A > B, beam width 1; lượt đầu tắt forward check nhìn trước, repair/backtracking, tự mở rộng beam/candidates và exact checker. Trace phải ghi B bị bỏ do beam rồi A → C bị từ chối vì lặp X; trả `SEARCH_BUDGET_EXHAUSTED`, không báo vô nghiệm/đòi mở khóa. Lượt phục hồi widen/exact trên cùng miền/constraints phải tìm B → C, qua validator và trả `SOLUTION_FOUND`.
- [ ] S18.T2 — So với exhaustive oracle trên fixture nhỏ; solver không xuất lời giải vi phạm hard constraints dù score cao.
- [ ] S18.T3 — `BEAM-UNSAT-v1`: miền chỉ A/C, cấm lặp X; chỉ exact checker kiểm đầy đủ mới trả `PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN`, kèm domain snapshot/hash, phiên bản checker và bằng chứng. Hết budget không là chứng minh; khóa xung đột thật có giải thích phạm vi và không bị tự mở để thuật toán có nghiệm.
- [ ] S18.T4 — TTS pause/transition overlap và callback được tính đúng; clip im lặng có tình tiết vẫn được chọn khi phù hợp.
- [ ] S18.T5 — `BEAM-FORWARD-v1`: cùng A/B/C và beam width 1, bật forward check có căn cứ trước khi cắt beam; loại A vì beat 2 không còn option hợp lệ, giữ B và tìm B → C. `SOLUTION_FOUND` ngay sau validator là PASS; không ép tạo thất bại hoặc chạy fallback không cần thiết.

**Điều kiện xong**

- [ ] S18.G — Chỉ phương án có WAV/cut hợp lệ được trình như dựng được; mọi thất bại tìm kiếm được diễn đạt trung thực và ba fixture STORY-03 có evidence đúng kết quả yêu cầu, không ép solver thất bại giả.

**Prompt bước:** “Xây solver có hard constraints và termination reasons của 07. Kiểm riêng BEAM-PRUNING-v1, BEAM-FORWARD-v1 và BEAM-UNSAT-v1 theo 07/09: tái hiện B bị prune rồi phục hồi, chấp nhận nghiệm tìm được ngay nhờ forward check, và chỉ exact checker đầy đủ mới chứng minh vô nghiệm trong miền. Giữ exact oracle nhỏ và trace; không ép thất bại giả hoặc buộc người dùng sửa kịch bản vì beam width quá hẹp.”

### S19 — Duyệt script theo snapshot; đóng G3

**Phụ thuộc:** S16–S18. **Đọc:** 01, 02, 04, 05, 09, 10. **Requirement:** DATA-04, AI-03 tại `script_ready`, UI-09..UI-11 và STORY approval.

**Đầu ra:** script approval command/gate, dependency manifest và UI diff/đang duyệt bản nào.

**Công việc**

- [ ] S19.1 — Hiển thị 1–3 phương án thực có lời, storyboard, duration thật và source/cách dùng; chọn bản chỉ là selection.
- [ ] S19.2 — Approval mang script revision, claim/fact revisions, constraints, storyboard và voice trial liên quan đã tồn tại; không tham chiếu artifact tương lai chưa sinh.
- [ ] S19.3 — Kiểm expected revision/fingerprint, facts cần xác nhận và mọi blocker trong canonical transaction trước commit.
- [ ] S19.4 — Sửa fact/claim/script/voice theo dependency policy tạo stale/diff và cổng duyệt phù hợp; không tự tái gắn approval cũ.
- [ ] S19.5 — Chặn render preview từ script chưa đủ điều kiện; giữ khả năng mở bản lịch sử và sửa một nhánh mới.

**Kiểm tra**

- [ ] S19.T1 — Chọn script không tự duyệt; duyệt script không xác nhận fact ngoài phạm vi.
- [ ] S19.T2 — Fact thay đúng lúc click duyệt trả conflict có diff; nhấp đúp/retry không tạo approval trùng.
- [ ] S19.T3 — Sửa dữ kiện không liên quan không làm stale mọi thứ; thêm evidence trong scope liên quan phải hoàn tất revalidation trước gate.
- [ ] S19.T4 — Đo AI-03 tại `script_ready` trên mọi phương án thực sự trình chọn: báo cáo `accepted_claim_support_precision`, `critical_false_accept_count`, mẫu số và khoảng bất định theo 09. Giữ kết quả riêng với harness `analysis_eligible` của G2; dữ liệu đã dùng chỉnh hệ thống không còn là held-out cho quyết định đó.

**Điều kiện xong**

- [ ] S19.G — G3 có một script thật được người dùng duyệt đúng snapshot, cut khả thi, manifest có thể giao cho adapter và báo cáo AI-03 tại `script_ready` đạt các yêu cầu áp dụng của 09.

**Prompt bước:** “Hoàn thiện script approval theo đúng revisions và artifacts đã tồn tại. Kiểm race lúc duyệt, chọn khác với duyệt và invalidation có phạm vi; xuất manifest để Resolve dựng đúng bản được phép.”

## 9. G4 — Dựng và kiểm preview

### S20 — Resolve adapter có journal và quyền sở hữu timeline

**Phụ thuộc:** G3, spike S03, publication S08. **Đọc:** 04, 05, 09. **Requirement:** RES-01..RES-05.

**Đầu ra:** edit-plan compiler, operation journal, managed timeline per revision và khả năng đối chiếu side effect sau gián đoạn.

**Công việc**

- [ ] S20.1 — Compile edit plan đã duyệt thành lệnh có thứ tự; xác minh source snapshot/hash/mapping/approval trước gọi API. Resolve phải dùng conformed-media artifact đã kiểm và pin, hoặc native path đã chứng minh mapping tương đương theo 04; không mặc định import VFR gốc sẽ thực hiện đúng bản đồ khung hình.
- [ ] S20.2 — Ghi intent trước side effect; adapter Resolve được serialize toàn app, mỗi operation có logical identity và attempt authority.
- [ ] S20.3 — Đối chiếu project/timeline/item/render signatures bằng capability đã probe; trường không đọc được không tự coi là đã xác minh.
- [ ] S20.4 — Sau crash, nhận kết quả đã có khi đủ chứng cứ hoặc giữ reconciling/blocked; không append/render lại chỉ vì mất ACK.
- [ ] S20.5 — Managed timeline có revision riêng; phát hiện drift thì giữ bản sửa tay làm nhánh riêng hoặc dựng lại timeline mới từ sealed inputs, không đè chỉnh tay.
- [ ] S20.6 — Giải phóng AI heavy lease trước render; thao tác mở Resolve không tự vượt ngân sách chung.

**Kiểm tra**

- [ ] S20.T1 — Crash sau append nhưng trước ghi receipt không thêm clip lần hai khi resume; thử cả ca effect status chưa chứng minh được.
- [ ] S20.T2 — Đổi shot/mix trong managed timeline rồi yêu cầu render: app phát hiện/chặn đúng contract; manual handoff copy không bị tự rebuild.
- [ ] S20.T3 — Resolve đóng, project chuyển, media thiếu và API không hỗ trợ trả trạng thái cụ thể; không tiếp tục trên project khác cùng tên.
- [ ] S20.T4 — `.drp` mở lại với layers đúng mức chỉnh sửa công bố; title raster không bị quảng bá là text native chỉnh trực tiếp. Render fixture VFR để đối chiếu frame đầu/cuối và bằng chứng trọng yếu với mapping, không chỉ kiểm metadata timeline.

**Điều kiện xong**

- [ ] S20.G — Timeline thật khớp edit plan và journal; retry/reconcile có bằng chứng không duplicate trong các ca đã công bố.

**Prompt bước:** “Nối edit-plan compiler với Resolve adapter có journal. Kiểm crash sau side effect, API readback thiếu, project bị đổi và manual edits; mọi uncertainty về effect phải được reconcile hoặc block, không retry mù.”

### S21 — Preview, QC và phê duyệt; đóng G4

**Phụ thuộc:** S20. **Đọc:** 04, 09, 10. **Requirement:** MEDIA/RES QC, UI-10..UI-13, UI-22.

**Đầu ra:** preview 1080×1920, technical/content QC findings, giao diện review từng beat và preview approval theo artifact bytes.

**Công việc**

- [ ] S21.1 — Dựng caption theo WAV cuối, tối đa hai dòng có nghĩa, font đủ dấu, safe area và cue không lộ punchline sớm.
- [ ] S21.2 — Crop giữ thông tin chứng minh; tracker chưa đạt dùng fit/layout hợp lệ; SFX không bị ghi ngược thành bằng chứng nguồn.
- [ ] S21.3 — Technical QC kiểm media/frame/sync/text/audio; content QC đối chiếu câu–shot–source, B-roll, chronology và ảnh.
- [ ] S21.4 — Tự sửa lỗi xác định trong vòng hữu hạn, tạo revision và chạy lại check chịu ảnh hưởng; lỗi nghĩa chưa rõ tạo review.
- [ ] S21.5 — Người dùng xem/nghe và duyệt đúng preview/script/edit/WAV/crop/mix snapshot; chỉ render xong chưa được báo đã duyệt.

**Kiểm tra**

- [ ] S21.T1 — Fixture cố ý sai hình/lời, crop mất biển, caption sớm, ảnh sai buổi, âm lệch bị chặn hoặc review đúng loại.
- [ ] S21.T2 — Cảnh tối/im lặng có chủ ý không bị sửa máy móc; nhạc không lấn lời, tiếng hiện trường quan trọng còn đúng vai trò.
- [ ] S21.T3 — Thay crop/mix/shot sau duyệt tạo preview mới và approval cần thiết stale; đổi appearance app không đổi video.
- [ ] S21.T4 — QC không dùng subtitle/voice do app sinh làm bằng chứng độc lập cho chính nội dung nguồn.

**Điều kiện xong**

- [ ] S21.G — G4 có preview đạt các cổng máy, user approval đúng snapshot và mọi artifact cần final được pin.

**Prompt bước:** “Hoàn thiện preview và QC theo từng beat, nối nút duyệt với canonical snapshot. Dùng các lỗi dựng có chủ đích để kiểm; giữ im lặng/cảnh tối hợp lệ và chặn mọi thay đổi nội dung sau approval.”

## 10. G5 — Final, trải nghiệm và bản phát hành có bằng chứng

### S22 — Final QC và project bàn giao

**Phụ thuộc:** G4. **Đọc:** 04, 05, 09, 10. **Requirement:** RES-03..RES-05, MEDIA family, UI-22/UI-25.

**Đầu ra:** MP4 final 2160×3840/24/1, QC report, approved dependency manifest, Resolve export và manual handoff branch.

**Công việc**

- [ ] S22.1 — Preflight snapshot/hash/pins/approvals/Resolve drift/dung lượng và quyền; final dùng chính WAV/graphics đã duyệt.
- [ ] S22.2 — Render theo preset codec đã qua capability gate; khác biệt độ phân giải/codec phải nằm trong policy được công bố, không đổi layout/timing ngầm.
- [ ] S22.3 — Kiểm codec/container, kích thước/fps, max thời lượng stream/container, sync, text/crop/mix và nội dung từng beat trên file cuối.
- [ ] S22.4 — Với 24/1 và trần < 180 giây, kiểm giới hạn frame tương ứng và thời lượng thực; audio/encoder padding không được vượt cổng dù video frame hợp lệ.
- [ ] S22.5 — Lưu `.drp`/backup, text/style/audio/assets được phép bàn giao và manifest; nêu rõ nội dung chỉnh được trong Resolve hoặc phải tái sinh.
- [ ] S22.6 — Tạo nhánh manual handoff riêng, giữ timeline managed; UI nói rõ không có đồng bộ hai chiều tự động ở MVP.

**Kiểm tra**

- [ ] S22.T1 — Preview đúng nhưng final bị mất chữ/đổi crop/lệchmix hoặc sai thời lượng phải FAIL; không báo done từ Resolve render status.
- [ ] S22.T2 — Original đổi sau khi snapshot đã seal không đổi bytes của snapshot/final đang được duyệt. Nếu người dùng nhận source revision mới, chạy impact revalidation trước khi dùng bản mới. Managed timeline bị sửa ngoài contract phải chặn final tương ứng; không coi ba tình huống là cùng một lỗi.
- [ ] S22.T3 — Mở lại project bàn giao, kiểm nguồn cần thiết, timing và mức editable; test export hoàn tất nhưng app chết trước nhận receipt.
- [ ] S22.T4 — Xuất lại kỹ thuật giữ approved bytes đầu vào; nếu phải sinh lại WAV khác thì tạo revision/duyệt phù hợp.

**Điều kiện xong**

- [ ] S22.G — Có một thành phẩm thật đạt QC và mở lại được project; trạng thái done chỉ dùng cho đúng output revision đã kiểm.

**Prompt bước:** “Làm final pipeline từ preview snapshot, kiểm chính file cuối và bàn giao Resolve theo managed/manual contract. Chèn lỗi preview→final và crash sau render để chứng minh finalgate không dựa vào metadata hoặc render status đơn thuần.”

### S23 — Sáu nâng cấp và capability gates

**Phụ thuộc:** S22 và nền phân tích. **Đọc:** 03, 07, 09. **Requirement:** các nhóm AI/STORY/RES tương ứng trong 09.

**Đầu ra:** sáu vai trò có hành vi nền thực, registry candidate/validated/disabled, fixture và báo cáo riêng cho mode nâng cao. Bước này không cho phép gọi một mode chưa đạt là đã có.

**Công việc**

- [ ] S23.1 — Ghép ảnh: candidate retrieval, ngữ cảnh/thời gian, exact_candidate khác use_mode; mode exact chỉ mở khi qua cổng riêng, mặc định chưa đủ thì illustrative/none.
- [ ] S23.2 — Event graph xuyên source: partial order, clock uncertainty, session boundaries và phát hiện cạnh mâu thuẫn.
- [ ] S23.3 — Omission/counterevidence audit: quay lại source theo vấn đề cụ thể, không chỉ tự chấm lại báo cáo.
- [ ] S23.4 — Gu local: explicit profile, feedback yếu từ lựa chọn, sửa/reset/export/project override; không fine-tune ngầm hoặc biến sở thích thành sự thật.
- [ ] S23.5 — Final review: đối chiếu bản xuất với nguồn/kịch bản, ghi finding và recheck dependency sau sửa.
- [ ] S23.6 — Nhịp hài: cue/pause/caption/photo/SFX theo WAV; không ép hiệu ứng hoặc tạo sự cố để làm hài.

**Kiểm tra**

- [ ] S23.T1 — Ảnh giống người/trang phục nhưng khác buổi và ứng viên gần ngang nhau không tự được dùng như đúng cú bấm.
- [ ] S23.T2 — Profile gu thay đổi chỉ tác động style/ranking trong tập hợp lệ; reset được, không đổi user fact hoặc mở khóa ràng buộc.
- [ ] S23.T3 — Các ca im lặng, biênbatch, punchline sớm và phản chứng thật được đánh giá; model đồng thuận không tự tăng confidence.
- [ ] S23.T4 — Registry mode exact/SED/tracking/emotion cues phản ánh report thật; mode chưa đạt có nhãn/fallback đúng và không xuất hiện trong quảng bá tính năng đã validated.

**Xác nhận mode nâng cao, chỉ tích khi thật sự đạt; có thể để mở trong release có phạm vi hẹp**

- [ ] S23.C1 — Exact-photo use đã qua bộ benchmark riêng và được bật với giới hạn công bố.
- [ ] S23.C2 — Sound-event detector đã qua benchmark vai trò riêng, không dựa ASR thay thế.
- [ ] S23.C3 — Tracking/crop động đã qua fixture giữ bằng chứng và tính ổn định theo thời gian.
- [ ] S23.C4 — Cue cảm xúc/giọng/phong cách nâng cao được backend hỗ trợ và mẫu người dùng chấp nhận.

**Điều kiện xong phần nền**

- [ ] S23.G — Sáu vai trò nền đã hoạt động đúng phạm vi; từng mode nâng cao có quyết định bật/tắt và bằng chứng hoặc mục hoãn rõ. Không tính mục hoãn là hoàn thành năng lực.

**Prompt bước:** “Tích hợp sáu nâng cấp của 09 và capability registry. Kiểm cả trường hợp phải từ chối exact match hoặc giữ unknown; mọi mode nâng cao phải có evidence trước khi bật, còn fallback được ghi đúng bản chất.”

### S24 — Hoàn thiện trải nghiệm native macOS

**Phụ thuộc:** S14, S19, S21–S23. **Đọc:** 10 đầy đủ; 01/05 cho semantics. **Requirement:** UI-01..UI-28.

**Đầu ra:** năm màn hình dùng backend thật, mọi trạng thái, keyboard/focus, accessibility, Instruments trace và UI test reports.

**Công việc**

- [ ] S24.1 — Hoàn thiện Tư liệu/Ngày làm việc/Cần làm rõ/Kịch bản/Dựng&xuất, empty/loading/partial/blocked/stale/error/done đúng scope.
- [ ] S24.2 — Layout thích ứng 960×640, 1280×800, 1440×900 pt; chữ 125%/150%, nhãn dài, sidebar/inspector và rút màn ngoài.
- [ ] S24.3 — Editor native giữ IME marked text, caret/selection/undo; keyboard shortcuts chỉ nhận đúng focus, không cướp Space khi gõ.
- [ ] S24.4 — Player/thumbnail cache có vòng đời và quota; stale seek result không ghi đè selection mới; task/log/progress buffers hữu hạn.
- [ ] S24.5 — VoiceOver, contrast, Reduce Motion/Transparency và chế độ sáng/tối; trạng thái dùng chữ và icon, không chỉ màu.
- [ ] S24.6 — Cmd+W/Cmd+Q, sleep/wake, nguồn ngoài, bookmark và nhiều project tôn trọng core/lease; không tự giả pause đã xong.

**Kiểm tra**

- [ ] S24.T1 — Gõ tiếng Việt với bộ gõ hệ thống và Telex/VNI có trên máy; paste dài/emoji, job cập nhật và undo không làm mất nội dung.
- [ ] S24.T2 — Fixture UI với 1.000 asset, 300 fact, 100 review và ít nhất 50 vòng đổi preview: RAM/player/observer không tăng vô hạn; ghi kết quả đo theo 10.
- [ ] S24.T3 — Đo lightweight interaction latency p95 theo target 09/10 trong tải đã công bố; không dùng async/Task làm bằng chứng UI không bị chặn.
- [ ] S24.T4 — Người kiểm hoàn thành luồng cốt lõi bằng keyboard/VoiceOver, hiểu source labels, lý do blocked và hành động phục hồi.
- [ ] S24.T5 — Lỗi lưu/QC/nguồn không bị thay bằng toast thoáng qua; final lịch sử không bị gọi nhầm là bản hiện hành đã duyệt.

**Điều kiện xong**

- [ ] S24.G — Có kết quả toàn bộ UI matrix áp dụng; mọi lỗi mất dữ liệu, duyệt nhầm hoặc mất hành động bắt buộc được xử lý trước release.

**Prompt bước:** “Hoàn thiện UI theo 10 trên backend thật và chạy UI-01..UI-28. Tập trung IME/focus/revision, accessibility và vòng đời media; đo bằng Instruments và thao tác thật, không lấy screenshot đẹp thay nghiệm thu.”

### S25 — Thử lỗi, tải dài và nghiệm thu phạm vi E0/E1

**Phụ thuộc:** S22–S24. **Đọc:** 05, 06, 09, 10. **Requirement:** INV/DATA/JOB/RES/REL và ma trận fault injection.

**Đầu ra:** báo cáo integration/fault injection, full-run traces, benchmark release-candidate và quyết định mức hỗ trợ đã đạt.

**Công việc**

- [ ] S25.1 — Chạy lại crash windows với pipeline AI/media/Resolve thật, không chỉ worker mock; xác minh artifact/approval sau restart.
- [ ] S25.2 — Thử cancel/resultlate, diskfull, source bị dời/đổi, Resolve đóng/chuyểnproject, sleep/wake và IPC mất ACK.
- [ ] S25.3 — Chạy phiên sử dụng kéo dài tối thiểu 2 giờ cho vòng nghiệm thu ban đầu và chạy trọn công việc dài thuộc phạm vi công bố; 2 giờ không thay job dài hơn.
- [ ] S25.4 — Đo total process/system memory, swap/pressure, SSD và queue; log đủ tái hiện mà không vô hạn hoặc lộ nội dung riêng tư.
- [ ] S25.5 — Chạy release-candidate holdout theo 09, report completion/abstention/blockers cùng accuracy; giữ nhóm E0/E1 và UI stress tách biệt.
- [ ] S25.6 — Đối chiếu requirements→testcases→build→results; mọi NOT_RUN/BLOCKED nằm trong quyết định phát hành, không đổi thành PASS.

**Kiểm tra**

- [ ] S25.T1 — Không mất dữ liệu đã commit, không approval sai snapshot, không duplicate Resolve trong suite đã công bố; các invariant violations đều chặn.
- [ ] S25.T2 — Restore portable/checkpoint backup đúng mức khai báo sau phiên làm việc thật; không chỉ restore database fixture rỗng.
- [ ] S25.T3 — Tập khó và project thất bại vẫn trong mẫu số theo eligibility đã khóa; không lấy unknown cao để che failure.
- [ ] S25.T4 — Nếu E1 fail nhưng E0 pass, scope được công bố đúng E0; muốn sửa và re-evaluate có version/dataset policy rõ, không tự coi cả hai đạt.

**Điều kiện xong**

- [ ] S25.G — Có quyết định phạm vi hỗ trợ dựa kết quả; không còn lỗi chặn đã biết trong phạm vi được đề xuất phát hành.

**Prompt bước:** “Chạy ma trận phá lỗi và tải thực theo 09 trên release candidate. Giữ tất cả failure/blocked trong báo cáo, phân biệt E0/E1/UI stress; không nới threshold hay scope sau khi thấy kết quả để tuyên bố đạt.”

### S26 — Đóng gói Release và bàn giao; đóng G5

**Phụ thuộc:** S25. **Đọc:** 03, 05, 06, 09, 10. **Requirement:** OFF family, REL-03 và G5.

**Đầu ra:** bản Release arm64, setup/model manifest, changelog, support matrix, release evidence, hướng dẫn backup/restore và hạn chế còn lại.

**Công việc**

- [ ] S26.1 — Build với dependencies/SDK/runtime đã pin; ghi build commit và checksums artifact phân phối; không yêu cầu người dùng chạy terminal để dùng luồng chính.
- [ ] S26.2 — Kiểm quyền helper/runtime/model/file picker trên bản đóng gói; nghiệm thu chính sách ký/notarization khi phạm vi phân phối yêu cầu.
- [ ] S26.3 — Tách setup tải/cài khỏi project execution; setup báo bytes/license/artifact thiếu, project offline không tự tải.
- [ ] S26.4 — Kiểm first launch, reopen, portable restore và thiếu dependency trong tài khoản/môi trường sạch đại diện cho phạm vi hỗ trợ.
- [ ] S26.5 — Xuất hồ sơ ca đã chạy, số đo, capability đang bật/tắt, scope E0/E1 và hướng nâng cấp/migration/rollback phù hợp.
- [ ] S26.6 — Bàn giao video/project mẫu được phép, tài liệu build và vận hành; giữ dữ liệu riêng tư ngoài gói phát hành nếu không được phép chia sẻ.

**Kiểm tra**

- [ ] S26.T1 — Bản Release từ Finder chạy hết luồng đã công bố và offline sau setup; kết quả không phụ thuộc môi trường terminal của người phát triển.
- [ ] S26.T2 — Core/schema/runtime version mismatch được xử lý rõ; app cũ không phá project schema mới.
- [ ] S26.T3 — Mỗi capability được quảng bá có report và build tương ứng; các tính năng nâng cao chưa đạt không bị ghi đã hoàn thành.
- [ ] S26.T4 — Release notes dùng phạm vi trung thực: “Đã vượt ma trận trên cấu hình liệt kê, không còn lỗi chặn đã biết trong phạm vi đó”; không hứa không lỗi mọi MacBook.

**Điều kiện xong**

- [ ] S26.G — G5 có đủ hồ sơ và bản Release kiểm thật; người dùng có thể tạo project, nhập/review/duyệt, nhận finalQC và mở project bàn giao trong phạm vi hỗ trợ.

**Prompt bước:** “Đóng gói và nghiệm thu Release theo G5. Thử launch từ Finder, môi trường sạch, setup/offline và restore; bàn giao build có evidence, capability matrix và hạn chế, không đánh đồng bản debug chạy được với release đã đạt.”

## 11. Lệnh kiểm tra tham khảo khi repository đã được tạo

Các tên project/scheme/package dưới đây là quy ước của cấu trúc đích. S00–S04 phải tạo hoặc điều chỉnh đúng tên trước khi dùng. Lệnh không thay cho các ca thử thủ công/thiết bị thật trong từng bước.

### 11.1. Khảo sát Mac ở S01

```bash
sw_vers
uname -m
xcodebuild -version
xcodebuild -showsdks
swift --version
python3 --version
ffmpeg -version
ffprobe -version
```

Ghi dung lượng bằng công cụ trả bytes thực và capability report của app. Không đưa dữ liệu thư mục riêng tư không liên quan vào log công khai. Nếu lệnh không có, ghi missing dependency; không đoán output.

### 11.2. Core và workers

```bash
swift test --package-path packages/AIVideoCore
uv run --project workers pytest
```

`uv`, `pytest` và test targets phải nằm trong công cụ phát triển/lockfile đã chọn. Runtime trong `.app` không dựa vào việc người dùng có `uv` hoặc gọi `pip` khi đang dựng project. Chọn công cụ môi trường khác phải có ADR và cập nhật lệnh tương ứng.

### 11.3. App build/test trên Mac

```bash
xcodebuild -list -project apps/macos/AIVideo.xcodeproj
xcodebuild -project apps/macos/AIVideo.xcodeproj -scheme AIVideo -showdestinations
xcodebuild -project apps/macos/AIVideo.xcodeproj -scheme AIVideo -configuration Release -destination 'platform=macOS,arch=arm64' build
xcodebuild -project apps/macos/AIVideo.xcodeproj -scheme AIVideo -destination 'platform=macOS,arch=arm64' test
```

Chọn destination đúng từ toolchain đã cài; nếu tên/kiến trúc không tương ứng, sửa cấu hình theo capability đã xác minh. UI tests cần môi trường phiên người dùng phù hợp. Ghi `.xcresult` bằng `-resultBundlePath` tới một đường dẫn mới của lần chạy khi thu bằng chứng; không gắn kết quả cũ vào build mới.

Các script contract/fault/benchmark trong `tools/qa/` được tạo ở S04/S08/S15. Khi chưa tạo, không liệt kê chúng như lệnh đã chạy. Sau khi tạo, ghi chính xác entrypoint và flags trong biên bản, kèm test version và fixture manifest.

## 12. Mẫu nhật ký tiến độ có thể sao chép

### Phiên code tiếp theo

```text
Ngày:
Bước đang làm:
Mục checkbox sẽ hoàn thành trong phiên:
Đầu vào và prerequisite đã đạt:
File/module dự kiến sửa:
Ca kiểm chứng minh hành vi cần đạt:
Kết quả thực sau phiên:
Commit/build:
Evidence:
Mục chưa xong và nguyên nhân:
Bước tiếp theo:
```

### Mẫu báo cáo máy đọc được — ví dụ chưa chạy

```json
{
  "progress_schema_version": 1,
  "step_id": "S08",
  "status": "NOT_STARTED",
  "build_commit": null,
  "environment_manifest": null,
  "dataset_manifest": null,
  "required_cases": ["DATA-02"],
  "results": [],
  "blocking_findings": [],
  "reviewed_by": null,
  "reviewed_at": null,
  "exit_gate_passed": false
}
```

`blocking_findings` trống trong ví dụ không có nghĩa không có lỗi; `results` chưa có và `exit_gate_passed=false` xác định chưa nghiệm thu. Khi điền, reference phải trỏ tới artifact/log có thật và đúng build.

## 13. Quy tắc đánh dấu gate và đánh giá lại

| Tình huống | Cách cập nhật tiến độ |
|---|---|
| Code xong nhưng chưa thử trên Mac | Mục code có thể tích nếu đúng; mục test/gate còn mở, trạng thái IN_REVIEW hoặc BLOCKED. |
| Test mock đạt, API thật chưa thử | Giữ gate tích hợp mở; ghi rõ fixture mock và phép thử còn thiếu. |
| Đổi schema/protocol | Review lại S04 và các bước persistence/worker/approval chịu ảnh hưởng. |
| Đổi model/processor/prompt | Review lại profile, coverage, semantic benchmark và các artifact phụ thuộc; holdout policy vẫn áp dụng. |
| Đổi voice/alignment | Review lại S17/S18/S21/S22 theo dependency; không chỉ test lại file WAV tồn tại. |
| Đổi media/color/Resolve version | Review capability/mapping/render/QC và saved projects tương ứng. |
| Nâng minimum OS hoặc cách đóng gói | Chạy lại G0 và các ca quyền/lifecycle/Release chịu ảnh hưởng. |
| E1 chưa qua | Công bố đúng mức đã qua; không ghi “hỗ trợ E1” bằng suy luận từ E0. |
| Optional capability bị hoãn | Registry disabled/candidate, ghi lý do và điều kiện bật; không tích ô xác nhận capability đã validated. |

Thứ tự thực dụng: đóng G0 sớm; làm G1 chắc; tạo một luồng E0 trọn vẹn; mở rộng theo số đo. Không dùng thêm hiệu ứng hoặc thêm model để che một lỗi dữ liệu/phê duyệt/phục hồi còn tồn tại.

## 14. Nguồn công cụ và tài liệu sở hữu

Quy trình và tiêu chí của AIVideo là thiết kế riêng trong bộ này. Cú pháp và khả năng công cụ nền tảng phải đối chiếu phiên bản cài thật:

- [Apple — Building from the Command Line with Xcode](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).
- [Apple — View and share test results](https://help.apple.com/xcode/mac/current/en.lproj/devc38fc7392.html).
- [Swift Package Manager — SwiftTest documentation](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftTest.md).
- [SQLite — Write-Ahead Logging](https://www.sqlite.org/wal.html) và [Backup API](https://www.sqlite.org/backup.html).
- [Apple — Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).
- [03 — Models and Resources](03-MODELS-AND-RESOURCES.md), [05 — Architecture](05-ARCHITECTURE-AND-ROADMAP.md), [09 — Acceptance](09-UPGRADES-AND-ACCEPTANCE.md), [10 — UI/UX](10-UI-UX-MACOS.md).

**Bước khởi đầu được đề nghị: S00.** Sau mỗi phiên, cập nhật bằng chứng và những ô thực sự đã hoàn thành; không cần sửa toàn bộ đặc tả mỗi lần thêm một hàm.
