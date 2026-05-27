#!/usr/bin/env bash
# Lint every HTML file + style.css.
# The site ships no standalone JS — the toggle script is inlined in
# index.html, so there's nothing to node --check separately.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
gray()  { printf '\033[90m%s\033[0m\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "missing tool: $1"; exit 1; }; }
need node
need npx

fail=0

HTML_FILES=(index.html privacy.html 404.html)
for f in "${HTML_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  gray "  htmlhint $f"
  if ! npx --no-install htmlhint "$f"; then
    fail=1
  fi
done

gray "  stylelint style.css"
if ! npx --no-install stylelint style.css; then
  fail=1
fi

if [[ $fail -eq 1 ]]; then
  red "lint failed"
  exit 1
fi
green "  lint clean"
exit 0
