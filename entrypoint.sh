#!/bin/sh
# Entrypoint for the caldera-music daemon.
#
# Translates environment variables into flags, because the upstream install is
# built around an interactive `--login` and a systemd user unit, neither of
# which a container has. `--token` makes the whole thing non-interactive.
set -eu

BIN=/opt/caldera-music/bin/caldera-music
CONFIG_DIR="${CALDERA_CONFIG:-/config}"
APP_USER=caldera

# Set by setup_unprivileged_user() when PUID/PGID ask for a privilege drop.
PRIV_UID=""
PRIV_GID=""

die() { echo "error: $*" >&2; exit 1; }

is_uint() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Create (or adopt) the requested uid/gid, give it access to the sound devices,
# and hand ownership of the config volume over to it.
setup_unprivileged_user() {
    uid="$1"
    gid="$2"

    # Adopt whatever already holds these ids rather than creating a duplicate:
    # useradd refuses a repeated uid, and setpriv --init-groups needs a real
    # passwd entry to resolve supplementary groups from.
    grp="$(getent group "$gid" | cut -d: -f1)"
    if [ -z "$grp" ]; then
        groupadd -g "$gid" "$APP_USER"
        grp="$APP_USER"
    fi

    usr="$(getent passwd "$uid" | cut -d: -f1)"
    if [ -z "$usr" ]; then
        useradd -u "$uid" -g "$gid" -M -N -s /usr/sbin/nologin "$APP_USER"
        usr="$APP_USER"
    fi

    # ALSA nodes are group-owned on the host, and that gid normally has no
    # counterpart inside the container. Mirror each one and join it, otherwise
    # the daemon starts up perfectly and then cannot open any audio device --
    # which looks like a config problem rather than a permission one.
    for dev in /dev/snd/*; do
        [ -e "$dev" ] || continue
        dgid="$(stat -c %g "$dev")"
        dgrp="$(getent group "$dgid" | cut -d: -f1)"
        if [ -z "$dgrp" ]; then
            dgrp="snd$dgid"
            groupadd -g "$dgid" "$dgrp" 2>/dev/null || continue
        fi
        usermod -aG "$dgrp" "$usr"
    done

    # The daemon writes preferences.json and its audio cache here. Recursive
    # chown is skipped when the top-level owner already matches, so a large
    # warm cache is not re-walked on every restart.
    if [ "$(stat -c %u "$CONFIG_DIR")" != "$uid" ]; then
        chown -R "$uid:$gid" "$CONFIG_DIR"
    fi

    PRIV_UID="$uid"
    PRIV_GID="$gid"
}

# exec the daemon, dropping privileges first when asked to.
run() {
    if [ -n "$PRIV_UID" ]; then
        exec setpriv --reuid="$PRIV_UID" --regid="$PRIV_GID" --init-groups "$@"
    fi
    exec "$@"
}

mkdir -p "$CONFIG_DIR"

# PUID/PGID run the daemon as an ordinary user. Leaving both unset keeps the
# container running as root, which is what this image has always done, so an
# upgrade does not silently change ownership under anyone's config volume.
if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
    req_uid="${PUID:-0}"
    req_gid="${PGID:-0}"

    is_uint "$req_uid" || die "PUID must be a number, got '$req_uid'"
    is_uint "$req_gid" || die "PGID must be a number, got '$req_gid'"

    if [ "$(id -u)" -ne 0 ]; then
        echo "warning: PUID/PGID set but this container is not running as root;" >&2
        echo "         cannot switch user, continuing as $(id -u):$(id -g)" >&2
    elif [ "$req_uid" -eq 0 ] && [ "$req_gid" -eq 0 ]; then
        : # explicitly asked for root
    else
        setup_unprivileged_user "$req_uid" "$req_gid"
    fi
fi

# Any explicit arguments win, so one-off maintenance commands still work:
#   docker run --rm -it -v ./config:/config <image> --login
#   docker run --rm --device /dev/snd <image> --list-devices
if [ "$#" -gt 0 ]; then
    run "$BIN" --config "$CONFIG_DIR" "$@"
fi

set -- --config "$CONFIG_DIR"

if [ -n "${CALDERA_TOKEN:-}" ]; then
    set -- "$@" --token "$CALDERA_TOKEN"
fi

if [ -n "${CALDERA_PLAYER_NAME:-}" ]; then
    set -- "$@" --player-name "$CALDERA_PLAYER_NAME"
fi

if [ -n "${CALDERA_DEVICE:-}" ]; then
    set -- "$@" --device "$CALDERA_DEVICE"
fi

# Deliberately unquoted: this is an escape hatch for arbitrary extra flags
# (--sample-rate, --xita-port, ...) and needs to word-split.
if [ -n "${CALDERA_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    set -- "$@" $CALDERA_EXTRA_ARGS
fi

# With no token in the environment the daemon falls back to the one saved in
# its config. If neither exists it will sit there unauthenticated, which is a
# confusing way to fail, so say so plainly.
# Preferences are nested JSON ({"plex":{"token":"..."}}), so match a non-empty
# "token" value rather than the dot-path the CLI uses.
if [ -z "${CALDERA_TOKEN:-}" ] \
   && ! grep -qs '"token"[[:space:]]*:[[:space:]]*"[^"]\+"' "$CONFIG_DIR/preferences.json"; then
    echo "warning: no CALDERA_TOKEN set and no saved token in $CONFIG_DIR" >&2
    echo "         authenticate once with: docker run --rm -it -v <config>:/config <image> --login" >&2
fi

run "$BIN" "$@"
