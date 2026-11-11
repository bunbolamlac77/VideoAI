# (ARCHIVED — DO NOT ENABLE) AIVideo AutoLoop add-on

> ⚠️ **Tài liệu lưu trữ, không dùng cho dự án này.**
> Add-on mô tả dưới đây gửi mã nguồn, `git status`, log test và tài liệu tiến độ tới **OpenAI
> API** để "viết code". Điều đó vi phạm trực tiếp bất biến số 1 của dự án
> ([GEMINI.md](GEMINI.md)): *100% local, không gọi API AI đám mây*. Nó cũng không nằm trong
> `tools/build_macos_app.sh` hay `tools/run_tests.sh`, nên không ảnh hưởng tới bằng chứng kiểm thử.
>
> Nếu bạn vẫn muốn dùng nó cho mục đích khác: hãy coi đây là tài liệu của một công cụ **bên
> ngoài**, không phải một phần sản phẩm, và đừng trích nó như bằng chứng chất lượng.


## What is and is not automated

This add-on uses the official paid OpenAI API as the GPT code author, existing
local Bridge v2 as code applier/test runner, and Antigravity App as a passive
visual editor. It never reads ChatGPT Web messages automatically or calls the
consumer Antigravity CLI as a third-party agent. Your current Tampermonkey
extension stays installed and can still be used manually.

ChatGPT subscriptions and API billing are separate. You need an API key with
access to the requested model. Running the script sends selected code, Git
status, test output, and progress documents to the OpenAI API. Check for
secrets and other information that must remain local before enabling it.

## Install add-on without overwriting your existing Bridge

1. Keep the Bridge Terminal running (`python3 tools/autobridge/bridge.py serve --repo "$PWD"`).
2. Unzip `AIVideo-AutoLoop-addon.zip` into the existing repo root.
3. Run tests in another Terminal:

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo
python3 -m unittest discover -s tools/autobridge/tests -v
python3 tools/autobridge/auto_loop.py --repo "$PWD" --max-rounds 2
```

The second command is a no-API, no-write PREVIEW. No token changes are needed.

## Activate fully automatic limited rounds

Create an API key in your personal API project and enable API billing. Then,
from Terminal 2 (zsh/bash), paste this block:

```bash
cd /Users/phuthanh/APP_CaNhan/AIVideo
read -s 'OPENAI_API_KEY?Paste API key (not shown): '
echo
export OPENAI_API_KEY
python3 tools/autobridge/auto_loop.py \
  --repo "$PWD" \
  --goal 'Verify S06 gate; only fix demonstrable failures; do not claim DONE without evidence' \
  --model gpt-5.5 \
  --max-rounds 2 \
  --execute
unset OPENAI_API_KEY
```

Replace `gpt-5.5` with an available official model if needed. Model availability,
pricing, and output limitations depend on your API account.

The script can perform 2 rounds. GPT will read the supplied selected documents,
request extra allowed repository files if needed, provide complete FILE blocks,
then hand them to the **existing** Bridge. Bridge will apply files and run tests.
It loops with the new report until max rounds, BLOCKED, TASK_ALL_COMPLETED, or
an error. It does not automatically commit, push, or call the Antigravity CLI.

## Safety and monitoring

- `--execute` is deliberate authorization to run tests/code and incur API usage.
- The maximum is 5 rounds; each round may use additional API calls to request
  source files. No fixed USD spending cap is enforced by this program.
- Never use `--skip-project-tests` for the production Bridge server.
- The local Bridge refuses unsafe file paths; the auto-loop blocks editing files
  that were already dirty/untracked before its run, rather than overwriting
  human changes. It stops if a loop-owned file changes unexpectedly.
- A model-generated Python or Swift file can still run unsafe code in tests;
  use a disposable clone or reviewed branch for real autonomous execution.
- Interrupt with Ctrl+C. Do not start two loops or send manual HUD jobs while
  a loop is running. Verify the original Bridge's status before restarting.
- Worker report and GPT responses are recorded locally in
  `~/.aivideo-bridge/auto-runs/`. Backup originals are in
  `~/.aivideo-bridge/backups/`.

## If you want no API subscription

Keep using the v2 Tampermonkey HUD. There is no officially supported way to make
ChatGPT Web emit an unlimited unattended series of coding responses into your
local bridge. You can still use Antigravity App native Automations for its own
scheduled work (with its own AI), but that changes the constraint that ChatGPT
must be the sole author of code.
