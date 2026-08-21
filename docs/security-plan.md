# Security Plan

Status: **Roadmap** (started 2026-08-20). Triggered by wanting to expose more services
externally (jellyfin, audiobookshelf, home-assistant, copy-party, grimmory, maybe tuwunel later)
— this is the "what needs to be true first" conversation that `home-ops-authentik-sso` memory
had flagged as deferred. Nothing below is urgent-blocking (home-assistant, immich, and vaultwarden
already sit behind `envoy-external` today), but the surface is about to grow and a few structural
gaps are worth closing before it does rather than after.

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

**Open, not yet decided:** `default-authentication-flow`'s MFA stage (and this brute-force
protection) only applies to the direct username+password login path — anyone using an SSO source
button (Google/GitHub) is routed through a completely separate flow
(`default-source-authentication`) that never touches it. The intent has been "SSO for everyone
except the break-glass `akadmin` account," but that isn't actually enforced at the credential
level today: both `brian@oreillys.io` and `brianporeilly@gmail.com` still have a **usable local
password** alongside their SSO link (`has_usable_password() == True`, confirmed live), so the
password/MFA-less path is reachable for them too, not just `akadmin`. To make "SSO except
break-glass" real rather than just the default habit, those two accounts' local passwords need to
be disabled (`set_unusable_password()`), leaving `akadmin` as the only account that can ever reach
that flow — at which point requiring MFA on that flow specifically becomes meaningful (right now
zero MFA devices are enrolled anywhere in the system, including `akadmin`). Not done — this
changes account access and needs a deliberate go-ahead, not a default-yes.

### 2.2 Network segmentation — the biggest structural gap

**Nothing enforces east-west traffic.** Calico is fully deployed — including Whisker + Goldmane,
its flow-visibility stack — but there are **zero** `NetworkPolicy`/`GlobalNetworkPolicy` resources
anywhere in this repo. Every pod can reach every other pod/service regardless of namespace. If any
externally-exposed app gets popped (RCE, a bad dependency, whatever), there's currently zero
lateral-movement friction to CNPG databases, Ceph, Authentik, kopiur backups — anything.

Plan:
1. Use Whisker/Goldmane to observe real east-west traffic per namespace **before** writing
   anything — don't default-deny blind on an established cluster, that's how things quietly break.
2. Start with default-deny + explicit allow on the namespaces that are actually about to gain
   external exposure (media, home, misc) rather than the whole cluster at once.
3. Explicitly allow the traffic every app actually needs: DNS, its own database/cache, Envoy
   Gateway ingress, kopiur's mover Jobs, Prometheus scraping. Expect a few iterations as
   legitimate traffic gets missed on the first pass.
4. Extend cluster-wide once the pattern is proven on a couple of namespaces.

This is "finally use what's already running," not a new dependency — the visibility tooling is
the reason to do this now instead of guessing at rules blind.

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
| home-assistant | **external** | native accounts + optional TOTP | proxying (`use_x_forwarded_for`/`trusted_proxies`) confirmed correct; confirm MFA is actually turned on |
| vaultwarden | internal only, **deliberately deferred** | native accounts, master password is the real boundary | agreed valuable (that's the point of a password manager) but not a default-yes — holding off for now, not forgotten |
| jellyfin | internal only, candidate | native accounts, no MFA/SSO (SSO plugin needs manual REST-API setup, backlog) | biggest risk is transcoding as a resource-exhaustion vector for anonymous abuse, plus credential stuffing on reused passwords; wire SSO or at least `protect-external` before exposing, and give it its own §2.3 rate limit |
| audiobookshelf | internal only, candidate | native accounts, no SSO | same profile as jellyfin but much smaller surface (little/no transcoding) — lower risk, reasonable to expose sooner with strong unique passwords |
| copy-party | internal only, candidate | volume ACLs (see "Done" above) | ACL redesign in progress; public read-only + root-only write is the right shape before this goes external |
| grimmory | internal only, candidate | **not yet checked** | confirm its auth model before considering external exposure |
| tuwunel | not deployed for real use yet | n/a | holding off is the right call — if federation is ever wanted, that's a different exposure model entirely (server reachable on 8448 or `.well-known` delegation on 443, closed registration, its own hardening), not a routine HTTPRoute add. Revisit once you've actually used it and know if you want federation vs. just remote client access |
| searxng | internal only, **should stay internal** | n/a | self-hosted search proxies are a magnet for bots hunting an open relay/scraper if exposed publicly |

---

## 4. Suggested sequencing

1. ~~**Authentik login-flow hardening** (§2.1)~~ — done and live-tested, branches
   `authentik-brute-force-protection` + `authentik-brute-force-threshold` (see §2.1).
2. **Network segmentation, phased** (§2.2) — start observing flow data now on the namespaces about
   to gain external exposure, so policy work isn't blocking the app rollout below.
3. **Finish copy-party** (in progress) and expose it, since the ACL redesign is already done.
4. **Home Assistant** — proxying's already correct; confirm MFA, add its own rate-limit policy
   (§2.3), then expose.
5. **Audiobookshelf** — lower risk than jellyfin, reasonable next.
6. **Jellyfin** — after SSO/`protect-external` is wired (or a deliberate decision to accept native
   accounts only, as immich already does) and its own rate limit is in place.
7. **Grimmory** — after confirming its auth model.
8. **Image scanning / admission control** (§2.4) — no urgency, pick up whenever.

## 5. Open items to confirm

- Home Assistant MFA — actually enabled, or just available?
- Grimmory's auth model — native accounts? anything at all?
- Whether the global 100 req/s external rate limit needs raising once more apps share it, or
  per-app policies make that moot.
- Watch for the deny stage accidentally firing on legitimate use (shared household IP, someone
  fat-fingering their password a few times) now that it's confirmed working — the `-3` threshold
  is tighter than the original `-5`, worth revisiting if it turns out too trigger-happy in practice.
