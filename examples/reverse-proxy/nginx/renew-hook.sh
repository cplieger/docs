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
