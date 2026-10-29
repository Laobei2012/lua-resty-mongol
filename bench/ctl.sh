#!/usr/bin/env bash
# Server-side controls. WORK must be shared with the load host.
set -Eeuo pipefail
[[ ${TRACE:-0} == 1 ]] && set -x

BENCH_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
WORK=${WORK:-$BENCH_DIR}
mkdir -p -- "$WORK"
WORK=$(cd -- "$WORK" && pwd)
SEED_LIB=${SEED_LIB:-$(dirname -- "$BENCH_DIR")/lib}
URL=${URL:-http://127.0.0.1:8090}
export BENCH_DIR WORK
export MONGO_HOST=${MONGO_HOST:-127.0.0.1}
export MONGO_PORT=${MONGO_PORT:-27017}
export MONGO_ADMIN_USER=${MONGO_ADMIN_USER:-admin}
export MONGO_ADMIN_PASSWORD=${MONGO_ADMIN_PASSWORD:-admin}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
usage() {
  printf 'Usage: %s <start|stop|seed|check-log|check-conns|check-reuse>\n' "$0" >&2
}
need() { command -v "$1" > /dev/null || die "$1 is required"; }
status() { resty -I "$SEED_LIB" "$BENCH_DIR/server_status.lua" "$@"; }
check_log() {
  [[ -f $WORK/logs/error.log ]] || die "missing error.log"
  if grep -E '\[(error|crit|alert|emerg)\]' "$WORK/logs/error.log" >&2; then
    die "nginx error log is not clean"
  else
    [[ $? == 1 ]] || die "cannot read error.log"
  fi
}
main() {
  case ${1:-} in
    -h | --help)
      usage
      return
      ;;
    start)
      need nginx
      need envsubst
      need resty
      need git
      need curl
      : "${MONGOL_LIB:?set MONGOL_LIB to the driver lib directory}"
      MONGOL_LIB=$(cd -- "$MONGOL_LIB" && pwd)
      export MONGOL_LIB
      [[ ! -f $WORK/logs/nginx.pid ]] || die "nginx already has a pid file"
      mkdir -p -- "$WORK/conf" "$WORK/logs" "$WORK/results"
      # Never carry metadata or errors from another driver/server into a pass.
      rm -f -- "$WORK/driver_sha" "$WORK/mongo_version"
      : > "$WORK/logs/error.log"
      local sha version
      sha=$(git -C "$MONGOL_LIB" rev-parse HEAD)
      [[ $sha =~ ^[a-f0-9]{40}$ ]] || die "invalid driver SHA"
      version=$(status --version)
      [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "invalid Mongo version"
      # shellcheck disable=SC2016 # substitute only template variables
      envsubst '$MONGOL_LIB $BENCH_DIR' < "$BENCH_DIR/nginx.conf.in" \
        > "$WORK/conf/nginx.conf"
      nginx -p "$WORK/" -c conf/nginx.conf -t
      nginx -p "$WORK/" -c conf/nginx.conf
      printf '%s\n' "$sha" > "$WORK/driver_sha"
      printf '%s\n' "$version" > "$WORK/mongo_version"
      # /connect_nopool does not need the bench user before seed.
      local ready=0 i
      for ((i = 0; i < 50; i++)); do
        if curl --silent --show-error --fail --max-time 2 \
          "$URL/connect_nopool" > /dev/null; then
          ready=1
          break
        fi
        sleep 0.1
      done
      [[ $ready == 1 ]] || die "nginx did not become ready"
      check_log
      ;;
    stop)
      need nginx
      if [[ -f $WORK/logs/nginx.pid ]]; then
        nginx -p "$WORK/" -c conf/nginx.conf -s quit
        local i
        for ((i = 0; i < 100; i++)); do
          [[ -f $WORK/logs/nginx.pid ]] || return 0
          sleep 0.1
        done
        die "nginx did not stop"
      fi
      ;;
    seed)
      need resty
      resty -I "$SEED_LIB" "$BENCH_DIR/seed.lua"
      local count
      count=$(status --read-count)
      [[ $count == 1000 ]] || die "read fixture count is $count, expected 1000"
      ;;
    check-log) check_log ;;
    check-conns)
      need resty
      local count
      count=$(status)
      [[ $count =~ ^[0-9]+$ ]] || die "invalid connection count: $count"
      ((count <= 105)) || die "connections.current $count exceeds 105"
      printf '%s\n' "$count"
      ;;
    check-reuse)
      need curl
      local count
      count=$(curl --silent --show-error --fail --max-time 10 "$URL/reuse")
      [[ $count =~ ^[0-9]+$ ]] || die "invalid reuse count: $count"
      ((count > 0)) || die "socket was not reused"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}
main "$@"
