#!/usr/bin/env bash
# Boot a local python http server, run Lighthouse mobile + desktop,
# gate on category scores. Thresholds are floors set to pass the
# current site — tighten as the site polish improves.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PORT=8765
# Floors set to pass the current site; tighten as the site is polished.
# Mobile perf currently lands ~73 (the giant serif hero costs ~0.3s of
# render time on simulated mobile); desktop is 100.
PERF_MIN=70
SEO_MIN=95
A11Y_MIN=90
BP_MIN=90

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
gray()   { printf '\033[90m%s\033[0m\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "missing: $1"; exit 1; }; }
need python3
need npx
need node

SERVER_PID=
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f /tmp/enshittifier-lh-*.json
}
trap cleanup EXIT

gray "  starting http://localhost:$PORT"
python3 -m http.server "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 30); do
  if curl -sf "http://localhost:$PORT/" >/dev/null; then break; fi
  sleep 0.1
done

fail=0
run_lh() {
  local preset_label="$1" preset_flag="$2"
  local out="/tmp/enshittifier-lh-${preset_label}.json"
  local extra=()
  [[ -n "$preset_flag" ]] && extra=("$preset_flag")
  gray "  lighthouse (${preset_label})"
  npx --no-install lighthouse "http://localhost:$PORT/" \
    --quiet \
    --output=json \
    --output-path="$out" \
    --chrome-flags="--headless=new --no-sandbox" \
    ${extra[@]+"${extra[@]}"} >/dev/null

  node -e "
    const r = require('$out');
    const cats = r.categories;
    const scores = {
      performance: Math.round(cats.performance.score * 100),
      accessibility: Math.round(cats.accessibility.score * 100),
      'best-practices': Math.round(cats['best-practices'].score * 100),
      seo: Math.round(cats.seo.score * 100),
    };
    const mins = {performance: $PERF_MIN, accessibility: $A11Y_MIN, 'best-practices': $BP_MIN, seo: $SEO_MIN};
    let bad = 0;
    for (const k of Object.keys(scores)) {
      const v = scores[k], min = mins[k];
      const mark = v >= min ? '✓' : '✗';
      const line = '    ' + mark + ' ' + k.padEnd(15) + v + '/100 (min ' + min + ')';
      if (v < min) { console.error('\x1b[31m' + line + '\x1b[0m'); bad = 1; }
      else         { console.log ('\x1b[90m' + line + '\x1b[0m'); }
    }
    process.exit(bad);
  " || fail=1
}

run_lh mobile  ""
run_lh desktop "--preset=desktop"

if [[ $fail -eq 1 ]]; then
  red "lighthouse check failed"
  exit 1
fi
green "  lighthouse OK"
exit 0
