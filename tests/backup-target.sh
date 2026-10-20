#!/usr/bin/env bash
# Archive target (s3 or sftp): the checks of the remote definition against
# backup_wal_target, the rendered scripts per target, and the append-only probe
# with a stub docker. Needs ansible-core; no Docker, no host touched.
#   tests/backup-target.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"
mkdir -p "$work"

s3conf='[openctem-backup]
type = s3
provider = Other
access_key_id = AKEXAMPLE
secret_access_key = SKEXAMPLE
endpoint = https://s3.example
'
sftpconf='[openctem-backup]
type = sftp
host = backup.example.net
user = openctem
known_hosts_file = /config/known_hosts
key_file = /config/sftp_key
'
check() { ansible-playbook tests/backup-target-checks.yml "$@" > "$work/last.log" 2>&1; }
ok() { check "$@" || { echo "expected to pass: ${*:2:3}" >&2; tail -n 12 "$work/last.log" >&2; exit 1; }; }
no() { ! check "$@" || { echo "expected to fail: ${*:2:3}" >&2; exit 1; }; }
conf() { printf -- '-e\n%s\n' "$(python3 -c 'import json,sys; print(json.dumps({"backup_wal_conf_text": sys.argv[1]}))' "$1")"; }

# s3 (the default): any S3-compatible service, including R2 and MinIO.
mapfile -t c < <(conf "$s3conf")
ok "${c[@]}" -e backup_wal_bucket=my-bucket
no "${c[@]}" -e backup_wal_bucket=Bad_Bucket
no "${c[@]}" -e backup_wal_bucket=my-bucket -e backup_wal_target=sftp   # an s3 remote for an sftp target
no "${c[@]}" -e backup_wal_bucket=my-bucket -e backup_wal_target=azure   # not supported
mapfile -t empty < <(conf "")
no "${empty[@]}" -e backup_wal_bucket=my-bucket                          # no remote definition

# sftp: the host key is pinned and only a key file is used.
mapfile -t c < <(conf "$sftpconf")
ok "${c[@]}" -e backup_wal_target=sftp -e backup_wal_bucket=srv/backups
ok "${c[@]}" -e backup_wal_target=sftp -e backup_wal_bucket=backups
no "${c[@]}" -e backup_wal_target=sftp -e backup_wal_bucket=../etc
no "${c[@]}" -e backup_wal_target=sftp -e backup_wal_bucket=/abs/path
no "${c[@]}" -e backup_wal_bucket=my-bucket                              # an sftp remote for an s3 target
mapfile -t c < <(conf "${sftpconf/known_hosts_file = \/config\/known_hosts/}")
no "${c[@]}" -e backup_wal_target=sftp -e backup_wal_bucket=backups      # host key not pinned
mapfile -t c < <(conf "$sftpconf
pass = obscured")
no "${c[@]}" -e backup_wal_target=sftp -e backup_wal_bucket=backups      # password login
mapfile -t c < <(conf "$sftpconf
ssh = ssh -o StrictHostKeyChecking=no host")
no "${c[@]}" -e backup_wal_target=sftp -e backup_wal_bucket=backups      # arbitrary ssh command
echo "ok: target checks"

# Rendered scripts per target.
ansible-playbook tests/render.yml -e render_dir="$work/s3" > "$work/render-s3.log" 2>&1 || { tail -n 20 "$work/render-s3.log"; exit 1; }
ansible-playbook tests/render.yml -e render_dir="$work/sftp" -e backup_wal_target=sftp -e backup_wal_bucket=srv/backups \
	> "$work/render-sftp.log" 2>&1 || { tail -n 20 "$work/render-sftp.log"; exit 1; }
grep -q '^TARGET=.s3.$' "$work/s3/scripts/wal-common.sh"
grep -q '^RCLONE_EXTRA=()$' "$work/s3/scripts/wal-common.sh" || { echo "s3 mounts an sftp file" >&2; exit 1; }
grep -q '^TARGET=.sftp.$' "$work/sftp/scripts/wal-common.sh"
! grep -q '{{ backup_' "$work/sftp/scripts/wal-common.sh" || { echo "unrendered template text in wal-common.sh" >&2; exit 1; }
grep -q "known_hosts:ro" "$work/sftp/scripts/wal-common.sh" || { echo "sftp does not mount the pinned host key" >&2; exit 1; }
grep -q "sftp_key:ro" "$work/sftp/scripts/wal-common.sh" || { echo "sftp does not mount the key" >&2; exit 1; }
grep -q "^REMOTE='openctem-backup:srv/backups/" "$work/sftp/scripts/wal-common.sh" || { echo "sftp remote path" >&2; exit 1; }
bash -n "$work/s3/scripts/openctem-backup-probe"
echo "ok: rendered scripts per target"

# The probe, with a stub docker: delete refused -> 0, delete works -> 3, write refused -> 1.
mkdir -p "$work/bin" "$work/lib" "$work/state"
sed -e "s|^WORK=.*|WORK='$work/state/work'|" -e "s|^BSTATE=.*|BSTATE='$work/state'|" \
	-e "s|^RECIPIENTS=.*|RECIPIENTS=$work/recipients|" -e "s|^SIGN_KEY=.*|SIGN_KEY='$work/signkey'|" \
	-e "s|^RCLONE_CONF=.*|RCLONE_CONF='$work/rclone.conf'|" "$work/s3/scripts/wal-common.sh" > "$work/lib/wal-common.sh"
printf 'age1x\n' > "$work/recipients"
: > "$work/signkey"
: > "$work/rclone.conf"
printf '#!/bin/bash\n:\n' > "$work/bin/age"
cat > "$work/bin/docker" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUBLOG"
case "$*" in
*copyto*) [ "${STUB_WRITE:-ok}" = ok ] || exit 1 ;;
*deletefile*) [ "${STUB_DELETE:-refused}" = ok ] && exit 0 || exit 1 ;;
esac
exit 0
STUB
chmod +x "$work/bin/docker" "$work/bin/age"
sed -e "s|/usr/local/lib/openctem/wal-common.sh|$work/lib/wal-common.sh|" "$work/s3/scripts/openctem-backup-probe" > "$work/probe"
chmod +x "$work/probe"
run() { PATH="$work/bin:$PATH" STUBLOG="$work/stub.log" "$@" "$work/probe" > "$work/probe.out" 2>&1; }
: > "$work/stub.log"
run env STUB_DELETE=refused || { echo "probe failed on an append-only credential" >&2; cat "$work/probe.out" >&2; exit 1; }
grep -q 'delete is refused' "$work/probe.out"
set +e
run env STUB_DELETE=ok; rc=$?
set -e
[ "$rc" = 3 ] || { echo "probe did not report a credential that can delete (exit $rc)" >&2; exit 1; }
grep -q 'CAN DELETE' "$work/probe.out"
set +e
run env STUB_WRITE=refused; rc=$?
set -e
[ "$rc" = 1 ] || { echo "probe did not fail on a refused write (exit $rc)" >&2; exit 1; }
grep -q -- '--cap-drop ALL' "$work/stub.log" || { echo "the probe's rclone did not run with the hardened options" >&2; exit 1; }
echo "ok: append-only probe"
