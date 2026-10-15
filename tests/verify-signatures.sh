#!/usr/bin/env bash
# Verifies the keyless cosign signature of every OpenCTEM image digest in
# versions.yml against the release workflow's identity at its tag, inside an
# isolated Docker-in-Docker (same safety model as tests/smoke.sh).
#   tests/verify-signatures.sh
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="$(date +%s)-$$"
dind="octsig-dind-$id"
case "${DOCKER_HOST:-}" in "" | unix:///var/run/docker.sock | unix:///run/docker.sock) ;; *) echo "unset DOCKER_HOST" >&2; exit 64 ;; esac
echo "local daemon: used ONLY to create/remove $dind"
trap 'docker rm -f "$dind" > /dev/null 2>&1 || true' EXIT
docker run -d --rm --privileged --name "$dind" --hostname "$dind" -e DOCKER_TLS_CERTDIR= "${DIND_IMAGE:-docker:28-dind}" > /dev/null
for _ in $(seq 1 60); do docker exec "$dind" docker info > /dev/null 2>&1 && break; sleep 1; done
[ "$(docker exec "$dind" docker info --format '{{.Name}}')" = "$dind" ] || { echo "not the DinD daemon" >&2; exit 64; }
cosign="$(sed -n 's/^openctem_cosign_image: *//p' "$kit/versions.yml")"
fail=0
current=""
while IFS= read -r line; do
	case "$line" in
	"  v"*":") current="${line%:}"; current="${current# }"; current="${current# }" ;;
	"    "*": ghcr.io/"*)
		ref="${line#*: }"
		if docker exec "$dind" docker run --rm "$cosign" verify "$ref" \
			--certificate-identity "https://github.com/openctemio/openctem/.github/workflows/docker-publish.yml@refs/tags/$current" \
			--certificate-oidc-issuer https://token.actions.githubusercontent.com > /dev/null 2>&1; then
			echo "OK   $current $ref"
		else
			echo "FAIL $current $ref"; fail=1
		fi ;;
	esac
done < <(sed -n '/^openctem_releases:/,/^[^ #]/p' "$kit/versions.yml")
# Negative: the newest api digest must NOT verify under another tag's identity.
newest_api="$(sed -n '/^openctem_releases:/,/^[^ #]/p' "$kit/versions.yml" | sed -n 's/^    api: //p' | head -n 1)"
if docker exec "$dind" docker run --rm "$cosign" verify "$newest_api" \
	--certificate-identity "https://github.com/openctemio/openctem/.github/workflows/docker-publish.yml@refs/tags/v0.0.0" \
	--certificate-oidc-issuer https://token.actions.githubusercontent.com > /dev/null 2>&1; then
	echo "FAIL identity not enforced: $newest_api verified under tag v0.0.0"; fail=1
else
	echo "OK   wrong tag identity is refused"
fi
exit "$fail"
