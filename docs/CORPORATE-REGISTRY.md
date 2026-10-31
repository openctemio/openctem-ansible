# Running from a registry your organisation already has

This is scenario B of [INSTALL-SCENARIOS.md](INSTALL-SCENARIOS.md) in its most
common enterprise form: the production host is not allowed out to the internet,
but it is allowed to reach a container registry — Harbor, Nexus, Artifactory, a
GitLab container registry, a cloud registry — that someone already runs, backs
up and authenticates against.

[Option B1](INSTALL-SCENARIOS.md#option-b1--a-registry-on-the-host-recommended)
stands up a throwaway `registry:2` on the host because, in that story, there is
nothing else. If a registry already exists, use it: you get its retention,
backups, access control and audit trail, and the OpenCTEM host ends up needing
no outbound internet access at all.

Two things have to be true. The host must reach the registry, and the machine
doing the mirroring must reach both the registry and the internet. The latter
is usually a workstation or jump host — the Ansible controller, if you use
Ansible. It is never the OpenCTEM host.

## Why this cannot be done with `docker save` and `docker load`

`compose.yml` pins every image by digest, and a digest is registry metadata. An
image that arrived through `docker load` carries no `RepoDigests`, so the pin
matches nothing and `docker compose pull` goes looking on the internet for an
image that is already on the disk in front of it. The long version is in
[INSTALL-SCENARIOS.md](INSTALL-SCENARIOS.md#first-what-does-not-work). Images
have to travel through a registry, which is what this document is about.

## 1. Create two repository prefixes

The two mirror settings are separate because the rewriting rules differ:

| Prefix | Holds | Rule |
|---|---|---|
| `<registry>/openctem` | the five OpenCTEM images | `ghcr.io/openctemio/NAME` to `<prefix>/NAME` |
| `<registry>/openctem-3p` | PostgreSQL, Redis, rclone, cloudflared, cosign | `docker.io/PATH` to `<prefix>/PATH`, path kept |

The second rule keeps the whole path, so PostgreSQL lands at
`<prefix>/library/postgres`, not `<prefix>/postgres`. A registry that forbids
nested repository paths cannot hold the third-party images under one project;
give them a project each and set the prefix accordingly.

On Harbor these are two projects. Create them before mirroring — nothing below
creates them for you. The account you mirror with needs push rights on both;
the account the host uses needs only pull.

## 2. Mirror the release

```bash
scripts/mirror-to-registry.sh v0.17.0 registry.example.com
```

It previews the plan, asks once, copies, and then reads every image back from
the registry **by the digest `versions.yml` pins**. That last step is the point
of the script. `skopeo copy` is run with `--preserve-digests`, but a registry
that re-serialises a manifest on the way in produces a copy that answers to the
tag and not to the digest. The copy reports success. The failure appears days
later, on the host, as a pull that cannot find an image you can see in the
registry's web interface. Catching it here costs one round trip per image.

Useful options:

| Option | When |
|---|---|
| `--insecure` | the registry serves plain HTTP or a self-signed certificate |
| `--signatures` | you want the host to verify signatures itself; see below |
| `--yes` | unattended runs |
| `--no-verify` | the mirroring machine cannot reach sigstore either |

`OC_PROJECT` and `TP_PROJECT` override the two prefix names (`openctem` and
`openctem-3p`).

The script needs `skopeo`. It does not need `cosign` installed: when the binary
is missing it runs cosign from the image `versions.yml` already pins, so a
missing tool never quietly degrades into an unverified mirror.

Underneath it is [`scripts/mirror-images.sh`](../scripts/mirror-images.sh),
which reads `versions.yml` and is the single source of truth for what gets
copied. Call that directly if you want the copying without the wrapper.

## 3. Deploy with Ansible

Put the two values the script prints into the inventory's `group_vars/all.yml`:

```yaml
openctem_registry_mirror: registry.example.com/openctem
openctem_third_party_registry_mirror: registry.example.com/openctem-3p
openctem_verify_signatures: false   # verified while mirroring; see Signatures
```

The README's [Private registry / air-gapped](../README.md#private-registry--air-gapped)
section is the full variable reference, including
`openctem_registry_docker_config_dir` and `openctem_registry_ca_file`.

## 4. Deploy without Ansible

[`scripts/render-standalone.yml`](../scripts/render-standalone.yml) turns the
roles into a directory the server runs with `docker compose` alone. Render it
with the mirror variables and the image references come out already pointing at
your registry:

```bash
ansible-playbook scripts/render-standalone.yml \
  -e out_dir=/tmp/openctem-bundle \
  -e openctem_version=v0.17.0 \
  -e openctem_app_host=ctem.example.com \
  -e openctem_ingress=loopback \
  -e openctem_registry_mirror=registry.example.com/openctem \
  -e openctem_third_party_registry_mirror=registry.example.com/openctem-3p
```

Copy the directory to the server and follow the `NEXT-STEPS.md` it writes.
Ansible is needed once, here, on the machine that renders; the server never
sees it.

### Re-pointing a directory that is already rendered

When the directory exists already — it was rendered without the mirror, or it
is deployed and you are moving it off the public registries — rewriting it in
place avoids a round trip through the controller:

```bash
scripts/compose-use-mirror.sh /opt/openctem/compose.yml registry.example.com
```

It applies the same two substitutions, on `image:` lines only, and refuses to
leave the file changed if a digest moved or if any image still points at
`ghcr.io` or `docker.io`. It writes a timestamped backup first and restores
from it on either failure. Add `PULL=1` to pull straight away.

Prefer re-rendering when you can: the rewrite only touches image references, so
a directory rendered from an older kit stays older in every other respect.

## Certificates and credentials

The host needs `docker login <registry>` once, as the user that runs compose
(root, under the Ansible path). An internal certificate authority goes in
`/etc/docker/certs.d/<registry>/ca.crt`, where the Docker daemon looks for it;
`<registry>` there includes the port if the registry uses one.

The cosign check runs in its own container and sees neither the host's Docker
config nor its CA store, so under Ansible both have to be handed to it:

```yaml
openctem_registry_docker_config_dir: /root/.docker
openctem_registry_ca_file: /etc/ssl/certs/registry-ca.pem
```

Plain-HTTP registries cannot be verified on the host: the check does not pass
`--allow-insecure-registry`.

## Signatures

Every OpenCTEM image is signed by the release workflow at its exact tag, and
verification needs sigstore. The host usually cannot reach it, which is the
whole reason you are reading this page, so the verification moves to the
machine that mirrors — where sigstore *is* reachable — and runs there before
anything is copied.

That is why `openctem_verify_signatures: false` is correct in this scenario and
nowhere else. It is not the check being waived: `mirror-to-registry.sh` ran it,
and `versions.yml` still pins every digest, so a registry serving different
bytes fails the pull. Verification moved to the boundary; it did not disappear.

To keep the check on the host instead, mirror with `--signatures` (which runs
`cosign copy`), leave `openctem_verify_signatures` at its default, and make
sure the host can reach sigstore. A plain-HTTP registry cannot do this.

## Upgrading

A new release moves every digest, so each upgrade is: mirror the new tag, then
roll the stack forward.

```bash
scripts/mirror-to-registry.sh v0.17.1 registry.example.com
```

Under Ansible, bump `openctem_version` and re-run. Without it, render again
with the new version and repeat the copy. Read the release notes first: a
release that migrates the schema is not reversible by starting the previous
compose file.

Nothing prunes the old tags. They are what a rollback needs, so keep at least
the release you are running and the one before it.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `mirror-to-registry.sh` ends at *does not serve every image by its pinned digest* | the registry re-serialised a manifest on push; look for an image-conversion or scanning policy that rewrites manifests |
| `unauthorized` while copying | the mirroring account lacks push rights, or the project does not exist yet |
| `manifest unknown` on the host, image visible in the registry UI | the same digest problem, found late — re-mirror and let the script check |
| Third-party image not found | the path after the host must be kept: `<prefix>/library/postgres` |
| `x509: certificate signed by unknown authority` | the CA is not in `/etc/docker/certs.d/<registry>/ca.crt` |
| Deploy stops at *Verify the release signatures* | the host cannot reach sigstore and `openctem_verify_signatures` is still `true` |
| `compose-use-mirror.sh` says a line still points at a public registry | an image the two rules do not cover; mirror it and edit that line by hand |

## See also

- [INSTALL-SCENARIOS.md](INSTALL-SCENARIOS.md) — every network shape, including the air gap
- [README, Private registry / air-gapped](../README.md#private-registry--air-gapped) — the variable reference
- [scripts/mirror-images.sh](../scripts/mirror-images.sh) — the copying itself
