---
title: Self-host on a VM with Ansible
description: Install OpenCTEM on one hardened Ubuntu VM behind Cloudflare Tunnel and Access, with signed images, encrypted backups and a tested restore.
---

# Self-host OpenCTEM on a VM with Ansible

The `openctem-ansible` repository is the supported way to run OpenCTEM on a
single virtual machine. It hardens the host, deploys the platform from signed
release images pinned by digest, puts Cloudflare Tunnel and Access in front
of it, and installs daily encrypted backups, a restore drill and monitoring.
Every stage is opt-in and can be rehearsed with `--check --diff`.

```mermaid
flowchart LR
  people(["People"]) -->|"Access login"| edge["Cloudflare: TLS, Access, WAF"]
  sensors(["Sensors"]) -->|"Access bypass: /api/v2/sensor/*"| edge
  ci(["CI"]) -->|"Access bypass: /api/v1/ci/..."| edge
  cfd -.->|"outbound tunnel"| edge
  subgraph vm["Ubuntu VM: no inbound port but SSH from admin networks"]
    cfd["cloudflared"] --> gw["gateway"]
    gw --> web["web console"]
    web --> api["API"]
    gw --> api
    api --> pg[("PostgreSQL")]
    api --> rd[("Redis")]
  end
```

## What you need

- A VM with 4 vCPU, 8 GB RAM and 80 GB disk, running **Ubuntu 26.04 LTS**,
  with SSH key access for a sudo user and access to its console.
- A DNS zone on Cloudflare and a Cloudflare Zero Trust account connected to
  your identity provider. Without Cloudflare you can put your own TLS reverse
  proxy on the host instead (`openctem_ingress: loopback`).
- An Ansible controller (Linux or macOS) with Python 3.11–3.13.
- An [age](https://age-encryption.org) key pair for backups, kept off the VM.

## Install in short

1. Clone the repository, install `ansible-core` 2.18 and the pinned
   collections, and copy `inventories/example` **outside** the repository.
   Set the VM address, the public host name, the administrator networks and
   your age public key there.
2. In Cloudflare, create a tunnel and store its token on the VM in
   `/opt/openctem/secrets/cloudflared_tunnel_token` (owner 65532, mode 0400).
3. Run the read-only preflight, take a VM snapshot, rehearse with
   `--check --diff`, then apply the stages one by one: OS baseline, SSH (keys
   only after a proven key login), Docker, firewall, OpenCTEM, backups and
   monitoring.
4. In Cloudflare, route the host name to `http://gateway:80`. Protect it with
   an Access application for people (identity provider and MFA). Add Access
   **Bypass** applications for exactly the machine paths sensors and CI call:
   `/api/v2/sensor/*`, `/api/v3/sensor/*`, `/api/v1/ci/oidc/exchange` and
   `/api/v1/ci/runs/*`. Rate-limit those paths with a WAF rule. The paths
   still require sensor keys or CI tokens in OpenCTEM.
5. Create the first administrator on the VM's console with
   `sudo openctem-bootstrap-admin`. The one-time credentials are shown only
   there.
6. Run the acceptance tests: the console and `/api/v1/me` are challenged by
   Access, the sensor path answers 401 without a key, and the VM publishes no
   port.

The repository README is the full runbook. It covers each command, what each
stage changes, backups and restore, upgrades with automatic rollback,
troubleshooting (including Ubuntu 26.04's uutils coreutils and Docker with
ufw) and a hardening checklist.

## Platform console on its own host name

From the release that ships the console plane (`admin_plane: true` in
`versions.yml`), the API serves the platform console's API only on an
internal listener (`ADMIN_LISTEN_ADDR`, the API's fixed address on the origin
network), and you can give the console its own host name:

```yaml
openctem_admin_host: admin.ctem.example.com
openctem_admin_allowed_cidrs: [203.0.113.0/24]   # your staff's egress ranges
```

The gateway then serves the console only on that name, the web console serves
it nowhere else, and `https://<openctem_app_host>/admin` answers 404.
`roles/cloudflared` adds the host name to the tunnel; give it its own
Cloudflare Access application (CLOUDFLARE-ACCESS.md, section 2) with your
administrators only. Behind Cloudflare the client address is the visitor's, so
the default allow-list (private networks only) blocks every visitor: list your
staff's ranges, or `0.0.0.0/0` and `::/0` when the Access application is the
gate. With an older release `openctem_admin_host` is refused and the console
stays on the main host name.

## Security model

- The VM accepts no inbound connection except SSH from your administrator
  networks. The tunnel is outbound-only, and no container publishes a port.
- People pass Cloudflare Access. Sensors and CI bypass it only on their own
  paths, where OpenCTEM authenticates them itself.
- Secrets are generated on the VM and never leave it, except inside encrypted
  backups.
- OpenCTEM images are verified with cosign against the release workflow
  before they run; every other image, package and collection is pinned.
- Upgrades back up first and roll back automatically if the new release fails
  its checks.
