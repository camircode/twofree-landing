# twofree-landing

The public marketing site for 2 Free, at <https://2free.camir.tech>.

Astro 6 with `output: "static"` — the build produces plain HTML, CSS and
fonts, and the container that serves them is nginx with no application runtime
behind it. Two pages (`/` and `/autohospedaje/`), plus a generated
`robots.txt` and sitemap.

Extracted from the `camircode/2free` monorepo, which it no longer depends on:
the logo and the social-preview image live in `src/assets/` here.

## Building it locally

```sh
pnpm install
pnpm build      # writes dist/
pnpm dev        # http://localhost:4321
pnpm check      # astro check; the pipeline runs this too
```

The container, run the way Kubernetes runs it:

```sh
docker build -t twofree-landing:local .
docker run --rm --user 10001:10001 --read-only --tmpfs /tmp \
  -p 18080:8080 twofree-landing:local
curl -i http://127.0.0.1:18080/
```

Those three flags are not optional decoration. The image serves on **8080**,
not 80, because a process running as uid 10001 cannot bind a privileged port,
and it needs a writable `/tmp` because that is where nginx keeps its pid file
and its request buffers. Running it as root with a writable root filesystem
proves nothing about whether it will start in the cluster.

## Configuration

Four build-time values, all public — Astro inlines them into the HTML, so none
of them is or can be a secret. They are `--build-arg`s, set in the
`env` block of `.github/workflows/ci.yml`:

| Variable | Effect |
| --- | --- |
| `PUBLIC_SITE_URL` | Becomes `site` in `astro.config.mjs`; generates canonical links, Open Graph URLs and the sitemap |
| `PUBLIC_WEB_URL` | Where the "open the app" links point |
| `PUBLIC_SOURCE_URL` | The GitHub link in the header and footer |
| `PUBLIC_GITHUB_REPOSITORY` | `owner/name`, shown on the page |

Changing one means rebuilding the image. Restarting a pod will not pick up a
new value, because by then the value is already inside the HTML.

## Deploying

Push to `main`. GitHub Actions builds the image, pushes it to
`ghcr.io/camircode/twofree-landing`, smoke-tests it by digest under the same
uid and read-only filesystem the cluster uses, scans it with Trivy, and then
commits the digest to `camircode/gitops`. Argo CD applies it.

**Never `kubectl apply`.** Nothing here talks to the cluster and neither should
you: Argo CD reconciles against git, so a manual apply is reverted on the next
sync and, until it is, the manifest in git no longer describes what is running.
The deployment history of this site is the git log of `camircode/gitops`.

## Licence

AGPL-3.0-only.
