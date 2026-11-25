# fushi_server in Docker

Run the headless Fushi server (library, sync, streaming, dictionaries, review,
downloads, WebUI) in a container. Commands below run from this directory
(`packages/fushi_server/docker`). 中文说明见 [../README.md](../README.md#docker)。

## First run

1. **Settings.** Copy the example file and edit it:

   ```bash
   cp .env.example .env
   ```

   | Setting | What to put |
   |---|---|
   | `PUID` / `PGID` | Your user on the host (`id -u`, `id -g`). The container runs as this user, never as root. |
   | `FUSHI_CONFIG_DIR` | Where config, database and logs live (default `./config`). Back this up. |
   | `FUSHI_MEDIA_DIR` | Your media folder; inside the container it is `/media`. |
   | `FUSHI_LANGUAGE` | `en` or `zh`: WebUI, CLI and log language on the first start. |
   | `FUSHI_SYNC_PORT` / `FUSHI_WEBUI_PORT` / `FUSHI_TORRENT_PORT` | Host ports, if the defaults (38765 / 38780 / 6881) are taken. |
   | `TZ` | Your time zone, e.g. `Europe/Berlin`. |

2. **Start.** Create the folders first as your own user. If Docker creates a
   missing folder, root owns it and the server cannot write there.

   ```bash
   mkdir -p config media      # or the folders you set in .env
   docker compose up -d --build
   ```

   This builds the server from this checkout. The first build takes a while
   (30+ minutes: a Linux toolchain image, then libtorrent and the native
   libraries) and needs about 15 GB of disk. Later builds reuse the BuildKit
   cache and only redo what changed.

3. **Admin token.** The first start creates the config and prints a WebUI token:

   ```bash
   docker compose logs fushi-server | grep admin_token
   ```

   It is also the `admin_token:` line in `fushi_server.yaml` in your config
   folder. To make a new one (the server must be stopped for this):

   ```bash
   docker compose stop fushi-server
   docker compose run --rm fushi-server admin reset-token
   docker compose start fushi-server
   ```

4. **WebUI.** Open `https://<host>:38780/` and sign in with the token. The
   certificate is self-signed, so the browser warns once.

5. **Pair a device.** In Fushi: Settings → Interconnect → add device → enter
   `<host>:38765` (or your `FUSHI_SYNC_PORT`). A 6-digit PIN appears on the WebUI
   Pairing page and in the log; type it into the app. The container does not
   show up in the app's LAN list (no mDNS from Docker), so always enter the address.

   **Pair links / QR codes:** WebUI → Pairing → "Create pairing link" skips the PIN.
   In bridge mode the server only sees its container address (`172.x.x.x`), which
   phones cannot reach. First add the address phones use under WebUI → Settings →
   Remote access → Public addresses, e.g. `https://192.168.1.20:38765` (your host and
   `FUSHI_SYNC_PORT`). It takes effect on save, and paired devices learn it too.

6. **Add a library.** WebUI → Libraries → add a path under `/media`, e.g.
   `/media/anime` with type `video`, then Status → Scan.

## Updating

```bash
git pull
docker compose up -d --build
```

The database schema only moves forward: once a newer server has opened your
data, an older image refuses it. Back up first (copy `FUSHI_CONFIG_DIR` with the
container stopped, or `docker compose exec fushi-server fushi_server ctl backup create`). The in-app remote update
is turned off inside the container; update the image instead.

## Two ways to build, plus prebuilt images

| | Command | Good for |
|---|---|---|
| **Source** (default) | `docker compose up -d --build` | The newest code from this checkout. Slow first build. |
| **Release bundle** | `docker compose -f docker-compose.bundle.yml up -d --build` | Packaging a published [fushi-server release](https://github.com/hajisensai/fushi-server/releases) in about a minute. Only as new as the latest release. `FUSHI_SERVER_TAG` pins one; a `fushi_server-*-linux-x64.tar.gz` in `dist/` is used instead of downloading. |
| **Prebuilt** | `FUSHI_IMAGE=ghcr.io/hajisensai/fushi-server:latest` in `.env`, then `docker compose up -d` (no `--build`) | Published automatically with every [fushi-server release](https://github.com/hajisensai/fushi-server/releases); see the tags below. |

Prebuilt image tags (same channels and version numbers as the Fushi app):

| Tag | Channel | Moves when |
|---|---|---|
| `latest`, `<x.y.z>`, `<x.y>`, `<x>` | formal | a Fushi release is published |
| `beta`, `<x.y.z>-beta.<seq>` | beta | a Fushi beta is published |
| `debug`, `debug-<seq>` | debug | `develop` changes something the server ships (checked every 30 minutes) |

Pin a full version (`3.4.0`, `3.4.0-beta.24500`, `debug-24510`) to stay put; a
channel tag follows its channel. `beta` and `debug` builds are prereleases.

Both builds give the same container: same settings, volumes and ports. The
source build runs `packages/fushi_server/tool/build_linux_bundle.sh`, the same
script the Linux release bundle is built with.

Images are **linux/amd64 only**: the release bundles and the native libraries
(libtorrent, the Rust cores, fushidicts, onnxruntime) are built for x64 only,
so there is no arm64 image (Raspberry Pi, ARM NAS) yet.

## Settings that matter later

- **Language.** `FUSHI_LANGUAGE` only applies to the first start. Change it later
  in WebUI → Settings → Language. A one-off CLI command in the other language:
  `docker compose exec fushi-server env FUSHI_CLI_LANGUAGE=zh fushi_server ctl status`.
- **Permissions.** The container runs as `PUID:PGID` from the start and never
  changes file ownership. The config folder must be writable by that user, media
  folders readable (writable for upload targets). If the config folder is not
  writable, the log says so and shows the `chown` command to fix it.
- **API keys.** `FUSHI_*` keys in `.env` (OpenSubtitles, SubDL, Jimaku, AniDB,
  Bangumi, Plex) take precedence over keys saved in the server. `.env` is
  git-ignored; never put keys in a Dockerfile.
- **Host networking** (Linux hosts only): uncomment `network_mode: host` in
  `docker-compose.yml` and remove `ports:`. Still no mDNS; pair by address.
- **CLI.** Any server command runs inside the container as `PUID`:
  `docker compose exec fushi-server fushi_server ctl status`.

## NAS

- **Unraid:** [`unraid/fushi-server.xml`](unraid/fushi-server.xml) is a template
  for a prebuilt image (Docker → Add Container → Template). It runs as
  `nobody:users` (99:100, set in Extra Parameters). Until prebuilt images
  exist, use the Compose Manager plugin with this folder.
- **Synology (Container Manager):** Project → Create → choose this folder as the
  path; it picks up `docker-compose.yml`. Set `PUID`/`PGID` to your DSM user
  (`id` over SSH), and point `FUSHI_CONFIG_DIR` / `FUSHI_MEDIA_DIR` at shared
  folders, e.g. `/volume1/docker/fushi-server` and `/volume1/video`. Check that
  ports 38765, 38780 and 6881 are free (e.g. Download Station settings).
- **TrueNAS SCALE:** Apps → Discover → Custom App (or Install via YAML with this
  compose file). Use host-path storage for `/config` and `/media`, run as the
  dataset owner's UID/GID through `PUID`/`PGID`, and keep the container ports
  38765, 38780 and 6881.

On any NAS the source build needs the disk space and patience above; the release
bundle or a prebuilt image is lighter.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port is already allocated` | Another program (often a desktop Fushi) uses 38765 / 38780. Set `FUSHI_SYNC_PORT` / `FUSHI_WEBUI_PORT` and pair with the new port. |
| `/config is not writable by uid …` | The config folder belongs to another user (often root, when Docker created it). Run `sudo chown -R <PUID>:<PGID> <config folder>`, or set `PUID`/`PGID` in `.env` to the folder's owner, then `docker compose up -d`. |
| Container `unhealthy` | `docker compose logs fushi-server`. The health check calls `https://127.0.0.1:38765/api/ping` inside the container. |
| Release-bundle build fails in `check_bundle_libs.sh` | The tarball needs a newer glibc than Debian trixie has (CI `linux-server` artifacts are built on a newer Ubuntu). Use a `release-server.yml` release or the source build. |
| Database refused after going back to an older image | Expected (no downgrade). Restore the backup taken before updating. |
