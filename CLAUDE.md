# CLAUDE.md — `camircode/twofree-landing`

The public marketing site at <https://2free.camir.tech>. Astro 6 with
`output: "static"`: two pages (`/` and `/autohospedaje/`), a generated
`robots.txt` and a sitemap. The build produces plain HTML, CSS and fonts, and the
container that serves them is nginx with no application runtime behind it.

It owns the **root** of that host. `camircode/twofree-web` is served under `/app`
on the same hostname, which is why a broken redirect here lands visitors in the
wrong application rather than on a 404.

Unlike the other extracted repositories, this one **does not consume the shared
`@camircode/twofree-*` packages** — no dependency, no scope mapping in `.npmrc`.
The logo and the social-preview image live in `src/assets/` here. Keep it that
way: adding a `@camircode` dependency would couple this site's delivery to the
publish cycle of `camircode/twofree-packages`, where a change must be versioned
and published before any consumer can install it, and a bump to a version that is
not published yet fails in the `deps` stage of the Docker build.

---

## 1. How a change reaches the cluster

Push to `main` → **GitHub Actions** (`.github/workflows/ci.yml`) →
`astro check` in a container → `docker buildx` push to GHCR **by digest** →
smoke-test that digest → Trivy (HIGH/CRITICAL, `--ignore-unfixed`) → commit the
digest into `manifests/twofree-landing/deployment.yaml` in `camircode/gitops` →
Argo CD syncs.

The pipeline never touches the cluster. The git log of `camircode/gitops` is the
deployment history.

- **Never `kubectl apply`.** Argo CD is the only writer. A manual apply makes the
  cluster and the repository disagree, and Argo either reverts it or reports
  drift forever. `kubectl get/describe/logs/top`, `port-forward` and `exec` are
  fine.
- **Images are referenced by digest, never a tag and never `latest`.** A tag is a
  mutable pointer: two pods started an hour apart from the same tag can run
  different code, and a rollback to a tag rolls back to whatever that tag means
  today.
- **Secrets come from Bitwarden Secrets Manager only** — never in this repo,
  never in a ConfigMap, never in a plaintext Secret in the GitOps repo, never a
  build `ARG` (it persists in image history and `docker history` prints it back),
  never on a command line. Nothing here needs one today, which is why `.gitignore`
  excludes `.env` and `.env.*` outright: a `.env` appearing in this repository is
  a mistake, not a configuration.
- **Gateway API, never `Ingress`**; infrastructure changes belong in
  `/home/camir/Desarrollo/infrastructure`.

`pnpm-lock.yaml` **is** committed here (it resolves — nothing private is
involved), and both the `Dockerfile` and the `.github/workflows/ci.yml` install with
`--frozen-lockfile`. Any manifest change must commit the regenerated lockfile in
the same commit, or the next build stops at the install step.

## 2. Port 8080, and why the base image is unprivileged

The runtime is `nginxinc/nginx-unprivileged`, not stock nginx. The stock image
starts as root to bind port 80 and drops privileges for the workers; under
`runAsNonRoot` the master never gets to be root, so it can neither bind 80 nor
chown its runtime directories, and nginx exits with
`bind() to 0.0.0.0:80 failed (13: Permission denied)` before serving anything.

The container runs as uid **10001** with a **read-only root filesystem** and an
**emptyDir at `/tmp`** — nginx keeps its pid file and its request buffers there,
and an unwritable `/tmp` makes it fail at startup. Verify any container change
the way Kubernetes will run it:

```sh
docker build -t twofree-landing:local .
docker run --rm --user 10001:10001 --read-only --tmpfs /tmp -p 18080:8080 twofree-landing:local
```

Running it as root with a writable filesystem proves nothing. This class of
failure never appears in a build.

## 3. `deploy/default.conf` must be complete at commit time

The nginx entrypoint normally runs a `sed` pass over `default.conf` at startup to
substitute the listen directives and templates. **On a read-only root filesystem
that pass is skipped**, silently. Everything this site needs therefore has to
already be in the committed file, not added at startup:

- `listen 8080;` **and** `listen [::]:8080;` — the IPv6 line will not be added
  for you.
- `absolute_redirect off;` — the build emits directory routes
  (`/autohospedaje/index.html`), so `/autohospedaje` without the slash must be
  redirected. Absolute would send the client to `http://<pod-ip>:8080`; nginx
  does not know it is behind the Gateway.
- `try_files $uri $uri/ $uri/index.html =404;`
- the cache headers: a year and `immutable` for `/_astro/` (those filenames carry
  a content hash), and `no-cache` for every `index.html`, or a returning visitor
  keeps requesting the previous deploy's asset names long after they stopped
  existing.

Do not replace this file with the base image's own, and do not move any of it
into a startup template.

## 4. Every `PUBLIC_*` value is baked in at build time

`PUBLIC_SITE_URL`, `PUBLIC_WEB_URL`, `PUBLIC_SOURCE_URL` and
`PUBLIC_GITHUB_REPOSITORY` are `--build-arg`s, set in the `env` block of
`.github/workflows/ci.yml`. Astro inlines them into the HTML, so a build ARG is the
right shape and a secret never is.

`PUBLIC_SITE_URL` in particular becomes `site` in `astro.config.mjs`, which
generates the canonical links, the Open Graph URLs and `sitemap-0.xml`. Building
without it publishes a sitemap full of `http://localhost:4321`. Changing any of
them means rebuilding the image — restarting a pod picks up nothing, because by
then the value is already inside the HTML.

`public/` is empty and still tracked via `public/.gitkeep`: `COPY public ./public`
fails the build when its source is missing, and git does not track empty
directories.

## 5. Working here

```sh
pnpm install
pnpm dev      # http://localhost:4321
pnpm build    # writes dist/
pnpm check    # astro check — the pipeline runs this too
```
