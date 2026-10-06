#!/usr/bin/env bash
# Boots one reverse-proxy example with its login from examples/reverse-proxy/login, made
# the way the guide makes it, and checks it the way a browser uses it.
#   bash tests/reverse-proxy/login.sh caddy|nginx|traefik|npm
# The test backend stands in for web-terminal-kiro on port 9848. check.py runs in a test
# client with the fixed address CLIENT_IP on the proxy network.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/proxy.sh"

proxy="${1:?usage: login.sh caddy|nginx|traefik|npm}"
folder="$(proxy_folder "$proxy")"
HERE="tests/reverse-proxy"
CLIENT_IP="172.30.0.10"
LOGIN_PASSWORD="docs-login-$(openssl rand -hex 12)"
export LOGIN_PASSWORD

# The guide tells a reader to copy the login folder over the proxy's folder, so every line
# of the base example, apart from its header line and its app, must be in the login twin.
without_app() {
  awk '/^  web-terminal-(server|kiro):$/ { skip = 1; next } skip && /^(  )?[^ ]/ { skip = 0 } !skip' "$1" \
    | tail -n +2
}
login_dir="examples/reverse-proxy/login/$folder"

# guide_image IMAGE_REGEX TAIL prints the image the guide's `docker run ... IMAGE TAIL` names,
# so the test runs the image a reader runs.
guide_image() {
  local image
  image="$(grep -oE "$1$2" "$DOCS_ROOT/docs/proxy-login.md" | head -n 1)"
  [ -n "$image" ] || die "docs/proxy-login.md has no command matching $1$2"
  echo "${image%"$2"}"
}
for twin in "$DOCS_ROOT/$login_dir"/*; do
  base="$DOCS_ROOT/examples/reverse-proxy/$folder/$(basename "$twin")"
  [ -f "$base" ] || die "$twin has no twin in examples/reverse-proxy/$folder"
  missing="$(diff <(without_app "$base" | grep -v 'web-terminal-server') <(without_app "$twin") | grep '^<' || true)"
  [ -z "$missing" ] || die "$login_dir/$(basename "$twin") lacks these lines of its base example:"$'\n'"$missing"
done
pass "each login file keeps every line of its base example"

use_example "rp-login-$proxy" "examples/reverse-proxy/$folder"
base_files=("${COMPOSE_FILES[@]}" "$DOCS_ROOT/$HERE/client.compose.yaml")
[ "$proxy" = caddy ] && base_files+=("$DOCS_ROOT/$HERE/caddy.compose.yaml")
if [ "$proxy" = nginx ] || [ "$proxy" = npm ]; then
  make_test_cert "$WORK/certs"
fi

echo "== Make the login the way the guide says"
if [ "$proxy" = caddy ]; then
  caddy_image="$(guide_image 'caddy:[^ `]+' ' caddy hash-password`')"
  # The guide's command, with -i in place of -it so the password comes from stdin.
  hash="$(docker run --rm -i "$caddy_image" caddy hash-password <<<"$LOGIN_PASSWORD")"
  case "$hash" in
    "\$2a\$"*) pass "caddy hash-password prints a bcrypt hash" ;;
    *) die "caddy hash-password printed '$hash', not a bcrypt hash" ;;
  esac
fi
cp -R "$DOCS_ROOT/$login_dir/." "$WORK/"
chmod -R a+rX "$WORK"
case "$proxy" in
  caddy)
    text="$(<"$WORK/Caddyfile")"
    printf '%s\n' "${text//"<hash>"/"$hash"}" >"$WORK/Caddyfile"
    grep -q '<hash>' "$WORK/Caddyfile" && die "the Caddyfile still holds <hash>"
    grep -qF "admin $hash" "$WORK/Caddyfile" || die "the hash is not in the Caddyfile"
    ;;
  nginx | traefik)
    htpasswd_image="$(guide_image 'httpd:[^ `]+' ' htpasswd -cB htpasswd admin`')"
    # The guide's command, with -i to read the password from stdin instead of asking twice.
    docker run --rm -i -v "$WORK:/work" -w /work "$htpasswd_image" htpasswd -ciB htpasswd admin <<<"$LOGIN_PASSWORD"
    line="$(head -n 1 "$WORK/htpasswd")"
    case "$line" in
      "admin:\$2y\$"*) pass "htpasswd -B wrote a bcrypt line for admin" ;;
      *) die "htpasswd -B wrote '$line', not a bcrypt line for admin" ;;
    esac
    ;;
esac

echo "== The example with its login, and the test backend as web-terminal-kiro"
COMPOSE_FILES=("${base_files[@]}" "$DOCS_ROOT/$HERE/override.login.compose.yaml")
compose up --detach --build --quiet-pull --remove-orphans --force-recreate
if [ "$proxy" = npm ]; then
  # The proxy host the base section creates, then the guide's login steps on it.
  python3 "$DOCS_ROOT/$HERE/npm-configure.py" "$WORK/certs/fullchain.pem" "$WORK/certs/privkey.pem"
  python3 "$DOCS_ROOT/$HERE/npm-configure.py" --login-password-env LOGIN_PASSWORD --forward web-terminal-kiro:9848
fi
wait_for 180 "the proxy asks for the login" \
  answers 401 "https://app.example.com/headers"
wait_for 60 "the proxy lets the login through to the backend" \
  answers 200 --user "admin:$LOGIN_PASSWORD" "https://app.example.com/headers"

check --mode login --scheme https --password-env LOGIN_PASSWORD --idle 100
