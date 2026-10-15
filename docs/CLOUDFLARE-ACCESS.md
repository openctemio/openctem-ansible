# Cloudflare Tunnel and Access for one OpenCTEM host name

OpenCTEM is served from **one origin**, `https://ctem.example.com` in this
guide (your `openctem_app_host`): the web console, the API, sensors and CI
pipelines all use it. The OpenCTEM gateway on the host routes each path to
the web console or the API. Cloudflare gives three things in front of it:

1. **Tunnel**: an outbound-only connection from the `cloudflared` container to
   Cloudflare. The host publishes no port; nothing on the internet can reach
   the origin except through the tunnel.
2. **Access** for people: every request must carry a Cloudflare Access session
   from your identity provider before it reaches OpenCTEM.
3. **Access Bypass** for machines, on the exact paths sensors and CI call. They
   cannot complete an interactive login. These paths still demand their own
   credentials in the API: sensor keys and signed jobs for sensors, a GitHub or
   GitLab OIDC token and then a short-lived run token for CI. A WAF rate-limit
   rule throttles them.

This repository does not configure Cloudflare through its API (no Cloudflare
API token is needed or stored). The steps below are dashboard steps; menu
names are those of the Cloudflare One / Zero Trust dashboard in 2026.

## The machine paths (verified against the OpenCTEM v0.9.6 routes)

| Path prefix | Caller | Authentication in OpenCTEM |
|---|---|---|
| `/api/v2/sensor/` | sensors, protocol v2 (enrollment, hello, heartbeat, commands, results, evidence) | enrollment token, then the sensor key; jobs are signed when the job signer is on |
| `/api/v3/sensor/` | sensors, protocol v3 HTTPS binding | as above |
| `/api/v1/ci/oidc/exchange` | CI pipelines: exchange the job's OIDC token for a run token | the CI provider's OIDC token, checked against a trust configuration |
| `/api/v1/ci/runs/` | CI pipelines: upload results, baseline diff, evaluate the gate | a run token (15 minutes, one run, one repository) |

`/api/v1/ci/runs/` also covers two console reads (`GET /api/v1/ci/runs`,
`GET /api/v1/ci/runs/{id}`). Without an Access challenge they still need a
signed-in console session and the `scans:ci:read` permission, so the bypass
removes only the identity-provider step in front of them.

**Not bypassed, on purpose:** everything else, including the console, `/api/v1/*`,
the admin console and `/api/v1/auth/*`. SAML and OIDC sign-in callbacks pass
through the user's browser, which already holds an Access session.

**Bypass only if you use them** (each authenticates in the API):

| Path prefix | Use |
|---|---|
| `/hooks/` | inbound webhooks (e.g. Jira), HMAC per organization |
| `/scim/v2/` | user provisioning from your identity provider, SCIM bearer token |
| `/api/v1/auth/backchannel-logout` | OIDC back-channel logout, called by your identity provider |

API-key scripts and MCP clients are not browsers. Give them an Access
**service token** (send `CF-Access-Client-Id` and `CF-Access-Client-Secret`)
through a Service Auth policy on the main application. Do not bypass `/api/v1/`.

## 1. Create the tunnel

1. Zero Trust → **Networks → Tunnels → Create a tunnel** → **Cloudflared**.
   Name it (e.g. `openctem`).
2. On "Install and run a connector", pick **Docker** and copy only the token
   (the long string after `--token`). Do not run the command: the
   `cloudflared` role runs the connector.
3. Put the token on the host, as root, without echoing it into your shell
   history or a log:

   ```bash
   sudo install -d -m 0700 -o root -g root /opt/openctem/secrets
   sudo sh -c 'umask 077; cat > /opt/openctem/secrets/cloudflared_tunnel_token'   # paste, Enter, Ctrl-D
   sudo chown 65532:65532 /opt/openctem/secrets/cloudflared_tunnel_token
   sudo chmod 0400 /opt/openctem/secrets/cloudflared_tunnel_token
   ```

   Ubuntu 26.04: use `chown` with numeric ids as shown. `install -o 65532`
   fails there because uid 65532 has no passwd entry.
4. **Which kind of tunnel is it?** The dashboard says so on the tunnel page.
   - **Remotely managed** (created in the dashboard, the default): set the
     route in the dashboard as described in step 5. Keep
     `cloudflared_management: remote` (the default).
   - **Locally managed** (created with `cloudflared tunnel create`): the
     dashboard shows "This tunnel is locally managed. Routes are configured
     via the local configuration file" and cannot add a route. Set
     `cloudflared_management: local` in your inventory: the role writes
     `/opt/openctem/cloudflared.yml` with exactly one rule
     (`openctem_app_host` → `http://gateway:80`, every other host name 404)
     and mounts it read-only into the connector. Skip step 5; you still need
     the DNS record (`cloudflared tunnel route dns <tunnel> <host>` or a CNAME
     to `<tunnel-id>.cfargotunnel.com`).
   - Symptom of a missing route either way: every request returns 503 and the
     connector logs `No ingress rules were defined`.
5. **Public hostname**, remotely managed tunnels only (Tunnel → Published
   application routes → Add):
   - Subdomain and domain: `ctem.example.com`.
   - Path: empty.
   - Service: **HTTP**, URL **`gateway:80`**. This is the gateway container on
     the internal tunnel network. Do not use `localhost`: inside the
     `cloudflared` container that is the connector itself.
   - Additional settings → HTTP Settings: leave **HTTP Host Header** empty. The
     gateway answers only for `openctem_app_host` and returns 404 for any
     other host name.
   - **Do not enable "Protect with Access" / origin JWT validation on this
     route.** It would refuse the bypassed machine paths, which carry no
     Access token. The tunnel being the only way in is the origin protection.
6. Deploy (`playbooks/50-openctem.yml`). The tunnel shows **Healthy** once the
   connector runs.

## 2. Access application for people

Zero Trust → **Access → Applications → Add an application → Self-hosted**:

- Application name: `OpenCTEM`.
- Session duration: 8 to 24 hours (OpenCTEM keeps its own, shorter, sign-in).
- Public hostname: `ctem.example.com`, **path empty** (the whole host).
- Identity providers: your IdP only. Turn off the one-time PIN unless you mean
  to use it.
- Policy **Allow people**: Action *Allow*; Include *Emails ending in*
  `@yourcompany.example`, or better an IdP group. Add *Require*:
  *Authentication method → mfa*. Optionally require *Gateway* / device posture
  (WARP) when the console must be reachable only from managed devices.
- (Optional) Policy **Automation** for API-key scripts: Action *Service Auth*;
  Include *Service Token* → the token you created under Access → Service
  credentials.
- Settings → Cookies: **SameSite Lax**, **HTTP Only** on, **Binding Cookie** on.
- Settings → CORS: leave off (one origin).

## 3. Access Bypass applications for machines

Create **one self-hosted application per machine path**. Access uses the most
specific matching application, so these win over the application above for
their paths only.

| Application name | Public hostname | Path |
|---|---|---|
| `OpenCTEM sensors v2` | `ctem.example.com` | `api/v2/sensor/*` |
| `OpenCTEM sensors v3` | `ctem.example.com` | `api/v3/sensor/*` |
| `OpenCTEM CI exchange` | `ctem.example.com` | `api/v1/ci/oidc/exchange` |
| `OpenCTEM CI runs` | `ctem.example.com` | `api/v1/ci/runs/*` |

Optional ones (only if used): `hooks/*`, `scim/v2/*`,
`api/v1/auth/backchannel-logout`.

For each:

- Policy **Machines**: Action **Bypass**; Include **Everyone**. A Bypass policy
  must be the only policy of the application.
- No identity providers needed.
- Check the path field: no leading slash, and `*` only at the end. Do not
  bypass a shorter prefix such as `api/*` or `api/v1/*`.

## 4. WAF rate limit on the bypassed paths

Security → **WAF → Rate limiting rules → Create rule** (zone of your domain):

- Name: `OpenCTEM machine paths`.
- If incoming requests match (expression editor):

  ```
  (http.host eq "ctem.example.com" and (
     starts_with(http.request.uri.path, "/api/v2/sensor/") or
     starts_with(http.request.uri.path, "/api/v3/sensor/") or
     http.request.uri.path eq "/api/v1/ci/oidc/exchange" or
     starts_with(http.request.uri.path, "/api/v1/ci/runs/")))
  ```

- Characteristics: **IP**.
- Rate: Free plan allows one rule with a 10-second period: **200 requests per
  10 seconds**, then **Block for 10 seconds**. On Pro or higher, make two rules:
  sensors at 1200 requests per minute per IP, and the CI exchange at 60 per
  minute per IP, each blocking for 10 minutes.
- Many sensors behind one NAT address share a budget: raise the sensor rate
  when you run more than about 50 sensors behind one address.

The API applies its own per-sensor, per-run and per-address limits behind
these.

## 5. Zone settings that matter for OpenCTEM

- **Network → WebSockets: On** (the console's live updates use `/api/v1/ws`).
- **SSL/TLS → Edge Certificates**: *Always Use HTTPS* on, *Minimum TLS 1.2*,
  HSTS on once everything works (max-age 6 months, include subdomains only if
  every subdomain is HTTPS).
- **Speed / Optimization**: leave *Rocket Loader* and any HTML rewriting **off**.
  They break the console's Content-Security-Policy.
- **Caching → Cache Rules**: one rule *Bypass cache* for `ctem.example.com`
  when the path does not start with `/_next/static/`.
- **Upload limit**: Cloudflare caps a request body at 100 MB on Free and Pro
  (200 MB Business). Larger finding or asset imports must be split, or
  uploaded with a CI or sensor integration instead of the console.

## 6. Acceptance tests (run from a machine outside your network)

```bash
H=https://ctem.example.com
# Console and user API: Access challenges an anonymous request (302 to <team>.cloudflareaccess.com).
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $H/
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $H/api/v1/me
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $H/api/v1/admin/health
# Sensor and CI paths: no Access challenge, and still refused without credentials.
curl -s -o /dev/null -w '%{http_code}\n' $H/api/v2/sensor/hello                                    # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST $H/api/v1/ci/runs/00000000-0000-0000-0000-000000000000/results  # 401
curl -s -w ' %{http_code}\n' -H 'Content-Type: application/json' -d '{}' $H/api/v1/ci/oidc/exchange   # 400 (from the API)
# Internal endpoints are never served.
curl -s -o /dev/null -w '%{http_code}\n' $H/metrics        # 302 (Access) — and 404 behind it
# The origin is not reachable directly (from your LAN, replace with the host's address).
curl -m 5 http://HOST_ADDRESS:80/ ; curl -m 5 -k https://HOST_ADDRESS:443/   # connection refused / timeout
```

| Test | Expected |
|---|---|
| Anonymous browser → `https://ctem.example.com/` | Access login page |
| Anonymous `GET /api/v1/me` | 302 to Access (or 403 with a service-token-only policy) |
| Disallowed identity signs in to Access | Access denies |
| Allowed identity + MFA | OpenCTEM sign-in page |
| `GET /api/v2/sensor/hello` without a key | **401 from OpenCTEM**, no Access page |
| `POST /api/v1/ci/oidc/exchange` with `{}` | **400 from OpenCTEM**, no Access page |
| `POST /api/v1/ci/runs/<id>/results` without a run token | **401 from OpenCTEM** |
| A sensor enrolled with `https://ctem.example.com` | heartbeats; shows Online in Sensors |
| A CI pipeline with the OpenCTEM CI action, URL `https://ctem.example.com` | exchange + upload succeed |
| > rate limit from one address on a bypassed path | 429 from Cloudflare |
| Host address, any port, from LAN or internet | refused (no published port) |

The host's monitor (`playbooks/60-monitoring.yml`) repeats the first and the
sensor checks every five minutes and alerts when Access stops challenging the
console, or when the sensor path stops reaching the API.

## Rollback

- Tunnel trouble: in the dashboard, the tunnel route can be pointed back at a
  previous origin or disabled; the Access applications stay in place.
- To take OpenCTEM offline at once: disable the public hostname route (the
  connector stays up but nothing reaches the gateway), or stop the connector
  on the host: `sudo docker compose -p openctem -f /opt/openctem/compose.yml
  -f /opt/openctem/compose.cloudflared.yml stop cloudflared`.
- Record the tunnel and Access settings when you change them; the tunnel token
  can be rotated in the dashboard (Tunnel → Refresh token) and re-placed on the
  host as in step 1.3.
