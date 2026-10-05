#!/usr/bin/env bash
# Starts a container named alert-test that logs "alert test", then stays up for two minutes.
# Alloy reads that line, Loki's AlertTest rule fires and Alertmanager sends the alert.
set -euo pipefail

docker run --rm --detach --name alert-test busybox:1.37.0 sh -c 'echo "alert test"; sleep 120'
echo "The test alert should reach you within three minutes."
