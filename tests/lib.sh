# shellcheck shell=bash
# Helpers for the example tests. Each test copies its example into a scratch
# folder, so a run never writes into examples/.

DOCS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOCS_ROOT
OUT="$DOCS_ROOT/tests/.out"
COMPOSE_FILES=()
PROJECT=""
WORK=""
CLEANUP_FUNCS=()
EXTRA_PROJECTS=()
EXTRA_DIRS=()

die() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok: $*"
}

# wait_for SECONDS DESCRIPTION COMMAND... retries COMMAND every 5 s.
wait_for() {
  local limit="$1" what="$2"
  shift 2
  local end=$((SECONDS + limit))
  until "$@"; do
    ((SECONDS < end)) || die "timed out after ${limit}s waiting for $what"
    sleep 5
  done
  pass "$what"
}

compose() {
  local args=(--project-name "$PROJECT")
  local f
  for f in "${COMPOSE_FILES[@]}"; do
    args+=(--file "$f")
  done
  docker compose "${args[@]}" "$@"
}

# On failure the logs go to tests/.out for the workflow to upload. The stacks
# and their volumes are removed either way, the extra projects first, because
# they use a network the main project created.
finish() {
  local rc=$?
  local i
  for i in "${!EXTRA_PROJECTS[@]}"; do
    if [ "$rc" -ne 0 ]; then
      mkdir -p "$OUT"
      project "${EXTRA_PROJECTS[$i]}" logs --no-color --timestamps >"$OUT/${EXTRA_PROJECTS[$i]}.log" 2>&1 || true
    fi
    project "${EXTRA_PROJECTS[$i]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf "${EXTRA_DIRS[$i]}" 2>/dev/null || true
  done
  if [ -n "$PROJECT" ]; then
    if [ "$rc" -ne 0 ]; then
      mkdir -p "$OUT"
      compose ps --all >"$OUT/$PROJECT.ps.txt" 2>&1 || true
      compose logs --no-color --timestamps >"$OUT/$PROJECT.log" 2>&1 || true
    fi
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  local fn
  for fn in "${CLEANUP_FUNCS[@]}"; do
    "$fn" || true
  done
  if [ -n "$WORK" ]; then
    # Containers may leave root-owned files here. The runner discards them anyway.
    rm -rf "$WORK" 2>/dev/null || true
  fi
  exit "$rc"
}

# use_example PROJECT EXAMPLE_DIR... copies each folder, in order, into one
# scratch folder whose compose.yaml becomes the first compose file.
use_example() {
  PROJECT="$1"
  shift
  WORK="$(mktemp -d)"
  trap finish EXIT
  local dir
  for dir in "$@"; do
    cp -R "$DOCS_ROOT/$dir/." "$WORK/"
  done
  chmod -R a+rX "$WORK"
  COMPOSE_FILES=("$WORK/compose.yaml")
}

# add_project PROJECT EXAMPLE_DIR copies one more example folder into its own
# scratch folder, to run as a separate compose project, the way a reader runs
# an app from its own folder. Call it after use_example.
add_project() {
  local dir
  dir="$(mktemp -d)"
  EXTRA_PROJECTS+=("$1")
  EXTRA_DIRS+=("$dir")
  cp -R "$DOCS_ROOT/$2/." "$dir/"
  chmod -R a+rX "$dir"
}

# project PROJECT ARGS... runs docker compose for a project add_project copied.
project() {
  local name="$1" i
  shift
  for i in "${!EXTRA_PROJECTS[@]}"; do
    if [ "${EXTRA_PROJECTS[$i]}" = "$name" ]; then
      docker compose --project-name "$name" --file "${EXTRA_DIRS[$i]}/compose.yaml" "$@"
      return
    fi
  done
  die "no project named $name"
}

# add_override FILE adds a test-only compose file that adds services and
# never changes one the guide shows.
add_override() {
  COMPOSE_FILES+=("$DOCS_ROOT/$1")
}

http_ok() {
  curl -fsS --max-time 5 -o /dev/null "$1"
}
