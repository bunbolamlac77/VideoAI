# LỆNH TRIỂN KHAI GỬI AI LOCAL — LEAD ARCHITECT / STAFF ENGINEER / RELEASE ENGINEER

> ⚠️ **ẢNH CHỤP LỊCH SỬ — không phải trạng thái hiện tại.**
> Giữ nguyên nội dung để tra cứu quá trình; nguồn đúng hiện tại là
> [`README.md`](../../README.md) và
> [`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](../../docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).
> Sau ngày ghi trong tài liệu, dự án đã qua kiểm toán 2026-11-11 (9 P0 + 54 P1 + 14 nhóm P2) và
> một số chi tiết đã đổi: `fixtures/corpus` → `fixtures/smoke`, schema do Swift sở hữu,
> TTS là Kokoro-Vietnamese, Whisper chưa nối, gate G2/G5 vẫn IN_REVIEW.

> Hãy cung cấp **NGUYÊN TÀI LIỆU NÀY** và các thư mục `SOURCE_CODE/`, `EVIDENCE/` cùng `CHANGESET.patch` cho AI local. Đây là yêu cầu thực hiện **mã và test**, không phải yêu cầu viết lại bản kế hoạch suông.

## Hệ thống bạn đang kiểm tra

Tên: AIVideo v3.1 — app native macOS (SwiftUI + Swift 6 Core + SQLite WAL) chạy trên Apple M1 Pro 16GB; Python 3.12 worker giao tiếp JSON-RPC 2.0 qua stdio; MLX local Qwen3-VL/ASR/TTS, FFmpeg, DaVinci Resolve Studio. Lộ trình và bất biến: `PROGRESS_TRACKER.md`, `AGENTS.md`, `GEMINI.md`, `01-PRODUCT.md` tới `11-CODING-WORKFLOW-AND-CHECKLIST.md`. User cung cấp ZIP snapshot có sha256 `b2d379869a6a1f6b65dd2c556a8d6ccf7575b593690d2a807fede6f04c8fd34f`; comment ZIP tham chiếu commit `92762facc60fde5dd4cb8ab3749c64ffd9a4a54a`. Không được giả định comment khớp Git HEAD hoặc release.

### VAI TRÒ / TIÊU CHUẨN

Bạn là lập trình viên cực kỳ khắt khe, lead system/security architect, macOS engineer, performance engineer và release QA. Mọi thay đổi phải có: đường dẫn chính xác, lý do, code thực, deterministic unit/fault test, lệnh tái tạo, exit code, giới hạn và bằng chứng. Ưu tiên giữ hệ thống chạy ổn định hơn là thêm chức năng. Không dùng prompt-only hoặc giả vờ đã sửa.

### LUẬT BẤT BIẾN

1. Không tự xóa model đang chạy, project, originals, media, `.drp`, `.app` hoặc SQLite live. Backup & integrity check rồi mới thay thế. Không `git reset --hard`, `rm -rf ~/Library/Application Support/AIVideo`, `push --force`.
2. Swift Core giữ độc quyền ghi canonical database; Python không ghi trực tiếp SQLite canonical. Các state machine, claim provenance, `unknown`, approval revision/fencing, publication journaling và content-addressed source snapshots là giao thức ổn định.
3. Chỉ AI local/inference offline sau setup. Không cloud fallback, không mang file của người dùng ra ngoài. `--verify` tuyệt đối không network. Chỉ `--install` mới được phép download.
4. Không thay đổi/publish công khai/đổi quyền repo nếu chưa có đồng ý cụ thể. Từng thay đổi thực hiện trên branch riêng với khả năng rollback.
5. Mọi kết quả test phải có exit status thật. Skipped khác PASS; benchmark chỉ ghi số đo được. Cấm tự tạo chứng nhận E0/E1 giả, HMAC signature tự ký bằng key public hay gian lận corpus holdout.
6. Đối với đường dẫn Unicode/space/symlink/hardlink/security-scoped bookmark, chỉ xử lý sau khi xác minh canonical path, permission và ownership. Phòng chống path traversal.
7. Giữ tính idempotent của thao tác Resolve; các thao tác có side-effect cần operation journal và readback, không retry mù.

## PHA 0 — CỐ ĐỊNH ĐẦU VÀO, KHÔNG ĐỤNG DỮ LIỆU SỐNG

- Đọc `00_BAT_DAU_O_DAY.md`, `01_BAO_CAO_KIEM_TOAN.md`, `03_BANG_KIEM_NGHIEM_THU.md` rồi `SOURCE_CODE/AGENTS.md`, `SOURCE_CODE/GEMINI.md`, `SOURCE_CODE/PROGRESS_TRACKER.md`.
- Xác định repo root Mac của người dùng (mặc định có thể là `$HOME/APP_CaNhan/AIVideo`). In: `pwd`, `git status --short`, `git rev-parse HEAD`, `git remote -v`, Python/Swift/FFmpeg/Xcode/Resolve versions, architecture, free disk, RAM.
- Phân biệt rõ: ZIP nguồn người dùng, HEAD local, `origin/main` và source bản vá. Không kết luận chúng cùng commit khi chưa kiểm.
- Kiểm tra file thay đổi của user, chưa commit, secrets và `.gitignore`; tuyệt đối không commit các keys/token/model/video. Bật chế độ manual review trước thao tác nguy hiểm.
- Backup: source code; database qua SQLite backup API của app hoặc copy an toàn sau khi đóng app; model manifest; DaVinci `.drp` quan trọng; file cấu hình. Không copy WAL khi DB đang mở nếu không dùng SQLite backup API.
- Đầu ra: `audit/00_environment.json`, `audit/00_git_diff.txt`, `audit/00_backup_inventory.md`, snapshot ID/hash; không tự đoán nếu không đọc được.

**Tiêu chí PHA 0:** xác nhận nhánh an toàn; source và dữ liệu sống không bị thay đổi; có phương án khôi phục đã kiểm lại bằng checksum.

## PHA 1 — ÁP DỤNG BẢN VÁ ĐÃ KIỂM TOÁN

Bản vá đã thực hiện trên bản sao nguyên bản gồm:

| File | Nhiệm vụ thực hiện |
|---|---|
| `tools/setup_s11_model.py` | staging + advisory lock + model weight SHA-256 upstream, local installation manifest, rollback, offline verify, fail closed |
| `tools/setup_g0_model.py` | `--force` không xóa cũ trước khi tải; phục hồi khi publish lỗi; `--plan` không tạo thư mục; không theo symlink |
| `tools/build_macos_app.sh` | cài `.app` dùng staging, code signature verify trước swap, backup và phục hồi |
| `tools/check_readiness.py` | chỉ công nhận worker Python3.12, model pinned verification, Resolve/field corpus gate, timestamp UTC, báo NO-GO chính xác |
| `workers/src/aivideo_workers/main_g2.py` | JSON strict: duplicate key/NaN/Infinity/float overflow, không phát response JSON không hợp lệ |
| `.github/workflows/ci.yml` | chạy full Python + bridge + Swift contracts + syntax + evidence |
| `tools/run_python_tests.py` | map requirement cho regression mới |
| `tests/test_s11_install_and_release_preflight.py` | synthetic fixture, lỗi tải/rollback/tamper/Python gate/DaVinci gate |
| `tests/test_rpc_strict_json.py` | subprocess malformed JSON, nguyên tắc RPC fail closed |

**Cách áp dụng:** ưu tiên `git apply --check <đường-dẫn-đến>/CHANGESET.patch` trên nhánh riêng chỉ khi `HEAD` / nội dung các tệp gốc khớp. Nếu thất bại, đọc `SOURCE_CODE/<file>` và gộp thay đổi theo ý nghĩa. Không overwrite các sửa đổi mới, không bỏ test mới. Sau tích hợp, dùng `git diff --check` và `git status --short` xác nhận đúng file.

**Việc bắt buộc sau khi áp dụng:** chạy toàn bộ test Python và autobridge trong Python phù hợp; chạy shell syntax; parse/compile Swift trên Mac; chạy `--verify` không network; cố ý fail download để chắc dữ liệu cũ còn. AI phải tự viết thêm test cho `os.replace` G0 rollback, malformed manifest, đồng thời cân nhắc lỗi `finalize_installation()` đã ghi một phần registry. Không chỉ tin suite nhỏ sẵn có.

**Tiêu chí PHA 1:** zero regression, mọi P0 có failure injection và rollback proof; không xóa app/model dự án user; không vượt qua gate khi thiếu model.

## PHA 2 — KIỂM TRA TOÀN BỘ RUNTIME / BUILD TRÊN MACOS

1. Xác định chính xác Xcode full vs CLT, `xcrun --sdk macosx --show-sdk-path`, `xcodebuild -version`, `swiftc -version`, macOS target >=14 arm64, code signing identity. Không hardcode SDK v26.5 một cách mù quáng; lấy SDK hợp lệ từ `xcrun` và thử biên dịch.
2. Cài Python **3.12** riêng worker, theo `workers/pyproject.toml` (`>=3.12,<3.13`) và `workers/uv.lock`. Dùng `uv sync --python 3.12 --frozen` nếu uv hỗ trợ và lock hợp lệ. Dừng nếu Python3.13 hoặc native Metal/MLX sai architecture. Verify `python -c 'import sys; print(sys.version)'` trên interpreter thực mà `AIVideoApp.swift` chọn.
3. Build `bash tools/build_macos_app.sh` (không `--install` trước khi chứng minh build sạch). Đảm bảo app bundle chứa worker source, contracts, Info.plist hợp lệ, app icon, binary Mach-O arm64 và signed local. Cấm sửa Swift để “compiles” bằng cách vô hiệu hóa actor isolation, bypass gate hay xóa state machine.
4. Chạy app từ `open -a <đường dẫn AIVideo.app>` và Finder, **không phải chỉ `swiftc -parse`**. Test launch cold, UI re-appearance, multiple restart worker, app exit, worker crash, Force Quit. Check App Sandbox/security-scoped bookmarks, Unicode đường dẫn, spaces, paths rất dài, ổ ngoài/ngắt kết nối, permissions denied.
5. Xem `AIVideoApp.swift:resolveWorkerScriptPath`, `resolvePythonPath`, `workspaceRoots`, Info.plist stamped repo root. Chuyển thành chiến lược runtime rõ ràng cho bản bundle: Python 3.12 đã pin + packages MLX + resolve adapter có thể tìm được sau khi di chuyển `.app` khỏi repo. Đừng nhét model 3GB vào bundle khi chưa thiết kế update/storage; model trong Application Support phải tồn tại ngoài `.app`.
6. Phân biệt **local developer app** (ad-hoc code sign) với **public distributor** (Developer ID, notarization). `codesign --verify` không tương đương `spctl --assess`/notarization. Trạng thái production phải ghi chính xác mức phát hành.

**Tiêu chí PHA 2:** Finder launch hoạt động không Terminal, popup/permission rõ ràng, model runtime được tìm đúng, UI không treo khi worker chết, không zombie; cả build và binary actual startup evidence; di chuyển app không làm mất runtime không được báo thành PASS.

## PHA 3 — JSON-RPC / PROCESS LIFECYCLE / RAM BACKPRESSURE

Hạng mục then chốt cần làm tiếp vì bản vá này chưa đụng sâu vào Swift concurrency:

- Tập trung `packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift` vùng `AsyncStream.makeStream` stdout: hiện `.unbounded`. Phải triển khai cơ chế **không làm rơi chunk**, nhưng có giới hạn backlog/memory thực, ví dụ đọc theo pull với Task chuyên dụng hoặc reader pipe chặn/backpressure theo queue tiêu thụ; không dùng `.bufferingNewest(N)`/`.bufferingOldest(N)` nếu parser cần byte-perfect framing. Đảm bảo callback không chặn main actor và không gây deadlock trên kênh stderr.
- Parser frame trên Swift/Python: UTF-8 đa-byte chia chunk, CRLF/LF, duplicate keys, invalid id incl bool, null/error fields, nested JSON quá sâu, 1MiB±1 byte, notification không id, request ID reuse, out-of-order response, stdout text rác từ MLX/Resolve, stderr spam; bounded error handling.
- Worker lifecycle: race init/terminate/restart, actor-isolated session token, watchdog parent loss, 0.1–10 giây timeout tùy type, cancellation, graceful shutdown, SIGKILL fallback, reaping orphan children/process groups. Không kill PID mà không xác thực ownership/start time nếu có thể tái sử dụng PID.
- Stress test 10k responses, 100 MB stdout total, stderr 100MB, worker died during flush, app close during download/inference, memory pressure, M1 16 GB; đo peak resident memory và queue backlog. Chuyển mọi metric vào `build/reports/` với real timestamps.

**Tiêu chí PHA 3:** request/response byte-perfect, không tăng RAM vô hạn, không deadlock/zombie, cancel và recovery nhất quán, Swift `-swift-version 6` strict concurrency sạch.

## PHA 4 — DATA / PUBLISH / RESOLVE / MEDIA INTEGRITY

- Đọc `ProjectStore` Swift, `G3ProjectStore`, `G4ProjectStore`, `G5ProjectStore`, `ArtifactPublisher`, `G4FilePublisher`, `BackupRestoreService` và state transitions. Verify SQLite WAL single writer; idempotency journal, monotonic revision/fencing token, crash recovery, APFS atomic staging, `fsync` before DB COMMITTED, recovery after SIGKILL/disk full. Không sửa bằng cách tắt foreign keys/transaction.
- Resolve operation journal: thử SDK thật với Studio, project nằm trong temp sandbox, thay Resolve object/stale timeline, API returns false, timeouts, duplicate replay, append edit 1x, `ExportProject` throw midwrite, không mất `.drp` trước đó; nhận dạng timeline managed vs user timeline, không được xóa ảnh/video của người dùng.
- Media pipeline: HDR/HLG và Rec.709 SDR, VFR input timestamps -> 24 CFR, 48kHz audio, silent streams, 90-degree phone rotation, HEVC, broken clips, frame mapping audit. Kiểm tra video output 1080x1920 preview và 2160x3840 @24 final với `ffprobe` + visually inspected key frames. Giữ hash/provenance đến tận final.
- G3 script/voice: nguồn claim do user cung cấp giữ `origin=user`, không nâng thành direct evidence; output TTS phải kiểm duration/WAV PCM SHA clipping; approval phải buộc immutable revision, hỗ trợ `unknown` mà không lén hợp thức hóa.

**Tiêu chí PHA 4:** không làm hỏng dữ liệu, các fault injection có rollback/reconcile, tệp render thực đúng thông số, người xem xác nhận shot/voice/caption trên video thực.

## PHA 5 — MODEL / OFFLINE / PERFORMANCE M1 PRO 16 GB

- S11: đọc `tools/setup_s11_model.py`, model ID, commit revision, SHA-256 pinned. Trước install kiểm free space và backup; thử `--plan` (KHÔNG mutation), `--install` (network được phép), `--verify` offline. Model đã cài trước bản vá **sẽ thiếu `.aivideo-install-manifest.json`**; đừng tự ý chấp nhận hoặc sửa hand-crafted manifest như proof. Reinstall qua stage sau backup hoặc viết `--adopt-existing` chỉ sau khi xác thực upstream toàn bộ artifacts với provenance.
- G0: `tools/setup_g0_model.py` hiện có nguy cơ source lock mutation khi finalize; cần tách immutable lock và per-machine install metadata. Tạo test mock download fail, os.replace fail, disk full, symlink, Concurrent lock và restart after SIGKILL.
- Ràng buộc 16GB: ResourceGovernor global heavy lease 1, explicit model unload/teardown, memory thresholds, chunk size VLM 8/16/32 frames theo registry, pixel budget và output tokens. Không chạy đồng thời VLM+8B Story+large Whisper+TTS khi memory không đủ. Đo CPU/GPU RAM/VRAM metal (unified mem), 5 video + 1 long 4K clip; báo throughput, peak RSS, peak swap, UI responsiveness. Không tự ghi `60 tokens/s` nếu không đo thực ở máy này.
- Offline audit: sau khi download xong, block mạng test mode, cắt Wi-Fi và chạy workflow; không `snapshot_download`/cloud fallback trong đường code inference. Kết quả phải liên kết model id + revision + file hashes, bao gồm cơ chế khai báo `missing model -> NO-GO` chứ không dựng câu trả lời giả.

**Tiêu chí PHA 5:** mô hình thật load/infer trên Metal, hash được kiểm và mô tả, RAM không thrash, app và Resolve vẫn hoạt động, tách offline vs setup network rõ ràng.

## PHA 6 — E0/E1 FIELD QA & RELEASE DECISION

- Cung cấp 5 held-out trip thật và quyền sử dụng dữ liệu; tính SHA-256 từng nguồn, signed manifest với key riêng tư do chủ dự án quản lý; không đặt secret key trong repo. Đối chiếu E0/E1 thresholds/metrics ở `reports/progress/S25.md`/`S26.md` và spec `08-ACCURACY-FIRST.md`.
- Mỗi video phải có import → index → worker analysis (real) → claims review → script/voice → cut selection → Resolve preview → approval → final export. Lưu timestamps, app/commit/model revision, platform, RAM pressure, encoding config, input/output SHA, UI screenshots/progress; clip lỗi phải có repro/expected/actual.
- So benchmark trước/sau để đo chậm lại, memory leak, crash loops. Kiểm sự nhất quán PTS/subtitle/voice/source photo/shutter match. Disabled capability phải luôn disabled trừ khi có bài nghiệm thu riêng.
- Chạy `python3 tools/check_readiness.py`; report phải GO chỉ khi mọi gate đúng. Nếu NO-GO phải ghi blockers, không sửa source để ép GO hoặc đổi chữ ký.
- Sau đó kiểm CI trên GitHub Actions, Developer ID/notarization nếu thực sự phân phối ngoài máy mình, ký release tags, tạo rollback plan cho app/data/model phiên bản cũ.

**Tiêu chí PHA 6:** có E0/E1 signed corpus thật, report readiness GO có thể tái lập trên máy đích, người dùng đã kiểm chứng video. Nếu thiếu bất kỳ yêu cầu nào, ghi rõ **NO-GO**, tuyệt đối không ghi TASK_ALL_COMPLETED.

## HÌNH THỨC PHẢN HỒI CỦA AI LOCAL (BẮT BUỘC)

### Sau mỗi pha, phải trả:

1. `CURRENT_COMMIT` và branch; danh sách files thay đổi; mô tả bug có vị trí dòng.
2. `PATCHES` hoàn chỉnh theo path: cung cấp diff hoặc nội dung file đầy đủ, không chỉ hướng dẫn; mọi file chỉnh phải có code cụ thể.
3. `TESTS`: command, environment, expected output, actual output, exit code, PASS/FAIL/NOT_RUN/SKIPPED, logs đường dẫn.
4. `PERFORMANCE`: số thực đo hoặc `NOT_MEASURED`, không bịa.
5. `SECURITY`: câu trả lời liệu có đụng model, project data, private token, source files; hash before/after nếu có.
6. `OPEN_BLOCKERS`: P0/P1/P2 rõ root cause, reproduction, assignee, next action.
7. `ROLLBACK`: backup nào, cách khôi phục, test phục hồi.
8. `GATE_DECISION`: GO / NO-GO **theo bằng chứng**, không theo người thực hiện muốn đóng tiến độ.

### Tiêu chí chấp nhận của người kiểm toán

- [ ] App mở được từ Finder, import/preview/export video thật qua Resolve Studio.
- [ ] S11 và G0 không mất model cũ khi download/rename/finalize thất bại.
- [ ] `.app` cũ không mất khi `ditto` hoặc publish fail; restore tested trên Mac.
- [ ] Swift JSON-RPC đọc/ghi không deadlock, không unbounded memory growth, không stdout bẩn.
- [ ] Python 3.12 pinned runtime đúng với `workers/pyproject.toml`.
- [ ] SQLite WAL và backup/restore APFS thực minh chứng single-writer.
- [ ] Model/trip files có SHA256 và revision, chạy hoàn toàn local sau setup.
- [ ] End-to-end 5 trip/field QA có valid signed manifest thực.
- [ ] CI main branch PASS; Developer ID/notarization được làm nếu phát hành cho người khác.
- [ ] Chỉ chủ dự án quyết định merge/push/release.

**Kết thúc công việc chỉ được ghi `[DUNG_TOAN_BO_TIEN_TRINH]` khi tất cả gate đã GO trên máy thật**, không khi chỉ unit test PASS. Nếu chưa, hãy trả mã sửa và các blockers thực tế, tiếp tục sửa theo ưu tiên nhưng không tự thổi phồng tiến độ.
