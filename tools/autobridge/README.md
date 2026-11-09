# AIVideo Bridge v2 - operator-approved local code execution

This bridge does not scrape ChatGPT Web. It applies explicit `FILE` code blocks from a reply the operator copies and pastes into the Tampermonkey panel. User approval is the click "Duyet & ap dung code". No OpenAI API or model is called by this bridge.

## On the user's Mac

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo
python3 tools/autobridge/bridge.py serve --repo "$PWD"
```

In a second terminal, print the local secret (do not paste into ChatGPT):

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo
python3 tools/autobridge/bridge.py token
```

1. Disable/delete the old `ChatGPT - Antigravity Autonomous Bridge` userscript. Do not run both.
2. Create a new Tampermonkey script and paste `tools/autobridge/tampermonkey.user.js`.
3. Open ChatGPT Web; paste the locally generated token into the HUD and save it.
4. Ask ChatGPT for complete code using the exact fence format:

       ```FILE: tests/example.py
       print('hello')
       ```

5. Use ChatGPT's native Copy action, paste its response into the Bridge panel, and click **Duyet & ap dung code**.
6. Local worker validates paths, backs up files into `~/.aivideo-bridge/backups/<job id>/`, writes them, runs `tools/run_python_tests.py` and `tools/run_s06_tests.sh`, then returns test logs and git status. Open Antigravity IDE on the SAME project folder to review the changed files.
7. Click **Copy bao cao test** and paste the report into ChatGPT to request the next code batch.

By design, the worker will not retry a job after an unclean shutdown. It becomes `interrupted`; review git status and backup manually before resubmitting. Identical response contents are idempotent, returning the existing job ID.

## Security

- Binds only 127.0.0.1:8765; random token in `~/.aivideo-bridge/token` with 0600 permissions.
- Accepts only a strict allowlist of project paths, blocks traversal and symlinks.
- No `--dangerously-skip-permissions`, shell execution, auto git push, or auto commit.
- The submitted code itself is trusted only after explicit operator review. Running untrusted code is always risky.
- Python's standard library is the only dependency. Python >= 3.10 recommended.

## Development tests

```bash
python3 -m unittest discover -s tools/autobridge/tests -v
```

To test the bridge alone without running native Swift tests, start with `--skip-project-tests`. Never use that switch as evidence that the project passes.

## Antigravity integration

Antigravity IDE can remain open and will pick up file changes on disk. For an agent-driven execution interface, the official `agy -p` headless CLI exists, but is deliberately **not** invoked here because it would use a model and might make extra edits or need permission. This bridge applies ChatGPT-authored code exactly, which meets the requirement that Antigravity not generate replacement code. This is not a direct integration into the Antigravity chat panel.
