#!/usr/bin/env bash
# Inside the DinD container of tests/role-e2e.sh only.
set -euo pipefail
expected="${1:?usage: role-e2e-inner.sh <dind container name> <from release> <to release>}"
from="${2:?from release}"
to="${3:?to release}"
[ -f /.dockerenv ] || { echo "not inside a container: refusing" >&2; exit 64; }
[ -z "${DOCKER_HOST:-}" ] || { echo "DOCKER_HOST is set: refusing" >&2; exit 64; }
[ "$(docker info --format '{{.Name}}')" = "$expected" ] && [ "$(hostname)" = "$expected" ] ||
	{ echo "not the DinD daemon: refusing" >&2; exit 64; }
echo "daemon: $expected (DinD, isolated storage)"
root=/e2e/opt
mkdir -p /e2e/inv/group_vars "$root"

# Target: Ubuntu 26.04 (python3.14, classic sudo as sudo.ws, uutils), with
# the DinD daemon's socket and CLI as its "host" Docker.
docker run -d --name e2e-target -v /var/run/docker.sock:/var/run/docker.sock \
	-v /usr/local/bin/docker:/usr/bin/docker:ro -v /usr/local/libexec/docker/cli-plugins:/usr/libexec/docker/cli-plugins:ro \
	-v /e2e:/e2e ubuntu:26.04 sleep infinity > /dev/null
docker exec e2e-target bash -c 'apt-get update -qq > /dev/null && apt-get install -y -qq python3 sudo openssl ca-certificates > /dev/null 2>&1'

cat > /e2e/inv/hosts.ini <<INV
[openctem]
target ansible_connection=community.docker.docker_api ansible_host=e2e-target ansible_python_interpreter=/usr/bin/python3.14 ansible_become_exe=/usr/bin/sudo.ws
INV
cat > /e2e/inv/group_vars/all.yml <<VARS
openctem_app_host: ctem.example.com
openctem_version: $from
openctem_ingress: loopback
openctem_root: $root
openctem_project: e2e
openctem_backup_before_upgrade: false
apply_openctem: true
apply_rollback: true
VARS

# Controller: Python 3.13 + ansible-core 2.18 (the supported pair), the kit
# read-only, the pinned collections from the kit plus community.docker.
controller() {
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v /kit:/kit:ro -v /e2e:/e2e \
		-e ANSIBLE_COLLECTIONS_PATH=/kit/collections:/e2e/testcollections -e ANSIBLE_CONFIG=/kit/ansible.cfg \
		-e ANSIBLE_LOCAL_TEMP=/tmp/ansible -e ANSIBLE_FORCE_COLOR=0 -w /kit python:3.13-slim bash -c "
		set -e
		pip install -q 'ansible-core>=2.18,<2.19' 'requests' 'docker' > /dev/null 2>&1
		$1"
}
controller "ansible-galaxy collection install community.docker:5.4.0 -p /e2e/testcollections > /dev/null"

echo "== first deploy"
controller "ansible-playbook -i /e2e/inv/hosts.ini playbooks/50-openctem.yml" > /e2e/run1.log || true
grep -E 'PLAY RECAP' -A1 /e2e/run1.log | tail -1
grep -q 'failed=0' /e2e/run1.log || { tail -n 60 /e2e/run1.log; exit 1; }
grep -q 'unreachable=0' /e2e/run1.log

echo "== idempotence: second run changes nothing in the stack"
controller "ansible-playbook -i /e2e/inv/hosts.ini playbooks/50-openctem.yml" > /e2e/run2.log || true
grep -E 'PLAY RECAP' -A1 /e2e/run2.log | tail -1
grep -q 'failed=0' /e2e/run2.log || { tail -n 60 /e2e/run2.log; exit 1; }
if [ -e "$root/compose.prev.yml" ]; then echo "an unchanged redeploy created a rollback target"; exit 1; fi

echo "== secret files on the target: modes and numeric owners"
docker exec e2e-target bash -c "stat -c '%a %u:%g %n' $root/secrets $root/secrets/* | sort -k3"

echo "== upgrade $from -> $to (job signer on as well), then rollback"
sed -i "s/^openctem_version: .*/openctem_version: $to/" /e2e/inv/group_vars/all.yml
echo 'openctem_job_signer: true' >> /e2e/inv/group_vars/all.yml
controller "ansible-playbook -i /e2e/inv/hosts.ini playbooks/50-openctem.yml" > /e2e/run3.log || true
grep -q 'failed=0' /e2e/run3.log || { tail -n 60 /e2e/run3.log; exit 1; }
[ "$(cat "$root/state/deployed-version")" = "$to" ] || { echo "deployed-version not $to"; exit 1; }
grep -q "^# OpenCTEM $to\." "$root/compose.yml"
grep -q 'openctem-signer' "$root/compose.yml"
echo "  upgraded to $to, verify passed"
controller "ansible-playbook -i /e2e/inv/hosts.ini playbooks/71-rollback.yml" > /e2e/run4.log || true
grep -q 'failed=0' /e2e/run4.log || { tail -n 60 /e2e/run4.log; exit 1; }
if grep -q 'openctem-signer' "$root/compose.yml"; then echo "rollback did not restore the previous compose file"; exit 1; fi
[ "$(cat "$root/state/deployed-version")" = "$from" ] || { echo "deployed-version not $from after rollback"; exit 1; }
grep -E 'Rolled back' /e2e/run4.log | head -1
