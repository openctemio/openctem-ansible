#!/usr/bin/env bash
# Runs INSIDE the DinD container started by tests/smoke.sh. Refuses to run
# anywhere else. All Docker work here goes to the DinD daemon.
set -euo pipefail
expected="${1:?usage: smoke-inner.sh <dind container name> <release> <private stand-in ip>}"
version="${2:?release}"
lan_ip="${3:?private stand-in address}"
project=octsmoke
work=/work
host=ctem.example.com
ubuntu_image="${SMOKE_UBUNTU_IMAGE:-ubuntu:26.04}"
curl_image="${SMOKE_CURL_IMAGE:-curlimages/curl:8.16.0}"
tunnel=172.30.81
egress_api=172.30.84

# --- Guard: only the DinD daemon, only our project ----------------------------
[ -f /.dockerenv ] || { echo "not inside a container: refusing" >&2; exit 64; }
[ -z "${DOCKER_HOST:-}" ] || { echo "DOCKER_HOST is set ($DOCKER_HOST): refusing" >&2; exit 64; }
daemon="$(docker info --format '{{.Name}}')"
[ "$daemon" = "$expected" ] && [ "$(hostname)" = "$expected" ] ||
	{ echo "daemon '$daemon' is not this DinD container '$expected': refusing" >&2; exit 64; }
case "$project" in openctemio | openctem-sensor | openctemio-obs) exit 64 ;; esac
echo "daemon: $daemon (DinD, isolated storage)"

dc() { docker compose -p "$project" --project-directory "$work" -f "$work/compose.yml" "$@"; }
say() { printf '\n== %s\n' "$*"; }

say "files"
rel="$work/releases/$version"
mkdir -p "$rel" "$work/state" "$work/secrets"
chmod 0700 "$work/secrets"
cp -r "/kit/roles/openctem/files/release/$version/." "$rel/"
(cd "$rel" && sha256sum -c --quiet SHA256SUMS)
cp "$work/render/gateway/modes/http.site" "$rel/gateway/modes/http.site"
cp "$work/render/compose.yml" "$work/"
echo "$version" > "$work/state/deployed-version"
mkdir -p /usr/local/sbin /usr/local/lib/openctem /etc/openctem
for s in openctem-secrets openctem-verify openctem-backup openctem-restore openctem-restore-drill openctem-egress; do
	install -m 0755 "$work/render/scripts/$s" "/usr/local/sbin/$s"
done
cp "$work/render/scripts/restore-common.sh" /usr/local/lib/openctem/restore-common.sh

# Helper: an Ubuntu 26.04 container (uutils coreutils) on the DinD daemon.
ubuntu() {
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v /usr/local/bin/docker:/usr/bin/docker:ro \
		-v /usr/local/libexec/docker/cli-plugins:/usr/libexec/docker/cli-plugins:ro \
		-v "$work:$work" -v /usr/local/sbin:/usr/local/sbin:ro -v /usr/local/lib/openctem:/usr/local/lib/openctem:ro \
		-v /etc/openctem:/etc/openctem "$ubuntu_image" bash -c "set -e
		apt-get update -qq > /dev/null && apt-get install -y -qq openssl age gzip > /dev/null 2>&1
		$1"
}

say "secrets (role script, Ubuntu 26.04, root)"
ubuntu "openctem-secrets | sed 's/^/  /'
	[ -z \"\$(openctem-secrets)\" ] && echo '  second run: no change'
	chown 999:1000 $work/secrets/redis.conf
	chown 999:999 $work/secrets/db_superuser_password"
dc config --quiet

say "start (no cloudflared: the stack's ingress is tested from the tunnel network)"
dc up -d --wait --wait-timeout 300

say "verify"
out="$(openctem-verify || true)"
echo "$out"
if echo "$out" | grep -q '^FAIL'; then echo "verify failed"; exit 1; fi

say "client address trust (Cf-Connecting-Ip only from the cloudflared address)"
# What the Cloudflare edge sends through the tunnel when the visitor typed its
# own X-Forwarded-For: Cf-Connecting-Ip = visitor, X-Forwarded-For = typed
# list + visitor. From .10 (cloudflared) the visitor must reach the API; from
# .50 (any other container on the tunnel network) the headers are ignored.
# The sensor path answers 401, so the API logs the request with client_ip.
for ip in 10 50; do
	docker run --rm --network "${project}_tunnel" --ip "$tunnel.$ip" "$curl_image" -s -o /dev/null \
		-H "Host: $host" -H "X-Request-ID: smoke-cip-$ip" -H 'Cf-Connecting-Ip: 203.0.113.7' \
		-H 'X-Forwarded-For: 198.51.100.9, 203.0.113.7' "http://$tunnel.11/api/v2/sensor/hello"
done
sleep 1
apilog="$(dc logs api 2>&1)"
cip() { grep -F "\"request_id\":\"$1\"" <<< "$apilog" | sed -n 's/.*"client_ip":"\([^"]*\)".*/\1/p' | tail -n 1; }
got10="$(cip smoke-cip-10)"
got50="$(cip smoke-cip-50)"
[ "$got10" = 203.0.113.7 ] || { echo "API saw '$got10' through cloudflared, want the visitor 203.0.113.7"; exit 1; }
[ "$got50" = "$tunnel.50" ] || { echo "API saw '$got50' from an untrusted peer, want $tunnel.50 (spoofed header believed?)"; exit 1; }
echo "  OK: the API sees the visitor through .10 and the peer itself from .50"

say "egress policy (rules of roles/firewall, as the real host would have them)"
internet_url="${SMOKE_INTERNET_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
gw="$egress_api.1" # the bridge address of the network: this host, as the container sees it
# A listener in the host network namespace of this daemon: "the host itself".
docker run -d --rm --name egress-hostweb --network host "${SMOKE_LAN_IMAGE:-busybox:1.37}" httpd -f -p 9099 -h /tmp > /dev/null
# A container like the API: on the outbound network and on the data network.
docker create --name egress-probe --network "${project}_egress_api" --entrypoint sleep "$curl_image" 3600 > /dev/null
docker network connect "${project}_data" egress-probe
docker start egress-probe > /dev/null
code() { docker exec egress-probe curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2> /dev/null || true; }
reach() { [ "$(code "$1")" != 000 ]; }
want() { # want <yes|no> <what> <url>
	if reach "$3"; then got=yes; else got=no; fi
	[ "$got" = "$1" ] || { echo "  FAIL: $2 reachable=$got, want $1"; exit 1; }
	echo "  OK: $2 reachable=$got"
}
echo "-- before the policy (proves the probes can reach what the policy will close)"
want yes "private server $lan_ip:8080" "http://$lan_ip:8080/"
want yes "the host itself $gw:9099" "http://$gw:9099/"
want yes "the internet" "$internet_url"
openctem-egress apply
want no "private server $lan_ip:8080" "http://$lan_ip:8080/"
want yes "allow-listed $lan_ip:8081" "http://$lan_ip:8081/"
want no "the host itself $gw:9099" "http://$gw:9099/"
want no "metadata 169.254.169.254" "http://169.254.169.254/"
want yes "the internet" "$internet_url"
docker exec egress-probe nc -z -w 3 postgres 5432 || { echo "  FAIL: postgres unreachable from the API-like container"; exit 1; }
echo "  OK: postgres reachable on the data network"
n="$(iptables -S OPENCTEM-EGRESS | wc -l)"
openctem-egress apply > /dev/null
[ "$(iptables -S DOCKER-USER | grep -c -- '-j OPENCTEM-EGRESS$')" = 1 ] && [ "$(iptables -S INPUT | grep -c -- '-j OPENCTEM-EGRESS-IN$')" = 1 ] &&
	[ "$(iptables -S OPENCTEM-EGRESS | wc -l)" = "$n" ] || { echo "  FAIL: a second apply changed the rules"; exit 1; }
echo "  OK: apply is idempotent"
openctem-egress remove
want yes "private server $lan_ip:8080 after remove" "http://$lan_ip:8080/"
iptables -S OPENCTEM-EGRESS > /dev/null 2>&1 && { echo "  FAIL: chain left behind"; exit 1; }
docker rm -f egress-probe egress-hostweb > /dev/null

say "backups, drill and restore (Ubuntu 26.04)"
ubuntu "
	echo '-- local mode'
	openctem-backup
	echo '-- local mode refuses an off-host copy'
	printf '#!/bin/sh\necho copied\n' > /etc/openctem/backup-offsite.sh; chmod 0700 /etc/openctem/backup-offsite.sh
	if openctem-backup 2>&1; then echo 'off-host copy NOT refused'; exit 1; fi
	echo '-- local drill'
	openctem-restore-drill \"\$(cat $work/bstate/last_path)\"
	echo '-- age mode'
	age-keygen -o /root/drill-identity.txt 2> /dev/null
	age-keygen -y /root/drill-identity.txt > /etc/openctem/backup-recipients.txt
	openctem-backup
	last=\"\$(cat $work/bstate/last_path)\"
	if ls \"\$last\" | grep -v -e '\.age\$' -e '^MANIFEST.sha256\$' | grep -q .; then echo 'plaintext file in an age backup'; exit 1; fi
	if openctem-restore-drill \"\$last\" 2> /dev/null; then echo 'drill ran without identity'; exit 1; fi
	openctem-restore-drill \"\$last\" /root/drill-identity.txt
	echo '-- full restore of the age backup over the running stack'
	openctem-restore \"\$last\" /root/drill-identity.txt --yes
"
say "verify after restore"
openctem-verify
