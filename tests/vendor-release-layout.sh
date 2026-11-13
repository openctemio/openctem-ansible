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
# The audit stream flag comes from the release's own source.
g checkout -q v0.21.1
mkdir -p "$repo/server/internal/config" "$repo/server/internal/extensionhost"
echo 'ADMIN_AUDIT_SINK string' >"$repo/server/internal/config/config.go"
g add -A; g commit -qm sink; g tag v0.21.2
printf 'var removedSettings = []string{\n\t"ADMIN_AUDIT_SINK",\n}\n' >"$repo/server/internal/extensionhost/removed_settings.go"
g add -A; g commit -qm removed; g tag v0.22.1
audit() { # <tag> <want>
  local got
  got="$(OPENCTEM_REPO="file://$repo" bash "$script" --audit-sink "$1" 2>/dev/null)" || true
  if [ "$got" = "$2" ]; then echo "ok   $1 audit sink -> $got"; else echo "FAIL $1 audit sink: got $got, want $2"; fail=1; fi
}
audit v0.21.1 none
audit v0.21.2 required
audit v0.22.1 removed
# The server image name comes from the release's own publish workflow
# (openctem-server from v0.23.0, openctem-api before); both map to the key api.
publish() { # <image name>
  mkdir -p "$repo/.github/workflows"
  printf 'jobs:\n  build:\n    strategy:\n      matrix:\n        image:\n          - { name: %s, legacy: %s, context: server, file: server/Dockerfile, target: production }\n          - { name: migrations, legacy: %s }\n' "$1" "''" "''" >"$repo/.github/workflows/docker-publish.yml"
}
g checkout -q v0.22.1
publish openctem-api
g add -A; g commit -qm old-name; g tag v0.22.2
publish openctem-server
g add -A; g commit -qm new-name; g tag v0.23.0
# A hotfix of the older line cut after the rename keeps its line's name.
g checkout -q v0.22.2
g commit -q --allow-empty -m hotfix; g tag v0.22.3
image() { # <tag> <want>
  local got
  got="$(OPENCTEM_REPO="file://$repo" bash "$script" --server-image "$1" 2>/dev/null)" || got=refused
  if [ "$got" = "$2" ]; then echo "ok   $1 server image -> $got"; else echo "FAIL $1 server image: got $got, want $2"; fail=1; fi
}
image v0.22.2 openctem-api
image v0.23.0 openctem-server
image v0.22.3 openctem-api
image v0.22.1 refused
# Both names print under the key api of openctem_releases.
for n in openctem-server openctem-api; do
  key="$(bash -c 'name="$1"; case "$name" in openctem-server | openctem-api) key=api ;; *) key="${name#openctem-}" ;; esac; echo "$key"' _ "$n")"
  [ "$key" = api ] && echo "ok   $n -> key api" || { echo "FAIL $n -> key $key"; fail=1; }
done
grep -qF 'openctem-server | openctem-api) key=api ;;' "$script" && echo "ok   vendor-release maps both names to api" || { echo "FAIL: vendor-release does not map both server image names to api"; fail=1; }
exit "$fail"
