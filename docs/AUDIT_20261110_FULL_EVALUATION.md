# BÁO CÁO ĐÁNH GIÁ TOÀN DIỆN — AIVideo v3.1

> ⚠️ **ẢNH CHỤP LỊCH SỬ — không phải trạng thái hiện tại.**
> Giữ nguyên nội dung để tra cứu quá trình; nguồn đúng hiện tại là
> [`README.md`](../README.md) và
> [`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](../docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).
> Sau ngày ghi trong tài liệu, dự án đã qua kiểm toán 2026-11-11 (9 P0 + 54 P1 + 14 nhóm P2) và
> một số chi tiết đã đổi: `fixtures/corpus` → `fixtures/smoke`, schema do Swift sở hữu,
> TTS là Kokoro-Vietnamese, Whisper chưa nối, gate G2/G5 vẫn IN_REVIEW.

**Vai trò:** Kỹ sư trưởng khó tính, review độc lập (không viết code trong lượt này)
**Ngày:** 2026-11-10
**Phạm vi:** toàn bộ mã nguồn trong repo (21.603 dòng Python + 14.313 dòng Swift), contracts, migrations, tooling, test suite, tài liệu Gate G0–G5
**Trạng thái dự án theo chính tài liệu của bạn:** "hoàn thành G0–G5" — báo cáo này kiểm chứng lại tuyên bố đó bằng mã và bằng lệnh chạy thật.

---

## 0. KẾT LUẬN TRƯỚC KHI ĐỌC CHI TIẾT

Đây là một **prototype kỹ thuật ấn tượng về mặt kiến trúc**, nhưng **chưa phải sản phẩm hoạt động được**, và một số tuyên bố nghiệm thu trong `progress.md` / `task_plan.md` **không đứng vững trước mã nguồn**.

Ba câu quan trọng nhất:

1. **Đường phân tích video cốt lõi (G2) đang tự mâu thuẫn và luôn ném lỗi khi có model thật.** Inspector gửi 1 frame/cửa sổ 16 frame, còn pipeline coi bất kỳ frame nào bị bỏ là `POST_PROCESSOR_TRUNCATION` và ném lỗi ngay cửa sổ 0. Tôi đã chạy thật: `PIPELINE RAISED: FullFramePipelineError POST_PROCESSOR_TRUNCATION`.
2. **Các chỉ số "nghiệm thu thực địa" (precision 1.0 / recall 0.96 / FAR 0.0) được tính từ một fixture tổng hợp hard-code trong Python, không phải từ quan sát của model trên 5 video held-out.** Chế độ "real corpus" chỉ thay mỗi mẫu số coverage, còn claim/event/adversarial vẫn lấy từ `build_canonical_g2_benchmark_fixture()`; chính JSON trả về vẫn ghi `evaluation_mode = "synthetic_decision_harness_fixture"`.
3. **Bất biến "chỉ Swift ProjectStore được ghi SQLite" đã bị vi phạm ngay trong mã:** `G3ProjectStore`, `G4ProjectStore`, `G5ProjectStore` mỗi cái tự mở connection riêng và `BEGIN IMMEDIATE` → 4 writer cùng lúc.

Điểm tổng: **5.4/10** — kiến trúc 8, hiện thực 4.

---

## 1. KẾ HOẠCH ĐÁNH GIÁ ĐÃ THỰC HIỆN

### 1.1. Phạm vi và cách chia lát cắt

| Lát cắt | Nội dung | Cách đánh giá |
|---|---|---|
| A. Python media pipeline (G2) | `main_g2.py`, `full_frame_pipeline.py`, `pipeline_adapters.py`, `media_indexer.py`, `semantic_verifier.py`, `local_model.py`, `g2_benchmark_runner.py` | Đọc toàn bộ + chạy probe thực thi |
| B. Python G3–G5 | `g3_engine`, `g3_rpc_safe`, `g4_core`, `g4_resolve`, `g4_stage`, `g5_final`, `g5_capabilities`, `g5_release_audit`, `g5_release_guards`, `review_workflow`, `data_contracts` | Đọc toàn bộ, truy vết chuỗi approval/certification |
| C. Swift Core | 18 file trong `packages/AIVideoCore` (ProjectStore, 3 store con, 3 guard, WorkerClient, publisher, backup, governor, media) | Đọc toàn bộ, phân tích concurrency + atomicity |
| D. App + tooling | `AIVideoApp.swift` (2.726 dòng), 3 console view, `run_tests.sh`, `run_python_tests.py`, `package_review.py`, `check_readiness.py`, setup model, CI | Đọc toàn bộ, truy vết exit-code của test harness |
| E. Thực thi | Python suite, toàn bộ ma trận `run_tests.sh`, probe model thật, preflight | Chạy thật trên M1 Pro, ghi lại output |

### 1.2. Nguyên tắc đánh giá (khó tính có lý do)

- **Không tin docstring/comment.** Mọi kết luận phải đối chiếu dòng code thực thi.
- **Không tin số liệu tự khai.** Một chỉ số chỉ được coi là có thật khi truy được về phép đo từ dữ liệu đầu vào thật.
- **Không tin test chỉ assert lên hằng số/mock.** Câu hỏi kiểm tra: *nếu tôi cố tình làm hỏng implementation, test này có fail không?*
- **Fail-closed mới là đúng.** Mọi nhánh "không có dữ liệu → bỏ qua" đều bị xếp vào lỗi nếu nó có thể dẫn tới báo cáo xanh giả.
- Phân mức: **P0** = sai lõi/không chạy được/mất toàn vẹn dữ liệu; **P1** = lỗi robustness, hiệu năng, bảo mật; **P2** = nợ kỹ thuật.

### 1.3. Bằng chứng thực thi trong phiên này

| Lệnh | Kết quả thật |
|---|---|
| `workers/.venv/bin/python3 tools/run_python_tests.py` | **156 test, 0 fail, 0 error, 0 skip, exit 0** (`build/reports/python_test_summary.json`) |
| `./tools/run_tests.sh` | **exit 0**, 15 nhóm Swift chạy xong, app build + codesign ad-hoc OK |
| `python3 tests/test_s11_real_vlm_inference.py` | PASS, 4.4 s — model Qwen3-VL 4B thật (3.09 GB) thực sự load và sinh chữ |
| Probe inspector + audit | `accepted_frame_ids=[8]`, `truncation_detected=True`, `coverage=0.0625` |
| Probe pipeline end-to-end | `POST_PROCESSOR_TRUNCATION` tại window 0 |
| `python3 tools/check_readiness.py` | **NO-GO**: `REAL_QWEN_VL_WEIGHTS_UNVERIFIED` + `UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS` |
| `git status` sau khi chạy test | 3 file **tracked** bị test ghi đè: `fixtures/AIVideo_G0_Spike.drp`, `reports/evidence/s02_t1_finder_launch.json`, `reports/evidence/s02_t2_bookmark.json` |

> Ghi chú trung thực: 3 file trên bị thay đổi **do chính lần chạy `run_tests.sh` của tôi**. Tôi không tự revert vì đó là thao tác thay đổi repo; bạn nên `git checkout -- <3 file>` hoặc chấp nhận chúng như artifact test.

---

## 2. KIẾN TRÚC HIỆN CÓ (dưới 5 gạch đầu dòng)

- **4 tầng:** SwiftUI macOS app (AppState + 4 màn workflow) → Swift Core (`AIVideoCore`: SQLite WAL actor, publication 4 trạng thái, guard G3/G4/G5) → Python worker (stdio JSON-RPC 2.0, 37 method) → DaVinci Resolve Studio scripting + ffmpeg.
- **Nguồn sự thật duy nhất:** SQLite canonical 15 bảng + 7 bảng G3/G4/G5 tạo ad-hoc; mọi thứ khác là artifact bất biến có hash.
- **Bằng chứng xuyên suốt:** `source_sha256` + PTS/timecode + `origin`/`epistemic_status` + approval revision, theo mô hình 5 trục evidence.
- **Gate tuần tự G0→G5, 27 bước S00–S26**, mỗi bước có test + report; tác vụ nặng đi qua `ResourceGovernor` single-lease trên ngân sách 16 GB.
- **100% local:** Qwen3-VL 4B (MLX), Qwen3-0.6B smoke, dự kiến Whisper large-v3 + VieNeu-TTS; không có cloud fallback trong đường chạy (trừ một script autobridge opt-in).

Đánh giá: **kiến trúc đúng hướng và hiếm gặp ở mức độ kỷ luật này** (tách quyền ghi, publication không coi DB và filesystem là một transaction, guard độc lập). Vấn đề nằm ở hiện thực, không nằm ở bản thiết kế.

---

## 3. BẢNG ĐIỂM

| Hạng mục | Điểm | Căn cứ |
|---|---:|---|
| Thiết kế kiến trúc & phân quyền | **8.0** | Invariant rõ, contract JSON Schema, publication state machine, guard tách biệt |
| Tính đúng đắn của pipeline G2 | **2.5** | Đường thật không chạy được; metric synthetic; provenance bị làm giả |
| Toàn vẹn dữ liệu / single-writer | **3.5** | 4 writer SQLite; reconciler báo SUCCEEDED sai; publication không bind job |
| Kiểm chứng & bằng chứng (evidence) | **5.0** | Ý tưởng tốt, nhưng có metric hằng số, test tự chứng nhận, key không pin |
| Bảo mật | **5.0** | Ed25519 không pin key; RPC ghi file tuỳ ý; `db_path` do caller chọn |
| Chất lượng test | **5.5** | Python 156 test thật và tốt; Swift đếm bằng `echo`; 2 suite không phát evidence |
| Trải nghiệm người dùng | **6.0** | 4 bước rõ ràng, auto-wiring tốt; nhưng claim bịa, slider tốc độ làm hỏng luồng |
| Khả năng bảo trì | **4.5** | `AIVideoApp.swift` 2.726 dòng, god object; schema ad-hoc; code trùng lặp |
| Đóng gói / phát hành / portability | **3.0** | Ký ad-hoc, path cứng `/Users/phuthanh`, NO-GO |
| **Tổng** | **5.4** | |

**Nhận xét một câu:** *Bạn đã xây một hệ thống kiểm soát chất lượng công nghiệp cho một pipeline chưa chạy được — cần đảo thứ tự: làm cho nó chạy thật, rồi mới siết gate.*

---

## 4. PHÁT HIỆN P0 — SAI LÕI

### P0-1. G2 không thể chạy end-to-end với model thật (tự mâu thuẫn nội bộ)

- `pipeline_adapters.py:618` → `submitted_frame_ids = [midpoint_fid]` (gửi đúng 1 frame/cửa sổ 16).
- `full_frame_pipeline.py:525` → `if audit.truncation_detected: raise FullFramePipelineError("POST_PROCESSOR_TRUNCATION", ...)`.
- `pipeline_adapters.py:166` → `truncated = len(dropped) > 0` (bất kỳ frame nào không được model xử lý đều là "truncation").

**Chạy thật:** `POST_PROCESSOR_TRUNCATION — Window 0 dropped frames [0..7, 9..15]`.
**Hệ quả:** bấm "Phân tích toàn bộ" trong app → mọi video đều lỗi ở cửa sổ đầu tiên. Chế độ không có model thì trả `blocked_model_unavailable` (trung thực), nhưng khi đã cài model đúng như khuyến nghị thì lại **hỏng**.
**Nghịch lý:** bước "sửa provenance trung thực" (chỉ nhận frame thật) đã biến pipeline thành không thể chạy, vì audit vẫn được thiết kế cho giả định "full-frame".

### P0-2. Inspector fail-open: payload rỗng vẫn sinh quan sát "observed" với coverage 100%

- `full_frame_pipeline.py:515` `insp.get("accepted_frame_ids", list(win.intended_frame_ids))` — thiếu key thì mặc định coi như đã xử lý đủ 16 frame.
- `:544` `str(insp.get("action_or_scene_type", "scenic_or_motion"))` — mặc định bịa loại cảnh.
- Probe với `lambda win: {}` cho kết quả: `status=completed`, `coverage=1.0`, 3 observation `origin=visual_model`, `observation_text=""`.

Đây đúng là kiểu "hallucination có chứng nhận" mà toàn bộ triết lý của dự án muốn chống.

### P0-3. Backdoor test-only nằm trên mặt RPC

- `main_g2.py:458` `inspector_fn = params.get("_inspector_fn") or s11_reg.build_offline_visual_window_inspector(src_path)`.
- Bất kỳ client nào gửi `_inspector_fn` truthy sẽ **bỏ qua kiểm tra weight/backend**, nhưng `vision_installed=True` vẫn được set và trả về client.
- `tests/test_s12_full_frame_pipeline.py` dùng đúng backdoor này để chứng minh "coverage 1.0 với model giả".

### P0-4. Coverage tự quy chiếu — con số 100% không đo gì cả

- `main_g2.py:472` truyền `total_declared_source_frames=len(pts_entries)` — tức mẫu số chính là danh sách đã index.
- `media_indexer.py:731-739` bỏ frame thiếu PTS rồi **đánh số lại** `frame_id=len(raw_frames)`.
- `full_frame_pipeline.py:608-611` chia cho cùng mẫu số đó, **không clamp**.
- Probe: declared=10, indexed=40 → `decode_coverage_ratio = 4.0`.
- `g2_benchmark_runner.py:904` trong chế độ synthetic: `frame_coverage_by_group = {hg: (1200, 1200)}` → `full_frame_input_coverage` luôn 1.0 **theo thiết kế**.

### P0-5. Nghiệm thu "thực địa S15" thực chất là fixture tổng hợp

- `g2_benchmark_runner.py:918-1007`: chạy VLM thật qua 5 clip, **nhưng** chỉ dùng kết quả thật để tính `frame_coverage_by_group`; `claim_opportunities`, `observable_events`, `verifier_adversarial_suite` đều lấy từ `build_canonical_g2_benchmark_fixture()` (105 claim + 50 event + 60 case do code Python tự sinh).
- `:1004` `report["real_video_corpus_verified"] = True` — gán vô điều kiện.
- `:466` `"evaluation_mode": "synthetic_decision_harness_fixture"` vẫn còn nguyên trong báo cáo "real".

**Kết luận:** precision 1.0 / recall 0.96 / FAR 0.0 là **điểm của bộ luật ra quyết định trên nhãn tự sinh**, không phải năng lực của Qwen3-VL trên video của bạn. Tuyên bố trong `progress.md` ("nghiệm thu thực địa trên 5 chuyến đi held-out") là **không trung thực về mặt phương pháp**, dù không cố ý.

### P0-6. Vi phạm bất biến single-writer ngay trong Swift Core

- `G3ProjectStore.swift:209`, `G4ProjectStore.swift:100`, `G5ProjectStore.swift:199`: mỗi store gọi `sqlite3_open_v2(... SQLITE_OPEN_READWRITE | FULLMUTEX)` + `BEGIN IMMEDIATE` trên **cùng file DB**.
- Cộng với `ProjectStore.swift:234` → **4 connection ghi đồng thời**, `busy_timeout` không nhất quán (3000 vs 5000 ms).
- 7 bảng `g3_*`/`g4_*`/`g5_*` được `CREATE TABLE IF NOT EXISTS` bên trong transaction của từng lần gọi → **không nằm trong `initializeSchema`, không có migration, không có `user_version`**, và backup/reconciler không biết chúng tồn tại.
- Hệ quả thực tế: `SQLITE_BUSY` ngẫu nhiên, schema trôi, restore có thể mất bảng.

### P0-7. Chuỗi chứng nhận phát hành không có gốc tin cậy

- `g5_release_audit.py:193-200` nạp public key Ed25519 từ `contracts/field_qa_ed25519_public_key.pem`, đường dẫn resolve qua `AIVIDEO_CONTRACTS_DIR` (env do caller đặt).
- **Trong repo không tồn tại file `.pem` này** (tôi đã `find` toàn cây — chỉ có thư viện cryptography trong venv). Nghĩa là nhánh CERTIFIED **không thể đạt trong production**.
- `tests/test_p0_integrity_gates.py` tự sinh key, tự ghi vào đúng đường dẫn đó, rồi assert PASS → **test đang chứng minh rằng thay thế key là con đường thành công**.
- Không có `key_id`, không kiểm tra fingerprint, không pin key trong binary.
- Cộng thêm: `is_synthetic_fixture` và `corpus_dir` là tham số do caller truyền → chứng nhận E0/E1 phụ thuộc 2 đầu vào do caller kiểm soát.

---

## 5. PHÁT HIỆN P1 — ROBUSTNESS, BẢO MẬT, HIỆU NĂNG

| # | Vấn đề | Bằng chứng |
|---|---|---|
| P1-1 | `commitPublication` không bind publication với job/attempt/project, và **không re-hash file** — chỉ `fileExists`. Bất kỳ attempt hợp lệ nào cũng commit được publication của project khác. | `ProjectStore.swift:1250-1273` |
| P1-2 | `saveClaim` public, không validate: có thể tạo claim `origin=user, reviewStatus=confirmed, supportStatus=supported` không cần con người duyệt. G3 chỉ đọc cột trạng thái → **bypass toàn bộ approval gate**. | `ProjectStore.swift:548-556`, `G3ProjectStore.swift:606-624` |
| P1-3 | Reconciler khởi động đánh `SUCCEEDED` khi **chỉ cần 1** publication COMMITTED. | `ProjectStore.swift:1470-1481` |
| P1-4 | ffprobe/ffmpeg (timeout 180 s) và hash hàng trăm MB chạy **bên trong transaction ghi** trên canonical actor → chặn toàn bộ DB và UI. | `G4ProjectStore.swift:264`, `G4S21Guard.swift:283/309`, `G5ProjectStore.swift:264` |
| P1-5 | `ResourceGovernor` có thể brick vĩnh viễn: PID worker chết không được reclaim (không TTL, `isHeartbeatSuspect` không dùng) → mọi lease sau bị từ chối tới khi relaunch. | `ResourceGovernor.swift:120-122`, `:151-156` |
| P1-6 | `allocateAttempt` chạy trước `acquireHeavyLease`; lease bị từ chối thì attempt mới treo RUNNING, attempt cũ đã bị CANCELLED, không rollback. | `ResourceGovernor.swift:181-192` |
| P1-7 | Một dòng stdout không decode được của Python → `failAllPending()` giết **mọi** request đang chạy (kể cả job 30 phút). | `WorkerClient.swift:579-605` |
| P1-8 | RPC `g5.preferences.manage` ghi file tuỳ ý qua `profile_path` do caller truyền, có `mkdir -p`. | `g5_capabilities.py:327/341/373`, `main.py:103` |
| P1-9 | Toàn bộ G4/G5 tin vào `db_path` do caller chỉ định (`mode=ro` chỉ chặn ghi, không chặn giả mạo nội dung). | `g4_resolve.py:168`, `g4_stage.py:46`, `g5_final.py:276/453` |
| P1-10 | `try!` trên rational time từ ffprobe → có thể trap (crash) với media pts/timebase cực trị. | `MediaIndexer.swift:64/70/74/114` |
| P1-11 | Audit rỗng hóa semantics: `origin="visual_model" if origin=="derived"` biến claim suy luận thành claim quan sát. | `semantic_verifier.py:340` |
| P1-12 | `g2.analyze_source` không thể trả kết quả cho video dài: ledger 86.400 frame ≈ 1.19 MB > `MAX_FRAME_BYTES` 1 MiB → `RESULT_TOO_LARGE`. | `main_g2.py:66/180-190` |
| P1-13 | Không có lease nào ở phía Python G2 (grep `governor` trong `workers/` = 0 hit) → Invariant 4 chỉ đúng trên UI, không đúng trên worker. | toàn bộ `workers/src` |
| P1-14 | VLM output **không được validate**: code validate chính cái dict nó vừa tạo, không validate `raw_text`; `replace("\ufffd","")` xoá lỗi encode thay vì reject. | `pipeline_adapters.py:602/632` |
| P1-15 | `subject_track_id` bịa theo index cửa sổ (`trk-w0000`), không có tracking thật; phân loại cảnh bằng so khớp chuỗi tiếng Việt. | `pipeline_adapters.py:610-627` |
| P1-16 | Không có ASR: `raw_audio_transcript_segments` không được caller nào truyền → `audio_analysis_status="completed"` là hằng số, Whisper chưa cài. | `full_frame_pipeline.py:651`, grep callers = 0 |
| P1-17 | VieNeu-TTS chưa cài (`ModuleNotFoundError: vieneu`) → bước voice luôn `blocked_tts_runtime_unavailable`. UI vẫn có slider 0.8–1.2× nhưng engine **từ chối mọi speed != 1.0**. | `g3_engine.py:492-494`, `G3ConsoleView.swift:347/593` |
| P1-18 | UI G3 **bịa claim** `claim_id="c1"`, `revision_id="rev-c1"`, `review_status=confirmed`, `support_status=supported` từ ô text tự do. | `G3ConsoleView.swift:527-539` |
| P1-19 | Test S02 "manual verification" tự ghi `"status": "PASS"` vào chính file mà `package_review.py` dùng để cấp PASS; không hề launch app qua Finder; bookmark dùng `.suitableForBookmarkFile` chứ không phải `.withSecurityScope`. | `tests/test_s02_manual_verification.swift:83/179/116` |
| P1-20 | Preflight coi "model đã cài" theo 3 định nghĩa khác nhau (file tồn tại / install registry / pinned manifest). Trên máy này weights thật và chạy được nhưng preflight báo `REAL_QWEN_VL_WEIGHTS_UNVERIFIED`. | `check_readiness.py`, `build/reports/readiness_report.json` |

---

## 6. PHÁT HIỆN P2 — NỢ KỸ THUẬT

- `AIVideoApp.swift` 2.726 dòng: `AppState` 1.143 dòng gánh 9 trách nhiệm (worker lifecycle, bookmark, scan, ffprobe, Resolve, G1/G2 store, batch, backup) + toàn bộ SwiftUI shell trong cùng file.
- `restartWorker()` re-entrant: `guard !isStartingWorker` kiểm tra trước `await worker.terminate()`, còn `isStartingWorker = true` set sau → double spawn.
- `runG2AnalysisOnAllVideos()` không tự chặn khi đã chạy; bảo vệ chỉ nằm ở `.disabled` của 3 view; `cancelBatchAnalysis()` chỉ set Bool, không cancel Task đang chạy.
- `defer { Task { await governor.releaseHeavyLease(...) } }` — release fire-and-forget, race với acquire kế tiếp trong batch.
- Phát hiện thành công của pipeline G4/G5 bằng `!resultText.contains("Lỗi")` — brittle và sai khi message đổi.
- `ArtifactPublisher` đọc cả file vào `Data(contentsOf:)` để hash → peak RSS gấp đôi với artifact 4K.
- `publishG4File` không revoke attempt khi throw → job treo RUNNING; copy 4 GB không giữ lease.
- Approval G3/G4/G5 **không** bump `projects.current_revision` → revision không phải mutation log, backup manifest sai root.
- `listCoverageRecords` tái tạo frame id bằng `Array(0..<count)` → mất khả năng truy vết frame thật.
- Đọc trạng thái (`currentG3Approval`, `currentG4Preview`, `currentG5FinalApproval`) dùng `BEGIN IMMEDIATE` → UI poll chặn writer.
- `ffmpeg` escape `\'` trong single-quote không được ffmpeg hiểu → path có dấu nháy làm hỏng graph caption.
- `except Exception: pass` xuất hiện 16 chỗ trong `workers/src` + `tools`.
- `docs/` và repo docs có 2 bản trùng nội dung (`.md` gốc và `docs/0x-*.md`).
- Script autobridge `auto_loop.py:117` gọi `https://api.openai.com/v1/responses` (mặc định `gpt-5.5`) — opt-in nhưng **đứng cạnh tuyên bố "100% local"**, cần tách khỏi sản phẩm.
- CI: `swiftc -frontend -parse` (chỉ syntax) cho app; 14/15 Swift suite không chạy trên CI; `runs-on: macos-26`.
- Không có `-warnings-as-errors`, không đếm warning → tuyên bố "0 warnings" không có artifact chứng minh.

---

## 7. BẢN ĐỒ CHỨC NĂNG: CÓ THẬT / NỬA VỜI / DANH NGHĨA

| Chức năng | Trạng thái | Ghi chú |
|---|---|---|
| Phân tích media bằng ffprobe, index PTS rational, VFR→CFR 24 | **Thật, tốt** | `media_indexer.py` + test S10 chắc |
| Qwen3-VL 4B offline inference | **Thật** | 3.09 GB weights, 4.4 s/lần, chạy được |
| Full-frame analysis pipeline | **Không chạy** | P0-1: luôn truncation với model thật |
| Coverage ledger / omission audit | **Danh nghĩa** | Coverage tự quy chiếu; omission audit ghi "đã kiểm" mà không kiểm |
| Semantic verifier 12 hàng quyết định | **Thật nhưng tự chấm** | Logic có, nhưng benchmark đo chính nó |
| Benchmark held-out S15 | **Giả** | Nhãn synthetic (P0-5) |
| Kịch bản G3 (story beats) | **Thật (heuristic)** | Sinh beat từ claim, chưa dùng LLM viết văn |
| VieNeu-TTS | **Chưa cài** | Luôn blocked; chưa từng chạy trên máy này |
| ASR / Whisper | **Chưa có** | Không có caller, không có dependency |
| SEARCH-v1 beam cut selection | **Thật** | Có test; biên phụ thuộc sort key shot_id (TypeError tiềm ẩn) |
| S19/G3 approval (Swift) | **Thật, mạnh** | Guard hash source + WAV + conform map |
| Resolve timeline 1080p/4K | **Có code, chưa nghiệm thu thật** | Resolve Studio có cài, nhưng chưa có bằng chứng render thật trong repo |
| Caption raster + burn-in | **Thật (ffmpeg)** | Có lỗi escape path |
| Publication 4 trạng thái + reconciler | **Thật nhưng hở** | P1-1/P1-3 |
| Backup/restore/migration | **Thật nhưng không atomic** | 5 actor hop rời rạc |
| Release certification E0/E1 | **Không thể đạt** | Thiếu PEM, key không pin |
| 4-bước UI + auto-wiring | **Thật, đẹp** | Nhưng nút "chạy phân tích" sẽ lỗi P0-1 |

**Tóm lại:** phần "hạ tầng tin cậy" (store, guard, publication, media index) khá tốt; phần "trí tuệ" (VLM → quan sát → claim → kịch bản) **chưa thông**.

---

## 8. ĐƯỜNG ĐI (USER FLOWS + RPC + DỮ LIỆU)

### 8.1. Bốn bước người dùng

1. **Tư liệu** — chọn thư mục (`⌘O`) → Security-Scoped Bookmark → `scanDirectoryAsync` → `media.probe` (ffprobe) → danh sách video/ảnh + inspector.
2. **Kịch bản & Thoại** — `g3.story.generate` → beats; `g3.story.edit`; `g3.voice.trial` (TTS); `g3.cut.search` (SEARCH-v1); `g3.approval.propose` → Swift `G3ProjectStore` commit S19.
3. **Preview** — `g4.caption.stage` → `g4.timeline.build` → `g4.render.start` → `g4.render.inspect` → `g4.preview.technical_qc` → S21 approve.
4. **Final 4K** — `g5.caption.stage_4k` → `g5.timeline.build_4k` → `g5.render.start_4k` → `g5.render.inspect_4k` → `g5.final.technical_qc` → `g5.handoff.fork` (DRP) → S22 approve → `g5.release.manifest`.

### 8.2. Đường phân tích G2 (thực tế đang gãy ở bước 4)

```
AppState.analyzeSingleSource
  → RPC g2.analyze_source
    → media.probe / probe_and_index_real_video      (OK)
    → S11ModelRegistryAndAdapters.preflight          (OK, file presence)
    → build_offline_visual_window_inspector          (OK, load 3 GB model)
    → FullFrameAnalysisPipeline.run_or_resume_analysis
        for each 16-frame window:
           inspector(window)  → ffmpeg decode 1 frame + mlx_vlm.generate
           audit_vision_processor_coverage(16 intended, 1 accepted)
           → truncation_detected = True
           → raise POST_PROCESSOR_TRUNCATION           ← GÃY TẠI ĐÂY
    → (không bao giờ tới) claims/reviews → ProjectStore
```

### 8.3. Bản đồ RPC (37 method)

| Nhóm | Method |
|---|---|
| Hệ thống | `initialize`, `system.ping`, `ai.model_status`, `ai.local_model_infer`, `ai.local_infer_test` |
| Media | `media.probe`, `media.index_and_proxy`, `g2.analyze_source` |
| Resolve | `resolve.status`, `resolve.spike_timeline` |
| G3 | `g3.story.generate`, `g3.story.edit`, `g3.voice.trial`, `g3.cut.search`, `g3.cut.stage`, `g3.approval.propose`, `g3.metrics.script_ready` |
| G4 | `g4.caption.stage`, `g4.timeline.build`, `g4.render.start`, `g4.render.inspect`, `g4.preview.technical_qc` |
| G5 | `g5.caption.stage_4k`, `g5.timeline.build_4k`, `g5.render.start_4k`, `g5.render.inspect_4k`, `g5.final.technical_qc`, `g5.handoff.fork`, `g5.capability.evaluate`, `g5.photo.match`, `g5.events.partial_order`, `g5.audit.final_vs_sources`, `g5.preferences.manage`, `g5.comedy.align_cues`, `g5.fault.run_suite`, `g5.eval.e0_e1_accounting`, `g5.release.manifest` |

### 8.4. Dữ liệu

- 15 bảng canonical: `projects, workdays, source_media, source_revisions, claims, approvals, idempotency_journal, jobs, job_attempts, artifact_publications, artifact_pins, schema_migrations, coverage_records, review_items, raw_observations`.
- 7 bảng ad-hoc (không migration): `g3_scripts, g3_selected, g3_voice_reviews, g3_approvals, g4_preview_approvals, g5_final_approvals, g5_manual_handoff_branches`.

---

## 9. ĐỘ TIN CẬY CỦA BỘ TEST

**Python: đáng tin.** `run_python_tests.py` có `StructuredJSONLTestResult` thật: PASS chỉ khi `addSuccess`, skip → NOT_RUN, unexpected success → FAIL, `main()` trả 1 nếu fail. Tôi chạy được 156/156 trong 9.8 s, artifact JSONL khớp.

**Swift: đếm bằng `echo`, không đếm assertion.** `run_tests.sh` in `[1/2] … [15/15]` với mẫu số không nhất quán, kết thúc bằng `echo "=== ALL ... SUCCESSFULLY ==="`. Hai suite (`test_source_revision_identity.swift`, `test_s02_manual_verification.swift`) không phát JSONL nên `package_review.py` không nhìn thấy. Exit code có propagate (tốt), nhưng "15/15 PASS" là **số banner**, không phải số test.

**S02 "manual": tự chứng nhận.** Test ghi file evidence mà công cụ tổng hợp dùng để cấp PASS. Đây là lỗi phương pháp nghiêm trọng nhất trong tooling.

**Benchmark S15: không đo model.** Như P0-5. Câu hỏi kiểm tra: *nếu thay Qwen3-VL bằng một hàm trả chuỗi cố định, test S15 có fail không?* → **Không**, vì metric lấy từ fixture.

**Kết luận:** 156 Python PASS là thật; 15 Swift suite "PASS" là thật về mặt exit code nhưng không có nghĩa 15 bộ test đầy đủ; S02 PASS và S15 PASS **không chứng minh điều chúng tuyên bố**.

---

## 10. HƯỚNG PHÁT TRIỂN TƯƠNG LAI

### 10.1. Nguyên tắc: sửa từ dưới lên

Đừng thêm tính năng. Thứ tự đúng: **làm cho một video chạy hết chuỗi** → đo lại → mới mở rộng. Hiện tại bạn đang có 5 tầng gate cho một pipeline chưa qua nổi tầng đầu.

### 10.2. Lộ trình 4 pha

**Pha 0 — Unblock G2 (1–2 ngày)**
- Chốt hợp đồng inspector ↔ audit (xem §11.1).
- Bỏ `_inspector_fn` khỏi `params`.
- Reject payload rỗng; bỏ default `intended_frame_ids`/`scenic_or_motion`.
- Clamp coverage; lấy mẫu số từ container (`nb_frames` / duration × fps).
- Paginate ledger frame ids.
- Test hồi quy: real inspector → pipeline → có observation; payload rỗng → raise; 86.400 frame → payload < 1 MiB.

**Pha 1 — G2 trung thực & đo được (1–2 tuần)**
- Multi-frame inference: 4–8 frame/cửa sổ trong một `generate` (Qwen3-VL hỗ trợ multi-image), prompt có mốc thời gian.
- Gắn nhãn thật cho 5 clip (claim/event ground truth do người viết), tính precision/recall từ **quan sát thật**; xoá fixture synthetic khỏi đường gate.
- Gate theo cận dưới Wilson/bootstrap, không theo point estimate.
- ASR: tích hợp `whisper.cpp`/`mlx-whisper`, truyền `raw_audio_transcript_segments`, bỏ hằng số `audio_analysis_status`.
- Omission audit: hoặc implement thật, hoặc xoá — không để trạng thái "recovered_evidence" giả.
- `ffmpeg -ss` theo cửa sổ thay vì decode từ frame 0 (O(n²) → O(n)).
- Lease: thêm lease token vào RPC hoặc ghi rõ worker chạy dưới lease của caller.

**Pha 2 — Thông chuỗi tới render (2–4 tuần)**
- Cài VieNeu-TTS; quyết định: hỗ trợ speed thật (resample/SSML) hoặc bỏ slider; đồng bộ UI ↔ engine.
- G3: bỏ `c1`/`rev-c1`, bind vào `ClaimRecord` thật; nút "Duyệt" chỉ bật khi có claim confirmed.
- Sửa mismatch transition S18 (cho phép overlap) ↔ G4 (yêu cầu overlap = 0).
- Swift: 1 writer duy nhất; chuyển ffprobe/hash ra khỏi transaction; reconciler yêu cầu **đủ** artifact; bind publication + re-hash.
- Nghiệm thu Resolve thật: 1 clip → preview 1080p → 4K → DRP mở lại được, có log + hash.

**Pha 3 — Phát hành & tin cậy (2 tuần)**
- Pin Ed25519 key trong bundle + `key_id`; provision PEM ngoài repo; test "key khác phải fail".
- `corpus_kind` bắt buộc; `is_synthetic_fixture` phải nằm trong manifest đã ký.
- Bỏ S02 tự chứng nhận; Swift suite ghi JSONL; CI chạy app build + toàn bộ suite; Developer ID + notarization.
- Bỏ path cứng; resolve `ffmpeg`/`python` qua PATH/env.

**Pha 4 — Sản phẩm (sau khi Pha 0–3 xanh)**
- Viết kịch bản bằng LLM local (Qwen3-8B) có ràng buộc evidence.
- Semantic retrieval trên footage (embedding DINOv2/CLIP) để chọn B-roll.
- Caption tiếng Việt có alignment ASR; loudness EBU R128; music ducking.
- Export đa tỉ lệ 9:16 / 1:1 / 16:9; preset theo nền tảng.
- Đo chất lượng biên tập với người thật (MOS), không chỉ metric kỹ thuật.

### 10.3. định nghĩa "xong" nên đổi

Hiện tại "xong" = test xanh. Đề xuất: **"xong" = một video 60 s đi từ thư mục nguồn tới file MP4 4K mở được, có log hash từng bước, chạy lại được từ checkpoint sau khi kill app giữa chừng.**

---

## 11. ĐỀ XUẤT BƯỚC TIẾP THEO CHO PIPELINE VIDEO (chi tiết kỹ thuật)

### 11.1. Quyết định thiết kế phải chốt trước khi sửa code

Có 2 hướng, chọn **một**:

- **(A) Full-frame thật:** decode toàn bộ `intended_frame_ids` của cửa sổ (16 frame) và đưa vào model. Đúng triết lý "full-frame" nhưng Qwen3-VL 4B với 16 ảnh/cửa sổ sẽ rất chậm và tốn RAM trên M1 Pro 16 GB.
- **(B) Sampling có khai báo:** mỗi cửa sổ gửi N frame (N=4 hoặc 8), và **`intended_frame_ids` của audit = đúng N frame đó**; coverage được báo theo 2 chỉ số tách biệt: `vlm_frame_coverage` (N/16) và `decode_coverage` (frame đã decode/giải mã). Không bao giờ gọi N/16 là "100%".

Khuyến nghị **(B)** cho v1.1, kèm ghi chú rõ trong UI: "Phân tích 8/16 khung hình mỗi cửa sổ".

### 11.2. Thứ tự công việc (mỗi mục có tiêu chí nghiệm thu)

1. **Sửa hợp đồng inspector/audit** — `pipeline_adapters.py`, `full_frame_pipeline.py`.
   *Nghiệm thu:* chạy `run_or_resume_analysis` với model thật trên `fixtures/corpus/trip-holdout-01-dalat.mp4` → có ≥1 observation, status `completed`, không raise.
2. **Xoá fail-open + backdoor** — `full_frame_pipeline.py:515/544`, `main_g2.py:458`.
   *Nghiệm thu:* inspector trả `{}` → raise `INVALID_VISUAL_PAYLOAD`; RPC có `_inspector_fn` → `ValueError`.
3. **Coverage trung thực** — mẫu số từ container, clamp [0,1], tách 2 chỉ số.
   *Nghiệm thu:* test declared=10/indexed=40 không còn cho 4.0; video 36 frame báo đúng 36.
4. **Payload ≤ 1 MiB** — trả `frame_id_ranges` + counts thay vì liệt kê.
   *Nghiệm thu:* test 86.400 frame → JSON < 1.048.576 byte, vẫn dựng lại được tập frame id.
5. **Benchmark thật** — xoá `(1200,1200)`, xoá `real_video_corpus_verified=True` vô điều kiện, nạp nhãn người viết cho 5 clip.
   *Nghiệm thu:* thay inspector bằng hàm trả text cố định → suite S15 **phải fail**.
6. **Provenance claim** — xoá `origin` rewrite; thêm `source_sha256` + `start/end_pts` vào `EvidenceEdge`.
   *Nghiệm thu:* claim `derived` không thể hiện ra là `visual_model`.
7. **ASR branch** — cài Whisper, truyền transcript thật.
   *Nghiệm thu:* clip có tiếng nói → `audio_state="speech_detected"`, segment có timecode.
8. **Lease + subprocess** — đăng ký ffmpeg/ffprobe vào child registry, giữ lease suốt job.
   *Nghiệm thu:* kill worker khi đang decode → không còn ffmpeg orphan (`pgrep`).
9. **Đo lại** — chạy 5 clip, ghi thời gian/frame, RSS đỉnh, số observation, rồi mới cập nhật tài liệu.
   *Nghiệm thu:* báo cáo có số đo thật + log; không dùng chữ "PASS" cho tới khi có.

### 11.3. Những gì nên **xoá** thay vì sửa

- `merge_window_observations`, `run_guided_revisit_without_overwriting_raw`, `compute_multi_window_unique_coverage`, `validate_model_policy_on_16gb` — hiện chỉ test gọi.
- `review_workflow.py` — không được gate nào dùng.
- `g5.fault.run_suite` tự dựng DB rồi tự trả "PASS" — thay bằng fault injection trên đường thật.
- `_inspector_fn`, `simulated_ram_rss_bytes`, `AIVIDEO_G5_SIMULATE_FREE_BYTES` — hook chỉ để test.
- `screen` giả trong `omission audit`.

---

## 12. PHỤ LỤC — LỆNH TÁI LẬP

```bash
# 1. Toàn bộ test Python (kỳ vọng: 156 PASS, 0 skip, exit 0)
workers/.venv/bin/python3 tools/run_python_tests.py

# 2. Ma trận đầy đủ (Swift + Python + build + codesign)
./tools/run_tests.sh

# 3. Chứng minh P0-1 (kỳ vọng: POST_PROCESSOR_TRUNCATION)
workers/.venv/bin/python3 - <<'PY'
import sys; sys.path.insert(0,"workers/src")
from pathlib import Path
from aivideo_workers.media_indexer import SourceFrameEntry, probe_and_index_real_video, _compute_file_sha256
from aivideo_workers.pipeline_adapters import S11ModelRegistryAndAdapters
from aivideo_workers.full_frame_pipeline import BoundedPipelineConfig, FullFrameAnalysisPipeline
clip = Path("fixtures/corpus/trip-holdout-01-dalat.mp4").resolve()
p = probe_and_index_real_video(clip)
pts=[SourceFrameEntry(frame_id=int(f["frame_id"]),pts=int(f["pts"]),duration_pts=int(f["duration_pts"]),
     time_base_num=int(f["time_base_num"]),time_base_den=int(f["time_base_den"]),key_frame=False) for f in p["pts_index"]]
pipe=FullFrameAnalysisPipeline(BoundedPipelineConfig())
pipe.run_or_resume_analysis(source_revision_id="rev",source_sha256=_compute_file_sha256(clip),pts_index=pts,
    total_declared_source_frames=len(pts),checkpoint_path=Path("/tmp/ck.json"),
    has_audio_stream=True,window_inspector_fn=S11ModelRegistryAndAdapters().build_offline_visual_window_inspector(clip))
PY

# 4. Preflight (kỳ vọng hiện tại: NO-GO)
workers/.venv/bin/python3 tools/check_readiness.py

# 5. Dọn side-effect của lần chạy test
git checkout -- fixtures/AIVideo_G0_Spike.drp reports/evidence/s02_t1_finder_launch.json reports/evidence/s02_t2_bookmark.json
```

---

## 13. TỔNG KẾT CỦA NGƯỜI REVIEW

Bạn đã làm được phần khó nhất về mặt kỹ thuật tổ chức: tách quyền ghi, mô hình publication, evidence contract, guard độc lập. Đó là nền tốt và hiếm.

Nhưng bạn đã tự lừa mình ở đúng chỗ nguy hiểm nhất: **các con số nghiệm thu**. Khi một chỉ số được sinh ra từ fixture do chính mình viết, khi test tự ghi `PASS`, khi benchmark "thực địa" vẫn chấm bằng nhãn synthetic — thì bộ gate không còn bảo vệ bạn, nó chỉ trang trí cho quyết định đã có sẵn.

Việc cần làm không phải là thêm gate G6. Là **xoá bớt gate, hạ tham vọng xuống một video 30 giây, và làm cho nó chạy thật từ đầu đến cuối.** Khi một video chạy được, mọi con số sẽ tự có nghĩa.
