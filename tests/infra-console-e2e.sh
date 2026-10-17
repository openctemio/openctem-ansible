#!/usr/bin/env bash
# Runs the REAL infrastructure console role (playbooks/65-infra-console.yml)
# against an Ubuntu 26.04 container inside an isolated Docker-in-Docker, then
# proves the sign-in rules with pamtester: password AND one-time code for
# operators only; root, non-members, a wrong code and removed operators are
# refused. Same safety model as tests/role-e2e.sh: the local daemon only
# creates/removes one uniquely named DinD container and network; the only
# bind mount is this kit, read-only. systemd, ufw and auditd are not in a
# container: those tasks are skipped (infra_console_e2e) and covered by the
# render test and a real host.
#
#   tests/infra-console-e2e.sh
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dind_image="${DIND_IMAGE:-docker:28-dind}"
id="$(date +%s)-$$"
dind="octic-dind-$id"
net="octic-net-$id"
case "${DOCKER_HOST:-}" in
"" | unix:///var/run/docker.sock | unix:///run/docker.sock) ;;
*) echo "DOCKER_HOST=$DOCKER_HOST: unset it" >&2; exit 64 ;;
esac
[ -d "$kit/collections/ansible_collections" ] || { echo "install the collections first (requirements.yml)" >&2; exit 64; }
echo "local daemon ($(docker context show 2>/dev/null || echo default)): used ONLY to create/remove $dind and $net"
cleanup() {
	[ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: left $dind and $net"; return; }
	docker rm -f "$dind" > /dev/null 2>&1 || true
	docker network rm "$net" > /dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$net" > /dev/null
docker run -d --rm --privileged --name "$dind" --hostname "$dind" --network "$net" \
	-e DOCKER_TLS_CERTDIR= -v "$kit:/kit:ro" "$dind_image" > /dev/null
for _ in $(seq 1 60); do docker exec "$dind" docker info > /dev/null 2>&1 && break; sleep 1; done
docker exec "$dind" sh -c 'apk add --no-cache bash > /dev/null'
docker exec "$dind" bash /kit/tests/infra-console-e2e-inner.sh "$dind"
echo "== infrastructure console e2e passed"
