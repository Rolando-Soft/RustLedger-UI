#!/usr/bin/env bash
# Starts the Rails app on a fresh copy of test/fixtures/reports.beancount and checks every report page
# against rledger's own output. Usage: test/run_reports.sh SCRATCH_DIR   (never a folder inside code/)
set -euo pipefail
SCRATCH="${1:?usage: test/run_reports.sh SCRATCH_DIR}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # code/rails
CODE="$(cd "$HERE/.." && pwd)"             # code/
RB_PORT="${RB_PORT:-8762}"

case "$(realpath -m "$SCRATCH")/" in "$(realpath "$CODE")"/*) echo "refusing to use a scratch dir inside code/" >&2; exit 2;; esac
if ss -ltn "sport = :$RB_PORT" | grep -q LISTEN; then echo "port $RB_PORT is busy; set RB_PORT" >&2; exit 2; fi

rm -rf "$SCRATCH/reports"
mkdir -p "$SCRATCH/reports"
cp "$HERE/test/fixtures/reports.beancount" "$SCRATCH/reports/"
printf '2024-01-01 open Assets:A\n\n2024-01-02 * "x"\n  Assets:A  5 USD\n  Expenses:Nope\n\n2024-01-03 balance Assets:A 7 USD\nbad line here\n' > "$SCRATCH/reports/broken.beancount"
rledger check -C "$SCRATCH/reports/reports.beancount"

(cd "$HERE" && LEDGER_FILE="$SCRATCH/reports/reports.beancount" PORT="$RB_PORT" exec bundle exec puma -C config/puma.rb > "$SCRATCH/reports/rb.log" 2>&1) &
RB_PID=$!
trap 'kill $RB_PID 2>/dev/null || true' EXIT

cd "$HERE" && bundle exec ruby test/reports.rb "$SCRATCH/reports/reports.beancount" "$RB_PORT" "$HERE" "$SCRATCH/reports/broken.beancount"
