# 06 — Quyết định kiến trúc, phạm vi hỗ trợ và rủi ro còn lại

> **Trạng thái triển khai (2026-11-11):** đặc tả dưới đây đã được hiện thực hoá và kiểm thử;
> xem [`README.md`](../README.md) để biết trạng thái hiện tại và
> [`AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md) cho các
> lỗi đã đóng. Chỗ nào đặc tả khác mã đang chạy, mã + audit là nguồn đúng.

**Phiên bản đặc tả:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** các quyết định dưới đây đã được chốt trong thiết kế để triển khai; chưa có build, benchmark hoặc chứng nhận vận hành kèm bộ Markdown này.

Tài liệu này giải thích vì sao chọn kiến trúc hiện hành, phần nào đã quyết định và phần nào chỉ có thể kết luận sau phép thử. Hợp đồng sản phẩm ở [01-PRODUCT.md](01-PRODUCT.md), dữ liệu ở [02-ANALYSIS-AND-DATA.md](02-ANALYSIS-AND-DATA.md), vận hành ở [05-ARCHITECTURE-AND-ROADMAP.md](05-ARCHITECTURE-AND-ROADMAP.md). Mã yêu cầu/ngưỡng nghiệm thu thuộc [09-UPGRADES-AND-ACCEPTANCE.md](09-UPGRADES-AND-ACCEPTANCE.md); thứ tự coding nằm ở [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md).

## 1. Cách đọc quyết định và bằng chứng

`accepted_design` nghĩa là dùng làm chuẩn triển khai cho v3.1. Nó không có nghĩa `validated_on_device`. Một quyết định có thể hợp lý nhưng capability mà nó cần vẫn chưa qua gate.

- Không gọi app ổn định chỉ vì có SwiftUI, SQLite WAL, checkpoint hoặc nhiều lượt AI.
- Không chuyển mục tiêu định lượng thành thành tích. Khi chưa có số đo, ghi **chưa đo** hoặc **chưa kiểm chứng**.
- Mỗi phát biểu hỗ trợ một máy/OS/codec/model phải có dòng capability matrix và evidence run tương ứng.
- Minimum macOS không được đoán từ giao diện mong muốn; nó là giao điểm yêu cầu đã xác minh của app, toolchain và runtime.
- M1 Pro 16 GB là cấu hình mục tiêu từ khảo sát trước. Resolve 21.1.2, đường dẫn model, khoảng 109 GB weights và khoảng 117 GiB trống là thông tin lịch sử, không phải kiểm kê máy hiện tại.
- Thời gian xử lý không quan trọng hơn chất lượng; nhưng hết RAM/disk, lost context hoặc evidence sai không được giải quyết bằng việc chờ vô hạn.
- Bộ Markdown v3.1 và ZIP chỉ là đặc tả được nâng cấp. Checklist code phải bắt đầu chưa hoàn tất; không dùng việc có tài liệu để đánh dấu app đã triển khai.

## 2. Danh mục ADR

ADR là quyết định có version, lý do, đánh đổi và bằng chứng cần có. Các mô tả chi tiết vẫn thuộc tài liệu owner; bảng dưới đây không tạo một nguồn quy tắc khác để copy rồi sửa lệch.

| ADR | Quyết định v3.1 | Owner contract | Gate xác minh chính |
|---|---|---|---|
| `ADR-001` | macOS native SwiftUI + Swift core + Python workers | 05, 10 | G0 |
| `ADR-002` | Một ProjectStore writer, local APFS, SQLite WAL/FULL | 02, 05 | G0–G1 |
| `ADR-003` | Managed sealed source snapshots cho phân tích và render | 02, 05 | G1 |
| `ADR-004` | JSON-RPC 2.0 JSON Lines stdio, schema có version | 05 | G0–G1 |
| `ADR-005` | Fencing/session và một heavy lease toàn app | 03, 05 | G1, G5 |
| `ADR-006` | Publication có durable intent và reconciliation | 05 | G1 |
| `ADR-007` | Approval gắn snapshot và bytes media đã duyệt | 02, 04, 05 | G1, G3–G5 |
| `ADR-008` | Tách nguồn/support/use; corpus impact có audit | 02, 08 | G2 |
| `ADR-009` | Baseline mọi frame hợp lệ, quan sát đầu độc lập brief | 02, 07, 08 | G2 |
| `ADR-010` | Beam search hữu hạn với trạng thái trung thực | 04, 07 | G3 |
| `ADR-011` | Resolve managed timeline và manual handoff tách biệt | 04, 05 | G0, G4–G5 |
| `ADR-012` | Media profile 24/1, SDR Rec.709, mapping chính xác | 04 | G0, G2, G4–G5 |
| `ADR-013` | Local/offline sau setup; pin runtime/model/assets | 03, 05 | G0, G2, G5 |
| `ADR-014` | Backup/restore/migration và GC có reference/pin | 02, 05 | G1, G5 |
| `ADR-015` | Công bố envelope E0/E1 sau khi có evidence | 06, 09 | G0–G5 |
| `ADR-016` | Benchmark độc lập, threshold quản lý theo version | 08, 09 | G2–G5 |
| `ADR-017` | UI có commit ACK, revision, accessibility và main-actor budget | 10 | G0, G1, G5 |
| `ADR-018` | Gate theo năng lực; packaging/Resolve spike làm từ đầu | 05, 11 | G0–G5 |

## 3. Các quyết định và đánh đổi

### ADR-001 — Giữ stack native macOS

**Quyết định:** SwiftUI/AppKit/AVKit cho giao diện và tích hợp máy; Swift core điều phối; Python subprocess cho model/media/Resolve; SQLite giữ nghiệp vụ chuẩn. Không chuyển sang Rust/Tauri trong phạm vi này.

**Lý do:** ranh giới này đặt quyền duyệt và dữ liệu vào core có kiểu rõ, đồng thời dùng được các runtime Python cần thử. Giao diện native phục vụ nhập tiếng Việt, quyền file, player, keyboard/focus và khôi phục cửa sổ.

**Đánh đổi:** phải chứng minh IPC, packaging, worker lifecycle và quyền file trên `.app` thật; SwiftUI không tự bảo đảm không lag hoặc không lỗi. G0 xác minh phần nền tảng trước UI hoàn chỉnh.

### ADR-002 — Một writer và active project local APFS

**Quyết định:** mỗi project có một ProjectStore actor; worker không ghi canonical DB. WAL, foreign keys, `synchronous=FULL`, short transaction và expected revision checks là mặc định v3.1.

**Lý do:** giữ một đường commit giúp tập trung invariants/approval và tránh mỗi module hiểu trạng thái khác nhau. Local APFS giới hạn bề mặt durability cần kiểm trong MVP.

**Đánh đổi:** không hỗ trợ active DB trên network share hoặc thư mục đang sync cloud trực tiếp. WAL không thay backup và không làm file/Resolve atomic. Ma trận runtime và fault tests phải xác minh contract trên máy thật.

### ADR-003 — Snapshot nguồn bất biến

**Quyết định:** mọi phân tích/render có thẩm quyền dùng sealed content revision do app quản lý; verified APFS clone nếu capability phù hợp, nếu không thì full verified copy. Không dùng hardlink như bảo đảm bất biến.

**Lý do:** source hash tại import không ngăn ứng dụng khác sửa file trước render. Snapshot cho phép giữ đúng bytes mà evidence và approval dựa vào, đồng thời giữ original chỉ đọc.

**Đánh đổi:** tốn disk và thời gian acquisition; clone vẫn có tăng trưởng copy-on-write. Không đủ disk thì pause, không tự hạ sang direct-read. Không tuyên bố read-only chống được tác nhân có toàn quyền hệ điều hành; hash/integrity gates vẫn cần.

### ADR-004 — Một transport IPC và typed outputs

**Quyết định:** JSON-RPC 2.0 qua UTF-8 JSON Lines stdio; stdout chỉ protocol, stderr log có giới hạn; message ban đầu tối đa 1 MiB. Payload lớn dùng registered artifact refs.

**Lý do:** một transport, version handshake, allowlist method và input/output schema giúp giảm đường lỗi và ngăn text nguồn trở thành lệnh.

**Đánh đổi:** cần quản lý backpressure, log của thư viện, response mất, worker crash và payload lỗi. Same idempotency key khác payload là conflict; output hợp schema vẫn chưa được coi đúng ngữ nghĩa.

### ADR-005 — Attempt fencing và resource governor toàn app

**Quyết định:** attempt có ID mới, fencing counter persist và session identity. Revoke quyền publish trước cancel/replacement. Một heavy lease áp dụng cho tất cả project windows, model nặng, render và media nặng.

**Lý do:** worker cũ có thể sống hoặc gửi result sau khi UI đã retry. Kiểm quyền commit và xác nhận hoạt động nặng đã dừng là hai việc riêng.

**Đánh đổi:** đôi lúc phải chờ/reconcile thay vì chạy ngay. Heartbeat mất chỉ là nghi ngờ. Adapter chết không chứng minh Resolve dừng render; app không kill project người dùng để lấy RAM.

### ADR-006 — Publication có journal

**Quyết định:** `PREPARED → MATERIALIZED → VERIFIED → COMMITTED`, durable intent, verify/flush/rename trên filesystem đích rồi commit canonical metadata theo protocol 05.

**Lý do:** DB và file không có một transaction chung; crash ở khoảng rename trước DB commit phải được thiết kế trước.

**Đánh đổi:** cần startup reconciler, orphan/quarantine policy và crash fixture từng ranh giới. “Atomic rename” một mình không là chứng nhận mất điện an toàn; durability profile chưa qua thử thì gate chưa đạt.

### ADR-007 — Approval đúng snapshot và đúng bytes

**Quyết định:** fact confirmation, script approval và preview approval có scope/revision riêng. Pin WAV, graphics, edit plan và media đã được duyệt. Cùng model/seed/config không cho phép tái sinh bytes rồi coi vẫn đã duyệt.

**Lý do:** giọng, timing, crop, caption và mix có thể đổi dù câu chữ không đổi. Người dùng phải nhận đúng bản đã xem/nghe.

**Đánh đổi:** sửa có ý nghĩa kéo theo preview/approval mới và tăng dung lượng giữ revisions. Rebuild kỹ thuật giữ approval chỉ khi dùng đúng snapshot/bytes và vượt QC; resolution/codec khác phải nằm trong profile được công bố.

### ADR-008 — Evidence có provenance và corpus impact

**Quyết định:** giữ các trục nguồn/tri thức/review riêng với support và allowed use. Mỗi lần dùng claim có decision; corpus/query scopes có revision. Thêm nguồn xét cả kết luận “chưa tìm thấy” và lựa chọn dựa toàn tập.

**Lý do:** user-confirmed không phải visually observed; file link không phải entailment. DAG cũ không thể có cạnh tới một clip mới chưa tồn tại.

**Đánh đổi:** cần đánh giá ngữ nghĩa, reverse retrieval và impact audit. `no_material_change` giữ nguyên approval ID/snapshot/fingerprint; decision mới gỡ pending block. Dependency thực đổi thì new artifact/stale approval, không sửa fingerprint cũ để duyệt lây.

### ADR-009 — Baseline mọi frame hợp lệ

**Quyết định:** lượt chi tiết đưa mọi frame hợp lệ tới processor/model, audit input thực sau processor, streaming cửa sổ nhỏ có chồng lấn. Lượt quan sát đầu không nhận câu chuyện kỳ vọng từ brief.

**Lý do:** yêu cầu ưu tiên chất lượng và sự kiện ngắn không cho phép âm thầm lấy mẫu thưa hoặc bỏ clip im lặng. Quan sát độc lập giảm việc đọc nguồn theo kỳ vọng đã có.

**Đánh đổi:** workload lớn, không chứng minh hiểu đúng mọi frame và có nguy cơ mất ngữ cảnh qua cửa sổ. Tune trên development grid, khóa profile trước held-out; adaptive refinement chỉ bổ sung, không thay baseline. E0/E1 chưa được gọi hỗ trợ trước khi đo đủ pipeline.

### ADR-010 — Search status không được giả thành chứng minh vô nghiệm

**Quyết định:** beam search là xấp xỉ với bốn trạng thái `SOLUTION_FOUND`, `SEARCH_BUDGET_EXHAUSTED`, `CANDIDATE_SET_EXHAUSTED`, `PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN` theo tài liệu 07.

**Lý do:** beam có thể loại mất nhánh dẫn tới nghiệm; không tìm thấy bằng cách tìm hữu hạn không chứng minh constraints của người dùng mâu thuẫn.

**Đánh đổi:** cần mở rộng/recover candidates, fallback feasibility trong miền hữu hạn nhỏ và counterexample fixture. Không gọi conflict core là tối thiểu hoặc thuật toán là tối ưu toàn cục nếu không có exact checker tương ứng.

### ADR-011 — Resolve có miền sở hữu rõ

**Quyết định:** app quản lý timeline có identity theo edit-plan revision; operation journal trước call, readback/reconcile sau call. Manual handoff là bản riêng, không roundtrip tự động trong MVP.

**Lý do:** Resolve có state ngoài SQLite và người dùng có thể chỉnh tay. Không được ghi đè chỉnh tay hoặc render drift rồi gắn approval cũ.

**Đánh đổi:** manual changes chưa quay lại được AI edit plan; người dùng phải giữ nhánh thủ công hoặc tạo managed revision mới. Effect không quan sát được phải dùng fallback cô lập có kiểm hoặc block capability, không giả fingerprint kiểm đủ mọi thứ.

### ADR-012 — Profile media rõ và kiểm trên output thật

**Quyết định:** output 24/1 fps, final 2160×3840, preview 1080×1920, canonical audio 48 kHz; khoảng nội bộ `[start,end)`, PTS/mapping versioned. SDR Rec.709 là profile MVP. Không dùng optical flow/frame sinh làm bằng chứng hay fallback mặc định.

**Lý do:** VFR, rotation, audio offset và conversion màu có thể làm cut/độ đúng khác với metadata. 4K là kích thước xuất, không chứng minh chi tiết gốc tương đương.

**Đánh đổi:** HDR chỉ nhận vào đường supported khi tags/transfer/primaries biết và tone-map fixture đạt. H.264/MP4 + AAC là candidate export preset cần capability test; không tự đổi codec/profile khi lỗi. Tolerances và mapping cụ thể thuộc 04/09.

Đường mặc định tạo conform-media artifact 24/1 được verify/publish/pin trước import Resolve. Native conform chỉ bật khi profile/fixture/job checks chứng minh trùng mapping; capability này không được suy ra từ fps hiển thị của timeline.

### ADR-013 — Offline sau pha cài đặt riêng

**Quyết định:** model, processor, runtime, font, SFX/nhạc, voice preset và template pin revision/checksum/nguồn sử dụng. Pha cài đặt/tải tách project; lúc làm project không gọi AI cloud hoặc tự tải dependency.

**Lý do:** loader “local” vẫn có thể thiếu artifact phụ; reproducibility cần cả weights lẫn processor/tokenizer/preset/runtime.

**Đánh đổi:** phải kiểm ngắt mạng bằng app đóng gói, có preflight thiếu dependency và lịch nâng version có regression gate. Qwen/VieNeu/Whisper/DINOv2 trong 03 là ứng viên; sound events/alignment/tracker chưa được coi đạt chỉ vì thêm tên model.

### ADR-014 — Backup, restore, migration và GC là một phần sản phẩm

**Quyết định:** backup snapshot nhất quán và pin referenced artifacts; phân biệt checkpoint với portable backup; restore vào thư mục mới. Migration có preflight/backup/journal/validation. GC có reservation `gc_pending` để không đua với pin mới.

**Lý do:** copy database đơn lẻ không chứng minh phục hồi được story/project. Transaction check xong rồi unlink file mà không giữ reservation vẫn có race.

**Đánh đổi:** giữ nhiều source/revisions/backup làm tăng SSD. Retention không được orphan refs; thiếu disk phải báo/pause. Mục tiêu backup 15 phút là policy, không tự là RPO đã đo. App cũ không tự ghi schema mới mình chưa hiểu.

### ADR-015 — Support envelope hữu hạn

**Quyết định:** dùng E0 pilot và E1 release candidate ở mục 4; mọi profile mang trạng thái đo được, chưa đo hoặc không hỗ trợ. UI stress 1.000 assets là fixture UI, không là cam kết AI xử lý 1.000 assets.

**Lý do:** “mọi video trên mọi MacBook” không phải phạm vi kiểm chứng khả thi của MVP. Giới hạn rõ giúp chọn dữ liệu, disk budget và soak duration thực tế.

**Đánh đổi:** dữ liệu vượt envelope cần profile mở rộng hoặc nhãn thử nghiệm trước khi chạy nặng. Không che việc vượt phạm vi dưới một lỗi “AI không hiểu”; không công bố hỗ trợ rộng hơn chỉ vì chạy được một lần.

### ADR-016 — Mục tiêu nghiệm thu có version và holdout độc lập

**Quyết định:** đo riêng coverage, support/false accepts, observable-event recall, abstention, completion, review load và chất lượng kể. Ngưỡng đề xuất v0.1 thuộc 09; khóa sau pilot development và trước held-out.

**Lý do:** không thể đạt “accuracy cao” bằng cách bỏ mọi claim khó, hỏi người dùng mọi frame hoặc tự chấm bằng cùng model đã viết.

**Đánh đổi:** cần dữ liệu gán nhãn, mẫu đánh giá mù và báo khoảng bất định/correlation. Không đổi ngưỡng để làm test đã biết thất bại trở thành pass; thay đổi qua ADR và một held-out độc lập mới.

### ADR-017 — UI thể hiện sự thật của state

**Quyết định:** native text input, autosave có commit ACK, expected revision ở backend, UI đủ loading/partial/blocked/stale/error; main actor không xử lý media/model nặng.

**Lý do:** người dùng phải biết đang gõ/chưa lưu, source nào đang xem, approval nào cần lại và job nào thực đã dừng. Độ đúng UI là một phần độ đúng dữ liệu.

**Đánh đổi:** cần kiểm Telex/VNI khi hỗ trợ, marked text, keyboard/focus, VoiceOver, resize/scaling, cancel/reopen và stress trên Release app. Target p95 phản hồi thao tác nhẹ ≤100 ms không nghĩa mọi worker phải dừng hoặc mọi màn hình tải xong trong 100 ms.

### ADR-018 — Cổng nền tảng và dữ liệu đi trước mở rộng hiệu ứng

**Quyết định:** packaging/permissions/offline/Resolve 10 giây tại G0; data/recovery G1; analysis G2; story/TTS/search/approval G3; preview G4; final/restore/release G5.

**Lý do:** phải phát hiện sớm nền tảng hoặc API không thực hiện được contract. Không đợi UI đẹp xong mới thử worker, filesystem hoặc `.drp`.

**Đánh đổi:** ban đầu có thể ít hiệu ứng và ít năng lực đã qua gate. G2 đo harness `analysis_eligible`, không đòi TTS/final hoàn chỉnh; `script_ready` thuộc G3, end-to-end completion/final thuộc G5. Không tạo vòng phụ thuộc giữa các gate.

## 4. Envelope E0/E1: phạm vi dự kiến để kiểm chứng

Đây là **profile thử nghiệm đề xuất**, trạng thái ban đầu **chưa kiểm chứng**. Chỉ chuyển một dòng sang được hỗ trợ sau evidence trên build/máy/profile thực. Mở rộng envelope cần ADR và bộ thử bổ sung trước khi công bố.

| Thuộc tính | E0 — Pilot | E1 — Release candidate |
|---|---|---|
| Workdays trong project | 1 | 1–3 |
| Tổng thời lượng video nguồn | Tối đa 30 phút | Tối đa 120 phút |
| Assets nguồn video + ảnh | Tối đa 30 | Tối đa 100 |
| Thời lượng một clip | Không vượt tổng E0 | Tối đa 30 phút |
| Phiên đồng hồ camera | Dữ liệu đơn giản có scope rõ trong pilot | Tối đa 2 camera sessions đã được định danh/kiểm clock policy |
| Video nguồn | Tới 4K60 trong codec/format matrix đã qua thử | Tới 4K60 trong codec/format matrix đã qua thử |
| Máy mục tiêu | M1 Pro 16 GB được kiểm thực | Cấu hình đã qua đầy đủ suite; không suy sang mọi Mac |
| Story/output | 1–3 bản khả thi, mặc định 45–90 giây, luôn <180 giây | Cùng hợp đồng, không nới cổng sự thật để tăng completion |
| Tốc độ voice | 1× theo preset/version đã kiểm | 1×; thay preset phải xét lại quality/timing |
| Trạng thái lúc soạn v3.1 | Chưa kiểm chứng | Chưa kiểm chứng |

“Tới 4K60” không thay danh sách width/height/fps/codec/profile cụ thể trong capability matrix. Định dạng như DCI 4K, video lớn hơn UHD hoặc ảnh rất lớn không được suy hỗ trợ từ chữ “4K”; phải có dòng fixture của đúng kích thước/decoder. Đếm assets nguồn tách khỏi số artifacts/proxy do app tạo.

Hai camera sessions là hai phạm vi đồng hồ theo định nghĩa ở 02, không tự là hai workdays hay hai người quay. Nếu dữ liệu cần nhiều session hơn, thông báo vượt profile và mở quy trình kiểm mở rộng; không ép offset sai để vừa giới hạn.

Preflight dữ liệu vượt envelope phải cho biết phần vượt và lựa chọn phù hợp: chia project có chủ đích, dùng profile thử nghiệm đã khai báo, hoặc chờ profile mở rộng. Không tự bỏ clip/frame hoặc tăng tốc voice để làm dữ liệu vừa envelope.

## 5. Ma trận nền tảng/capability phải được điền bằng số đo thật

Các ô dưới đây là **ứng viên hoặc quyết định thiết kế**, không phải kết quả pass. Mỗi capability có ID/profile riêng, build hash và evidence run. Unknown availability phải chặn vai trò cần nó hoặc dùng fallback đã công bố, không giả định SDK mới nhất là máy người dùng.

| Thành phần | Hợp đồng/ứng viên | Bằng chứng cần lưu |
|---|---|---|
| CPU/memory | Apple Silicon, M1 Pro 16 GB mục tiêu ban đầu | Model máy, RAM thực, memory pressure/swap, workload/profile |
| macOS/toolchain | Minimum OS lấy từ giao điểm yêu cầu thực | macOS build, deployment target, Xcode/Swift/SDK, architectures |
| `.app`/workers | Bản Release arm64 và quyền process/file thật | Cách ký/đóng gói, worker launch/shutdown, quyền đọc snapshot/ghi attempt |
| Database/filesystem | SQLite pinned runtime, local APFS active project | Version/options, WAL/FULL, lock, flush/rename/crash/restore fixtures |
| Video decode | MOV/MP4/M4V, H.264/H.265 và VFR là candidates | Codec/profile/bit depth/size/fps/rotation/timebase, actual frame decode |
| Ảnh | JPG/PNG/HEIC là candidates | Decode orientation/color/size, bounded-memory behavior |
| HDR→SDR | Chỉ đường tone-map đã validate với tags rõ | Transfer/primaries/range, policy, golden image/video comparison |
| Render | 24/1, 2160×3840; candidate H.264/MP4 + AAC | API/settings đọc lại, codec availability, output QC và `.drp` reopen |
| Resolve | Installed version/API thật, scripting local capability | 10 giây spike, readback IDs/signatures, append/render/reconcile/manual handoff |
| VLM/LLM | Qwen3-VL 4B/8B MLX, Qwen3-8B candidates | Repo/revision/config/processor/runtime/prompt, coverage/quality/RAM |
| ASR | whisper.cpp large-v3 đa ngôn ngữ candidate | Build/backend/weights checksum, tiếng Việt, no-audio/no-speech fixtures |
| TTS | VieNeu v3 Turbo ONNX/CPU candidate | SDK/graph/codec/phonemizer/preset, quyền dùng, speech/timing quality |
| Ảnh/event matching | DINOv2 + metadata/local matching candidates | Retrieval recall, wrong-pair rejection, exact-use gate riêng |
| SED/alignment/tracker | Chọn theo capability gate ở 03 | Nhiệm vụ đạt/chưa đạt, fixture âm thanh/căn lời/crop, fallback trung thực |
| Offline | Không gọi/tải ngoài trong project | Chạy mất mạng từ `.app` đã đóng gói và đủ phụ thuộc |
| UI | Native input, accessibility, multiwindow/resizing | Release app, dataset stress, p95 nhẹ, memory trend, recovery logs |

Model 32B từng có config không khớp tên thư mục và weights khoảng 18 GB không là mặc định trên 16 GB. Không sửa wired-memory setting hoặc dựa swap để ép chạy. FLUX/SUPIR/matting/depth không tự trở thành phần bắt buộc của quy trình POV.

## 6. Quyền xác nhận và cách xử lý thông tin thiếu

| Tình huống | Cách xử lý chuẩn | Việc bị cấm |
|---|---|---|
| Brief đã lưu, facts mới là nháp | Cho kiểm/sửa/xác nhận đúng scope khi cần dùng | Nhấn tiếp tục đồng nghĩa xác nhận tất cả |
| Chi tiết phụ chưa chắc | Bỏ khỏi câu chuyện hoặc giữ unknown | Gán certainty để lời kể trôi chảy |
| Claim cốt lõi chưa rõ | Hỏi ngắn kèm evidence; chặn phần phụ thuộc | Dừng toàn bộ phân tích độc lập hoặc kể như chắc chắn |
| Người dùng chọn “Chưa biết” | Lưu resolution, bỏ/đổi góc kể nếu cần | Hỏi lặp đến khi nhận câu trả lời mong muốn |
| Người dùng bỏ chi tiết | Bỏ claim/beat phụ thuộc và kiểm lại script | Giữ tiền đề đó trong một câu đùa |
| Sự kiện ngoài camera đã xác nhận | Kể ngôi thứ nhất/đúng nguồn; B-roll là minh họa khi phù hợp | Gắn B-roll làm bằng chứng trực tiếp của đúng thời điểm |
| Hai nguồn có vẻ mâu thuẫn | Giữ cả hai, xem context/clock/scope, review hoặc bỏ claim | Tự chọn nguồn thuận tiện cho concept |
| Không đủ ba câu chuyện | Chỉ đưa 1–3 bản thực sự khả thi | Thêm sự cố/nhân quả để đủ số phương án |
| Search hết budget | Ghi đúng trạng thái, mở rộng/fallback có giới hạn | Tuyên bố đã chứng minh constraints vô nghiệm |
| Không có output đủ gate | Báo thiếu gì, giữ dữ liệu và đường bổ sung | Xuất bản lỗi nhưng gắn nhãn hoàn thành đạt chuẩn |

Thông tin kỹ thuật của provenance nằm trong inspector khi cần; video vẫn có thể tự nhiên. Gắn nhãn minh họa trên video khi cần tránh hiểu sai, không bắt mọi câu phải đọc metadata.

Thiếu hình không chứng minh user fact sai. User xác nhận lại cũng không xóa observation trái chiều. Resolution phải nói cách dùng hoặc loại điều đang tranh chấp; sự im lặng/không trả lời không phải đồng ý.

## 7. Risk register: điều chưa được loại bỏ bằng thiết kế

Mức ưu tiên dưới đây là mức cần xử lý khi phát triển, không phải ước lượng xác suất. **P0** có thể làm mất dữ liệu, dùng sai revision/sự thật hoặc công bố final sai gate. **P1** chặn một capability/chất lượng quan trọng trong phạm vi công bố. **P2** là mở rộng sau khi đường cơ bản đã đạt; P2 không cho phép vượt invariant.

| Rủi ro | Mức | Kiểm soát đã chốt | Rủi ro còn lại và bằng chứng phải có |
|---|---|---|---|
| Canonical data do nhiều thành phần sửa | P0 | ProjectStore single writer, typed commands, FK/expected revision | Bug store/migration vẫn có thể sai; kiểm hai cửa sổ, process thứ hai, late result |
| File gốc đổi sau preflight | P0 | Sealed snapshots, acquisition verify, new source revision | Acquisition/corruption ngoài app cần fault fixture; không dựa pathname |
| DB/artifact lệch sau crash | P0 | Publication journal, immutable blobs, startup reconcile | Từng cửa sổ crash/rename/ACK phải chạy thật |
| Worker cũ ghi kết quả sau cancel | P0 | Session/fencing, revoke trước dừng | Kill/resume/restore và result muộn phải bị loại; không chỉ test enum |
| Hai job nặng cùng chạy vì heartbeat mất | P0 | Global lease, xác nhận hoạt động thực dừng | Native backend/Resolve có thể treo; không grant lease khi chưa rõ |
| Resolve append/render bị replay | P0 | Intent trước call, readback, serialize, reconcile | API không quan sát đủ có thể block; không giả effect absent |
| Chỉnh tay bị ghi đè hoặc dùng approval cũ | P0 | Managed/manual branch, drift gate, revision timeline | Effect readback không toàn diện; fixture trước/trong/sau render |
| Approval dùng nhầm phiên bản hoặc tái sinh WAV | P0 | Snapshot/revision/bytes pin, CAS backend | Fingerprint builder bỏ sót dependency vẫn nguy hiểm; test nghĩa/timing/mix |
| Corpus mới phản bác claim cũ nhưng DAG không thấy | P0 | Scope/query manifests, pending impact, reverse retrieval | Retrieval/verifier có thể bỏ phản chứng; test new evidence và no-impact sai |
| LLM có citation nhưng không entail câu | P0 | Atomic claims, relationship evidence, decision table | Semantic verifier false accept chưa biết; đo riêng trên held-out |
| Brief khiến OCR/hình bị “nhìn theo chuyện” | P0 | Quan sát đầu độc lập, raw revisions, separate guided pass | Models vẫn có bias chung; kiểm biển mờ/brief sai/negation |
| Backup tồn tại nhưng không restore được | P0 | Consistent backup, manifests, pins, restore thư mục mới | Thiếu media/runtime/Resolve export phải báo prerequisite; chạy restore sạch |
| GC xóa blob vừa được pin | P0 | `gc_pending` reservation, journal/generation, recheck | Unlink ngoài DB còn crash windows; thử race/power interruption theo profile |
| Migration làm mất/chuyển sai dữ liệu | P0 | Pre-backup, transaction/journal, compatibility gate | App cũ/new schema, migration giữa chừng và rollback/restore cần test |
| VFR/audio/crop làm mất bằng chứng | P0 | PTS/maps, `[start,end)`, critical-frame checks, final QC | Quy ước API/conform/màu còn cần fixture thật |
| Final khác preview ở chữ/cut/mix | P0 | Same approved media/plan, declared profile, final QC riêng | QC có thể bỏ sót; cần lỗi có chủ đích và kiểm actual output |
| Không đủ RAM dù weights nhỏ | P1 | One heavy lease, streaming/buffer/context limits, phases | Peak RAM/swap chưa đo trên profile; pause chứ không tuyên bố chạy ổn |
| All-frame vẫn bỏ lỡ/hiểu sai sự kiện | P1 | Multi-scale/context, omission audit, counterevidence | Coverage không là recall; long-context stitching cần benchmark |
| Photo match nhầm buổi/cú bấm | P1 | Retrieval + temporal/context/geometric checks, gate exact | Thiếu bằng chứng thì illustrative; ưu tiên biết từ chối đúng |
| TTS sai tên/số/từ hoặc nhịp không tự nhiên | P1 | Pin preset, WAV check, ASR đối chiếu + nghe targeted | ASR có thể cùng sai; quality tiếng Việt/gu cần nghe thực |
| SED/alignment/tracker không đạt | P1 | Capability riêng và fallback có giới hạn | Không có model đạt thì không công bố năng lực; crop vẫn phải giữ chi tiết |
| Search hết beam bị coi vô nghiệm | P1 | Bốn trạng thái, expansion/fallback, exact small-domain tests | Candidate generator/scoring yếu vẫn làm chất lượng kém; báo honest diagnostics |
| Review quá tải hoặc hỏi lại | P1 | Gom đúng nguyên nhân, priority theo tác động, resolutions | Nhu cầu hỏi thực chưa đo; báo active time/duplicates/usefulness, không cap giả |
| Đẹp/hài nhưng sai gu | P1 | Explicit preference, examples, blind review, preview approval | Không có điểm máy bảo đảm hấp dẫn; không fine-tune từ một lần chọn |
| Chạy offline thiếu artifact phụ | P1 | Install manifest/prefetch/local paths/network-off test | Loader/runtime mới có thể đổi hành vi; regression trước nâng version |
| Nguồn/quyền dùng voice/font/SFX không rõ | P1 | Manifest nguồn, version và điều kiện sử dụng trước đóng gói | Chưa có hồ sơ thì capability/tài sản chưa được cấp phép phát hành |
| UI lag, lỗi bộ gõ/focus, memory leak | P1 | Native controls, actor boundaries, bounded cache/logs, Release stress | `.async` không tự chứng minh khỏi main actor; đo Instruments/load thật |
| Gu học quá mức hoặc hiệu ứng tăng scope | P2 | Explicit profiles/project override/reset, mở rộng sau gate | Một lựa chọn là tín hiệu yếu; không biến nó thành luật cứng mọi project |

Rủi ro P0 không được đánh “đã xử lý” chỉ vì có ADR. Kết quả cụ thể phải gắn build/fixture/evidence, và nếu còn violation thì không gọi bản đó đạt gate tương ứng.

## 8. Dữ liệu và mẫu cần có khi phát triển

1. Dùng fixture POV thật có quyền sử dụng, gồm ảnh liên quan, brief đúng/sai/thiếu và những điểm mơ hồ đã biết. Bộ khởi đầu khoảng 20 clip chỉ phục vụ phát triển/pilot; tập held-out độc lập theo quy định 09.
2. Có nhiều chuyến/ngày, thời gian ước lượng, đi qua nửa đêm, clock lệch/drift, cùng địa điểm nhiều buổi, tên file xáo trộn và nguồn bổ sung muộn.
3. Có clip im lặng/không audio stream, tối/rung, chữ nhỏ, sự kiện ngắn và biên batch để đo omission thật.
4. Có lỗi có chủ đích: nguồn chỉ hỗ trợ một phần câu, nhân quả không có căn cứ, B-roll gây hiểu sai, ghép sai ảnh, caption lộ punchline và crop mất chi tiết.
5. Có 1–2 video tham chiếu hoặc mô tả gu để đánh giá nhịp; quyền xem tham chiếu không tự là quyền đóng gói/phân phối tài sản trong đó.
6. Có sample voice/đọc tên/số/tiếng Việt và preset font đủ dấu; thiếu mẫu thì ghi chưa biết mức khớp gu, không tuyên bố đã khớp.
7. Có golden projects/fixtures cho Unicode, source dời, disk đầy, permissions, sleep/wake, Resolve đóng/crash, IPC mất ACK và migration/restore.
8. Có profile Release `.app` và bản xuất thật trên máy mục tiêu. UI stress 1.000 assets và 2 giờ soak ban đầu không thay full analysis benchmark hoặc thời gian chạy dài nhất được công bố hỗ trợ.

Không chia các frame cùng video/chuyến vào development và held-out rồi gọi chúng độc lập. Người dùng có thể tham gia đánh giá mẫu và duyệt thành phẩm; không yêu cầu họ tự gán nhãn mọi frame của mỗi project mới.

## 9. Những giới hạn chờ lâu hơn không xóa được

Không thể suy ra chắc chắn ý định, ký ức, danh tính, lý do đi nhầm hoặc sự kiện không quay chỉ bằng xem lại source nhiều lần. Dùng lời người dùng đúng nguồn hoặc giữ chưa biết.

Đưa mọi frame vào model không đồng nghĩa hiểu đúng mọi frame. Hai model cùng họ hoặc dùng cùng chứng cứ có thể cùng sai; lặp câu trả lời không tự tăng độ chắc. Confidence do model tự báo không phải xác suất đã hiệu chuẩn.

Chia batch nhỏ giải bài toán RAM nhưng có thể mất quan hệ dài. Event/evidence graph và cửa sổ nhiều thang thời gian là kiểm soát cần thử, không là bằng chứng long-context đã được giải quyết.

Chất hài, nhịp và gu cần người xem/nghe mẫu. Tư liệu ít tình tiết không tự trở nên hấp dẫn nhờ thêm hiệu ứng; kể ngắn, đổi trọng tâm hoặc báo thiếu là kết quả đúng hơn bịa sự cố.

4K/24 fps không bảo đảm video đẹp. Nguồn, ánh sáng, crop, cadence, màu, audio, chữ, bố cục và câu chuyện có các phép kiểm riêng. Overlay raster không tự biến thành caption native sửa được.

Backup/config/seed không tự tái tạo được output AI giống hệt. Giữ media bytes đã duyệt và kiểm restore là điều kiện của khả năng tiếp tục công việc.

## 10. Quy tắc số đo và thay đổi ngưỡng

Tài liệu 09 là nguồn chuẩn duy nhất cho các mục tiêu nghiệm thu v0.1, denominator, loại lỗi và cách đánh giá. Các tỷ lệ/ngưỡng trong đó là **mục tiêu kỹ thuật đề xuất**, không phải độ chính xác đã đạt của dự án.

- Khóa dataset development/held-out và profile sau pilot trước khi xem kết quả held-out.
- Báo sample size, denominator, số lỗi và khoảng bất định phù hợp cho metric không deterministic; ghi correlation theo chuyến, không coi mọi frame là mẫu độc lập.
- Báo đồng thời abstention/unknown, số claim được dùng, recall sự kiện quan trọng và completion trong đúng stage/envelope.
- G2 báo đầu ra harness `analysis_eligible`; G3 báo `script_ready`; G5 mới báo project/final completion. Không dùng denominator của một stage để làm đẹp stage khác.
- Zero critical violation trên suite đã công bố là cổng của suite đó, không là lời hứa ứng dụng sẽ không bao giờ lỗi trên mọi nguồn.
- Exact-photo use có gate riêng; chưa đạt thì chỉ illustrative/none. Không buộc G2 phải đạt một capability sáng tạo chưa nằm trong gate đó.
- Review active time, mức hữu ích và câu hỏi trùng được đo; không áp một cap tùy ý để người dùng nhận ít câu hỏi nhưng chuyện sai.
- Nếu thay threshold/policy vì lý do sản phẩm hợp lý, ghi ADR revision, tác động và test plan độc lập mới. Không sửa tiêu chí chỉ để biết trước một test thất bại sẽ pass.

## 11. Ma trận traceability

Các requirement IDs dưới đây được tài liệu 09 quản lý. Khi đổi code/contract, cập nhật evidence map của chúng thay vì tạo một checklist thứ hai đã tick sẵn.

| Quyết định/rủi ro | Contract cần đọc | Yêu cầu nghiệm thu liên quan | Gate chứng minh |
|---|---|---|---|
| Source snapshot, external source mutation | 02 §8, 05 §6–7 | `DATA-01`, `DATA-02` | G1; hồi quy G5 |
| Writer authority, save ACK, revision conflict | 02 §7, 05 §2/9, 10 | `DATA-03`, `DATA-04`, `UI-*` | G1; UI G5 |
| Artifact publication/crash consistency | 05 §6–7 | `DATA-02`, `JOB-*` | G1 |
| Late attempt/session/fencing | 05 §4–5 | `JOB-01`, `JOB-03`, `JOB-04` | G1 |
| Resource pressure/lease | 03, 05 §5 | `JOB-02`, `JOB-05` | G1, G2; soak G5 |
| Corpus/retrieval/negative dependency | 02 §11, 07 | `DATA-05`, `AI-*` | G2 |
| Fact provenance/support/causal claim | 02 §3–6, 08 | `AI-*`, `STORY-*` | G2; story G3 |
| Full-frame coverage, short events, omissions | 02 §9–10, 07–08 | `AI-*`, `MEDIA-*` | G2 |
| TTS thực và khả năng dựng | 03–04, 07 | `STORY-*`, `MEDIA-*` | G3 |
| Search-status honesty và user locks | 04, 07 | `STORY-*` | G3 |
| Script/preview approval và giữ bytes | 02 §14–15, 05 §9 | `DATA-04`, `STORY-*`, `UI-*` | G3–G4; final G5 |
| Resolve capability/codec/API | 04, 05 §8 | `RES-01`, `RES-05`, `MEDIA-*` | G0; media đầy đủ G4 |
| Resolve effect journal/reconcile | 05 §8 | `RES-02`, `JOB-02` | G1 adapter harness; tích hợp G4–G5 |
| Managed/manual drift | 04, 05 §8–9 | `RES-03`, `RES-04` | G4–G5 |
| PTS/CFR/audio/color/crop | 04, 07 | `MEDIA-*` | G2 mapping; G4 preview; G5 final |
| Backup/restore/migration | 05 §10–11 | `DATA-06`, `DATA-07`, `REL-*` | G1 core; portable/reopen G5 |
| GC/ref/pin race | 02 §7/16, 05 §12 | `DATA-08` | G1; stress G5 |
| Offline và đủ phụ thuộc | 03, 05 §13 | `OFF-*` | G0 smoke; đầy đủ G2/G5 |
| UI text/focus/accessibility/performance | 10 | `UI-*` | G0 smoke; G5 đầy đủ |
| Support envelope và project completion | 06 §4–5, 09 | `REL-*` | G5 trong profile thực đã đo |
| Sáu nâng cấp sáng tạo | 04, 07, 09 | Các capability/requirement tương ứng của 09 | Theo từng gate; không tự coi tất cả là G2 |

“G1 adapter harness” là phép thử side-effect/journal cô lập, không đòi toàn bộ pipeline sáng tạo hoặc preview UI đã xong. G0 sample TTS chỉ kiểm runtime chạy được; không thay cổng chất lượng lời đọc/nhịp ở G3.

## 12. Khi thay đổi một quyết định

Mỗi thay đổi có `adr_id`, revision mới, lý do, dữ liệu dẫn tới thay đổi, owner contract, compatibility/migration impact và kế hoạch kiểm. Giữ quyết định cũ để truy nguyên build từng dùng nó.

1. Xác định đây là đổi capability, policy dữ liệu, schema, profile media, model/runtime hay envelope; không gộp dưới tên “tối ưu nhỏ”.
2. Liệt kê artifact/approval/cache cần xét lại; quyết định không tác động phải có cơ sở, nhất là corpus và bytes đã duyệt.
3. Cập nhật đúng tài liệu owner và links/traceability; không thêm một phụ lục trái quy tắc cũ rồi giữ cả hai làm chuẩn.
4. Nếu schema/bytes/Resolve ownership đổi, bổ sung migration/recovery fixtures trước rollout.
5. Nếu quality threshold/profile/model đổi, dùng development rồi held-out độc lập theo 09; không ghi đè kết quả cũ như cùng một cấu hình.
6. Ghi build/evidence/profile được phép phát hành, hạn chế và cách quay về dữ liệu/phiên bản an toàn đã kiểm.

Một nâng cấp không được giữ lại chỉ vì có tên thuật toán mới, model lớn hơn hoặc UI đẹp hơn. Nó phải cải thiện nhiệm vụ đã đo trong khi giữ các cổng nguồn, dữ liệu, duyệt và phục hồi.

## 13. Điều kiện tiếp tục và điều kiện dừng

Tiếp tục mở rộng khi vòng **snapshot → evidence/brief → review → script approval → preview approval → final QC → restore** hoạt động trong envelope được công bố và có evidence đúng gate. Không buộc người dùng xem lại mọi source hoặc trả lời mọi câu hỏi phụ để gọi đó là tự động hóa.

Dừng nhánh phụ thuộc khi thiếu quyền/capability/resources, source/hash sai, critical claim chưa đủ hỗ trợ, approval stale, corpus impact chưa rõ, Resolve effect chưa reconcile hoặc final QC còn lỗi chặn. Giữ dữ liệu, lý do và hành động tiếp tục; nhánh độc lập vẫn chạy nếu tài nguyên cho phép.

Retry/tự sửa có budget hữu hạn và checkpoint. Hết lượt không phải đạt. Sửa nghĩa/kịch bản/shot/voice/mix sau duyệt phải tạo revision và trở lại gate phù hợp; không nhờ nhãn “tự sửa” để vượt quyền người dùng.

Chỉ sau các cổng này mới mở rộng nhiều hiệu ứng, nhiều phong cách, model lớn hơn, roundtrip Resolve hoặc support envelope rộng hơn. Mỗi thứ mở rộng thêm có thể làm tăng độ khó phục hồi và phải được đánh giá theo chính dữ liệu của nó.

## 14. Nguồn nền tảng và giới hạn của trích dẫn

- [SQLite WAL](https://www.sqlite.org/wal.html) hỗ trợ việc hiểu journal, concurrency và durability tradeoffs; runtime thực vẫn phải được khóa/kiểm.
- [SQLite Online Backup API](https://www.sqlite.org/backup.html) là cơ sở cho snapshot DB nhất quán; không chứng nhận portable backup của AIVideo đã restore được.
- [Apple App Sandbox: accessing files](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) là nguồn về quyền file/bookmarks khi dùng sandbox profile.
- [Apple: improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) hỗ trợ nguyên tắc xử lý main thread; target UI của AIVideo vẫn phải đo trên build/fixture thật.
- Model/runtime sources nằm trong [03-MODELS-AND-RESOURCES.md](03-MODELS-AND-RESOURCES.md); media và thuật toán nằm trong [04-SCRIPT-AND-EDIT.md](04-SCRIPT-AND-EDIT.md), [07-OPTIMIZATION.md](07-OPTIMIZATION.md).

Các nguồn trên hỗ trợ API/nguyên tắc, không thay bằng chứng về dự án này. Chưa có mã nguồn, kết quả fault injection, benchmark và restore report thì không công bố tỷ lệ ổn định hay chất lượng đã đạt.
