#!/usr/bin/env bash
# Platform feed proxy: renders the compose file and the secrets script for a
# fixture release flagged feed_proxy, and checks the settings validation.
# Needs ansible-core and PyYAML; no Docker, no host touched.
#   tests/feed-proxy.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"
fx="@$kit/tests/fixtures/feed-proxy-release.yml"

render() { # render <name> [-e k=v ...]
	local name="$1"; shift
	ansible-playbook tests/render.yml -e "$fx" -e render_dir="$work/$name" -e openctem_root="$work/$name" "$@" >/dev/null
}

# Unset: nothing rendered. Set: the API gets both names in its environment.
render unset
render set -e openctem_feed_proxy=http://proxy.corp.example:3128 -e openctem_feed_no_proxy=mirror.corp.example,.corp.example
! grep -q 'OPENCTEM_HTTPSEC_FEED' "$work/unset/compose.yml"
python3 -I - "$work" <<'PY'
import sys, yaml
w = sys.argv[1]
e = yaml.safe_load(open(f"{w}/set/compose.yml"))["services"]["api"]["environment"]
assert e["OPENCTEM_HTTPSEC_FEED_PROXY"] == "http://proxy.corp.example:3128", e
assert e["OPENCTEM_HTTPSEC_FEED_NO_PROXY"] == "mirror.corp.example,.corp.example", e
PY

# A proxy password comes only from the server-side file, into the API env file.
grep -q 'feed_proxy_url.*OPENCTEM_HTTPSEC_FEED_PROXY=' "$work/unset/scripts/openctem-secrets"
# A release without the flag never writes the name (its API would refuse it).
ansible-playbook tests/render.yml -e render_dir="$work/legacy" >/dev/null
! grep -q 'OPENCTEM_HTTPSEC_FEED' "$work/legacy/compose.yml" "$work/legacy/scripts/openctem-secrets"

# Validation.
check() { ansible-playbook tests/feed-proxy-checks.yml "$@" >/dev/null 2>&1; }
ok() { check -e "$fx" "$@" || { echo "expected to pass: $*" >&2; exit 1; }; }
no() { ! check -e "$fx" "$@" || { echo "expected to fail: $*" >&2; exit 1; }; }
ok
ok -e openctem_feed_proxy=http://proxy.corp.example:3128
ok -e openctem_feed_proxy=https://10.20.0.5:8443/
ok -e 'openctem_feed_proxy=http://[fd00::5]:3128'
ok -e openctem_feed_proxy=http://p:3128 -e openctem_feed_no_proxy=mirror.corp.example,.corp.example
no -e openctem_feed_proxy=http://user:pw@proxy.corp.example:3128     # credentials in the inventory
no -e openctem_feed_proxy=proxy.corp.example:3128                   # no scheme
no -e openctem_feed_proxy=socks5://proxy.corp.example:1080
no -e openctem_feed_proxy=http://proxy.corp.example:3128/path
no -e 'openctem_feed_no_proxy=a.example;rm'
# A release without the flag refuses the settings.
! ansible-playbook tests/feed-proxy-checks.yml -e openctem_feed_proxy=http://p:3128 >/dev/null 2>&1 || { echo "expected to fail without the release flag" >&2; exit 1; }
ansible-playbook tests/feed-proxy-checks.yml >/dev/null 2>&1 || { echo "unset must pass on any release" >&2; exit 1; }
echo "feed proxy tests passed"
