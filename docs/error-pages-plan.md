# Custom Error Pages Plan

Status: **Live, with a known limitation accepted on purpose** (2026-08-21). Companion to
`kubernetes/apps/network/error-pages/` and `envoy-gateway/config/envoy.yaml`'s `responseOverride`.

**Current state:** styled error pages (tarampampam/error-pages, `l7` theme) are served for
400/401/403/404/429/500/502/503/504 on both gateways, via `BackendTrafficPolicy.responseOverride`'s
`redirect` action - Envoy internally fetches the page from error-pages and returns its body to the
client, including real Accept-header content negotiation (HTML/JSON/XML). **Known bug, accepted for
now:** the client-facing status code is always `302`, never the real code (400/404/500/etc), because
of an Envoy Gateway API restriction - see §2. Content is correct, status code is not.

---

## 1. What was tried, in order, and why each didn't stick

1. **Dynamic `redirect`** (first implementation) - worked for content, but `redirect.statusCode` is
   hard-restricted to `301`/`302` at the CRD level. Client always saw `302`.
2. **Static `response` action** (ConfigMap-sourced HTML per status code, correct status codes) -
   switched to this to fix the status code. Broke much worse: Envoy Gateway translates
   `response.body` into Envoy's `LocalResponsePolicy.body_format.text_format`, which is parsed as an
   access-log-style `%COMMAND%` format string, not a raw string. Any literal `%` in the HTML/CSS
   (e.g. ordinary `width: 100%`) crashes the parser. Envoy **rejected the entire listener config**
   and silently kept serving the last-known-good snapshot - `kubectl get backendtrafficpolicy`
   showed `Accepted: True` the whole time, invisible at the Kubernetes layer. Both `envoy-internal`
   and `envoy-external`'s https listeners got stuck: not just error pages broken, but *every future
   config change to those listeners silently stopped applying* until reverted. Full incident detail
   in the `envoy-response-override-percent-bug` memory - worth reading before touching
   `response.body` again, even escaped (see §4).
3. **Reverted to `redirect`** (`revert-error-pages-static-response` branch, PR #622) - restored the
   known-working, if status-code-wrong, state. This is what's live now.
4. **`EnvoyPatchPolicy`** (researched, drafted, deliberately not adopted) - see §2.

## 2. Why the status code is wrong, and why we're not patching around it (yet)

The real Envoy proxy has always supported this correctly - `custom_response.redirect_policy.v3.RedirectPolicy.status_code`
accepts `200-999` per its own protobuf. The restriction to `301`/`302` is purely an Envoy Gateway API
choice (`api/v1alpha1/shared_types.go`, `CustomRedirect.StatusCode`:
`+kubebuilder:validation:Enum=301;302`), not something inherited from Envoy. Confirmed as a live,
acknowledged, still-open upstream bug via envoyproxy/gateway#9112 - a maintainer (zhaohuabing) said
directly "I think this is a valid API limitation... EG should not restrict redirect.statusCode to
only 301/302" and "that limit is still there and it should be corrected somewhere in the future."
That issue got closed only because the *original reporter's* problem was an unrelated
misconfiguration, not because the limitation itself was fixed.

**The real fix is a ~3-line upstream PR** (loosen that one `Enum` marker to a `Minimum`/`Maximum`
range, matching the sibling `response.statusCode` field's existing pattern from PR #9753) plus the
mechanical scaffolding around it (`make generate gen-check`, one CEL test, a release-note fragment).
Contribution bar is low: DCO only (no CLA), external PRs are the norm on this exact area of the
codebase, and a maintainer has already signaled agreement with the change - normally the hardest
part of a first PR. **Not yet filed** - draft issue text lives in this session's history, not yet
posted. Filing it (or a PR) is still open, worth doing since it costs little and the fix is small.

**The workaround (`EnvoyPatchPolicy`) exists but isn't enabled.** It directly overrides the
generated `status_code` field on each `redirect_policy` rule post-translation - the dynamic-fetch
mechanism itself untouched, just the one restricted field patched afterward. Fully drafted and
validated: schema-checked via server-side dry-run, and briefly applied live to confirm the CRD
accepts it. **Deliberately not wired into `kustomization.yaml`**, for one reason:
`EnvoyPatchPolicy` is disabled cluster-wide by default, and Envoy Gateway's own docs carry an
explicit security warning - enabling it lets anyone who can write that CRD inject **arbitrary Envoy
config**, with the blast radius of a full proxy compromise (read every header/cookie in flight,
extract TLS secrets, silently disable the rate-limiting/SSO/admin-block work already in
`docs/security-plan.md`). That's a real security decision for the whole cluster, not a narrow
scoped risk to this one feature, and not worth it for cosmetic error pages. The file
(`envoy-patch-error-pages-status-code.yaml`) is fully written, commented, and ready if that
calculus ever changes - see its own header comment for the enable/remove checklist either way.

## 3. If revisiting this later

In priority order:
1. **File the upstream issue/PR** (§2) - cheapest, and the actual correct fix. Check if it's landed
   in a newer Envoy Gateway release before doing anything else here.
2. **`%%`-escape the static approach** (§1.2) - untested but plausible: Envoy's format-string parser
   treats `%%` as an escaped literal `%` (confirmed via its own source,
   `source/common/formatter/substitution_formatter.cc`). Would keep everything inside the
   safe/supported `response` action, correct status codes, zero new attack surface - cost is losing
   Accept-header content negotiation (one fixed HTML body per code) and re-verifying escaping is
   applied to 100% of the static content, forever, by hand or a check step. If tried, verify via
   `/config_dump`'s `error_state`, not just `kubectl status` (see the percent-bug memory - status
   alone lied about this exact failure mode).
3. **Enable `EnvoyPatchPolicy`** (§2) - only if the security tradeoff becomes acceptable for a
   stronger reason than "styled 404 pages." The draft is ready.

## 4. Not chosen, with reasons (don't re-litigate without a new one)

- **Lua filter via `EnvoyExtensionPolicy`** - initially proposed, then ruled out: Envoy's Lua filter
  cannot modify the response status code from `envoy_on_response` at all ("the status has been
  decided" by that phase, confirmed via Envoy's own Lua filter docs). Would only ever have solved
  the body, not the status - the exact problem that needed solving.
- **A different Envoy Gateway version** - checked; we're already on the latest release (v1.9.0) and
  the limitation is confirmed still present by a maintainer. Nothing to upgrade to.
- **A different error-page project** - tarampampam/error-pages is the right tool; it even ships a
  dedicated static-generator build target (`ghcr.io/tarampampam/error-pages:<version>-builder`) used
  to regenerate the current static HTML, separate from the server image actually deployed. The
  limitation is entirely in Envoy Gateway's translation layer, not the content source.
