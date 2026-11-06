#!/usr/bin/env bash
# The vendor script reads the release's deploy files from the backend
# directory of that tag: api/ up to v0.20.x, server/ from v0.21.0 on.
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/vendor-release.sh"
fail=0
expect() { # <tag> <dir>
  local got
  got="$(bash "$script" --layout "$1")"
  if [ "$got" = "$2" ]; then echo "ok   $1 -> $got"; else echo "FAIL $1: got $got, want $2"; fail=1; fi
}
expect v0.9.7 api
expect v0.19.4 api
expect v0.20.0 api
expect v0.20.2 api
expect v0.20.15 api
expect v0.21.0 server
expect v0.21.0-rc.1 server
expect v0.100.0 server
expect v1.0.0 server
if bash "$script" --layout latest >/dev/null 2>&1; then echo "FAIL: a non-tag was accepted"; fail=1; else echo "ok   non-tag refused"; fi
exit "$fail"
