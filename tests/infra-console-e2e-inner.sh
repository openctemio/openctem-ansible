#!/usr/bin/env bash
# Inside the DinD container of tests/infra-console-e2e.sh only.
set -euo pipefail
expected="${1:?usage: infra-console-e2e-inner.sh <dind container name>}"
[ -f /.dockerenv ] || { echo "not inside a container: refusing" >&2; exit 64; }
[ -z "${DOCKER_HOST:-}" ] || { echo "DOCKER_HOST is set: refusing" >&2; exit 64; }
[ "$(docker info --format '{{.Name}}')" = "$expected" ] && [ "$(hostname)" = "$expected" ] ||
	{ echo "not the DinD daemon: refusing" >&2; exit 64; }
mkdir -p /e2e/inv/group_vars

docker run -d --name ic-target -v /e2e:/e2e ubuntu:26.04 sleep infinity > /dev/null
docker exec ic-target bash -c 'apt-get update -qq > /dev/null && apt-get install -y -qq python3 sudo pamtester oathtool util-linux > /dev/null 2>&1'
t() { docker exec ic-target bash -c "$1"; }

cat > /e2e/inv/hosts.ini <<INV
[openctem]
target ansible_connection=community.docker.docker_api ansible_host=ic-target ansible_python_interpreter=/usr/bin/python3 ansible_become_exe=/usr/bin/sudo.ws
INV
cat > /e2e/inv/group_vars/all.yml <<VARS
apply_infra_console: true
infra_console_e2e: true
infra_console_listen_address: 127.0.0.1
infra_console_operators: [alice, carol]
infra_console_terminal: true
admin_cidrs: [192.0.2.0/24]
VARS

controller() {
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v /kit:/kit:ro -v /e2e:/e2e \
		-e ANSIBLE_COLLECTIONS_PATH=/kit/collections:/e2e/testcollections -e ANSIBLE_CONFIG=/kit/ansible.cfg \
		-e ANSIBLE_LOCAL_TEMP=/tmp/ansible -e ANSIBLE_FORCE_COLOR=0 -w /kit python:3.13-slim bash -c "
		set -e
		pip install -q 'ansible-core>=2.18,<2.19' 'requests' 'docker' > /dev/null 2>&1
		$1"
}
controller "ansible-galaxy collection install community.docker:5.4.0 -p /e2e/testcollections > /dev/null"

play() { # <log>
	controller "ansible-playbook -i /e2e/inv/hosts.ini playbooks/65-infra-console.yml $2" > "$1" || true
	grep -E 'PLAY RECAP' -A1 "$1" | tail -1
	grep -q 'failed=0' "$1" || { tail -n 60 "$1"; exit 1; }
}

echo "== apply"
play /e2e/run1.log ''
echo "== idempotence"
play /e2e/run2.log ''
grep -A1 'PLAY RECAP' /e2e/run2.log | tail -1 | grep -q 'changed=0' || { grep -B2 -E '^changed:' /e2e/run2.log | head -40; exit 1; }

echo "== settings on the host"
t 'grep -qx "ListenStream=" /etc/systemd/system/cockpit.socket.d/listen.conf'
t 'grep -qx "ListenStream=127.0.0.1:9090" /etc/systemd/system/cockpit.socket.d/listen.conf'
t '[ "$(grep -c "^ListenStream=" /etc/systemd/system/cockpit.socket.d/listen.conf)" = 2 ]'
t 'grep -q "^LoginTo = false" /etc/cockpit/cockpit.conf && grep -q "^AllowMultiHost = false" /etc/cockpit/cockpit.conf'
t 'grep -qx root /etc/cockpit/disallowed-users'
t '[ ! -e /etc/cockpit/systemd.override.json ]'  # terminal on in this run
t '[ "$(getent passwd alice | cut -d: -f7)" = /usr/bin/tlog-rec-session ]'
t '[ "$(stat -c %a:%U /var/lib/openctem-console/totp)" = 700:root ]'
t 'visudo -cf /etc/sudoers.d/60-openctem-operators > /dev/null && ! grep -q NOPASSWD /etc/sudoers.d/60-openctem-operators'
t 'passwd -S alice | grep -qE "^alice L"'  # no usable password before enrolment

echo "== enrolment (the real command, on a terminal)"
pw='Corr3ct-Horse-Battery-9!'
enrol() {
	t "(sleep 2; printf '%s\n' '$pw'; sleep 1; printf '%s\n' '$pw') | script -qec 'openctem-console-enroll $1' /dev/null" > "/e2e/enrol-$1.log"
	sed -n 's/^Secret: \([A-Z2-7]*\).*/\1/p' "/e2e/enrol-$1.log" | tr -d '\r'
}
alice_secret="$(enrol alice)"
[ -n "$alice_secret" ] || { cat /e2e/enrol-alice.log; exit 1; }
t '[ "$(stat -c %a:%U /var/lib/openctem-console/totp/alice)" = 400:root ]'
t 'passwd -S alice | grep -qE "^alice P"'
t "openctem-console-enroll alice < /dev/null" 2> /dev/null && { echo "enrolment without a terminal was accepted"; exit 1; }
t "openctem-console-enroll bob < /dev/null" 2> /dev/null && { echo "enrolment of a non-operator was accepted"; exit 1; }

code() { t "oathtool --totp -b -N '$2' '$1'"; } # <secret> <time>
signin() { # <user> <password> <code>: rc of the full console sign-in (auth + account)
	t "printf '%s\n%s\n' '$2' '$3' | pamtester cockpit '$1' authenticate acct_mgmt" > /dev/null 2>&1
}
expect() { # <want ok|refused> <name> <user> <password> <code>
	local got=refused
	signin "$3" "$4" "$5" && got=ok
	[ "$got" = "$1" ] && echo "ok    $1  $2" || { echo "WRONG $got (wanted $1)  $2"; exit 1; }
}

echo "== sign-in"
# Each accepted code is used once (DISALLOW_REUSE): neighbouring 30 s steps
# inside the window keep the cases independent.
expect refused "operator, wrong code" alice "$pw" 000000
expect refused "operator, wrong password, valid code" alice wrong-password "$(code "$alice_secret" now)"
expect ok "operator, password and code" alice "$pw" "$(code "$alice_secret" '30 seconds ago')"
expect refused "operator, code reused" alice "$pw" "$(code "$alice_secret" '30 seconds ago')"
expect refused "operator, password only" alice "$pw" ""
# carol is listed but never enrolled: no password, no secret.
expect refused "operator not enrolled" carol "" 123456
# bob has a password and a valid secret but is not in the operators group.
t "useradd -m bob && printf 'bob:%s\n' '$pw' | chpasswd && printf '%s\n\" TOTP_AUTH\n' '$alice_secret' > /var/lib/openctem-console/totp/bob && chmod 0400 /var/lib/openctem-console/totp/bob"
expect refused "not in the operators group" bob "$pw" "$(code "$alice_secret" '30 seconds')"
t "printf 'root:%s\n' '$pw' | chpasswd"
expect refused "root" root "$pw" 000000

echo "== off-boarding: alice removed from the list"
sed -i 's/^infra_console_operators: .*/infra_console_operators: [carol]/' /e2e/inv/group_vars/all.yml
play /e2e/run3.log ''
t '! id -nG alice | tr " " "\n" | grep -qx openctem-operators'
t '[ ! -e /var/lib/openctem-console/totp/alice ]'
expect refused "removed operator" alice "$pw" "$(code "$alice_secret" '60 seconds')"

echo "== terminal off removes its menu entry"
play /e2e/run4.log '-e infra_console_terminal=false'
t 'grep -q "\"terminal\": null" /etc/cockpit/systemd.override.json'

echo "== absent"
play /e2e/run5.log '-e infra_console_state=absent'
