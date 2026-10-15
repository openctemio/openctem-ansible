#!/usr/bin/env bash
# Vendor the gateway config and the least-privilege SQL of an OpenCTEM release
# into roles/openctem/files/release/<tag>/, and print the image digests to put
# into roles/openctem/defaults/main.yml (openctem_releases).
#
#   scripts/vendor-release.sh v0.9.7
#
# Runs on the controller. Needs git and docker (buildx imagetools, read-only
# registry lookups). Review the diff against the previous release before use:
# the gateway's planes.caddy changes when the API adds a route plane.
set -euo pipefail
tag="${1:?usage: $0 vX.Y.Z}"
case "$tag" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "not a release tag: $tag" >&2; exit 2 ;; esac
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$kit/roles/openctem/files/release/$tag"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone -q --depth 1 --branch "$tag" https://github.com/openctemio/openctem.git "$work/src"
src="$work/src/api/deploy"
mkdir -p "$dest/gateway/modes" "$dest/gateway/sensors" "$dest/postgres"
cp "$src/gateway/Caddyfile" "$src/gateway/planes.caddy" "$src/gateway/entrypoint.sh" "$dest/gateway/"
cp "$src/gateway/modes/http.global" "$dest/gateway/modes/"
cp "$src/gateway/sensors/off.wrappers" "$dest/gateway/sensors/"
cp "$src/postgres/least-privilege-roles.sql" "$dest/postgres/"
( cd "$dest" && sha256sum gateway/Caddyfile gateway/entrypoint.sh gateway/modes/http.global \
    gateway/planes.caddy gateway/sensors/off.wrappers postgres/least-privilege-roles.sql > SHA256SUMS )
echo "vendored into $dest"
echo "openctem_releases entry (verify each with cosign before committing):"
echo "  $tag:"
for name in openctem-api openctem-web openctem-gateway migrations; do
  d="$(docker buildx imagetools inspect "ghcr.io/openctemio/$name:$tag" --format '{{json .Manifest.Digest}}' | tr -d '"')"
  key="${name#openctem-}"
  echo "    $key: ghcr.io/openctemio/$name@$d"
done
