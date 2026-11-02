#!/usr/bin/env bash
# Point a rendered compose.yml at a registry mirror, keeping every digest.
#
# The Ansible path does this with openctem_registry_mirror and
# openctem_third_party_registry_mirror. A directory rendered by
# scripts/render-standalone.yml is run without Ansible and has no variables
# left to set, so the image references are rewritten in place instead. The two
# substitutions are the ones roles/openctem_common/defaults/main.yml defines:
#
#   ghcr.io/openctemio/NAME  ->  <registry>/<oc-project>/NAME
#       the prefix is replaced, the image name kept
#   docker.io/PATH           ->  <registry>/<tp-project>/PATH
#       the registry host is replaced, the whole path kept
#
# Digests are never touched, and the script refuses to leave the file changed
# if any of them moved: the digest is the only thing standing between the host
# and an image nobody verified.
#
#   scripts/compose-use-mirror.sh /opt/openctem/compose.yml registry.example.com
#
# Environment:
#   OC_PROJECT   repository prefix for the OpenCTEM images   (default: openctem)
#   TP_PROJECT   repository prefix for the third-party ones  (default: openctem-3p)
#   PULL=1       run docker compose pull afterwards
#
# Mirror the images first with scripts/mirror-to-registry.sh.
# docs/CORPORATE-REGISTRY.md is the walkthrough.
set -euo pipefail

file="${1:?usage: $0 <compose.yml> <registry-host>}"
registry="${2:?missing registry host, e.g. registry.example.com}"
oc="$registry/${OC_PROJECT:-openctem}"
tp="$registry/${TP_PROJECT:-openctem-3p}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$file" ] || die "$file does not exist"
grep -q '^[[:space:]]*image:[[:space:]]' "$file" || die "$file has no image: lines"

# Every digest in the file, before. Nothing below may change this list.
before="$(grep -o 'sha256:[0-9a-f]\{64\}' "$file" | sort)"
[ -n "$before" ] ||
	die "$file pins no digests; this is not a directory rendered by render-standalone.yml"

backup="$file.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$file" "$backup"

restore() { cp -p "$backup" "$file"; die "$1 -- restored $file from $backup"; }

# Anchored to image: so that a registry host named in a comment, an env var or
# a healthcheck is left alone.
sed -i \
	-e "s|^\([[:space:]]*image:[[:space:]]*\)ghcr\.io/openctemio/|\1$oc/|" \
	-e "s|^\([[:space:]]*image:[[:space:]]*\)docker\.io/|\1$tp/|" \
	"$file"

after="$(grep -o 'sha256:[0-9a-f]\{64\}' "$file" | sort)"
[ "$before" = "$after" ] || restore "a digest changed"

# A reference left pointing at a public registry would be pulled from the
# internet on a host that is not supposed to have any, and the stack would come
# up looking fine until the day that pull is the one that fails.
#
# Anchored at the registry host, which is everything before the first slash --
# not matched anywhere in the line. A mirror prefix may legitimately contain
# the original host: registries are commonly laid out as
# <registry>/<project>/<original-host>/<path>, which keeps an image's
# provenance visible, and then every rewritten line still has ghcr.io or
# docker.io inside it. Searching the whole line fails every one of them, and
# this script restores the backup over a file it had rewritten correctly.
if grep -nE '^[[:space:]]*image:[[:space:]]*(ghcr\.io|docker\.io)/' "$file"; then
	restore "an image: line still points at a public registry"
fi

printf 'backup: %s\n\n' "$backup"
grep '^[[:space:]]*image:' "$file" | sed 's/^[[:space:]]*image:[[:space:]]*/  /' | sort -u

cat <<EOF

Next, on the host:

  docker login $registry
  docker compose -f $file pull

An internal certificate authority goes in /etc/docker/certs.d/${registry%%/*}/ca.crt
EOF

if [ "${PULL:-}" = 1 ]; then
	printf '\n== pulling\n'
	docker compose -f "$file" pull
fi
