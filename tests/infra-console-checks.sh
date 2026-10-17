#!/usr/bin/env bash
# Every unsafe infrastructure-console setting is refused, the safe ones pass.
# Runs on the controller only and changes nothing (tests/infra-console-checks.yml).
#   tests/infra-console-checks.sh
set -uo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$kit" || exit 64
fails=0
run() { # <expect: pass|fail> <name> <extra vars as JSON>
	local want="$1" name="$2" vars="$3" got out
	out="$(ansible-playbook tests/infra-console-checks.yml -e "$vars" < /dev/null 2>&1)"
	if [ $? = 0 ]; then got=pass
	# A refusal is a failed check task, not a broken run.
	elif grep -q "^fatal: \[localhost\]" <<< "$out"; then got=fail
	else echo "$out" | grep -E "ERROR|fatal|msg" | head -n 5; got=error; fi
	if [ "$got" = "$want" ]; then echo "ok    $want  $name"; else echo "WRONG $got (wanted $want)  $name"; fails=$((fails + 1)); fi
}
tmp="$(mktemp -d)"
trap 'find "$tmp" -delete' EXIT
touch "$tmp/c.pem" "$tmp/k.pem"

run pass "loopback, one operator" '{"infra_console_port": 9090}'
run pass "terminal on (recording follows it)" '{"infra_console_terminal": true}'
run pass "own certificate present" "{\"infra_console_tls_cert\": \"$tmp/c.pem\", \"infra_console_tls_key\": \"$tmp/k.pem\"}"
run pass "absent needs no settings" '{"infra_console_state": "absent", "infra_console_listen_address": "", "infra_console_operators": []}'
run fail "state unknown" '{"infra_console_state": "on"}'
run fail "no listen address" '{"infra_console_listen_address": ""}'
run fail "every address" '{"infra_console_listen_address": "0.0.0.0"}'
run fail "not an address" '{"infra_console_listen_address": "console"}'
run fail "not this host" '{"infra_console_listen_address": "192.0.2.77"}'
run fail "public address" '{"infra_console_listen_address": "8.8.8.8"}'
run fail "SSH port" '{"infra_console_port": 22}'
run fail "port out of range" '{"infra_console_port": 70000}'
run fail "open to the internet" '{"infra_console_allowed_cidrs": ["0.0.0.0/0"]}'
run fail "no allowed networks" '{"infra_console_allowed_cidrs": []}'
run fail "address without prefix" '{"infra_console_allowed_cidrs": ["192.0.2.1"]}'
run fail "no operators" '{"infra_console_operators": []}'
run fail "root as operator" '{"infra_console_operators": ["root"]}'
run fail "automation account as operator" '{"ansible_user": "deploy", "infra_console_operators": ["deploy"]}'
run fail "bad account name" '{"infra_console_operators": ["Alice Smith"]}'
run fail "shared admin group" '{"infra_console_operators_group": "sudo"}'
run fail "docker group" '{"infra_console_operators_group": "docker"}'
run fail "terminal without recording" '{"infra_console_terminal": true, "infra_console_session_recording": false}'
run fail "certificate without key" "{\"infra_console_tls_cert\": \"$tmp/c.pem\"}"
run fail "certificate missing on host" '{"infra_console_tls_cert": "/nonexistent/c.pem", "infra_console_tls_key": "/nonexistent/k.pem"}'
run fail "bad server name" '{"infra_console_server_names": ["bad name"]}'
run fail "no idle timeout" '{"infra_console_idle_timeout_minutes": 0}'
bridge="$(ip -4 -o addr show docker0 2> /dev/null | awk '{print $4}' | cut -d/ -f1)"
if [ -n "$bridge" ]; then run fail "container bridge address" "{\"infra_console_listen_address\": \"$bridge\"}"; fi

[ "$fails" = 0 ] || { echo "$fails case(s) wrong" >&2; exit 1; }
echo "== infrastructure console checks passed"
