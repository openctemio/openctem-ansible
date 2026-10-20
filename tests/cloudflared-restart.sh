#!/usr/bin/env bash
# A changed ingress file of a locally managed tunnel must recreate the running
# connector (a single-file bind mount keeps the old file until then), and an
# unchanged one must not. Runs roles/cloudflared against localhost with a stub
# `docker`: no Docker, no host touched. Needs ansible-core and fakeroot (the
# role insists on a root-owned secrets directory and a token owned by uid 65532).
#   tests/cloudflared-restart.sh [workdir]
set -euo pipefail
if [ "$(id -u)" -ne 0 ] && [ -z "${FAKEROOTKEY:-}" ]; then
	exec fakeroot -- "$0" "$@"
fi
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
root="$work/opt"
mkdir -p "$work/bin" "$root/secrets" "$work/inv"
chmod 0700 "$root/secrets"
: > "$root/secrets/cloudflared_tunnel_token"
printf 'dummy' > "$root/secrets/cloudflared_tunnel_token"
chown 65532:65532 "$root/secrets/cloudflared_tunnel_token"
chmod 0400 "$root/secrets/cloudflared_tunnel_token"
printf '[local]\nlocalhost ansible_connection=local\n' > "$work/inv/hosts.ini"

calls="$work/docker.calls"
: > "$calls"
cat > "$work/bin/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$calls"
case "\$*" in
	*" ps -q cloudflared"*) [ -f "$work/running" ] && echo 0123456789ab ;;
esac
exit 0
STUB
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"

play() { # play [-e k=v ...]
	ansible-playbook -i "$work/inv/hosts.ini" "$kit/tests/cloudflared-restart.yml" \
		-e openctem_root="$root" -e openctem_secrets_dir="$root/secrets" -e openctem_state_dir="$root/state" \
		-e cloudflared_management=local -e openctem_app_host=ctem.example.com "$@" > "$work/play.log" 2>&1 ||
		{ cat "$work/play.log"; exit 1; }
}
recreates() { grep -c 'up -d --no-deps --force-recreate cloudflared' "$calls" || true; }

# 1. First install: no connector yet, so nothing to recreate.
play
grep -q 'hostname: ctem.example.com' "$root/cloudflared.yml"
[ "$(recreates)" = 0 ] || { echo "recreated a connector that is not running"; exit 1; }

# 2. Unchanged ingress, connector running: untouched.
touch "$work/running"
play
[ "$(recreates)" = 0 ] || { echo "recreated for an unchanged ingress file"; exit 1; }

# 3. The ingress file changes (a console host name is added), connector running: recreated once.
play -e openctem_admin_site=host -e openctem_admin_host=admin.example.com -e @"$kit/tests/fixtures/console-release.yml"
grep -q 'hostname: admin.example.com' "$root/cloudflared.yml"
[ "$(recreates)" = 1 ] || { echo "want exactly one recreate after the ingress changed, got $(recreates)"; exit 1; }
grep -q -- '-p openctem' "$calls"

# 4. Same settings again: no further recreate.
play -e openctem_admin_site=host -e openctem_admin_host=admin.example.com -e @"$kit/tests/fixtures/console-release.yml"
[ "$(recreates)" = 1 ] || { echo "recreated again without a change"; exit 1; }

# 5. The ingress changes again but the stack's `up -d` already recreated the
# connector in this run: no second recreate.
play -e openctem_admin_site=host -e openctem_admin_host=admin2.example.com -e @"$kit/tests/fixtures/console-release.yml" \
	-e '{"openctem_up": {"stderr": " Container openctem-cloudflared-1  Recreated\n Container openctem-gateway-1  Running"}}'
grep -q 'hostname: admin2.example.com' "$root/cloudflared.yml"
[ "$(recreates)" = 1 ] || { echo "recreated the connector twice in one run, got $(recreates)"; exit 1; }

# 6. Same change shape, `up -d` left the connector running: recreated.
play -e openctem_admin_site=host -e openctem_admin_host=admin3.example.com -e @"$kit/tests/fixtures/console-release.yml" \
	-e '{"openctem_up": {"stderr": " Container openctem-cloudflared-1  Running"}}'
[ "$(recreates)" = 2 ] || { echo "want a recreate when up -d left the connector running, got $(recreates)"; exit 1; }
echo "cloudflared restart on ingress change: ok"
