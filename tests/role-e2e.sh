#!/usr/bin/env bash
# Runs the REAL roles (playbooks/50-openctem.yml: deploy, idempotence, an
# upgrade between the two newest releases, then playbooks/71-rollback.yml) against an Ubuntu 26.04 container, all inside an
# isolated Docker-in-Docker. Same safety model as tests/smoke.sh: the local
# daemon only creates/removes one uniquely named DinD container and network;
# the only bind mount is this kit, read-only.
#
#   tests/role-e2e.sh
#
# The connection plugin community.docker is a test-only dependency: it is
# installed inside DinD, not in requirements.yml.
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dind_image="${DIND_IMAGE:-docker:28-dind}"
# Upgrade path tested: the two newest releases in versions.yml.
mapfile -t rels < <(sed -n 's/^  \(v[0-9][0-9.]*\):$/\1/p' "$kit/versions.yml" | sort -V | tail -n 2)
[ "${#rels[@]}" = 2 ] || { echo "versions.yml needs two releases for the upgrade test" >&2; exit 64; }
id="$(date +%s)-$$"
dind="octe2e-dind-$id"
net="octe2e-net-$id"
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
echo "upgrade path: ${rels[0]} -> ${rels[1]}"
docker exec "$dind" bash /kit/tests/role-e2e-inner.sh "$dind" "${rels[0]}" "${rels[1]}"
echo "== role e2e passed"
