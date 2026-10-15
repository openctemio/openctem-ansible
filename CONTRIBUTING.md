# Contributing

Thank you for improving the OpenCTEM self-hosting kit. Changes here run as
root on other people's servers: keep them small, reviewable and safe.

## Ground rules

- **Security first.** Every change states what it protects against and what
  it could break. Secrets are generated on the host or kept in ansible-vault;
  never in git, task output or logs (`no_log: true` wherever a secret appears).
- **Pin everything.** Images by digest and versions in `versions.yml`;
  collections by exact version in `requirements.yml`; downloaded files by
  checksum. OpenCTEM images are checked against their keyless cosign signature.
- **Opt-in and staged.** A play changes a host only when its `apply_*` flag is
  true. Anything that can lock an operator out (SSH, firewall) proves access
  first.
- **No site data.** No real host names, addresses, domains, keys or people in
  committed files: use the documentation ranges (192.0.2.0/24, 198.51.100.0/24,
  203.0.113.0/24) and `example.com`.
- **Ubuntu 26.04 ships uutils coreutils.** Prefer Ansible modules to shell; set
  ownership with `file`/`copy` and numeric ids, not `install -o`; check every
  shell flag you use against uutils.
- **Never touch another stack.** Every `docker compose` call names its project
  (`-p`) and files (`-f`); never rely on the working directory. Tests run only
  inside Docker-in-Docker (see below), never against your workstation's daemon.
- No AI attribution lines in commits or pull requests.

## Before you open a pull request

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install 'ansible-core>=2.18,<2.19' ansible-lint yamllint
ansible-galaxy collection install -r requirements.yml -p ./collections
yamllint .
ansible-lint                       # production profile
for p in site.yml playbooks/*.yml; do ansible-playbook --syntax-check "$p"; done
ansible-playbook tests/render.yml -e render_dir=/tmp/openctem-render
tests/smoke.sh                     # stack in an isolated DinD container
tests/role-e2e.sh                  # the real roles against Ubuntu 26.04, in DinD
```

CI runs the same checks plus a gitleaks scan.

## Adding an OpenCTEM release

```bash
scripts/vendor-release.sh vX.Y.Z   # vendors gateway config + SQL, prints digests
```

Add the printed entry to `openctem_releases` in `versions.yml` (keep the
previous release for rollback), review the diff of the vendored files against
the previous release, and run the smoke and e2e tests.

## Contributor License Agreement

Every outside contribution is accepted under the OpenCTEM Contributor License
Agreement (CLA). It keeps your copyright with you and grants the project a
license that lets it offer OpenCTEM under its open source license and under
other terms (for example a commercial license). A summary is in
[CLA.md](CLA.md); the full texts are the
[Individual CLA](https://docs.openctem.io/legal/cla/) and the
[Corporate CLA](https://docs.openctem.io/legal/cla-corporate/).

### How to sign

1. Make sure the e-mail address of your commits is
   [added to your GitHub account](https://github.com/settings/emails). The
   check can only match commits that are linked to a GitHub account.
2. Open your pull request. If a commit author has not accepted the CLA yet,
   the `cla` check fails and comments on the pull request.
3. Read the agreement and post this comment on the pull request:

   ```text
   I have read the CLA Document and I hereby sign the CLA
   ```

   The check re-runs and passes. You sign once; the signature covers every
   repository of the `openctemio` organization and your earlier
   contributions. Post `recheck` to run the check again.
4. If you contribute as part of your job and your employer has rights in your
   work, your employer signs the [Corporate CLA](CLA-CORPORATE.md) as well.

The maintainer and the dependency bots are on the check's allowlist. A
maintainer who opens a pull request with someone else's commits makes sure
those authors have signed; the check also runs then for every commit linked
to another GitHub account.

### What is recorded

Your acceptance is recorded in a private repository that only the maintainer
can read: your GitHub username and numeric account id, the id and time of
your signing comment, and the repository and pull request where you signed.
No e-mail address is stored. The signing comment itself stays public on the
pull request. The record is kept for as long as the project distributes your
contribution, because it is the evidence of the license. To see or correct
your record, or to ask for its removal, write to info@openctem.io; anything
not needed as evidence of the license is removed.
