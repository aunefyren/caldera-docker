# caldera-docker

Dockerfile and pre-built images for [Caldera Music headless](https://caldera.homes/music/headless/) - a Plex-powered music daemon for Linux.

This repository is a fork of [`anatosun/plexamp-docker`](https://github.com/anatosun/plexamp-docker), rebuilt for Caldera Music, which replaced Plexamp headless.

## Architectures

| Architecture | Available | Tag                     |
| :----------: | :-------: | ----------------------- |
|  Multi-arch  |    ✅     | latest, \<version tag\> |
|    x86-64    |    ✅     | amd64-\<version tag\>   |
|    arm64     |    ✅     | arm64v8-\<version tag\> |
|    arm32     |    ✅     | arm32v7-\<version tag\> |

The `latest` and version tags are multi-architecture manifests that automatically select the appropriate image for your platform.

## Authentication

Caldera does **not** use Plex claim tokens. It authenticates with a Plex auth
token, which does not expire in four minutes - so unlike the old Plexamp image,
a slow first pull can no longer cause a failed start.

Authenticate once, interactively. The token is written to your config volume and
reused on every subsequent start:

```bash
docker run --rm -it \
  -v ./config:/config \
  ghcr.io/aunefyren/caldera-music:latest --login --player-name "Living Room"
```

This prints a QR code plus a short code to enter at
[plex.tv/link](https://plex.tv/link); you have 15 minutes to complete it. The
`-it` flags matter, since without a TTY you cannot see the code. Once it
completes, start the container normally, with no `CALDERA_TOKEN` set.

If you already have a Plex auth token, skip the interactive step and set
`CALDERA_TOKEN` instead (see below).

## Compose file

```yaml
services:
  caldera-music:
    container_name: caldera-music
    image: ghcr.io/aunefyren/caldera-music:latest
    devices:
      - "/dev/snd:/dev/snd"
    volumes:
      - ./config:/config
    environment:
      - CALDERA_PLAYER_NAME=Living Room
      # Only needed if you did not authenticate with --login above:
      # - CALDERA_TOKEN=xxxxxxxxxxxxxxxxxxxx
    ports:
      - 32500:32500
      - 9999:9999/udp
    restart: unless-stopped
```

Control playback by casting from Plexamp, Plex iOS, or the Plex web app - the
daemon appears as a Plex player on your network.

## Environment variables

| Variable               | Description                                                                      |
| ---------------------- | -------------------------------------------------------------------------------- |
| `CALDERA_TOKEN`        | Plex auth token. Optional once a token is saved in the config volume.              |
| `CALDERA_PLAYER_NAME`  | Name shown in the Plex remote UI. Defaults to `Caldera Music (<hostname>)`.        |
| `CALDERA_DEVICE`       | ALSA output device UID. List them with `--list-devices` (below).                   |
| `CALDERA_EXTRA_ARGS`   | Extra flags passed verbatim, e.g. `--sample-rate 96000 --verbose`.                 |
| `CALDERA_CONFIG`       | Config directory inside the container. Defaults to `/config`.                      |
| `PUID`                 | User id to run the daemon as. Unset means root. See below.                         |
| `PGID`                 | Group id to run the daemon as. Unset means root. See below.                        |

Any arguments passed to the container are forwarded to the daemon instead of
starting it, which is how one-off commands work:

```bash
docker run --rm --device /dev/snd ghcr.io/aunefyren/caldera-music:latest --list-devices
```

## Running as a non-root user

By default the container runs as root, which is what this image has always
done. Set `PUID` and `PGID` to run the daemon as an ordinary user instead:

```yaml
    environment:
      - PUID=1000
      - PGID=1000
```

The entrypoint creates (or adopts) that uid/gid, hands it ownership of the
config volume, and then drops privileges before starting the daemon.

Audio keeps working: the entrypoint reads the group of each node under
`/dev/snd`, recreates those groups inside the container, and joins them. That
is the part people usually have to solve by hand with `group_add`, because a
host audio gid normally has no counterpart in the container.

Notes:

- Both default to `0` if only one is given, so set them together.
- `PUID=0` / `PGID=0` explicitly keeps root.
- The recursive `chown` of the config volume is skipped when ownership already
  matches, so a large warm cache is not re-walked on every restart.

## Ports

| Port        | Purpose                                        |
| ----------- | ---------------------------------------------- |
| `32500/tcp` | Plex Companion - remote control                 |
| `9999/udp`  | xita - multi-room audio between Caldera nodes   |

## Remarks

- **Multi-room sync needs multicast.** Caldera nodes discover each other over
  multicast, which does not cross Docker's default bridge network. If you want
  several nodes to stay in lock-step, add `network_mode: host` and remove the
  port bindings. A single standalone player works fine on the default bridge.
- **Audio requires access to the host sound device.** Map `/dev/snd` as shown.
  Running as root, that is enough. Running with `PUID`/`PGID`, the entrypoint
  joins the host's sound groups for you, so `group_add` should not be needed;
  `privileged: true` remains the blunt fallback if a setup still refuses.
- **Auto-updates are disabled in this image, deliberately.** Upstream, the
  daemon updates itself in place; in a container those writes land in the
  ephemeral layer, vanish on recreate, and get re-downloaded after every
  release. The image is the source of truth instead, and it is rebuilt
  automatically whenever upstream publishes a new version.

## Building

```bash
docker build -t caldera-music .
```

Upstream publishes only a rolling `latest/` path - no versioned URLs and no
checksums - so the build verifies instead of trusting: it downloads, then
compares the version inside the tarball against `version.json` and **fails on a
mismatch**. The image is therefore either exactly the version it advertises, or
it does not build.

If upstream has moved ahead of `version.json`, either bump that file or name the
version explicitly:

```bash
docker build --build-arg CALDERA_VERSION=1.0.47 -t caldera-music .
# or accept whatever upstream is currently serving:
docker build --build-arg CALDERA_VERSION=latest -t caldera-music .
```

## Trademark notice

Caldera Music is a product of Caldera Homes, LLC. Plex is a trademark of Plex,
Inc. This project is an unofficial Docker image and is not affiliated with,
endorsed by, or sponsored by either.
