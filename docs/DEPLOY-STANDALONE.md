# Deploying without Ansible, end to end

`scripts/render-standalone.yml` turns the roles into a directory a server runs
with `docker compose` alone. [CORPORATE-REGISTRY.md](CORPORATE-REGISTRY.md)
covers getting the images into a registry you already run; this page is the
whole path from there, for the common shape where three machines each do one
job:

| Machine | Reaches | Does |
|---|---|---|
| Build host | the internet and the registry | mirrors the images, renders the directory |
| Registry | — | holds the images; Harbor, Nexus, Artifactory, a cloud registry |
| Server | the registry only | runs the stack |

Ansible is needed once, on the build host, and never touches the server. The
server needs Docker with the compose plugin, and nothing else: no Ansible, no
Python, no Galaxy collections. It needs no outbound internet access at all.

## Two things that look like shortcuts and are not

Both of these produce a deployment that appears to work on the build host and
fails on the server, with an error that does not name the cause. They are
worth reading before the steps rather than after.

### `docker pull` then `docker push` does not mirror an image

A digest is registry metadata, and `compose.yml` pins every image by digest.
Pulling an image, tagging it and pushing it re-serialises the manifest on the
way out, so the copy in your registry answers to the tag under a **different**
digest. The image is plainly there in the registry's web interface, and the
server's pull fails with `manifest unknown`.

Only `skopeo copy --all --preserve-digests` preserves it, which is what
`scripts/mirror-images.sh` runs. A pleasant consequence: the build host needs
`skopeo`, not Docker — the copy goes registry to registry and never touches
local storage.

`docker save` and `docker load` fail the same way, for the same reason: an
image that arrived through `docker load` carries no `RepoDigests`, so the pin
matches nothing at all.

### The rendered bundle is a directory, not a compose file

`compose.yml` bind-mounts the release's configuration by absolute path:

```yaml
- /opt/openctem/releases/<version>/gateway:/etc/caddy:ro
- /opt/openctem/releases/<version>/postgres:/bootstrap:ro
```

Copying `compose.yml` on its own leaves the gateway without its Caddyfile and
PostgreSQL without its least-privilege role script. The containers start and
die, and the logs point at neither. Carry the whole directory:

```
compose.yml
.env                                   COMPOSE_PROJECT_NAME, COMPOSE_FILE
NEXT-STEPS.md
scripts/openctem-secrets               generates secrets, runs ON the server
scripts/openctem-verify
releases/<version>/SHA256SUMS
releases/<version>/gateway/            Caddyfile, modes, admin, sensors
releases/<version>/postgres/least-privilege-roles.sql
```

## 1. Mirror the release

On the build host, with push rights on the registry:

```bash
scripts/mirror-to-registry.sh v0.17.0 registry.example.com
```

It previews the plan, asks once, copies, and reads every image back from the
registry by the digest `versions.yml` pins. See
[CORPORATE-REGISTRY.md](CORPORATE-REGISTRY.md) for the options, the two
repository prefixes, and what to do when that read-back fails.

The build host needs `skopeo`, and for the signature check either `cosign`
(**version 3** — see the troubleshooting table) or Docker, through which the
script runs the cosign image `versions.yml` pins. It needs Docker for nothing
else: `skopeo` copies registry to registry without local storage.

## 2. Render the directory

Put the deployment's settings in a variables file. Keep it outside the kit's
working tree: it names your hosts and networks, and it is not something to
commit by accident.

```yaml
# deployment.yml
openctem_version: v0.17.0
openctem_root: /opt/openctem

openctem_app_host: ctem.example.com

openctem_ingress: loopback
openctem_loopback_bind: 0.0.0.0        # 127.0.0.1 when the proxy is on this host
openctem_loopback_port: 8080
openctem_trusted_proxies:
  - 198.51.100.7/32                    # the proxy in front, by address

openctem_admin_site: host
openctem_admin_host: admin.example.com
openctem_admin_port: 8443
openctem_admin_allowed_cidrs:
  - 127.0.0.0/8
  - '::1/128'
  - 10.0.0.0/8

openctem_registry_mirror: registry.example.com/openctem
openctem_third_party_registry_mirror: registry.example.com/openctem-3p
```

```bash
ansible-playbook scripts/render-standalone.yml \
  -e out_dir=/tmp/openctem-bundle \
  -e @deployment.yml
```

`openctem_trusted_proxies` is worth getting right the first time. The gateway
takes the client address from `X-Forwarded-For` only when the peer that sent it
is listed here. Leave it wrong and every client address in the logs is the
proxy's own — an access trail that records nothing.

Ansible does not run natively on Windows (`os.get_blocking` is a Unix API, so
the CLI exits with `OSError: [WinError 87]`). Render on Linux, or in WSL.

## 3. Check before carrying

```bash
grep -nE '^[[:space:]]*image:[[:space:]]*(ghcr\.io|docker\.io)/' /tmp/openctem-bundle/compose.yml
```

This must print nothing. A line that survives means the render did not pick up
the mirror variables, and the server — which cannot reach those registries —
will fail to pull.

The pattern is anchored at the registry host, everything before the first
slash, rather than searching the line for `ghcr.io` anywhere in it. Registries
are often laid out as `<registry>/<project>/<original-host>/<path>`, which
keeps an image's provenance visible in its name. Under that layout every
correctly rewritten line still contains `ghcr.io` or `docker.io`, and the
looser pattern reports all of them. Listing the hosts is the other way to read
the same thing, and shows your registry and nothing else:

```bash
grep -oE '^[[:space:]]*image:[[:space:]]*[^/]+' /tmp/openctem-bundle/compose.yml | sort -u
```

## 4. Carry it over

```bash
tar -czf openctem-bundle.tar.gz -C /tmp/openctem-bundle .
scp openctem-bundle.tar.gz server:
```

## 5. Deploy

The path matters: `compose.yml` refers to `openctem_root` by absolute path, so
the directory goes exactly where it was rendered for. To use another, render
again with `-e openctem_root=...`.

```bash
sudo mkdir -p /opt/openctem
sudo tar -xzf openctem-bundle.tar.gz -C /opt/openctem
sudo chown -R root:root /opt/openctem
cd /opt/openctem

sudo docker login registry.example.com
sudo docker compose pull

sudo mkdir -p /opt/openctem/secrets && sudo chmod 0700 /opt/openctem/secrets
sudo scripts/openctem-secrets

# two secrets are read by a container running as its own user
sudo chown 999:1000 /opt/openctem/secrets/redis.conf
sudo chown 999:999  /opt/openctem/secrets/db_superuser_password

# the job signer's key: nothing else creates it
sudo docker compose run --rm --no-deps -T \
    signer keygen -out /var/lib/openctem-signer/keys/signer.pem

sudo docker compose config --quiet
sudo docker compose up -d
sudo scripts/openctem-verify
```

The two steps between generating the secrets and starting are the ones the
Ansible path performs and this directory does not carry.

`openctem-secrets` writes every file mode 0400 owned by root, which is right
for the ones Compose reads as root and wrong for the two a container opens as
its own user. Redis without a readable `redis.conf` restarts in a loop and
says nothing about permissions. The ids are given numerically on purpose:
those users do not exist on the host, so a name would not resolve.

The signer key is not one of the files `openctem-secrets` writes, and the
signer refuses to start without it — `signer.pem: no such file or directory`,
over and over. Create it once, before the first start. It prints a key id and
the PUBLIC key, both worth recording; the private key stays in the
`signer-keys` volume and is never mounted into the API.

An internal certificate authority goes in
`/etc/docker/certs.d/<registry>/ca.crt`, where `<registry>` includes the port
if the registry uses one. A registry whose certificate a public CA already
signs needs nothing.

Log in even against a registry that allows anonymous pulls. It costs one
command, and it means a registry that is later closed to anonymous access does
not stop the stack with an error that looks like something else.

`openctem-secrets` runs here, on the server, once. It prints file names and
never values, so no password is created on the build host or travels in the
archive. Do not run it on the build host and copy `secrets/` across: that puts
every key the deployment has through an intermediate machine and leaves it
inside a tar file.

### The first administrator

The rendered directory does not carry the `openctem-bootstrap-admin` wrapper
that the Ansible path installs, so call the service directly:

```bash
sudo docker compose run --rm --no-deps bootstrap-admin \
  -email=admin@example.com -backup-email=breakglass@example.com
```

Run it on the console or an interactive SSH session. The credentials are
printed once, and the service sets `logging: driver: none` so nothing keeps
them. Do not redirect the output.

## The proxy in front

With `openctem_ingress: loopback` the gateway speaks plain HTTP on
`openctem_loopback_bind:openctem_loopback_port`. Your proxy owns TLS and is the
only thing in front of the application:

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Host $host;
```

When the proxy runs on another host, the port carries plain HTTP across the
network, so the network itself is the only thing protecting it.

In `host` admin mode the console is its own virtual host
(`openctem_admin_host`, on `openctem_admin_port`), not a path on the
application site: the application port answers 404 for `/api/v1/admin`.

## Upgrading

Every release moves every digest, so an upgrade is: mirror the new tag, render
again, replace the directory, start.

```bash
scripts/mirror-to-registry.sh v0.17.1 registry.example.com
ansible-playbook scripts/render-standalone.yml \
  -e out_dir=/tmp/openctem-bundle-next \
  -e @deployment.yml -e openctem_version=v0.17.1
```

Read the release notes first and back the database up before starting: a
release that migrates the schema is not reversible by starting the previous
compose file. Keep the previous release's tags in the registry — a rollback
needs them.

## What you are taking on

The Ansible path does more than start containers, and none of it is here: host
hardening, a firewall, unattended security updates, time sync, file integrity
monitoring, backups with a tested restore, and monitoring. Running the stack
this way is supported; the rest of that list becomes yours.

Image signatures move rather than disappear. `openctem_verify_signatures` has
no effect without Ansible, but `mirror-to-registry.sh` verified every image on
the build host, where sigstore is reachable, and the digests stay pinned in
`compose.yml` — a registry serving different bytes fails the pull. The check
happens at the boundary instead of on the server.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `manifest unknown` on the server, image visible in the registry UI | mirrored with `docker push`, or the registry re-serialised the manifest |
| `cosign` says `no signatures found` for a release that is signed | cosign 2 looking for the `sha256-<digest>.sig` tag; the signatures are under the referrers fallback tag `sha256-<digest>` that cosign 3 writes when the registry has no referrers API. Install cosign 3 |
| `neither cosign nor docker is available` | install cosign 3 on the build host, or Docker so the script can run the pinned cosign image |
| `unauthorized ... action: push` while copying | the account can pull but not push to that project; nothing is written, so it is safe to fix the rights and re-run |
| Gateway container starts and exits immediately | only `compose.yml` was copied; `releases/<version>/gateway/` is missing |
| `signer.pem: no such file or directory`, signer restarting | the signer key was never created; run `scripts/openctem-signer-key` |
| `curl` connects to the published port, then times out with 0 bytes | the host's own egress policy drops the proxy's connection to the container; see [FIREWALL.md](FIREWALL.md#the-opposite-caveat-a-host-egress-allowlist) |
| Redis restarting, no error about permissions | `secrets/redis.conf` is still root-owned 0400; `chown 999:1000` it |
| `db-roles`: `Permission denied` on `/bootstrap/least-privilege-roles.sql` | the directory arrived without world-read; `chmod -R a+rX <root>/releases` |
| `compose.yml` still names `ghcr.io` or `docker.io` | rendered without the mirror variables; re-render, or rewrite with `scripts/compose-use-mirror.sh` |
| Every client address in the logs is the proxy's | `openctem_trusted_proxies` does not list the proxy |
| Console unreachable | wrong virtual host, or the client is outside `openctem_admin_allowed_cidrs` |
| `OSError: [WinError 87]` from `ansible-playbook` | Ansible does not run natively on Windows; render on Linux or WSL |
| `x509: certificate signed by unknown authority` | the CA is not in `/etc/docker/certs.d/<registry>/ca.crt` |

## See also

- [CORPORATE-REGISTRY.md](CORPORATE-REGISTRY.md) — mirroring into a registry you already run
- [INSTALL-SCENARIOS.md](INSTALL-SCENARIOS.md) — every network shape, including the air gap
- [README, Private registry / air-gapped](../README.md#private-registry--air-gapped) — the variable reference
