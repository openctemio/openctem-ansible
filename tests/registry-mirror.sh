#!/usr/bin/env bash
# Private registry support: with openctem_registry_mirror the OpenCTEM images keep
# their digest under the mirror prefix and cosign verifies the MIRROR reference
# with the same certificate identity and issuer; third-party images follow
# openctem_third_party_registry_mirror; unset changes nothing; bad values are
# refused. A recording `docker` stub stands in for the daemon: no Docker, no host
# touched. Needs ansible-core and PyYAML.
#   tests/registry-mirror.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$2" "$3" && pass "$1" || fail "$1 (missing: $2)"; }
hasnt() { grep -qF -- "$2" "$3" && fail "$1 (unexpected: $2)" || pass "$1"; }

# Unset: no mirror reference anywhere, the rendered compose names ghcr.io.
ansible-playbook tests/render.yml -e render_dir="$work/default" >/dev/null
has "default: ghcr.io api" "image: ghcr.io/openctemio/openctem-api@sha256:" "$work/default/compose.yml"
hasnt "default: no mirror" "registry.example.com" "$work/default/compose.yml"

# Mirror on: prefix swapped (trailing slash tolerated), digest unchanged.
ansible-playbook tests/render.yml -e render_dir="$work/mirror" -e openctem_registry_mirror=registry.example.com:5000/oc/ \
	-e openctem_third_party_registry_mirror=registry.example.com/mirror >/dev/null
orig="$(sed -n 's/^ *image: ghcr.io\/openctemio\/openctem-api@//p' "$work/default/compose.yml" | head -n 1)"
has "mirror: api by the same digest" "image: registry.example.com:5000/oc/openctem-api@$orig" "$work/mirror/compose.yml"
has "mirror: web" "image: registry.example.com:5000/oc/openctem-web@sha256:" "$work/mirror/compose.yml"
has "mirror: gateway" "image: registry.example.com:5000/oc/openctem-gateway@sha256:" "$work/mirror/compose.yml"
has "mirror: migrations" "image: registry.example.com:5000/oc/migrations@sha256:" "$work/mirror/compose.yml"
hasnt "mirror: no ghcr.io image" "ghcr.io/openctemio" "$work/mirror/compose.yml"
has "third-party: postgres" "image: registry.example.com/mirror/library/postgres:" "$work/mirror/compose.yml"
has "third-party: redis" "image: registry.example.com/mirror/library/redis:" "$work/mirror/compose.yml"
has "third-party: cloudflared" "image: registry.example.com/mirror/cloudflare/cloudflared:" "$work/mirror/compose.cloudflared.yml"
has "third-party: rclone (wal scripts)" "RCLONE_IMAGE='registry.example.com/mirror/rclone/rclone:" "$work/mirror/scripts/wal-common.sh"
has "third-party: postgres (backup script)" "registry.example.com/mirror/library/postgres:" "$work/mirror/scripts/openctem-backup"

# Console release: the console image follows the mirror too.
ansible-playbook tests/render.yml -e "@$kit/tests/fixtures/console-release.yml" -e render_dir="$work/console" \
	-e openctem_registry_mirror=registry.example.com/oc >/dev/null
has "mirror: console" "image: registry.example.com/oc/openctem-console@sha256:" "$work/console/compose.yml"

# Signature check: what the docker stub is asked to run.
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
STUB
chmod +x "$work/bin/docker"
sig() { # sig <logname> [-e k=v ...]
	local log="$work/$1.log"; shift
	: >"$log"
	STUB_LOG="$log" PATH="$work/bin:$PATH" ansible-playbook tests/mirror-signatures.yml -e "@$kit/tests/fixtures/console-release.yml" "$@" >/dev/null
}
sig sig-default
[ "$(wc -l <"$work/sig-default.log")" -eq 5 ] && pass "default: 5 images verified" || fail "default: 5 images verified"
has "default: ghcr.io ref verified" "verify ghcr.io/openctemio/openctem-api@sha256:" "$work/sig-default.log"
sig sig-mirror -e openctem_registry_mirror=registry.example.com/oc -e openctem_third_party_registry_mirror=registry.example.com/mirror \
	-e openctem_registry_docker_config_dir=/root/.docker -e openctem_registry_ca_file=/etc/ssl/oc-ca.pem
[ "$(wc -l <"$work/sig-mirror.log")" -eq 5 ] && pass "mirror: 5 images verified" || fail "mirror: 5 images verified"
has "mirror: verifies the mirror ref" "verify registry.example.com/oc/openctem-api@sha256:" "$work/sig-mirror.log"
hasnt "mirror: no ghcr.io ref verified" "verify ghcr.io/openctemio" "$work/sig-mirror.log"
has "mirror: same identity and issuer" "--certificate-identity https://github.com/openctemio/openctem/.github/workflows/docker-publish.yml@refs/tags/v0.99.0 --certificate-oidc-issuer https://token.actions.githubusercontent.com" "$work/sig-mirror.log"
has "mirror: cosign image through the third-party mirror" "registry.example.com/mirror/sigstore/cosign/cosign:" "$work/sig-mirror.log"
has "mirror: registry login mounted read-only" "--volume=/root/.docker:/registry-auth:ro" "$work/sig-mirror.log"
has "mirror: CA mounted read-only" "--volume=/etc/ssl/oc-ca.pem:/registry-ca.pem:ro" "$work/sig-mirror.log"
hasnt "default: no registry mounts" "registry-auth" "$work/sig-default.log"

# Bad values are refused.
bad() { ! ansible-playbook tests/mirror-checks.yml "$@" >/dev/null 2>&1 && pass "refused: $*" || fail "accepted: $*"; }
ok() { ansible-playbook tests/mirror-checks.yml "$@" >/dev/null 2>&1 && pass "accepted: $*" || fail "refused: $*"; }
ok
ok -e openctem_registry_mirror=registry.example.com:5000/oc
bad -e openctem_registry_mirror=https://registry.example.com/oc
bad -e openctem_registry_mirror='reg.example.com/oc@sha256:abc'
bad -e 'openctem_registry_mirror=reg.example.com/oc\1'
bad -e openctem_third_party_registry_mirror=reg//x
bad -e openctem_registry_ca_file=relative.pem

echo
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
