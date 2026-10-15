#!/usr/bin/env bash
set -euo pipefail
file="${1:?usage: $0 <rendered compose file>}"
echo 'Checking syntax (NOTE: compose config output may reveal secrets; do not paste it)'
# Read-only: renders the model, starts nothing (explicit project name).
docker compose -p compose-audit -f "$file" config --quiet
echo 'Checking published ports configured in the compose model...'
python3 - "$file" <<'PYS'
import sys
try:
 import yaml
except ImportError:
 print('Install PyYAML for static audit: python3 -m pip install pyyaml');sys.exit(2)
data=yaml.safe_load(open(sys.argv[1]))
failed=False
for name,svc in data.get('services',{}).items():
 if svc.get('ports'):
  print('WARNING: service', name,'publishes ports:',svc['ports']); failed=True
 if svc.get('privileged') or svc.get('network_mode')=='host':
  print('WARNING: privileged/host network:',name);failed=True
 if any('/var/run/docker.sock' in str(v) for v in svc.get('volumes',[])):
  print('WARNING: docker.sock mounted:',name);failed=True
print('No flagged static Compose configurations' if not failed else 'Review findings before deployment')
sys.exit(1 if failed else 0)
PYS
