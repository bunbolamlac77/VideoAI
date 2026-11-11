# BÁO CÁO ĐÁNH GIÁ TOÀN DIỆN & KẾ HOẠCH KIỂM THỬ — AIVideo v3.1

**Vai trò:** Kỹ sư trưởng khó tính, thẩm định độc lập (không sửa mã nguồn trong lượt này)
**Ngày:** 2026-11-11 · **Cây mã nguồn:** working tree hiện tại (24 file sửa + 12 file mới, chưa commit) trên `main` @ `3e3b22a`
**Quy mô đã đọc:** 46 file Swift (21.268 dòng, gồm 21 suite test), 60 file Python production/test (27.640 dòng), 7 JSON contract, 3 schema JSON, 4 workflow CI, 12 tài liệu đặc tả 01–11 + README
**Nguyên tắc:** không tin docstring, không tin số liệu tự khai, không tin test chỉ assert vào hằng số/mock. Mọi kết luận phải truy được về **dòng code** hoặc **output lệnh chạy thật** trong phiên này.

> Tài liệu đi kèm: [PLAYBOOK_KIEM_THU.md](PLAYBOOK_KIEM_THU.md) — danh mục đầy đủ mọi chức năng, đường đi, thao tác và lệnh cần thực hiện để test.

---

## 0. KẾT LUẬN TRƯỚC KHI ĐỌC CHI TIẾT

AIVideo **đã tiến bộ rõ rệt** so với bản thẩm định `AUDIT_20261110_FULL_EVALUATION.md`: 7 lỗi P0 cũ trong đó **6 lỗi đã được sửa thật** và kiểm chứng được trong phiên này. Hệ thống hiện là một **prototype kỹ thuật có kỷ luật**, nhưng **chưa phải sản phẩm có thể đưa cho người dùng thật**, và có **một nguyên tắc cốt lõi của chính dự án đang bị vi phạm ở 4 chỗ mới**: *"không bịa; Unknown là trạng thái hợp lệ"*.

Ba câu quan trọng nhất:

1. **Vẫn còn một đường bịa kết quả hoàn chỉnh, và nó nằm trên mặt RPC.** `main_g2.py:470` cho caller tự chỉ định `checkpoint_dir`; `full_frame_pipeline.py:542-558` nạp nguyên `raw_observations` từ file đó và trả về như quan sát của model. Caller chỉ cần một file video hợp lệ (để qua được ffprobe) + tự ghi checkpoint ⇒ nhận về observation `origin="visual_model"` **không cần model**, không decode một frame nào. Đây là hậu duệ trực tiếp của backdoor `_inspector_fn` cũ, chỉ đổi vỏ.
2. **Luồng em dùng mặc định không thể duyệt được S19.** LLM kịch bản (`script_engine="llm"`) bị ràng buộc *không lặp nguyên văn claim* (`story_writer.py:74`), trong khi `G3ProjectStore.approveG3Draft` so **nguyên văn** narration với `claims.text` (`G3ProjectStore.swift:726-737`). Mọi kịch bản do LLM viết sẽ bị chặn ở bước "Duyệt kịch bản" — fail-closed (an toàn) nhưng chết gate.
3. **"Bộ chứng nhận" của dự án có thể tự lên màu xanh.** `package_review.py:483-499` suy `DONE` từ việc *không có record FAIL* (xoá evidence ⇒ DONE), và `package_review.py:713-715` **không trả exit code khác 0** trong mọi trường hợp, trong khi `auto_sync_git.sh` dựa vào exit code để quyết định `git push`. Tầng test kỹ thuật khá; tầng *báo cáo nghiệm thu* vẫn là hàng rào tre.

**Điểm tổng: 5,6/10** — kiến trúc 7,5 · hiện thực 4,5 · độ tin cậy của bằng chứng 4,0.

---

## 1. KẾ HOẠCH ĐÁNH GIÁ ĐÃ THỰC HIỆN

### 1.1. Chia lát cắt và cách đánh giá

| Lát | Phạm vi | Cách đánh giá | Ai thực hiện |
|---|---|---|---|
| A. Swift Core storage & guard | `ProjectStore`, `G3/G4/G5ProjectStore`, `G3ApprovalGuard`, `G4S21Guard`, `G5S22Guard`, `ArtifactPublisher`, `G4FilePublisher`, `BackupRestoreService`, `ResourceGovernor` (11 file) | Đọc trọn + grep chéo toàn repo | Review 1 |
| B. App UI & state | `AIVideoApp`, `AppState`, `AppState+ScriptBrief`, 3 console view, `ScriptBriefView`, `AIVideoTheme` (8 file) | Đọc trọn + đối chiếu `WorkerClient`/`G3StoryRequestBuilder` | Review 2 |
| C. Python G2 | `media_indexer`, `full_frame_pipeline`, `pipeline_adapters`, `main_g2`, `prefilter`, `semantic_verifier`, `g2_benchmark_runner`, `local_model` | Đọc trọn + probe thuần (clip synthetic 640×360 trong `/tmp`) | Review 3 |
| D. Python G3 | `g3_engine`, `g3_rpc_safe`, `story_writer`, `tts_engine`, `wedding_scenes`, `review_workflow` | Đọc trọn + grep call sites | Review 4 |
| E. Python G4/G5 & release | `native_render`, `g4_*`, `resolve_adapter`, `g5_*`, `main`, `model_installation`, `corpus_labels` | Đọc trọn + shasum PEM, đọc schema | Review 5 |
| F. Tooling / test / CI / contracts | `tools/*` (12 script), `.github/workflows`, `contracts/*`, `migrations/`, toàn bộ `tests/` | Đọc + `bash -n`, đếm JSONL, validate schema bằng `jsonschema` | Review 6 |
| G. Kiểm chứng chéo (người điều phối) | Các phát hiện P0 nghiêm trọng nhất | Đọc lại đúng dòng + xem file JSONL kết quả test | Trưởng thẩm định |

### 1.2. Phân mức

- **P0** — phá vỡ toàn vẹn dữ liệu/bằng chứng, hoặc chặn luồng người dùng chính, hoặc ghi sai trạng thái phê duyệt.
- **P1** — lỗi robustness/hiệu năng/bảo mật có điều kiện, hoặc tuyên bố trong tài liệu không khớp mã.
- **P2** — nợ kỹ thuật, khả năng bảo trì, khả năng tiếp cận.

### 1.3. Bằng chứng thực thi trong phiên này (chạy thật, output thật)

| Lệnh | Kết quả thật |
|---|---|
| `workers/.venv/bin/python3 tools/run_python_tests.py` | **279 test · 0 FAIL · 0 ERROR · 4 NOT_RUN**, exit 0. Artifact: `build/reports/python_test_summary.json` + `python_test_records.jsonl` (279 record khớp) |
| 4 test NOT_RUN | `test_s15…real_video_corpus_passes_with_verified_held_out_clips` (cần `AIVIDEO_RUN_HEAVY_G2=1`), `test_s16…real_qwen3_writes_pov_script` (`…_STORY`), `test_s17_tts_engine…real_kokoro_synthesis_end_to_end` (`…_TTS`), `test_s17_voice_phrases…real_kokoro_per_phrase_offsets` (`…_TTS`) — **chính 4 ca chứng minh model thật chạy end-to-end đều chưa chạy** |
| `tests/test_s11_real_vlm_inference.py` (trong suite) | PASS — Qwen3-VL 4B thật chạy trên máy này |
| `./tools/build_macos_app.sh` | exit 0 — "BUILD SUCCESSFUL: apps/macos/build/AIVideo.app" |
| `workers/.venv/bin/python3 tools/check_readiness.py` | **NO-GO**, blocker `UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS: CORPUS_KIND_NOT_FIELD:SYNTHETIC_FIXTURE, LABELS_NOT_HUMAN:['agent_visual_review'], NOT_FIELD_FOOTAGE:['synthetic_title_card']` |
| `swiftc … test_g2_coverage_dto.swift` (SDK `MacOSX.sdk`) | PASS — nhưng phải dùng SDK cụ thể; `xcrun --show-sdk-path` (MacOSX27) **không tương thích** với swiftc 6.3.3 |
| Probe `g2.analyze_source` qua stdin JSON-RPC trên clip synthetic 36 frame | `vision_model_installed=True`, 3 observation, `audio_branch_state="no_audio"`, `omission_findings_count=3`, checkpoint ghi vào **thư mục do caller chọn** |
| `ffprobe` 5 clip corpus | Mỗi clip **1080×1920, 24/1 fps, 36 frame, 1,5 s**; label `synthetic_title_card`, `agent_visual_review`, **0 claim, 0 event** |

> Ghi chú trung thực: `run_python_tests.py` ghi đè `build/reports/`, và probe của tôi ghi `/tmp/g2probe/g2_ckpt_*.json` — không file tracked nào bị thay đổi bởi đánh giá này.

---

## 2. KIẾN TRÚC HIỆN CÓ

- **4 tầng:** SwiftUI macOS (4 bước + 5 màn chẩn đoán) → Swift Core `AIVideoCore` (SQLite WAL actor **duy nhất** + publication 4 trạng thái + 3 guard G3/G4/G5) → Python worker (stdio JSON-RPC 2.0, **32 method** đăng ký trong `main.py`) → **ffmpeg native renderer** (mặc định) và DaVinci Resolve (tuỳ chọn).
- **Nguồn sự thật:** SQLite canonical — **23 bảng** (đo thật: `sqlite3 -readonly project_store.db "SELECT count(*) FROM sqlite_master WHERE type='table'"` ⇒ 23) tạo trong `ProjectStore` (`initializeSchema` 16 bảng + `initializeGateSchema` 7 bảng gate `g3_*`/`g4_*`/`g5_*`).
- **Bằng chứng:** `source_sha256` + PTS/timecode + `origin`/`epistemic_status` + revision & hash của claim/WAV/cut plan để duyệt S19/S21/S22.
- **Tài nguyên:** `ResourceGovernor` single-lease trên ngân sách 16 GB.
- **100% local:** Qwen3-VL 4B (MLX), Qwen3-8B-4bit (kịch bản), Kokoro-Vietnamese (TTS), ffmpeg. Không có cloud fallback trong đường chạy sản phẩm.

Đánh giá: kiến trúc đúng hướng và hiếm gặp ở mức kỷ luật này. Vấn đề nằm ở **chỗ nối giữa các tầng** và ở **cách dự án tự đo chính mình**, không nằm ở thiết kế.

---

## 3. BẢNG ĐIỂM

| Hạng mục | Điểm | Căn cứ chính |
|---|---:|---|
| Thiết kế kiến trúc & phân quyền ghi | **7.5** | 1 connection ghi duy nhất (`ProjectStore.swift:488`); 3 store con đi qua `withCanonicalTransaction` |
| Toàn vẹn dữ liệu | **5.0** | commitPublication bind + re-hash ✔; nhưng job→SUCCEEDED sớm, restore không rewrite path, backup không atomic |
| Pipeline G2 (hiểu nội dung) | **4.0** | audit coverage thành tautology; `checkpoint_dir` RPC; decode toàn file mỗi cửa sổ; benchmark không chấm output model |
| G3 (kịch bản/TTS/cut) | **5.0** | TTS + Swift guard chắc; nhưng LLM rewrite chặn S19, node budget SEARCH-v1 sai đơn vị |
| G4/G5 (render/xuất bản) | **4.0** | renderer thật chạy được (20 test), nhưng receipt không ràng buộc plan, fault suite tự PASS |
| Bảo mật | **5.0** | nhiều path guard thật; còn `preferences.manage`, `models_root_dir`, `AIVIDEO_*` env |
| Chất lượng test | **5.5** | Python tốt (fault injection thật); Swift dùng banner tautology, 5 suite không phát JSONL, BLOCKED vẫn exit 0 |
| Chuỗi evidence → gate → release | **3.5** | package_review suy DONE, luôn exit 0; release manifest không ký; corpus là title card |
| Trải nghiệm người dùng | **5.5** | 4 bước rõ ràng, auto-wiring; nhưng 2 chỗ UI tự khai "verified", "Dừng" không huỷ thật |
| Khả năng bảo trì | **4.5** | `ProjectStore` 2463 dòng, `g3_engine` 1800, `AIVideoApp` 1547, `AppState` 1301; bundle chứa 2 bản worker |
| **Tổng** | **5.6** | |

**Một câu:** *Bạn đã sửa rất tốt các lỗ hổng được chỉ ra, nhưng lại tái sinh đúng loại lỗi cũ ở hình thức mới — "bịa kết quả" chuyển từ inspector sang checkpoint, "tự chứng nhận" chuyển từ S02 sang package_review, "benchmark giả" chuyển từ fixture sang nhãn tự khai. Cần một vòng siết vào đúng ba chỗ này trước khi thêm bất kỳ tính năng nào.*

---

## 4. P0 — SAI LÕI (phải sửa trước khi làm gì khác)

### P0-01 · `checkpoint_dir` qua RPC cho phép bịa toàn bộ kết quả phân tích
- `main_g2.py:470-471`: `ckpt_dir = Path(params.get("checkpoint_dir") or tempfile.gettempdir())`
- `full_frame_pipeline.py:542-558`: nạp `committed_windows` / `skipped_windows` / `raw_observations` từ JSON **không ký**, không xác minh nguồn.
- Hệ quả: caller-fake ghi checkpoint với `raw_observations` tuỳ ý ⇒ response `origin="visual_model"`, coverage 1.0, **không cần model**. Trong phiên này tôi xác nhận checkpoint được ghi vào thư mục do caller chỉ định (`/tmp/g2probe/g2_ckpt_00000000_fe989e70.json`).
- Sửa: bỏ `checkpoint_dir` khỏi RPC; checkpoint chỉ ghi trong thư mục do app quy định; ký/HMAC + bind `source_sha256`/`input_fingerprint`; **từ chối resume nếu `window_inspector_fn is None`**; mỗi record checkpoint phải có `model_id`/`prompt_sha256`/`frame_sha256` của frame đã gửi.

### P0-02 · Audit coverage là vòng tròn tự chứng — `POST_PROCESSOR_TRUNCATION` trở thành dead code
- `full_frame_pipeline.py:682-690`: `intended_frame_ids=planned_ids` (không phải `win.intended_frame_ids`).
- `pipeline_adapters.py:772,784`: `submitted_frame_ids = list(planned_ids)` … `"planned_frame_ids": submitted_frame_ids`.
- `full_frame_pipeline.py:661`: chặn `accepted ⊆ planned` **trước** audit ⇒ `truncation_detected` không thể True.
- Hệ quả: Lỗi cũ "luôn truncation" đã hết, nhưng **cơ chế phát hiện đã bị vô hiệu**; coverage mỗi cửa sổ luôn 1.0 dù chỉ 2/16 frame tới model.
- Sửa: audit nhận `win.intended_frame_ids`; báo riêng `window_coverage = |accepted ∩ window| / |window|`; cấm `planned ≡ accepted`; giữ `POST_PROCESSOR_TRUNCATION` cho trường hợp model thực sự bỏ frame đã gửi.

### P0-03 · Receipt native không ràng buộc plan/publication ⇒ có thể thay MP4 4K
- `G5S22Guard.swift:362-374`: chỉ kiểm `schema`, kích thước, fps, `total_frames`, `beats[].frames`, `output.sha256`.
- `native_render.py:786-795`: receipt chứa `plan_sha256` nhưng **guard không đối chiếu** với plan đã duyệt.
- Hệ quả: bất kỳ MP4 2160×3840/24 fps đúng số frame + receipt tự chế (hash 64 hex bất kỳ) đều qua `verifyFinalProvenance`, miễn chuỗi dependency id đúng.
- Sửa: guard bắt buộc `plan_sha256 == plan đã duyệt` và đối chiếu `video_publication_id`/`voice_publication_id` từng beat với `artifact_publications`; receipt do Swift dựng từ DB (worker không giữ quyền tạo receipt).

### P0-04 · `g5.fault.run_suite` tự dựng DB rồi tự trả `"PASS"`
- `g5_release_audit.py:49-55`: `db_path = root / "fault_test.sqlite3"`; `:150-156`: `"status": "PASS"`.
- Hệ quả: 4 "boundary" chỉ chạy trong tempdir, không chạm DB thật/Resolve/đĩa thật ⇒ PASS trên máy hỏng hoàn toàn. Được dùng làm bằng chứng S25 trong `package_review`.
- Sửa: chạy trên bản sao ProjectStore + publication thật với fault injection thật; đổi status `SELF_TEST_ONLY`; loại khỏi evidence release.

### P0-05 · Gate "tự DONE khi mất bằng chứng" và `package_review` không bao giờ chặn
- `package_review.py:483-499`: `s12_status = "FAIL" if s12_failed else "DONE"` — không có record ⇒ DONE (kèm nhãn khen hardcode "…S15 benchmark 5 video PASS").
- `package_review.py:713-715`: `create_review_package(out_name)` không `sys.exit` ⇒ **luôn exit 0**; `auto_sync_git.sh` dùng exit code này để quyết định push.
- Hệ quả: xoá `build/reports/swift_s12_s15_records.jsonl` rồi chạy lại ⇒ G2 vẫn DONE; test FAIL vẫn `git push`.
- Sửa: DONE chỉ khi `expected_case_ids ⊆ {PASS}`; thiếu record = NOT_RUN; `sys.exit(1)` khi có FAIL/BLOCKED/NOT_RUN; chặn push.

### P0-06 · 5 "clip chuyến đi held-out" không phải dữ liệu thực địa
- `fixtures/corpus/*.mp4`: 5 file **1080×1920, 24/1, 36 frame, 1,5 s** (16–18 KB) — title card tĩnh.
- `fixtures/corpus/labels/*.json`: `labeler_type: "agent_visual_review"`, `labeler_id: "deepseek-harness-vision"`, `source_kind: "synthetic_title_card"`, `claims: []`, `events: []`.
- Preflight hiện **đúng** khi báo NO-GO (điểm cộng), nhưng `task_plan.md` vẫn ghi "🟢 DONE — … S15 benchmark trên 5 video held-out thực tế" và `package_review` vẫn in "5 Held-Out Rec.709 Video Corpus Benchmark PASS".
- Sửa: đổi tên thư mục/fixture thành `fixtures/smoke/`; sửa `task_plan.md`/`progress.md` theo sự thật; chỉ còn **một** nguồn định nghĩa "corpus" là manifest đã ký.

### P0-07 · UI tự khai `voice_review_status="verified"`, worker tin nguyên văn
- `G3ConsoleView.swift:677-678`: `"voice_review_status": .string("verified"), "voice_wav_published": .bool(true)` — **hằng số**; không đọc store, không kiểm WAV đã publish.
- `g3_engine.py:1095-1107`: cổng S18 chỉ kiểm hai tham số này ⇒ bỏ qua bảo vệ "phải nghe và duyệt giọng".
- Sửa: bỏ hai khoá khỏi UI; worker tự tra `g3_voice_reviews` + `artifact_publications` (hoặc Swift truyền `voice_approval_id` và worker xác minh với DB canonical ở chế độ read-only).

### P0-08 · LLM rewrite narration không thể qua được S19 (luồng mặc định chết gate)
- `story_writer.py:74`: prompt ràng buộc **không** lặp nguyên văn claim.
- `G3ProjectStore.swift:726-737`: `let expected = mustAttribute ? "Theo thông tin đã được người quay xác nhận: " : "" + row[0]; guard narration == expected`.
- Hệ quả: kịch bản LLM (mặc định `scriptEngine: "llm"` trong `G3StoryRequest.swift:131`) luôn bị chặn ở "Duyệt kịch bản", **sau khi đã trả tiền TTS** cho đúng đoạn text đó.
- Sửa (chọn 1): (a) lưu narration như một claim revision mới có evidence trước khi duyệt; (b) cho duyệt khi có `voice_text_origin="llm_local_rewrite"` + `raw_output_sha256` + `prompt_sha256` và Swift chạy kiểm entailment; (c) chỉ dùng LLM làm bản nháp, narration chính vẫn từ claim.

### P0-09 · UI gửi scope revision bịa (`scope-g2-main`) và `scopeRevalidationStatus: "complete"` cứng
- `G3ConsoleView.swift:111`: `@State private var scopeRevisionId: String = "scope-g2-main"`.
- `G3StoryRequest.swift:116`: `scopeRevalidationStatus: "complete"` — không code nào tính.
- Sửa: picker lấy `evidence_scope_revision_id` thật từ store; `scopeRevalidationStatus` do worker trả; chặn khi rỗng/không tồn tại.

---

## 5. P1 — ROBUSTNESS, BẢO MẬT, HIỆU NĂNG

### 5.1. Toàn vẹn dữ liệu & tài nguyên

| # | Vấn đề | Bằng chứng |
|---|---|---|
| P1-01 | Job bị đánh `SUCCEEDED` khi commit **một** publication, dù còn artifact anh em đang PREPARED — **ĐÃ SỬA 2026-11-11** (`expected_publication_count`, migration ALTER TABLE, `jobIsFullyPublishedInternal`, `openPublicationJob`) | test `tests/test_p1_job_completion.swift` |
| P1-02 | Hash/ffprobe/ffmpeg chạy **bên trong** `BEGIN IMMEDIATE` (busy_timeout 3000 ms) — **ĐÃ SỬA một phần 2026-11-11**: nhánh S22 đo và băm artifact trên connection read-only trước transaction (`G5S22Guard.measureFile/readPublishedArtifact`, `verifyFinalBindings(fileReader:)`); **G4/S21 và transaction của `commitPublication` vẫn còn băm trong transaction** | `G4S21Guard.swift:283` từ `G4ProjectStore.swift:231`; `ProjectStore.swift:2118` | ĐÃ SỬA MỘT PHẦN 2026-11-11: S22 đã đo hash/đọc plan ngoài transaction; G4/S21 và `commitPublication` vẫn băm trong `BEGIN IMMEDIATE`.
| P1-03 | `ResourceGovernor` brick vĩnh viễn — **ĐÃ SỬA 2026-11-11**: reclaim khi PID đã chết (`kill(pid,0)`) **và** heartbeat quá hạn, reap PID tái sử dụng; test S07.T4 | `ResourceGovernor.swift` |
| P1-04 | Cấp attempt trước khi xin lease — **ĐÃ SỬA 2026-11-11**: reserve lease → `allocateAttempt` → `bind`; lease bị từ chối trả `attempt == nil`, attempt cũ không bị revoke; test S07.T5 | `ResourceGovernor.swift` |
| P1-05 | Backup không atomic — **ĐÃ SỬA 2026-11-11**: closure pins/publications đọc từ chính snapshot (`SnapshotClosure.read`, mở `immutable=1`); thiếu blob pinned ⇒ backup fail | test `tests/test_p1_backup_restore.swift` |
| P1-06 | Restore không rewrite `canonical_path` — **ĐÃ SỬA 2026-11-11**: `rewriteCanonicalPaths` re-point mọi publication COMMITTED sang blob đã restore; test xoá thư mục gốc trước khi kiểm | test `tests/test_p1_backup_restore.swift` |
| P1-07 | `restoredClaimsCount` bằng số approval — **ĐÃ SỬA 2026-11-11**: đếm claim thật (`countClaims`) | test `tests/test_p1_backup_restore.swift` |
| P1-08 | Không có đường job→FAILED khi worker chết | grep `FAILED` chỉ ở CHECK + `ProjectStore.swift:1612` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-09 | `listCoverageRecords` bịa frame id `Array(0..<count)` | `ProjectStore.swift:2319` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-10 | `user_version` không bao giờ set ⇒ cổng schema version vô hiệu | `ProjectStore.swift:2108` chỉ gọi trong `applyMigration` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-11 | Native render không đi qua governor (trong khi Resolve render thì có) | `G4ConsoleView.swift:412-429` vs `:521` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy). `ResourceGovernor.withHeavyLease` (P1-11) lấy lease quanh render native; G4 `heavyMediaConform`, G5 `resolveRender`.

### 5.2. Bảo mật / tin cậy bằng chứng

| # | Vấn đề | Bằng chứng |
|---|---|---|
| P1-12 | `models_root_dir` từ RPC + `deep=False` ⇒ tự viết manifest khớp size là "verified" | `main_g2.py:414`, `model_installation.py:41-64` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-13 | `label_source` là chuỗi tự khai ⇒ gọi `label_source="human_labeled_holdout"` được `ELIGIBLE_PASS` | `g2_benchmark_runner.py:286,467` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy). Bỏ tham số `label_source`; eligibility chỉ khi `label_provenance` là signed manifest hợp lệ (human + field_footage).
| P1-14 | `g2_gate_decision: "PASS"` vẫn được phát từ fixture; `real_video_corpus_verified` hardcode `False` | `g2_benchmark_runner.py:534,1035-1037` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-15 | `staging_root`/`allow_overwrite` do caller chọn ở `g4/g5.render.native` | `native_render.py:770-773,813-820` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy). `staging_root` và `allow_overwrite` bị từ chối trước mọi kiểm tra khác (`STAGING_ROOT_FORBIDDEN`/`OVERWRITE_FORBIDDEN`).
| P1-16 | `g5.preferences.manage` ghi file tuỳ ý qua `profile_path` | `g5_capabilities.py:327,341,373` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-17 | `AIVIDEO_G5_SIMULATE_FREE_BYTES` là hook test lọt production | `g5_final.py:66-77` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-18 | Release manifest chỉ tự băm, không ký (field corpus thì có Ed25519 pin đúng) | `g5_release_audit.py:399-441` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-19 | E0/E1 `CERTIFIED` chỉ cần manifest ký; `runs` do caller truyền | `g5_release_audit.py:243-247` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-20 | `AIVIDEO_CONTRACTS_DIR` vẫn redirect được `local_model`/`runtime_paths` | `local_model.py:121`, `runtime_paths.py:11` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-21 | Corpus labels fail-open: label hỏng bị `continue` im lặng | `corpus_labels.py:33-40` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-22 | Ad-hoc signature được coi là "ready" khi không có `AIVIDEO_RELEASE_TEAM_ID` | `check_readiness.py:116-125` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-23 | `.drp` chỉ cần magic ZIP + size > 1024 | `G5S22Guard.swift:423-426` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy). `validate_resolve_drp_structure`: Project.db/.sqlite + timeline payload + `testzip()`; dùng cho cả G4 và G5.

### 5.3. Tính đúng & hiệu năng của pipeline

| # | Vấn đề | Bằng chứng |
|---|---|---|
| P1-24 | Mỗi cửa sổ decode **toàn bộ** file (không `-ss`/`-frames:v`); timeout 60 s không bắt ⇒ abort cả run | `pipeline_adapters.py:690-710` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-25 | Response > 1 MiB với video dài: 7200 cửa sổ ≈ 3,5 MB ⇒ `RESULT_TOO_LARGE`, mất kết quả | `full_frame_pipeline.py:334-364`, `main_g2.py:119-129` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy). Ngân sách inline 512 KiB (`paginate_raw_observations`) + RPC `g2.get_raw_observations` đọc checkpoint do worker sở hữu.
| P1-26 | Mẫu số coverage tự quy chiếu khi container thiếu `nb_frames` và `duration` | `media_indexer.py:822-827` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-27 | `audio_state="no_speech"` khi chưa hề chạy ASR | `full_frame_pipeline.py:750-757` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-28 | "Validate VLM output" chỉ validate dict tự dựng; U+FFFD bị xoá lặng | `pipeline_adapters.py:749,793-795` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-29 | `subject_track_id` bịa theo cửa sổ ⇒ logic merge chết | `pipeline_adapters.py:788` → `full_frame_pipeline.py:392-400` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-30 | Omission audit ghi `recovered_evidence` mà không kiểm gì | `full_frame_pipeline.py:903-931` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-31 | Crossfade/photo làm tổng frame khác plan ⇒ G4/G5 guard chặn dù worker báo PASS | `native_render.py:114-118,795` | **ĐÃ SỬA MỘT PHẦN 2026-11-11**: độ dài timeline bị chặn bởi `PLAN_FRAME_MISMATCH`; transition vẫn do plan khai (`transitions`), chưa đối chiếu với G4 preview đã duyệt. `PLAN_FRAME_MISMATCH` khi `expected_frames` khác `plan.total_frames` (transition/photo insert không được đổi độ dài).
| P1-32 | Photo insert không có publication; guard chỉ cần `illustrative_only` | `native_render.py:721-752`, `G5S22Guard.swift:384-388` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy). Photo insert bắt buộc `photo_sha256` khớp bytes **và** `photo_publication_id` (UUID S08); guard kiểm cả hai và đòi publication nằm trong chuỗi đã duyệt.
| P1-33 | Filtergraph thiếu escape `;`/newline; caption bị `%{}` expansion | `native_render.py:121-125,143-150` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-34 | Đọc cả MP4 4K vào RAM để băm | `native_render.py:589` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-35 | SEARCH-v1: `node_budget` không tính chi phí `has_future` ⇒ "hết budget" vẫn treo rất lâu | `g3_engine.py:1155-1175,1230-1249` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-36 | Thiếu model TTS tại `infer` trả `-32603 INTERNAL_ERROR` thay vì `blocked_tts_runtime_unavailable` | `g3_engine.py:589-597` vs `:631` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-37 | "Faithfulness" của LLM chỉ kiểm chữ số | `story_writer.py:163-176` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).

### 5.4. Test & tooling

| # | Vấn đề | Bằng chứng |
|---|---|---|
| P1-38 | Banner "N/N PASS" là tautology/literal ("11/11", "(3/3)") | `test_worker_ipc.swift:707`, `test_s06_project_store.swift:339` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-39 | 5 suite Swift không phát JSONL ⇒ vô hình trong ma trận | không có record cho g2_coverage_dto, g3_story_request, source_revision_identity, g5_native_provenance, s02_manual | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-40 | Suite BLOCKED vẫn exit 0 | `test_resolve_spike.swift:228-231` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-41 | S02 evidence tự cấp PASS được bằng cách ghi file | `package_review.py:350-361` + `test_s02_manual_verification.swift:205` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-42 | Schema artifact lệch code: `g5_final_mp4`, `g2_source_mapping` **không có** trong enum | `contracts/schemas/artifact_publication_schema.json` (xác minh bằng `jsonschema`: `valid=False`) | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-43 | CI chỉ `swiftc -frontend -parse` (syntax), không typecheck, không warnings-as-errors | `.github/workflows/ci.yml:106-108` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-44 | `run_tests.sh` xoá sạch `build/reports/*.jsonl` trước khi chạy | `tools/run_tests.sh:33` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-45 | Traceability: 151/279 record rơi vào `JOB-04` mặc định | `tools/run_python_tests.py:21-66` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).

### 5.5. UI (đã kiểm chứng dòng)

| # | Vấn đề | Bằng chứng |
|---|---|---|
| P1-46 | `script_revision_id` fallback `"rev-01"` khi chưa lưu revision | `G3ConsoleView.swift:692` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-47 | "Dừng" batch chỉ set cờ, RPC của video hiện tại vẫn chạy hết | `AppState.swift:1165-1193` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-48 | `restartWorker` set cờ **sau** `await terminate()` ⇒ double-spawn | `AppState.swift:383-392` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-49 | Thời lượng phụ đề = `wordCount × 0.45 s` (đoán), dùng như cue đã duyệt | `AppState.swift:206-214` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-50 | G5 báo ".drp đã niêm phong" khi nhánh native chỉ có receipt JSON | `G5ConsoleView.swift:337,682` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-51 | "Làm video mới" không reset state workflow ⇒ video 2 thừa hưởng "đã duyệt" | `G5ConsoleView.swift:376-378` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-52 | Inspector hiển thị thông số file trước khi probe xong (`\|\|` điều kiện) | `AIVideoApp.swift:739` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-53 | Cue mặc định "Nội dung đã duyệt" bị burn nếu bấm Stage ngay | `G4ConsoleView.swift:31-33`, `G5ConsoleView.swift:37-39` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).
| P1-54 | `mappingPublicationId` fallback sang `g3_*`/`g4_*` dù trường yêu cầu `g2_source_mapping` | `G5ConsoleView.swift:456-461` | **ĐÃ SỬA 2026-11-11** (kèm test hồi quy).

---

## 6. P2 — NỢ KỸ THUẬT

- **God files:** `ProjectStore.swift` 2463, `g3_engine.py` 1800, `AIVideoApp.swift` 1547, `AppState.swift` 1301, `G3ProjectStore.swift` 1114.
- **Bundle chứa 2 bản worker:** `build_macos_app.sh:80-85` copy cả `Workers/aivideo_workers` và `Workers/workers/src` (632 KB ×2) — "legacy path" không còn ai dùng.
- **Đọc trạng thái dùng `BEGIN IMMEDIATE`:** `G3ProjectStore`/`G4ProjectStore`/`G5ProjectStore` `current*` ⇒ UI poll chặn writer.
- **So UUID case-sensitive:** `G4ProjectStore.swift:121` so với `uuidString` (chữ hoa) trong khi `:237` dùng lowercase ⇒ receipt Python bị từ chối oan.
- **Trap `Double(parts[0])`** khi `avg_frame_rate` rỗng: `G4S21Guard.swift:272`, `G5S22Guard.swift:292`.
- **String escape sai** in ra literal: `G5S22Guard.swift:302,392`.
- **`except Exception:` 30 chỗ** (5 chỗ nuốt hoàn toàn) trong `workers/src` và `tools`.
- **State bằng so khớp chuỗi UI:** `hasPrefix("Đã lưu")`, `== "NATIVE_PREVIEW_VERIFIED"`, `== "ready_for_core_reverification_not_approved"`.
- **Dữ liệu mồi:** UUID dự án/workday cố định, prompt demo "…đèo Prenn buổi sáng sớm" điền sẵn, `g1SaveStatus = "Đã lưu (Rev …)"` ngay khi khởi tạo.
- **Accessibility:** font cố định 9–11 pt; 5 nút icon-only thiếu `accessibilityLabel`; `.controlSize(.mini)` cho nút "Dừng".
- **`review_workflow.py` là code mồ côi:** không có call site production, chỉ test gọi ⇒ không được tính là bằng chứng S14.
- **Hai nguồn schema:** `contracts/migrations/001_initial_g1_schema.sql` (10 bảng) chỉ dùng trong test; runtime tạo 23 bảng bằng Swift; `migrations/` rỗng.
- **Doc trùng:** `README.md` và `docs/README.md` khác nhau; `01-PRODUCT.md`/`02-ANALYSIS-AND-DATA.md` trùng byte ở gốc và `docs/`.
- **`REVIEW_SUMMARY.md`** ghi "189 PASS" trong khi record hiện tại 338.

---

## 7. BẢN ĐỒ CHỨC NĂNG: THẬT / NỬA VỜI / DANH NGHĨA

| Chức năng | Trạng thái | Ghi chú |
|---|---|---|
| Chỉ mục media ffprobe, PTS rational, quyết định màu | **Thật, tốt** | `media_indexer.py` 838 dòng |
| Qwen3-VL 4B offline inference (MLX) | **Thật** | PASS trong suite + probe 3 cửa sổ trên clip synthetic |
| Pipeline full-frame + sampling khai báo | **Chạy được** | Nhưng audit tautology (P0-02), checkpoint bịa được (P0-01) |
| Coverage ledger / omission audit | **Danh nghĩa phần omission** | omission audit luôn `recovered_evidence` |
| Semantic verifier (12 hàng quyết định) | **Thật nhưng tự chấm** | benchmark đo chính fixture |
| Benchmark S15 | **Không đo model** | `g2_gate_decision` từ fixture; corpus title card |
| Kịch bản G3 LLC (Qwen3-8B) | **Thật** | Nhưng bị chặn ở duyệt S19 (P0-08) |
| Kokoro-Vietnamese TTS | **Thật** | 4 test heavy NOT_RUN; test light PASS |
| ASR / Whisper | **Không có** | `audio_state` khai `no_speech` không bằng chứng |
| SEARCH-v1 beam cut | **Thật** | Ngân sách node sai đơn vị (P1-35) |
| Native renderer ffmpeg 1080p/4K + caption + SRT + receipt | **Thật** | 20 test render thật PASS |
| Receipt native → G4S21/G5S22 guard | **Thật nhưng giả được** | P0-03 |
| DaVinci Resolve timeline / .drp | **Tuỳ chọn, chưa nghiệm thu lại** | Resolve spike có evidence cũ |
| Publication 4 trạng thái + reconciler | **Thật** | Còn job→SUCCEEDED sớm (P1-01) |
| Backup/restore/migration | **Thật nhưng không atomic, restore lệch path** | P1-05/06 |
| Release E0/E1 + manifest | **Không thể đạt đúng cách** | corpus synthetic; manifest không ký |
| 4-bước UI + auto-wiring | **Thật** | 2 chỗ UI tự khai "verified" |

---

## 8. ĐƯỜNG ĐI THỰC TẾ (bản đồ đường đi)

### 8.1. Đường user 4 bước

```
BƯỚC 1 Tư liệu      ⌘O / ⇧⌘O → NSOpenPanel → Security-Scoped Bookmark → loadDirectory
                    → media.probe (ffprobe) → danh sách video/ảnh
                    → "Thông tin cho người viết kịch bản" → store.saveScriptBrief
                    → "Phân tích video này" | "Phân tích toàn bộ (N video)"
                    → RPC g2.analyze_source → ProjectStore: coverage/claims/review_items

BƯỚC 2 Kịch bản     chọn claim (confirmed) → "Tạo kịch bản…"  → g3.story.generate
                    sửa câu → "Lưu revision bất biến vào SQLite"
                    "Tạo WAV 48 kHz" → g3.voice.trial → ghi SHA-256 vào ô review
                    "Ghi nhận Speech Review vào SQLite" → g3_voice_reviews
                    "Tìm Cut hợp lệ (SEARCH-v1)" → g3.cut.search
                    "Stage Cut Plan để S08 Publish" → g3.cut.stage → publish
                    "Kiểm tra Manifest đề nghị duyệt" → g3.approval.propose
                    "Duyệt kịch bản trong SQLite (S19 Guard)" → store.approveG3Draft

BƯỚC 3 Preview      "Thêm Cue" → "Stage + S08 Publish Beat này" → g4.caption.stage + publish
                    "Dựng & render tự động" (native 1080p) → g4.render.native → receipt
                    "S08 Publish Preview MP4" → publishG4File
                    "S21: Phê duyệt Preview" (notes ≥ 12 ký tự) → store.approveG4Preview

BƯỚC 4 Final 4K     "Dựng & render 4K" (native) → g5.render.native_4k → receipt
                    [tuỳ chọn] "Phân nhánh DRP" → g5.handoff.fork
                    "S08 Publish Final 4K MP4" → publish
                    "S22: Phê duyệt Final 4K" → store.approveG5Final
                    Card hoàn tất: "Hiện MP4 4K trong Finder" / "Phát video 4K"
```

### 8.2. Mặt RPC (32 method)

| Nhóm | Method |
|---|---|
| Hệ thống / media / Resolve (legacy) | `initialize`, `system.ping`, `media.probe`, `media.index_and_proxy`, `ai.model_status`, `ai.local_infer_test`, `ai.local_model_infer`, `g2.analyze_source`, `resolve.status`, `resolve.spike_timeline` |
| G3 | `g3.story.generate`, `g3.story.edit`, `g3.voice.trial`, `g3.voice.phrases`, `g3.cut.search`, `g3.cut.stage`, `g3.approval.propose`, `g3.metrics.script_ready` |
| Render | `video.render.native`, `g4.render.native`, `g5.render.native_4k` |
| G4 | `g4.caption.stage`, `g4.timeline.build`, `g4.render.start`, `g4.render.inspect`, `g4.preview.technical_qc` |
| G5 | `g5.caption.stage_4k`, `g5.timeline.build_4k`, `g5.render.start_4k`, `g5.render.inspect_4k`, `g5.final.technical_qc`, `g5.handoff.fork`, `g5.capability.evaluate`, `g5.photo.match`, `g5.events.partial_order`, `g5.audit.final_vs_sources`, `g5.preferences.manage`, `g5.comedy.align_cues`, `g5.fault.run_suite`, `g5.eval.e0_e1_accounting`, `g5.release.manifest` |

> Xác nhận bằng đếm: `main_g2.py:553-564` khai báo 10 tên (`initialize` + 9 legacy), `main.py:82-115` `update()` thêm 22 method (gồm `initialize` override) ⇒ tập hợp cuối **32 tên duy nhất** (danh sách trên).

### 8.3. Dữ liệu — 21 bảng nghiệp vụ + `schema_migrations`

Canonical (16): `projects, workdays, source_media, source_revisions, claims, approvals, idempotency_journal, jobs, job_attempts, artifact_publications, artifact_pins, schema_migrations, coverage_records, review_items, raw_observations, script_briefs`
Gate (7): `g3_scripts, g3_selected, g3_voice_reviews, g3_approvals, g4_preview_approvals, g5_final_approvals, g5_manual_handoff_branches`
⇒ tổng **23 bảng** trong DB thật, nhưng `PRAGMA user_version = 0` (P1-10).

---

## 9. SO SÁNH VỚI BÁO CÁO 2026-11-10

| Lỗi cũ | Trạng thái hiện tại | Kiểm chứng |
|---|---|---|
| P0-1 luôn `POST_PROCESSOR_TRUNCATION` | **Triệu chứng hết, cơ chế phát hiện bị vô hiệu** → P0-02 mới | `full_frame_pipeline.py:661,682-690` |
| P0-2 payload rỗng ⇒ observation `observed` | **Đã sửa** (raise `INVALID_VISUAL_PAYLOAD`) — nhưng mở lại qua checkpoint (P0-01) | `:654-658,669-675` |
| P0-3 backdoor `_inspector_fn` | **Đã chặn** — thay bằng `checkpoint_dir` + `models_root_dir` | `main_g2.py:348-352,414,470` |
| P0-4 coverage tự quy chiếu | **Đã sửa khi có metadata**; fallback vẫn tự quy chiếu (P1-26) | `media_indexer.py:808-838` |
| P0-5 benchmark synthetic | **Sửa nhãn, chưa sửa scoring** (P1-13/14) | `g2_benchmark_runner.py:467,1035-1037` |
| P0-6 4 writer SQLite | **Đã sửa thật** (1 connection) | `grep sqlite3_open` = `ProjectStore.swift:488` (canonical) + `:2044` (đích backup) |
| P0-7 PEM không tồn tại, key không pin | **Đã sửa** (PEM tồn tại, fingerprint pin `9c7edbdd…`, `key_id`) | `g5_release_audit.py:41,206-220` |
| P1-1 commitPublication không bind | **Đã sửa** (bind + re-hash + `changes==1`) | `ProjectStore.swift:1767-1787` |
| P1-3 reconciler 1 là đủ | **Đã sửa** (`committed == total`) | `ProjectStore.swift:2008-2021` |
| P1-19 S02 tự ghi PASS | **Đã sửa** (NOT_RUN khi không bật `AIVIDEO_RUN_UI_TESTS`) — nhưng evidence vẫn forge được khi tool đọc file (P1-41) | `test_s02_manual_verification.swift:103-117` |

---

## 10. LỘ TRÌNH SỬA (đề xuất, theo thứ tự)

**Vòng 0 — Siết "không bịa" (2–3 ngày, không tính năng mới)**
1. P0-01 (bỏ `checkpoint_dir` + ký checkpoint + từ chối resume không có inspector).
2. P0-02 (audit nhận `win.intended_frame_ids`, tách `window_coverage`).
3. P0-05 (package_review: DONE ⇔ đủ case PASS; `sys.exit(1)`).
4. P0-06 (đổi tên fixture `smoke`, sửa `task_plan.md`/`progress.md`).
5. P0-07 + P0-09 (bỏ 2 hằng số "verified" và scope bịa khỏi UI).

**Vòng 1 — G3 chạy thông tới S19 (3–5 ngày)**
6. P0-08 chọn hướng (khuyến nghị (a): narration LLM sinh claim revision mới có evidence).
7. P1-35 (node budget), P1-36 (TTS infer bọc lỗi), P1-37 (faithfulness nêu rõ phạm vi).

**Vòng 2 — Toàn vẹn & tài nguyên (1 tuần)**
8. P1-01 (job SUCCEEDED theo sibling), P1-02 (hash/ffprobe ngoài transaction), P1-03/04 (lease TTL + đảo thứ tự), P1-05/06 (backup atomic + rewrite path).
9. P1-11 (native render qua governor).

**Vòng 3 — Bằng chứng phát hành (1 tuần)**
10. P0-03 (receipt ràng buộc plan/publication), P0-04 (fault suite thật hoặc `SELF_TEST_ONLY`), P1-18 (ký release manifest), P1-12/13 (bỏ tự khai model/nhãn).
11. P1-38..45 (banner thật, JSONL cho mọi suite, exit code BLOCKED, schema khớp, CI typecheck).

**Vòng 4 — Hiệu năng & UX**
12. P1-24 (`-ss` seek), P1-25 (phân trang observation), P1-31/32 (transition/photo vào plan), P1-46..54.

**Trạng thái 2026-11-11 (sau khi vá):** cả 6 vòng ở trên đã thực hiện. 9/9 P0 và 54/54 P1
đã có bản vá + test hồi quy, trừ hai hạn chế còn mở được ghi rõ: **P1-02** chỉ sửa nhánh S22
(G4/S21 và `commitPublication` vẫn băm trong transaction) và một phần **P1-31** (độ dài timeline
nay bị chặn, nhưng transition vẫn do caller khai như `transitions` của plan). Bằng chứng chạy:
`tools/run_python_tests.py` 395 PASS/0 FAIL (heavy: 395 PASS, 0 skip) và `./tools/run_tests.sh`
exit 0 với 23 khối.

**Định nghĩa "xong" nên đổi:** *"xong" = một video 30–60 s đi từ thư mục nguồn tới MP4 2160×3840 mở được, mọi con số trên UI đều truy được về một dòng DB/bằng chứng, giết app giữa chừng vẫn resume được, và `git push` bị chặn nếu bất kỳ case nào không PASS.*

---

## 11. PHỤ LỤC — TÁI LẬP BẰNG CHỨNG

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo

# 1. Python suite (kỳ vọng: 279 test, 0 FAIL, 4 NOT_RUN, exit 0)
workers/.venv/bin/python3 tools/run_python_tests.py

# 2. Preflight (kỳ vọng: NO-GO, blocker signed field corpus)
workers/.venv/bin/python3 tools/check_readiness.py; echo "exit=$?"

# 3. Build app (kỳ vọng: exit 0)
./tools/build_macos_app.sh

# 4. Corpus thật là title card 1,5 s
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,avg_frame_rate,nb_frames,duration \
  -of default=nw=1 fixtures/corpus/trip-holdout-01-dalat.mp4

# 5. Probe checkpoint do caller chọn (P0-01) — ghi vào /tmp/g2probe
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"g2.analyze_source","params":{"file_path":"/tmp/g2probe/probe.mp4","checkpoint_dir":"/tmp/g2probe"}}' \
 | PYTHONPATH=workers/src workers/.venv/bin/python3 -m aivideo_workers.main_g2

# 6. Schema artifact lệch code (P1-42) — kỳ vọng in False
python3 -c "import json;from jsonschema import Draft202012Validator as V;s=json.load(open('contracts/schemas/artifact_publication_schema.json'));print(not list(V(s).iter_errors({'artifact_type':'g5_final_mp4'})))"

# 7. Swift suite dùng SDK cụ thể (xcrun trả MacOSX27 không tương thích)
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -target arm64-apple-macosx14.0 \
  -swift-version 6 -parse-as-library \
  packages/AIVideoCore/Sources/Models/DomainModels.swift tests/test_g2_coverage_dto.swift \
  -o /tmp/aivideo_g2_dto_test && /tmp/aivideo_g2_dto_test
```
