#!/usr/bin/env bash
# The vendor script reads the release's deploy files from the backend
# directory that tag actually has: server/ since the backend directory rename,
# api/ before it, whatever the version number.
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/vendor-release.sh"
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
g() { git -C "$repo" -c user.name=t -c user.email=t@example.com "$@"; }
g init -q
release() { # <tag> <dir>
  g rm -rq --ignore-unmatch api server
  mkdir -p "$repo/$2/deploy/gateway"
  echo "$1" >"$repo/$2/deploy/gateway/Caddyfile"
  g add -A
  g commit -qm "$1"
  g tag "$1"
}
release v0.20.3 api
release v0.20.4 api
release v0.21.0 server
release v0.21.1 server
fail=0
expect() { # <tag> <dir>
  local got
  got="$(OPENCTEM_REPO="file://$repo" bash "$script" --layout "$1" 2>/dev/null)" || true
  if [ "$got" = "$2" ]; then echo "ok   $1 -> $got"; else echo "FAIL $1: got $got, want $2"; fail=1; fi
}
expect v0.20.3 api
expect v0.20.4 api
expect v0.21.0 server
expect v0.21.1 server
# A hotfix of an old line cut after the rename merged keeps its own layout.
g checkout -q v0.20.4
release v0.20.5 api
expect v0.20.5 api
# A release cut before the rename merged keeps api/ even with a higher number.
release v0.21.9 api
expect v0.21.9 api
# A tag with neither directory is refused.
g checkout -q v0.21.1
g rm -rq server
g commit -qm empty
g tag v0.22.0
if OPENCTEM_REPO="file://$repo" bash "$script" --layout v0.22.0 >/dev/null 2>&1; then echo "FAIL: a tag without a deploy directory was accepted"; fail=1; else echo "ok   unknown layout refused"; fi
if bash "$script" --layout latest >/dev/null 2>&1; then echo "FAIL: a non-tag was accepted"; fail=1; else echo "ok   non-tag refused"; fi
exit "$fail"
