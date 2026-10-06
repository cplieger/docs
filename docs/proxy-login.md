# Adding a login on a reverse proxy

This page puts a user name and password on the reverse proxy in front of marotte or web-terminal-kiro, which have no login of their own. It is for anyone who opens one of these two apps through Caddy, nginx, Traefik or Nginx Proxy Manager. The proxy then checks the login before it passes any request on to the app.

Set up your proxy's example from [Running an app behind a reverse proxy](reverse-proxy.md) first. This page then switches that example to web-terminal-kiro behind a login, and lists the changes for marotte. Leave this out for web-terminal-server and subflux, which have their own login. A login on the proxy in front of web-terminal-server keeps asking, because the app asks for its own password in the same browser prompt.

## The password is the only lock

Use a long password that you use nowhere else, such as one a password manager makes. Without the proxy login, anyone who reaches the app gets web-terminal-kiro's root shell, or marotte's agent and shell on its mounted folders. None of these examples limits repeated guesses. Open the app only over HTTPS, because after you log in, the browser keeps sending the password over the network. Every example sends plain HTTP to HTTPS before it asks for the password.

Without a `ports:` line, nothing on your network reaches the app around the proxy. Other containers on the `proxy` network, and any program running on the Docker host itself, can still reach it directly, without the login. So put only containers you trust on that network. If you cannot trust them all, give the app and the proxy a network of their own instead of the shared `proxy` network.

## Switching the example to web-terminal-kiro

Each proxy has a folder under `examples/reverse-proxy/login` with only the files that change. Copy it over your proxy's folder, then make the login as your proxy's part below shows. The app becomes web-terminal-kiro on port 9848, with the same `ALLOWED_HOSTS` and `TRUSTED_PROXIES` as before. Its `config`, `workspace` and `uploads` folders appear next to `compose.yaml`.

For marotte, change these in the copied files before the next step:

- In `compose.yaml`, rename the `web-terminal-kiro` service and its `container_name` to `marotte`, and set `image:` to `ghcr.io/cplieger/marotte:latest`.
- Delete the `init: true` line, because marotte's image has its own.
- Keep the three `volumes:` lines, because marotte uses the same folders.
- Add the line `user: "${PUID:-1000}:${PGID:-1000}"` to the service. Then run `mkdir -p config workspace uploads` and `sudo chown -R 1000:1000 config workspace uploads` in the proxy's folder, as [marotte's README](https://github.com/cplieger/marotte#quick-start) explains. If you set `PUID` and `PGID` in `.env`, use those numbers.
- Send the proxy to `marotte` on port `9847` instead of `web-terminal-kiro` on `9848`. That is the `reverse_proxy` line in Caddy's `Caddyfile`, the `server` line in nginx's `app.conf`, the `loadbalancer.server.port` label for Traefik, or step 6 for Nginx Proxy Manager.

After you make the login, run `docker compose up -d --remove-orphans --force-recreate` in the proxy's folder. `--remove-orphans` removes the web-terminal-server container. `--force-recreate` makes the proxy read its changed files.

## Caddy login

Run `docker run --rm -it caddy:2.11.7 caddy hash-password`, which needs nothing else running. Type your password twice, and Caddy prints its hash, a line that starts with `$2a$`. Put that line in place of `<hash>` in the `Caddyfile`. Caddy refuses to start while `<hash>` is still there. The documentation of [`basic_auth`](https://caddyserver.com/docs/caddyfile/directives/basic_auth), [`hash-password`](https://caddyserver.com/docs/command-line#caddy-hash-password) and [`reverse_proxy`](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#headers) has the details.

`Caddyfile`:

<!-- include: examples/reverse-proxy/login/caddy/Caddyfile -->

```caddyfile
# Serves web-terminal-kiro at https://app.example.com behind a login. Caddy gets the certificate by itself.
# WebSockets, live updates and the forwarded headers need no extra lines.
app.example.com {
	# admin is the user name. Replace <hash> with the hash of your password, which
	# caddy hash-password prints. docs/proxy-login.md shows how to run it.
	basic_auth {
		admin <hash>
	}
	reverse_proxy web-terminal-kiro:9848 {
		# The app has no use for the password, so Caddy removes it from each request.
		header_up -Authorization
	}
}
```

<!-- /include -->

`compose.yaml`:

<!-- include: examples/reverse-proxy/login/caddy/compose.yaml -->

```yaml
# web-terminal-kiro behind Caddy, with a login. See docs/proxy-login.md.
services:
  caddy:
    image: caddy:2.11.7
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

  web-terminal-kiro:
    image: ghcr.io/cplieger/web-terminal-kiro:latest
    container_name: web-terminal-kiro
    restart: unless-stopped
    init: true  # required, it cleans up the processes each terminal tab leaves behind
    environment:
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    volumes:
      - "./config:/config"  # kiro-cli sign-in, installed tools and settings. The disk must allow running programs.
      - "./workspace:/workspace"  # your repositories
      - "./uploads:/uploads"  # images you paste into a tab, kept when the container is recreated
    networks:
      - proxy  # no ports line, so Docker does not publish the app on a host port

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

## nginx login

nginx reads the login from a file named `htpasswd` next to `compose.yaml`. In that folder, run `htpasswd -cB htpasswd admin` and type your password twice. `admin` is the user name. `-c` creates the file, or replaces it if it exists. `-B` stores the password as a bcrypt hash, which is stronger than the MD5 hash `htpasswd` uses by default.

The `htpasswd` command comes in the `apache2-utils` package on Debian and Ubuntu, and in `httpd-tools` on Fedora. Without it, run `docker run --rm -it -v "$PWD:/work" -w /work httpd:2.4.69 htpasswd -cB htpasswd admin` in the same folder.

Make the file before you start nginx with the new `compose.yaml`. If it is missing when nginx starts, Docker makes an empty folder named `htpasswd` in its place. Delete that folder, make the file, and run the command from [Switching the example to web-terminal-kiro](#switching-the-example-to-web-terminal-kiro) again. The documentation of [`auth_basic`](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html), [`proxy_set_header`](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_set_header) and [`htpasswd`](https://httpd.apache.org/docs/2.4/programs/htpasswd.html) has the details.

`app.conf`:

<!-- include: examples/reverse-proxy/login/nginx/app.conf -->

```nginx
# Serves web-terminal-kiro at https://app.example.com behind a login. Put your certificate in the certs folder.

# Docker's own name server. nginx asks it for the app's address again every 10 seconds,
# so it still reaches the app after an update gives the app a new address.
resolver 127.0.0.11 valid=10s;

upstream web_terminal {
    zone web_terminal 64k;
    server web-terminal-kiro:9848 resolve;
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

    # The login. nginx asks for a user name and password from the htpasswd file before it
    # passes any request on. Port 80 above only sends visitors to HTTPS, so it needs none.
    auth_basic "login";
    auth_basic_user_file /etc/nginx/htpasswd;

    location / {
        proxy_pass http://web_terminal;
        proxy_http_version 1.1;

        proxy_set_header Host $host;  # the app checks this name against ALLOWED_HOSTS
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Authorization "";  # the app has no use for the password, so nginx removes it

        proxy_buffering off;  # sends live updates as they happen
        proxy_read_timeout 1h;  # keeps a quiet WebSocket open, the default closes it after 60 seconds
        proxy_send_timeout 1h;
    }
}
```

<!-- /include -->

`compose.yaml`:

<!-- include: examples/reverse-proxy/login/nginx/compose.yaml -->

```yaml
# web-terminal-kiro behind nginx, with a login. See docs/proxy-login.md.
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
      - "./htpasswd:/etc/nginx/htpasswd:ro"  # the login, make this file before the first start
    networks:
      proxy:
        ipv4_address: "172.30.0.2"  # a fixed address, so the app can trust it

  web-terminal-kiro:
    image: ghcr.io/cplieger/web-terminal-kiro:latest
    container_name: web-terminal-kiro
    restart: unless-stopped
    init: true  # required, it cleans up the processes each terminal tab leaves behind
    environment:
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    volumes:
      - "./config:/config"  # kiro-cli sign-in, installed tools and settings. The disk must allow running programs.
      - "./workspace:/workspace"  # your repositories
      - "./uploads:/uploads"  # images you paste into a tab, kept when the container is recreated
    networks:
      - proxy  # no ports line, so Docker does not publish the app on a host port

networks:
  proxy:
    name: proxy  # a fixed name, so an app's own compose file can join this network
    ipam:
      config:
        - subnet: "172.30.0.0/24"  # pick another range if a network on this host already uses it
          ip_range: "172.30.0.128/25"  # Docker gives other containers addresses from here
```

<!-- /include -->

## Traefik login

Traefik reads the same `htpasswd` file. Make it as [nginx login](#nginx-login) shows, before you start Traefik with the new `compose.yaml`. Two labels on web-terminal-kiro set up a `basicAuth` middleware named `login`, and a third puts it on the app's route. If the app runs from its own compose file, as [Running the app from its own compose file](reverse-proxy.md#running-the-app-from-its-own-compose-file) shows, put the three login labels there.

Traefik can also take the hash in a `users` label. The file is simpler, because compose reads each `$` in a label as the start of a variable, so every `$` of the hash would have to be written `$$`. The [`basicAuth` documentation](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/basicauth/) has the details.

<!-- include: examples/reverse-proxy/login/traefik/compose.yaml -->

```yaml
# web-terminal-kiro behind Traefik, with a login. See docs/proxy-login.md.
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
      - "./htpasswd:/etc/traefik/htpasswd:ro"  # the login, make this file before the first start
    networks:
      proxy:
        ipv4_address: "172.30.0.2"  # a fixed address, so the app can trust it

  web-terminal-kiro:
    image: ghcr.io/cplieger/web-terminal-kiro:latest
    container_name: web-terminal-kiro
    restart: unless-stopped
    init: true  # required, it cleans up the processes each terminal tab leaves behind
    environment:
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`app.example.com`)"
      - "traefik.http.routers.app.entrypoints=websecure"
      - "traefik.http.routers.app.tls.certresolver=letsencrypt"
      - "traefik.http.services.app.loadbalancer.server.port=9848"
      # The login. A file keeps the password hash out of this file, where every $ in it
      # would have to be written $$.
      - "traefik.http.middlewares.login.basicauth.usersfile=/etc/traefik/htpasswd"
      # The app has no use for the password, so Traefik removes it from each request.
      - "traefik.http.middlewares.login.basicauth.removeheader=true"
      - "traefik.http.routers.app.middlewares=login"
    volumes:
      - "./config:/config"  # kiro-cli sign-in, installed tools and settings. The disk must allow running programs.
      - "./workspace:/workspace"  # your repositories
      - "./uploads:/uploads"  # images you paste into a tab, kept when the container is recreated
    networks:
      - proxy  # no ports line, so Docker does not publish the app on a host port

networks:
  proxy:
    name: proxy  # a fixed name, so an app's own compose file can join this network
    ipam:
      config:
        - subnet: "172.30.0.0/24"  # pick another range if a network on this host already uses it
          ip_range: "172.30.0.128/25"  # Docker gives other containers addresses from here
```

<!-- /include -->

## Nginx Proxy Manager login

Nginx Proxy Manager keeps the login in an access list, which you add to the proxy host. Copy the login folder and run the command from [Switching the example to web-terminal-kiro](#switching-the-example-to-web-terminal-kiro). Then open the admin page and follow these steps:

1. Open **Access Lists**, then **Add Access List**.
2. On the **Details** tab, set **Name** to `login`. Leave **Satisfy Any** and **Pass Auth to Upstream** off.
3. On the **Authorizations** tab, enter `admin` as **Username** and your password as **Password**.
4. Leave the **Rules** tab empty, then select **Save**.
5. Open **Hosts**, then **Proxy Hosts**. Open the menu at the end of the row for `app.example.com`, then **Edit**.
6. On the **Details** tab, set **Forward Hostname / IP** to `web-terminal-kiro` and **Forward Port** to `9848`.
7. Choose `login` under **Access List**, and leave **Cache Assets** off. Then select **Save**.

**Cache Assets** must stay off, because with it on, Nginx Proxy Manager serves images, scripts and style sheets without asking for the login.

Nginx Proxy Manager keeps the password in plain text in its database in the `data` folder, so keep that folder and any backup of it private.

**Satisfy Any** matters only when **Rules** lists addresses. With it on, a listed address or the password is enough. With it off, a visitor needs both. **Pass Auth to Upstream** sends the password on to the app, which has no use for it. The [access list template](https://github.com/NginxProxyManager/nginx-proxy-manager/blob/v2.16.0/backend/templates/_access.conf) shows the nginx lines each choice writes.

<!-- include: examples/reverse-proxy/login/nginx-proxy-manager/compose.yaml -->

```yaml
# web-terminal-kiro behind Nginx Proxy Manager, with a login. See docs/proxy-login.md for the settings to enter.
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

  web-terminal-kiro:
    image: ghcr.io/cplieger/web-terminal-kiro:latest
    container_name: web-terminal-kiro
    restart: unless-stopped
    init: true  # required, it cleans up the processes each terminal tab leaves behind
    environment:
      ALLOWED_HOSTS: "app.example.com"  # the name you open it at, any other name is refused
      TRUSTED_PROXIES: "172.30.0.2"  # the proxy, so the app logs the visitor's address
    volumes:
      - "./config:/config"  # kiro-cli sign-in, installed tools and settings. The disk must allow running programs.
      - "./workspace:/workspace"  # your repositories
      - "./uploads:/uploads"  # images you paste into a tab, kept when the container is recreated
    networks:
      - proxy  # no ports line, so Docker does not publish the app on a host port

networks:
  proxy:
    name: proxy  # a fixed name, so an app's own compose file can join this network
    ipam:
      config:
        - subnet: "172.30.0.0/24"  # pick another range if a network on this host already uses it
          ip_range: "172.30.0.128/25"  # Docker gives other containers addresses from here
```

<!-- /include -->

## Terminals and live updates keep working

The browser asks for the login once. It then sends the login again with its requests to the same name, including the terminal's WebSocket and the live updates. Every example removes the login from each request before it passes the request on, so the app never sees the password.

Safari, and other browsers built on its engine WebKit, do not send the login with a WebSocket. On an iPhone or iPad, most browsers use WebKit. [WebKit bug 80362](https://bugs.webkit.org/show_bug.cgi?id=80362) tracks this. In those browsers, the terminal does not connect behind a proxy login. For them, use single sign-on instead, from the security pages of [marotte](https://github.com/cplieger/marotte/blob/main/docs/hardening.md#who-can-reach-it) and [web-terminal-kiro](https://github.com/cplieger/web-terminal-kiro/blob/main/docs/hardening.md#behind-a-reverse-proxy).

The browser fetches the app's manifest, the file that lets it install the app, without the login. So installing the app on a phone's home screen does not work behind a proxy login.

`ALLOWED_HOSTS` and `TRUSTED_PROXIES` stay as [Telling the app about the proxy](reverse-proxy.md#telling-the-app-about-the-proxy) sets them. `ALLOWED_HOSTS` stays, because the proxy passes each request on with its original `Host`. `TRUSTED_PROXIES` stays, because the proxy still connects from its fixed address, `172.30.0.2`.

The app's own health check runs inside its container at `127.0.0.1`, so it never meets the login. A monitor that checks the address from outside gets `401` without the login, which still shows that the proxy is up.

## Checking the login

Run `curl -I https://app.example.com`, which answers `401`. Open the address in a private window. The browser asks for the user name and password, and asks again after a wrong one. The test for each example sends no login, then a wrong password, and both get `401` for a plain request, a script file, the WebSocket and the live updates. With the right login, it checks that the app gets no password, then runs every check from [What the apps expect from a proxy](reverse-proxy.md#what-the-apps-expect-from-a-proxy).
