# Hardening a compose file

This page shows the compose settings that limit what a container can do if something inside it goes wrong. It also shows how to keep passwords and tokens out of your compose file. It is for anyone who runs a cplieger image and wants more than the example compose file in its README.

## The hardened example

This file runs knell with every setting on this page. knell is small, reads two secrets from files and runs as a non-root user, so each setting is visible in a few lines. The values are knell's own. Other images need other users, folders and rights, so read an image's `docs/hardening.md` page before you copy a setting to it. [Which user the container runs as](#which-user-the-container-runs-as) links the page of every image.

<!-- include: examples/hardening/compose.yaml -->

```yaml
# knell with every hardening option from docs/hardening.md. The values are knell's own.
# Before you copy one to another image, read that image's docs/hardening.md.
services:
  knell:
    image: ghcr.io/cplieger/knell:latest
    container_name: knell
    restart: unless-stopped

    read_only: true  # nothing in the image can be changed while it runs. knell writes no file, so it needs no tmpfs
    cap_drop: [ALL]  # knell needs no Linux capabilities
    security_opt:
      - "no-new-privileges:true"  # no program inside can gain more rights than it started with
    user: "65534:65534"  # the user the image already runs as, written down so it cannot change
    mem_limit: 64m
    pids_limit: 64
    cpus: 0.5

    environment:
      BEATS: "nightly-backup:26h"  # one id:deadline pair per job you watch
      NODE_NAME: "server-1"
      BEAT_TOKEN_FILE: "/run/secrets/beat_token"  # knell reads the token from this file
      DISCORD_WEBHOOK_URL_FILE: "/run/secrets/discord_webhook_url"
    secrets:
      - beat_token
      - discord_webhook_url

    ports:
      - "127.0.0.1:9190:9190"  # this host only, see docs/hardening.md "Ports"

secrets:
  # Create both files before the first start. Then run "chmod 600 secrets/*" and
  # "sudo chown 65534:65534 secrets/*", so only knell's user can read them.
  beat_token:
    file: ./secrets/beat_token
  discord_webhook_url:
    file: ./secrets/discord_webhook_url
```

<!-- /include -->

To run it:

1. Create a `secrets` folder next to `compose.yaml`.
2. Run `openssl rand -hex 16 > secrets/beat_token` to make a token.
3. Put your Discord webhook address in `secrets/discord_webhook_url`, on one line.
4. Run `chmod 600 secrets/*`, then `sudo chown 65534:65534 secrets/*`. knell runs as user 65534, so it can read both files and no other account on the host can, apart from root. To change a file later, edit it with `sudo`.
5. Run `docker compose up -d`, then `docker compose ps`. The container should show `healthy` within a minute.

The port is published to this host only. If backup jobs on other machines send beats to knell, publish it on an address those machines reach instead, as [Ports](#ports) explains.

## Secrets in files

Anyone who can run `docker inspect` on the container sees every value set under `environment:`. The values also end up in every copy or backup of your compose file. A Docker secret keeps it in a separate file instead. Compose mounts each file listed under `secrets:` into the container at `/run/secrets/<name>`, read-only, as [Docker's secrets guide](https://docs.docker.com/compose/how-tos/use-secrets/) describes.

Some images read a secret from such a file when you append `_FILE` to the variable's name and set it to the path. knell reads `BEAT_TOKEN_FILE` instead of `BEAT_TOKEN`. When both are set, the `_FILE` variable wins. The app reads the file once, when it starts, and removes one trailing line break. The file can hold up to 1 MiB, and its path must be a plain path with no `..` in it. The app's README lists which of its variables accept `_FILE`.

| Image | Variables that accept `_FILE` |
| --- | --- |
| cert-converter | `PFX_PASSWORD`, `INPUT_PFX_PASSWORD` |
| knell | `BEAT_TOKEN`, `DISCORD_WEBHOOK_URL` |
| plex-exporter | `PLEX_TOKEN` |
| plex-language-sync | `PLEX_URL`, `PLEX_TOKEN` |
| tautulli-remap | `TAUTULLI_API_KEY`, `PLEX_TOKEN` |

plex-language-sync also removes spaces and line breaks around `PLEX_URL` and `PLEX_TOKEN`, from the file or the variable, and refuses a blank value.

Other images take secrets differently. subflux, seadex-scout and forge-scout read a YAML config file, which can refer to an environment variable with `${NAME}`. That works only for names the app allows, and any other name stays in the config as written.

The allowed names start with `SUBFLUX_` for subflux, and with `SONARR_`, `RADARR_` or `SEADEX_SCOUT_` for seadex-scout. For forge-scout, they start with `FORGE_SCOUT_` or end in `_TOKEN`, and each forge token must be one such reference, such as `token: ${GITHUB_TOKEN}`.

web-terminal-server's `AUTH_PASSWORD` and docker-smtp-relay's `RELAY_PASSWORD` are plain environment variables. For those, keep the value in an `.env` file next to `compose.yaml` that only you can read, with `chmod 600 .env`, and refer to it as `"${NAME}"`. The value still shows in `docker inspect`, but it stays out of the compose file and its copies.

The mounted file keeps the owner and permissions it has on your host. An image that runs as a non-root user can read the file only if that user may read it. Give the file to the image's user with `sudo chown`, and make it readable by its owner only with `chmod 600`. Mode 644 also works, but then every account on the host can read the secret.

## Read-only filesystem

`read_only: true` mounts the container's own files read-only, so nothing that runs inside can change the program or plant a file for the next start. Folders you mount with `volumes:` stay writable.

The cplieger Go images keep their health verdict in memory, so their health check needs no folder you add. An image that opens no port also copies that verdict to a file, `/dev/shm/<app>.healthy`, which its Docker healthcheck reads. Docker gives every container a writable `/dev/shm` in memory, also under `read_only: true`, so you add no `tmpfs` for health. knell writes no file at all, so the example has no `tmpfs` line.

Folders an image keeps its data in, such as cert-converter's `/output`, pg-autodump's `/dumps` and docker-fclones-scheduler's `/cache`, are already mounts in the compose file of its README, so they stay writable. Some images also write files outside their mounts. Each of these needs a `tmpfs`, a folder kept in memory that disappears when the container stops:

| Image | What it writes there | The `tmpfs` it needs |
| --- | --- | --- |
| [docker-fclones-scheduler](https://github.com/cplieger/docker-fclones-scheduler/blob/main/docs/hardening.md) | Its trigger socket and its home folder | `/tmp` |
| [pg-autodump](https://github.com/cplieger/pg-autodump/blob/main/docs/hardening.md) | The run lock that keeps two runs from overlapping | `/tmp` |
| [seadex-scout](https://github.com/cplieger/seadex-scout/blob/main/docs/hardening.md) | Its health marker, which this image still keeps in `/tmp` | `/tmp` |
| [tautulli-remap](https://github.com/cplieger/tautulli-remap/blob/main/docs/hardening.md) | The run lock that keeps two passes from running at once | `/tmp` |
| [web-terminal-server](https://github.com/cplieger/web-terminal-server/blob/main/docs/hardening.md) | The files of the programs its terminals run, and the shell's home folder | `/tmp` and `/root` |
| [docker-keepalived](https://github.com/cplieger/docker-keepalived/blob/main/docs/hardening.md) and [docker-radvd](https://github.com/cplieger/docker-radvd/blob/main/docs/hardening.md) | Their PID files | `/run` |

Under `read_only: true`, also mount a folder on docker-caddy's `/config`. Caddy saves a copy of each config it loads under `/config/caddy`, and without a mount it logs `unable to autosave config` at ERROR while it keeps serving.

Copy each `tmpfs` line from the image's page. It sets the folder's size and, where the image allows it, `noexec`, `nosuid` and `nodev`, which stop programs in the folder from running. If an image logs `read-only file system` after you add `read_only: true`, its `docs/hardening.md` names the folder it writes to.

Five images do not run with a read-only root, so run them without `read_only: true`. docker-renovate-scheduler installs the tools a repository needs into `/opt/containerbase` during a run. docker-nut-upsd writes its generated NUT configuration into `/etc/nut` at each start. docker-smtp-relay does the same with its Postfix configuration in `/etc/postfix`. web-terminal-kiro and marotte give you a shell whose programs write to `/tmp`, and web-terminal-kiro installs the Debian packages you list into the image's own folders. Neither image's page names a read-only setup yet.

## Capabilities

Linux splits root's powers into capabilities, such as binding a low port or changing file owners. Docker gives every container a default set. `cap_drop: [ALL]` removes all of them. A program that runs as a non-root user usually needs none. A program that runs as root keeps only what you add back with `cap_add`.

## No new privileges

`no-new-privileges:true` stops any program in the container from gaining more rights than it started with, for example through a setuid file. It costs nothing for an image that never switches users, which is most images. An image that starts as root and drops to another user can still do that under this setting, because dropping rights is allowed.

## Which user the container runs as

Each image sets the user it runs as. `user:` in the compose file overrides it. Set it to the image's own user to write that choice down, as the example does. Set it to your own user ID only when the image's README says it supports that. The usual reason is that files it writes to a mounted folder then belong to you.

| User | Images |
| --- | --- |
| 65532 | [cert-converter](https://github.com/cplieger/cert-converter/blob/main/docs/hardening.md), [docker-age](https://github.com/cplieger/docker-age/blob/main/docs/hardening.md), [docker-fclones-scheduler](https://github.com/cplieger/docker-fclones-scheduler/blob/main/docs/hardening.md), [forge-scout](https://github.com/cplieger/forge-scout/blob/main/docs/hardening.md), [pg-autodump](https://github.com/cplieger/pg-autodump/blob/main/docs/hardening.md), [plex-exporter](https://github.com/cplieger/plex-exporter/blob/main/docs/hardening.md), [plex-language-sync](https://github.com/cplieger/plex-language-sync/blob/main/docs/hardening.md), [seadex-scout](https://github.com/cplieger/seadex-scout/blob/main/docs/hardening.md), [subflux](https://github.com/cplieger/subflux/blob/main/docs/hardening.md), [tautulli-remap](https://github.com/cplieger/tautulli-remap/blob/main/docs/hardening.md) |
| 65534 | [knell](https://github.com/cplieger/knell/blob/main/docs/hardening.md) |
| 12021 | [docker-renovate-scheduler](https://github.com/cplieger/docker-renovate-scheduler/blob/main/docs/hardening.md) |
| root | [docker-caddy](https://github.com/cplieger/docker-caddy/blob/main/docs/hardening.md), [docker-keepalived](https://github.com/cplieger/docker-keepalived/blob/main/docs/hardening.md), [docker-nut-upsd](https://github.com/cplieger/docker-nut-upsd/blob/main/docs/hardening.md), [docker-radvd](https://github.com/cplieger/docker-radvd/blob/main/docs/hardening.md), [docker-smtp-relay](https://github.com/cplieger/docker-smtp-relay/blob/main/docs/hardening.md), [marotte](https://github.com/cplieger/marotte/blob/main/docs/hardening.md), [web-terminal-kiro](https://github.com/cplieger/web-terminal-kiro/blob/main/docs/hardening.md), [web-terminal-server](https://github.com/cplieger/web-terminal-server/blob/main/docs/hardening.md) |

Each name links to the image's `docs/hardening.md` page, which gives the profile it supports. The root images need root for their job, such as managing network interfaces, reaching USB devices, or giving a terminal full access. Their pages say what each one does as root.

## Resource limits

Limits stop one container from starving the rest of the host:

- `mem_limit` caps memory. When the container goes over it, the kernel stops the largest process inside, and Docker restarts the container if its restart policy says so.
- `pids_limit` caps the number of processes, which stops a runaway loop from filling the host's process table.
- `cpus` caps how much processor time it gets, here half of one core.

Pick limits from what the container really uses. Run `docker stats` for a few days and add a margin. A limit that is too low shows up as restarts with exit code 137.

## Healthchecks

Every cplieger image has a healthcheck built in, so you need to add nothing. `docker compose ps` shows `healthy` or `unhealthy` for each container. To make one service wait until another is ready, use `depends_on:` with `condition: service_healthy`.

Docker's health status notifies nobody on its own, and Docker does not restart an unhealthy container. [Knowing that an app is alive](monitoring.md#knowing-that-an-app-is-alive) shows how to be told.

If an app needs longer to start on your data, change only the timing, such as `healthcheck:` with `start_period: 5m`. A `healthcheck:` block with no `test:` keeps the image's own check and changes only the timing.

## Ports

A published port is reachable from every network your host is on, unless you say otherwise. Publish only what something outside the host must reach:

- `"127.0.0.1:9190:9190"` publishes the port to the host itself only. Use it for a page you open on the host, or for a reverse proxy that runs directly on the host.
- Leave out `ports:` for an app that only a reverse proxy in the same compose file reaches. Containers on one compose network reach each other by service name with no published port. [Running an app behind a reverse proxy](reverse-proxy.md) shows this.
- `"9190:9190"` publishes the port on every address of the host. Use it only for a service other devices must reach directly, and keep it on a network you trust.

Each app listens on the port in this table. An app with `LISTEN_ADDR` listens by default, and the setting moves it, as in `LISTEN_ADDR=:9300`. An app with `METRICS_LISTEN_ADDR` opens no port until you set it, to the port its README suggests, such as `METRICS_LISTEN_ADDR=:9468`. That listener serves only `/metrics` and `/healthz`. No two apps share a port, so they run side by side on one host and one network.

| App | Port | The setting that changes it | What answers there |
| --- | --- | --- | --- |
| cert-converter | none, `9468` once set | `METRICS_LISTEN_ADDR` | `/metrics` and `/healthz` |
| docker-caddy | `80`, `443` and `443/udp` | your Caddyfile | Your sites. Metrics answer on `2020` only when your Caddyfile opens that listener, and the admin API on `2019` stays on the container's own loopback |
| docker-fclones-scheduler | none, `9469` once set | `METRICS_LISTEN_ADDR` | `/metrics` and `/healthz` |
| docker-nut-upsd | `3493` and `9199` | `API_PORT` and `METRICS_PORT`. `METRICS_PORT=0` turns off `9199` | NUT clients on `3493`, `/metrics` and `/healthz` on `9199` |
| docker-renovate-scheduler | none, `9470` once set | `METRICS_LISTEN_ADDR` | `/metrics` and `/healthz` |
| docker-smtp-relay | `25` | none | Mail from your apps |
| grelot | `9737` | none | The API, `/metrics` and `/healthz` |
| knell | `9190` | `LISTEN_ADDR` | Beats, `/metrics` and `/healthz` |
| marotte | `9847` | none | The web page and `/api/health` |
| pg-autodump | `9472` | `LISTEN_ADDR` | `POST /dump`, `/metrics` and `/healthz` |
| plex-exporter | `9594` | `LISTEN_ADDR` | `/metrics` and `/healthz` |
| plex-language-sync | none, `9471` once set | `METRICS_LISTEN_ADDR` | `/metrics` and `/healthz` |
| subflux | `8374` | none | The web page, `/metrics` and `/api/health` |
| web-terminal-kiro | `9848` | `LISTEN_ADDR` | The web page and `/healthz` |
| web-terminal-server | `7681` | `LISTEN_ADDR` | The web page and `/healthz` |

For an app with no setting, publish another host port instead, such as `"9300:9737"`. docker-age, docker-keepalived, docker-radvd, forge-scout and tautulli-remap open no port.

An app's `/metrics` page answers without a login. Let your scraper reach it on the `monitoring` network, as [Reaching an app's metrics page](monitoring.md#reaching-an-apps-metrics-page) shows, rather than through a published port.

## The Docker socket

Some tools mount `/var/run/docker.sock`, such as Alloy to read container logs and Traefik to read labels. A program that can reach the socket controls Docker, and through it the whole host. The `:ro` flag only stops writes to the socket file. It does not limit what the program can ask Docker to do. Mount the socket only into images you trust, as [Docker's security page](https://docs.docker.com/engine/security/) advises.

## When an image needs more

Some images do a job that needs extra rights, so they cannot run with every setting on this page as written. These are examples of what an image can need. The image's own page has its exact profile:

| Image | What it needs |
| --- | --- |
| [docker-keepalived](https://github.com/cplieger/docker-keepalived/blob/main/docs/hardening.md) | Host networking, `cap_add` of `NET_ADMIN` and `NET_RAW`, and a `tmpfs` at `/run` under `read_only` |
| [docker-radvd](https://github.com/cplieger/docker-radvd/blob/main/docs/hardening.md) | Host networking, `cap_add` of `NET_RAW`, `SETUID`, `SETGID` and `KILL` after `cap_drop: [ALL]`, and a `tmpfs` at `/run` |
| [docker-nut-upsd](https://github.com/cplieger/docker-nut-upsd/blob/main/docs/hardening.md) | The host's USB devices and their `device_cgroup_rules`. It starts as root and drops to its `nut` user |
| [docker-caddy](https://github.com/cplieger/docker-caddy/blob/main/docs/hardening.md) | Runs as root by default, like the official Caddy image. The page shows how to run it as another user |
| [docker-age](https://github.com/cplieger/docker-age/blob/main/docs/hardening.md) | When it runs as root, `cap_drop: [ALL]` stops it from writing to folders other users own. The page shows the profile for its default user |
| [docker-smtp-relay](https://github.com/cplieger/docker-smtp-relay/blob/main/docs/hardening.md) | Runs as root, because Postfix needs root to listen on port 25 and runs its workers as its own user. The page adds only `no-new-privileges` |
