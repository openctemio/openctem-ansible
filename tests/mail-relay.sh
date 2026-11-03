#!/usr/bin/env bash
# Mail relay: off by default; rendering of the relay stack and of the platform
# wiring when on; the relay is never an open relay; settings validation.
# Needs ansible-core and PyYAML; no Docker, no host touched.
#   tests/mail-relay.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"

render() { # render <name> [-e k=v ...]
	local name="$1"; shift
	ansible-playbook tests/render.yml -e render_dir="$work/$name" -e openctem_root="$work/$name" "$@" >/dev/null
}

# Off (default): the platform stack does not know the relay at all.
render off
! grep -q 'mail_submit\|BOOTSTRAP_SMTP\|ALLOW_PRIVATE_CIDRS' "$work/off/compose.yml"
! grep -q 'mail_relay\|MAIL' "$work/off/scripts/openctem-egress"

# On, with a smarthost login and DKIM.
render on -e openctem_mail_relay=true -e mail_relay_smarthost=smtp.corp.example:587 -e mail_relay_smarthost_login=true -e mail_relay_dkim=true \
	-e '{"openctem_api_env": {"OPENCTEM_HTTPSEC_ALLOW_PRIVATE_CIDRS": "10.1.0.0/16"}}'
python3 -I - "$work" <<'PY'
import sys, yaml
w = sys.argv[1]
p = yaml.safe_load(open(f"{w}/on/compose.yml"))
api, boot = p["services"]["api"], p["services"]["bootstrap-admin"]
# The API joins the relay's (external, internal) submission network and may reach exactly that address.
assert "mail_submit" in api["networks"] and "mail_submit" in boot["networks"], (api["networks"], boot["networks"])
assert p["networks"]["mail_submit"] == {"external": True, "name": "openctem-mail_submit"}, p["networks"]["mail_submit"]
assert api["environment"]["OPENCTEM_HTTPSEC_ALLOW_PRIVATE_CIDRS"] == "10.1.0.0/16,172.30.86.10/32", api["environment"]
# The one-shot tool seeds the platform e-mail to the relay, verified against the relay's CA.
e = boot["environment"]
assert e["BOOTSTRAP_SMTP_HOST"] == "mail-relay" and e["BOOTSTRAP_SMTP_PORT"] == "587" and e["BOOTSTRAP_SMTP_STARTTLS"] == "true", e
assert e["BOOTSTRAP_SMTP_FROM"] == "noreply@example.com" and e["BOOTSTRAP_SMTP_CA_FILE"], e
assert any(v.endswith("mail_relay_ca/ca.crt:/etc/openctem/mail-relay-ca.crt:ro") for v in boot["volumes"]), boot["volumes"]
# No password and no key ever reaches the platform compose file.
assert "PASSWORD" not in str(api["environment"]) .replace("DB_PASSWORD","")

m = yaml.safe_load(open(f"{w}/on/compose.mail-relay.yml"))
r = m["services"]["mail-relay"]
env = r["environment"]
# Never an open relay.
assert env["POSTFIX_mynetworks"] == "172.30.86.0/24", env
assert env["POSTFIX_smtpd_client_restrictions"] == "permit_mynetworks,reject", env
assert "reject_unauth_destination" in env["POSTFIX_smtpd_relay_restrictions"], env
assert env["POSTFIX_smtpd_tls_security_level"] == "encrypt", env
assert env["ALLOWED_SENDER_DOMAINS"] == "example.com", env
assert "ports" not in r, "the relay must publish no port"
# Own networks: submission is internal; nothing else is on the egress network.
assert m["networks"]["submit"]["internal"] is True
assert set(r["networks"]) == {"submit", "egress"}, r["networks"]
assert r["cap_drop"] == ["ALL"] and "no-new-privileges:true" in r["security_opt"] and r["healthcheck"]["test"], r
# Smarthost: all mail goes there with TLS required; the login comes from a root-only file.
assert env["RELAYHOST"] == "[smtp.corp.example]:587" and env["RELAYHOST_TLS_LEVEL"] == "encrypt", env
assert r["env_file"][0].endswith("mail_relay_smarthost.env"), r
assert "RELAYHOST_PASSWORD" not in str(env)
# DKIM key mounted read-only, one per domain.
assert any(v.endswith("mail_relay_dkim/example.com.private:/etc/opendkim/keys/example.com.private:ro") for v in r["volumes"]), r["volumes"]
assert env["DKIM_SELECTOR"] == "openctem"
assert "@sha256:" in r["image"]
PY
grep -q '172.30.87.0/24' "$work/on/scripts/openctem-egress" # the relay's outbound network is under the egress policy
grep -q '^_dmarc.example.com' "$work/on/dns-records.txt"
grep -q 'include:' "$work/on/dns-records.txt"

# Direct delivery: no smarthost, no login file, relay-wide default TLS is opportunistic outbound.
render direct -e openctem_mail_relay=true
python3 -I - "$work" <<'PY'
import sys, yaml
r = yaml.safe_load(open(sys.argv[1] + "/direct/compose.mail-relay.yml"))["services"]["mail-relay"]
assert "RELAYHOST" not in r["environment"] and "env_file" not in r and not any("opendkim" in v for v in r["volumes"]), r
PY
grep -q 'ip4:' "$work/direct/dns-records.txt"

# Validation.
check() { ansible-playbook tests/mail-relay-checks.yml -e openctem_mail_relay=true "$@" >/dev/null 2>&1; }
ok() { check "$@" || { echo "expected to pass: $*" >&2; exit 1; }; }
no() { ! check "$@" || { echo "expected to fail: $*" >&2; exit 1; }; }
ok
ok -e mail_relay_smarthost=smtp.corp.example:587
ok -e '{"mail_relay_sender_domains": ["example.com", "example.org"]}'
no -e mail_relay_hostname=''
no -e mail_relay_hostname='mail;rm'
no -e '{"mail_relay_sender_domains": []}'
no -e openctem_mail_relay_from=noreply@other.example   # not a sender domain
no -e mail_relay_smarthost=smtp.corp.example           # no port
no -e 'mail_relay_smarthost=smtp.corp.example:587;x'
no -e mail_relay_dkim_bits=1024
no -e '{"mail_relay_dkim_selector": "a b"}'
no -e openctem_mail_relay_project=openctemio           # a protected project
no -e openctem_mail_relay_project=openctem             # the platform's own project
no -e openctem_net_mail_submit=172.30.82               # overlaps the data network
echo "mail relay tests passed"
