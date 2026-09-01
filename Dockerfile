# syntax=docker/dockerfile:1

# --- fetch stage ------------------------------------------------------------
# Pinned to the *build* platform: the only arch-dependent thing here is which
# tarball we pull, so there is no reason to run curl/jq under QEMU emulation
# when building the arm images.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS fetch

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG TARGETVARIANT

# Expected release. Empty (the default) pins the build to version.json, so a
# local build reproduces the version this commit claims. CI passes the version
# it just detected upstream. Pass "latest" to deliberately accept whatever
# upstream is serving right now.
ARG CALDERA_VERSION=""

COPY version.json /tmp/version.json

# Upstream publishes only a rolling "latest/" prefix -- there are no versioned
# paths and no checksum files -- so the URL itself cannot pin anything. Instead
# we download, then compare the VERSION inside the tarball against what this
# repo expects, and fail the build on a mismatch. The image is then either
# exactly the advertised version or it does not build; it never drifts silently.
RUN set -eu; \
    case "${TARGETARCH}${TARGETVARIANT:-}" in \
        amd64*) arch=x86_64  ;; \
        arm64*) arch=aarch64 ;; \
        armv7*) arch=armv7   ;; \
        *) echo "unsupported platform: ${TARGETARCH}${TARGETVARIANT:-}" >&2; \
           echo "supported: linux/amd64, linux/arm64, linux/arm/v7" >&2; \
           exit 1 ;; \
    esac; \
    expected="${CALDERA_VERSION:-$(jq -r '.version' /tmp/version.json)}"; \
    mkdir -p /out; \
    curl -sSfL "https://releases.caldera.homes/music/headless/latest/caldera-music-linux-${arch}.tar.gz" \
        | tar xz -C /out; \
    actual="$(cat /out/VERSION)"; \
    if [ "$expected" != "latest" ] && [ "$expected" != "$actual" ]; then \
        echo "version mismatch: expected '$expected', tarball contains '$actual'" >&2; \
        echo "upstream has moved on; bump version.json or pass --build-arg CALDERA_VERSION=$actual" >&2; \
        exit 1; \
    fi; \
    echo "caldera-music $actual ($arch)"

# The daemon self-updates by exec'ing the bundled upgrade.sh, which would rewrite
# the install dir in the container's ephemeral layer -- changes that vanish on
# recreate and get re-downloaded on the next release. The image is the source of
# truth here, so drop the updater. The systemd unit and the $HOME-bound wrapper
# script are equally meaningless in a container.
RUN rm -f /out/upgrade.sh /out/caldera-music.service /out/caldera-music

# --- runtime stage ----------------------------------------------------------
FROM debian:trixie-slim

# libasound2 is the t64 package in trixie. FFmpeg ships inside the tarball, so
# ALSA plus the C++ runtime is the whole dependency list -- the binary needs at
# most GLIBC 2.30, well under trixie's.
#
# passwd (useradd/groupadd/usermod) and util-linux (setpriv) back the PUID/PGID
# privilege drop in the entrypoint. Both are priority:required in Debian and so
# are already in the base image; naming them makes the dependency explicit and
# survives a future slimming of that base.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libasound2t64 \
        libstdc++6 \
        passwd \
        util-linux \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /out /opt/caldera-music
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENV LD_LIBRARY_PATH=/opt/caldera-music/lib \
    CALDERA_CONFIG=/config

VOLUME /config

# 32500/tcp Plex Companion (control), 9999/udp xita multi-room audio.
EXPOSE 32500
EXPOSE 9999/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
