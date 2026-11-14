#!/usr/bin/env bash
# Boots examples/monitoring/grafana on top of the starting stack's folder, the way
# the guide tells a reader to, then plex-exporter from its own folder as a second
# compose project, and checks that every part is connected.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

GRAFANA_PASSWORD="docs-test-password"

use_example monitoring-grafana examples/monitoring/stack examples/monitoring/grafana
add_project monitoring-app examples/monitoring/plex-exporter

printf 'http://alert-receiver.invalid/\n' >"$WORK/alertmanager/webhook_url"
chmod 600 "$WORK/alertmanager/webhook_url"
sudo chown 65534:65534 "$WORK/alertmanager/webhook_url"
mkdir -p "$WORK/secrets"
printf '%s\n' "$GRAFANA_PASSWORD" >"$WORK/secrets/grafana_admin_password"
# The guide's step 1, as written.
chmod 600 "$WORK/secrets/grafana_admin_password"
sudo chown 472:0 "$WORK/secrets/grafana_admin_password"
# The files a reader gets by default, for the image a reader runs by default.
# The log rules come from cert-converter, which keeps a LogQL file.
(
  cd "$WORK"
  bash fetch.sh plex-exporter promql
  bash fetch.sh cert-converter logql
  bash fetch.sh plex-exporter dashboard
)

# The compose file's own Prometheus, so one Renovate bump moves both.
prometheus_image="$(awk '$1 == "image:" && $2 ~ /^prom\/prometheus:/ { print $2; exit }' "$WORK/compose.yaml")"
[ -n "$prometheus_image" ] || die "compose.yaml names no prom/prometheus image"
docker run --rm --entrypoint promtool --volume "$WORK/prometheus:/etc/prometheus:ro" \
  "$prometheus_image" check rules /etc/prometheus/rules/plex-exporter.yaml
pass "promtool accepts the shipped PromQL rules"

compose up --detach --quiet-pull
# The app's own compose file joins the monitoring network the stack just created.
project monitoring-app up --detach --quiet-pull
wait_for 120 "Loki is ready" http_ok http://127.0.0.1:3100/ready
wait_for 60 "Prometheus is ready" http_ok http://127.0.0.1:9090/-/ready

loki_rules() {
  local rules
  rules="$(curl -fsS http://127.0.0.1:3100/loki/api/v1/rules)" || return 1
  grep -q 'name: cert-converter' <<<"$rules"
}
wait_for 120 "Loki's ruler loaded the shipped LogQL rules" loki_rules

grafana() {
  curl -fsS --max-time 10 --user "admin:$GRAFANA_PASSWORD" "http://127.0.0.1:3000$1"
}
wait_for 120 "Grafana answers with the password from the secret file" grafana /api/health

uids=$(grafana /api/datasources | jq -r '[.[].uid] | sort | join(",")')
[ "$uids" = "alertmanager,loki,prometheus" ] || die "Grafana data sources are $uids"
pass "Grafana has the three provisioned data sources"

datasource_ok() {
  grafana "/api/datasources/uid/$1/health" | jq --exit-status '.status == "OK"' >/dev/null
}
wait_for 60 "Grafana reaches Prometheus" datasource_ok prometheus
wait_for 60 "Grafana reaches Loki" datasource_ok loki

grafana /api/dashboards/uid/plex-exporter >/dev/null || die "the plex-exporter dashboard was not loaded"
pass "Grafana loaded the downloaded dashboard"

prom_query() {
  curl -fsS --get --data-urlencode "query=$1" http://127.0.0.1:9090/api/v1/query \
    | jq --exit-status '.data.result | length > 0' >/dev/null
}
wait_for 180 "Alloy scrapes plex-exporter, which runs in its own compose project, into Prometheus" prom_query 'up{job="plex-exporter"} == 1'
wait_for 180 "Alloy's probe of plex-exporter's health page succeeds" prom_query 'probe_success{container="plex-exporter"} == 1'

prom_rules() {
  curl -fsS http://127.0.0.1:9090/api/v1/rules \
    | jq --exit-status '[.data.groups[].name] | index("plex-exporter") != null' >/dev/null
}
wait_for 60 "Prometheus loaded the shipped PromQL rules" prom_rules

retention="$(curl -fsS http://127.0.0.1:9090/api/v1/status/flags | jq -r '.data["storage.tsdb.retention.time"]')"
[ "$retention" = 15d ] || die "Prometheus keeps metrics for $retention, want the 15d compose.yaml sets"
pass "Prometheus keeps metrics for the 15d compose.yaml sets"

loki_logs() {
  curl -fsS --get --data-urlencode 'query={container="plex-exporter"}' \
    --data-urlencode "start=$(($(date +%s) - 900))000000000" \
    http://127.0.0.1:3100/loki/api/v1/query_range \
    | jq --exit-status '.data.result | length > 0' >/dev/null
}
wait_for 180 "Alloy ships plex-exporter logs into Loki" loki_logs
