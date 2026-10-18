# Continuous archiving and point-in-time recovery

The nightly backup (README section 5) loses up to a day of data. With
`openctem_wal_archive: true` the database also ships every finished WAL
segment, encrypted, to an S3-compatible bucket, plus a weekly base backup. A
disk, host or site loss then costs a few minutes of data (RPO), and a bad
change (a wrong delete, a faulty migration) can be undone by recovering to a
time just before it. It is **off by default**.

| | |
|---|---|
| RPO | `openctem_wal_archive_timeout` (300 s: a segment is closed after at most 5 minutes of activity) plus the upload interval (1 minute): about 6 minutes. The monitor alerts at 15 minutes of lag. |
| RTO | base backup download and unpack, plus WAL replay: minutes for a small database; **measure it with the drill** and record the time. |
| Scope | the database only. Uploaded files and the generated secrets are in the nightly backup; point-in-time recovery does not replace them. |
| Retention | `backup_wal_retention_days` (14): base backups and WAL older than the window are deleted from the bucket, except the newest base backup older than the window, which anchors its first day. State this retention in the privacy policy: erased personal data stays in backups until it ages out. |

## What you must provide

1. **A bucket** on any S3-compatible service (a region and provider of your
   choice; it becomes a subprocessor and a cross-border transfer if abroad).
   Use a private bucket with versioning off, and a **dedicated access key** that
   may read, write and delete objects in this bucket only.
2. **The access key in a file on the server**: `/opt/openctem/secrets/backup_remote.conf`
   (`backup_wal_remote_conf`), `root:root`, mode `0400` or `0600`. It never goes
   in the inventory or git. The play refuses to continue if it is missing or too open.

   ```ini
   [openctem-backup]
   type = s3
   provider = Other
   access_key_id = <key id>
   secret_access_key = <secret>
   endpoint = https://<s3 endpoint of your provider>
   region = <region>
   ```

3. **An age key pair** (`backup_age_recipient`, the same as the nightly backups).
   Everything in the bucket except `meta.json` is encrypted to its public key on
   this host. The private key stays off the host: with the bucket key alone an
   attacker cannot read the data, and a stolen host cannot read old backups.
   **Losing the private key makes the archive unreadable**: keep two copies offline.

Inventory (never the token):

```yaml
openctem_wal_archive: true
backup_age_recipient: age1...
backup_wal_bucket: my-openctem-backups
backup_wal_prefix: openctem          # a path in the bucket, default: the project name
```

## Turn it on

The order matters, so the spool never fills the disk without an uploader:

```bash
# 1. uploader, timers, tools (the first base backup waits for step 2)
ansible-playbook -i $INV playbooks/55-backup.yml -K -e apply_backup=true -e openctem_wal_archive=true
# 2. Postgres starts archiving (archive_mode needs one Postgres restart: a brief outage)
ansible-playbook -i $INV playbooks/50-openctem.yml -K -e apply_openctem=true -e openctem_wal_archive=true
# 3. again: starts the first base backup now (the weekly timer keeps it fresh)
ansible-playbook -i $INV playbooks/55-backup.yml -K -e apply_backup=true -e openctem_wal_archive=true
sudo journalctl -u openctem-base-backup -f
```

Put `openctem_wal_archive: true` in the inventory afterwards. Turning it off and
rerunning the plays removes the units and tools; the objects in the bucket stay.

## How it works

- Postgres' `archive_command` copies each finished segment (and syncs it) into
  `/var/lib/openctem-wal-spool`, readable by root only. A failed copy is retried by Postgres.
- `openctem-wal-ship` (systemd timer, every minute) compresses and encrypts each
  segment, uploads it with rclone, checks the bucket lists it, then removes it
  from the spool. rclone runs from a digest-pinned image (`versions.yml`) with no
  capabilities and a read-only root; it sees only the key file and a work directory.
- `openctem-base-backup` (weekly) runs `pg_basebackup` inside the Postgres
  container, encrypts the tar, uploads it, verifies the upload by checksum and only
  then writes `meta.json`, which marks the backup complete. Then it prunes.
- Bucket layout: `<prefix>/wal/<segment>.gz.age`, `<prefix>/base/<UTC time>/base.tar.gz.age`
  and `meta.json` (finished time, first WAL segment, checksum: no secrets).

### Why small scripts instead of a backup framework

The kit keeps one encryption model for everything it backs up: **age with a
public recipient on the host and the private key off it**. General-purpose
Postgres backup frameworks encrypt with a symmetric passphrase or a key pair
that must sit on the host, so a stolen host would read every backup. Small
scripts (`pg_basebackup`, `age`, `rclone`) keep the private key off the host, add
no daemon, and are covered by an end-to-end test in `tests/smoke.sh`: base backup,
upload, a drill, and a restore to a time between two marked transactions against
a fake bucket. The price is that the restore logic is ours
(`roles/backup/templates/openctem-wal-common.sh.j2`); that test exercises it on
every change. rclone is pinned by digest (it publishes no image signature), age
comes from Ubuntu's archive.

## Recover to a point in time

Pick the time in UTC just before the damage (`latest` replays everything in the
archive). Bring the age identity file to the server for the duration only.

```bash
scp ~/openctem-backup-identity.txt vm:/tmp/id.txt
ssh -t vm 'sudo install -m 0600 /tmp/id.txt /root/pitr.key && rm /tmp/id.txt'
sudo openctem-restore --pitr "2026-10-18 14:02:00 UTC" /root/pitr.key --yes
sudo rm -f /root/pitr.key
```

What it does: finds the newest complete base backup finished before the target,
downloads and decrypts it and the WAL after it, replays to the target in a
throwaway Postgres without network, dumps the recovered `openctem` database, and
only then stops the front services and replaces the live database with that
dump (the same steps as `openctem-restore`). If anything fails before that point
the stack is untouched. Afterwards it runs `openctem-verify`.

Things to know:

- Data written after the target is gone. Write down the target and the time of the
  restore, and tell the affected tenants.
- A target before the oldest base backup in the bucket, or after the archive's end
  with a missing segment, fails with an error; it never recovers silently to a wrong time.
- If a release upgrade (migrations) happened between the target and now, the
  recovered schema is the older one: roll the release back (`playbooks/71-rollback.yml`)
  or rerun the openctem play so the migrations run again.
- Uploaded files are not touched. Restore them from a nightly backup if needed.
- On a **new host**: deploy the release, restore the nightly backup with
  `--with-secrets` first (the key that decrypts stored credentials), then point-in-time
  recovery on top if you want the newer data.

## Restore drill (monthly)

```bash
sudo openctem-restore-drill --pitr latest /root/drill.key
sudo openctem-restore-drill --pitr "2026-10-18 14:02:00 UTC" /root/drill.key
```

It recovers a throwaway Postgres, checks it has tables and prints how long it took:
record that as the restore time. It touches neither the stack nor the spool.

## Monitoring

`openctem-monitor` (every 5 minutes) alerts when:

- the oldest segment waiting for upload is older than `monitoring_wal_lag_minutes` (15),
  which is the archive lag, or the spool is larger than `monitoring_wal_spool_max_mb` (2048);
- the last upload or base backup failed;
- Postgres' `archive_command` is failing (`pg_stat_archiver`);
- no base backup exists a day after enabling, or the newest one is older than `monitoring_basebackup_max_age_days` (8).

Configure `monitoring_webhook_url`, or the alerts only reach the journal.

## Rotating the bucket key

Create a new key, write it over `backup_wal_remote_conf` (keep mode 0600), run
`sudo systemctl start openctem-wal-ship`, then delete the old key at the provider.
