#!/usr/bin/env bash
# Job signer and AI triage settings: preflight refusals, and the rendered
# compose file (signer service isolation, SIGNER_LEDGER, ADMIN_PUBLIC_URL).
# Needs ansible-core and PyYAML; no Docker, no host touched.
#   tests/signer.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"
fix="@$kit/tests/fixtures/console-release.yml"

check() { ansible-playbook tests/signer-checks.yml -e "$fix" "$@" >/dev/null 2>&1; }
ok() { check "$@" || { echo "expected to pass: $*" >&2; exit 1; }; }
no() { ! check "$@" || { echo "expected to fail: $*" >&2; exit 1; }; }

# Defaults: signer on, ledger audit.
ok
# AI_TRIAGE_ENABLED, anywhere in the inventory, stops the play (the API refuses to start with it).
no -e AI_TRIAGE_ENABLED=false
no -e AI_TRIAGE_ENABLED=true
no -e openctem_ai_triage_enabled=true
no -e '{"openctem_api_env":{"AI_TRIAGE_ENABLED":"false"}}'
# Production without the signer is refused unless unsigned jobs are accepted explicitly.
no -e openctem_job_signer=false
ok -e openctem_job_signer=false -e '{"openctem_api_env":{"SIGNER_DANGEROUS_ALLOW_UNSIGNED_JOBS":"true"}}'
no -e openctem_job_signer=false -e '{"openctem_api_env":{"SIGNER_DANGEROUS_ALLOW_UNSIGNED_JOBS":"false"}}'
# Ledger mode.
ok -e openctem_signer_ledger=enforce
no -e openctem_signer_ledger=maybe

render() { # render <name> [-e k=v ...]
	local name="$1"; shift
	ansible-playbook tests/render.yml -e "$fix" -e render_dir="$work/$name" -e openctem_root="$work/$name" "$@" >/dev/null
}
render signer
render nosigner -e openctem_job_signer=false
render host -e openctem_admin_site=host -e openctem_admin_host=admin.example.com
render enforce -e openctem_signer_ledger=enforce

python3 -I - "$work" <<'PY'
import sys, yaml
w = sys.argv[1]
def load(n):
    with open(f"{w}/{n}/compose.yml") as f:
        return yaml.safe_load(f)
c = load("signer")
s, api = c["services"]["signer"], c["services"]["api"]
assert s["network_mode"] == "none" and s["read_only"] is True
assert s["user"] == "1001:1000"
assert s["environment"]["SIGNER_LEDGER"] == "audit"
# The key volume is mounted into the signer only; the API gets the socket volume.
assert any(v.startswith("signer-keys:") for v in s["volumes"])
assert not [v for sv_name, sv in c["services"].items() if sv_name != "signer" for v in (sv.get("volumes") or []) if "signer-keys" in str(v)]
assert any(v.startswith("signer-socket:") for v in api["volumes"])
assert api["environment"]["SIGNER_SOCKET"] == "/run/openctem-signer/signer.sock"
assert api["depends_on"]["signer"]["condition"] == "service_healthy"
assert "ADMIN_PUBLIC_URL" not in api["environment"]
c = load("nosigner")
assert "signer" not in c["services"] and "SIGNER_SOCKET" not in c["services"]["api"]["environment"]
assert load("enforce")["services"]["signer"]["environment"]["SIGNER_LEDGER"] == "enforce"
assert load("host")["services"]["api"]["environment"]["ADMIN_PUBLIC_URL"] == "https://admin.example.com"
PY
echo "signer tests passed"
