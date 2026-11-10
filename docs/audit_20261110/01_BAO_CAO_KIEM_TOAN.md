# AIVideo — BÁO CÁO KIỂM TOÁN HẠ TẦNG, MÃ NGUỒN VÀ ĐỘ TIN CẬY

- Ngày: **2026-11-10** (UTC+07)
- Nguồn chính: ZIP người dùng cung cấp `AIVideo_handoff.zip`
- Repository tham chiếu: https://github.com/bunbolamlac77/VideoAI
- SHA-256 ZIP nguồn: `b2d379869a6a1f6b65dd2c556a8d6ccf7575b593690d2a807fede6f04c8fd34f`
- Archive comment khai báo commit: `92762facc60fde5dd4cb8ab3749c64ffd9a4a54a` (**metadata do ZIP khai báo, KHÔNG phải xác nhận GitHub HEAD**)
- Phạm vi: 198 file thường của bản chụp được trích xuất, Python worker, Swift macOS UI/Core, model installer, daemon/bridge, SQLite contracts, Resolve adapter, CI, unit/integration tests và tài liệu gate. 240 entry trong archive gốc có bao gồm entry thư mục.
- Nền tảng kiểm toán: Linux, Python 3.13.x, Swift compiler để parse/compile Swift không phụ thuộc Cocoa. Không có hệ điều hành macOS/Xcode/Resolve/Metal đúng mục tiêu.

## A. Kết luận ngắn

**Đánh giá kỹ thuật sơ bộ sau sửa: khoảng 72/100, có điều kiện, không phải chứng chỉ chất lượng. Trạng thái sẵn sàng phát hành: NO-GO.** Điểm phản ánh kiến trúc khá rõ ràng, nhiều bài test tốt và chiến lược provenance đáng ghi nhận, đồng thời bị trừ nặng vì chưa chạy được toàn bộ macOS/Resolve/model/video thật trong môi trường kiểm toán, một số đường cài đặt trước đó phá hủy dữ liệu cũ, và thiếu chứng cứ hiệu năng cuối đến cuối có thể xác thực độc lập.

Thang gợi ý: kiến trúc/tách lớp 80/100, kiểm thử tự động 80/100, an toàn cài đặt/khôi phục sau vá 75/100, khả năng phân phối/chứng minh production 45/100. Đây là **nhận định kỹ thuật**, không phải một phép đo thống kê. Không dùng số 72 để tuyên bố app chạy mượt.

Trong `PROGRESS_TRACKER.md`, G0–G4 được đánh dấu DONE; G5 IN_REVIEW. Trạng thái checklist và nhiều báo cáo S11/S15 đã công bố số benchmark; nhưng khi không có model/corpus/Resolve trên máy kiểm toán, các tuyên bố đó **chưa thể được tái thực hiện**. Vì vậy mọi cổng tác nghiệp sản xuất phải dựa trên bằng chứng mới chạy trên máy đích, không dựa vào checkbox.

## B. Bằng chứng kỹ thuật đã chạy

| Hạng mục | Trạng thái | Bằng chứng |
|---|---|---|
| Python baseline nguyên bản | 135 tests / 0 failed / 3 skipped | `EVIDENCE/baseline_python.log` |
| Python bản vá | **152 tests / 0 failed / 3 skipped** | `EVIDENCE/final_python_full.log`; `EVIDENCE/python_test_summary.json` |
| Autobridge | **21 tests / 0 failed** | `EVIDENCE/final_autobridge2.log` |
| Python syntax | PASS | `python3 -m compileall -q workers/src tools tests` |
| Swift syntax (toàn bộ sources và tests) | PASS | `swiftc -frontend -parse ...` |
| Swift G1 contracts | **5/5 PASS** (Linux Swift) | `EVIDENCE/final_swift_g1.log` |
| Shell script syntax | PASS | `bash -n tools/build_macos_app.sh` |
| Release preflight | **NO-GO** (exit code 2) | `EVIDENCE/final_preflight.log` |
| Build `.app` Mac + test Finder | NOT_RUN | Không có macOS/Xcode/signing trong môi trường này |
| Resolve Studio thật + xuất video | NOT_RUN | Không có Resolve Studio và media dự án trong container |
| Local Qwen/Whisper/TTS + MLX Metal | NOT_RUN | Model chưa có trong container |
| E0/E1 video held-out thực tế | NOT_RUN | Chưa có corpus kèm quyền truy cập trong bản chụp |

Các bài skipped không tính là PASS. Không được tự làm giả logs hay điền PASS cho những mục NOT_RUN. `python3 tools/check_readiness.py` luôn ghi report `build/reports/readiness_report.json` và trả 2 khi NO-GO.

## C. Các lỗi được sửa (đã nằm trong SOURCE_CODE và CHANGESET.patch)

### P0-01 — S11 xóa model cũ trước khi download

**Địa điểm nguyên bản:** `tools/setup_s11_model.py`, các dòng khoảng 119–143. Khi `--force`, script `shutil.rmtree(target_dir)` trước cả khi snapshot tải xong. Trong các lần cài không có force, nó cũng download trực tiếp vào thư mục đang dùng. Điện/mạng lỗi, thiếu ổ cứng hay hỏng tệp có thể làm mất phiên bản chạy được hoặc để lại cài đặt một nửa. **Đã sửa:** tải vào thư mục staging riêng cùng filesystem, khóa cài đặt `fcntl`, đối chiếu SHA-256 của weights với revision ghim trước khi publish, tạo manifest từng file, giữ backup cũ cho tới khi publish thành công, rollback khi lần đổi tên thứ hai lỗi. Thêm tests download failure/rollback/manifest tamper.

**Lưu ý:** hai lệnh rename liên tiếp không phải một transaction nguyên tử tuyệt đối khi SIGKILL/mất điện xen giữa. AI local phải rà soát các thư mục `.aivideo-s11-backup-*` tồn đọng khi khởi động. Không tự xóa backup nếu chưa xác minh model đích.

### P0-02 — G0 `--force` xóa dữ liệu trước preflight và download

**Địa điểm nguyên bản:** `tools/setup_g0_model.py`, các dòng khoảng 190–204 và 234–258. **Đã sửa:** kiểm tra symlink an toàn, chặn model sai khi không force, giữ phiên bản cũ cho tới khi stage kiểm tra thành công, dùng backup trước khi thay thế và thử khôi phục khi publish lỗi. **Đã sửa thêm:** `--plan` ở `execute_plan()` không còn tạo thư mục Application Support (nguyên bản gọi `os.makedirs()`). Unit test mới xác nhận `--force` với mạng lỗi bảo toàn dữ liệu cũ và symlink bị chặn.

**Rủi ro tiếp theo:** `finalize_installation()` vẫn thay `contracts/g0_model.lock.json` trong source repo khi cài model. Việc này làm không tái lập được clean tree và có thể lệch giữa source lock và registry. Cần tách lock dự án bất biến và registry trạng thái theo máy, nâng cấp bằng migration rõ ràng ở nhánh tiếp theo (không tự bỏ khả năng verify). Phải fault-inject registry finalization để kiểm chứng các tình huống một nửa thành công.

### P0-03 — Cài `.app` xóa bản cũ trước khi sao chép

**Địa điểm nguyên bản:** `tools/build_macos_app.sh`, dòng 148 `rm -rf "$DEST"` trước `ditto`. **Đã sửa:** copy bản mới vào staging trên cùng filesystem với thư mục cài, yêu cầu có executable và chữ ký kiểm tra được; đưa bản cũ sang thư mục backup, đổi tên staging sang đích, và tự phục hồi bản cũ nếu quá trình thay thế lỗi trước khi publish. Bước đăng ký Spotlight giảm thành warning, không làm mất app do lỗi chỉ mục. `bash -n` PASS; **chưa có macOS live fault test**. Thời điểm giữa hai lần rename vẫn có khoảng hở nếu bị mất điện, xem recovery.

### P0-04 — Model verification trước đây cho false-positive

**Địa điểm nguyên bản:** `tools/setup_s11_model.py` chỉ kiểm cấu trúc header/sizes; `tools/check_readiness.py` chỉ kiểm tệp weights đủ lớn. Một file bất kỳ có header hợp lệ vẫn có thể qua. **Đã sửa:** SHA-256 `model.safetensors` phải trùng checksum upstream của pinned revision, các file còn lại đối chiếu với manifest ghi sau staging, file symlink bị từ chối, header `safetensors` kiểm tra offset căn bản. `--verify` offline, không tự tải. Bản cài cũ thiếu manifest **sẽ nhận NO-GO và cần tái cài có backup**.

- Model ID: `mlx-community/Qwen3-VL-4B-Instruct-4bit`.
- Revision: `2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b`.
- Published weight SHA256: `90eeb02604181dbcccd0a30a1f550a4a8928ca7dcbee4aee1449239306cfdfca`.
- Tham chiếu: https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/tree/main ; https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/blob/main/model.safetensors

**Quan trọng:** checksum pinned ở source cần được AI local đối chiếu lại trên Hugging Face chính thức trước khi `--force`, đặc biệt nếu upstream sửa dữ liệu. Nếu snapshot bị ghim đúng nhưng `hf` download thiếu file, từ chối cài chứ không bỏ kiểm tra.

### P1-05 — Worker Python check sai phiên bản

**Địa điểm:** `workers/pyproject.toml` yêu cầu `>=3.12,<3.13`, nhưng preflight cũ chỉ chấp nhận chung chung `python3 >=3.10`. **Đã sửa:** xác định interpreter thực được lựa chọn, yêu cầu Python 3.12 và ghi path vào report. Chạy Python 3.13 cho bộ test kiểm toán **không** có nghĩa MLX worker hỗ trợ Python 3.13. AI local phải kiểm lại logic chọn interpreter trong `AIVideoApp.swift` để tránh app rơi xuống system Python khác 3.12.

### P1-06 — JSON-RPC cho phép JSON mơ hồ/phi chuẩn

**Địa điểm:** `workers/src/aivideo_workers/main_g2.py`, `json.loads()` nguyên bản chấp nhận khóa trùng nhau (ghi đè) và các numeric non-finite. **Đã sửa:** từ chối duplicate object keys, `NaN`, `Infinity`, `-Infinity` và overflow `1e999`; serializing response dùng `allow_nan=False` với lỗi RPC tiêu chuẩn thay vì phát message vô hiệu; subprocess regression chạy và PASS. Cần kiểm cả bounded queue Swift còn tồn tại.

### P1-07 — CI chỉ chạy tập test hẹp

**Địa điểm:** `.github/workflows/ci.yml`. **Đã sửa:** regression Python đầy đủ, 21 bài bridge, Python compilation, Swift source parse, Swift G1 contract runtime, JSON schema, không theo dõi weights, evidence upload. **Chưa chứng thực GitHub Actions runner `macos-26` thực thi nhánh này**, phải quan sát workflow thực sau khi người dùng cho phép push và xử lý khác biệt SDK/Swift.

### P2-08 — Sai metadata report

**Địa điểm:** `tools/check_readiness.py`, trường `timestamp` trước kia là string hệ điều hành. **Đã sửa:** timestamp ISO 8601 UTC thực, tách trường `platform`.

### P2-09 — Truy vết requirement cho test mới

**Địa điểm:** `tools/run_python_tests.py`. **Đã sửa:** map test mới tới requirement `INV-03` (JSON-RPC) và `OFF-01` (model/offline), tránh gán chung `JOB-04`.

## D. Rủi ro chưa tự ý thay vì cần chạy macOS hoặc thiết kế lại

| ID | Mức | Địa chỉ | Phân tích và hướng xử lý an toàn |
|---|---|---|---|
| R-01 | P1 | `packages/AIVideoCore/Sources/WorkerIPC/WorkerClient.swift` khoảng dòng 414–437 | `AsyncStream` stdout dùng `.unbounded`. Parser giới hạn độ dài line **không giới hạn số chunk trong queue**; worker spam dữ liệu có thể đội RAM trên M1 16GB. Cần thiết kế backpressure hoặc nguồn đọc có giới hạn ở Swift, không được đổi `.unbounded` thành `bufferingNewest` vì sẽ làm mất mảnh JSON. Stress test 100 MB và 10k small frames, theo dõi RSS và thứ tự JSON; hủy worker khi quá ngưỡng, báo lỗi rõ ràng. |
| R-02 | P1 | `apps/macos/Sources/AIVideoApp.swift` khoảng dòng 144–260, `tools/build_macos_app.sh` khoảng dòng 51–78 | `.app` có worker source nhưng **không nhúng interpreter Python3.12+venv/MLX dependencies**; plist stamp đường dẫn repo build-time. App chạy từ Finder sau khi đổi đường dẫn repo/máy mới có thể không tìm được runtime. Đóng gói runtime & deps, kiểm định license, không cho hệ thống âm thầm fallback sang Python sai phiên bản. Test Finder launch, app di chuyển, PATH tối giản, Unicode paths. |
| R-03 | P1 | `tools/build_macos_app.sh` khoảng dòng 135–138 và `tools/check_readiness.py:check_app_bundle()` | `codesign -s -` là **ad-hoc**, không tương đương Developer ID + Apple notarization/Gatekeeper cho phát hành cho người khác. Tách tiêu chí “local dev build” khỏi “public distribution”; kiểm `spctl --assess`, signing team, hardened runtime, notarization trước phát hành. |
| R-04 | P1 | `tools/setup_g0_model.py:finalize_installation()` | Source lock có thể thay sau install. Thêm state-machine hai tầng và rollback cả registry/lock; không ghi vào bản source đã release; xác minh `uv.lock` pin theo runtime. |
| R-05 | P1 | `PROGRESS_TRACKER.md`, các reports S11/S15/S25/S26 | Số liệu `100%` hoặc `DONE` phải có biên bản nền tảng tương ứng và dữ liệu signed field corpus bên ngoài bản snapshot. Tự chạy 5 real video, đối chiếu SHA, giữ nguyên holdout. Không ký/đánh dấu PASS bằng fixture giả. |
| R-06 | P1 | `packages/.../WorkerClient.swift`, `main_g2.py`, `main.py`, `resolve_adapter.py` | Thử fault injection: worker chết khi flush frame, stdout 1MiB-1 byte và 1MiB+1 byte, parent kill, SIGTERM/SIGKILL process group, Resolve API timeout/đối tượng stale, offline network denial; xác nhận không zombie/treo UI, không tự retry thao tác edit không idempotent. |
| R-07 | P1 | `packages/.../Storage` + `.../Publication` | SQLite WAL, `fsync`, checkpoint, crash recovery, disk full, duplicate request ID, backup restore path traversal, symlink attacks cần nghiệm thu APFS thực; Linux fixture không có APFS đặc tính. |
| R-08 | P1 | Media Indexer/Render/Color pipeline | VFR→24 CFR, HDR→Rec.709, audio 48kHz, khung 2160x3840 và clip ngắn phải được kiểm trên video nguồn thật; không thể kết luận tương thích mọi codec chỉ từ unit tests. |
| R-09 | P2 | `README.md` và một số docs kế hoạch | Một số văn bản còn mô tả repo như chưa triển khai; đồng bộ docs trước release để tránh AI local hiểu sai trạng thái. |
| R-10 | P2 | G0/S11 backup rename | Sau SIGKILL/power loss, các thư mục backup `.g0-backup_*`, `.aivideo-s11-backup-*`, hoặc `.aivideo-install.*` có thể tồn đọng. Tạo recovery audit cho Mac: liệt kê, kiểm tra checksums, chỉ khôi phục với sự xác nhận của người dùng. |

## E. Những gì cần xem lại trên GitHub

Repository tham chiếu tồn tại, nhưng kiểm toán này **không giả định ZIP đồng bộ HEAD tại thời điểm đọc**. Các kiểm tra áp dụng patch yêu cầu commit baseline khớp. Sau khi người dùng cho phép Git access/gh hoặc AI local trên máy có `git`, thực hiện:

```bash
git remote -v
git status --porcelain=v1
git rev-parse HEAD
git fetch --prune origin  # CHỈ fetch, KHÔNG merge, không reset, không push
git rev-parse origin/main
git log --oneline --decorate -8
```

Nếu `HEAD != 92762facc60fde5dd4cb8ab3749c64ffd9a4a54a`, xử lý merge theo nội dung, không áp patch mù. Tên commit trong comment ZIP chỉ dùng làm manh mối nhận dạng.

## F. Quyết định và phạm vi bảo đảm

**Đã bàn giao:** source đầy đủ đã vá + Git patch + tests mới + tài liệu và bằng chứng offline có thể tái tạo. **Không thực hiện:** tải model hàng GB, đăng nhập GitHub hay push code, tạo app `.app` macOS, render Resolve, kiểm nghiệm E0/E1 hoặc sửa SQLite live của người dùng. **Không tuyên bố:** hệ thống “không còn lỗi”, “sẵn sàng 100%”, “mọi test trên Mac đã PASS” hoặc “model đúng/đầy đủ trên máy người dùng”.

**Thứ tự ưu tiên:** P0 backup/loss-of-data > P1 native app boot + Python runtime > P1 IPC/backpressure + resource governor > P1 field corpus & Resolve proof > P2 CI/docs polish.
