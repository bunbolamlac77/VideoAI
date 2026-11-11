# 04 — Kịch bản có bằng chứng, media conform và dựng đúng bản duyệt

> **Trạng thái triển khai (2026-11-11):** đặc tả dưới đây đã được hiện thực hoá và kiểm thử;
> xem [`README.md`](../README.md) để biết trạng thái hiện tại và
> [`AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](AUDIT_20261111_REVIEW_AND_TEST_PLAN.md) cho các
> lỗi đã đóng. Chỗ nào đặc tả khác mã đang chạy, mã + audit là nguồn đúng.

**Phiên bản:** 3.1 · **Ngày:** 06/11/2026.  
**Trạng thái:** đặc tả sẵn sàng để triển khai; các thuật toán, preset và tích hợp Resolve chưa được chứng nhận bằng lần chạy thực.

Luồng chuẩn: dữ kiện có nguồn → làm rõ đúng phạm vi → 1–3 phương án khả thi → người dùng duyệt script → preview/QC → người dùng duyệt preview → final/QC. Tài liệu này sở hữu hợp đồng dựng và profile media `M-24-SDR-v1`. Schema/cách dùng claim theo [02-ANALYSIS-AND-DATA.md](02-ANALYSIS-AND-DATA.md); thuật toán tìm cut theo [07-OPTIMIZATION.md](07-OPTIMIZATION.md); giao dịch và Resolve recovery theo [05-ARCHITECTURE-AND-ROADMAP.md](05-ARCHITECTURE-AND-ROADMAP.md).

## 1. Hợp đồng thành phẩm

| Mục | Quyết định v3.1 |
|---|---|
| Loại nội dung | Video kể chuyện POV tiếng Việt, có người dùng biên tập và duyệt |
| Độ dài thường dùng | 45–90 giây; ít tư liệu có thể 15–30 giây |
| Trần cứng | Thời lượng phát thực dưới 180 giây |
| Timeline | 2160×3840, chính xác 24/1 fps |
| Preview | 1080×1920 từ cùng edit plan và lịch thời gian |
| Final ban đầu | SDR Rec.709; MP4/H.264 + AAC là candidate preset phải qua capability probe |
| Voice | Tiếng Việt, tốc độ mặc định 1×, có kiểm lời và audio được pin |
| Khả năng chỉnh | Clip/audio/cut riêng; mức sửa chữ/hiệu ứng được khai báo theo lớp |
| Quyền cuối | Không tự đăng TikTok hoặc nền tảng khác |

Ở 24/1 fps, timeline dưới 180 giây có tối đa 4.319 frame. Điều kiện này chưa đủ cho file cuối: audio, encoder padding và duration container sau render vẫn phải được kiểm tra. Không tự cắt lời để vượt cổng thời lượng.

## 2. Đầu vào đủ điều kiện viết

Đầu vào gồm event graph, danh mục shot/ảnh, transcript nếu có, âm thanh được hỗ trợ, brief/fact revisions, resolutions, giới hạn kể chuyện và preference profile. Mỗi lần truy xuất phải có `evidence_scope_revision_id` và `query_manifest_id` theo tài liệu 02.

- Raw notes được giữ riêng; fact draft không tự trở thành user-confirmed.
- Chỉ đưa vào tập dữ kiện cốt lõi những claim/fact có cách dùng được phép theo decision table chuẩn.
- Mâu thuẫn trọng yếu chặn những beat/phương án phụ thuộc, không chặn phân tích các clip độc lập.
- Nguồn lỗi, chưa được phân tích đủ hoặc đang impact revalidation không được giả là đã hiểu đầy đủ.
- Một câu chuyện có thể dùng lời người dùng xác nhận ngoài camera, nhưng phải giữ đúng provenance và tránh B-roll gây hiểu sai.
- Thêm clip có thể thay đổi tập bằng chứng dù clip mới chưa có cạnh dependency cũ; phải qua impact review trước final phụ thuộc.

## 3. Sinh 1–3 phương án thực sự khác nhau

1. Lập tập sự kiện được phép kể, giữ cả phạm vi, uncertainty, nguồn và điều cấm.
2. Sinh nhiều outline ngắn với trọng tâm, thứ tự kể hoặc tỷ lệ lời/hình khác nhau.
3. Loại outline thiếu bằng chứng cho beat bắt buộc, bịa nhân quả, vi phạm điều cấm hoặc chỉ đổi tiêu đề.
4. Ghép từng beat với một tập shot có thời gian nguồn, vai trò chứng minh/minh họa và khả năng crop.
5. Viết voice/text, tách mệnh đề factual và quan hệ nối thành claim cần kiểm tra.
6. Chạy TTS thử theo voice profile đã chọn, kiểm lời và đo WAV thật.
7. Tìm cut hợp lệ theo lịch voice/pause thật; kiểm ràng buộc trước điểm thẩm mỹ.
8. Xếp hạng những phương án hợp lệ theo hook, mạch chuyện, tiếng Việt, nhịp, độ khác biệt và gu.
9. Đưa tối đa ba phương án. Có một phương án tốt thì đưa một; không bịa sự kiện cho đủ số lượng.

Hook 0–3 giây là mục tiêu sáng tạo, không là yêu cầu giật gân. Một hình hoặc âm thanh có ý nghĩa có thể làm hook. Không ép mọi nguồn thành chuyện hài hoặc tạo twist không có thật.

## 4. Hợp đồng script revision

Mỗi revision lưu concept, hook, beats, voice lines, chữ bình luận, shot candidates, cue âm thanh, constraints, thời lượng và dependency manifest. Phần ước lượng và phần đã đo phải có nhãn khác nhau.

| Thành phần | Nội dung bắt buộc |
|---|---|
| Beat | ID/revision, vai trò, chronology và narrative order, khoảng timeline dự kiến |
| Lời/chữ | Nội dung gốc, voice text chuẩn hóa, claims được dùng và nguồn |
| Shot candidate | Source snapshot/revision, khoảng PTS, vai trò hình, crop plan, head/tail khả dụng |
| Claim use | Claim revision, `narrative_type`, `allowed_use`, support assessment được tham chiếu |
| Audio/cue | WAV revision/hash, pause, event âm thanh thật hoặc SFX được phân biệt |
| Constraints | `must_use`, `must_not_use`, `preferred`, scope và revision của khóa |
| Bằng chứng đủ điều kiện | Scope/query manifest, phần còn unknown và lý do bỏ claim |
| Feasibility report | Kết quả tìm kiếm, profile, số frame, các bottleneck và giới hạn |

Schema và timecode hợp lệ chỉ chứng minh cấu trúc hợp lệ. Không được biến việc JSON parse được thành chứng cứ nội dung đúng hoặc câu chuyện hay.

## 5. Kiểm từng mệnh đề và quan hệ

Một câu “Tôi đi nhầm vì GPS nên phải quay đầu lúc ba giờ” chứa nhiều mệnh đề: chủ thể, đi nhầm, nguồn nguyên nhân, quay đầu và thời gian. Một reference cho cả câu không tự hỗ trợ tất cả thành phần.

- Kiểm cả “vì”, “nên”, “sau đó”, “lại”, “đã bỏ lỡ” và gán ý định cho người thật.
- `reported_by_user` không đổi thành `observed` sau script/preview approval.
- `nonliteral_commentary` có thể ví von nhưng không được đưa lén một sự cố factual chưa được hỗ trợ.
- Claim còn disputed trọng yếu không đi vào lời khẳng định trực tiếp; cách xử lý theo decision table tài liệu 02.
- Việc không tìm thấy hình trong phạm vi đã xem không tự chứng minh sự kiện không xảy ra trong ngày.
- Mỗi câu sửa phải được tách và kiểm lại; không chỉ kiểm bản đầu rồi miễn kiểm những bản viết trôi chảy hơn.

### Ví dụ giữ đúng nguồn

Người dùng xác nhận: “Tôi rời nhà khoảng ba giờ sáng để đi chụp rước dâu.” Video cho thấy biển đường cụt, không cho thấy GPS hoặc nguyên nhân chọn đường.

| Câu kể | Nguồn | Quyết định |
|---|---|---|
| “Tôi rời nhà khoảng ba giờ sáng.” | User fact đã xác nhận | Giữ từ “khoảng”, giữ nguồn reported; có thể kể ngôi thứ nhất |
| “Hôm ấy tôi đi chụp rước dâu.” | User fact đã xác nhận | Có thể kể dù khâu chuẩn bị không được quay |
| “Tới đây thì gặp biển đường cụt.” | Frame/đoạn thực đọc được biển | Dùng khi đúng claim, đúng source revision và khoảng thời gian |
| “GPS dẫn tôi sai đường.” | Chưa có nguồn đủ hỗ trợ | Bỏ hoặc hỏi riêng nếu chi tiết làm thay đổi câu chuyện |

B-roll đường đêm không được khiến người xem hiểu nhầm rằng nó ghi chính xác thời điểm ba giờ. Nhãn “hình minh họa”, lời dẫn hoặc chuyển cảnh chỉ cần khi có nguy cơ hiểu sai; không bắt voice đọc metadata kỹ thuật.

## 6. Chọn, sửa và duyệt script

Thẻ phương án cho thấy góc kể, lời mẫu, storyboard, độ dài đã đo, dữ kiện chính và giới hạn. Chọn thẻ chỉ đặt phương án hiện hành; nút duyệt là một hành động riêng trên snapshot được hiển thị.

- Sửa sự thật hoặc quan hệ: tạo fact/claim revision phù hợp, giữ nguồn và mở đúng review; không chỉ sửa chuỗi text trong UI.
- Sửa cách diễn đạt: tạo script revision, kiểm claim, tái tạo TTS và timing/cut phụ thuộc; không quét lại mọi frame cũ vô cớ.
- Khóa câu/shot/ảnh/điểm cắt là constraint có revision; AI không tự mở khóa để có điểm đẹp hơn.
- Constraint có vẻ xung đột nhưng search chưa tìm được nghiệm phải được báo trung thực; thất bại beam không là bằng chứng vô nghiệm.
- Sau approval, AI chỉ đề xuất thay đổi nội dung dưới dạng revision có diff để người dùng duyệt lại.
- Tinh chỉnh triển khai không đổi lời/cách kể vẫn phải thể hiện ở preview; không dùng tên “kỹ thuật” để thay shot mang ý nghĩa khác.
- Script approval không thay xác nhận fact và không thay preview approval.

## 7. Voice, cách đọc và artifact audio

VieNeu v3 Turbo ONNX/CPU là candidate; điều kiện chọn, preset và offline theo [03-MODELS-AND-RESOURCES.md](03-MODELS-AND-RESOURCES.md).

1. Lưu script gốc và voice text đã chuẩn hóa số, tên viết tắt, tên riêng.
2. Giữ bảng ánh xạ để chứng minh chuẩn hóa không đổi nghĩa hoặc mức chắc chắn.
3. Tạo WAV tốc độ 1×, ghi voice/model/preset/phonemizer/config revision.
4. Kiểm lời, pause, clipping, duration và các đoạn nghi vấn bằng ASR đối chiếu cùng review nghe khi cần.
5. Căn cụm/từ theo WAV cuối; alignment chỉ là kết quả có thể sai và phải qua fixture.
6. Publish WAV qua core thành artifact bất biến có SHA-256; WAV được dùng trong approval phải được pin.
7. Dùng lại chính WAV đã được duyệt trong preview/final. Cùng seed/config không cho phép giả định WAV sinh lại giống hệt.

Giữ tiếng hiện trường có ý nghĩa, duck nhạc theo voice và phân biệt SFX với âm nguồn. Audio do app tạo không được ghi ngược thành bằng chứng sự kiện. Người dùng có thể dùng WAV của mình nhưng phải qua cùng kiểm lời/thời lượng.

## 8. Profile thời gian `M-24-SDR-v1`

| Thành phần | Quy ước chuẩn |
|---|---|
| Timeline video | Số frame nguyên, 24/1 fps; không thay bằng 23,976 |
| Mọi khoảng nội bộ | Nửa mở `[start, end)`; end không thuộc khoảng |
| Thời gian source | PTS + time base hữu tỷ của stream; giữ presentation order |
| Audio chuẩn | 48.000 sample/giây; index sample nguyên |
| Quan hệ video/audio chuẩn | 2.000 sample cho một frame timeline |
| Tốc độ source mặc định | 1×; retime khác cần profile/mapping riêng đã qua cổng |
| Quy đổi API | Chuyển ở biên adapter theo capability probe inclusive/exclusive |
| Số thực | Không dùng float tích lũy làm định danh frame hoặc thời gian chuẩn |

Frame ID/PTS nguồn vẫn được giữ sau conform. Timecode ms trong UI chỉ là biểu diễn cho người dùng. PTS âm, edit list, rotation và audio start offset phải được ghi nhận trong source manifest, không bị xóa bằng phép “đặt mọi stream về 0” không có mapping.

## 9. Ánh xạ VFR → CFR có thể tái lập

Đây là quy tắc chọn frame của profile ban đầu, không phải lời hứa nó phù hợp mọi nội dung. Nếu làm mất bằng chứng quyết định, phương án dựng phải đổi hoặc bị chặn.

1. Giải mã source snapshot theo presentation order, lập `frame_id`, `pts`, time base và khoảng hiển thị được decoder xác nhận.
2. Xác định khoảng source của shot và số frame timeline nguyên `N` từ phương án cut; không làm tròn duration độc lập ở nhiều tầng.
3. Với frame timeline cục bộ `k`, `0 ≤ k < N`, lấy thời điểm giữa frame: `t(k) = source_start + (k + 1/2) / 24` cho tốc độ 1×.
4. Chọn source frame có khoảng hiển thị chứa `t(k)` theo quy tắc nửa mở. Tại đúng ranh giới chọn frame bắt đầu ở ranh giới đó.
5. So sánh thời gian bằng số nguyên/hữu tỷ; không dùng `milliseconds × fps_trung_bình` để suy frame VFR.
6. Ghi từng map source-frame → timeline-frame, các frame được lặp/bỏ và lý do chọn.
7. Nếu timestamp thiếu, trùng bất thường, gap không giải thích được hoặc không biết khoảng hiển thị cuối, đưa vào scoped error/capability review; không tự kéo dài frame cuối tùy ý.
8. Kiểm frame đầu/cuối, duration, cue và bằng chứng quan trọng sau conform trước khi dựng.

Không dùng optical flow hoặc sinh frame nội suy trong MVP. Chuyển frame rate bằng chọn/lặp frame có thể đổi cadence; preview cho người dùng thấy kết quả và QC không được chỉ đọc metadata.

### Hiện thực map trong media Resolve thực sự sử dụng

- Đường mặc định tạo **artifact media conform CFR 24/1** cho các source ranges được dùng, gồm head/tail cần thiết. File này phải hiện thực đúng map chọn/lặp/bỏ frame đã khóa; một manifest mô tả map chưa đủ thay đổi cách decoder của Resolve xử lý original VFR.
- Artifact conform lưu revision/hash, profile codec/màu, source snapshot revision, media-map revision và ánh xạ từng frame output về frame ID/PTS gốc. Nếu time origin của file conform khác nguồn, offset đó phải có trong mapping; không bỏ trace về source chuẩn.
- Core kiểm bytes, frame count, thứ tự frame, media-map và các frame bằng chứng quyết định, rồi publish artifact qua giao thức PREPARED → MATERIALIZED → VERIFIED → COMMITTED của tài liệu 05. Worker không tự đặt file tạm vào timeline như một output đã được cấp quyền.
- Resolve import **đúng artifact conform đã commit**, dùng frame ranges tương ứng trong edit plan. Artifact được job pin khi đang dùng và được approval/backup pin khi là dependency của bản đã duyệt; không dọn nó như proxy có thể tùy ý tái sinh.
- Đường native import source rồi để Resolve conform chỉ được bật như capability riêng khi fixture trên đúng API/runtime/profile chứng minh frame mapping trùng map chuẩn, đồng thời các kiểm tra theo edit plan của job đạt. Đường này mặc định tắt; không suy nó đúng chỉ từ việc duration/fps đầu ra khớp.
- Native path chưa chứng minh tương đương thì dùng artifact conform đã xác minh hoặc chặn capability. Nếu map làm mất frame bằng chứng quyết định, đổi cut/cách trình bày có revision hoặc chặn; việc materialize file không làm phương án sai trở thành hợp lệ.

Retime, slow motion hoặc frame interpolation về sau là capability riêng với media-map version mới. Không tái dùng approval cũ khi retime làm đổi timing/cách kể. Chồng lấn J-cut/L-cut và chuyển cảnh được biểu diễn theo track, không cộng duration các track như chúng nối tiếp nhau.

## 10. Chính sách màu, HDR và upscale

`M-24-SDR-v1` chọn đầu ra SDR Rec.709. Tất cả source/graphics phải được đưa về một pipeline màu đã khóa trước khi so preview/final.

- Ghi primaries, transfer, matrix, range, bit depth, rotation và các metadata HDR có liên quan.
- Nguồn SDR có tags hợp lệ được chuyển qua transform đã pin; không chỉ gắn lại tag mà không biến đổi pixels khi cần.
- Nguồn HDR chỉ được nhận khi tags/transfer/primaries đã biết và đường chuyển đã qua fixture; metadata thiếu/mâu thuẫn tạo `unsupported` hoặc yêu cầu quyết định color interpretation có revision.
- HDR → SDR dùng pipeline FFmpeg đã pin: giải mã đúng nguồn → linearize với mức sáng tham chiếu được khai báo → tone map → gamut/transfer đích → quantize/tag đầu ra. Không tone map trực tiếp dữ liệu gamma-encoded.
- Candidate ban đầu cho tone-map là CPU `zscale` + `tonemap` với đường Mobius; parameters và source-peak interpretation nằm trong `color_transform_revision`, phải được chọn trên development fixtures rồi khóa.
- Không dùng auto tone-map theo default thay đổi giữa máy/phiên bản. Nếu build thiếu filter hoặc không xác minh được peak/transfer, capability HDR chưa đạt.
- Timeline/Resolve phải dùng cùng color interpretation với intermediate; không áp tone-map lần hai.
- Overlay RGBA phải khai báo color space và alpha premultiplication; kiểm mép chữ/đổ bóng sau composite.
- Xuất 2160×3840 từ nguồn crop nhỏ là upscale, không được tuyên bố tạo thêm chi tiết thật. Không dùng ảnh sinh thêm chi tiết làm bằng chứng.

Profile màu phải lưu đầy đủ tham số số, working/output settings và golden render ở G0/G4. Câu “đã dùng Rec.709” không thay cho kiểm màu đen/trắng, skin tone, chữ, clipping highlight và so preview/final theo MEDIA-03/MEDIA-08 ở tài liệu 09.

## 11. Audio clock, alignment và mix

- Decode audio giữ liên hệ source PTS; resample một lần theo profile về 48 kHz và lưu mapping.
- Khi cần quy timestamp sang sample, dùng phép làm tròn nearest/ties-to-even được pin; decode rộng rồi trim đúng sample, không trim sớm trước khi có mapping.
- Offset audio/video được giữ riêng; offset do camera và drift giữa phiên không tự bằng nhau.
- Không kéo audio để khớp bằng mắt. Drift correction chỉ dùng khi có phép đo/căn cứ và transform revision rõ.
- Voice/caption/beat cues cùng tham chiếu WAV đã duyệt; sửa voice làm stale những cue phụ thuộc.
- Silence có chủ ý có nhãn trong edit plan; `no_audio`, `audio_present_untranscribed`/`no_speech` và khoảng im lặng trong thành phẩm là những tình huống khác nhau.
- Mix giữ dialogue dễ nghe và âm hiện trường quan trọng; nhạc/SFX có quyền dùng và không giả làm bằng chứng nguồn.
- Final phải kiểm âm sau encode/mux, bao gồm clipping, lỗi kênh, thiếu/lặp từ và sync; có audio stream chưa đủ đạt.

Tolerance sync, drift và alignment được đặt duy nhất tại MEDIA-04/MEDIA-05/MEDIA-07 của tài liệu 09. Các mục tiêu đó chưa phải kết quả đã đạt.

## 12. Shot search và khả thi của cut

Mỗi beat có phương án hữu hạn gồm một hoặc nhiều shot, nguồn đã seal, khoảng in/out, mapping, crop, vai trò hình và số frame timeline thật. Lịch voice/pause là khung để tìm cut.

Ràng buộc cứng bao gồm:

- Claim được phép kể và shot hỗ trợ đúng nội dung hoặc có cách minh họa hợp lệ.
- Source/hash tồn tại, range hợp lệ và đủ head/tail cho transition.
- Giữ thông tin cần chứng minh sau crop/conform.
- Chronology/cause/identity không bị dựng thành ý nghĩa sai.
- Khóa của người dùng, beat bắt buộc và giới hạn duration.
- Cue chữ/ảnh/SFX không tiết lộ punchline sớm hơn kế hoạch.

Chỉ sau đó mới tối ưu khớp ý, hình đẹp, nhịp, continuity và đa dạng. MMR dùng để xếp ứng viên hợp lệ; không dùng shot đẹp hơn nhưng sai hành động để thay shot đúng.

`SEARCH-v1` ở tài liệu 07 phân biệt nghiệm tìm thấy, hết ngân sách, hết tập ứng viên và vô nghiệm được chứng minh trong miền đã khai báo. Khi chưa chứng minh xung đột, UI chỉ nêu bottleneck nghi ngờ và phương án thử thêm; không khẳng định người dùng phải bỏ khóa.

## 13. Nhịp hài, chữ và ảnh

- Beat có thể dẫn chuyện, tạo kỳ vọng, bẻ lái, punchline hoặc khoảng thở; không phải video nào cũng cần đủ các vai trò.
- Cue lấy từ WAV thật và lịch cut đã khóa; không tính bằng số ký tự.
- Phụ đề bám lời cuối, theo cụm có nghĩa, tối đa hai dòng; kiểm độ rộng glyph và thời gian đọc, không chỉ đếm từ.
- Font đủ dấu tiếng Việt, tương phản rõ; viền/bóng vừa đủ và phải được thử trên màn hình điện thoại.
- Chữ bình luận là lớp riêng với subtitle voice; không làm người xem tưởng lời bình là lời nói trong source.
- Safe-area preset có revision; thay preset làm stale layout/render/QC liên quan.
- Không lộ ảnh/chữ/punchline trước cue đã duyệt; kiểm cả frame đầu xuất hiện sau render.
- Ảnh phải có thời gian quan sát phù hợp bố cục/nội dung; flash/freeze không được lấn át ảnh.
- Âm click thật và click SFX có quyền được phân biệt. Không cần tiếng click để xác định mọi cú bấm, cũng không dùng click giả làm evidence.

## 14. Crop dọc và ghép ảnh

Crop 9:16 phải giữ chủ thể và thông tin làm bằng chứng, làm mượt theo thời gian và được đánh giá trên từng shot. Detector/tracker chưa qua cổng thì dùng fit/bố cục đã kiểm hoặc yêu cầu chỉnh, không mặc định cắt giữa khung.

Một crop đẹp làm mất biển đường, bàn tay, người liên quan hoặc phần trước/sau quyết định vẫn là phương án không hợp lệ. Trạng thái chất lượng kỹ thuật thấp không tự loại một shot có giá trị câu chuyện.

`match_status` và `use_mode` theo tài liệu 02. `exact_candidate` không đủ để kể “đây là đúng ảnh của cú bấm ấy”. Chỉ cho `use_mode=exact` khi đánh giá support và capability exact-photo đã đạt; nếu chưa thì minh họa phù hợp hoặc không dùng. Xác nhận của người dùng vẫn là nguồn reported, không thành chứng cứ thị giác.

## 15. Biên dịch edit plan bất biến

Compiler chuyển script/storyboard được duyệt thành edit plan có version, không gọi Resolve trực tiếp từ câu trả lời LLM.

| Nhóm dữ liệu | Nội dung của edit plan |
|---|---|
| Identity | Project, script/edit revision, profile media/runtime, dependency fingerprint |
| Nguồn | Snapshot revision/hash; conform artifact revision/hash thực được import hoặc native-conform capability đã chứng minh; bookmarks chỉ relink original khi cần |
| Timeline | Exact 24/1, kích thước, duration frame, track layout và clip identity |
| Cut/mapping | Khoảng nửa mở, source PTS, CFR map, transition, crop/retime revision |
| Audio | WAV/mix/SFX hashes, sample ranges, offsets, gain/duck automation |
| Chữ/graphics | Nội dung/style source, font hash, cue, native/raster capability |
| Nội dung | Claims, allowed use, chronology, constraints và evidence scope |
| Duyệt | Approval targets còn hiệu lực cho đúng snapshot; không tự cấp approval |

Validation trước adapter kiểm file/hash, media map, claim eligibility, timing, resource capability và trạng thái impact revalidation. Plan có lỗi không được “thử render rồi xem sao” để bỏ qua gate.

## 16. Capability spike Resolve ở G0

Trên đúng bản Resolve cài thực tế, dựng một timeline khoảng 10 giây để xác minh:

- Kết nối scripting local, API version và quyền truy cập file từ worker đã đóng gói.
- Tạo/query project/timeline dọc, 24/1 fps và color settings.
- Import/append source, voice, subtitle/title, graphic và transition cần cho MVP.
- Quy ước source start/end, timeline frame và readback identity/signature.
- Import artifact conform 24/1 giữ đúng frame map; nếu muốn bật native-conform thì có fixture riêng chứng minh tương đương trên profile được hỗ trợ.
- Codec/container preset candidate, render status, khả năng đọc lại output và xuất/mở `.drp`.
- Khả năng phát hiện timeline drift và nhận diện tác động sau crash.

Phiên bản 21.1.2 được ghi trong khảo sát cũ không là chứng nhận API hiện tại. Nếu API không đặt được một setting, chỉ dùng template đã kiểm và query lại kết quả; không giả setting đã đổi vì hàm không báo lỗi.

## 17. Tác động Resolve và chỉnh sửa bên ngoài

Adapter được serialize toàn cục. Core ghi operation intent trước mỗi tác động, rồi reconcile bằng observable IDs/signatures đã probe. Quy trình chi tiết, fencing và crash windows do tài liệu 05 sở hữu.

- Mỗi edit-plan revision có managed project/timeline identity xác định.
- Media readback phải khớp conform artifact/hash và frame ranges của edit plan; native source chỉ đi qua native-conform capability đã đạt. Không đổi đường media giữa preview và final mà không kiểm dependency, mapping và approval tương ứng.
- Retry kiểm trạng thái thật trước; không append/render lại mù quáng.
- Nếu không thể biết một thao tác đã xảy ra hay chưa, giữ reconciling/blocked; không coi rollback SQLite là rollback Resolve.
- API không đọc lại được một effect thì capability gate yêu cầu rebuild cô lập từ sealed inputs; không giả fingerprint nhìn thấy toàn bộ hiệu ứng.
- App-managed timeline là nhánh automation quản lý. Người dùng muốn sửa tự do nhận một bản manual handoff riêng.
- MVP không tự nhập ngược mọi chỉnh sửa trong Resolve vào evidence/script/edit plan.
- Phát hiện drift ở managed timeline thì chặn export; cho bảo toàn thành nhánh thủ công hoặc tạo managed revision mới.
- Không xóa/ghi đè chỉnh sửa thủ công để phục hồi trạng thái app. Sửa bên ngoài trong khi job managed đang chạy làm job mất hiệu lực.
- Kiểm lại trước và sau render để phát hiện thay đổi trong cửa sổ chạy.

## 18. Track riêng và mức chỉnh sửa thực tế

| Lớp | Hình thức ưu tiên | Cam kết được phép ghi |
|---|---|---|
| Video/cut | Clip và track riêng | Có thể thay media, cut và timing trong bản handoff |
| Voice/nhạc/SFX | Track riêng, file audio giữ lại | Có thể chỉnh timing/mix; đổi lời cần WAV mới |
| Caption/title | Native title/Fusion template nếu API đã qua cổng | Có thể sửa text đúng khả năng template |
| Raster overlay | RGBA + text/style source để tái sinh | Đổi timing được; sửa nội dung chữ phải tái sinh overlay |
| Hiệu ứng API không hỗ trợ | Pre-render riêng lớp cần thiết | Phạm vi bị bake được ghi rõ; không flatten toàn bộ vô cớ |

“Project có thể sửa” không đồng nghĩa mọi chữ đã raster hóa trở thành editable text. Lưu text/style/font/cue nguồn cùng project và chỉ hứa mức chỉnh sửa đã được nghiệm thu khi mở lại.

## 19. Preview và QC trước khi yêu cầu duyệt

1. Core xác nhận script approval còn hiệu lực và edit plan đã publish bất biến.
2. Dừng worker AI nặng, cấp lease cho Resolve và kiểm dung lượng thật.
3. Render preview 1080×1920 từ timeline/profile đã khóa, gắn đúng manifest.
4. QC deterministic kiểm media, frame, duration, geometry, text bounds, âm thanh và mapping.
5. QC nội dung xem từng beat đối chiếu script/source: hình–lời, crop, chronology, người, ảnh, TTS và timing.
6. Caption/SFX do app sinh không được dùng làm bằng chứng cho chính claim nó đang kể.
7. Lỗi xác định được có thể sửa trong số vòng giới hạn, tạo revision và chạy lại checks bị ảnh hưởng.
8. Lỗi ngữ nghĩa không chắc tạo review hoặc blocked; không bịa một sự kiện mới để “sửa”.

Cảnh tối, shot rung có chủ đích hoặc khoảng im lặng hợp lệ không tự là lỗi. Ngược lại, có MP4 mở được không chứng minh preview đạt nội dung.

## 20. Preview approval và điều kiện final

Người dùng xem/nghe preview và duyệt đúng revision. Approval gắn preview/edit plan/script/facts/voice/crop/mix và scope liên quan, không là một boolean chung của project.

- Đổi lời, shot, voice, timing, crop, nhạc hoặc cue có ý nghĩa tạo preview revision mới và duyệt lại phần bị ảnh hưởng.
- Sửa factual/story quay lại script gate; không chỉ duyệt lại một MP4 rồi coi factual issue đã được giải quyết.
- Final dùng chính approved WAV/graphics và edit plan; không chạy LLM để “tút lại câu” trong bước xuất.
- Chênh lệch chỉ về resolution/codec được phép theo render profile đã công bố, nhưng vẫn phải QC chính final.
- Scope bằng chứng đang chờ revalidation hoặc approval stale chặn final phụ thuộc.
- Nếu render kỹ thuật lại cùng snapshot, giữ approval chỉ khi chứng minh không đổi nội dung/timing và QC lại đạt.

## 21. QC final và tương đương preview

Không so hash hai file preview/final để đòi giống bytes vì resolution/codec khác. Cần kiểm những bất biến và những thay đổi được phép:

| Lớp kiểm | Nội dung |
|---|---|
| Snapshot | Cùng script/edit plan/approved media hashes và profile ngoại lệ được cho phép |
| Timing | Frame count, cut/cue/transition, audio sample offsets và duration hiệu dụng |
| Hình | Shot/source identity, crop, chữ, ảnh, visibility của bằng chứng quyết định |
| Màu | Đúng transform/tag/range; không đổi interpretation khi xuất 4K |
| Âm | Đúng voice/mix, không mất/lặp từ, lỗi kênh, clipping hoặc drift |
| Nội dung | Không đổi chronology, ý nghĩa B-roll, nhân vật hoặc punchline |

So sánh hình có thể chuẩn hóa về cùng kích thước/màu để hỗ trợ tìm khác biệt; bộ đo perceptual không tự chứng minh hai video có cùng ý nghĩa. Checks deterministic và review nội dung vẫn là hai lớp riêng.

MEDIA-01 đến MEDIA-08 trong tài liệu 09 sở hữu tolerance và fixture. Final sai cut/chữ/crop/âm phải tạo finding, bị chặn và sửa/duyệt đúng phạm vi; không vượt gate chỉ vì metadata 4K24 đúng.

## 22. Đầu ra, handoff và mở lại

Một lần hoàn tất có MP4 final, manifest/QC, script/edit plan revision, approved media cần thiết và `.drp`/backup Resolve mở lại được. Source snapshot và các pin được quản lý theo tài liệu 05, không dọn như proxy tùy ý.

- Managed output giữ quan hệ với những approvals đã cho phép nó.
- Manual handoff có nhãn rõ, giữ bản automation gốc và mô tả giới hạn roundtrip MVP.
- Backup checkpoint khác portable backup; không hứa project mang sang máy khác mở đủ media nếu source snapshots chưa được đóng gói.
- Kiểm mở `.drp` và relink đúng snapshot trong fixture restore, không chỉ kiểm file `.drp` tồn tại.
- Chỉ báo hoàn tất khi final/QC đúng revision, không còn lỗi chặn và user-state đã commit bền vững.

## 23. Các ca phải có trong nghiệm thu

- Brief “khoảng ba giờ” không bị kể thành thời gian chính xác; câu nhiều mệnh đề chỉ có nguồn một phần bị bắt.
- Một nguồn nghèo chỉ sinh một script; LLM không thêm sự cố để đủ ba.
- TTS bỏ/lặp từ, đọc sai số/tên, subtitle lệch pause và punchline bị lộ sớm được phát hiện hoặc đưa review.
- Source VFR/rotation, metadata lệch, crop mất biển và ảnh khác buổi không tự báo đạt.
- Ba ca beam của tài liệu 07/09: fixture prune-only khóa cấu hình trả `SEARCH_BUDGET_EXHAUSTED`; forward check tìm được B→C trả `SOLUTION_FOUND`; exact checker chỉ chứng minh vô nghiệm trong miền A/C đã khai báo.
- Sửa voice sau duyệt làm timing/cut/caption/mix phụ thuộc stale; final không dùng approval cũ.
- Crash sau append/render được reconcile, không nhân đôi timeline; managed drift bảo toàn manual edits.
- Preview đúng nhưng final sai layout/cut/màu/âm bị chặn dù resolution/codec đúng.
- File gần trần 180 giây phải qua kiểm duration thực sau mux; không tự xén câu cuối.

Mỗi ca gắn requirement ID, fixture và bằng chứng theo [09-UPGRADES-AND-ACCEPTANCE.md](09-UPGRADES-AND-ACCEPTANCE.md), triển khai theo [11-CODING-WORKFLOW-AND-CHECKLIST.md](11-CODING-WORKFLOW-AND-CHECKLIST.md).

## 24. Tài liệu kỹ thuật tham chiếu

- [FFmpeg filters: chuyển màu, scale, audio và tone mapping](https://www.ffmpeg.org/ffmpeg-filters.html).
- [Mã tone-map trong FFmpeg](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_tonemap.c).
- Tài liệu scripting đi kèm đúng bản Resolve trên máy; đường dẫn khảo sát cũ: `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/`.

Ví dụ và profile ở đây là blueprint chưa kiểm thử. Không chạy theo branch mới nhất tự động; build/runtime/parameters thực tế phải được ghi vào capability report và manifest.
