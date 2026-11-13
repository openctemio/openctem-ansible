#!/usr/bin/env bash
# Custom server image (openctem_custom_api_image): preflight refusals, the
# rendered compose file (api image, the image's own migration job, the
# administrators' audit sink kept), and the signature check (its own identity
# and the release annotation, through a recording `docker` stub that acts like
# cosign's annotation check). Needs ansible-core and PyYAML; no Docker, no host
# touched.
#   tests/custom-image.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
cd "$kit"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

rel="@$kit/tests/fixtures/sink-removed-release.yml" # v0.99.0, admin_audit_sink_removed
digest="$(printf 'c%.0s' $(seq 64))"
img="registry.example.com/org/server:v0.99.0@sha256:$digest"
id="https://ci.example.com/org/server/.github/workflows/release.yml@refs/tags/v0.99.0"
custom=(-e "openctem_custom_api_image=$img" -e "openctem_custom_api_cosign_identity=$id")
mig='{"openctem_custom_api_migrate_command":["/app/extension-migrate","-path","/migrations-extension","-database","postgres://openctem_migrator@postgres:5432/openctem?sslmode=require","up"]}'
managed='{"openctem_api_env":{"MANAGED_SERVICE":"true"}}'
sink=(-e "$managed" -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_provided=true)

check() { ansible-playbook tests/custom-image-checks.yml -e "$rel" "$@" >/dev/null 2>&1; }
ok() { if check "$@"; then pass "accepted: $*"; else fail "refused: $*"; fi; }
no() { if check "$@"; then fail "accepted: $*"; else pass "refused: $*"; fi; }

# --- Preflight ------------------------------------------------------------------
ok
ok "${custom[@]}"
ok "${custom[@]}" -e "$mig"
ok "${custom[@]}" -e openctem_custom_api_image="registry.example.com:5000/org/server@sha256:$digest"
no -e "openctem_custom_api_image=$img"                                         # no signing identity
no -e "openctem_custom_api_image=$img" -e openctem_custom_api_cosign_identity=ci.example.com/x
no "${custom[@]}" -e openctem_custom_api_image=registry.example.com/org/server:v0.99.0   # a tag, no digest
no "${custom[@]}" -e "openctem_custom_api_image=registry.example.com/org/server@sha256:${digest:0:63}"
no "${custom[@]}" -e "openctem_custom_api_image=https://registry.example.com/org/server@sha256:$digest"
no "${custom[@]}" -e openctem_custom_api_cosign_issuer=http://issuer.example.com
no "${custom[@]}" -e openctem_verify_signatures=false                          # never unverified
no -e "$mig"                                                                    # migrations without the image
no "${custom[@]}" -e '{"openctem_custom_api_migrate_command":"/app/extension-migrate up"}'
no "${custom[@]}" -e '{"openctem_custom_api_migrate_command":["app/extension-migrate","up"]}'
no "${custom[@]}" -e '{"openctem_custom_api_migrate_command":["/app/m","-database","postgres://openctem_migrator:example-not-a-secret@postgres:5432/openctem","up"]}'
# The audit stream: "provided" only with a custom image, for a release without the stream.
no "${sink[@]}"
ok "${sink[@]}" "${custom[@]}"
no -e "$managed" -e openctem_admin_audit_sink=file "${custom[@]}"              # the flag is still required
ok -e openctem_version=v0.21.0 -e openctem_admin_audit_sink=file -e openctem_admin_audit_sink_provided=true -e '{"openctem_releases":{"v0.21.0":{"admin_audit_sink_required":true}}}'

# --- Rendering ------------------------------------------------------------------
render() { # render <name> [-e k=v ...]
	local name="$1"; shift
	mkdir -p "$work/$name/secrets"
	for f in api.env migrate.env bootstrap-admin.env db-roles.env redis.env; do echo "X=dummy" >"$work/$name/secrets/$f"; done
	ansible-playbook tests/render.yml -e "$rel" -e render_dir="$work/$name" -e openctem_root="$work/$name" -e openctem_project=ci "$@" >/dev/null
}
render plain
render custom "${sink[@]}" "${custom[@]}" -e "$mig"
render custom-nomig "${custom[@]}"
render custom-mirror "${custom[@]}" -e openctem_registry_mirror=mirror.example.com/oc

for r in plain custom custom-nomig custom-mirror; do
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		if docker compose -p ci -f "$work/$r/compose.yml" -f "$work/$r/compose.cloudflared.yml" config --quiet; then pass "$r: compose config"; else fail "$r: compose config"; fi
	fi
done

if python3 -I - "$work" "$img" <<'PY'; then pass "rendered services"; else fail "rendered services"; fi
import sys, yaml
w, img = sys.argv[1], sys.argv[2]
def svc(n):
    with open(f"{w}/{n}/compose.yml") as f:
        return yaml.safe_load(f)["services"]
release_api = "ghcr.io/openctemio/openctem-api@sha256:" + "1" * 64

s = svc("plain")
assert s["api"]["image"] == release_api, s["api"]["image"]
assert "migrate-extension" not in s
assert "ADMIN_AUDIT_SINK" not in s["api"]["environment"]

s = svc("custom")
a = s["api"]
assert a["image"] == img, a["image"]
# The sink and its mount are kept.
assert a["environment"]["ADMIN_AUDIT_SINK"] == "file:///var/lib/openctem-admin-audit/admin-audit.jsonl", a["environment"]
assert any(v.endswith(":/var/lib/openctem-admin-audit") for v in a["volumes"]), a["volumes"]
# Only the api service runs the custom image (and its migration job).
assert s["signer"]["image"] == release_api, s["signer"]["image"]
assert s["bootstrap-admin"]["image"] == release_api
assert s["migrate"]["image"].startswith("ghcr.io/openctemio/migrations@")
m = s["migrate-extension"]
assert m["image"] == img
assert m["entrypoint"] == ["/app/extension-migrate"], m["entrypoint"]
assert m["command"][-1] == "up" and "-database" in m["command"]
assert m["read_only"] is True and m["restart"] == "no" and m["networks"] == ["data"]
assert m["depends_on"]["migrate"]["condition"] == "service_completed_successfully"
assert any(e.endswith("/migrate.env") for e in m["env_file"])
assert not any(":" in x.split("@")[0].split("//")[-1] for x in m["command"] if "://" in x), "no password in the command"
assert "migrate-extension" in s["db-grants"]["depends_on"]
assert "db-grants" in a["depends_on"]

s = svc("custom-nomig")
assert s["api"]["image"] == img and "migrate-extension" not in s
assert "migrate-extension" not in s["db-grants"]["depends_on"]

s = svc("custom-mirror")
assert s["api"]["image"] == img, "the custom image is used as given"
assert s["signer"]["image"].startswith("mirror.example.com/oc/openctem-api@sha256:")
PY

# openctem-verify does not expect a running container for the image's migration
# job (it exits when done); before, every deploy with it failed verify and rolled back.
if grep -qE "^oneshot=' .*migrate-extension .*'$" "$work/custom/scripts/openctem-verify" &&
	grep -qF 'case "$oneshot" in *" $svc "*) continue' "$work/custom/scripts/openctem-verify"; then
	pass "verify skips migrate-extension"
else fail "verify skips migrate-extension"; fi

# A rollback starts the previous compose file without one-shot jobs.
if grep -qE '^openctem_oneshot_services: .*migrate-extension' roles/openctem/defaults/main.yml; then pass "rollback skips migrate-extension"; else fail "rollback skips migrate-extension"; fi

# --- Signature check --------------------------------------------------------------
# The stub records each `docker run ... cosign verify` and, like cosign, fails
# the custom image unless the requested annotation equals what was "signed"
# (STUB_SIGNED_RELEASE).
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
*"verify $STUB_CUSTOM "*)
	[[ "$*" == *"--annotations io.openctem.core.version=$STUB_SIGNED_RELEASE "* ]] || { echo "annotation mismatch" >&2; exit 1; } ;;
esac
STUB
chmod +x "$work/bin/docker"
sig() { # sig <logname> <signed release> [-e k=v ...]
	local log="$work/$1.log" signed="$2"; shift 2
	: >"$log"
	STUB_LOG="$log" STUB_CUSTOM="$img" STUB_SIGNED_RELEASE="$signed" PATH="$work/bin:$PATH" \
		ansible-playbook tests/mirror-signatures.yml -e "$rel" "$@" >/dev/null 2>&1
}
has() { if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$3"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }

if sig sig-plain v0.99.0; then pass "plain: verified"; else fail "plain: verified"; fi
[ "$(wc -l <"$work/sig-plain.log")" -eq 5 ] && pass "plain: 5 release images" || fail "plain: 5 release images"
hasnt "plain: no custom image" "registry.example.com/org/server" "$work/sig-plain.log"

if sig sig-custom v0.99.0 "${custom[@]}"; then pass "custom: verified"; else fail "custom: verified"; fi
[ "$(wc -l <"$work/sig-custom.log")" -eq 6 ] && pass "custom: 5 release images + the custom one" || fail "custom: 5 release images + the custom one"
has "custom: own identity, issuer and release annotation" "verify $img --certificate-identity $id --certificate-oidc-issuer https://token.actions.githubusercontent.com --annotations io.openctem.core.version=v0.99.0" "$work/sig-custom.log"
has "custom: release api still verified with the release identity" "verify ghcr.io/openctemio/openctem-api@sha256:$(printf '1%.0s' $(seq 64)) --certificate-identity https://github.com/openctemio/openctem/.github/workflows/docker-publish.yml@refs/tags/v0.99.0" "$work/sig-custom.log"

if sig sig-other v0.98.0 "${custom[@]}"; then fail "custom built on another release: refused"; else pass "custom built on another release: refused"; fi

# A registry login readable by its owner only (like root's 0600 config.json):
# cosign runs as that owner, or it could not read it.
auth="$work/registry-auth"
mkdir -p "$auth" && (umask 077 && echo '{"auths":{}}' >"$auth/config.json")
if sig sig-auth v0.99.0 "${custom[@]}" -e openctem_registry_docker_config_dir="$auth"; then pass "custom: private registry"; else fail "custom: private registry"; fi
has "custom: registry login mounted read-only for its check" "--volume=$auth:/registry-auth:ro" "$work/sig-auth.log"
[ "$(grep -c 'registry-auth:ro' "$work/sig-auth.log")" -eq 6 ] && pass "custom: login used for every check" || fail "custom: login used for every check"
[ "$(grep -c -- "--user=$(id -u):$(id -g) " "$work/sig-auth.log")" -eq 6 ] && pass "custom: cosign runs as the login file's owner" || fail "custom: cosign runs as the login file's owner"
mkdir -p "$work/no-login"
if sig sig-nologin v0.99.0 "${custom[@]}" -e openctem_registry_docker_config_dir="$work/no-login"; then fail "custom: a login directory without config.json is accepted"; else pass "custom: a login directory without config.json is refused"; fi
[ ! -s "$work/sig-nologin.log" ] && pass "custom: nothing verified without the login" || fail "custom: nothing verified without the login"

echo
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
