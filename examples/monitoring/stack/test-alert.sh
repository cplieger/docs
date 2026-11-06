#!/usr/bin/env bash
# Sends two test alerts, one from a log line and one from a metric rule.
# A container named alert-test logs "alert test" and stays up for two minutes,
# so Alloy reads that line and Loki's AlertTest rule fires.
# prometheus/alert-test.yaml goes into prometheus/rules for three minutes,
# so Prometheus's MetricAlertTest rule fires. Run it from the folder that holds compose.yaml.
set -euo pipefail

docker run --rm --detach --name alert-test busybox:1.37.0 sh -c 'echo "alert test"; sleep 120'

# Prometheus reads its rule files again when it gets the HUP signal.
remove_metric_rule() {
  rm -f prometheus/rules/alert-test.yaml
  docker kill --signal HUP prometheus >/dev/null
}
trap remove_metric_rule EXIT
cp prometheus/alert-test.yaml prometheus/rules/alert-test.yaml
chmod 644 prometheus/rules/alert-test.yaml
docker kill --signal HUP prometheus >/dev/null

echo "Both test alerts should reach you within three minutes."
echo "This script waits that long, then removes the metric test rule."
sleep 180
