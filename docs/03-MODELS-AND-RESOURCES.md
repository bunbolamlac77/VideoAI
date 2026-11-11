# 03 — Model local, profile thực thi và ngân sách tài nguyên

> **Trạng thái triển khai (2026-11-11):** đặc tả dưới đây đã được hiện thực hoá và kiểm thử;
> xem [`README.md`](../README.md) để biết trạng thái hiện tại và
> [`AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md) cho các
> lỗi đã đóng. Chỗ nào đặc tả khác mã đang chạy, mã + audit là nguồn đúng.

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả sẵn sàng để triển khai; chưa phải ứng dụng đã chạy, cấu hình đã đạt benchmark hoặc chứng nhận hiệu năng.

Tài liệu này sở hữu danh mục ứng viên model, hợp đồng cài đặt, profile thực thi và chính sách phân bổ tài nguyên. Kiến trúc tiến trình, quyền ghi dữ liệu và fencing thuộc [05-ARCHITECTURE-AND-ROADMAP.md](05-ARCHITECTURE-AND-ROADMAP.md). Hợp đồng dữ liệu thuộc [02-ANALYSIS-AND-DATA.md](02-ANALYSIS-AND-DATA.md); chỉ tiêu nghiệm thu thuộc [09-UPGRADES-AND-ACCEPTANCE.md](09-UPGRADES-AND-ACCEPTANCE.md).

## 1. Mục tiêu và những điều không được suy ra

- Ưu tiên hiểu đúng tư liệu, giữ nguồn thông tin và tạo kịch bản dựng được trước tốc độ.
- Toàn bộ suy luận, phân tích media, TTS và dựng chạy local sau một pha cài đặt riêng.
- Không dùng API AI đám mây, tự tải model hoặc tự đổi giọng làm phương án dự phòng trong project.
- Dung lượng weights không phải bộ nhớ đỉnh; số tham số không phải điểm chất lượng trên tư liệu POV.
- Một model được liệt kê ở đây chỉ là ứng viên cho một vai trò, chưa phải backend đã được sản phẩm chứng nhận.
- Chạy lâu hơn không tự làm model hiểu đúng hơn; lượt bổ sung phải giải một bất định hoặc kiểm tra bằng chứng cụ thể.
- Yêu cầu mọi frame đi qua lượt chi tiết vẫn được giữ. Chính sách tài nguyên không được âm thầm thay nó bằng lấy mẫu thưa.

## 2. Thông tin máy và khảo sát cũ

| Mục | Thông tin được kế thừa | Quy tắc sử dụng trong v3.1 |
|---|---|---|
| Máy mục tiêu | Apple M1 Pro, 16 GB unified memory | Cấu hình mục tiêu cần đo; app phải đọc phần cứng thực tế |
| Model cũ | `/Users/phuthanh/LLMLocalAI`, khoảng 109 GB | Snapshot lịch sử; không giả định còn tồn tại hoặc có đúng revision |
| Model từng mang tên 32B | Có ghi nhận config `qwen2_5_vl`, khoảng 18 GB weights | Đọc config và hash thật; không chọn bằng tên thư mục |
| Dung lượng trống | Khoảng 117 GiB ở một khảo sát cũ | Không sử dụng làm ngân sách hiện tại |
| Resolve | Studio 21.1.2 được ghi trong tài liệu trước | Probe phiên bản, quyền scripting, codec và API đang cài |
| Đầu ra | Final 2160×3840, 24/1 fps | Preset mục tiêu; không chứng minh nguồn có chi tiết 4K dọc |

Không dùng model 32B kể trên làm mặc định cho máy 16 GB. Không sửa `sysctl` wired-memory hoặc dựa vào swap để ép một cấu hình không đạt. FLUX, SUPIR, matting và depth không được nạp trong luồng POV thông thường chỉ vì máy đã có weights.

## 3. Phạm vi tải cần được chứng minh

E0 và E1 là phạm vi thử nghiệm ban đầu, không phải cam kết app hiện đã xử lý được những tải này.

| Profile phạm vi | Workday | Tổng video | Số asset video + ảnh | Giới hạn bổ sung |
|---|---:|---:|---:|---|
| E0 — pilot | 1 | Tối đa 30 phút | Tối đa 30 | Nguồn tối đa 4K60 trong capability matrix đã vượt cổng |
| E1 — ứng viên phát hành | 1–3 | Tối đa 120 phút | Tối đa 100 | Tối đa 30 phút/clip, tối đa 2 phiên camera, nguồn tối đa 4K60 đã được hỗ trợ |

- Chỉ ghi một profile là được hỗ trợ sau khi đã chạy đủ kiểm thử tương ứng.
- Nguồn vượt phạm vi được công bố phải hiện rõ là ngoài phạm vi đã kiểm chứng trước khi chạy tác vụ nặng.
- Người dùng có thể chia project hoặc chọn một profile thử nghiệm được mô tả rõ; không biến giới hạn vận hành thành lỗi chất lượng AI khó hiểu.
- Kiểm UI với 1.000 asset không chứng nhận pipeline AI xử lý được 1.000 asset.
- Mở rộng phạm vi cần ADR, dữ liệu kiểm tra bổ sung và kết quả mới; không chỉ tăng một con số trong UI.

## 4. Danh mục ứng viên giữ lại

Kích thước dưới đây là ước lượng artifact được kế thừa, không phải số bytes đã kiểm kê trong phiên này và không phải RAM lúc chạy.

| Vai trò | Ứng viên | Artifact tham khảo | Điều kiện chọn |
|---|---|---:|---|
| Thị giác nền | `mlx-community/Qwen3-VL-4B-Instruct-4bit` | Khoảng 3,11 GB | Vượt bài hiểu hành động, OCR, thời gian và bộ nhớ trên POV thật |
| Thị giác đối chiếu | `mlx-community/Qwen3-VL-8B-Instruct-4bit` | Khoảng 5,78 GB | Chạy tuần tự; chỉ bật khi cải thiện nhiệm vụ cần thiết và còn headroom |
| Tổng hợp/kịch bản | `mlx-community/Qwen3-8B-4bit` (`P-STORY-SYNTH-v1`) | 4,3 GB đã cài | Đã nối thật trong `generate_story` (`script_engine=llm`): chỉ viết lại claim đã duyệt, sai schema/số liệu thì fallback nguyên văn |
| ASR | `ggerganov/whisper.cpp`, `ggml-large-v3.bin` | Khoảng 3,1 GB | Bản đa ngôn ngữ; đo riêng tiếng Việt và nguồn khó |
| TTS tiếng Việt | `contextboxai/Kokoro-Vietnamese` (Apache-2.0, 82M) | 327 MB (`kokoro_vi.pth`) + voicepacks | Engine thay VieNeu: preset voicepack, CPU fp32, RTF ≈ 0.3 đo trên M1 Pro; xuất 24 kHz rồi resample 48 kHz PCM16 |
| Tạo ứng viên ảnh/shot | `facebook/dinov2-base` | Kiểm kê theo revision | Đo recall ứng viên; embedding không được tự xác nhận cùng sự kiện |

Qwen3-VL 4B và 8B cùng họ không tạo thành hai nguồn sự thật độc lập. Đồng thuận giữa chúng không được nhân thành confidence mới. DINOv2 tạo ứng viên để kiểm tra tiếp, không thay thế temporal/geometric verification.

## 5. Capability registry bắt buộc

Mỗi vai trò có trạng thái `candidate`, `validated` hoặc `disabled` trong cấu hình năng lực, kèm lý do và báo cáo kiểm tra. Đây là trạng thái backend, không thay thế trạng thái job/claim trong dữ liệu chuẩn.

| Năng lực | Phương án ban đầu | Khi chưa qua cổng |
|---|---|---|
| Hiểu hình và hành động | Qwen3-VL theo profile đã khóa | Giữ quan sát chưa đủ hỗ trợ; không tự khẳng định sự kiện |
| OCR tiếng Việt | VLM/crop; Apple Vision local chỉ sau probe | Cho xem source rõ hơn hoặc hỏi đúng chi tiết; không sinh thêm chữ |
| Tiếng click, còi, âm thanh hiện trường | Detector local phải được chọn bằng benchmark riêng | Giữ âm gốc; không gán nhãn sự kiện âm thanh chắc chắn |
| Căn từ/cụm tiếng Việt | Backend alignment local qua bộ kiểm riêng | Dùng cue cụm do người dùng kiểm hoặc chặn xuất phụ đề cần độ chính xác chưa có |
| Crop theo chủ thể | Detector/tracker có kiểm tra trên shot thật | Dùng fit/bố cục tĩnh đã duyệt, không cắt mất bằng chứng |
| Ghép ảnh đúng cú bấm | Truy xuất + kiểm thời gian/hình học/ngữ cảnh | Chỉ dùng minh họa phù hợp cho đến khi đạt cổng exact-photo |
| Chất hài, giọng đúng gu | Review mù và mẫu người dùng nghe/xem | Ghi chưa đạt gu; không tự chấm đạt bằng điểm LLM |

Không gọi Whisper là sound-event detector. Không biến việc backend tạo được một file WAV thành chứng cứ lời đọc, phát âm hoặc nhịp đã đạt.

## 6. Runtime profile có phiên bản

Mỗi lần chạy sử dụng một `runtime_profile_id` bất biến trong input manifest. Profile tối thiểu ghi:

- Model ID, revision, checksum SHA-256, quantization và config thực tế.
- Runtime/backend, Python/SDK version, processor, tokenizer và chat template.
- Prompt/policy revision, generation settings và seed nếu backend hỗ trợ.
- Kích thước cửa sổ, overlap, giới hạn pixel/token, kích thước output và chính sách xử lý truncate.
- Audio sample rate, voice preset, codec/phonemizer revision nếu có.
- Danh sách capability đã qua cổng và `capability_report_id`.
- Ngân sách bộ nhớ, hàng đợi, buffer, artifact tạm và điều kiện pause đã đo/chốt.
- Phạm vi nguồn E0/E1 hoặc profile mở rộng đã được công bố.

Seed được lưu để hỗ trợ tái hiện; seed và cùng config không bảo đảm output có cùng bytes. Artifact đã duyệt phải được giữ theo hash, không được âm thầm sinh lại.

## 7. Lưới phát triển cho lượt thị giác

`P-VISION-DEV-v1` là lưới thử trên tập phát triển, không phải cấu hình đã chứng minh tốt nhất. Thử tuần tự từ cấu hình nhỏ, dừng cấu hình không đủ bộ nhớ và ghi kết quả thất bại.

| Biến | Ứng viên thử ban đầu | Quy tắc |
|---|---|---|
| Model | 4B; 8B sau cổng tài nguyên | Không cùng nạp hai model |
| Frame/cửa sổ chi tiết | 8, 16, 32 | Mọi frame vẫn phải xuất hiện trong ít nhất một cửa sổ hợp lệ |
| Overlap | Khoảng một phần tư cửa sổ, làm tròn lên theo profile | Frame chồng lấn không cộng thêm coverage |
| Ngân sách pixel full-frame | 262.144, 589.824, 1.048.576 pixel trước quy đổi hợp lệ của processor | Giữ tỷ lệ khung; ghi kích thước sau processor |
| Output budget | 256, 512, 1.024 token theo nhiệm vụ | Truncate không được coi là kết quả rỗng hợp lệ |
| Context trước/sau | Cửa sổ lân cận và event có evidence | Không chỉ nhồi toàn bộ báo cáo cũ vào prompt |

- Không bắt chạy toàn bộ tích Descartes của lưới. Chọn thí nghiệm có câu hỏi rõ và loại cấu hình lỗi sớm.
- Khoảng thời gian của một cửa sổ tính từ PTS thực; cùng số frame không có cùng độ dài trên mọi nguồn.
- Quan hệ dài hạn dùng cấp clip/workday và truy xuất bằng chứng bổ sung theo [08-ACCURACY-FIRST.md](08-ACCURACY-FIRST.md).
- Crop chi tiết được thêm sau full-frame context; crop nhỏ không thay thế việc quan sát toàn frame.
- Mọi thay đổi sampling của processor đều phải được đo qua adapter; không chỉ tin tham số CLI.
- Profile chọn được phải khóa trước held-out. Chỉnh lại vì đã nhìn lỗi held-out đòi tập kiểm độc lập mới theo tài liệu 09.

## 8. Hợp đồng adapter đầu vào model

Adapter nhận danh sách frame từ sealed source snapshot, kèm frame ID, PTS/time base, transform và vai trò cửa sổ. Nó không giao một đường dẫn video dài cho thư viện rồi mặc định thư viện xem đủ frame.

1. Giải mã theo presentation order và ghi chỉ mục PTS từ snapshot đã xác minh.
2. Tạo cửa sổ hữu hạn, overlap đúng profile, đưa full-frame context tới processor.
3. Ghi manifest đầu vào trước processor và ánh xạ đầu vào thực sau processor.
4. Kiểm frame nào bị sampling, lặp, ghép temporal patch, crop hoặc truncate.
5. Với temporal patch, giữ ánh xạ từng frame nguồn vào tensor/token group; không gọi một group là một frame nguồn.
6. So coverage bằng hợp frame ID duy nhất; phát hiện vùng thiếu và lập job bù có phạm vi.
7. Nếu runtime không cho kiểm chứng mapping đủ tin cậy, capability all-frame chưa đạt; không báo phân tích đầy đủ.
8. Giữ output thô, output đã parse, lỗi validation, profile và attempt identity để kiểm toán.

Ghi input manifest thực không yêu cầu lưu mọi tensor/frame 4K vô hạn. Giữ manifest, hash, chỉ mục và frame bằng chứng cần thiết; tái trích từ snapshot khi cần.

## 9. TTS tiếng Việt và bất biến audio

- Dùng đường ONNX/CPU fp32 của candidate đã khóa; không áp tối ưu int8/VNNI của Intel cho M1 theo suy đoán.
- Prefetch đầy đủ graph, codec, phonemizer và preset được SDK thực sự dùng.
- Preset Adam/Adam bựa chỉ xuất hiện nếu `list_preset_voices` của revision đã cài trả về; tên preset không chứng minh đúng gu.
- Tốc độ mặc định 1×. Nhịp hài đến từ câu chữ, pause và phối hợp dựng, không từ việc âm thầm tăng tốc.
- Không dựa vào reading-style parameter đã bị bỏ; cue cảm xúc chỉ bật nếu backend đã probe và mẫu nghe đạt.
- Tạo WAV thử cho từng phương án trước khi gắn nhãn dựng được. Lưu WAV/revision đó để dùng lại nếu người dùng chọn.
- Voice text có chuẩn hóa số/tên riêng phải lưu riêng với script gốc và bảng đối chiếu giữ nghĩa.
- Kiểm duration, thiếu/lặp từ, số, tên, pause, clipping và mức tín hiệu trên WAV thật.
- ASR hỗ trợ phát hiện bất thường; sự đồng ý của ASR không chứng minh phát âm hoặc ngữ điệu đúng.
- Đoạn nghi vấn tạo review có audio ngắn và timecode. Lỗi thay nghĩa chặn approval tương ứng.
- WAV đã duyệt là artifact được pin bằng hash. Final dùng chính bytes đó; sinh lại khác audio/timing tạo revision mới.
- Người dùng có thể import WAV của mình; vẫn phải đo thời lượng, kiểm lời và áp cùng quy tắc duyệt.
- Piper chỉ là ứng viên dự phòng sau benchmark riêng; không tự tải hoặc thay giọng đã duyệt.
- Dịch vụ VieNeu v4 không thuộc profile local này. Không tự chuyển sang dịch vụ khi SDK local lỗi.

## 10. Một resource governor trên toàn ứng dụng

App process sở hữu một governor chung cho mọi cửa sổ và mọi project. Worker không tự cấp tài nguyên cho mình.

- Chỉ một **heavy lease** hoạt động tại một thời điểm: inference nặng, render Resolve hoặc tác vụ media được đo là nặng.
- Tác vụ decode nhẹ có thể tiếp tục khi profile cho phép, nhưng buffer và hàng đợi luôn có giới hạn.
- Resolve đang mở nhưng idle vẫn được tính vào baseline bộ nhớ; không coi idle là bằng không.
- Model nặng không chạy song song với render. Tải weights của pha kế tiếp cũng cần quyền của governor.
- Mỗi lease gắn project/job/attempt/fencing token, profile, phạm vi tài nguyên và trạng thái thu hồi.
- Hủy hoặc timeout không chứng minh process đã thoát. Chỉ cấp heavy lease mới sau khi xác nhận process cũ đã dừng và tài nguyên được thu hồi. Adapter subprocess đã chết không chứng minh render trong Resolve đã dừng; heavy lease vẫn bị giữ cho tới khi reconcile được tác vụ thực.
- Worker cũ trả kết quả muộn không được publish; quy tắc fencing tại tài liệu 05 là bắt buộc.

## 11. Đo ngân sách bộ nhớ trước khi chốt

Không đặt một giá trị “model này dùng đúng X GB” từ dung lượng tải. Pilot ghi theo từng pha:

| Nhóm đo | Cần ghi |
|---|---|
| Hệ thống | Physical memory, memory pressure, swap baseline và diễn biến |
| App + core | Resident/peak memory, số cửa sổ, DB/cache/UI đang mở |
| Worker | Weights, KV cache, vision tokens, decoder/processor buffers, peak process memory |
| Resolve | Idle, import, preview, render và lúc đóng project |
| Đầu vào | Số frame, pixel, context, codec, độ dài cửa sổ, output token |
| Khôi phục | Bộ nhớ sau hủy, đóng worker, trả lease và mở lại job |

Ngân sách profile được chốt từ phần dư thực tế sau baseline app/hệ điều hành/Resolve, đỉnh đo trong ca khó và một khoản headroom có khai báo. Báo cáo phải nêu khoản dự phòng, số lần đo và phạm vi nguồn; không suy một lần chạy thành bảo đảm cho mọi video.

Trong giai đoạn chưa có profile đạt, chỉ cho chạy tác vụ probe hữu hạn với cấu hình nhỏ nhất và giám sát liên tục. Probe thất bại là kết quả năng lực, không làm project được đánh dấu phân tích xong.

## 12. Xử lý áp lực tài nguyên

1. Trước job: đọc dung lượng, trạng thái nguồn, capability và quyền lease.
2. Khi áp lực tăng: ngừng nhận thêm batch, xả hàng đợi an toàn và checkpoint tại ranh giới được hỗ trợ.
3. Có thể giảm batch theo những biến thể profile đã kiểm, giữ đủ frame và context theo chính sách; thay đổi được ghi vào attempt manifest.
4. Không giảm pixel, đổi model hoặc đổi voice âm thầm để tiếp tục. Nếu cần đổi profile có ảnh hưởng chất lượng, tạo quyết định cấu hình và đánh giá lại dependencies.
5. Khi phải kết thúc worker: revoke quyền publish trước, dừng cả process group và xác nhận thoát theo tài liệu 05.
6. Giữ job `blocked_resource` với lý do, checkpoint và hành động tiếp tục; không báo đạt vì đã hết thời gian chờ.
7. Sau khôi phục, chỉ resume đúng sealed input và profile/revision còn hiệu lực.

Heartbeat xác định worker có thể mất liên lạc, không phải chứng cứ nó không còn giữ RAM. Timeout tác vụ phải phù hợp thao tác và tiến độ; không dùng một timeout ngắn để tự bỏ kiểm tra bắt buộc.

## 13. Chu trình AI — Resolve — QC

| Pha | Thành phần giữ heavy lease | Điều kiện chuyển pha |
|---|---|---|
| Phân tích/kịch bản | Một worker model | Kết quả được publish đúng revision; process trả lease |
| Dựng timeline | Adapter Resolve theo capability | Edit plan đã validate, operation journal còn hợp lệ |
| Render preview | Resolve | Worker AI nặng đã dừng; bộ nhớ/dung lượng đủ |
| QC nội dung | Một worker model hoặc tác vụ kiểm đã định nghĩa | Render kết thúc; không giữ model và render cùng lúc |
| Sửa có kiểm soát | Core + adapter theo pha | Revision mới, đúng approval/invalidation |
| Render final | Resolve | Snapshot đã duyệt còn hiệu lực, final gate cho phép |

Nếu Resolve idle vẫn làm thiếu RAM cho QC, chỉ được save/đóng project app-managed theo lifecycle đã kiểm và xác nhận bộ nhớ đã được giải phóng. Nếu Resolve đang chứa project hoặc manual edits ngoài quyền quản lý của app, giữ `blocked_resource` và để người dùng xử lý; không kill/đóng Resolve để lấy RAM rồi làm mất chỉnh sửa. Thoát Resolve chỉ thuộc lifecycle cho phép khi không còn project/chỉnh sửa ngoài phạm vi được quản lý.

## 14. SSD, snapshots và dữ liệu tạm

25–35 GB cho bộ model/môi trường khởi đầu chỉ là dự trù lịch sử. Preflight phải kiểm kê bytes thực cho từng nhóm:

- Model/runtime/font/template/SFX đã chọn và artifact phụ của TTS.
- Source snapshots bất biến đang được project tham chiếu.
- Proxy, index, audio phân tích và frame bằng chứng.
- WAV/graphics/edit plan đã duyệt, preview/final và render tạm.
- Dữ liệu backup, journal và phần dư để hoàn tất publish an toàn.

Nguồn được chụp thành snapshot theo tài liệu 05: ưu tiên APFS clone đã xác minh khi được hỗ trợ, nếu không thì copy đầy đủ rồi seal. Không dùng hardlink làm bằng chứng bất biến. Clone không làm chi phí lưu trữ tương lai bằng không; preflight xét cả copy thực tế và khả năng COW tăng khi nguồn ngoài app thay đổi.

Thiếu dung lượng thì pause hoặc đề nghị nơi lưu được hỗ trợ. Không tự chuyển sang đọc trực tiếp nguồn có thể đổi; không xóa facts, approvals, source snapshots còn tham chiếu hoặc WAV đã duyệt để lấy chỗ.

## 15. Cache, artifact và quyền dọn dữ liệu

| Nhóm | Có thể dọn tự động theo quota? | Điều kiện |
|---|---|---|
| Proxy/frame tạm có thể trích lại | Có | Không đang dùng, không còn pin bảo vệ, có source snapshot hợp lệ |
| Output attempt chưa publish | Có sau reconciliation | Xác minh attempt không còn quyền publish và không phải artifact chuẩn |
| Source snapshot đang tham chiếu | Không | Chỉ thu hồi khi không còn references/pins theo chính sách rõ |
| WAV/graphics/edit plan đã duyệt | Không | Là nội dung đã được người dùng duyệt, không phải cache |
| Facts, review, approvals, lịch sử | Không | Phải được backup và giữ tính nhất quán |
| Model không còn dùng | Chỉ theo thao tác quản lý model rõ ràng | Kiểm project/profile đang cần và khả năng restore offline |

Cache key gồm source revision, model/processor/runtime, prompt/policy, config, media mapping và fingerprint đầu vào. Cache đúng key vẫn phải có bytes/hash hợp lệ trước khi dùng.

## 16. Manifest cài đặt và đóng gói

Manifest phải ghi model/runtime cùng checksum, local path, license/source, revision và dependency graph. Không tải theo `main` mỗi lần chạy. Các graph ONNX, tokenizer, preset, phonemizer, font và template đều là dependencies thật.

- **Phân tách pha setup và chạy project:**
  - Tải/cài đặt model là một pha riêng biệt (thực hiện qua công cụ `tools/setup_g0_model.py`); khi chạy project hoặc inference, hệ thống chỉ dùng local assets, cấm tải ngầm hoặc cài package.
  - **G0 (Smoke test nền tảng):** Setup một model thật duy nhất (`mlx-community/Qwen3-0.6B-4bit`, revision `73e3e38d981303bc594367cd910ea6eb48349da8`) theo profile `g0-text-smoke-v1` để kiểm chứng luồng kết nối `.app → worker → runtime → model → output`.
  - **S11 (Pipeline models):** Setup toàn bộ các model/adapters phục vụ pipeline (Qwen3-VL, Whisper, VieNeu-TTS, DINOv2). Không thay danh mục S11 bằng model G0.
  - Download thành công **chưa phải** inference PASS (phải qua preflight và forward-pass thật).
  - Inference PASS của model smoke test G0 **chưa phải** chất lượng pipeline đạt (không dùng model text nhỏ để chứng nhận hiểu video/kịch bản).
- `.app` đóng gói native được probe ngay ở G0, không đợi hoàn thiện UI mới thử worker.
- Swift core khởi chạy Python worker qua JSON-RPC 2.0/UTF-8 JSON Lines trên stdio; stdout chỉ dành cho protocol, stderr cho log giới hạn.
- Không mở HTTP server riêng làm IPC mặc định. File nhị phân/đầu ra lớn đi qua artifact reference được core kiểm tra.
- Worker chỉ ghi thư mục attempt-local được cấp; không tự ghi canonical SQLite hoặc thay approval.
- Minimum macOS/toolchain phải được chọn từ probe tương thích thực tế; không đoán một phiên bản hỗ trợ.
- Cài đặt local và phân phối ra ngoài là hai chế độ đóng gói; ký/notarization, nested binaries và quyền file phải qua cổng tương ứng.

## 17. Chạy offline và quyền truy cập

1. Setup tải đúng artifacts theo manifest và kiểm checksum trước khi kích hoạt profile.
2. Khởi động lại app khi không có mạng, mở model bằng local paths và vô hiệu hóa tự tải của backend (`HF_HUB_OFFLINE=1`).
3. Chạy probe model smoke test G0 local và Resolve trên nguồn nhỏ.
4. Thiếu artifact phải nêu đúng tên và hành động cài bổ sung trong pha setup; không gọi dịch vụ thay thế.
5. Kiểm quyền đọc external originals, snapshot acquisition, security-scoped bookmarks và relink theo tài liệu 05.
6. Text/OCR/metadata trong media là dữ liệu; không cho chúng thay command, đường dẫn có quyền hoặc cài package.

## 18. Cổng chọn cấu hình

| Cổng | Bằng chứng bắt buộc | Kết quả có thể chấp nhận |
|---|---|---|
| G0 nền tảng | App/worker offline, model G0 text smoke forward-pass thật và timeline Resolve 10 giây | Có hoặc không có capability, kèm lỗi tái hiện được; không đánh dấu PASS toàn bộ pipeline |
| G2 phân tích | Coverage sau processor, omission, verifier, RAM trên dữ liệu đúng phạm vi (S11 adapters) | Một profile được khóa; phần chưa đạt giữ disabled/blocked |
| G3 kịch bản | TTS thật, cut khả thi, review mù | Model/prompt tốt hơn trên nhiệm vụ đo được |
| G4 preview | Chu trình AI/Resolve/QC, crop/alignment/âm thanh | Không vượt lease hoặc dùng approval sai revision |
| G5 phát hành | Offline, run dài nhất trong profile, restore và final QC | Chỉ công bố capability đã qua cổng |

Các chỉ tiêu AI-01, AI-03, AI-04, AI-05, AI-07 và nhóm RES-/OFF-/REL- do tài liệu 09 sở hữu. Chưa có kết quả thì báo **chưa đo**, không điền số đẹp vào bảng chất lượng.

## 19. Quyết định sau benchmark

- Giữ model nhỏ hơn nếu model lớn không cải thiện nhiệm vụ cần thiết hoặc phá ngân sách.
- Chỉ thay quantization/context/processor sau một so sánh có cùng tập phát triển và bộ giữ kín phù hợp.
- Ghi cả cấu hình thất bại, peak resource và lý do loại; không chỉ ghi mẫu thành công.
- Chất hài, tiếng Việt và phong cách phải nghe/xem trên mẫu thực; không thay bằng benchmark học thuật chung.
- Một profile đạt E0 chưa tự đạt E1. Một lần chạy ngắn không chứng minh memory leak hoặc resume của lượt dài.

## 20. Nguồn chính thức để đối chiếu khi triển khai

- [Qwen3-VL chính thức và xử lý đầu vào video](https://github.com/QwenLM/Qwen3-VL/blob/main/qwen-vl-utils/src/qwen_vl_utils/vision_process.py).
- [Qwen3-VL 4B MLX](https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/tree/main).
- [Qwen3-VL 8B MLX](https://huggingface.co/mlx-community/Qwen3-VL-8B-Instruct-4bit/tree/main).
- [Qwen3 8B MLX](https://huggingface.co/mlx-community/Qwen3-8B-4bit/tree/main).
- [MLX-VLM](https://github.com/Blaizzy/mlx-vlm) và [MLX-LM](https://github.com/ml-explore/mlx-lm).
- [Whisper weights cho whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp/tree/main) và [whisper.cpp](https://github.com/ggml-org/whisper.cpp).
- [VieNeu v3 Turbo](https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo) và [SDK của tác giả](https://github.com/pnnbao97/VieNeu-TTS).
- [DINOv2 base](https://huggingface.co/facebook/dinov2-base).

Liên kết giúp kiểm xuất xứ; revision/checksum trong manifest mới xác định thứ thực sự được chạy. Các bước triển khai và hồ sơ bằng chứng nằm ở [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md).
