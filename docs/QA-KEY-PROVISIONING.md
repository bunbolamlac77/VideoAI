# QA Key Provisioning (Ed25519)

The field-corpus signature chain needs one long-lived key. The **private key never
enters the repository**; only the public key and its SHA-256 fingerprint are pinned.

## What exists now

| Item | Location | Notes |
|---|---|---|
| Private key | `~/.aivideo-qa/field_qa_ed25519_private.pem` | mode `0600`, outside git; override with `AIVIDEO_QA_PRIVATE_KEY` |
| Public key | `contracts/field_qa_ed25519_public_key.pem` | tracked |
| Pinned fingerprint | `g5_release_audit.PINNED_FIELD_QA_KEY_SHA256` | SHA-256 of the PEM bytes |
| Key id | `aivideo-field-qa-v1` | must match `signing_authority.key_id` |
| Signing tool | `tools/sign_field_corpus.py` | derives every field from files + labels |

## Sign / verify

```bash
workers/.venv/bin/python3 tools/sign_field_corpus.py \
  --corpus fixtures/smoke --labels fixtures/smoke/labels   # smoke: KHÔNG dùng làm field evidence \
  --out reports/evidence/signed_field_corpus_manifest.json

workers/.venv/bin/python3 tools/sign_field_corpus.py --verify
```

A valid signature only proves the key works. Release certification additionally
requires, from the signed manifest itself:

- `corpus_scope.corpus_kind == "E0_5_HELD_OUT_TRIPS"`
- `corpus_scope.labels.labeler_types == ["human"]`
- `corpus_scope.labels.source_kinds == ["field_footage"]`

The repository currently ships five synthetic title cards labelled by an agent, so
`--verify` returns valid while certification stays blocked by design.

## Rotation

1. Generate a new Ed25519 keypair and store the private key outside the repo (0600).
2. Replace `contracts/field_qa_ed25519_public_key.pem`.
3. Update `PINNED_FIELD_QA_KEY_SHA256` in `workers/src/aivideo_workers/g5_release_audit.py`.
4. Re-sign the manifest and run the Python suite (`tests/test_qa_anchor_invariants.py`
   checks that the pin matches the committed PEM).
5. Revoke the old public key by removing it from any release artefact; old manifests
   will fail verification, which is the intent.

---

## Trạng thái hiện tại (2026-11-11)

- `fixtures/smoke/` là **title card 1,5 s tổng hợp**, nhãn do agent ⇒ `tools/check_readiness.py`
  phải trả **NO-GO**. Muốn GO: cung cấp footage thật + nhãn người + manifest ký Ed25519.
- `model_installation.inspect_model_installation()` chỉ kiểm bộ artifact của **vision**
  (`config.json`, `model.safetensors`, `tokenizer.json`, `preprocessor_config.json`). Với role
  `story_synthesis` và `tts_kokoro_vi`, hàm này trả `incomplete` vì chúng có layout khác — đó
  **không** phải lỗi cài đặt; 4 case model thật (`AIVIDEO_RUN_HEAVY_*`) là bằng chứng chúng chạy.
- `AIVIDEO_CONTRACTS_DIR` không còn được dùng cho key: worker từ chối biến này
  (`CONTRACTS_DIR_FORBIDDEN`).
