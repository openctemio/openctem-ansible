#!/usr/bin/env bash
# The first-admin tool runs as a one-shot container with the schema owner's
# password, which the API never sees; the monitor never puts its webhook URL on
# a command line. Static checks of the rendered files, no Docker daemon needed.
#   ansible-playbook tests/render.yml -e render_dir=$dir && tests/bootstrap-admin.sh $dir
set -euo pipefail
r="${1:?usage: $0 <render dir>}"
tmp="$(mktemp -d)"
trap 'find "$tmp" -delete' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Compose service: tools profile, hardened, owner env file, no log driver, no ports.
python3 - "$r/compose.yml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
s = c["services"]["bootstrap-admin"]
def need(cond, msg):
    if not cond:
        sys.exit("FAIL: bootstrap-admin " + msg)
need(s["profiles"] == ["tools"], "not in the tools profile")
need(s["entrypoint"] == ["/app/bootstrap-admin"], "entrypoint")
need(s["image"] == c["services"]["api"]["image"], "not the API image")
need(s["logging"] == {"driver": "none"}, "logs are kept")
need(s["read_only"] is True and s["cap_drop"] == ["ALL"], "not hardened")
need("no-new-privileges:true" in s["security_opt"], "no-new-privileges missing")
need(s["networks"] == ["data"] and "ports" not in s, "network or ports")
need(len(s["env_file"]) == 1 and s["env_file"][0].endswith("/bootstrap-admin.env"), "env file")
need(s["environment"]["DB_MIGRATE_USER"] == "openctem_migrator", "not the schema owner")
for k in c["services"]["api"]["env_file"]:
    need(not k.endswith("bootstrap-admin.env") and not k.endswith("migrate.env"), "API reads the owner credentials")
PY

# Wrapper: a one-shot run, never exec into the running API.
w="$r/scripts/openctem-bootstrap-admin"
grep -q 'run --rm --no-deps bootstrap-admin' "$w" || fail "wrapper does not run the one-shot service"
! grep -q 'exec api' "$w" || fail "wrapper still execs into the API"
grep -q '! -t 0' "$w" || fail "wrapper lost its terminal requirement"

# Secrets: the owner password reaches bootstrap-admin.env only, never api.env.
mkdir -m 0700 "$tmp/sec"
sed "s|^d='.*'|d='$tmp/sec'|" "$r/scripts/openctem-secrets" > "$tmp/s.sh"
sh "$tmp/s.sh" > /dev/null
pw="$(cat "$tmp/sec/db_migrate_password")"
grep -qx "DB_MIGRATE_PASSWORD=$pw" "$tmp/sec/bootstrap-admin.env" || fail "bootstrap-admin.env lacks the owner password"
grep -q '^APP_ENCRYPTION_KEY=' "$tmp/sec/bootstrap-admin.env" || fail "bootstrap-admin.env lacks APP_ENCRYPTION_KEY"
! grep -q "$pw" "$tmp/sec/api.env" || fail "the owner password is in api.env"
[ "$(stat -c %a "$tmp/sec/bootstrap-admin.env")" = 400 ] || fail "bootstrap-admin.env is not 0400"

# Monitor: the URL is never an argument; quoting survives a quote in the URL.
m="$r/scripts/openctem-monitor"
grep -n 'curl ' "$m" | grep -q 'WEBHOOK_URL' && fail "curl gets the webhook URL on its command line"
grep -q 'curl .*-K -' "$m" || fail "curl does not read its config from stdin"
url="https://hooks.example/x'y\"z\\w?t=1"
# The role renders WEBHOOK_URL={{ url | quote }}; a root-sourced file must read it back unchanged.
python3 - "$url" "$tmp/monitor.env" <<'PY'
import sys
from ansible.plugins.filter.core import FilterModule
quote = FilterModule().filters()["quote"]
open(sys.argv[2], "w").write("WEBHOOK_URL=" + quote(sys.argv[1]) + "\n")
PY
got="$(bash -c '. "$1"; printf %s "$WEBHOOK_URL"' _ "$tmp/monitor.env")"
[ "$got" = "$url" ] || fail "quoted URL does not round-trip: $got"
# The escaping lines of the monitor produce one valid curl config line.
sed -n '/^\t\turl=\${WEBHOOK_URL/,/^\t\tprintf .url = /p' "$m" | sed '$s/ *|$//' > "$tmp/esc.part"
[ -s "$tmp/esc.part" ] || fail "escaping lines not found"
cfg="$(WEBHOOK_URL="$url" bash -c "$(cat "$tmp/esc.part")")"
[ "$cfg" = 'url = "https://hooks.example/x'"'"'y\"z\\w?t=1"' ] || fail "curl config line wrong: $cfg"
echo "bootstrap-admin and monitor checks passed"
