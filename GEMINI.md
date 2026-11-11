# AIVideo — Hướng dẫn kỹ thuật & quy tắc cho agent

Dự án: **AIVideo v3.1** — trợ lý phân tích và dựng video POV tiếng Việt trên macOS.
Kiến trúc: **SwiftUI (native)** + **Swift core (`ProjectStore`, SQLite WAL, writer duy nhất)** +
**Python worker (stdio JSON-RPC 2.0, 42 method)** + **renderer ffmpeg native** (mặc định;
DaVinci Resolve Studio là tuỳ chọn cho timeline quản lý / bàn giao `.drp`).
Mục tiêu phần cứng: **Apple Silicon M1 Pro, 16 GB RAM hợp nhất**.

Trạng thái thực tế: xem [`README.md`](README.md) và
[`docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md`](docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).

---

## 1. Bất biến (có test canh — đừng vi phạm)

1. **Suy luận 100% local.** Không gọi API AI đám mây, không fallback cloud. Model lấy từ registry
   có pin; `model_installation.inspect_model_installation(deep=True)` phải trả `verified`.
2. **Swift core là writer duy nhất của SQLite.**
   - Chỉ actor `ProjectStore` (và extension G3/G4/G5 của nó) được ghi.
   - Python/gate store chỉ đọc, qua `SQLITE_OPEN_READONLY`; đường đọc dùng transaction
     `BEGIN DEFERRED` (`withCanonicalRead`), đường ghi dùng `BEGIN IMMEDIATE`.
   - `tests/test_single_writer_invariants.py` chặn mọi write handle ngoài `ProjectStore`.
3. **Một nguồn schema.** Swift tạo 23 bảng + `PRAGMA user_version = 2`; cột thêm về sau đi qua
   `ProjectStore.migrateAdditiveColumns`. File SQL trong `contracts/migrations/fixtures/` chỉ là
   fixture test (xem `contracts/migrations/README.md`).
4. **Bằng chứng trước.** Mỗi claim/cut/approval gắn `sha256` + timecode + publication id.
   `Unknown` là giá trị hợp lệ; không suy diễn khi thiếu tư liệu.
5. **Một lease cho việc nặng.** VLM inference, TTS batch, render 4K đều qua
   `ResourceGovernor` (`withHeavyLease` / `startHeavyAttempt`). Không chạy song song hai việc nặng.
6. **Chuẩn video.** Preview 1080×1920, final 2160×3840, **24/1 fps**, Rec.709, audio Việt 1×.
   Caption burn-in từ đúng text đã duyệt; photo insert là `illustrative_only` và phải có
   publication S08.
7. **Bundle chỉ một worker.** `Resources/Workers/aivideo_workers`; script build assert đúng 1
   `main.py`.

## 2. Quy tắc kỹ thuật bắt buộc

### 2.1. Không nhận "đường dẫn/định danh do người gọi chọn" từ RPC

Các tham số sau bị **từ chối** (không phải tuỳ chọn): `checkpoint_dir`, `models_root_dir`
(+ env `AIVIDEO_MODELS_ROOT`), `registry_path`, `app_binary_path`, `staging_root`,
`allow_overwrite`, `inspector_factory`. Root/model/contract do app cấp qua env:
`AIVIDEO_APP_SUPPORT`, `AIVIDEO_RENDER_ROOT`, `AIVIDEO_G3_STAGING_ROOT`,
`AIVIDEO_G4_WORK_ROOT`, `AIVIDEO_G5_WORK_ROOT`. `AIVIDEO_CONTRACTS_DIR` bị từ chối — contract
resolve theo vị trí package/bundle.

### 2.2. Không tự khai trạng thái

- Model: chỉ `verified` khi manifest khai đúng **hash trọng số đã pin**, không chỉ khớp size.
- Voice/cut: `voice_review_status` chỉ là `verified` sau khi người dùng nghe WAV; nếu chưa, worker
  trả `unverified` và kết quả cut phải tách `verified` / `unverified`.
- Nhãn corpus: `acceptance_eligible` chỉ khi có **signed manifest** (human + field_footage).
- Release manifest: phải ký Ed25519 (`sign_release_manifest`); `manifest_sha256` là checksum,
  **không** phải chữ ký.
- Ad-hoc signature là blocker của preflight (chỉ bỏ qua bằng `--allow-adhoc`).

### 2.3. Không băm/ffprobe trong transaction ghi

Đo bằng chứng (hash artifact, đọc JSON, ffprobe) phải xong **trước** `BEGIN IMMEDIATE`; trong
transaction chỉ so sánh row và INSERT. Mẫu đúng: `G5S22Guard.measureFile` /
`readPublishedArtifact` → `withTransaction` chỉ kiểm tra. (P1-02 còn 2 chỗ: xem
[`docs/PROPOSED_REMAINING_FIXES.md`](docs/PROPOSED_REMAINING_FIXES.md).)

### 2.4. Không nuốt ngoại lệ

`except Exception` phải gọi `aivideo_workers.diagnostics.note_suppressed(context, exc)` hoặc
re-raise/ghi log. `tests/test_p2_debt.py` chặn handler im lặng.

### 2.5. Nguồn build

`tools/build_macos_app.sh` và `tools/run_tests.sh` **glob** toàn bộ `packages/AIVideoCore/Sources`
+ `apps/macos/Sources`. Không quay lại liệt kê tay: danh sách tay từng làm mọi suite Swift fail
trong khi app vẫn build.

### 2.6. SDK

Luôn `-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`. `xcrun --show-sdk-path` trả
MacOSX27 và không build được với swiftc 6.3.3.

## 3. File trạng thái (bắt buộc cập nhật)

- `task_plan.md` — lộ trình, gate nào còn mở và **vì sao**.
- `findings.md` — phát hiện kỹ thuật, giới hạn đo được.
- `progress.md` — nhật ký + bằng chứng chạy thật (số liệu, không phải lời kể).

Quy tắc: cập nhật ngay sau mỗi thay đổi lớn; không tuyên bố hoàn thành khi chưa có output lệnh
chứng minh.

## 4. Lệnh thường dùng

```bash
# Python (428 case; thêm 3 cờ dưới để chạy 4 case model thật)
workers/.venv/bin/python3 tools/run_python_tests.py
AIVIDEO_RUN_HEAVY_G2=1 AIVIDEO_RUN_HEAVY_STORY=1 AIVIDEO_RUN_HEAVY_TTS=1 \
  workers/.venv/bin/python3 tools/run_python_tests.py

# Ma trận đầy đủ (build + codesign + 17 suite Swift + Python): 23 khối
./tools/run_tests.sh

# Build app
./tools/build_macos_app.sh            # thêm --install để cài vào /Applications

# Typecheck chặt
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 -swift-version 6 \
  -parse-as-library -typecheck -warnings-as-errors \
  $(find packages/AIVideoCore/Sources -name '*.swift')

# Preflight (NO-GO là đúng khi thiếu field corpus)
workers/.venv/bin/python3 tools/check_readiness.py; echo "exit=$?"
```

## 5. UI (Calm Editor)

- Sidebar 4 bước + nhóm "Nâng cao & Chẩn đoán"; Canvas preview lớn; Inspector phải.
- Light/Dark bằng semantic colors; Teal `#0F766E` / `#5EEAD4`; monospaced digits cho timecode.
- Chữ tối thiểu **11 pt**; nút icon-only phải có `accessibilityLabel`; không dùng
  `.controlSize(.mini)` cho hành động (đặc biệt là nút "Dừng").
- Màu trạng thái đọc từ `PersistenceState`, **không** so khớp tiền tố chuỗi tiếng Việt.
- Trạng thái "đã lưu" chỉ khi đã có revision thật; không seed dữ liệu demo.

## 6. Bẫy đã gặp (đừng lặp lại)

1. **APFS không phân biệt hoa/thường** — `rm -rf Resources/workers` xoá luôn `Resources/Workers`.
2. **`git stash` trên file untracked** từng làm mất bản sửa; muốn chứng minh "đỏ trước fix" thì
   copy sang `/tmp`.
3. **Plan hash là thứ approval pin** — thêm khoá vào plan dict làm mọi approval invalid.
4. **`fixtures/smoke` không phải field corpus** — đừng trích nó làm bằng chứng chất lượng.
5. **Không dùng `sqlite3` ghi** khi kiểm thử; chỉ `-readonly`.

## 7. Skill của dự án

`.agents/skills/aivideo-workflow/SKILL.md` (quy trình S00–S26) và
`.agents/skills/aivideo-ui-designer/SKILL.md` (HIG/SwiftUI). Skill mới đặt tại
`.agents/skills/<name>/SKILL.md` với frontmatter `name`, `description`.
