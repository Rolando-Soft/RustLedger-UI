#!/usr/bin/env bash
# Runs the same requests against server.py and the Rails app, each on its own copy of the scratch
# fixture ledger, and compares the answers and the resulting files.
# Usage: test/run_parity.sh SCRATCH_DIR     (never a folder inside code/)
set -euo pipefail
SCRATCH="${1:?usage: test/run_parity.sh SCRATCH_DIR}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # code/rails
CODE="$(cd "$HERE/.." && pwd)"             # code/
PY_PORT="${PY_PORT:-8751}"
RB_PORT="${RB_PORT:-8761}"

case "$(realpath -m "$SCRATCH")/" in "$(realpath "$CODE")"/*) echo "refusing to use a scratch dir inside code/" >&2; exit 2;; esac
for port in "$PY_PORT" "$RB_PORT"; do
  if ss -ltn "sport = :$port" | grep -q LISTEN; then echo "port $port is busy; set PY_PORT/RB_PORT" >&2; exit 2; fi
done

rm -rf "$SCRATCH/py" "$SCRATCH/rb"
mkdir -p "$SCRATCH/py" "$SCRATCH/rb"
for d in py rb; do cp "$HERE/test/fixtures/t.beancount" "$HERE/test/fixtures/inc.beancount" "$SCRATCH/$d/"; done
rledger check -C "$SCRATCH/py/t.beancount"

(exec python3 "$CODE/server.py" "$SCRATCH/py/t.beancount" --port "$PY_PORT" > "$SCRATCH/py.log" 2>&1) &
PY_PID=$!
(cd "$HERE" && LEDGER_FILE="$SCRATCH/rb/t.beancount" PORT="$RB_PORT" exec bundle exec puma -C config/puma.rb > "$SCRATCH/rb.log" 2>&1) &
RB_PID=$!
trap 'kill $PY_PID $RB_PID 2>/dev/null || true' EXIT

ruby "$HERE/test/parity.rb" "$SCRATCH" "$PY_PORT" "$RB_PORT"
