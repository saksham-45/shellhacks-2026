#!/usr/bin/env bash
# myAD Agents hook: offline, keyless, and scoped to server/tests only.
set -euo pipefail
cd "$(dirname "$0")"
unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_USE_VERTEXAI GOOGLE_CLOUD_PROJECT
unset MYAD_LIVE MYAD_EVAL_LIVE_LLM
export MYAD_MODEL=stub MYAD_ROOT="$(cd .. && pwd)"

# The lockfile is the only source of Python dependencies.  --offline makes a
# missing cache an explicit setup failure rather than silently reaching a network.
if [[ ! -x .venv/bin/python ]]; then
  uv venv --offline -q --python 3.12 .venv
fi
uv pip sync --offline -q --python .venv/bin/python requirements.lock
exec .venv/bin/python -m pytest -q -m 'not live_llm' -p no:cacheprovider tests
