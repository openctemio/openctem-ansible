#!/usr/bin/env bash
# Administrators' audit sink: preflight refusals and the rendered compose file /
# secrets script for off, file and https. Needs ansible-core and PyYAML; no
# Docker, no host touched.
#   tests/audit-sink.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"
fix="@$kit/tests/fixtures/sink-release.yml"

# A 64-byte key file and a short one, to stand in for the server's secret file.
mkdir -p "$work/sec"
( umask 077; openssl rand -hex 32 > "$work/sec/admin_audit_sink_secret" )
mkdir -p "$work/short"
( umask 077; echo tooshort > "$work/short/admin_audit_sink_secret" )
mkdir -p "$work/wide"
( umask 077; openssl rand -hex 32 > "$work/wide/admin_audit_sink_secret"; chmod 0644 "$work/wide/admin_audit_sink_secret" )

check() { ansible-playbook tests/audit-checks.yml -e "$fix" "$@" >/dev/null 2>&1; }
ok() { check "$@" || { echo "expected to pass: $*" >&2; exit 1; }; }
no() { ! check "$@" || { echo "expected to fail: $*" >&2; exit 1; }; }
managed='{"openctem_api_env":{"MANAGED_SERVICE":"true"}}'
url=https://audit.example.com/ingest

# Off: fine unless a managed service runs a release that requires the sink.
ok
ok -e '{"openctem_api_env":{"MANAGED_SERVICE":"false"}}'
no -e "$managed"
no -e '{"openctem_api_env":{"MANAGED_SERVICE":true}}'
no -e '{"openctem_api_env":{"MANAGED_SERVICE":"True"}}'
# A release that does not require it (the pinned one) keeps working.
ok -e openctem_version=v0.10.1 -e "$managed"
# File.
ok -e "$managed" -e openctem_admin_audit_sink=file
ok -e "$managed" -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_head_interval=5m
# https needs the key file (>= 32 bytes, 0600).
ok -e "$managed" -e openctem_admin_audit_sink=$url -e openctem_secrets_dir="$work/sec"
no -e "$managed" -e openctem_admin_audit_sink=$url -e openctem_secrets_dir="$work/none"
no -e "$managed" -e openctem_admin_audit_sink=$url -e openctem_secrets_dir="$work/short"
no -e "$managed" -e openctem_admin_audit_sink=$url -e openctem_secrets_dir="$work/wide"
# A release without the audit stream: no sink needed for a managed service, a
# sink is refused unless the images include the stream.
rm_fix="@$kit/tests/fixtures/sink-removed-release.yml"
ok -e "$rm_fix" -e "$managed"
no -e "$rm_fix" -e "$managed" -e openctem_admin_audit_sink=file
no -e "$rm_fix" -e openctem_admin_audit_sink=$url -e openctem_secrets_dir="$work/sec"
# "provided" means a custom server image that includes the stream (tests/custom-image.sh).
custom=(-e "openctem_custom_api_image=registry.example.com/org/server:v0.99.0@sha256:$(printf 'c%.0s' $(seq 64))"
	-e openctem_custom_api_cosign_identity=https://ci.example.com/org/server/.github/workflows/release.yml@refs/tags/v0.99.0)
no -e "$rm_fix" -e "$managed" -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_provided=true
ok -e "$rm_fix" -e "$managed" -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_provided=true "${custom[@]}"
ok -e "$rm_fix" -e "$managed" -e openctem_admin_audit_sink=$url -e openctem_admin_audit_sink_provided=true -e openctem_secrets_dir="$work/sec" "${custom[@]}"
# From v0.22.0 on, a release entry must be flagged admin_audit_sink_removed (an
# entry copied from an older one would render the sink and stop the API).
no -e '{"openctem_version":"v0.22.0","openctem_releases":{"v0.22.0":{"admin_audit_sink_required":true}}}'
no -e '{"openctem_version":"v0.22.0","openctem_releases":{"v0.22.0":{}}}'
no -e '{"openctem_version":"v0.22.0","openctem_releases":{"v0.22.0":{"admin_audit_sink_removed":true,"admin_audit_sink_required":true}}}'
ok -e '{"openctem_version":"v0.22.0","openctem_releases":{"v0.22.0":{"admin_audit_sink_removed":true}}}' -e "$managed"
ok -e '{"openctem_version":"v0.21.0","openctem_releases":{"v0.21.0":{"admin_audit_sink_required":true}}}' -e openctem_admin_audit_sink=file
# Files on the server the kit does not render must not set the sink for such a
# release (api.env is written again by the run and is not read).
mkdir -p "$work/host/root" "$work/host/sec"
ok -e "$rm_fix" -e openctem_root="$work/host/root" -e openctem_secrets_dir="$work/host/sec"
echo 'ADMIN_AUDIT_SINK_SECRET=x' > "$work/host/sec/api.env"
ok -e "$rm_fix" -e openctem_root="$work/host/root" -e openctem_secrets_dir="$work/host/sec"
printf 'services:\n  api:\n    environment:\n      ADMIN_AUDIT_SINK: file:///x\n' > "$work/host/root/compose.override.yml"
no -e "$rm_fix" -e openctem_root="$work/host/root" -e openctem_secrets_dir="$work/host/sec"
ok -e "$rm_fix" -e openctem_root="$work/host/root" -e openctem_secrets_dir="$work/host/sec" -e openctem_admin_audit_sink_provided=true "${custom[@]}"
rm "$work/host/root/compose.override.yml"
echo 'ADMIN_AUDIT_SINK_HEAD_INTERVAL=5m' > "$work/host/sec/extra.env"
no -e "$rm_fix" -e openctem_root="$work/host/root" -e openctem_secrets_dir="$work/host/sec"
printf 'services:\n  api:\n    environment:\n      - "ADMIN_AUDIT_SINK=https://a.example.com/x"\n' > "$work/host/root/docker-compose.override.yaml"
rm "$work/host/sec/extra.env"
no -e "$rm_fix" -e openctem_root="$work/host/root" -e openctem_secrets_dir="$work/host/sec"
# A release that still has the stream does not read the server's files.
ok -e "$managed" -e openctem_admin_audit_sink=file -e openctem_root="$work/host/root" -e openctem_secrets_dir="$work/host/sec"
rm "$work/host/root/docker-compose.override.yaml"
# Malformed settings.
no -e openctem_admin_audit_sink=http://audit.example.com/x
no -e openctem_admin_audit_sink=syslog+tls://audit.example.com:6514
no -e openctem_admin_audit_sink=file:///etc/x
no -e "openctem_admin_audit_sink=https://a.example.com/x y"
no -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_head_interval=soon
no -e openctem_admin_audit_sink_head_interval=5m   # interval without a sink

# Rendering.
render() { # render <name> [-e k=v ...]
	local name="$1"; shift
	ansible-playbook tests/render.yml -e "$fix" -e render_dir="$work/$name" -e openctem_root="$work/$name" "$@" >/dev/null
}
render off
render file -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_head_interval=5m
render https -e openctem_admin_audit_sink=$url
render removed -e "$rm_fix"
render removed-provided -e "$rm_fix" -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_provided=true

! grep -q 'ADMIN_AUDIT_SINK' "$work/off/compose.yml" "$work/off/scripts/openctem-secrets"
! grep -q 'ADMIN_AUDIT_SINK\|admin-audit' "$work/removed/compose.yml"
grep -q 'ADMIN_AUDIT_SINK: file://' "$work/removed-provided/compose.yml"
python3 -I - "$work" <<'PY'
import sys, yaml
w = sys.argv[1]
def api(n):
    with open(f"{w}/{n}/compose.yml") as f:
        return yaml.safe_load(f)["services"]["api"]
a = api("file")
assert a["environment"]["ADMIN_AUDIT_SINK"] == "file:///var/lib/openctem-admin-audit/admin-audit.jsonl"
assert a["environment"]["ADMIN_AUDIT_SINK_HEAD_INTERVAL"] == "5m"
assert f"{w}/file/admin-audit:/var/lib/openctem-admin-audit" in a["volumes"], a["volumes"]
a = api("https")
assert a["environment"]["ADMIN_AUDIT_SINK"] == "https://audit.example.com/ingest"
assert "ADMIN_AUDIT_SINK_HEAD_INTERVAL" not in a["environment"]
assert not [v for v in a["volumes"] if "admin-audit" in v], a["volumes"]
assert not any("SECRET" in k for k in a["environment"]), "no secret in the compose file"
PY
# The key reaches the API through api.env only (https mode), never the compose file.
grep -q '^ADMIN_AUDIT_SINK_SECRET=$(val admin_audit_sink_secret)$' "$work/https/scripts/openctem-secrets"
! grep -q 'ADMIN_AUDIT_SINK_SECRET' "$work/file/scripts/openctem-secrets"
# The backup archives the file sink directory and the https key when present.
grep -q 'admin-audit.tar.gz' "$work/file/scripts/openctem-backup"
grep -q "admin_audit_sink_secret" "$work/file/scripts/openctem-backup"
echo "audit sink tests passed"
