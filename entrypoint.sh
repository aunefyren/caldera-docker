#!/bin/sh
# Entrypoint for the caldera-music daemon.
#
# Translates environment variables into flags, because the upstream install is
# built around an interactive `--login` and a systemd user unit, neither of
# which a container has. `--token` makes the whole thing non-interactive.
set -eu

BIN=/opt/caldera-music/bin/caldera-music
CONFIG_DIR="${CALDERA_CONFIG:-/config}"

mkdir -p "$CONFIG_DIR"

# Any explicit arguments win, so one-off maintenance commands still work:
#   docker run --rm -it -v ./config:/config <image> --login
#   docker run --rm --device /dev/snd <image> --list-devices
if [ "$#" -gt 0 ]; then
    exec "$BIN" --config "$CONFIG_DIR" "$@"
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

exec "$BIN" "$@"
