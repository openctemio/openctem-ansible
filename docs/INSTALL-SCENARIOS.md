# Installation scenarios

The README walks through one happy path: a host that reaches the internet. This
document covers the rest — restricted networks, both supported operating
systems, and both ingress modes — so you can find your situation and follow the
steps for it instead of adapting the happy path yourself.

Read [What the install needs from the network](#what-the-install-needs-from-the-network)
first, then jump to your scenario. The [common ground](#common-ground) applies
to all of them.

## What the install needs from the network

Six classes of dependency reach outside the host. Any scenario that restricts
the network has to answer for each one.

| # | Dependency | Reached from | Default source |
|---|---|---|---|
| 1 | Container images (10 per release) | the **host**, via `docker compose pull` | `ghcr.io/openctemio`, `docker.io` |
| 2 | cosign signature check | the **host**, in a container | Fulcio, Rekor, the sigstore TUF root |
| 3 | OS packages (chrony, auditd, aide, rsyslog, fail2ban, ufw/firewalld) | the **host** | the distribution's archive |
| 4 | Docker Engine packages | the **host** | `download.docker.com` |
| 5 | Time synchronisation | the **host** | the distribution's NTP pool |
| 6 | Ansible collections | the **controller** | `galaxy.ansible.com` |

Note which side each one is on. Items 1–5 are pulled by the **host**, not by
Ansible — so a controller with internet access does not, on its own, give the
host anything. That is what scenarios B and C are about.

## Choose your scenario

| Your situation | Scenario |
|---|---|
| The host reaches the internet (directly or via NAT) | [A](#scenario-a--the-host-reaches-the-internet) |
| Only the Ansible controller reaches the internet | [B](#scenario-b--only-the-controller-reaches-the-internet) |
| The host reaches a registry you already run, but not the internet | [B3](#option-b3--a-registry-your-organisation-already-runs) |
| Neither reaches the internet; files cross on removable media | [C](#scenario-c--a-true-air-gap) |
| Everything goes through a corporate HTTP proxy | [D](#scenario-d--a-corporate-http-proxy) |

## Common ground

### The controller

The controller needs Ansible and the pinned collections. It never needs Docker.

```bash
ansible-galaxy collection install -r requirements.yml -p ./collections
```

The collections land in `./collections` (git-ignored) and `ansible.cfg` already
points there, so this is the only step that touches Galaxy. In an air gap,
download them once on a connected machine and copy the directory across — see
[scenario C](#scenario-c--a-true-air-gap).

Ansible does not run on Windows. Use WSL2, a Linux VM, or a jump host.

### The inventory

Copy `inventories/example/` to a directory of your own, **outside this
repository**, so your site settings are not mixed into the kit:

```
inventories/mysite/
  hosts.ini
  group_vars/
    all.yml      # from all.yml.example
    vault.yml    # ansible-vault, for the monitoring webhook
```

Every option below goes in `group_vars/all.yml` unless stated otherwise.

### Which operating system

Both are first-class; the roles switch on `ansible_os_family`. The preflight
accepts Ubuntu ≥ 24.04 or Rocky/Alma/RHEL ≥ 9 and refuses anything else.

| | Ubuntu 24.04+ | Rocky / Alma / RHEL 9 |
|---|---|---|
| Packages | apt | dnf |
| Firewall | ufw | firewalld (drop zone + rich rules) |
| Mandatory access control | AppArmor | SELinux |
| Unattended security updates | `unattended-upgrades` | `dnf-automatic` |
| audit daemon package | `auditd` | `audit` |
| fail2ban | in the archive | needs **EPEL**, installed by the role |
| Docker version pins | `docker_ce_version` and friends | `docker_rpm_ce_version` and friends |

**Ubuntu version pins are the usual first failure.** `versions.yml` pins the
Docker packages for Ubuntu 26.04 (`resolute`). On 24.04 those exact version
strings do not exist and the install stops. Override all four, taking the exact
values from `apt-cache madison docker-ce` on the host — the shape is:

```yaml
docker_apt_codename: noble
docker_ce_version: '5:<version>-1~ubuntu.24.04~noble'
docker_containerd_version: '<version>-1'
docker_compose_plugin_version: '<version>-1~ubuntu.24.04~noble'
```

**On Rocky the three RPM pins are empty by default**, which installs the latest
Docker CE. Pin them for a reproducible build:

```yaml
docker_rpm_ce_version: '29.9.0-1.el9'
docker_rpm_containerd_version: '2.4.2-1.el9'
docker_rpm_compose_plugin_version: '5.6.0-1.el9'
```

List the candidates with `dnf list --showduplicates docker-ce`.

### Which ingress

`openctem_ingress` decides how traffic reaches the gateway, and nothing else in
the kit changes.

**`loopback`** (the default) binds the gateway to `127.0.0.1` and expects your
own TLS terminator — nginx, Caddy, an existing load balancer — in front of it.
Nothing else is needed:

```yaml
openctem_ingress: loopback
openctem_app_host: ctem.example.com
```

**`cloudflared`** runs a Cloudflare Tunnel, so the host opens no inbound port at
all. You place the tunnel token on the host yourself, before
`playbooks/50-openctem.yml` runs; the preflight only reads its metadata and
asserts the ownership:

```bash
sudo install -d -m 0700 -o root -g root /opt/openctem/secrets
printf '%s' "$TOKEN" | sudo install -m 0400 -o 65532 -g 65532 /dev/stdin \
  /opt/openctem/secrets/cloudflared_tunnel_token
```

```yaml
openctem_ingress: cloudflared
cloudflared_management: remote   # or 'local' for a locally managed tunnel
```

A token that is not a non-empty regular file owned by uid 65532, mode 0400, in
a 0700 root-owned directory, fails the preflight. See
[CLOUDFLARE-ACCESS.md](CLOUDFLARE-ACCESS.md) for the Access applications that
guard the console and the machine paths.

### Running the stages

`site.yml` imports every stage in runbook order, and each one runs only when its
`apply_*` flag is true. Rehearse before applying:

```bash
ansible-playbook -i inventories/mysite site.yml --check --diff
ansible-playbook -i inventories/mysite site.yml -e apply_os=true -e apply_ssh=true
```

Order matters: `00-preflight` → `10-os` → `20-ssh` → `30-docker` → `35-firewall`
→ `50-openctem` → `55-backup` → `60-monitoring` → `80-audit`. Apply SSH
hardening in two steps (`ssh_stage: 1`, then `2`) so you do not lock yourself
out, and keep `admin_cidrs` correct — the firewall allows SSH only from there.

### Time synchronisation

The preflight and the OS role both fail when the clock is unsynchronised or
more than `os_baseline_clock_max_offset` seconds out, because sensor request
signatures allow only about two minutes of skew. The role installs chrony and
writes a `makestep` drop-in, but it **does not choose your NTP servers** — the
distribution's defaults stay.

On a restricted network those defaults often cannot work, and the failure is
confusing: `chronyc sources` shows servers that answer, yet `chronyc tracking`
reports `Stratum 0` and nothing is ever selected. Recent Ubuntu ships NTS pools
marked `prefer`, and NTS needs **TCP 4460** in addition to UDP 123. Block 4460
and chrony has no selectable source at all. Point it at a reachable server
instead:

```bash
# /etc/chrony/conf.d/local-ntp.conf  (Debian)  or  /etc/chrony.d/  (RedHat)
server ntp.example.internal iburst
authselectmode ignore
```

Then `sudo systemctl restart chrony && sudo chronyc makestep`.

---

## Scenario A — the host reaches the internet

The README's path. Nothing from this document is needed beyond the OS and
ingress choices above.

```bash
ansible-playbook -i inventories/mysite site.yml --check --diff
ansible-playbook -i inventories/mysite site.yml \
  -e apply_os=true -e apply_ssh=true -e apply_docker=true \
  -e apply_firewall=true -e apply_openctem=true
```

Signatures are verified on the host against sigstore, as designed. Leave
`openctem_verify_signatures` alone.

Note that the egress firewall restricts the **containers**, not the host's own
package and image pulls — see [FIREWALL.md](FIREWALL.md).

---

## Scenario B — only the controller reaches the internet

This is the common enterprise shape: your workstation or a jump host can reach
GitHub and Docker Hub, the production VM cannot. The controller already has an
SSH channel to the host, and both options below reuse it.

### First, what does not work

Pulling images on the controller and loading them onto the host with
`docker save` / `docker load` **does not work**, and it fails in a way that is
easy to misread. `compose.yml` pins every image by digest, but a digest is
registry metadata: a `docker load`ed image carries no `RepoDigests`, so
`docker compose pull` still tries to fetch it and fails. The image is sitting
right there on the host and Docker cannot match it.

The fix is not to abandon the idea — it is to ship the images through something
that keeps digests, which means a registry.

### Option B1 — a registry on the host (recommended)

Run a small registry on the host itself, push into it from the controller
through the SSH tunnel, and point the kit at `127.0.0.1`. The host then pulls
from its own loopback and never touches the internet.

**1. Put `registry:2` on the host.** This one image may travel by
`save`/`load`, because it is run by tag from the command line, not by digest
from a compose file:

```bash
docker pull registry:2 && docker save registry:2 -o registry2.tar
scp registry2.tar user@host:/tmp/
ssh user@host "sudo docker load -i /tmp/registry2.tar && \
  sudo docker run -d --restart=always --name registry \
    -p 127.0.0.1:5000:5000 -v /var/lib/registry:/var/lib/registry registry:2"
```

**2. Open a forward to it** from the controller:

```bash
ssh -N -L 5000:127.0.0.1:5000 user@host &
```

**3. Mirror the release.** `scripts/mirror-images.sh` reads `versions.yml`,
verifies each OpenCTEM image against the release workflow's signature, and
copies all ten with their digests intact:

```bash
scripts/mirror-images.sh v0.15.2 \
  127.0.0.1:5000/openctem 127.0.0.1:5000/mirror \
  --dest-insecure
```

Preview with `--dry-run` first. The controller needs `skopeo` and `cosign`.

**4. Point the inventory at the loopback registry:**

```yaml
openctem_registry_mirror: 127.0.0.1:5000/openctem
openctem_third_party_registry_mirror: 127.0.0.1:5000/mirror
openctem_verify_signatures: false
```

**Why `openctem_verify_signatures: false` is correct here, and only here.** The
check runs *on the host*, in a container, and needs sigstore. The host has no
internet, so it cannot run it. What replaces it is stronger than nothing:
`mirror-images.sh` verified every image on the controller, where sigstore *is*
reachable, before copying — and `versions.yml` still pins every digest, so a
registry that served different bytes would fail the pull. Verification moved to
the boundary; it did not disappear. Do not set this flag in scenario A, where
the host can do the check itself.

If your registry has a real certificate and your host *can* reach sigstore,
keep the check on the host instead: mirror the signatures with
`--signatures` (which runs `cosign copy`) and leave
`openctem_verify_signatures` at its default. Plain-HTTP registries cannot do
this — the cosign check does not pass `--allow-insecure-registry`.

**What this option does not solve:** OS and Docker packages (dependencies 3 and
4). Either pre-install them, mirror the distribution repositories internally, or
use option B2, which covers everything at once.

### Option B2 — a reverse-tunnelled HTTP proxy

Run an HTTP proxy on the controller and expose it on the host's loopback for the
duration of the run. Every dependency — images, signatures, OS packages, Docker
packages — then resolves normally.

In the inventory:

```ini
host ansible_host=10.0.0.5 ansible_ssh_common_args='-R 3128:127.0.0.1:3128'
```

```yaml
docker_daemon_settings:
  log-driver: json-file
  log-opts: {max-size: "{{ docker_log_max_size }}", max-file: "{{ docker_log_max_file }}"}
  live-restore: true
  userland-proxy: false
  no-new-privileges: true
  proxies:
    http-proxy: http://127.0.0.1:3128
    https-proxy: http://127.0.0.1:3128
    no-proxy: localhost,127.0.0.1,::1
docker_daemon_restart: true
```

apt and dnf need the proxy too, and they run before Docker does, so write it on
the host once before the first run (`/etc/apt/apt.conf.d/01proxy` with
`Acquire::http::Proxy "http://127.0.0.1:3128";`, or `proxy=` in `/etc/dnf/dnf.conf`).

**Trade-off.** B2 is less work and keeps `compose.yml` referencing the canonical
`ghcr.io` digests, with signature verification running on the host as designed.
But the host genuinely reaches the internet while the playbook runs, through the
controller. If that is a policy violation rather than a routing fact, use B1.
Also keep the SSH connection alive: if the tunnel drops mid-`pull`, the pull
fails.

### Option B3 — a registry your organisation already runs

B1 stands up a registry because there is none. If there already is one — Harbor,
Nexus, Artifactory, a GitLab container registry — and the host is allowed to
reach it, mirror into that instead and skip the tunnel entirely:

```bash
scripts/mirror-to-registry.sh v0.17.0 registry.example.com
```

It wraps `mirror-images.sh` with the preview, the cosign run, and the check that
the registry serves every image back **by its pinned digest** — the failure mode
B1 cannot hit, because a registry that re-serialises manifests on push breaks
the pins while reporting a successful copy.

Then set the same two variables as B1, or, for a directory from
`scripts/render-standalone.yml`, render it with them. The host needs no internet
at all, and the images inherit the registry's retention, access control and
audit trail.

[docs/CORPORATE-REGISTRY.md](CORPORATE-REGISTRY.md) is the walkthrough:
repository layout, certificates, credentials, upgrades.

---

## Scenario C — a true air gap

Nothing on either side reaches the internet. Work in three phases, with a
staging machine that does have access.

**Phase 1, on the staging machine.** Collect everything:

```bash
# Ansible collections
ansible-galaxy collection install -r requirements.yml -p ./collections

# Images, verified then written to a directory tree you can carry
scripts/mirror-images.sh v0.15.2 registry.internal/openctem registry.internal/mirror --dry-run
# ... run the printed cosign verify commands, then copy each image with
#     skopeo copy --all --preserve-digests docker://<src> dir:/media/openctem/<name>
```

Also download the OS packages (`apt-get download` / `dnf download --resolve`)
for: chrony, auditd (`audit` on RedHat), aide, rsyslog, fail2ban (plus EPEL on
RedHat), ufw or firewalld, unattended-upgrades or dnf-automatic — and the four
Docker Engine packages.

**Phase 2.** Carry the media across.

**Phase 3, inside the air gap.** Load the images into your internal registry
with `skopeo copy --all --preserve-digests dir:/media/... docker://registry.internal/...`,
put the collections in `./collections`, serve the packages from an internal apt
or dnf mirror, and configure a local NTP server. Then the inventory is the same
as B1, with your registry's name:

```yaml
openctem_registry_mirror: registry.internal/openctem
openctem_third_party_registry_mirror: registry.internal/mirror
openctem_verify_signatures: false   # verified in phase 1
openctem_registry_ca_file: /etc/ssl/certs/registry-ca.pem
openctem_registry_docker_config_dir: /root/.docker
```

Run `docker login registry.internal` on the host once if the registry
authenticates; the cosign check reads that config from
`openctem_registry_docker_config_dir`.

To keep the host-side signature check in an air gap, you would also have to
mirror the signatures (`cosign copy`), pre-seed the sigstore TUF root with
`cosign initialize`, and refresh it before it expires. Verifying at the
boundary in phase 1 is simpler and is what this document recommends.

---

## Scenario D — a corporate HTTP proxy

Both sides reach the internet, but only through a proxy. This is scenario A plus
proxy configuration in four places:

- **Docker daemon** — the `proxies` block shown in [B2](#option-b2--a-reverse-tunnelled-http-proxy),
  with your proxy's address.
- **apt or dnf** — `/etc/apt/apt.conf.d/01proxy` or `proxy=` in `/etc/dnf/dnf.conf`.
- **The cosign container** — it inherits nothing from the host's shell. If your
  proxy is the only route to sigstore, verify on the controller and use
  `openctem_verify_signatures: false`, as in B1.
- **The controller**, for `ansible-galaxy`: `https_proxy=... ansible-galaxy collection install ...`

If the proxy terminates TLS with its own CA, add that CA to the host's trust
store and set `openctem_registry_ca_file` so the cosign container trusts it too.

---

## Signatures, scenario by scenario

| Scenario | Where verification happens | `openctem_verify_signatures` |
|---|---|---|
| A | On the host, against sigstore | leave at default (`true`) |
| B1 | On the controller, before mirroring | `false` |
| B1 + `--signatures` + TLS registry | On the host, against the mirror | leave at default |
| B2 | On the host, through the tunnel | leave at default |
| B3 | On the mirroring machine, before copying | `false` |
| C | On the staging machine, phase 1 | `false` |
| D | Controller or host, depending on the proxy | see above |

Setting the flag to `false` is only defensible when something else verified the
images first and the digests in `versions.yml` are unchanged. It is never a way
to get past a failing check in scenario A — there, a failure means the digest is
not signed by the release workflow at that tag, or sigstore is unreachable, and
both deserve investigation.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Preflight: *Unsupported OS* | Ubuntu < 24.04, or a RedHat family release < 9 |
| Preflight: clock is not synchronised | NTP blocked; see [Time synchronisation](#time-synchronisation) |
| `docker-ce=... not found` on Ubuntu | version pins are for 26.04; override for your release |
| `docker compose pull` fails with no internet | images were `docker load`ed, so they carry no digest — use a registry (B1) |
| Pull fails against a mirror | the mirror was filled without `--preserve-digests`, so the digest changed |
| Pull fails against a mirror filled *with* `--preserve-digests` | the registry re-serialised the manifest on push; `scripts/mirror-to-registry.sh` catches this at mirroring time |
| Third-party image not found on the mirror | the path after the host must be kept: `<mirror>/library/postgres`, not `<mirror>/postgres` |
| Deploy stops at *Verify the release signatures* | the host cannot reach sigstore, or the signature is not on the mirror |
| fail2ban missing on Rocky | EPEL is unreachable; mirror it or pre-install the package |
| Locked out after the SSH stage | `admin_cidrs` did not include your address; recover from the console |

## See also

- [self-hosting-with-ansible.md](self-hosting-with-ansible.md) — the guided walkthrough
- [CORPORATE-REGISTRY.md](CORPORATE-REGISTRY.md) — mirroring into a registry you already run
- [FIREWALL.md](FIREWALL.md) — ingress and container egress policy
- [CLOUDFLARE-ACCESS.md](CLOUDFLARE-ACCESS.md) — Access applications for the tunnel
- [BACKUP-PITR.md](BACKUP-PITR.md) — backups and point-in-time recovery
- The README's *Private registry / air-gapped* section — the variable reference
