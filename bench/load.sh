#!/usr/bin/env bash
# Client-side load. No resty/nginx required; WORK is shared with ctl.sh.
set -Eeuo pipefail
[[ ${TRACE:-0} == 1 ]] && set -x
BENCH_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WORK=${WORK:-$BENCH_DIR}
URL=${URL:-http://127.0.0.1:8090}
RUN_BASE=${RUN_BASE:-0}
WRK_THREADS=${WRK_THREADS-2}
WRK_CONNECTIONS=${WRK_CONNECTIONS-32}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
usage() { printf 'Usage: %s <label> <api> <runs>\n' "$0" >&2; }
check_log() {
  [[ -f $WORK/logs/error.log ]] || die "missing shared error.log"
  if grep -E '\[(error|crit|alert|emerg)\]' "$WORK/logs/error.log" >&2; then
    die "nginx error log is not clean"
  else
    [[ $? == 1 ]] || die "cannot read shared error.log"
  fi
}
main() {
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    return
  fi
  [[ $# == 3 ]] || {
    usage
    exit 2
  }
  if [[ ! $WRK_THREADS =~ ^[1-9][0-9]*$ || ! $WRK_CONNECTIONS =~ ^[1-9][0-9]*$ ]] \
    || ! awk -v threads="$WRK_THREADS" -v connections="$WRK_CONNECTIONS" 'BEGIN {exit !(threads <= connections)}'; then
    printf 'Error: WRK_THREADS and WRK_CONNECTIONS must be positive integers; threads must not exceed connections\n' >&2
    exit 2
  fi
  local label=$1 api=$2 runs=$3
  [[ $label =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid label"
  case $api in
    ping | find_one | find_100 | count | insert_1 | insert_100 | update | delete_insert | find_and_modify | gridfs_read | auth | connect_nopool) ;;
    *) die "unknown API: $api" ;;
  esac
  [[ $runs =~ ^[1-9][0-9]*$ && $RUN_BASE =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "runs must be positive and RUN_BASE nonnegative integers"
  local command
  for command in curl wrk; do
    command -v "$command" > /dev/null || die "$command is required"
  done
  mkdir -p -- "$WORK/logs" "$WORK/results"
  local code
  code=$(curl --silent --show-error --max-time 30 -o /dev/null \
    -w '%{http_code}' "$URL/$api")
  check_log
  if [[ $code == 501 ]]; then
    printf 'Skipping unsupported API: %s\n' "$api" >&2
    return 0
  fi
  [[ $code == 2[0-9][0-9] ]] || die "/$api returned HTTP $code"
  export BENCH_LABEL=$label BENCH_API=$api
  BENCH_DRIVER_SHA=$(cat -- "$WORK/driver_sha")
  BENCH_MONGO_VERSION=$(cat -- "$WORK/mongo_version")
  [[ $BENCH_DRIVER_SHA =~ ^[a-f0-9]{40}$ ]] || die "invalid driver SHA"
  [[ $BENCH_MONGO_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
    || die "invalid Mongo version"
  export BENCH_DRIVER_SHA BENCH_MONGO_VERSION
  TEMPORARY=$(mktemp -d "$WORK/logs/load.XXXXXXXX")
  trap 'rm -rf -- "${TEMPORARY:?}"' EXIT
  # Warm-up uses the same response/error validation as a measured run.
  export BENCH_RUN=0
  wrk "-t$WRK_THREADS" "-c$WRK_CONNECTIONS" --timeout 10s -d10s --latency -s "$BENCH_DIR/wrk_report.lua" \
    "$URL/$api" > "$WORK/logs/$label-$api-warmup.log" 2>&1
  check_log
  local i report
  for ((i = 1; i <= runs; i++)); do
    export BENCH_RUN=$((RUN_BASE + i))
    report=$WORK/logs/$label-$api-$BENCH_RUN.log
    wrk "-t$WRK_THREADS" "-c$WRK_CONNECTIONS" --timeout 10s -d30s --latency -s "$BENCH_DIR/wrk_report.lua" \
      "$URL/$api" > "$report" 2>&1
    check_log
    # wrk's human summary shares stdout with done(); only keep its JSON.
    [[ $(grep -c '^{' "$report") == 1 ]] || die "missing wrk JSON: $report"
    grep '^{' "$report" >> "$TEMPORARY/results.jsonl"
  done
  check_log
  cat -- "$TEMPORARY/results.jsonl" >> "$WORK/results/$label.jsonl"
}
main "$@"
