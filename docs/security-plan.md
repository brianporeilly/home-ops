# Security Plan

Status: **Roadmap** (started 2026-08-20). Triggered by wanting to expose more services
externally (jellyfin, audiobookshelf, home-assistant, copy-party, grimmory, maybe tuwunel later)
— this is the "what needs to be true first" conversation that `home-ops-authentik-sso` memory
had flagged as deferred. Nothing below is urgent-blocking (home-assistant and immich already sit
behind `envoy-external` today), but the surface is about to grow and a few structural gaps are
worth closing before it does rather than after.

**Done so far:**
- **forgejo SSH via TCPRoute** instead of a dedicated kube-vip LB IP — smaller surface, one less
  IP/DNS special-case (`kubernetes/apps/network/envoy-gateway/config/envoy.yaml`'s `ssh` listener
  + `kubernetes/apps/misc/forgejo/app/tcproute.yaml`).
- **copy-party volume ACLs tightened** — was `rw: *` (read-write for *anyone*, even
  unauthenticated, even internally); changed to `r: *` / `rwmda: root` (public read-only, root
  keeps full access), with a comment showing how to add named uploader accounts later
  (`kubernetes/apps/misc/copyparty/app/secret.yaml`, branch `copyparty-volume-acls`).
- **§2.1 Authentik brute-force protection** — confirmed live (via `ak shell` against
  `default-authentication-flow`) that neither of its two default policy bindings do any
  throttling, and zero `ReputationPolicy` objects existed anywhere in the system. Added a
  `ReputationPolicy` (threshold `-3`, checks both IP and username) gating a new `DenyStage` bound
  between the identification and password stages
  (`kubernetes/apps/authentik/authentik/app/blueprints-brute-force.yaml`, branch
  `authentik-brute-force-protection`).
- **§2.1 Authentik admin UI blocked externally** — `auth.oreillys.io`'s external `HTTPRoute`
  matched `PathPrefix: /` with no carve-out, so `/if/admin/` was just as reachable from the
  internet as the login page. Added a named rule + `BackendTrafficPolicy` with
  `faultInjection.abort` (100%, 404) scoped to just `/if/admin` via `sectionName` — everything
  else on that hostname (OIDC endpoints, flow executor, static assets) is untouched, since
  externally-exposed apps' SSO logins depend on those
  (`kubernetes/apps/authentik/authentik/app/httproute-external.yaml` +
  `backendtrafficpolicy-admin-block.yaml`, branch `authentik-block-external-admin`).
- **§2.1 SSO-except-break-glass made real** — `brian@oreillys.io` and
  `brianporeilly@gmail.com` had their local passwords disabled live
  (`set_unusable_password()`), leaving `akadmin` as the only account that can ever reach
  `default-authentication-flow`'s password/MFA path. Paired with `not_configured_action:
  configure` on the MFA stage (forces inline enrollment instead of silently skipping) and a new
  `DenyStage` gating `default-source-enrollment` (no untrusted Google/GitHub account could
  self-enroll before this — confirmed live, zero access gate existed) — branch
  `authentik-sso-hardening-round2`, merged. **Correction (2026-08-21)**: `not_configured_action:
  configure` also requires `configuration_stages` to be set (M2M to `Stage`, not `Flow`) — omitting
  it failed blueprint validation outright, and since a blueprint file applies as one DB
  transaction, this was silently rolling back on every 15-minute reapply cycle since merge.
  `not_configured_action` was never actually `configure` in the live DB despite the file existing
  in git. Found via `KubeJobFailed` alerts on `authentik-blueprint-reapply`, fixed in
  `fix-authentik-blueprint-validation-errors`.
- **§2.1 Password policy tightened** — `default-password-change-password-policy` ships with
  authentik already bound to the password-change `PromptStage` (`validation_policies` M2M,
  length_min=8/no complexity by default) — **correction to an earlier claim here**: it was never
  actually unbound, that conclusion checked `authentik_policies.PolicyBinding`, a different
  mechanism entirely from `PromptStage.validation_policies`; the real gap was just that the
  shipped default is weak, not that nothing was enforced. Tightened to length 14+/mixed-case/
  digit/symbol plus `check_zxcvbn` (pattern-strength) and `check_have_i_been_pwned`. The original
  version of this fix also tried to (re-)create the binding via a
  `authentik_stages_prompt.promptstagevalidationpolicy` blueprint entry — not on authentik's
  blueprint model allowlist at all (confirmed live, "Model ... not allowed"), which was silently
  rolling back this file's otherwise-valid `PasswordPolicy` attrs update too, for the same
  one-transaction-per-file reason as the MFA fix above. Fixed by dropping that entry — the binding
  already exists, only the policy's own attrs need managing
  (`kubernetes/apps/authentik/authentik/app/blueprints-password-policy.yaml`).
- **§2.1 Email wired to Maddy** — authentik had no SMTP configured at all (confirmed live -
  default `email.host: localhost`), so the four shipped `NotificationRule`s already pointed at
  `default-email-transport` (config-error/warning, update-available, exception) were silently
  going nowhere. Same no-auth in-cluster relay pattern as forgejo
  (`maddy.misc.svc.cluster.local:25`), routed to a new empty `authentik-notifications` group
  (add yourself via the UI).
- **Both blueprint bugs above were found by chasing a real `KubeJobFailed` alert in Alertmanager**,
  not proactively — worth remembering that a merged blueprint file isn't actually verified until
  its next real reapply cycle succeeds, not just until `ak apply_blueprint` is tested once by hand
  against a single file in isolation.

---

## 1. What's already in place

Worth stating explicitly so the roadmap below doesn't re-litigate it:

- **TLS + headers**: `envoy-external`/`envoy-internal` `ClientTrafficPolicy` pins `minVersion:
  "1.2"`, sets HSTS/`X-Content-Type-Options`/`X-Frame-Options`/`Referrer-Policy` on every
  response. Wildcard cert via cert-manager + Let's Encrypt DNS-01.
- **Real client IPs**: `envoy-external`'s `clientIPDetection.trustedCIDRs` pinned to OPNsense's
  transit address, so rate limiting/logging see the actual attacker IP, not OPNsense's.
- **Edge blocking**: crowdsec runs in-cluster but is **detection-only** (parses Envoy access logs
  into a Grafana dashboard) — the actual bouncer/enforcement lives **upstream on OPNsense**, not
  in the cluster.
- **A rate-limit backstop**: `envoy-external-ratelimit` `BackendTrafficPolicy` caps the whole
  `https` listener at 100 req/s (local, **shared across every externally-exposed app** — see §2.3).
- **SSO, where wired**: Authentik has two patterns — `protect`/`protect-external` (Envoy Gateway
  `SecurityPolicy` wrapping an app's `HTTPRoute`, for apps with no native OIDC: sonarr/radarr/
  prowlarr/lidarr, kopiur-ui, changedetection) and native OIDC (grafana, nebraska, paperless-ngx,
  linkwarden, forgejo). Tiered groups + `PolicyBinding` gate access per-app (see
  `home-ops-authentik-sso` memory for the full picture). **Not every externally-exposed app is
  behind this yet** — immich, jellyfin, and home-assistant currently rely on their own native
  accounts, not Authentik.
- **Secrets**: SOPS + age, nothing plaintext in git (this repo is public). OIDC creds specifically
  go through ESO + Reflector, never touch git at all.

---

## 2. Gaps to close (roadmap, roughly priority order)

### 2.1 Authentik login-flow hardening — done

First priority because Authentik is the single point every SSO-gated app (current and future)
depends on, and it becomes a higher-value target once more apps sit behind it externally
(`auth.oreillys.io`) instead of just internal SSO.

Confirmed live there was no throttling/lockout at all (see "Done so far" above) and fixed it with
a `ReputationPolicy` + `DenyStage` in `blueprints-brute-force.yaml`, branch
`authentik-brute-force-protection`. **Live-tested post-merge**: 12 failed logins against a `test`
account only brought the reputation score to `-5`, not `-12` — the decrement isn't a flat
`-1`/failure — so the threshold was retuned from `-5` to `-3` (branch
`authentik-brute-force-threshold`) to land closer to the originally-intended "~3-5 attempts"
range. Confirmed via `Reputation`/`Event` table queries (`ak shell`), not just visually — the
`DenyStage` fired exactly once the score crossed the threshold, no earlier/later.

Also found and fixed: the admin UI (`/if/admin/`) was reachable externally with no restriction
(see "Done so far" above) — blocked via a `BackendTrafficPolicy` fault-injection, scoped narrowly
enough not to touch the OIDC/login surface other apps depend on.

**Resolved**: SSO-except-break-glass is now enforced at the credential level (see "Done so far"
above), not just the default habit — `akadmin` is the only account that can reach the
password/MFA path, that path now forces MFA enrollment instead of skipping it, enrollment itself
is gated to trusted emails/domains, and the password policy for that one remaining path is bound
and tightened. **Still open**: `akadmin` itself has zero MFA devices enrolled — the `configure`
action will force this on next password login, but hasn't happened yet (owner task, in progress).

### 2.2 Network segmentation — the biggest structural gap

**Nothing enforces east-west traffic.** Calico is fully deployed — including Whisker + Goldmane,
its flow-visibility stack — but there are **zero** `NetworkPolicy`/`GlobalNetworkPolicy` resources
anywhere in this repo. Every pod can reach every other pod/service regardless of namespace. If any
externally-exposed app gets popped (RCE, a bad dependency, whatever), there's currently zero
lateral-movement friction to CNPG databases, Ceph, Authentik, kopiur backups — anything.

**Full plan, including a real flow-data review: `docs/network-policy-plan.md`.** Short version:
Calico `NetworkPolicy`/`GlobalNetworkPolicy` (not plain Kubernetes `NetworkPolicy`, not a service
mesh — see that doc for why), rolled out via Calico's staged policies (already installed) so
nothing is enforced blind, baseline is namespace-level default-deny plus a short list of
cluster-wide exceptions (DNS, Envoy Gateway ingress, Prometheus scraping) rather than a bespoke
policy per app.

### 2.3 Per-app rate limiting

Only `llama-cpp` has its own `BackendTrafficPolicy` today; every other externally-exposed app
shares the one blanket 100 req/s limit on the `envoy-external` `https` listener. That's a
reasonable backstop but coarse — a login endpoint (jellyfin, audiobookshelf) getting hammered for
credential stuffing doesn't need 100 req/s, and one noisy/abused app can eat the whole external
budget for everyone else sharing that listener.

Plan: add a tighter, per-route `BackendTrafficPolicy` (`targetRefs` an app's `HTTPRoute`, not the
whole Gateway) for each newly-external app, especially ones fronting a login form. Revisit the
global 100 req/s once there are enough external apps that legitimate combined traffic could
plausibly bump into it.

### 2.4 Image scanning / admission control

No Trivy (or equivalent) scanning images pre-deploy, no Kyverno/Gatekeeper enforcing pod security
baselines beyond what's hand-written per-`HelmRelease`. Renovate keeps images current, which
covers known-CVE patching *reactively*, but nothing catches a vulnerable image before it deploys
or enforces baseline pod-security policy cluster-wide. Lower priority than 2.1–2.3 — worth doing,
not worth blocking on.

---

## 3. External-exposure candidates — per-app notes

The actual "which apps get an external route" decision, made deliberately per app rather than
default-yes. Status as of 2026-08-20:

| App | Status | Auth today | Notes |
|-----|--------|-----------|-------|
| immich | **external** | native accounts (no SSO — explicitly out of scope, admin-UI-only OIDC config) | precedent for "native accounts are enough for family use" |
| home-assistant | **internal only** (corrected — `helmrelease.yaml` has only an `envoy-internal` route; this table previously said "external" incorrectly) | Authentik SSO, live-tested (§3.2) | still native-account-capable as fallback (`hass-oidc-auth` doesn't remove it) |
| grocy | **not deployed** (`ks.yaml` commented out in `apps/home/kustomization.yaml`) | native accounts — not yet verified | Its `helmrelease.yaml` had a leftover external route from before it was disabled - not a live exposure gap, just stale config. Switched to internal-only for whenever it's actually enabled; revisit auth model at that point. |
| vaultwarden | internal only, **deliberately deferred** | native accounts, master password is the real boundary | agreed valuable (that's the point of a password manager) but not a default-yes — holding off for now, not forgotten |
| jellyfin | internal only, candidate | native accounts, no MFA/SSO (SSO plugin needs manual REST-API setup, backlog) | biggest risk is transcoding as a resource-exhaustion vector for anonymous abuse, plus credential stuffing on reused passwords; wire SSO or at least `protect-external` before exposing, and give it its own §2.3 rate limit |
| audiobookshelf | internal only, candidate | native accounts, no SSO | same profile as jellyfin but much smaller surface (little/no transcoding) — lower risk, reasonable to expose sooner with strong unique passwords |
| copy-party | internal only, candidate | volume ACLs (see "Done" above) | ACL redesign in progress; public read-only + root-only write is the right shape before this goes external |
| grimmory | internal only, candidate | **not yet checked** | confirm its auth model before considering external exposure |
| tuwunel | not deployed for real use yet | n/a | holding off is the right call — if federation is ever wanted, that's a different exposure model entirely (server reachable on 8448 or `.well-known` delegation on 443, closed registration, its own hardening), not a routine HTTPRoute add. Revisit once you've actually used it and know if you want federation vs. just remote client access |
| searxng | internal only, **should stay internal** | n/a | self-hosted search proxies are a magnet for bots hunting an open relay/scraper if exposed publicly |

---

## 3.1 Full app sweep (2026-08-22)

Follow-up to "did the initial research pass miss anything" — swept every app with a `route:`/
`HTTPRoute` block across the whole repo (not just the ones already tracked above) and checked
which are `envoy-external` vs internal-only. Initial pass flagged grocy as an externally-exposed
miss, but its `ks.yaml` is commented out in `apps/home/kustomization.yaml` - not actually deployed,
so no live gap there (its `helmrelease.yaml` had a stale external route from before it was
disabled, switched to internal-only regardless). Everything below is internal-only and lower
urgency than §3's candidates, but flagging two for being more sensitive than "internal" alone
implies:

- **frigate** (`frigate.internal.oreillys.io`) — NVR web UI, live camera feeds. Native accounts,
  not reviewed for MFA/strength. Worth the same deliberate treatment as home-assistant even though
  it's staying internal-only, since "internal" here just means "reachable by anything on the LAN,"
  not "low value if compromised."
- **omada-controller** (`omada.internal.oreillys.io`) — controls the actual network switch/AP
  hardware. Native accounts. Compromise here is a path to re-poisoning the network itself, not just
  one app's data - same reasoning.

Everything else swept (bazarr, lazylibrarian, qbittorrent, qui, sabnzbd, slskd, soularr, esphome,
grocy, microbin, octoprint, ersatztv, jellyseerr, podfetch, tdarr, tube-archivist, atuin,
thelounge, akvorado, llama-cpp, kromgo) is internal-only with no external route, and kromgo
specifically is a public-by-design status/metrics JSON endpoint (no accounts to protect), not a
gap. None of these are wired to SSO; none are being proposed for it right now - listed here so a
future "did we miss anything" pass doesn't have to re-derive this list from scratch.

---

## 3.2 Home Assistant SSO — research (2026-08-22)

HA core has no built-in OIDC/SSO support, so this always needed a component. The option this
table used to point at, `hass-auth-header` (BeryJu's header-trust component, meant to pair with
Authentik's own forward-auth proxy), is **archived as of October 2025** — the maintainer's note
says to use one of the newer OIDC-native components instead. Not viable.

**Chosen: [`hass-oidc-auth`](https://github.com/christiaangoossens/hass-oidc-auth)** (HACS,
actively maintained, dedicated Authentik setup guide). Makes HA itself a real OIDC relying party —
same shape as grafana/paperless-ngx's native-OIDC pattern, but via a custom_component since it's
not built into HA core. Fully YAML-configurable
([docs](https://github.com/christiaangoossens/hass-oidc-auth/blob/main/docs/configuration.md)), so
this can be wired entirely through git — no manual UI step required, unlike a plain HACS install.

Three things worth being deliberate about, given how much this app controls:

- **Replaces `components/authentik/protect`, doesn't layer with it.** The project's own FAQ says
  to remove any reverse-proxy SSO layer once this is installed — HA's `HTTPRoute` does not get the
  `protect` component; HA does the entire OIDC flow itself.
- **No session revocation until token expiry.** Disabling/logging a user out in Authentik doesn't
  kill an already-live HA session.
- **Mobile companion app login is a device-code flow** (enter a code from the app into a browser),
  not the seamless native redirect — a real regression from HA's current native-account mobile
  login.

**Implementation status:**
- ✅ Authentik provider + application blueprint entry (`provider-home-assistant.yaml`, moved into
  `blueprints-native-apps.yaml` — it belongs there, not `blueprints-protected-apps.yaml` where it
  first landed in PR #670; that file's own header is explicit that it's for apps with no
  `components/authentik/protect` SecurityPolicy, which is exactly HA's setup, same category as
  grafana/paperless-ngx/linkwarden/forgejo/immich) — **public client** (project's own
  recommendation: PKCE + redirect-URL matching is enough for a home setup, no client secret to
  manage at all). Gated via a dedicated `home-assistant-users` group (`blueprints-groups.yaml`),
  same convention as changedetection/linkwarden/forgejo — empty membership by default, add via the
  Authentik UI.
- ✅ `auth_oidc` custom_component installed via GitOps: an `initContainer` on the `home-assistant`
  controller downloads the pinned `hass-oidc-auth` GitHub release zip, verifies its sha256, and
  unpacks it into the persistent `/config/custom_components/auth_oidc` — no HACS runtime/UI
  involved, version is pinned in git like every other image/chart in this repo.
- ✅ `auth_oidc:` block added to `configuration.yaml` (`client_id`, `discovery_url` — no
  `client_secret`, matching the public-client choice above).
- ✅ **Live-tested and working (2026-08-22)** — real SSO login confirmed end-to-end.
- ✅ **Admin-role auto-grant, done.** PR #670's "not done yet" note here was wrong — no custom
  scope mapping was ever needed. `blueprints-native-apps.yaml`'s own header already documented
  (confirmed against Authentik's shipped `scope-profile` mapping) that the default profile scope
  already returns a `groups` claim — `[group.name for group in request.user.groups.all()]` — and
  the home-assistant provider already requests that scope. Just needed `roles: {admin:
  home-assistant-admins}` in `configuration.yaml` plus a new `home-assistant-admins` group,
  same pattern as `grafana-admins`/`nebraska-admins`. Empty membership by default.

---

## 4. Suggested sequencing

1. ~~**Authentik login-flow hardening** (§2.1)~~ — done and live-tested, branches
   `authentik-brute-force-protection` + `authentik-brute-force-threshold` (see §2.1).
2. **Network segmentation, phased** (§2.2) — start observing flow data now on the namespaces about
   to gain external exposure, so policy work isn't blocking the app rollout below.
3. **Finish copy-party** (in progress) and expose it, since the ACL redesign is already done.
4. **Home Assistant** — internal only today; SSO live and working (§3.2). Confirm MFA/backup-login
   story and add its own rate-limit policy (§2.3) before considering external exposure.
5. **Audiobookshelf** — lower risk than jellyfin, reasonable next.
6. **Jellyfin** — after SSO/`protect-external` is wired (or a deliberate decision to accept native
   accounts only, as immich already does) and its own rate limit is in place.
7. **Grimmory** — after confirming its auth model.
8. **Image scanning / admission control** (§2.4) — no urgency, pick up whenever.
9. **Grocy** — not deployed yet; revisit exposure/auth model whenever it's actually enabled.

## 5. Open items to confirm

- Home Assistant SSO — live and working, admin-role auto-grant wired (§3.2). Add yourself to
  `home-assistant-users` (and `home-assistant-admins` if you want the HA admin role) via the
  Authentik UI if not already done.
- Home Assistant MFA — actually enabled, or just available? Matters less once SSO lands (Authentik
  becomes the real credential boundary), but still worth confirming for the native-login fallback.
- Grocy — not deployed yet; revisit auth model and exposure once it's actually enabled.
- Grimmory's auth model — native accounts? anything at all?
- Frigate / omada-controller — worth a deliberate MFA/password-strength review given what they
  control, even while staying internal-only (§3.1).
- Whether the global 100 req/s external rate limit needs raising once more apps share it, or
  per-app policies make that moot.
- Watch for the deny stage accidentally firing on legitimate use (shared household IP, someone
  fat-fingering their password a few times) now that it's confirmed working — the `-3` threshold
  is tighter than the original `-5`, worth revisiting if it turns out too trigger-happy in practice.
