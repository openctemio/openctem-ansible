#!/usr/bin/env bash
# End-to-end smoke test of the rendered stack, ISOLATED in Docker-in-Docker.
#
#   tests/smoke.sh
#
# Safety model (read before changing this file):
# - The Docker daemon of the machine running this script is used for exactly
#   three things: create ONE privileged docker:dind container and ONE network,
#   both with a unique generated name, copy files into that container, and
#   remove both at the end. No host socket, docker binary or host directory is
#   mounted into any container; the only bind mount is this kit, read-only.
# - Every test workload (the stack, its volumes, the Ubuntu 26.04 helper
#   containers) runs on the DinD container's OWN daemon and storage, driven by
#   tests/smoke-inner.sh, which refuses to start unless the daemon it talks to
#   is that DinD daemon, and which calls compose only with an explicit project
#   name and file list.
#
# Steps: render the templates on this machine (tests/render.yml, no Docker),
# copy them into DinD, then inside DinD: secrets with the role's script in an
# Ubuntu 26.04 container (uutils), stack up (no cloudflared: no real token),
# openctem-verify, the trusted-proxy check, backups in local and age mode,
# restore drill, full restore, verify again; then continuous archiving against
# a fake S3 bucket (rclone serve s3 in DinD): base backup, WAL upload, a
# point-in-time drill, and a point-in-time restore that must bring back the
# state between two marked transactions.
#
# Env: ANSIBLE_PLAYBOOK (default ansible-playbook), DIND_IMAGE, KEEP=1 keeps
# the DinD container for inspection (remove it yourself by its printed name).
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ap="${ANSIBLE_PLAYBOOK:-ansible-playbook}"
dind_image="${DIND_IMAGE:-docker:28-dind}"
id="$(date +%s)-$$"
dind="octsmoke-dind-$id"
net="octsmoke-net-$id"
render="$(mktemp -d "${TMPDIR:-/tmp}/octsmoke-render.XXXXXX")"
version="$(sed -n 's/^openctem_version: *//p' "$kit/tests/vars.yml")"

case "${DOCKER_HOST:-}" in
"" | unix:///var/run/docker.sock | unix:///run/docker.sock) ;;
*) echo "DOCKER_HOST=$DOCKER_HOST: unset it; this script talks to the local daemon only to create its DinD container" >&2; exit 64 ;;
esac
echo "local daemon ($(docker context show 2>/dev/null || echo default)): used ONLY to create/remove $dind and $net"

cleanup() {
	rm -rf -- "$render"
	if [ "${KEEP:-0}" = 1 ]; then
		echo "KEEP=1: left $dind and $net running"
		return
	fi
	docker rm -f "$dind" > /dev/null 2>&1 || true
	docker network rm "$net" > /dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== render $version (no Docker)"
"$ap" "$kit/tests/render.yml" -e "render_dir=$render" -e openctem_root=/work -e openctem_project=octsmoke \
	-e openctem_state_dir=/work/state -e backup_dir=/work/backups -e backup_state_dir=/work/bstate \
	-e openctem_app_host=ctem.example.com \
	-e openctem_wal_archive=true -e openctem_wal_spool_dir=/work/wal-spool -e backup_wal_bucket=smoke-bucket \
	-e backup_wal_remote_conf=/work/secrets/backup_remote.conf < /dev/null > "$render/render.log" 2>&1 || { tail -n 30 "$render/render.log"; exit 1; }

echo "== start isolated DinD ($dind_image)"
docker network create --internal=false "$net" > /dev/null
docker run -d --rm --privileged --name "$dind" --hostname "$dind" --network "$net" \
	-e DOCKER_TLS_CERTDIR= -v "$kit:/kit:ro" "$dind_image" > /dev/null
for _ in $(seq 1 60); do docker exec "$dind" docker info > /dev/null 2>&1 && break; sleep 1; done
docker exec "$dind" sh -c 'apk add --no-cache bash coreutils > /dev/null'
docker exec "$dind" mkdir -p /work
docker cp "$render/." "$dind:/work/render/"
docker exec "$dind" bash /kit/tests/smoke-inner.sh "$dind" "$version"
echo "== smoke test passed"
