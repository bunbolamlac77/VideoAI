# BẢNG KIỂM TRA VÀ NGHIỆM THU AIVideo v3.1 (macOS, Apple M1 Pro 16GB)

Mọi ô bắt đầu để trống; chỉ chủ dự án hoặc AI local có logs kiểm chứng mới đánh dấu. **Không đổi NOT_RUN thành PASS vì đã xuất hiện “DONE” trong PROGRESS_TRACKER.**

## Trước khi làm

- [ ] Đang trên nhánh mới, không có source modification mất kiểm soát.
- [ ] Đã lưu backup project, SQLite canonical theo đúng SQLite backup API, `.drp`, model nếu có.
- [ ] Đã kiểm chính xác commit SHA local với ZIP audit và `origin/main`; nếu khác, merge có review.
- [ ] Đã chạy `git apply --check` trước khi áp patch.

## G0 / setup / native Mac

```bash
uname -m
sw_vers
xcodebuild -version
xcrun --sdk macosx --show-sdk-path
swiftc -version
python3 --version
ffmpeg -version | head -n 1
ffprobe -version | head -n 1
```

- [ ] macOS arm64; Xcode SDK đúng.
- [ ] Python worker thực được app chọn phải là 3.12.x, dependency từ `uv.lock` đã sync `--frozen`.
- [ ] `python3 -m compileall -q workers/src tools tests`: exit 0.
- [ ] `bash -n tools/build_macos_app.sh`: exit 0.
- [ ] `bash tools/build_macos_app.sh`: tạo `.app` thật, Swift 6 build/signed thành công.
- [ ] `codesign --verify --deep --strict apps/macos/build/AIVideo.app`: exit 0 (chỉ local build verification).
- [ ] Finder/Spotlight launch, quyền truy cập thư mục/video, đường dẫn có dấu tiếng Việt/spaces, bookmark sau app restart PASS.
- [ ] Worker JSON-RPC hello/ping/real media probe, no UI hang on worker restart/exit.
- [ ] Cài `--install` vào Applications trên bản thử có backup và kiểm `ditto` fail không xóa app cũ.

## G1 / data & crash recovery

- [ ] `python3 tools/run_python_tests.py`: PASS; 0 failure, 0 error; ghi skipped thực.
- [ ] `python3 -m unittest discover -s tools/autobridge/tests -p 'test_*.py' -v`: PASS.
- [ ] `swiftc -frontend -parse apps/macos/Sources/*.swift packages/AIVideoCore/Sources/*/*.swift tests/*.swift`: PASS.
- [ ] `bash tools/run_tests.sh`: PASS **trên Mac**, đủ Swift tests/Resolve tùy runner.
- [ ] SQLite WAL single-writer; revisions; rollback disk-full, process death, stale fencing, duplicate attempt.
- [ ] APFS source snapshots SHA-256, symlink outside root denied, restore sang thư mục mới.

## G2 / real AI & media

```bash
# --plan/--verify không được tạo model hay tải từ mạng.
python3 tools/setup_models.py --plan
python3 tools/setup_s11_model.py --verify
# --install CHỈ sau khi backup và xác nhận mô hình cần tải; cần internet:
# python3 tools/setup_s11_model.py --install
# Nếu có model cũ thiếu manifest, không ép --force trước khi backup.
```

- [ ] Qwen3-VL 4B pinned revision và SHA-256 đúng upstream, manifest toàn bộ artifact PASS.
- [ ] Whisper/ASR, VieNeu TTS, model các vai trò khác đã có runtime thật hoặc khả năng disabled minh bạch.
- [ ] Thử mạng offline sau setup; không cloud fallback.
- [ ] Media VFR 23.976/29.97/60, 4K HEVC, 90° rotation, Rec.709, HDR/HLG, clips corrupt; evidence frame mapping PASS.
- [ ] Claim provenance không bị suy diễn `unknown -> supported`, chống falsified direct facts.
- [ ] 5 video held-out thật có input hash, nhãn và evidence; benchmark được đo lại, không chép cũ.

## G3 / storyboard / TTS / approvals

- [ ] Outline có source claim per beat; invalid/unknown không được tự nâng quyền.
- [ ] WAV thật PCM16 48k, duration/clipping/audio SHA verified; human listening review.
- [ ] SEARCH-v1/EXACT-v1 đúng ràng buộc clip frame, giới hạn shot, behavior infeasible/pruned.
- [ ] Approval được gắn immutable snapshot; stale revision rejected.

## G4 / Resolve preview

- [ ] DaVinci Resolve **Studio** thực chạy trên máy đích, script API compatible.
- [ ] Tạo managed timeline 1080x1920 24fps; không đụng các timeline ngoài phạm vi.
- [ ] Operation journal `INTENT` trước side-effect, readback, idempotency, no blind retry.
- [ ] Render preview, `ffprobe` đúng stream/fps/size/duration/audio, full human QC caption/voice/safe crop.
- [ ] SIGKILL Resolve/worker lúc render/xuất không phá file `.drp` cũ.

## G5 / final / release

- [ ] Output final 2160x3840 @24fps, audio/caption QC, source video hash trace.
- [ ] 5 held-out trips signed manifests bằng private key riêng của QA; validate input `sha256`; cấm tự ký dùng key có trong repo.
- [ ] E0/E1 metrics kiểm tra trên video thực với logs, phiên bản model, machine ID dạng không nhạy cảm, date/time.
- [ ] Worker backpressure/stress 100MB stdout + stderr, 10k responses, peak RSS, swap usage acceptable M1 Pro 16GB.
- [ ] `python3 tools/check_readiness.py` trả 0 `GO` **sau khi** tất cả các blocker thực đã được giải quyết.
- [ ] GitHub Actions trên branch/PR có logs PASS, không fake.
- [ ] Nếu phân phối bên ngoài: Developer ID signing + Apple notarization + Gatekeeper assess; ad-hoc build không được gọi public distribution ready.
- [ ] Rollback thử được từ bản `.app`, data snapshot và model cũ.

## Mẫu record bắt buộc mỗi lần chạy

```json
{
  "testcase_id": "G2_S11_MODEL_VERIFY_001",
  "platform": "macOS arm64 / Apple M1 Pro 16GB (điền phiên bản thật)",
  "commit": "ĐIỀN_GIT_SHA_THẬT",
  "command": "python3 tools/setup_s11_model.py --verify",
  "exit_code": "ĐIỀN_SỐ_THẬT",
  "status": "PASS|FAIL|NOT_RUN|SKIPPED",
  "timestamp_utc": "ĐIỀN_TIMESTAMP_THẬT",
  "evidence_files": ["ĐƯỜNG_DẪN_LOG", "REPORT_JSON"],
  "observed": "Mô tả điều thực sự quan sát được",
  "blockers": ["Không được xóa nếu chưa giải quyết"]
}
```

## Điều kiện GO

**Không có lỗi P0/P1 còn mở** làm ảnh hưởng dữ liệu, sự nhất quán nghiệp vụ, sandbox/native startup, model/offline hoặc final export; G0-G5 có chứng cứ trên macOS+DaVinci+real weights+real held-out corpus; preflight exit=0; chủ dự án xác nhận video. Nếu không đủ, giữ **NO-GO**, ngay cả khi 152 Python test đều PASS.
