#!/usr/bin/env bash
# Behaviour of the rendered openctem-secrets for FINGERPRINT_KEY, in a temp
# directory (no host state): an existing install gets its current encryption
# key copied, a new install an independent random key, a second run changes
# nothing. Values are compared, never printed.
#   ansible-playbook tests/render.yml -e render_dir=$dir/render && tests/secrets-fingerprint.sh $dir/render/scripts/openctem-secrets
set -euo pipefail
script="${1:?usage: $0 <rendered openctem-secrets>}"
tmp="$(mktemp -d)"
trap 'find "$tmp" -delete' EXIT
run() { # run <secrets dir>
	mkdir -p "$1"
	chmod 0700 "$1"
	sed "s|^d='.*'|d='$1'|" "$script" > "$tmp/s.sh"
	sh "$tmp/s.sh" > "$tmp/out.txt"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

# New install: its own random key, not the encryption key.
run "$tmp/new"
[ -s "$tmp/new/fingerprint_key" ] || fail "new install: no fingerprint_key"
[ "$(stat -c %a "$tmp/new/fingerprint_key")" = 400 ] || fail "new install: mode is not 0400"
[ "$(wc -c < "$tmp/new/fingerprint_key")" -ge 32 ] || fail "new install: key shorter than 32"
! cmp -s "$tmp/new/fingerprint_key" "$tmp/new/app_encryption_key" || fail "new install: fingerprint key equals the encryption key"
grep -q '^FINGERPRINT_KEY=' "$tmp/new/api.env" || fail "api.env has no FINGERPRINT_KEY"

# Existing install (encryption key present, no fingerprint key): copied, never random.
mkdir -m 0700 "$tmp/old"
openssl rand -hex 32 > "$tmp/old/app_encryption_key"
chmod 0400 "$tmp/old/app_encryption_key"
run "$tmp/old"
cmp -s "$tmp/old/fingerprint_key" "$tmp/old/app_encryption_key" || fail "existing install: fingerprint key is not the encryption key"
[ "$(stat -c %a "$tmp/old/fingerprint_key")" = 400 ] || fail "existing install: mode is not 0400"
grep -q "^FINGERPRINT_KEY=$(cat "$tmp/old/app_encryption_key")\$" "$tmp/old/api.env" || fail "existing install: api.env FINGERPRINT_KEY differs"

# Second run: no change; a stored fingerprint key is never replaced.
run "$tmp/old"
[ ! -s "$tmp/out.txt" ] || fail "second run changed something"
echo "secrets-fingerprint: ok"
