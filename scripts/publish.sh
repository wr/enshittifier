#!/usr/bin/env bash
# Push gh-pages without GitHub's "Create a pull request" sideband.
#
# GitHub injects an unprompted "remote: Create a pull request for
# 'gh-pages' on GitHub by visiting: …" block on every push to a
# non-default branch. There's no server-side opt-out, so this just
# filters those lines out of the push output. Real refspec output
# (the "x..y gh-pages -> gh-pages" line, errors, etc.) passes
# through unchanged.
#
# Use it like `git push origin gh-pages`:
#   ./scripts/publish.sh
#   ./scripts/publish.sh --force-with-lease
#   ./scripts/publish.sh --no-verify        # skip pre-push checks
#
# Args are forwarded verbatim to `git push`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Filter applied to both stdout and stderr (the PR prompt arrives on
# stderr via the sideband). Drop:
#   - blank `remote: ` lines (the spacing around the prompt)
#   - the "Create a pull request" advisory line
#   - the bare `pull/new/<branch>` URL line that follows it
filter='^remote: \s*$|^remote:\s*Create a pull request|^remote:\s*https?://[^[:space:]]+/pull/new/'

# Pipe stderr through grep too — preserve exit code via pipefail.
git push origin gh-pages "$@" 2>&1 | grep -vE "$filter" || {
  status=${PIPESTATUS[0]}
  # grep returning 1 (no matches) is fine; bail out on a real git failure.
  if [[ $status -ne 0 ]]; then exit $status; fi
}
