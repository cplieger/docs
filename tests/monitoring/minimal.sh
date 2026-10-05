#!/usr/bin/env bash
# Boots examples/monitoring/minimal and proves two alerts travel from a real
# container log line through Alloy, Loki's ruler and Alertmanager to a webhook.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

use_example monitoring-minimal examples/monitoring/minimal
add_override tests/monitoring/minimal.compose.yaml

printf 'http://sink:8080/\n' >"$WORK/alertmanager/webhook_url"
# The guide's step 2, as written.
chmod 600 "$WORK/alertmanager/webhook_url"
sudo chown 65534:65534 "$WORK/alertmanager/webhook_url"
# The rules a reader gets by default, for the image a reader runs by default.
(cd "$WORK" && bash fetch.sh knell logql)

compose up --detach --quiet-pull
wait_for 120 "Loki is ready" http_ok http://127.0.0.1:3100/ready
wait_for 60 "Alertmanager is ready" http_ok http://127.0.0.1:9093/-/ready
curl -fsS http://127.0.0.1:3100/config | grep -A1 '^analytics:' | grep -q 'reporting_enabled: false' \
  || die "Loki still sends usage statistics"
pass "Loki sends no usage statistics"
loki_config="$(curl -fsS http://127.0.0.1:3100/config)"
grep -qx '  retention_enabled: true' <<<"$loki_config" || die "Loki's compactor does not delete old logs"
grep -qx '  retention_period: 15d' <<<"$loki_config" || die "Loki does not keep logs for the 15d config.yaml sets"
pass "Loki deletes logs after the 15d config.yaml sets"

rules_loaded() {
  local rules
  rules="$(curl -fsS http://127.0.0.1:3100/loki/api/v1/rules)" || return 1
  grep -q 'name: alert-test' <<<"$rules" && grep -q 'name: knell' <<<"$rules"
}
wait_for 120 "Loki's ruler loaded the alert-test and knell groups" rules_loaded

if docker container inspect alert-test >/dev/null 2>&1; then
  die "a container named alert-test already exists. This test leaves it alone, so remove it yourself first"
fi
(cd "$WORK" && bash test-alert.sh)
# Only a successful `docker run --name` gets here, so this ID is the container the test started.
ALERT_TEST_ID="$(docker container inspect --format '{{.Id}}' alert-test)"
remove_alert_test() {
  docker rm --force "$ALERT_TEST_ID" >/dev/null 2>&1
}
CLEANUP_FUNCS+=(remove_alert_test)

# sink_has ALERTNAME CONTAINER: the webhook received that alert, firing, with that container label.
sink_has() {
  curl -fsS http://127.0.0.1:8080/ | jq --exit-status --arg a "$1" --arg c "$2" \
    '[.[] | select(.status == "firing") | .alerts[] | select(.labels.alertname == $a and .labels.container == $c)] | length > 0' \
    >/dev/null
}
wait_for 360 "the webhook received AlertTest" sink_has AlertTest alert-test
wait_for 360 "the webhook received knell's shipped KnellExitedWithError" sink_has KnellExitedWithError knell

active=$(curl -fsS 'http://127.0.0.1:9093/api/v2/alerts?filter=alertname%3D%22AlertTest%22' | jq length)
[ "$active" -ge 1 ] || die "Alertmanager lists no active AlertTest alert"
pass "Alertmanager lists the AlertTest alert"
