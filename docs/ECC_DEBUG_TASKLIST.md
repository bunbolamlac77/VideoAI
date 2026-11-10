# ECC DEBUG TASKLIST — AIVideo v3.1

**Operation:** `orch-fix-defect` (ECC gated pipeline)
**Intake:** sửa toàn bộ lỗi tồn đọng được phát hiện trong [AUDIT_20261110_FULL_EVALUATION.md](AUDIT_20261110_FULL_EVALUATION.md).
**Size tier:** **large** — cross-cutting (Python pipeline contract, benchmark, Swift stores, tests, docs), có thay đổi contract nội bộ và open questions.
**Phase mask:** 0 → 1 (light) → 2 → **GATE 1** → 4 (TDD) → 5 → 6 → **GATE 2**

---

## Phase 1 — Research (kết quả, không đoán)

| Câu hỏi | Kết quả |
|---|---|
| `mlx_vlm` có nhận nhiều ảnh trong một lần generate? | **Có.** `generate(image: str \| list[str])`, `apply_chat_template(..., num_images=N)` — mlx_vlm 0.7.12 |
| Test nào đang encode hành vi lỗi? | `test_s11_real_vlm_inference.py:81` (`[8]`), `test_s12_full_frame_pipeline.py:382/387` (backdoor + coverage 1.0), `test_s15_g2_benchmark.py:222/225` (verified + coverage) |
| Có sẵn cơ chế inject inspector hợp lệ để test? | Có — `run_or_resume_analysis(window_inspector_fn=...)`; chỉ cần bỏ đường RPC `_inspector_fn` |
| ffprobe có trả `nb_frames` cho mọi container? | Không đáng tin (MP4 thường có, MKV/stream có thể không) → cần fallback `duration × r_frame_rate` |

---

## Defect registry (ánh xạ từ audit)

| ID | Defect | Mức | Wave |
|---|---|---|---|
| D01 | Inspector 1 frame vs audit 16 frame → `POST_PROCESSOR_TRUNCATION` | P0-1 | A |
| D02 | Inspector payload rỗng fail-open, coverage 100% | P0-2 | A |
| D03 | Backdoor `_inspector_fn` trên mặt RPC | P0-3 | A |
| D04 | Coverage tự quy chiếu, không clamp (4.0) | P0-4 | A |
| D05 | Benchmark synthetic + `real_video_corpus_verified=True` vô điều kiện | P0-5 | B |
| D06 | 3 store Swift mở connection ghi riêng, schema ad-hoc | P0-6 | C |
| D07 | Ed25519 key không pin, PEM không tồn tại | P0-7 | C |
| D08 | `g2.analyze_source` > 1 MiB với video dài | P1-12 | A |
| D09 | `commitPublication` không bind job + không re-hash | P1-1 | C |
| D10 | `saveClaim` cho phép tự tạo claim `confirmed` | P1-2 | C |
| D11 | Reconciler `SUCCEEDED` khi mới 1 artifact | P1-3 | C |
| D12 | G3 UI bịa `c1`/`rev-c1`/`confirmed` | P1-18 | D |
| D13 | Test S02 tự ghi PASS | P1-19 | D |
| D14 | 3 định nghĩa "model đã cài" | P1-20 | D |
| D15 | VieNeu thiếu + slider 0.8–1.2× bị engine từ chối | P1-17 | D (cần quyết định) |
| D16 | ASR/Whisper chưa có, `audio_analysis_status` hard-code | P1-16 | D (tính năng) |
| D17 | Không lease ở Python, ffmpeg orphan | P1-13 | D |
| P2 | God object, path cứng, CI echo, dead code… | P2 | E |

---

## Phase 2 — Task list (thin vertical slices)

### Wave 0 — Baseline (trivial)
| Task | Việc | Nghiệm thu |
|---|---|---|
| T00 | Chốt baseline sạch: xử lý 3 file evidence bị test ghi đè; `git status` sạch | `git status --short` rỗng; 156 Python PASS |

### Wave A — G2 chạy thật & trung thực (D01–D04, D08)
| Task | Red test (mới) | Thay đổi | Nghiệm thu |
|---|---|---|---|
| **T01** Hợp đồng cửa sổ | `test_g2_window_contract.py::test_sampled_window_completes` + `test_inspector_underreports_frames_raises` | `pipeline_adapters`: decode N frame/cửa sổ (N=8, đều nhau, gồm midpoint), trả `accepted_frame_ids` = frame thật gửi; `full_frame_pipeline`: audit theo `planned_frame_ids` của inspector, không theo 16 frame; ledger tách `vlm_frame_coverage` vs `decode_coverage` | Pipeline với model thật trên `trip-holdout-01-dalat.mp4` → `completed`, ≥1 observation, không raise; coverage = 8/16 chứ không phải 1.0 |
| **T02** Fail-closed + bỏ backdoor | `test_empty_inspector_payload_raises`, `test_rpc_rejects_inspector_override` | `full_frame_pipeline:515/544` bắt buộc `frame_ids` + `observation_text`; `main_g2:458` ném `ValueError("INSPECTOR_OVERRIDE_FORBIDDEN")` | `{}` → `INVALID_VISUAL_PAYLOAD`; RPC có `_inspector_fn` → lỗi |
| **T03** Coverage số học | `test_coverage_never_exceeds_one`, `test_index_denominator_mismatch_fails_closed` | Mẫu số từ container (fallback duration×fps), đếm frame bị bỏ, clamp [0,1], fail-closed khi lệch > 5% | declared=10/indexed=40 → raise, không còn 4.0 |
| **T04** Payload ≤ 1 MiB | `test_long_video_result_fits_frame_budget` | Trả `frame_id_ranges` + counts; client dựng lại được | 86.400 frame → JSON < 1.048.576 B |

### Wave B — Benchmark trung thực (D05)
| Task | Red test | Thay đổi | Nghiệm thu |
|---|---|---|---|
| **T05** Bỏ metric giả | `test_real_mode_refuses_synthetic_labels`, `test_fixed_text_inspector_fails_gate` | Xoá `(1200,1200)`; bỏ gán `real_video_corpus_verified=True`; thêm `label_source`; `real` mode từ chối nhãn synthetic | Report ghi `label_source=synthetic`, `real_video_corpus_verified=False`; thay inspector bằng text cố định → G2 FAIL |
| **T06** (hoãn) Nhãn thật 5 clip | — | Cần người viết ground truth | Chỉ chạy khi có nhãn |

### Wave C — Toàn vẹn SQLite & phát hành (D06, D07, D09–D11)
| Task | Red test | Thay đổi | Nghiệm thu |
|---|---|---|---|
| **T07** Single-writer | `test_only_project_store_opens_sqlite` (static) + `test_g3_g4_g5_use_shared_handle` | G3/G4/G5 dùng handle/transaction của `ProjectStore`; DDL vào `initializeSchema` + migration `002`; bỏ `BEGIN IMMEDIATE` khỏi read | 1 connection; `user_version` tăng; 15 Swift suite vẫn xanh |
| **T08** Publication binding | `test_commit_rejects_foreign_job`, `test_commit_rejects_hash_mismatch` | `commitPublication` bind `project/job/attempt/fencing`, re-hash file | Publication của project khác bị từ chối |
| **T09** Reconciler | `test_reconciler_requires_all_artifacts` | Yêu cầu đủ artifact set | Thiếu 1 artifact → không SUCCEEDED |
| **T10** Ed25519 pin | `test_foreign_key_cannot_certify`, `test_key_path_override_ignored` | Key trong bundle + `key_id`; bỏ `AIVIDEO_CONTRACTS_DIR` cho key | Key khác → fail |

### Wave D — Luồng người dùng & trung thực (D12–D17)
| Task | Việc | Nghiệm thu |
|---|---|---|
| T11 | G3 UI bind claim thật từ `state.g1Claims` | Không còn `c1`; nút Duyệt tắt khi không có claim confirmed |
| T12 | S02 evidence: launch thật hoặc NOT_RUN | Không còn file tự ghi PASS |
| T13 | Thống nhất "model installed" (1 hàm) | Preflight và worker cùng kết quả |
| T14 | TTS: cài VieNeu hoặc disable bước voice + bỏ slider | Không còn ngõ cụt |
| T15 | Lease Python + reaper ffmpeg | Kill worker → không còn ffmpeg orphan |

### Wave E — Hygiene (P2, sau cùng)
`AIVideoApp` tách file, path cứng → env, Swift suite ghi JSONL, CI chạy harness, xoá dead code.

---

## Commit plan (Gate 2, conventional commits)

```
fix(g2): sample windows explicitly and audit submitted frames   [T01,T02]
fix(g2): derive coverage from container with clamping          [T03]
fix(rpc): paginate frame ids to stay under 1 MiB               [T04]
fix(bench): stop certifying synthetic labels as real corpus    [T05]
refactor(store): single SQLite writer + real migration         [T07]
fix(store): bind publications to their job and re-hash bytes   [T08,T09]
fix(release): pin Ed25519 key and reject foreign keys          [T10]
fix(ui): bind G3 story request to real confirmed claims        [T11]
test(s02): stop self-certifying manual evidence                [T12]
```

## Stop conditions / definition of done
- Mỗi task: red test chạy fail trước, green sau, không regression 156 Python + 15 Swift.
- Gate 2 chỉ commit sau khi user xem diff.
- Không mở rộng sang tính năng mới (ASR, nhãn tay) nếu chưa được duyệt.
