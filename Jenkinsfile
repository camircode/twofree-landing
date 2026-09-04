// Builds the image, pushes it to GHCR by digest, and commits that digest to the
// GitOps repository.
//
// This pipeline never touches the cluster. Argo CD does the deploying, and the
// only thing Jenkins changes is a line in git — which is why the git log of
// camircode/gitops is the real deployment history.

pipeline {
    agent { label 'docker' }

    options {
        timestamps()
        timeout(time: 25, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    environment {
        REGISTRY = 'ghcr.io'
        IMAGE    = 'ghcr.io/camircode/twofree-landing'
        GITOPS   = 'git@github.com:camircode/gitops.git'
        MANIFEST = 'manifests/twofree-landing/deployment.yaml'

        // Baked into the HTML by `astro build`, so they are decided here rather
        // than at deploy time: changing one of these means rebuilding, not
        // restarting a pod. None of them is a secret — every value ends up in
        // the page source of a public website.
        //
        // PUBLIC_SITE_URL is the one that silently breaks things when it is
        // wrong: it becomes `site` in astro.config.mjs, which generates every
        // canonical link, Open Graph URL and sitemap entry. A build without it
        // publishes a sitemap advertising http://localhost:4321 to Google.
        PUBLIC_SITE_URL           = 'https://2free.camir.tech'
        PUBLIC_WEB_URL            = 'https://2free.camir.tech/app'
        PUBLIC_SOURCE_URL         = 'https://github.com/camircode/2free'
        PUBLIC_GITHUB_REPOSITORY  = 'camircode/2free'
    }

    stages {
        stage('Build') {
            steps {
                // In a container rather than on the agent, so the agent does not
                // accumulate a toolchain per language it ever built, and so the
                // Node here is the same Node the Dockerfile uses.
                //
                // This runs before the image build on purpose. Both compile the
                // same site, but a failure here comes back as an Astro error
                // with a file and a line, whereas the same failure inside buildx
                // arrives as a wall of interleaved layer output.
                //
                // Three flags that are not decoration:
                //
                //   -u, so node_modules is not left behind owned by root for
                //   cleanWs() to fail on afterwards.
                //
                //   HOME=/tmp, because corepack writes there and a uid mapped in
                //   with -u has no home directory inside the image.
                //
                //   the /tmp/bin dance, because corepack resolves its install
                //   directory with realpathSync and fails with a bare ENOENT
                //   naming no path if it does not already exist.
                sh '''
                    set -eu

                    docker run --rm \
                      -u "$(id -u):$(id -g)" \
                      -e HOME=/tmp -e CI=true \
                      -e PUBLIC_SITE_URL -e PUBLIC_WEB_URL \
                      -e PUBLIC_SOURCE_URL -e PUBLIC_GITHUB_REPOSITORY \
                      -v "$PWD":/src -w /src \
                      node:24 \
                      sh -c '
                        set -eu
                        mkdir -p /tmp/bin
                        corepack enable --install-directory /tmp/bin
                        export PATH=/tmp/bin:$PATH
                        pnpm install --frozen-lockfile
                        pnpm check
                        pnpm build
                      '
                '''
            }
        }

        stage('Build and push') {
            steps {
                // Computed in Groovy, not in the shell. `${VAR:0:7}` is a bash
                // substring and Jenkins runs `sh`, which on Debian is dash: it
                // answers "Bad substitution" and nothing else.
                script {
                    env.SHORT_SHA = env.GIT_COMMIT.take(7)
                }
                withCredentials([usernamePassword(
                    credentialsId: 'ghcr',
                    usernameVariable: 'GHCR_USER',
                    passwordVariable: 'GHCR_PASS',
                )]) {
                    sh '''
                        set -eu
                        echo "$GHCR_PASS" | docker login "$REGISTRY" -u "$GHCR_USER" --password-stdin

                        docker buildx create --use --name builder 2>/dev/null || docker buildx use builder

                        # The tag exists so a human can find the build; the digest
                        # is what gets deployed. --metadata-file is how the digest
                        # comes back without a second registry round trip.
                        #
                        # --build-arg and not --secret: these are public values
                        # that Astro inlines into the shipped HTML, so hiding them
                        # from the image history would protect nothing and only
                        # make the build harder to reproduce.
                        docker buildx build \
                          --push \
                          --provenance=false \
                          --build-arg "PUBLIC_SITE_URL=$PUBLIC_SITE_URL" \
                          --build-arg "PUBLIC_WEB_URL=$PUBLIC_WEB_URL" \
                          --build-arg "PUBLIC_SOURCE_URL=$PUBLIC_SOURCE_URL" \
                          --build-arg "PUBLIC_GITHUB_REPOSITORY=$PUBLIC_GITHUB_REPOSITORY" \
                          --tag "$IMAGE:$SHORT_SHA" \
                          --metadata-file metadata.json \
                          .
                    '''
                }
                script {
                    def meta = readJSON file: 'metadata.json'
                    env.IMAGE_DIGEST = meta['containerimage.digest']
                    echo "Pushed ${env.IMAGE}@${env.IMAGE_DIGEST}"
                }
            }
        }

        stage('Smoke test') {
            steps {
                // Start the image before committing its digest.
                //
                // The Build stage cannot cover this. It compiles the source; it
                // never runs the thing that serves it. Everything that makes
                // this image different from `astro build` on a laptop — the web
                // server, the port it binds, the uid it binds it as, whether it
                // can write anything at all — only exists once the container
                // starts.
                //
                // The specific failure this catches: stock nginx starts as root
                // to bind port 80. Under runAsNonRoot it never gets to be root,
                // so it dies at startup with "bind() to 0.0.0.0:80 failed (13:
                // Permission denied)" and the pod lands in CrashLoopBackOff. The
                // build is perfectly green either way.
                //
                // So it runs with the same user and the same read-only root
                // filesystem the Deployment applies, because "works as root" and
                // "works as 10001 with nothing writable" are different claims.
                // /tmp is a tmpfs here for the same reason it is an emptyDir
                // there: nginx puts its pid file and its request buffers under
                // /tmp, and an unwritable /tmp stops it before the first request.
                //
                // By digest, not by tag: what is tested is exactly what ships.
                sh '''
                    set -eu
                    NET="smoke-$BUILD_NUMBER"
                    APP="smoke-landing-$BUILD_NUMBER"

                    cleanup() {
                      docker logs "$APP" 2>&1 | tail -30 || true
                      docker rm -f "$APP" >/dev/null 2>&1 || true
                      docker network rm "$NET" >/dev/null 2>&1 || true
                    }
                    trap cleanup EXIT

                    docker network create "$NET"

                    docker pull "${IMAGE}@${IMAGE_DIGEST}"
                    docker run -d --name "$APP" --network "$NET" \
                      --user 10001:10001 --read-only --tmpfs /tmp \
                      "${IMAGE}@${IMAGE_DIGEST}"

                    # curl from a container on the same network: the agent needs
                    # neither curl installed nor a published port.
                    probe() {
                      docker run --rm --network "$NET" curlimages/curl:latest \
                        -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://$APP:8080$1"
                    }

                    ok=""
                    for i in $(seq 1 30); do
                      if [ "$(probe / || true)" = "200" ]; then ok=yes; break; fi
                      sleep 2
                    done
                    [ -n "$ok" ] || { echo "The image never answered on / at port 8080."; exit 1; }

                    # A second route, because / would still answer 200 from the
                    # base image's own index.html if the COPY of dist had gone
                    # to the wrong path. /autohospedaje/ only exists if this
                    # site's build is what is being served.
                    [ "$(probe /autohospedaje/)" = "200" ] || { echo "/autohospedaje/ did not answer 200; dist may not be what is being served."; exit 1; }

                    echo "Smoke test passed: the image starts as 10001 on a read-only filesystem and serves the site."
                '''
            }
        }

        stage('Scan') {
            steps {
                // After the push and before the GitOps commit, deliberately. An
                // image that fails here exists in the registry and is never
                // referenced by anything, which is harmless — whereas scanning
                // before the push would mean scanning an image built from a
                // different set of layers than the one that shipped.
                //
                // --ignore-unfixed, because failing a build over a vulnerability
                // with no fix available teaches people to ignore the scanner. The
                // exceptions live in .trivyignore.yaml, each with a reachability
                // argument and a date it stops applying.
                withCredentials([usernamePassword(
                    credentialsId: 'ghcr',
                    usernameVariable: 'GHCR_USER',
                    passwordVariable: 'GHCR_PASS',
                )]) {
                    sh '''
                        set -eu
                        docker run --rm \
                          -e TRIVY_USERNAME="$GHCR_USER" \
                          -e TRIVY_PASSWORD="$GHCR_PASS" \
                          -v "$HOME/.cache/trivy:/root/.cache/" \
                          -v "$PWD/.trivyignore.yaml:/.trivyignore.yaml:ro" \
                          aquasec/trivy:latest image \
                            --scanners vuln \
                            --severity HIGH,CRITICAL \
                            --ignore-unfixed \
                            --ignorefile /.trivyignore.yaml \
                            --exit-code 1 \
                            "${IMAGE}@${IMAGE_DIGEST}"
                    '''
                }
            }
        }

        stage('Update the desired state') {
            steps {
                sshagent(credentials: ['gitops-write']) {
                    sh '''
                        set -eu
                        rm -rf gitops
                        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
                          git clone --depth 1 "$GITOPS" gitops

                        cd gitops
                        git config user.email "jenkins@camir.tech"
                        git config user.name  "jenkins"

                        # Matches the repository rather than the old value, so the
                        # scaffold's :PLACEHOLDER, a previous digest and a
                        # hand-edited manifest are all corrected rather than one
                        # of them being silently skipped.
                        sed -i -E "s#image: ghcr\\.io/camircode/twofree-landing[@:][^[:space:]]+#image: ${IMAGE}@${IMAGE_DIGEST}#" "$MANIFEST"

                        if git diff --quiet; then
                          echo "Already at ${IMAGE_DIGEST}; nothing to commit."
                          exit 0
                        fi

                        git add "$MANIFEST"
                        git commit -m "deploy(twofree-landing): ${IMAGE_DIGEST}

Built from camircode/twofree-landing@${GIT_COMMIT} by Jenkins build ${BUILD_NUMBER}."
                        GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git push origin main
                    '''
                }
            }
        }
    }

    post {
        always {
            sh 'docker logout ghcr.io || true'
            cleanWs()
        }
    }
}
