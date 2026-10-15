#!/usr/bin/env bash
set -euo pipefail
# Run on target via sudo. A configuration archive is NOT an ESXi snapshot.
OUT="/root/hardening-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
cp -a /etc/ssh "$OUT/" || true
cp -a /etc/docker "$OUT/" || true
cp -a /etc/sysctl.conf /etc/sysctl.d "$OUT/" 2>/dev/null || true
cp -a /etc/pam.d "$OUT/" || true
cp -a /etc/security "$OUT/" || true
cp -a /etc/modprobe.d "$OUT/" || true
cp -a /etc/ufw "$OUT/" 2>/dev/null || true
ss -lntup > "$OUT/listeners.txt" || true
docker ps --format '{{.Names}} {{.Ports}}' > "$OUT/docker-ports.txt" 2>/dev/null || true
printf 'Backup directory: %s\n' "$OUT"
