# Host firewall: ufw, Docker and the tunnel

## Policy

- **Inbound:** deny everything except SSH (tcp/22) from `admin_cidrs`. No HTTP
  or HTTPS port is needed: the Cloudflare Tunnel is an outbound connection.
- **Outbound (host):** allowed. The stack's containers have their own
  [outbound policy](#outbound-policy-of-the-stacks-containers). The host needs: Cloudflare's edge on 7844/udp and
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

## The opposite caveat: a host egress allowlist

Published ports fail the other way on a host whose own outbound traffic is
filtered — a corporate baseline that allowlists destinations and drops the
rest on 80 and 443 is the usual shape:

```
-A OUTPUT -d 10.0.0.0/8 -p tcp --dport 443 -j ACCEPT
...
-A OUTPUT -p tcp --dport 443 -j DROP
-A OUTPUT -p tcp --dport 80  -j DROP
```

Docker's bridge subnets are not in a list like that, and with
`userland-proxy: true` (the Docker default; this kit's `daemon.json` turns it
off) the host itself opens a connection to the container — `docker-proxy`
accepts yours on the published port, then dials `172.x.y.z:80`. That second
connection is the host's own outbound traffic, so it meets the `OUTPUT` chain
and is dropped on the container's port, not the published one.

The symptom reads like an application fault and is not one. `curl` prints
`Connected`, sends the request and receives nothing until it times out: the
proxy accepted the connection it could, and the one it could not make leaves
no error to return. Inside the container the server answers normally.

Prove where it stops before changing a rule:

```bash
sudo docker exec <gateway-container> wget -S -O- -T 5 http://127.0.0.1:80/
```

An answer there — `404` is one, when the Host header matches no site — means
the application is healthy and the break is on the host's own network path.
Then allow the bridges, which are virtual interfaces on this machine and not
the internet, so this does not widen the egress policy:

```bash
sudo iptables -I OUTPUT -d 172.17.0.0/16 -j ACCEPT   # docker0
sudo iptables -I OUTPUT -d 172.30.0.0/16 -j ACCEPT   # this stack's networks
```

Check which subnets a host actually uses with `ip -4 addr show | grep -E
'docker0|br-'`; Docker allocates them per network, so they differ per host.

Inbound needs its own rule, because the published port is usually not the one
a baseline already permits: 80 and 443 commonly are, `8080` is not. Keep it
narrow, to the proxy that needs it:

```bash
sudo iptables -I INPUT -s <proxy>/32 -p tcp --dport <published port> -j ACCEPT
```

A reverse proxy on the same host needs neither rule, since loopback traffic
meets neither chain. That is one more reason to prefer it.

Finally, find out what persists the ruleset — `systemctl is-active iptables
nftables firewalld`, then `/etc/sysconfig/iptables` or the equivalent — and
leave that file to whoever owns it. An `-I` rule is gone at the next reboot,
which is the right behaviour while testing and the wrong one afterwards.

## Outbound policy of the stack's containers

Only two containers have a route to the internet: the **API** (network
`egress_api`: threat-intelligence feeds, CI OIDC keys, webhooks, SMTP, identity
providers, integrations) and **cloudflared** (network `egress_tunnel`:
Cloudflare's edge). The gateway, web, console, Postgres and Redis sit on
internal networks only and cannot start a connection out. With the optional
`loopback` ingress the gateway's network is not internal, so it is covered too.

Left open, the API can still be made to call an address on the operator's own
network (a tenant-supplied webhook, identity-provider or template URL that
slipped past the application's SSRF guard): the LAN, the cloud metadata address
or the host itself. `openctem_egress_policy: restricted` closes that at the
network layer. The application guard stays the primary control; this is the
second one.

| Setting | Meaning |
|---|---|
| `openctem_egress_policy: open` | no restriction beyond the networks above |
| `openctem_egress_policy: restricted` | the outbound networks cannot reach `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16` (link-local, cloud metadata), `172.16.0.0/12`, `192.168.0.0/16`, nor any address of this host |
| default | `restricted` when `openctem_signup_mode: open` (tenants are strangers), `open` otherwise |
| `openctem_egress_allow` | operator-approved destinations, see below |
| `openctem_egress_allow_host_dns` | default `true`: the host's DNS resolvers (read when the rules are applied) stay reachable on port 53 |

What stays reachable: the whole internet, the stack itself (it runs on other
networks, and the rules match only packets whose source is an outbound network)
and, from the API, its replies. The networks are IPv4 only, so there is no
IPv6 path to filter.

**Approved internal destinations** (an internal SMTP relay, Jira, an identity
provider):

```yaml
openctem_egress_allow:
  - { cidr: 192.0.2.25/32, port: 587 }          # tcp by default
  - { cidr: 198.51.100.0/28, port: 636, proto: tcp }
```

`cidr` is IPv4, `/24` or narrower, never in `169.254.0.0/16`; `port` and
`proto` narrow it further. Prefer one host and one port. Each entry is a hole
a tenant-controlled URL could aim at: add only what a configured integration
needs.

**Behind a corporate proxy** (outbound mostly blocked, the only way out is an
HTTPS proxy): set `openctem_feed_proxy: 'http://proxy.corp.example:3128'`
(a proxy password goes in `<openctem_secrets_dir>/feed_proxy_url` on the
server, never in the inventory) and, with `restricted`, allow the proxy:
`{ cidr: <proxy address>/32, port: 3128 }`. The API then fetches only its own
feeds through it: vulnerability bundles, CISA KEV, EPSS, the CTEM-ID catalog,
the program feed and the release feed. Webhooks, integrations and anything an
organization configures never go through the proxy. `openctem_feed_no_proxy`
lists hosts reached directly (an internal bundle mirror). Needs an OpenCTEM
release flagged `feed_proxy` in `versions.yml`; the preflight refuses the
settings otherwise.

Hosts the feeds need (HTTPS, port 443) when you allow them at the proxy or the
firewall instead: `github.com`, `release-assets.githubusercontent.com`,
`objects.githubusercontent.com` (vulnerability bundles, release feed);
`www.cisa.gov` then `raw.githubusercontent.com` (KEV); `epss.empiricalsecurity.com`
(EPSS); `ctem.org` (CTEM-ID). KEV and EPSS also arrive inside the signed
vulnerability bundles, and an air-gapped install reads the bundles from a
local directory: OpenCTEM `server/docs/deployment/air-gapped.md`
(`api/docs/deployment/air-gapped.md` in v0.20.x and earlier).

**How it is enforced.** `playbooks/35-firewall.yml` (with `apply_firewall`)
installs `/usr/local/sbin/openctem-egress` and a systemd unit. The script
writes two chains of its own, `OPENCTEM-EGRESS` (forwarded traffic: LAN,
internet, metadata) and `OPENCTEM-EGRESS-IN` (traffic to the host itself),
loaded in one atomic `iptables-restore`, and jumps to them first from
`DOCKER-USER` and `INPUT`. It is idempotent. The unit re-applies it at boot and
whenever Docker restarts, and `openctem-monitor` alerts when a jump is missing.
Needs Docker's iptables backend (`docker info --format '{{.FirewallBackend}}'`);
the role refuses the nftables backend rather than pretend. Rerun the play after
changing a resolver or the allow-list.

```bash
sudo openctem-egress status     # rules and packet counters
sudo openctem-egress remove     # drop the rules (the next play run re-applies them)
```

Switching back to `open` and rerunning the play removes the rules and the unit.
`tests/smoke.sh` proves the policy in an isolated Docker-in-Docker: a container
on the API's networks reaches the internet and Postgres, an allow-listed
destination, and not another private address, the host or the metadata address.

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
gateway believes `Cf-Connecting-Ip` only from cloudflared's fixed address and
hands the API the one resolved address, and the API believes forwarding
headers only from the gateway and web. An internal network
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
| API container → private LAN address, `169.254.169.254`, the host (policy `restricted`) | dropped (an allow-listed destination works) |
| API container → internet, postgres, redis | works |
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
