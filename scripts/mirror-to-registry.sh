#!/usr/bin/env bash
# Mirror a release into a registry you already run, and prove the digests
# survived the push.
#
# scripts/mirror-images.sh does the copying. This wraps it with the three
# things a first run usually gets wrong:
#
#   - cosign is not skipped for convenience. When it is not installed, it runs
#     from the image versions.yml already pins, so nothing is downloaded and
#     the verification still happens.
#   - nothing is written to the registry before you have seen the plan.
#   - every image is read back from the destination BY THE DIGEST versions.yml
#     pins. A push that re-serialises a manifest changes the digest; the copy
#     still reports success, and the failure surfaces much later, on the host,
#     as a pull that cannot find an image that is plainly sitting there.
#
# Use it for a registry the OpenCTEM host can already reach: Harbor, Nexus,
# Artifactory, a cloud registry, or the loopback registry of option B1 in
# docs/INSTALL-SCENARIOS.md. docs/CORPORATE-REGISTRY.md is the walkthrough.
#
#   scripts/mirror-to-registry.sh v0.17.0 registry.example.com
#   scripts/mirror-to-registry.sh v0.17.0 registry.example.com:5000 --insecure
#
# Options:
#   --insecure     the registry serves plain HTTP or a self-signed certificate
#   --no-verify    skip the cosign check (read the doc before you do)
#   --signatures   copy the signatures too, so the host can verify as well
#   --yes          do not ask before copying
#
# Environment:
#   OC_PROJECT   repository prefix for the OpenCTEM images   (default: openctem)
#   TP_PROJECT   repository prefix for the third-party ones  (default: openctem-3p)
#
# Runs on the controller, which needs skopeo and the network. Never on the
# OpenCTEM host.
set -euo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tag="${1:?usage: $0 vX.Y.Z <registry-host> [options]}"
registry="${2:?missing registry host, e.g. registry.example.com}"
shift 2

oc_mirror="$registry/${OC_PROJECT:-openctem}"
tp_mirror="$registry/${TP_PROJECT:-openctem-3p}"

insecure=no
assume_yes=no
pass_through=()
for opt in "$@"; do
	case "$opt" in
	--insecure) insecure=yes; pass_through+=(--dest-insecure) ;;
	--no-verify | --signatures) pass_through+=("$opt") ;;
	--yes) assume_yes=yes ;;
	*) echo "unknown option: $opt" >&2; exit 2 ;;
	esac
done

# Reading the destination back needs the same TLS exception as writing it.
tls_args=()
[ "$insecure" = no ] || tls_args=(--tls-verify=false)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

# --- The release has to exist in this checkout --------------------------------
# A kit that predates the tag renders an older stack without saying so, so this
# is a hard stop rather than a warning.
grep -q "^  ${tag//./\.}:" "$kit/versions.yml" ||
	die "$tag is not in $kit/versions.yml; update the kit first (git pull)"

command -v skopeo >/dev/null ||
	die "skopeo is not installed (dnf install skopeo / apt-get install skopeo)"

# --- cosign without installing cosign -----------------------------------------
# The verification is the one step that still reaches sigstore, and it can only
# happen here, on the machine with the network. Rather than let a missing
# binary turn into --no-verify, run it from the image versions.yml pins, the
# same one roles/openctem/tasks/signatures.yml uses on the host.
case " ${pass_through[*]-} " in
*" --no-verify "*) ;;
*)
	if ! command -v cosign >/dev/null; then
		cosign_image="$(sed -n 's/^openctem_cosign_image: *//p' "$kit/versions.yml")"
		[ -n "$cosign_image" ] || die "no openctem_cosign_image in $kit/versions.yml"
		command -v docker >/dev/null ||
			die "neither cosign nor docker is available; install one, or pass --no-verify"
		shim="$(mktemp -d)"
		trap 'rm -rf "$shim"' EXIT
		cat >"$shim/cosign" <<EOF
#!/usr/bin/env bash
exec docker run --rm --network host -e HOME=/tmp $cosign_image "\$@"
EOF
		chmod +x "$shim/cosign"
		PATH="$shim:$PATH"
		say "cosign runs from $cosign_image"
	fi
	;;
esac

# --- Credentials --------------------------------------------------------------
# Read from the terminal by skopeo itself, so the password reaches neither the
# process list nor the shell history.
if ! skopeo login "${tls_args[@]}" --get-login "$registry" >/dev/null 2>&1; then
	say "log in to $registry (an account with push rights)"
	skopeo login "${tls_args[@]}" "$registry"
fi

# --- Preview ------------------------------------------------------------------
# Through bash, not as a command: mirror-images.sh is mode 644 in the repository,
# and a kit unpacked from an archive loses the executable bit anyway.
say "plan"
plan="$(bash "$kit/scripts/mirror-images.sh" "$tag" "$oc_mirror" "$tp_mirror" \
	${pass_through[@]+"${pass_through[@]}"} --dry-run)"
printf '%s\n' "$plan"

if [ "$assume_yes" = no ]; then
	printf '\nBoth repository prefixes must already exist on the registry.\n'
	read -rp "Copy now? [y/N] " reply
	case "$reply" in
	y | Y) ;;
	*) echo "nothing copied."; exit 0 ;;
	esac
fi

# --- Copy ---------------------------------------------------------------------
say "copying"
bash "$kit/scripts/mirror-images.sh" "$tag" "$oc_mirror" "$tp_mirror" \
	${pass_through[@]+"${pass_through[@]}"}

# --- The check that matters ---------------------------------------------------
# Ask the destination for each image the way the host will: by the digest
# versions.yml pins, not by the tag it was pushed under. A manifest that was
# re-serialised on the way in answers the tag and not the digest, which is
# exactly the failure this catches -- here, where it is still cheap.
say "reading every image back by its pinned digest"
failed=0
while IFS= read -r line; do
	case "$line" in *"skopeo copy"*) ;; *) continue ;; esac
	dest="${line##*docker://}"; dest="${dest%% *}"        # right-hand ref
	rest="${line% docker://*}"; src="${rest##*docker://}" # left-hand ref, has @sha256
	ref="${dest%:*}@${src##*@}"                           # drop :tag, keep :port
	if skopeo inspect "${tls_args[@]}" --raw "docker://$ref" >/dev/null 2>&1; then
		printf '  ok      %s\n' "$ref"
	else
		printf '  MISSING %s\n' "$ref"
		failed=1
	fi
done <<<"$plan"

[ "$failed" = 0 ] ||
	die "the registry does not serve every image by its pinned digest; do not deploy this"

# --- What to do with it -------------------------------------------------------
cat <<EOF

== done

With Ansible, in the inventory's group_vars/all.yml:

  openctem_registry_mirror: $oc_mirror
  openctem_third_party_registry_mirror: $tp_mirror
EOF
case " ${pass_through[*]-} " in
*" --signatures "*) ;;
*) echo "  openctem_verify_signatures: false   # verified here, where sigstore is reachable" ;;
esac
cat <<EOF

Without Ansible, against a directory from scripts/render-standalone.yml:

  scripts/compose-use-mirror.sh /opt/openctem/compose.yml $registry
EOF
