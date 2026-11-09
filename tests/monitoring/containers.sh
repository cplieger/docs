#!/usr/bin/env bash
# Boots examples/monitoring/stack with examples/monitoring/containers copied over
# it, the way the guide tells a reader to, and proves both container rules reach
# the webhook: ContainerRestarting for a container that keeps restarting, and
# KernelOutOfMemoryKill once oom-worker runs out of memory.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

use_example monitoring-containers examples/monitoring/stack examples/monitoring/containers
# Compose reads compose.override.yaml on its own; lib.sh names every file, so it is added here.
COMPOSE_FILES+=("$WORK/compose.override.yaml")
add_override tests/monitoring/containers.compose.yaml

printf 'http://sink:8080/\n' >"$WORK/alertmanager/webhook_url"
chmod 600 "$WORK/alertmanager/webhook_url"
sudo chown 65534:65534 "$WORK/alertmanager/webhook_url"

compose up --detach --quiet-pull
wait_for 60 "Prometheus is ready" http_ok http://127.0.0.1:9090/-/ready

# has_series QUERY: Prometheus answers QUERY with at least one series.
has_series() {
  curl -fsS --get --data-urlencode "query=$1" http://127.0.0.1:9090/api/v1/query \
    | jq --exit-status '.data.result | length > 0' >/dev/null
}
wait_for 180 "cAdvisor reports the crash-loop container" has_series 'container_start_time_seconds{name="crash-loop"}'
wait_for 180 "Alloy reports the kernel's out-of-memory count under its fixed hostname" has_series 'node_vmstat_oom_kill{job="integrations/unix", instance="alloy"}'

# sink_has ALERTNAME CONTAINER: the webhook received that alert, firing, with that container label.
sink_has() {
  curl -fsS http://127.0.0.1:8080/ | jq --exit-status --arg a "$1" --arg c "$2" \
    '[.[] | select(.status == "firing") | .alerts[] | select(.labels.alertname == $a and .labels.container == $c)] | length > 0' \
    >/dev/null
}
# sink_fired ALERTNAME: the webhook received that alert, firing. For a host alert, which has no container label.
sink_fired() {
  curl -fsS http://127.0.0.1:8080/ | jq --exit-status --arg a "$1" \
    '[.[] | select(.status == "firing") | .alerts[] | select(.labels.alertname == $a)] | length > 0' \
    >/dev/null
}
wait_for 600 "the webhook received ContainerRestarting for crash-loop" sink_has ContainerRestarting crash-loop
wait_for 300 "the webhook received KernelOutOfMemoryKill" sink_fired KernelOutOfMemoryKill
