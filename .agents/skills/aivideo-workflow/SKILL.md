---
name: aivideo-workflow
description: Procedures and verification rules for developing, modifying, or testing the AIVideo v3.1 application on macOS. Use this skill whenever working on AIVideo tasks, executing steps S00-S26, verifying gates G0-G5, or checking local model and database constraints.
---

# AIVideo Development & Verification Workflow

## Core Principles
1. **Never use Cloud AI**: Local inference only (Qwen3-VL 4B, VieNeu-TTS, Whisper large-v3).
2. **Swift Core writes DB exclusively**: Python workers never execute write queries directly to SQLite.
3. **Evidence Required**: All cut decisions and narrative claims must cite source content hash and IN/OUT timecode.
4. **Planning Files**: Always check `task_plan.md` before starting, and update `progress.md` upon completion.

## Verification Checklist
- Run Python tests:
  ```bash
  for t in tests/test_*.py; do
    workers/.venv/bin/python3 "$t"
  done
  ```
- Run Swift package tests:
  ```bash
  cd packages/AIVideoCore && swift test
  ```
- Validate against gate criteria before closing any step.
