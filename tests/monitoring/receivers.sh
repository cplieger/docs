#!/usr/bin/env bash
# Checks every Alertmanager config the guide shows with amtool, then sends one
# alert through the Discord config to a test webhook to prove the format.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

IMAGE="prom/alertmanager:v0.34.1"

for file in minimal/alertmanager/alertmanager.yml receivers/discord.yml receivers/email.yml; do
  docker run --rm --entrypoint amtool \
    --volume "$DOCS_ROOT/examples/monitoring/$(dirname "$file"):/cfg:ro" \
    "$IMAGE" check-config "/cfg/$(basename "$file")"
  pass "amtool accepts $file"
done

PROJECT="monitoring-receivers"
WORK="$(mktemp -d)"
trap finish EXIT
mkdir -p "$WORK/alertmanager"
cp "$DOCS_ROOT/examples/monitoring/receivers/discord.yml" "$WORK/alertmanager/alertmanager.yml"
printf 'http://sink:8080/\n' >"$WORK/alertmanager/discord_webhook_url"
chmod -R a+rX "$WORK"
chmod 600 "$WORK/alertmanager/discord_webhook_url"
sudo chown 65534:65534 "$WORK/alertmanager/discord_webhook_url"
COMPOSE_FILES=("$DOCS_ROOT/tests/monitoring/receivers.compose.yaml")
export RECEIVERS_DIR="$WORK/alertmanager"

compose up --detach --quiet-pull
wait_for 60 "Alertmanager is ready" http_ok http://127.0.0.1:9093/-/ready
curl -fsS -H 'Content-Type: application/json' -X POST http://127.0.0.1:9093/api/v2/alerts \
  -d '[{"labels":{"alertname":"ReceiverTest","severity":"info"},"annotations":{"summary":"receiver test"}}]' >/dev/null

discord_message() {
  curl -fsS http://127.0.0.1:8080/ \
    | jq --exit-status '[.[] | .embeds[]? | select(.title | contains("ReceiverTest"))] | length > 0' >/dev/null
}
wait_for 120 "the Discord config posted a Discord message" discord_message
