#syntax=docker/dockerfile:1.10
# Shopware 6 on Shopware's official runtime image (FrankenPHP: Caddy with
# embedded PHP, one process), following Shopware's Docker guide:
# https://developer.shopware.com/docs/guides/hosting/installation-updates/docker.html
#
# The project is created and built with shopware-cli at build time (only the
# Shopware version is pinned), then copied into the runtime image. The code is
# immutable: upgrading Shopware means changing SW_VERSION and rebuilding; the
# stack's `setup` service then runs the migrations (deployment helper).

ARG PHP_VERSION=8.5
FROM ghcr.io/shopware/docker-base:${PHP_VERSION}-frankenphp AS base-image
FROM ghcr.io/shopware/shopware-cli:latest-php-${PHP_VERSION} AS build

ARG SW_VERSION=6.7.14.2
ENV SHOPWARE_CACHE_ID=docker
WORKDIR /src

RUN --mount=type=cache,target=/root/.composer \
    shopware-cli project create /src --version "${SW_VERSION}" -n
# Stack configuration (e.g. the admin worker is replaced by the `worker` service).
COPY config/packages/ /src/config/packages/
RUN --mount=type=cache,target=/root/.composer \
    --mount=type=cache,target=/root/.npm \
    /usr/local/bin/entrypoint.sh shopware-cli project ci /src
# Writable directories (volumes in the stack): created here so new volumes
# are owned by www-data (82) instead of root.
RUN mkdir -p /src/files /src/public/theme /src/public/media /src/public/thumbnail /src/public/sitemap

FROM base-image AS final

ARG SW_VERSION=6.7.14.2
ENV SW_VERSION=${SW_VERSION} \
    SHOPWARE_DISABLE_UPDATE_CHECK=1

COPY --from=build --chown=82 --link /src /var/www/html
