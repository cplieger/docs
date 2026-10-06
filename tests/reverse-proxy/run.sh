#!/usr/bin/env bash
# Boots one reverse-proxy example twice and checks it the way a browser uses it.
#   bash tests/reverse-proxy/run.sh caddy|nginx|traefik|npm
# Pass 1 swaps the app for a neutral test backend, because no single real image
# reports the headers it receives or accepts an arbitrary upload. Pass 2 runs the
# example unchanged in front of the real web-terminal-server image, then recreates
# the app so it gets a new address, as an update does. Pass 3 follows the guide's
# steps for moving the app out of the proxy's compose file into its own compose
# project from examples/reverse-proxy/app, with the proxy left running.
# check.py runs in a test client with the fixed address CLIENT_IP on the proxy network.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/proxy.sh"

proxy="${1:?usage: run.sh caddy|nginx|traefik|npm}"
folder="$(proxy_folder "$proxy")"
HERE="tests/reverse-proxy"
CLIENT_IP="172.30.0.10"
AUTH_PASSWORD="docs-test-$(openssl rand -hex 8)"
export AUTH_PASSWORD

use_example "rp-$proxy" "examples/reverse-proxy/$folder"
base_files=("${COMPOSE_FILES[@]}" "$DOCS_ROOT/$HERE/client.compose.yaml")
[ "$proxy" = caddy ] && base_files+=("$DOCS_ROOT/$HERE/caddy.compose.yaml")

if [ "$proxy" = nginx ] || [ "$proxy" = npm ]; then
  make_test_cert "$WORK/certs"
fi

app_ip() {
  docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$(compose ps --quiet web-terminal-server)"
}
# The terminal's session id travels in the /ws query string, so no proxy log may keep it.
proxy_logs() {
  compose logs --no-color "$folder"
  if [ "$proxy" = npm ]; then
    sudo sh -c 'cat "$1"/data/logs/*.log' sh "$WORK"
  fi
}
no_session_in_logs() {
  local logs
  logs="$(proxy_logs)"
  case "$proxy" in
    nginx)
      grep -q '"GET /ws HTTP/1.1" 101' <<<"$logs" || die "nginx logged no /ws request, so this check proves nothing"
      ;;
    npm)
      sudo test -e "$WORK/data/logs/proxy-host-1_access.log" || die "Nginx Proxy Manager has no log for the proxy host"
      ;;
  esac
  if grep -q 'session=' <<<"$logs"; then
    grep 'session=' <<<"$logs" | head -n 3 >&2
    die "the proxy's log keeps the /ws session id"
  fi
  pass "the proxy's logs keep no /ws session id"
}
configure_npm() {
  if [ "$proxy" = npm ]; then
    python3 "$DOCS_ROOT/$HERE/npm-configure.py" "$WORK/certs/fullchain.pem" "$WORK/certs/privkey.pem"
  fi
}

echo "== Pass 1: protocol checks against the test backend"
COMPOSE_FILES=("${base_files[@]}" "$DOCS_ROOT/$HERE/override.compose.yaml")
compose up --detach --build --quiet-pull
configure_npm
wait_for 180 "the proxy routes app.example.com to the backend" \
  answers 200 "https://app.example.com/headers"
check --mode protocol --scheme https --idle 100
compose down --remove-orphans

echo "== Pass 2: the example unchanged, with web-terminal-server"
COMPOSE_FILES=("${base_files[@]}" "$DOCS_ROOT/$HERE/override.app.compose.yaml")
compose up --detach --quiet-pull --wait --wait-timeout 180
configure_npm
wait_for 180 "the proxy routes app.example.com to web-terminal-server" \
  answers 200 --user "admin:$AUTH_PASSWORD" "https://app.example.com/healthz"
check --mode app --scheme https --password-env AUTH_PASSWORD
no_session_in_logs

if [ "$proxy" = nginx ]; then
  # Run renew-hook.sh the way Certbot runs a deploy hook: RENEWED_LINEAGE names a live
  # folder whose files are links into an archive folder.
  lineage="$(mktemp -d)"
  mkdir -p "$lineage/archive/app.example.com" "$lineage/live/app.example.com"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=app.example.com/O=renewed" \
    -addext subjectAltName=DNS:app.example.com \
    -keyout "$lineage/archive/app.example.com/privkey2.pem" \
    -out "$lineage/archive/app.example.com/fullchain2.pem" 2>/dev/null
  ln -s ../../archive/app.example.com/fullchain2.pem "$lineage/live/app.example.com/fullchain.pem"
  ln -s ../../archive/app.example.com/privkey2.pem "$lineage/live/app.example.com/privkey.pem"
  RENEWED_LINEAGE="$lineage/live/app.example.com" "$WORK/renew-hook.sh"
  served_subject() {
    openssl s_client -connect 127.0.0.1:443 -servername app.example.com </dev/null 2>/dev/null \
      | openssl x509 -noout -subject | grep -q 'O *= *renewed'
  }
  wait_for 30 "nginx serves the certificate renew-hook.sh copied in" served_subject
  rm -rf "$lineage"
fi

direct() {
  compose exec -T probe curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "admin:$AUTH_PASSWORD" --header "Host: $1" http://web-terminal-server:7681/healthz
}
code="$(direct other.example.com)"
[ "$code" = 403 ] || die "the app answered $code to a Host it does not list"
pass "the app refuses a Host that ALLOWED_HOSTS does not list"
code="$(direct app.example.com)"
[ "$code" = 200 ] || die "the app answered $code to its own Host"
pass "the app accepts the Host the proxy forwards"

logged="$(compose logs --no-color web-terminal-server | grep 'path=/api/sessions ' | grep -o 'client_ip=[^ ]*' | tail -n 1 || true)"
[ "$logged" = "client_ip=$CLIENT_IP" ] || die "the app logged '${logged:-no client_ip}' for /api/sessions, not client_ip=$CLIENT_IP"
pass "the app logs the visitor's address from X-Forwarded-For ($logged)"

echo "== The app gets a new address, as an update gives it"
old_ip="$(app_ip)"
app_net="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' \
  "$(compose ps --quiet web-terminal-server)")"
compose rm --stop --force web-terminal-server
# Docker hands a freed address straight back, so hold the old one while the app starts again.
holder="$(docker run --detach --rm --network "$app_net" --ip "$old_ip" curlimages/curl:8.22.0 sleep 600)"
compose up --detach --no-deps --wait --wait-timeout 180 web-terminal-server
new_ip="$(app_ip)"
docker rm --force "$holder" >/dev/null
[ -n "$new_ip" ] && [ "$new_ip" != "$old_ip" ] \
  || die "the recreated app has address '$new_ip', the same as before, so this check proves nothing"
wait_for 60 "the proxy reaches the recreated app at its new address $new_ip" \
  answers 200 --user "admin:$AUTH_PASSWORD" "https://app.example.com/healthz"

echo "== Pass 3: the app moved to its own compose file, following the guide's steps"
# The guide's steps: delete the app's service from the proxy's compose file, run
# up --remove-orphans there, then start the app from its own folder. A left-over
# container would hold the name web-terminal-server and the app's start would fail.
awk '/^  web-terminal-server:$/ { skip = 1; next } skip && /^(  )?[^ ]/ { skip = 0 } !skip' \
  "$WORK/compose.yaml" >"$WORK/compose.moved.yaml"
mv "$WORK/compose.moved.yaml" "$WORK/compose.yaml"
if grep -q '^  web-terminal-server:' "$WORK/compose.yaml"; then
  die "the app's service is still in the proxy's compose file"
fi
COMPOSE_FILES=("${base_files[@]}")
compose up --detach --quiet-pull --remove-orphans
add_project rp-app examples/reverse-proxy/app
configure_npm
project rp-app up --detach --quiet-pull --wait --wait-timeout 180
wait_for 180 "the proxy routes app.example.com to web-terminal-server from its own compose project" \
  answers 200 --user "admin:$AUTH_PASSWORD" "https://app.example.com/healthz"
check --mode app --scheme https --password-env AUTH_PASSWORD
logged="$(project rp-app logs --no-color web-terminal-server | grep 'path=/api/sessions ' | grep -o 'client_ip=[^ ]*' | tail -n 1 || true)"
[ "$logged" = "client_ip=$CLIENT_IP" ] || die "the app in its own project logged '${logged:-no client_ip}', not client_ip=$CLIENT_IP"
pass "the app in its own project logs the visitor's address from X-Forwarded-For ($logged)"
