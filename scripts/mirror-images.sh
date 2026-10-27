#!/usr/bin/env bash
# Mirror every image a release needs into your own registry, preserving the
# digests that versions.yml pins. Use it when the OpenCTEM host cannot reach
# ghcr.io and docker.io (docs/INSTALL-SCENARIOS.md, scenarios B and C).
#
#   scripts/mirror-images.sh v0.15.2 registry.example.com/openctem registry.example.com/mirror
#   scripts/mirror-images.sh v0.15.2 127.0.0.1:5000/openctem 127.0.0.1:5000/mirror --dest-insecure
#
# Options:
#   --dry-run         print the skopeo commands, copy nothing
#   --dest-insecure   destination registry serves plain HTTP or a self-signed cert
#   --no-verify       skip the cosign check of the OpenCTEM images (not recommended)
#   --signatures      also copy the cosign signatures, so the host can verify too
#
# Runs on the controller, which needs skopeo and (unless --no-verify) cosign.
# The two mirror arguments are the values you then put in group_vars as
# openctem_registry_mirror and openctem_third_party_registry_mirror.
#
# --preserve-digests is not optional: without it skopeo may re-serialise a
# manifest, the digest changes, and every pull fails against versions.yml.
set -euo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions="$kit/versions.yml"

tag="${1:?usage: $0 vX.Y.Z <openctem-mirror> <third-party-mirror> [options]}"
oc_mirror="${2:?missing openctem mirror prefix, e.g. registry.example.com/openctem}"
tp_mirror="${3:?missing third-party mirror prefix, e.g. registry.example.com/mirror}"
shift 3

dry_run=no
dest_tls_args=()
verify=yes
copy_sigs=no
for opt in "$@"; do
	case "$opt" in
	--dry-run) dry_run=yes ;;
	--dest-insecure) dest_tls_args=(--dest-tls-verify=false) ;;
	--no-verify) verify=no ;;
	--signatures) copy_sigs=yes ;;
	*) echo "unknown option: $opt" >&2; exit 2 ;;
	esac
done

case "$tag" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "not a release tag: $tag" >&2; exit 2 ;; esac
if [ "$dry_run" = no ]; then
	command -v skopeo >/dev/null || { echo "skopeo is not installed" >&2; exit 2; }
	[ "$verify" = no ] || command -v cosign >/dev/null || { echo "cosign is not installed (or pass --no-verify)" >&2; exit 2; }
fi

# versions.yml is the single source of truth for what gets mirrored. PyYAML
# comes with Ansible, so a controller that can run this kit already has it.
plan_text="$(python3 - "$versions" "$tag" "$oc_mirror" "$tp_mirror" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML is missing: pip install pyyaml")

path, tag, oc_mirror, tp_mirror = sys.argv[1:5]
with open(path) as fh:
    v = yaml.safe_load(fh)

releases = v.get("openctem_releases", {})
if tag not in releases:
    sys.exit(f"{tag} is not a key of openctem_releases in versions.yml")


def split(ref):
    """'host/path:tag@sha256:...' -> (repo, tag or '', digest)."""
    head, _, digest = ref.partition("@")
    colon = head.find(":", head.rfind("/") + 1)
    if colon == -1:
        return head, "", digest
    return head[:colon], head[colon + 1:], digest


rows = []

# OpenCTEM images: the ghcr.io/openctemio prefix is swapped, the name kept.
# They are also the ones the host's cosign check covers.
for ref in releases[tag].values():
    if not isinstance(ref, str) or "@sha256:" not in ref:
        continue  # release flags (admin_plane, console_service, ...)
    repo, _, digest = split(ref)
    name = repo.rsplit("/", 1)[-1]
    rows.append(f"openctem\t{repo}@{digest}\t{oc_mirror.rstrip('/')}/{name}:{tag}")

# Third-party images: the registry host is replaced, the whole path kept, so
# docker.io/library/postgres is read from <mirror>/library/postgres.
for key in ("openctem_postgres_image", "openctem_redis_image",
            "openctem_rclone_image", "openctem_cosign_image", "cloudflared_image"):
    ref = v.get(key)
    if not ref:
        continue
    repo, image_tag, digest = split(ref)
    after_host = repo.split("/", 1)[1]
    dest = f"{tp_mirror.rstrip('/')}/{after_host}:{image_tag or 'mirrored'}"
    rows.append(f"third-party\t{repo}@{digest}\t{dest}")

if not rows:
    sys.exit("nothing to mirror: versions.yml held no image references")
print("\n".join(rows))
PY
)"
mapfile -t plan <<<"$plan_text"

identity="https://github.com/openctemio/openctem/.github/workflows/docker-publish.yml@refs/tags/$tag"
issuer="https://token.actions.githubusercontent.com"

echo "# release $tag: ${#plan[@]} images"
echo "# openctem_registry_mirror: $oc_mirror"
echo "# openctem_third_party_registry_mirror: $tp_mirror"
echo

for row in "${plan[@]}"; do
	IFS=$'\t' read -r kind src dest <<<"$row"

	# Verify upstream BEFORE copying: this is the one place that still reaches
	# sigstore. An air-gapped host cannot repeat it (see the doc's "Signatures").
	if [ "$verify" = yes ] && [ "$kind" = openctem ]; then
		if [ "$dry_run" = yes ]; then
			echo "cosign verify $src --certificate-identity '$identity' --certificate-oidc-issuer '$issuer'"
		else
			echo "verifying $src"
			cosign verify "$src" \
				--certificate-identity "$identity" \
				--certificate-oidc-issuer "$issuer" >/dev/null
		fi
	fi

	if [ "$dry_run" = yes ]; then
		echo "skopeo copy --all --preserve-digests ${dest_tls_args[*]-} docker://$src docker://$dest"
	else
		echo "copying  $src"
		echo "      -> $dest"
		skopeo copy --all --preserve-digests "${dest_tls_args[@]}" "docker://$src" "docker://$dest"
	fi

	# The host's cosign check looks the signature up on the mirror reference,
	# so it has to be copied too. Only useful when the host can still reach
	# sigstore's roots; otherwise keep openctem_verify_signatures: false.
	if [ "$copy_sigs" = yes ] && [ "$kind" = openctem ]; then
		dest_repo="${dest%:*}"
		if [ "$dry_run" = yes ]; then
			echo "cosign copy $src $dest_repo"
		else
			cosign copy "$src" "$dest_repo"
		fi
	fi
done

echo
echo "# done. Put these in your inventory's group_vars/all.yml:"
echo "openctem_registry_mirror: $oc_mirror"
echo "openctem_third_party_registry_mirror: $tp_mirror"
[ "$copy_sigs" = yes ] || echo "openctem_verify_signatures: false   # verified above, on this machine"
