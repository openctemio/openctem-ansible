#!/usr/bin/env bash
# Platform console as its own service (RFC-022 revision 21): renders the
# compose file for a fixture release flagged console_service, in each site
# mode, and checks the settings validation. Needs ansible-core and PyYAML; no
# Docker, no host touched.
#   tests/console.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"

render() { # render <name> [-e k=v ...]
	local name="$1"; shift
	ansible-playbook tests/render.yml -e "@$kit/tests/fixtures/console-release.yml" -e render_dir="$work/$name" -e openctem_root="$work/$name" "$@" >/dev/null
}

py() { python3 -I - "$@"; }

# A release without console_service renders no console service and keeps the
# console settings out (legacy rendering; the diff against main is in the PR).
ansible-playbook tests/render.yml -e render_dir="$work/legacy" >/dev/null
! grep -q 'openctem-console\|OPENCTEM_CONSOLE_UPSTREAM\|OPENCTEM_ADMIN_SITE' "$work/legacy/compose.yml"

# Port mode (loopback ingress), default bind, then a private bind.
render port -e openctem_ingress=loopback
render portbind -e openctem_ingress=loopback -e openctem_admin_bind=10.0.0.5 -e openctem_admin_port=9443
# Host mode through the tunnel, and off.
render host -e openctem_admin_site=host -e openctem_admin_host=admin.example.com
render off -e openctem_admin_site=off

py "$work" <<'PY'
import sys, yaml
w = sys.argv[1]
def load(n):
    with open(f"{w}/{n}/compose.yml") as f:
        t = f.read()
    return yaml.safe_load(t), t
for n in ("port", "portbind", "host", "off"):
    c, t = load(n)
    s = c["services"]
    assert "console" in s, n
    con, gw, web, api = s["console"], s["gateway"], s["web"], s["api"]
    assert con["image"].startswith("ghcr.io/openctemio/openctem-console@sha256:"), n
    e = con["environment"]
    assert e["ADMIN_API_URL"] == "http://api:8081" and e["BACKEND_API_URL"] == "http://api:8080", n
    assert e["SECURE_COOKIES"] == "true" and e["TRUST_PROXY_HEADERS"] == "true", n
    assert con["read_only"] is True and con["cap_drop"] == ["ALL"] and con["init"] is True, n
    assert "no-new-privileges:true" in con["security_opt"], n
    assert any(x.startswith("/app/console/.next/cache:uid=1001") for x in con["tmpfs"]), n
    assert con["networks"]["origin"]["ipv4_address"].endswith(".13"), n
    assert "ports" not in con and "expose" not in con, n
    g = gw["environment"]
    assert g["OPENCTEM_CONSOLE_UPSTREAM"] == "console:3000", n
    assert "OPENCTEM_ADMIN_SITE" in g and "OPENCTEM_ADMIN_ALLOWED_CIDRS" in g and "GATEWAY_HTTPS_PORT" in g, n
    assert gw["depends_on"]["console"]["condition"] == "service_healthy", n
    assert "ADMIN_API_URL" not in web["environment"] and "OPENCTEM_ADMIN_PLANE" not in web["environment"], n
    assert api["environment"]["SERVER_TRUSTED_PROXIES"].endswith(".13"), n
    assert "OPENCTEM_ADMIN_PLANE" not in t, n
    # No service is pointed at an /admin path (the console is at the site's root).
    assert not [v for sv in s.values() for k, v in (sv.get("environment") or {}).items() if k != "ADMIN_PUBLIC_URL" and "/admin" in str(v)], n
    assert "SENSOR_MTLS" not in t, n

c, _ = load("port")
assert c["services"]["gateway"]["environment"]["OPENCTEM_ADMIN_SITE"] == "port"
assert "127.0.0.1:8443:8443" in c["services"]["gateway"]["ports"]
assert c["services"]["gateway"]["environment"]["GATEWAY_HTTPS_PORT"] == "8080"
c, _ = load("portbind")
assert "10.0.0.5:9443:9443" in c["services"]["gateway"]["ports"]
for n in ("host", "off"):
    c, _ = load(n)
    assert "ports" not in c["services"]["gateway"], n
c, _ = load("host")
g = c["services"]["gateway"]["environment"]
assert g["OPENCTEM_ADMIN_SITE"] == "host" and g["OPENCTEM_ADMIN_HOST"] == "admin.example.com"
PY

# Tunnel: host mode adds the console's host name, port mode never does.
grep -q 'hostname: admin.example.com' "$work/host/cloudflared.yml"
! grep -q 'hostname: admin' "$work/port/cloudflared.yml" "$work/off/cloudflared.yml"

# Validation: every refusal fails, a valid combination passes.
check() { ansible-playbook tests/console-checks.yml -e "@$kit/tests/fixtures/console-release.yml" "$@" >/dev/null 2>&1; }
ok() { check "$@" || { echo "expected to pass: $*" >&2; exit 1; }; }
no() { ! check "$@" || { echo "expected to fail: $*" >&2; exit 1; }; }
ok -e openctem_ingress=loopback
ok -e openctem_admin_site=host -e openctem_admin_host=admin.example.com
ok -e openctem_admin_site=off
no -e openctem_admin_site=bogus
no -e openctem_ingress=loopback -e openctem_admin_port=443
no -e openctem_ingress=loopback -e openctem_admin_port=80
no -e openctem_ingress=loopback -e openctem_admin_port=0
no -e openctem_ingress=loopback -e openctem_admin_port=65536
no -e openctem_ingress=loopback -e openctem_admin_port=8080          # the gateway's published port
no -e openctem_admin_site=port                                        # cloudflared publishes no port
no -e openctem_admin_site=host                                        # host needs a name
no -e openctem_admin_site=host -e openctem_admin_host=ctem.example.com  # the app host
no -e openctem_admin_site=host -e openctem_admin_host=https://admin.example.com
no -e openctem_admin_site=host -e openctem_admin_host=admin.example.com:8443
no -e openctem_ingress=loopback -e openctem_admin_host=admin.example.com   # host set, site is port
no -e openctem_ingress=loopback -e openctem_admin_bind=not-an-ip
no -e openctem_ingress=loopback -e '{"openctem_admin_allowed_cidrs":["10.0.0.0/8","bogus"]}'
echo "console tests passed"
