# Forgejo Pages

Static sites from Forgejo repos, served by [git-pages](https://codeberg.org/git-pages/git-pages)
(`kubernetes/apps/misc/git-pages/`). A Forgejo Actions job builds the site and
uploads the output directory; nothing else holds credentials.

## Enable Pages for a repo

Add `.forgejo/workflows/pages.yaml`:

```yaml
name: Pages
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      # build step for your generator, writing to _site/ (hugo, npm run build, ...)
      - uses: https://codeberg.org/git-pages/action@v2
        with:
          site: https://<owner>.pages.internal.oreillys.io/<repo>/
          token: ${{ forgejo.token }}
          source: _site/
```

The site is then at `https://<owner>.pages.internal.oreillys.io/<repo>/`.
A `404.html` at the top of the published directory is served for missing pages.

## How it fits together

- **Auth:** the job's automatic token (`forgejo.token`) is enough to publish
  that job's own repo. git-pages checks push permission with Forgejo
  (`auth: forge (wildcard): allow` in its log). No secrets, no per-repo setup.
  Publishing a different repo's site needs a personal access token.
- **Serving:** `*.pages.internal.oreillys.io` on envoy-internal. The cert has
  the `*.pages.internal.oreillys.io` SAN; DNS has a wildcard to `10.21.0.2`.
- **Storage:** filesystem backend on the `git-pages-data` ceph-filesystem PVC
  (backed up by kopiur). RGW is not used: git-pages' S3 manifest write
  (minio-go over plain HTTP) is rejected by RGW with 403, while the `aws` CLI
  works against the same bucket.
- **Egress:** the runner reaches git-pages through envoy-internal (already
  allowed); git-pages reaches only DNS and Forgejo.
- **Monitoring:** Gatus probes `gatus.pages.internal.oreillys.io` and accepts
  404 (an unpublished host proves route, TLS and pod are up).

## Caveats

- Any repo's published site is readable by everything that can reach the
  internal gateway, including sites built from private repos.
- Sites share the `internal.oreillys.io` parent domain with Forgejo and the
  other internal apps, so site JavaScript could set cookies on that parent.
  Acceptable for single-user internal use; an external setup needs a separate
  registrable domain.
- Not tested: the owner root site (`https://<owner>.pages.internal.oreillys.io/`
  from a repo named `pages`), `_redirects`, `_headers`.
- git-pages is pre-1.0 (pinned at 0.10.2); read release notes before bumping.
