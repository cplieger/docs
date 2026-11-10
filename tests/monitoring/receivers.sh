#!/usr/bin/env bash
# Checks every Alertmanager config the guide shows with amtool, then sends one
# alert through the Discord config to a test webhook to prove the format.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

# The stack's own Alertmanager, so one Renovate bump moves both.
IMAGE="$(awk '$1 == "image:" && $2 ~ /^prom\/alertmanager:/ { print $2; exit }' "$DOCS_ROOT/examples/monitoring/stack/compose.yaml")"
[ -n "$IMAGE" ] || die "examples/monitoring/stack/compose.yaml names no prom/alertmanager image"

for file in stack/alertmanager/alertmanager.yml receivers/discord.yml receivers/email.yml receivers/one-app.yml; do
  docker run --rm --entrypoint amtool \
    --volume "$DOCS_ROOT/examples/monitoring/$(dirname "$file"):/cfg:ro" \
    "$IMAGE" check-config "/cfg/$(basename "$file")"
  pass "amtool accepts $file"
done

# route_of LABEL=VALUE...: the receiver one-app.yml picks for an alert with those labels.
route_of() {
  docker run --rm --entrypoint amtool --volume "$DOCS_ROOT/examples/monitoring/receivers:/cfg:ro" \
    "$IMAGE" config routes test --config.file=/cfg/one-app.yml "$@"
}
[ "$(route_of alertname=ExampleAppItemFound item=first)" = notify-once ] \
  || die "one-app.yml does not send the app's item alerts to notify-once"
[ "$(route_of alertname=KnellDown job=knell)" = notify ] \
  || die "one-app.yml does not send other alerts to notify"
pass "one-app.yml routes the app's item alerts apart from the others"

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
