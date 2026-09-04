# syntax=docker/dockerfile:1

# Multi-stage so the toolchain never reaches the running image. Node, pnpm,
# TypeScript and a Vite tree of several hundred packages are attack surface that
# does nothing once `astro build` has written the HTML.

# --- dependencies -------------------------------------------------------------
# Its own stage, and only the manifests are copied, so this layer is cached
# unless the lockfile changes. Editing a page does not re-resolve the tree.
FROM node:24-alpine AS deps
WORKDIR /src

# Corepack otherwise stops on an interactive "do you want to download pnpm?"
# prompt, which in a build has no one to answer it and just hangs until the
# timeout.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable

# .npmrc travels with the manifests, not as an afterthought: it carries
# strict-peer-dependencies and auto-install-peers=false, and without it the
# install resolves a different tree here than it does on a developer's machine.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile

# --- build --------------------------------------------------------------------
FROM node:24-alpine AS build
WORKDIR /src
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable
COPY --from=deps /src/node_modules ./node_modules
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc tsconfig.json astro.config.mjs ./
COPY src ./src

# public/ is empty today and still has to exist: COPY fails the build when its
# source path is missing, and git does not track empty directories. public/.gitkeep
# is what keeps a fresh clone buildable.
COPY public ./public

# Every one of these is public by definition: Astro inlines them into the HTML
# it ships to browsers, so a build ARG is the right shape for them and a secret
# never is. PUBLIC_SITE_URL in particular is not cosmetic — it becomes
# `site` in astro.config.mjs, which is what generates the canonical links, the
# Open Graph URLs and sitemap-0.xml. Building without it silently publishes a
# sitemap full of http://localhost:4321.
ARG PUBLIC_SITE_URL=https://2free.camir.tech
ARG PUBLIC_WEB_URL=https://2free.camir.tech/app
ARG PUBLIC_SOURCE_URL
ARG PUBLIC_GITHUB_REPOSITORY
ENV PUBLIC_SITE_URL=$PUBLIC_SITE_URL \
    PUBLIC_WEB_URL=$PUBLIC_WEB_URL \
    PUBLIC_SOURCE_URL=$PUBLIC_SOURCE_URL \
    PUBLIC_GITHUB_REPOSITORY=$PUBLIC_GITHUB_REPOSITORY

RUN pnpm build

# --- the image that runs ------------------------------------------------------
# nginx-unprivileged rather than plain nginx. The stock image starts as root to
# bind port 80 and drops privileges for the workers; under runAsNonRoot the
# master never gets to be root, so it cannot bind 80 and cannot chown its
# runtime directories. This variant listens on 8080 and keeps every writable
# path it needs under /tmp.
FROM nginxinc/nginx-unprivileged:1.29-alpine

COPY deploy/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist /usr/share/nginx/html

# Matches runAsNonRoot in the Deployment. Declaring it here as well means the
# image is safe to run without a securityContext rather than depending on one.
#
# 10001, not the image's own 101: the platform pins that uid, and nginx only
# needs to read files that are world-readable anyway. The one thing it must
# write is its pid file, and the base nginx.conf already puts that in /tmp —
# which the Deployment mounts as an emptyDir, because the root filesystem is
# read-only and an unwritable /tmp makes nginx fail at startup rather than under
# load.
USER 10001

EXPOSE 8080

# wget, not curl: the alpine image has busybox and no curl. --spider would only
# check the status line, so the body is fetched and discarded instead — a
# truncated index.html is exactly the failure a health check should catch.
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD wget -qO- http://127.0.0.1:8080/ >/dev/null || exit 1
