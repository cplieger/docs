# shellcheck shell=bash
# The proxy under test, shared by run.sh and login.sh. Source it after tests/lib.sh.
# The caller sets CLIENT_IP, the test client's fixed address on the proxy network.

# proxy_folder PROXY prints the example folder under examples/reverse-proxy.
proxy_folder() {
  case "$1" in
    caddy | nginx | traefik) echo "$1" ;;
    npm) echo nginx-proxy-manager ;;
    *) die "unknown proxy $1" ;;
  esac
}

# make_test_cert DIR writes a self-signed certificate for app.example.com, which stands in
# for the one a reader puts in certs/ for nginx, or adds as a Custom Certificate in
# Nginx Proxy Manager.
make_test_cert() {
  mkdir -p "$1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=app.example.com \
    -addext subjectAltName=DNS:app.example.com \
    -keyout "$1/privkey.pem" -out "$1/fullchain.pem" 2>/dev/null
  chmod 0644 "$1/privkey.pem"
}

through_proxy() {
  curl --silent --insecure --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --resolve "app.example.com:80:127.0.0.1" --resolve "app.example.com:443:127.0.0.1" \
    "$@"
}
answers() {
  local want="$1"
  shift
  [ "$(through_proxy "$@")" = "$want" ]
}
check() {
  compose exec -T client python3 /check.py --client-ip "$CLIENT_IP" "$@"
}
