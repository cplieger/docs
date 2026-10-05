# Running an app behind a reverse proxy

This page shows how to put a cplieger app that answers over HTTP behind Caddy, nginx, Traefik or Nginx Proxy Manager, with HTTPS. It lists the settings each app needs. It is for anyone who wants to open an app at an address like `https://app.example.com` instead of a port number.

## What the apps expect from a proxy

A reverse proxy receives the visitor's request on ports 80 and 443 and passes it to the app. Every example on this page passes these, and a test checks each one:

- WebSocket connections, which terminal and shell pages use. The proxy must pass the `Upgrade` request through and keep a quiet connection open.
- Live updates, sent as server-sent events, a response that stays open and delivers one message at a time. The proxy must pass each message on at once instead of collecting the whole response first.
- The original `Host` header. Apps compare it with their `ALLOWED_HOSTS` list and refuse other names.
- `X-Forwarded-For` and `X-Forwarded-Proto`, which tell the app the visitor's address and whether the visitor used HTTPS.
- Requests as large as the app accepts, such as a file upload, even when one takes minutes to arrive.

| App | Port | Login | WebSocket | Live updates | Largest request body |
| --- | --- | --- | --- | --- | --- |
| web-terminal-server | 7681 | `AUTH_PASSWORD` | `/ws` | `/api/sessions/events` | 64 KiB |
| web-terminal-kiro | 9848 | none | `/ws` | `/api/sessions/events` | 64 KiB |
| marotte | 9847 | none | `/api/shell/ws` | `/api/events` | 256 MiB, for a file upload |
| subflux | 8374 | its own login page | none | `/api/events` | 1 MiB |
| knell | 9190 | `BEAT_TOKEN` for beats | none | none | none, a beat's body is ignored |

The apps already ask a proxy not to collect their live updates, with the `X-Accel-Buffering: no` header. They also send a keep-alive message at regular intervals. Both nginx and Nginx Proxy Manager honor that header. The examples still turn off collecting in the proxy, and keep a quiet connection open longer. The metrics apps plex-exporter and registry-stats, and seadex-scout's feed, need no proxy. They serve plain HTTP to a scraper or to Sonarr and Radarr on your network.

marotte and web-terminal-kiro have no login of their own. Anyone who reaches them can use the agent or a root shell on your files. The examples on this page add no login, so use them for these two only after you add a login to the proxy. The security pages of [marotte](https://github.com/cplieger/marotte/blob/main/docs/hardening.md#who-can-reach-it) and [web-terminal-kiro](https://github.com/cplieger/web-terminal-kiro/blob/main/docs/hardening.md#behind-a-reverse-proxy) explain how.

All examples on this page put web-terminal-server at `app.example.com`. Change that name to your own in every file, and the app to another one from the table. Each compose file defines a network with a fixed address for the proxy, `172.30.0.2`, which [Telling the app about the proxy](#telling-the-app-about-the-proxy) explains. Put `AUTH_PASSWORD=<a long password>` in an `.env` file next to `compose.yaml`, which is the password web-terminal-server asks for. Then run `docker compose up -d`.

## Give each app its own subdomain

Serve each app at the root of its own name, such as `term.example.com` and `subs.example.com`, never under a path such as `example.com/term`. The apps have no setting for a path prefix. Their pages ask for `/ws`, `/api/...` and their files at the root of the name, so under a path they break.

One name per app also keeps each app's page and its WebSocket on one origin. The terminal apps accept a WebSocket only from a page on the same name as the request. A single proxied name per app is what makes them work.

Passkeys, in subflux, need three more things:

- HTTPS. A browser offers passkeys only over HTTPS, or on `localhost`.
- A name with a domain, such as `subs.example.com`. An IP address or a one-word name such as `nas` cannot use passkeys. `localhost` is the one exception.
- A domain that stays the same. subflux takes the passkey domain from the address you first save its settings from, so `subs.example.com` gives `example.com`. Passkeys then keep working under any name in that domain. If you move subflux to another domain, they stop working and you register them again.

subflux's [passkey page](https://github.com/cplieger/subflux/blob/main/docs/hardening.md#passkeys-and-domain-scope) explains the domain and how to narrow it to one name.

## Caddy

Caddy passes WebSockets, live updates and the original `Host` without extra settings, and sets no limit on request size. It gets and renews a free certificate from [letsencrypt.org](https://letsencrypt.org) by itself. For that, your DNS name must point to the host, and ports 80 and 443 must be open to the internet. The [`reverse_proxy` documentation](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) lists its defaults.

If the name is only on your home network, add `tls internal` inside the site block. Caddy then makes its own certificate, which each browser must trust once, as the [`tls` documentation](https://caddyserver.com/docs/caddyfile/directives/tls) explains. For the other proxies, a certificate from a DNS challenge needs no open port. Certbot, Traefik and Nginx Proxy Manager each support one.

`Caddyfile`:

<!-- include: examples/reverse-proxy/caddy/Caddyfile -->

```caddyfile
# Serves web-terminal-server at https://app.example.com. Caddy gets the certificate by itself.
# WebSockets, live updates and the forwarded headers need no extra lines.
app.example.com {
	reverse_proxy web-terminal-server:7681
}
```

<!-- /include -->

`compose.yaml`:

<!-- include: examples/reverse-proxy/caddy/compose.yaml -->

```yaml
# web-terminal-server behind Caddy. See docs/reverse-proxy.md.
services:
  caddy:
    image: caddy:2.11.6
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"  # needed to get and renew the certificate
      - "443:443"
      - "443:443/udp"
    volumes:
      - "./Caddyfile:/etc/caddy/Caddyfile:ro"
      - "caddy-data:/data"  # keeps the certificates
      - "caddy-config:/config"
    networks:
      proxy:
        ipv4_address: "172.30.0.2"  # a fixed address, so the app can trust it

  web-terminal-server:
    image: ghcr.io/cplieger/web-terminal-server:latest
    container_name: web-terminal-server
    restart: unless-stopped
    init: true
    environment:
      AUTH_PASSWORD: "${AUTH_PASSWORD:?put AUTH_PASSWORD=<a long password> in .env}"
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    networks:
      - proxy  # no ports line, so only the proxy can reach the app

networks:
  proxy:
    name: proxy  # a fixed name, so an app's own compose file can join this network
    ipam:
      config:
        - subnet: "172.30.0.0/24"  # pick another range if a network on this host already uses it
          ip_range: "172.30.0.128/25"  # Docker gives other containers addresses from here

volumes:
  caddy-data:
  caddy-config:
```

<!-- /include -->

## nginx

nginx needs every setting written out. By default it closes a quiet connection after 60 seconds and refuses requests over 1 MiB. It also collects responses before passing them on, and sends the name from `proxy_pass` instead of the visitor's `Host`. The [proxy module documentation](https://nginx.org/en/docs/http/ngx_http_proxy_module.html) and the [WebSocket page](https://nginx.org/en/docs/http/websocket.html) describe each setting.

Put your certificate as `certs/fullchain.pem` and its key as `certs/privkey.pem`. Get them first with Certbot, as [Renewing the certificate for nginx](#renewing-the-certificate-for-nginx) shows, then start nginx.

`app.conf`:

<!-- include: examples/reverse-proxy/nginx/app.conf -->

```nginx
# Serves web-terminal-server at https://app.example.com. Put your certificate in the certs folder.

# Docker's own name server. nginx asks it for the app's address again every 10 seconds,
# so it still reaches the app after an update gives the app a new address.
resolver 127.0.0.11 valid=10s;

upstream web_terminal {
    zone web_terminal 64k;
    server web-terminal-server:7681 resolve;
}

# Logs the path without the query string. The terminal apps put a session id in the
# query of /ws, and anyone who reads that id from a log can open the terminal.
log_format no_query '$remote_addr [$time_local] "$request_method $uri $server_protocol" $status $body_bytes_sent "$http_user_agent"';

# Passes the WebSocket upgrade through, and closes other connections normally.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;
}

server {
    listen 80;
    server_name app.example.com;
    access_log /var/log/nginx/access.log no_query;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name app.example.com;
    access_log /var/log/nginx/access.log no_query;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    client_max_body_size 300m;  # nginx refuses bodies over 1 MiB unless told otherwise

    location / {
        proxy_pass http://web_terminal;
        proxy_http_version 1.1;

        proxy_set_header Host $host;  # the app checks this name against ALLOWED_HOSTS
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_buffering off;  # sends live updates as they happen
        proxy_read_timeout 1h;  # keeps a quiet WebSocket open, the default closes it after 60 seconds
        proxy_send_timeout 1h;
    }
}
```

<!-- /include -->

`client_max_body_size 300m` covers marotte's 256 MiB uploads. For an app with a smaller limit, you can lower it to that limit.

The `no_query` log format leaves the query string out of nginx's access log. web-terminal-server and web-terminal-kiro put a session id in the address of each terminal connection, as `/ws?session=<id>`. Anyone who reads that id from a log can open the terminal. Caddy and Traefik write no access log unless you turn one on.

nginx normally looks up the app's address once, when it starts. An update recreates the app container, and Docker can give it a new address. The `resolver` and `upstream` lines make nginx look the address up again every 10 seconds, so it keeps reaching the app after an update.

`compose.yaml`:

<!-- include: examples/reverse-proxy/nginx/compose.yaml -->

```yaml
# web-terminal-server behind nginx. See docs/reverse-proxy.md.
services:
  nginx:
    image: nginx:1.31.6
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "./app.conf:/etc/nginx/conf.d/app.conf:ro"
      - "./certs:/etc/nginx/certs:ro"  # fullchain.pem and privkey.pem for app.example.com
    networks:
      proxy:
        ipv4_address: "172.30.0.2"  # a fixed address, so the app can trust it

  web-terminal-server:
    image: ghcr.io/cplieger/web-terminal-server:latest
    container_name: web-terminal-server
    restart: unless-stopped
    init: true
    environment:
      AUTH_PASSWORD: "${AUTH_PASSWORD:?put AUTH_PASSWORD=<a long password> in .env}"
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    networks:
      - proxy  # no ports line, so only the proxy can reach the app

networks:
  proxy:
    name: proxy  # a fixed name, so an app's own compose file can join this network
    ipam:
      config:
        - subnet: "172.30.0.0/24"  # pick another range if a network on this host already uses it
          ip_range: "172.30.0.128/25"  # Docker gives other containers addresses from here
```

<!-- /include -->

### Renewing the certificate for nginx

Caddy, Traefik and Nginx Proxy Manager renew their certificates by themselves. nginx does not, and it reads the certificate only when it starts or reloads. [Certbot](https://certbot.eff.org) on the host can get and renew it. Use a [Certbot DNS plugin](https://eff-certbot.readthedocs.io/en/stable/using.html#dns-plugins) for your DNS provider, because this example sends every request on port 80 to HTTPS, where Certbot cannot answer.

`renew-hook.sh` copies each new certificate into `certs` and reloads nginx:

<!-- include: examples/reverse-proxy/nginx/renew-hook.sh -->

```sh
#!/usr/bin/env bash
# Certbot runs this each time it gets or renews the certificate, when you pass it with --deploy-hook.
# It copies the new files into the certs folder next to this script, then tells nginx to load them.
set -euo pipefail

certs="$(dirname "$(readlink -f "$0")")/certs"
mkdir -p "$certs"
# Certbot's live folder holds links into its archive folder. cp -L copies the files they point to.
cp -L "$RENEWED_LINEAGE/fullchain.pem" "$certs/fullchain.pem"
cp -L "$RENEWED_LINEAGE/privkey.pem" "$certs/privkey.pem"
chmod 600 "$certs/privkey.pem"

# nginx reads the certificate only when it starts or reloads. A stopped or missing
# nginx container reads the new files when it starts. A Docker error stops the hook,
# so Certbot reports it.
state="$(docker container ls --all --filter 'name=^nginx$' --format '{{.State}}')"
if [ "$state" = running ]; then
  docker exec nginx nginx -s reload
fi
```

<!-- /include -->

Run `chmod +x renew-hook.sh`, because Certbot runs it as a program. Then add `--deploy-hook` with the full path of the script to the Certbot command that gets the certificate, such as `--deploy-hook /home/you/proxy/renew-hook.sh`. Certbot runs it after the first certificate and after every renewal. If nginx is not running, the script only copies the files, and nginx loads them when it starts.

## Traefik

Traefik reads each app's route from the labels on its service, so `traefik.yaml` holds only Traefik's own settings. It passes WebSockets, live updates and the original `Host` without extra settings, and sets no limit on request size. By default it does stop reading a request after 60 seconds. That would cut off a large upload on a slow link, so `traefik.yaml` turns the limit off.

Traefik gets a free certificate from [letsencrypt.org](https://letsencrypt.org) for every route that names the `letsencrypt` resolver. As with Caddy, your DNS name must point to the host, and port 443 must be open to the internet. Change the email address in `traefik.yaml` to your own first, because the certificate service refuses `example.com` addresses. The [Docker provider documentation](https://doc.traefik.io/traefik/providers/docker/) lists the labels. Traefik reads them through the Docker socket, which gives it control of Docker, as [The Docker socket](hardening.md#the-docker-socket) explains.

`traefik.yaml`:

<!-- include: examples/reverse-proxy/traefik/traefik.yaml -->

```yaml
# Traefik's own settings. Each app's route lives in the labels of its service in compose.yaml.
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        # Traefik stops reading a request after 60 seconds by default, which cuts off
        # a large upload on a slow link. 0 removes that limit, as Caddy and nginx do.
        readTimeout: 0

providers:
  docker:
    exposedByDefault: false  # only containers with traefik.enable=true get a route

certificatesResolvers:
  letsencrypt:
    acme:
      email: "you@example.com"  # use your own address, Let's Encrypt refuses example.com
      storage: /letsencrypt/acme.json
      tlsChallenge: {}
```

<!-- /include -->

`compose.yaml`:

<!-- include: examples/reverse-proxy/traefik/compose.yaml -->

```yaml
# web-terminal-server behind Traefik. See docs/reverse-proxy.md.
services:
  traefik:
    image: traefik:v3.7.13
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "./traefik.yaml:/etc/traefik/traefik.yaml:ro"
      - "./letsencrypt:/letsencrypt"  # keeps the certificates
      - "/var/run/docker.sock:/var/run/docker.sock:ro"  # lets Traefik read the labels below
    networks:
      proxy:
        ipv4_address: "172.30.0.2"  # a fixed address, so the app can trust it

  web-terminal-server:
    image: ghcr.io/cplieger/web-terminal-server:latest
    container_name: web-terminal-server
    restart: unless-stopped
    init: true
    environment:
      AUTH_PASSWORD: "${AUTH_PASSWORD:?put AUTH_PASSWORD=<a long password> in .env}"
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`app.example.com`)"
      - "traefik.http.routers.app.entrypoints=websecure"
      - "traefik.http.routers.app.tls.certresolver=letsencrypt"
      - "traefik.http.services.app.loadbalancer.server.port=7681"
    networks:
      - proxy  # no ports line, so only the proxy can reach the app

networks:
  proxy:
    name: proxy  # a fixed name, so an app's own compose file can join this network
    ipam:
      config:
        - subnet: "172.30.0.0/24"  # pick another range if a network on this host already uses it
          ip_range: "172.30.0.128/25"  # Docker gives other containers addresses from here
```

<!-- /include -->

## Nginx Proxy Manager

Nginx Proxy Manager is nginx with a web page for its settings. It already passes the original `Host` and the forwarded headers, and accepts requests up to 2000 MB. It closes a quiet connection after 90 seconds. It also collects responses from apps that do not send `X-Accel-Buffering: no`. The Advanced settings below change both.

`compose.yaml`:

<!-- include: examples/reverse-proxy/nginx-proxy-manager/compose.yaml -->

```yaml
# web-terminal-server behind Nginx Proxy Manager. See docs/reverse-proxy.md for the settings to enter.
services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:2.16.0
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:81:81"  # the admin page, from this host only
    volumes:
      - "./data:/data"  # the proxy hosts you create and the admin account
      - "./letsencrypt:/etc/letsencrypt"  # keeps the certificates
    networks:
      proxy:
        ipv4_address: "172.30.0.2"  # a fixed address, so the app can trust it

  web-terminal-server:
    image: ghcr.io/cplieger/web-terminal-server:latest
    container_name: web-terminal-server
    restart: unless-stopped
    init: true
    environment:
      AUTH_PASSWORD: "${AUTH_PASSWORD:?put AUTH_PASSWORD=<a long password> in .env}"
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    networks:
      - proxy  # no ports line, so only the proxy can reach the app

networks:
  proxy:
    name: proxy  # a fixed name, so an app's own compose file can join this network
    ipam:
      config:
        - subnet: "172.30.0.0/24"  # pick another range if a network on this host already uses it
          ip_range: "172.30.0.128/25"  # Docker gives other containers addresses from here
```

<!-- /include -->

Start it with `docker compose up -d`, then open `http://localhost:81` on the host and create the admin account. If the host has no browser, run `ssh -L 8181:localhost:81 <you>@<host>` on your computer and open `http://localhost:8181` there. Then add the app:

1. Open **Hosts**, then **Proxy Hosts**, then **Add Proxy Host**.
2. On the **Details** tab, set **Domain Names** to `app.example.com`, **Scheme** to `http`, **Forward Hostname / IP** to `web-terminal-server` and **Forward Port** to `7681`.
3. Turn on **Block Common Exploits** and **Websockets Support**.
4. On the **SSL** tab, choose **Request a new Certificate** under **SSL Certificate**, then turn on **Force SSL**. As with Caddy, your DNS name must point to the host, and port 80 must be open to the internet. For a name that is only on your home network, first add your own certificate under **Certificates**, then **Add Certificate**, then **Custom Certificate**. Then choose it under **SSL Certificate** instead.
5. On the last tab, with the gear icon, paste these lines into **Custom Nginx Configuration**, then select **Save**.

<!-- include: examples/reverse-proxy/nginx-proxy-manager/advanced.conf -->

```nginx
# Paste these lines into the Custom Nginx Configuration box of the proxy host.
proxy_buffering off;
proxy_read_timeout 1h;  # keeps a quiet WebSocket open
proxy_send_timeout 1h;
access_log off;  # the proxy's log keeps the query string, which holds the terminal's session id
```

<!-- /include -->

`access_log off` stops the proxy host's own access log, which would keep the terminal's session id. The app still logs each request with the visitor's address.

## Running the app from its own compose file

Each example above keeps the app in the proxy's compose file. Most apps run from their own folder instead, with the compose file from their README. Compose gives each compose file its own network, so the proxy cannot reach an app in another folder by name. Each example names its network `proxy`, so an app's own compose file can join it:

1. Delete the app's service from the proxy's compose file.
2. In the proxy's folder, run `docker compose up -d --remove-orphans`. That starts the proxy and its `proxy` network. It also removes the app container the example started, which would otherwise keep the app's name taken.
3. In the app's own compose file, add the `networks:` lines from the file below.
4. Set `ALLOWED_HOSTS` and `TRUSTED_PROXIES` as the file below does, because the app's own file lists other names.
5. With Traefik, also copy the `labels:` lines, which give Traefik the route.
6. Remove the app's `ports:` lines, so only the proxy can reach it.
7. Run `docker compose up -d` in the app's folder.

<!-- include: examples/reverse-proxy/app/compose.yaml -->

```yaml
# web-terminal-server in its own folder, behind the proxy from any example in docs/reverse-proxy.md.
# It joins the proxy network that the proxy's compose file creates, so start the proxy first.
services:
  web-terminal-server:
    image: ghcr.io/cplieger/web-terminal-server:latest
    container_name: web-terminal-server
    restart: unless-stopped
    init: true
    environment:
      AUTH_PASSWORD: "${AUTH_PASSWORD:?put AUTH_PASSWORD=<a long password> in .env}"
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    labels:  # only Traefik reads these, the other proxies ignore them
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`app.example.com`)"
      - "traefik.http.routers.app.entrypoints=websecure"
      - "traefik.http.routers.app.tls.certresolver=letsencrypt"
      - "traefik.http.services.app.loadbalancer.server.port=7681"
    networks:
      - proxy  # no ports line, so only the proxy can reach the app

networks:
  proxy:
    external: true  # created by the proxy's compose.yaml
```

<!-- /include -->

The proxy keeps its fixed address on the shared network, so `TRUSTED_PROXIES` stays `172.30.0.2`.

## Telling the app about the proxy

Two settings on the app match the proxy:

- `ALLOWED_HOSTS` lists every name you open the app at, without `https://` or a port. The app reads only the `Host` header and ignores `X-Forwarded-Host`, so the proxy must pass the original `Host`, which all four examples do. A request for a name not on the list gets `403` with `host not allowed`. The app's own healthcheck uses `localhost` from inside the container and is always allowed. subflux sets the same list as `allowed_hosts` in its config file.
- `TRUSTED_PROXIES` lists the proxy's address. The app then reads the visitor's address from `X-Forwarded-For` and writes it in its access log as `client_ip`. Without it, the log shows the proxy's address. Each entry is an address or a range such as `172.30.0.0/24`, and the app ignores an entry it cannot read, with a warning.

In web-terminal-server, web-terminal-kiro, marotte and knell, the list changes only the address in the logs. subflux sets the same list as `trusted_proxies` in its config file, and uses it for more:

- It reads `X-Forwarded-Proto` only from a trusted proxy. When that header says `https`, its login cookie is sent over HTTPS only. Without the proxy on the list, subflux ignores the header and sends its plain-HTTP cookie, even to visitors on HTTPS.
- It limits failed logins per visitor address, and records that address with each login.
- Write one proxy as `172.30.0.2/32`, as subflux's page does. subflux refuses a config with an entry it cannot read.

subflux's [reverse proxy section](https://github.com/cplieger/subflux/blob/main/docs/hardening.md#running-behind-a-reverse-proxy) has the details.

List only the proxy, never the whole network. Any address on the list can choose the visitor address the app sees.

Docker gives containers new addresses when they are recreated. So the examples fix the proxy at `172.30.0.2` and keep other containers in the upper half of the range. If `172.30.0.0/24` is already in use on your host, `docker compose up` says so. Pick another private range and change all four places in the proxy's `compose.yaml`. `ipv4_address` and `TRUSTED_PROXIES` take the proxy's new address, and `subnet` and `ip_range` take the new range. An app with its own compose file takes the new address in its `TRUSTED_PROXIES` too.

## Checking your setup

Each example on this page runs in a test that starts it on a clean machine. The test checks the points in [What the apps expect from a proxy](#what-the-apps-expect-from-a-proxy) twice. It first replaces the app with a small test server that reports the headers it receives, then runs the example as written with web-terminal-server. It then recreates the app, as an update does, and checks that the proxy still reaches it.

Last, the test follows [Running the app from its own compose file](#running-the-app-from-its-own-compose-file). It deletes the app from the proxy's compose file, runs `docker compose up -d --remove-orphans`, then starts the app from its own compose file and checks it again.

To check your own setup:

- Open the app's address. web-terminal-server asks for its login. A `403` page with `host not allowed` means the name is missing from `ALLOWED_HOSTS`, or the proxy does not pass the visitor's `Host`.
- Leave a terminal open and idle for five minutes. If it disconnects, raise the proxy's read timeout.
- Run `docker compose logs web-terminal-server` and find a line with `client_ip=`. It should show your device's address, not `172.30.0.2`.
