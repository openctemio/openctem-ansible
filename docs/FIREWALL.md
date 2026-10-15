# Host firewall: ufw, Docker and the tunnel

## Policy

- **Inbound:** deny everything except SSH (tcp/22) from `admin_cidrs`. No HTTP
  or HTTPS port is needed: the Cloudflare Tunnel is an outbound connection.
- **Outbound:** allowed. The host needs: Cloudflare's edge on 7844/udp and
  7844/tcp (tunnel; QUIC first, HTTP/2 fallback); DNS; HTTPS to `ghcr.io`,
  `docker.io`, `download.docker.com`, the Ubuntu archive and the sigstore
  services (image signature checks at deploy). The API also calls out for its
  feeds, CI OIDC keys, SMTP and the integrations you configure. To restrict
  egress further, do it upstream (ESXi / router), and test a deploy and a
  sensor job afterwards.
- **Forwarding:** untouched. Docker manages its own chains, and
  `net.ipv4.ip_forward=1` stays on (the OS role pins it, because DevSec OS
  hardening would turn it off and break container networking).

`playbooks/35-firewall.yml` (role `firewall`) applies this with **ufw**:
default deny incoming, allow outgoing, `allow from <cidr> to any port 22 proto
tcp` per admin CIDR, then removes any "22 from anywhere" rule (including the
`OpenSSH` application rule). It refuses to run when the controller's own
address (as the host sees it in `SSH_CLIENT`) is outside `admin_cidrs`, so a
typo cannot lock you out. Keep the ESXi console open anyway.

## Docker and ufw: the caveat

Docker programs the kernel firewall itself. **A port published by a container
(`ports:` / `-p`) is reachable even when ufw denies it.** The DNAT happens
before ufw's INPUT rules and the traffic goes through the FORWARD path Docker
manages. ufw alone therefore does not protect published container ports.

This deployment avoids the problem by design:

- No OpenCTEM container publishes a port (`cloudflared` ingress). With the
  optional `loopback` ingress the gateway publishes only `127.0.0.1:<port>`.
- The firewall role, `openctem-verify` (after every deploy and every five
  minutes from the monitor) and `playbooks/85-exposure-audit.yml` all fail
  when any container publishes a port beyond loopback.
- `daemon.json` sets `userland-proxy: false` and keeps Docker's iptables
  management on. Never set `iptables: false`: containers lose egress and the
  tunnel cannot connect. The docker role refuses such a config.

If another workload on this host must publish a port, filter it in the
`DOCKER-USER` chain (iptables backend; check with `docker info --format
'{{.FirewallBackend}}'`) or upstream, never with ufw rules alone.

## Internal networks

| Network | Members | Internet |
|---|---|---|
| `tunnel` | cloudflared (.10), gateway (.11) | no (internal) |
| `egress_tunnel` | cloudflared | yes, outbound only, no container-to-container traffic |
| `origin` | gateway (.10), web (.11), api | no (internal) |
| `data` | api, migrate, db-roles, postgres, redis | no (internal) |
| `egress_api` | api | yes, outbound only, no container-to-container traffic |

`cloudflared` can reach only the gateway. Postgres and Redis are reachable
only from the API (TLS, passwords) and the one-shot migration jobs. The
gateway believes `X-Forwarded-For` only from cloudflared's fixed address, and
the API believes `X-Real-IP` only from the gateway and web. An internal network
is no boundary against root on the host: host security comes first.

## Acceptance matrix

| Source → destination | Expected |
|---|---|
| Internet → host, any TCP/UDP port | no answer |
| LAN (not admin) → host:22 | refused/dropped |
| Admin CIDR → host:22 | key login works (passwords off after SSH stage 2) |
| LAN → host:80, :443, :3000, :8080, :5432, :6379 | refused (nothing listens, nothing published) |
| cloudflared → `gateway:80` | works (tunnel network) |
| cloudflared → `api:8080`, `web:3000`, `postgres`, `redis` | fails (not on those networks) |
| host → Cloudflare 7844 udp/tcp | works (tunnel Healthy) |
| Browser → `https://<app host>/` | Access login, then OpenCTEM |
| Browser → `https://<app host>/api/v1/me` without Access | Access challenge |
| Sensor → `https://<app host>/api/v2/sensor/*` | reaches the API, no Access; 401 without a key |
| CI → `https://<app host>/api/v1/ci/oidc/exchange` and `/api/v1/ci/runs/*` | reaches the API, no Access; needs OIDC/run token |
| Any host name other than the app host, through the tunnel | 404 from the gateway |
| `https://<app host>/metrics`, `/ready`, `/debug/*` | never served (404 behind Access) |
| IPv6 to the host | same as IPv4 (ufw applies to both; admin rules are IPv4 only, so SSH over IPv6 is denied) |

Commands: `docs/CLOUDFLARE-ACCESS.md` § 6 (from outside), `sudo
openctem-verify` (on the host), `ansible-playbook -i <inv>
playbooks/85-exposure-audit.yml` (every container on the host).
