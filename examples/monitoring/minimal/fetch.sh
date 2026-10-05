#!/usr/bin/env bash
# Downloads the alert rules or the dashboard a cplieger app ships, into the right folder.
# Run it from the folder that holds your compose.yaml.
#   bash fetch.sh <repository> logql       log alert rules, for Loki
#   bash fetch.sh <repository> promql      metric alert rules, for Prometheus
#   bash fetch.sh <repository> dashboard   the Grafana dashboard of the latest release
# <repository> is the app's repository name on GitHub, such as knell or docker-caddy.
# Add a version tag such as v2.2.1 after the kind to download that release instead of the newest files.
set -euo pipefail

app="${1:?usage: fetch.sh <repository> logql|promql|dashboard [version]}"
kind="${2:?usage: fetch.sh <repository> logql|promql|dashboard [version]}"
version="${3:-}"

# The first word becomes part of a folder path and a web address, so it must be one plain name.
case "$app" in
  . | .. | *[!A-Za-z0-9._-]*)
    echo "The first word must be a repository name, such as knell." >&2
    exit 2
    ;;
esac

case "$kind" in
  logql)
    dest="loki/rules/fake/$app.yaml"
    url="https://raw.githubusercontent.com/cplieger/$app/${version:-main}/alerts/logql.yaml"
    ;;
  promql)
    dest="prometheus/rules/$app.yaml"
    url="https://raw.githubusercontent.com/cplieger/$app/${version:-main}/alerts/promql.yaml"
    ;;
  dashboard)
    dest="grafana/dashboards/$app.json"
    if [ -n "$version" ]; then
      url="https://github.com/cplieger/$app/releases/download/$version/grafana-dashboard.json"
    else
      url="https://github.com/cplieger/$app/releases/latest/download/grafana-dashboard.json"
    fi
    ;;
  *)
    echo "The second word must be logql, promql or dashboard." >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$dest")"
# Download one folder above the file, where Loki, Prometheus and Grafana read nothing,
# and move it into place only when the download is complete.
# A failed download then never replaces or half-writes a file they read.
tmp="$(mktemp "$(dirname "$(dirname "$dest")")/.fetch.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "$url"
chmod 644 "$tmp"
mv "$tmp" "$dest"
echo "Saved $dest"
