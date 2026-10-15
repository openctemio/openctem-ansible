# Security Policy

This policy covers this repository: the Ansible roles, playbooks, templates
and scripts that install and operate a self-hosted OpenCTEM platform. It is
part of the OpenCTEM vulnerability disclosure policy, which covers every
`openctemio` repository.

## Reporting a vulnerability

**Do not open a public issue, pull request or discussion for a
vulnerability.** Report it privately through GitHub: **Security → Report a
vulnerability** on this repository (a draft advisory visible only to you and
the maintainers), or through the security contact in the
[OpenCTEM security policy](https://github.com/openctemio/openctem/blob/main/SECURITY.md).

Please include the affected file or role and the commit, the impact and the
access an attacker needs first, reproduction steps, and any suggested fix.
Test only on machines you own or are authorized to test.

## In scope

- A role or script that weakens the host it configures (for example a firewall
  rule wider than documented, a secret written world-readable, a secret printed
  to Ansible output or a log, a port published that should not be).
- Supply-chain issues: an unpinned image, package or collection; a signature,
  checksum or fingerprint check that can be bypassed.
- Backup handling that exposes data (plaintext where encryption was
  configured, an identity key placed on the host).
- Documentation that would lead an operator to an insecure configuration.

Vulnerabilities in the OpenCTEM platform itself belong to the
[openctem repository](https://github.com/openctemio/openctem/security).

## Supported versions

The `main` branch and the latest tagged release of this repository.
