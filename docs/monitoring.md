# Monitoring and alerts

This page shows how to get alerts, metrics and dashboards for the cplieger container images. It is for anyone who runs them with Docker Compose and has never set up monitoring before.

## Why you need a stack for notifications

Most cplieger apps publish a metrics page and ship alert rules for it. Apps that open no port by default also ship log rules. knell and marotte also notify you on their own, through Discord and browser push. A separate set of tools reads the metrics and the logs, checks them against the alert rules, and sends you a notification when a rule matches.

The tools on this page are all free and open source:

- [Grafana Alloy](https://grafana.com/docs/alloy/latest/) reads each app's metrics page and the logs of every container on your host.
- [Prometheus](https://prometheus.io/docs/introduction/overview/) stores the metrics and checks the metric alert rules.
- [Loki](https://grafana.com/docs/loki/latest/) stores the logs. Its ruler checks the log alert rules once a minute.
- [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) groups the alerts and sends them to a webhook, Discord or email.
- [Grafana](https://grafana.com/docs/grafana/latest/) shows dashboards built from the metrics and the logs.

Start with Alloy, Prometheus, Loki and Alertmanager. Prometheus checks the apps' metric rules, Loki checks their log rules, and Alertmanager sends you the alerts. Every app with a metrics page ships a metric rule that alerts when the app stops answering, and only a metric store such as Prometheus can check that rule. Add Grafana when you want dashboards. If you already run [VictoriaMetrics](https://docs.victoriametrics.com/) with vmalert, or [Grafana Mimir](https://grafana.com/docs/mimir/latest/), it loads the same metric rule files in place of Prometheus.

## The starting stack

This stack runs Alloy, Prometheus, Loki and Alertmanager. It reads the logs of every container on the same host, so your apps need no change for their log rules. To copy it to your host, run `git clone https://github.com/cplieger/docs.git`, then `cp -r docs/examples/monitoring/stack monitoring`. The `monitoring` folder then holds the files below, with the same names and subfolders.

`compose.yaml`:

<!-- include: examples/monitoring/stack/compose.yaml -->

```yaml
# Alerts from metrics and logs. Alloy reads each app's metrics page and every container's log.
# Prometheus and Loki check the alert rules, and Alertmanager sends the alerts.
# See docs/monitoring.md for every step.
services:
  loki:
    image: grafana/loki:3.7.9
    container_name: loki
    restart: unless-stopped
    command: "-config.file=/etc/loki/config.yaml"
    volumes:
      - "./loki/config.yaml:/etc/loki/config.yaml:ro"
      - "./loki/rules:/etc/loki/rules:ro"  # put log alert rule files in loki/rules/fake
      - "loki-data:/loki"
    ports:
      - "127.0.0.1:3100:3100"  # Loki has no login, so only this host can reach it

  alertmanager:
    image: prom/alertmanager:v0.35.0
    container_name: alertmanager
    restart: unless-stopped
    volumes:
      # Before the first start, create the secret file your alertmanager.yml names,
      # such as alertmanager/webhook_url. docs/monitoring.md shows how.
      - "./alertmanager:/etc/alertmanager:ro"
      - "alertmanager-data:/alertmanager"
    ports:
      - "127.0.0.1:9093:9093"  # the Alertmanager page, from this host only

  alloy:
    image: grafana/alloy:v1.21.3
    container_name: alloy
    restart: unless-stopped
    volumes:
      - "./alloy/config.alloy:/etc/alloy/config.alloy:ro"
      - "alloy-data:/var/lib/alloy/data"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"  # lets Alloy find containers and read their logs

  prometheus:
    image: prom/prometheus:v3.16.0
    container_name: prometheus
    restart: unless-stopped
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"  # how long Prometheus keeps metrics, raise it for a longer history
      - "--web.enable-remote-write-receiver"  # lets Alloy send metrics in
    volumes:
      - "./prometheus:/etc/prometheus:ro"
      - "prometheus-data:/prometheus"
    ports:
      - "127.0.0.1:9090:9090"  # Prometheus has no login, so only this host can reach it

# A fixed name, so an app's own compose file can join this network and Alloy can read its metrics.
networks:
  default:
    name: monitoring

volumes:
  loki-data:
  alertmanager-data:
  alloy-data:
  prometheus-data:
```

<!-- /include -->

Alloy reads container logs through the Docker socket. A program that can reach that socket controls Docker, even with `:ro`, so mount it only into images you trust. [The Docker socket](hardening.md#the-docker-socket) says more.

`alloy/config.alloy` finds every container and sends its log to Loki. Each log stream gets a `container` label with the container's name, which is the label the shipped log alert rules select on. The file also has one `prometheus.scrape` block per app that has a metrics page, which reads the app's metrics and sends them to Prometheus. Its one block reads plex-exporter, the app [Reaching an app's metrics page](#reaching-an-apps-metrics-page) tries the stack with. Change it to your own apps.

<!-- include: examples/monitoring/stack/alloy/config.alloy -->

```alloy
// Find every container on this host.
discovery.docker "containers" {
	host = "unix:///var/run/docker.sock"
}

// Name each log stream after its container. The shipped alert rules select on this "container" label.
discovery.relabel "containers" {
	targets = []

	rule {
		source_labels = ["__meta_docker_container_name"]
		regex         = "/(.*)"
		target_label  = "container"
	}
}

// Read the logs of every container and send them to Loki.
loki.source.docker "containers" {
	host          = "unix:///var/run/docker.sock"
	targets       = discovery.docker.containers.targets
	relabel_rules = discovery.relabel.containers.rules
	forward_to    = [loki.write.local.receiver]
}

loki.write "local" {
	endpoint {
		url = "http://loki:3100/loki/api/v1/push"
	}
}

// Read the metrics of each app that has a metrics port. Add one block per app.
// The job name is the one its shipped alert rules expect.
// Alloy finds the app by its container name on the monitoring network, so the app must join that network.
prometheus.scrape "plex_exporter" {
	job_name   = "plex-exporter"
	targets    = [{"__address__" = "plex-exporter:9594"}]
	forward_to = [prometheus.remote_write.local.receiver]
}

prometheus.remote_write "local" {
	endpoint {
		url = "http://prometheus:9090/api/v1/write"
	}
}
```

<!-- /include -->

`prometheus/prometheus.yml` makes Prometheus check every metric rule file in `prometheus/rules` and send firing alerts to Alertmanager:

<!-- include: examples/monitoring/stack/prometheus/prometheus.yml -->

```yaml
# Prometheus stores the metrics Alloy sends it and checks the metric alert rules.
# It scrapes nothing itself, because Alloy does the scraping.
global:
  evaluation_interval: 1m

rule_files:
  - /etc/prometheus/rules/*.yaml  # put metric alert rule files in prometheus/rules

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
```

<!-- /include -->

`loki/config.yaml` is the config the Loki image ships with, plus four blocks. The ruler reads every rule file in `loki/rules/fake` and sends firing alerts to Alertmanager. The folder is named `fake` because that is the name Loki gives its only user when it runs without logins. The `compactor` and `limits_config` blocks delete logs after 15 days. Without them, Loki keeps every log until the disk is full. The `analytics` block stops Loki sending anonymous usage statistics to Grafana Labs, which it does by default.

<!-- include: examples/monitoring/stack/loki/config.yaml -->

```yaml
# A single Loki for one host, based on the config the Loki image ships.
# The ruler block is what turns log lines into alerts.
auth_enabled: false

server:
  http_listen_port: 3100

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

ruler:
  storage:
    type: local
    local:
      directory: /etc/loki/rules  # Loki reads every file in /etc/loki/rules/fake
  rule_path: /loki/rules-temp
  alertmanager_url: http://alertmanager:9093
  enable_api: true

# Loki keeps logs forever unless retention is on. These two blocks delete logs after 15 days.
compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem

limits_config:
  retention_period: 15d  # how long Loki keeps logs, raise it for a longer history

analytics:
  reporting_enabled: false  # stops Loki sending anonymous usage statistics to Grafana Labs
```

<!-- /include -->

`alertmanager/alertmanager.yml` sends every alert to one webhook:

<!-- include: examples/monitoring/stack/alertmanager/alertmanager.yml -->

```yaml
# Sends every alert to one webhook. docs/monitoring.md shows Discord and email instead.
route:
  receiver: notify
  group_by: [alertname, container]
  group_wait: 30s  # waits this long to collect related alerts into one message
  group_interval: 5m
  repeat_interval: 4h  # reminds you again while an alert keeps firing

receivers:
  - name: notify
    webhook_configs:
      - url_file: /etc/alertmanager/webhook_url  # the file holds your webhook address on one line
```

<!-- /include -->

`loki/rules/fake/alert-test.yaml` is a test rule that fires on demand:

<!-- include: examples/monitoring/stack/loki/rules/fake/alert-test.yaml -->

```yaml
# A test alert. It fires when a container named alert-test logs the words "alert test".
# docs/monitoring.md shows the command that starts that container.
groups:
  - name: alert-test
    rules:
      - alert: AlertTest
        expr: |
          sum by (container) (count_over_time(
            {container="alert-test"} |= `alert test` [10m]
          )) > 0
        for: 0m
        labels:
          severity: info
        annotations:
          summary: "Test alert from the alert-test container"
          description: >
            Loki found the words "alert test" in the alert-test container's log.
            If you got this message, logs reach Loki and alerts reach you.
            It stops firing 10 minutes after the last test line.
```

<!-- /include -->

Then start it:

1. Put the address Alertmanager posts to in `alertmanager/webhook_url`, on one line. Use this when your notification app accepts Alertmanager webhooks. Otherwise use Discord or email, shown in [Choosing where notifications go](#choosing-where-notifications-go).
2. Run `chmod 600 alertmanager/webhook_url`, then `sudo chown 65534:65534 alertmanager/webhook_url`. Alertmanager runs as user 65534, so it can read the address and no other account on the host can, apart from root.
3. Run `docker compose up -d` in the folder.
4. Run `docker compose logs loki`. You should see `msg="Loki started"` and no line that says `unable to read rule dir`.
5. Run `curl -s http://localhost:9090/-/ready` on the host. The answer says that Prometheus is ready.

Alertmanager must also be able to read `alertmanager/alertmanager.yml`. A file you create with a text editor usually is readable by everyone. If Alertmanager logs `permission denied`, run `chmod 644 alertmanager/alertmanager.yml`.

Prometheus keeps metrics for 15 days, set by `--storage.tsdb.retention.time` in `compose.yaml`. For a longer history, raise it, for example to `90d`, then run `docker compose up -d`. To keep logs longer, raise `retention_period` in `loki/config.yaml` the same way, then run `docker compose restart loki`. Consider [Grafana Mimir](https://grafana.com/docs/mimir/latest/) if you want metrics from many hosts in one place. Alloy can also collect CPU and memory use per container with its [cAdvisor component](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.cadvisor/), which needs a privileged container.

### Sending a test alert

`test-alert.sh` starts a short-lived container that writes the words the test rule looks for:

<!-- include: examples/monitoring/stack/test-alert.sh -->

```sh
#!/usr/bin/env bash
# Starts a container named alert-test that logs "alert test", then stays up for two minutes.
# Alloy reads that line, Loki's AlertTest rule fires and Alertmanager sends the alert.
set -euo pipefail

docker run --rm --detach --name alert-test busybox:1.37.0 sh -c 'echo "alert test"; sleep 120'
echo "The test alert should reach you within three minutes."
```

<!-- /include -->

Run `bash test-alert.sh`. Within about three minutes the alert `AlertTest` reaches your webhook. To see it in Alertmanager, run `curl -s http://localhost:9093/api/v2/alerts` on the host. To open the Alertmanager page instead, run `ssh -L 9093:localhost:9093 <you>@<host>` on your computer and open `http://localhost:9093` there. If nothing arrives, run `docker compose logs alertmanager` and look for a line with `level=ERROR`, which names the problem with your webhook.

### If you run Loki and no Prometheus

Earlier versions of this guide started with Alloy, Loki and Alertmanager only. That stack still sends the alerts of the rules that read an app's log. It sends no alert from a rule that reads an app's metrics, and nothing on it tells you that an app with a metrics page stopped answering. This table lists what each app's shipped rules give that stack today:

| On a stack with Loki and no Prometheus | Apps |
| --- | --- |
| Every alert the app ships | cert-converter, docker-fclones-scheduler, docker-keepalived, docker-nut-upsd, docker-radvd, docker-renovate-scheduler, docker-smtp-relay, forge-scout, pg-autodump, plex-language-sync, seadex-scout |
| The log alerts only, and no alert when the app stops answering | docker-caddy, knell, plex-exporter |
| No alert, because every rule the app ships needs Prometheus | subflux |

The other cplieger apps ship no alert rules. To get every alert, move to the starting stack as the next section shows.

### Coming from the logs-only stack

These steps add Prometheus to a stack you set up with Alloy, Loki and Alertmanager. Your `loki` and `alertmanager` folders and the two scripts stay as they are.

1. In the folder you cloned this repository into, run `git pull`, or clone it again.
2. From that folder, run `cp -r docs/examples/monitoring/stack/prometheus monitoring/`.
3. Copy `docs/examples/monitoring/stack/compose.yaml` over `monitoring/compose.yaml`, and `docs/examples/monitoring/stack/alloy/config.alloy` over `monitoring/alloy/config.alloy`. Carry over any change you made to your copies first.
4. In `alloy/config.alloy`, keep one `prometheus.scrape` block per app that has a metrics page, as [Reaching an app's metrics page](#reaching-an-apps-metrics-page) explains.
5. Fetch each of those apps' metric rules, as [Loading metric alert rules](#loading-metric-alert-rules) shows.
6. Run `docker compose up -d` in the `monitoring` folder.

The new `compose.yaml` names the stack's network `monitoring`, so `docker compose up -d` recreates the containers on it. Your logs and alerts stay in their volumes.

## Loading an app's alert rules

Every cplieger app that ships alert rules keeps them in its repository's `alerts/` folder. `alerts/logql.yaml` holds the log rules for Loki, and `alerts/promql.yaml` holds the metric rules for Prometheus. Each file loads in only one of the two, so put each in its own folder. A few apps with one or two rules show them in their `docs/monitoring.md` page instead. Copy that block into a new file in `loki/rules/fake`, such as `loki/rules/fake/pg-autodump.yaml`. Metric rules load into Prometheus, as [Loading metric alert rules](#loading-metric-alert-rules) explains. The app's README links its monitoring page, which explains each rule.

`fetch.sh` downloads a rule file or a dashboard into the right folder. Run it from the folder that holds `compose.yaml`. Its first word is the app's repository name on GitHub, such as `knell` or `docker-caddy`. A failed download leaves the file you had in place.

<!-- include: examples/monitoring/stack/fetch.sh -->

```sh
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
```

<!-- /include -->

For example, `bash fetch.sh knell logql` saves `loki/rules/fake/knell.yaml`. Loki picks up new and changed rule files within a minute, with no restart. To pin the rules to the version of the app you run, add the version, as in `bash fetch.sh knell logql v2.2.1`.

The log rules select on `{container="<name>"}`, where `<name>` is the `container_name` in the app's example compose file. That name can differ from the repository name. docker-caddy's container is named `caddy`, for example. If you named the container differently, change the name in the rule file too. Thresholds and time windows in the rules are starting points that you can change. Every rule carries a `severity` label of `info`, `warning` or `critical`, so you can route by it in Alertmanager.

To check that Loki loaded the file, run `curl -s http://localhost:3100/loki/api/v1/rules` on the host. Each loaded group is listed by name. A file Loki cannot read is reported in `docker compose logs loki`.

## Choosing where notifications go

Alertmanager sends notifications to receivers. These two files are complete replacements for `alertmanager/alertmanager.yml`. Each keeps its secret in a file next to it, so the secret stays out of the config. Give that file to user 65534 with `chmod 600` and `sudo chown`, as in step 2 of the starting stack.

Discord, with the webhook address from the channel's Integrations settings in `alertmanager/discord_webhook_url`:

<!-- include: examples/monitoring/receivers/discord.yml -->

```yaml
# Sends every alert to a Discord channel. Save it as alertmanager/alertmanager.yml.
# Put the channel's webhook address in alertmanager/discord_webhook_url, on one line.
route:
  receiver: discord
  group_by: [alertname, container]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: discord
    discord_configs:
      - webhook_url_file: /etc/alertmanager/discord_webhook_url
```

<!-- /include -->

Email, with your mail account's password in `alertmanager/smtp_password`:

<!-- include: examples/monitoring/receivers/email.yml -->

```yaml
# Sends every alert by email. Save it as alertmanager/alertmanager.yml.
# Put your mail account's password in alertmanager/smtp_password, on one line.
route:
  receiver: email
  group_by: [alertname, container]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: email
    email_configs:
      - to: "you@example.com"
        from: "alerts@example.com"
        smarthost: "smtp.example.com:587"  # your mail provider's server and port
        auth_username: "alerts@example.com"
        auth_password_file: /etc/alertmanager/smtp_password
```

<!-- /include -->

After you change the file, run `docker compose restart alertmanager`. Alertmanager supports more receivers, such as Slack, Telegram and Pushover. The [Alertmanager configuration reference](https://prometheus.io/docs/alerting/latest/configuration/#receiver-integration-settings) lists them all.

## Reaching an app's metrics page

Alloy reads an app's metrics page by the app's container name. Compose gives each compose file its own network, so Alloy cannot reach an app in another folder until the app joins the stack's network. The starting stack names its network `monitoring` for that. Logs need no network, because Alloy reads them through the Docker socket.

To try it, run plex-exporter from its own folder with this file. You need no Plex Media Server or token for this. The file points plex-exporter at an address where no Plex server answers, so it reports Plex as unreachable, but it still serves its metrics page and writes logs. For real Plex statistics, set your server's address and token as [plex-exporter's quick start](https://github.com/cplieger/plex-exporter#quick-start) explains.

<!-- include: examples/monitoring/plex-exporter/compose.yaml -->

```yaml
# plex-exporter in its own folder, an app with metrics and a dashboard to try the stack with.
# It joins the monitoring network that the starting stack creates, so Alloy can read its metrics.
# Run the starting stack first. See docs/monitoring.md.
services:
  plex-exporter:
    image: ghcr.io/cplieger/plex-exporter:latest
    container_name: plex-exporter
    restart: unless-stopped
    # No Plex server answers at this address, so plex-exporter reports Plex as unreachable.
    # It still serves its metrics page and writes logs, which is enough to try the stack.
    environment:
      PLEX_URL: "http://plex.invalid:32400"  # a name ending in .invalid never resolves
      PLEX_TOKEN: "placeholder"  # not a real token, so this file holds no secret
    networks:
      - monitoring

networks:
  monitoring:
    external: true  # created by the starting stack's compose.yaml
```

<!-- /include -->

1. Run `cp -r docs/examples/monitoring/plex-exporter plex-exporter` from the folder you cloned this repository into.
2. Run `docker compose up -d` in the `plex-exporter` folder, after the starting stack is up.
3. Run `curl -s 'http://localhost:9090/api/v1/query?query=up'` on the host. Within two minutes, the answer includes `"job":"plex-exporter"` with the value `"1"`, which means Alloy reaches its metrics page.

If you load plex-exporter's alert rules, as [Loading metric alert rules](#loading-metric-alert-rules) explains, two of them fire because no Plex server answers. `PlexExporterAPIUnreachable` fires after ten minutes, and `PlexExporterCollectionErrors` after thirty.

For your own apps, add the same `networks:` lines to each app's compose file, and a `prometheus.scrape` block to `alloy/config.alloy`. Use the job name the app's alert rules expect, which its monitoring page names. If the app has an `ALLOWED_HOSTS` setting, or `allowed_hosts` in subflux's config, add the app's container name to that list. Otherwise the app refuses the scrape, and its down alert fires.

## Loading metric alert rules

Apps with a metrics page ship `alerts/promql.yaml`. Run `bash fetch.sh <repository> promql` to save it in `prometheus/rules`. Prometheus reads rule files only when it starts or reloads, so run `docker compose restart prometheus` afterwards. The rules use the `job` label from your scrape block, so keep the job name the rule file names. Firing metric alerts go to the same Alertmanager as the log alerts.

## Adding dashboards

Grafana shows dashboards built from the metrics and the logs. Run it in the same folder as the starting stack. From the folder you cloned this repository into, run `cp -r docs/examples/monitoring/grafana/. monitoring/`. That replaces `compose.yaml` with the file below, which is the starting stack plus Grafana, and adds the `grafana` folder. The other folders and the two scripts stay as they are.

`compose.yaml`:

<!-- include: examples/monitoring/grafana/compose.yaml -->

```yaml
# The starting stack plus Grafana, for dashboards.
# Copy it over the starting stack's folder. It replaces compose.yaml and adds the grafana folder.
# See docs/monitoring.md for every step.
services:
  loki:
    image: grafana/loki:3.7.9
    container_name: loki
    restart: unless-stopped
    command: "-config.file=/etc/loki/config.yaml"
    volumes:
      - "./loki/config.yaml:/etc/loki/config.yaml:ro"
      - "./loki/rules:/etc/loki/rules:ro"  # put log alert rule files in loki/rules/fake
      - "loki-data:/loki"
    ports:
      - "127.0.0.1:3100:3100"  # Loki has no login, so only this host can reach it

  alertmanager:
    image: prom/alertmanager:v0.35.0
    container_name: alertmanager
    restart: unless-stopped
    volumes:
      # Before the first start, create the secret file your alertmanager.yml names,
      # such as alertmanager/webhook_url. docs/monitoring.md shows how.
      - "./alertmanager:/etc/alertmanager:ro"
      - "alertmanager-data:/alertmanager"
    ports:
      - "127.0.0.1:9093:9093"  # the Alertmanager page, from this host only

  alloy:
    image: grafana/alloy:v1.21.3
    container_name: alloy
    restart: unless-stopped
    volumes:
      - "./alloy/config.alloy:/etc/alloy/config.alloy:ro"
      - "alloy-data:/var/lib/alloy/data"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"  # lets Alloy find containers and read their logs

  prometheus:
    image: prom/prometheus:v3.16.0
    container_name: prometheus
    restart: unless-stopped
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"  # how long Prometheus keeps metrics, raise it for a longer history
      - "--web.enable-remote-write-receiver"  # lets Alloy send metrics in
    volumes:
      - "./prometheus:/etc/prometheus:ro"
      - "prometheus-data:/prometheus"
    ports:
      - "127.0.0.1:9090:9090"  # Prometheus has no login, so only this host can reach it

  grafana:
    image: grafana/grafana:13.3.0
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_PASSWORD__FILE: "/run/secrets/grafana_admin_password"
    secrets:
      - grafana_admin_password
    volumes:
      - "./grafana/provisioning:/etc/grafana/provisioning:ro"
      - "./grafana/dashboards:/etc/grafana/dashboards:ro"  # put dashboard files here
      - "grafana-data:/var/lib/grafana"
    ports:
      - "3000:3000"  # open Grafana from another device, it asks for a login

# A fixed name, so an app's own compose file can join this network and Alloy can read its metrics.
networks:
  default:
    name: monitoring

secrets:
  grafana_admin_password:
    file: ./secrets/grafana_admin_password  # create it before the first start, see docs/monitoring.md

volumes:
  loki-data:
  alertmanager-data:
  alloy-data:
  prometheus-data:
  grafana-data:
```

<!-- /include -->

`grafana/provisioning/datasources/datasources.yaml` connects Grafana to Prometheus, Loki and Alertmanager when it first starts:

<!-- include: examples/monitoring/grafana/grafana/provisioning/datasources/datasources.yaml -->

```yaml
# Grafana connects to these three on its first start, so you set nothing up in its pages.
# Shipped dashboards pick Prometheus or Loki from their own data source menu.
apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true

  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100

  - name: Alertmanager
    uid: alertmanager
    type: alertmanager
    access: proxy
    url: http://alertmanager:9093
    jsonData:
      implementation: prometheus
```

<!-- /include -->

`grafana/provisioning/dashboards/dashboards.yaml` loads every dashboard file in `grafana/dashboards`:

<!-- include: examples/monitoring/grafana/grafana/provisioning/dashboards/dashboards.yaml -->

```yaml
# Grafana loads every dashboard file in grafana/dashboards and checks the folder for changes.
apiVersion: 1

providers:
  - name: dashboards
    type: file
    allowUiUpdates: false
    updateIntervalSeconds: 60
    options:
      path: /etc/grafana/dashboards
```

<!-- /include -->

Then start it:

1. Create the `secrets` folder and put a password for Grafana's `admin` user in `secrets/grafana_admin_password`, on one line. Run `chmod 600 secrets/grafana_admin_password`, then `sudo chown 472:0 secrets/grafana_admin_password`. Grafana runs as user 472, so it can read the password and no other account on the host can, apart from root.
2. Run `docker compose up -d`.
3. Open `http://<your-host>:3000` from another device, for example `http://192.0.2.10:3000`, and log in as `admin` with that password.

Grafana reads the password only when it creates its database on the first start. To change it later, use your profile page in Grafana.

## Importing an app's dashboard

Apps with a dashboard attach `grafana-dashboard.json` to every release. Run `bash fetch.sh <repository> dashboard` to save it in `grafana/dashboards`, and Grafana loads it within a minute. Most dashboards have a data source menu at the top, set to Prometheus or Loki. Each one works with the provisioned data sources as they are.

To import one by hand instead, download `grafana-dashboard.json` from the app's latest GitHub release. In Grafana, open **Dashboards**, then **New**, then **Import**, and upload the file.
