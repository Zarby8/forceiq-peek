#!/bin/bash
# Install Cua (trycua cua-driver, MIT) into its OWN venv, ~/ForceIQ/.venv-peak-cua (never the test venv or system
# Python), exactly as pinned (with hashes) in requirements.lock. No /tmp writes: TMPDIR is ~/ForceIQ/peak-tmp/cua/.
# Re-lock after editing requirements.in:
#   TMPDIR=~/ForceIQ/peak-tmp/cua/ uv pip compile requirements.in --python-version 3.12 \
#     --python-platform aarch64-apple-darwin --generate-hashes --no-header -o requirements.lock
set -euo pipefail
cd "$(dirname "$0")"
export TMPDIR="$HOME/ForceIQ/peak-tmp/cua/"
mkdir -p "$TMPDIR"
VENV="$HOME/ForceIQ/.venv-peak-cua"
PY="${PEAK_CUA_PYTHON:-/opt/homebrew/bin/python3.12}"
[ -x "$VENV/bin/python" ] || uv venv --python "$PY" "$VENV"
uv pip sync --python "$VENV/bin/python" --require-hashes requirements.lock
"$VENV/bin/python" -I -c 'import importlib.metadata as m; print("cua-driver", m.version("cua-driver"), m.metadata("cua-driver")["License"])'
