#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${TRACE:-0} == 1 ]] && set -x
BENCH_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
export WORK=${WORK:-$BENCH_DIR}
RUNS=${RUNS:-3}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
usage() { printf 'Usage: %s <label> [api ...]\n' "$0" >&2; }
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if ! "$BENCH_DIR/ctl.sh" stop; then rc=1; fi
  exit "$rc"
}
main() {
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    return
  fi
  (($# > 0)) || {
    usage
    exit 2
  }
  local label=$1 api
  shift
  [[ $label =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid label"
  [[ $RUNS =~ ^[1-9][0-9]*$ ]] || die "RUNS must be positive"
  if (($# == 0)); then
    set -- ping find_one find_100 count insert_1 insert_100 update \
      delete_insert find_and_modify gridfs_read auth connect_nopool
  fi
  for api in "$@"; do
    case $api in
      ping | find_one | find_100 | count | insert_1 | insert_100 | update | delete_insert | find_and_modify | gridfs_read | auth | connect_nopool) ;;
      *) die "unknown API: $api" ;;
    esac
  done
  mkdir -p -- "$WORK/results"
  # A label is one pass; prevent accidental mixing with an earlier pass.
  [[ ! -e $WORK/results/$label.jsonl ]] || die "result label already exists"
  [[ ! -f $WORK/logs/nginx.pid ]] || die "nginx already has a pid file"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  "$BENCH_DIR/ctl.sh" start
  for api in "$@"; do
    "$BENCH_DIR/ctl.sh" seed
    "$BENCH_DIR/load.sh" "$label" "$api" "$RUNS"
    "$BENCH_DIR/ctl.sh" check-log
    "$BENCH_DIR/ctl.sh" check-conns
    if [[ $api == find_one ]]; then
      "$BENCH_DIR/ctl.sh" check-reuse
    fi
  done
}
main "$@"
