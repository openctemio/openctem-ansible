#!/usr/bin/env bash
# Signed backups and the restore guards, on the rendered scripts with a stub
# `docker` (no daemon, no host touched). Local mode backups are used because the
# signature logic is the same as in age mode; the Docker-in-Docker smoke test
# covers age mode.
#   ansible-playbook tests/render.yml -e render_dir=$dir && tests/backup-signing.sh $dir
set -euo pipefail
r="$(cd "${1:?usage: $0 <render dir>}" && pwd)"
tmp="$(mktemp -d)"
trap 'find "$tmp" -delete' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v ssh-keygen > /dev/null || fail "ssh-keygen is needed"

# The scripts under test, pointed at temp paths.
mkdir -p "$tmp/lib" "$tmp/bin" "$tmp/state" "$tmp/dest"
sed -e "s|^DEST='.*'|DEST='$tmp/dest'|" "$r/scripts/restore-common.sh" > "$tmp/lib/restore-common.sh"
sed -e "s|/usr/local/lib/openctem/restore-common.sh|$tmp/lib/restore-common.sh|" \
	-e "s|/usr/local/lib/openctem/wal-common.sh|$tmp/lib/wal-common.sh|" \
	-e "s|{{ openctem_state_dir }}|$tmp/state|" "$r/scripts/openctem-restore" > "$tmp/restore"
sed -e "s|/usr/local/lib/openctem/restore-common.sh|$tmp/lib/restore-common.sh|" "$r/scripts/openctem-restore-drill" > "$tmp/drill"
grep -q "$tmp/state\|deployed-version" "$tmp/restore" || fail "restore script lost its state path"
# state dir: the rendered path is the real one; point it at the temp state.
state_dir="$(sed -n "s|.*cat '\(.*\)/deployed-version'.*|\1|p" "$r/scripts/openctem-restore")"
[ -n "$state_dir" ] && sed -i "s|$state_dir/deployed-version|$tmp/state/deployed-version|" "$tmp/restore"
chmod +x "$tmp/restore" "$tmp/drill"

# Stub docker: records every call; answers what the restore asks.
cat > "$tmp/bin/docker" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUBLOG"
case "$*" in
*"pg_database"*) echo 1 ;;
*pg_dump*) echo "PGDMP-stub" ;;
*"ps --services"*) ;;
esac
exit 0
STUB
cat > "$tmp/bin/logger" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUBLOG.logger"
STUB
chmod +x "$tmp/bin/docker" "$tmp/bin/logger"
export STUBLOG="$tmp/docker.log"
export PATH="$tmp/bin:$PATH"

# A signing key and the allowed_signers file kept "off the host".
ssh-keygen -q -t ed25519 -N '' -C openctem-backup -f "$tmp/signkey"
echo "openctem-backup $(cut -d' ' -f1,2 "$tmp/signkey.pub")" > "$tmp/allowed"
ssh-keygen -q -t ed25519 -N '' -C attacker -f "$tmp/otherkey"

# A local-mode backup as openctem-backup writes it: MANIFEST over every file, signed.
mk_backup() { # mk_backup <dir> <version>
	mkdir -p "$1"
	echo "dump" > "$1/openctem.dump"
	echo "$2" > "$1/VERSION"
	( cd "$1" && sha256sum -- openctem.dump VERSION > SHA256SUMS && sha256sum -- * > "$tmp/m" )
	mv "$tmp/m" "$1/MANIFEST.sha256"
	ssh-keygen -q -Y sign -n openctem-backup -f "$tmp/signkey" "$1/MANIFEST.sha256"
}
resign() { rm -f "$1/MANIFEST.sha256.sig"; ssh-keygen -q -Y sign -n openctem-backup -f "$2" "$1/MANIFEST.sha256"; }

echo "v0.0.1" > "$tmp/state/deployed-version"
mk_backup "$tmp/dest/20260101T000000Z" v0.0.1
good="$tmp/dest/20260101T000000Z"

# 1. A good, signed backup passes the drill's staging (it stops later, at the stubbed Postgres).
run_drill() { "$tmp/drill" "$@" > "$tmp/out" 2>&1; }
run_drill "$good" --allowed-signers="$tmp/allowed" || true
! grep -q 'does not verify\|no signature\|MANIFEST' "$tmp/out" || fail "a good backup was refused: $(cat "$tmp/out")"
grep -q 'release of the backup' "$tmp/out" || fail "staging did not complete: $(cat "$tmp/out")"

# 2. Tampered dump with a RECOMPUTED manifest (the bucket writer): refused.
cp -r "$good" "$tmp/planted"
echo "evil" > "$tmp/planted/openctem.dump"
( cd "$tmp/planted" && sha256sum -- openctem.dump VERSION > SHA256SUMS && sha256sum -- openctem.dump VERSION SHA256SUMS > MANIFEST.sha256 )
if run_drill "$tmp/planted" --allowed-signers="$tmp/allowed"; then fail "drill accepted a planted backup"; fi
grep -q 'does not verify' "$tmp/out" || fail "wrong reason for the planted backup: $(cat "$tmp/out")"

# 3. Re-signed with the wrong key: refused. Unsigned: refused.
resign "$tmp/planted" "$tmp/otherkey"
if run_drill "$tmp/planted" --allowed-signers="$tmp/allowed"; then fail "drill accepted a backup signed by another key"; fi
rm -f "$tmp/planted/MANIFEST.sha256.sig"
if run_drill "$tmp/planted" --allowed-signers="$tmp/allowed"; then fail "drill accepted an unsigned backup"; fi
grep -q 'no signature' "$tmp/out" || fail "unsigned: wrong reason"
# No allowed signers file at all: refused (nothing to trust).
if run_drill "$good" --allowed-signers="$tmp/missing"; then fail "drill ran without an allowed signers file"; fi

# 4. --allow-unsigned goes past it, loudly (output and journal).
: > "$tmp/docker.log.logger"
run_drill "$tmp/planted" --allowed-signers="$tmp/allowed" --allow-unsigned || true
grep -q 'WARNING.*allow-unsigned' "$tmp/out" || fail "--allow-unsigned was not loud"
grep -q 'WITHOUT a valid signature' "$tmp/docker.log.logger" || fail "--allow-unsigned was not logged to the journal"

# 5. Restore: a tampered backup stops before any docker call.
: > "$STUBLOG"
if "$tmp/restore" "$tmp/planted" --yes --allowed-signers="$tmp/allowed" > "$tmp/out" 2>&1; then fail "restore accepted a planted backup"; fi
[ ! -s "$STUBLOG" ] || fail "restore touched docker before refusing: $(cat "$STUBLOG")"

# 6. Restore: a VERSION mismatch is refused without the flag, the database untouched.
mk_backup "$tmp/dest/20260102T000000Z" v0.0.0
old="$tmp/dest/20260102T000000Z"
: > "$STUBLOG"
if "$tmp/restore" "$old" --yes --allowed-signers="$tmp/allowed" > "$tmp/out" 2>&1; then fail "restore accepted a version mismatch"; fi
grep -q 'allow-version-mismatch' "$tmp/out" || fail "mismatch: wrong message: $(cat "$tmp/out")"
! grep -q 'DROP DATABASE' "$STUBLOG" || fail "mismatch: the database was dropped"

# 7. With the flag: the current database is dumped BEFORE it is dropped; the actor is logged.
: > "$STUBLOG"; : > "$STUBLOG.logger"
SUDO_USER=alice "$tmp/restore" "$old" --yes --allow-version-mismatch --allowed-signers="$tmp/allowed" > "$tmp/out" 2>&1 || true
grep -q 'DROP DATABASE' "$STUBLOG" || fail "restore did not reach the drop: $(tail -n 5 "$tmp/out")"
dump_line="$(grep -n 'pg_dump' "$STUBLOG" | head -n 1 | cut -d: -f1)"
drop_line="$(grep -n 'DROP DATABASE' "$STUBLOG" | head -n 1 | cut -d: -f1)"
[ -n "$dump_line" ] && [ "$dump_line" -lt "$drop_line" ] || fail "no pre-restore dump before DROP DATABASE"
ls "$tmp/dest"/pre-restore-*.dump > /dev/null 2>&1 || fail "pre-restore dump file missing"
grep -q 'alice' "$STUBLOG.logger" || fail "SUDO_USER not logged to the journal"
# 8. Pruning from the host is opt-in: off by default, and every delete comes after the guard.
grep -q "^PRUNE='no'" "$r/scripts/wal-common.sh" || fail "pruning is not off by default"
guard="$(grep -n 'PRUNE" != yes' "$r/scripts/openctem-base-backup" | sed -n 2p | cut -d: -f1)"
first_del="$(grep -n 'rc purge "$REMOTE/base/$b"\|rc delete' "$r/scripts/openctem-base-backup" | head -n 1 | cut -d: -f1)"
[ -n "$guard" ] && [ -n "$first_del" ] && [ "$guard" -lt "$first_del" ] || fail "a bucket delete can run with pruning off"
! grep -q 'rc \(purge\|delete\)' "$r/scripts/openctem-wal-ship" || fail "the uploader deletes from the bucket"
echo "backup signing and restore guard checks passed"
