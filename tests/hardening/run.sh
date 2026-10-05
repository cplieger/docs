#!/usr/bin/env bash
# Boots examples/hardening, checks Docker applied every option, and proves knell
# read its token from the secret file.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../lib.sh"

use_example hardening examples/hardening

mkdir -p "$WORK/secrets"
openssl rand -hex 16 >"$WORK/secrets/beat_token"
# A well-formed address that is never called: knell posts only when a beat misses its 26 h deadline.
printf 'https://discord.com/api/webhooks/0/example\n' >"$WORK/secrets/discord_webhook_url"
# The guide's step 4, as written.
chmod 600 "$WORK"/secrets/*
sudo chown 65534:65534 "$WORK"/secrets/*
for file in "$WORK"/secrets/*; do
  mode="$(stat -c '%a %u:%g' "$file")"
  [ "$mode" = "600 65534:65534" ] || die "$(basename "$file") is $mode, want 600 65534:65534"
done
pass "both secret files are mode 600 and owned by knell's user"

compose up --detach --quiet-pull --wait --wait-timeout 120
pass "knell is healthy with the full hardening profile"

inspect() {
  docker inspect --format "$1" knell
}
# check_tmp_mount LINE passes when a /proc/<pid>/mounts line is the tmpfs the example asks for.
# The kernel writes size=16m as size=16384k.
check_tmp_mount() {
  local mountpoint type options want
  [ "$(wc -l <<<"$1")" -eq 1 ] || return 1
  read -r _ mountpoint type options _ <<<"$1"
  [ "$mountpoint" = /tmp ] && [ "$type" = tmpfs ] || return 1
  for want in rw noexec nosuid nodev size=16384k mode=1777; do
    case ",$options," in
      *",$want,"*) ;;
      *) return 1 ;;
    esac
  done
}
expect() {
  local what="$1" format="$2" want="$3" got
  got="$(inspect "$format")"
  [ "$got" = "$want" ] || die "$what is $got, want $want"
  pass "$what is $want"
}
expect "the root filesystem" '{{.HostConfig.ReadonlyRootfs}}' true
expect "the dropped capabilities" '{{json .HostConfig.CapDrop}}' '["ALL"]'
expect "the added capabilities" '{{json .HostConfig.CapAdd}}' null
expect "the security options" '{{json .HostConfig.SecurityOpt}}' '["no-new-privileges:true"]'
expect "the user" '{{.Config.User}}' 65534:65534
expect "the memory limit" '{{.HostConfig.Memory}}' 67108864
expect "the process limit" '{{.HostConfig.PidsLimit}}' 64
expect "the CPU limit" '{{.HostConfig.NanoCpus}}' 500000000
expect "the tmpfs Docker was asked for" '{{json .HostConfig.Tmpfs}}' '{"/tmp":"rw,noexec,nosuid,nodev,size=16m,mode=1777"}'

# Read the mount the kernel really made inside the container, from the host.
pid="$(inspect '{{.State.Pid}}')"
tmp_mount="$(sudo awk '$2 == "/tmp"' "/proc/$pid/mounts")"
check_tmp_mount "$tmp_mount" || die "/tmp inside the container is: ${tmp_mount:-not mounted}"
pass "/tmp inside the container is a 16 MiB tmpfs with noexec, nosuid, nodev and mode 1777"
expect "the port binding" '{{json .HostConfig.PortBindings}}' '{"9190/tcp":[{"HostIp":"127.0.0.1","HostPort":"9190"}]}'

beat() {
  curl --silent --output /dev/null --write-out '%{http_code}' --request POST \
    --header "Authorization: Bearer $1" http://127.0.0.1:9190/beat/nightly-backup
}
code="$(beat "$(sudo cat "$WORK/secrets/beat_token")")"
[ "$code" = 200 ] || die "a beat with the token from the secret file got $code"
pass "knell accepted the token it read from /run/secrets/beat_token"
code="$(beat wrong-token-of-sixteen-bytes)"
[ "$code" = 401 ] || die "a beat with a wrong token got $code"
pass "knell refuses a wrong token"
