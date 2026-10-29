#!/usr/bin/env bash
# Smoke test of the bench server: one request to each location.
#
#   MONGOL_LIB=<driver>/lib bench/smoke.sh
#
# Needs a Mongo server with auth on (MONGO_INITDB_ROOT_USERNAME=admin,
# MONGO_INITDB_ROOT_PASSWORD=admin) at MONGO_HOST:MONGO_PORT, and nginx,
# resty and curl in PATH. The seed always uses the new driver of this
# checkout (SEED_LIB, default bench/../lib).
set -Eeuo pipefail

: "${MONGOL_LIB:?set MONGOL_LIB to the directory that holds resty/mongol/}"
BENCH_DIR=$(cd "$(dirname "$0")" && pwd)
SEED_LIB=${SEED_LIB:-$(dirname "$BENCH_DIR")/lib}
MONGOL_LIB=$(cd "$MONGOL_LIB" && pwd)
export MONGOL_LIB BENCH_DIR SEED_LIB
export MONGO_HOST=${MONGO_HOST:-127.0.0.1}
export MONGO_PORT=${MONGO_PORT:-27017}
export MONGO_ADMIN_USER=${MONGO_ADMIN_USER:-admin}
export MONGO_ADMIN_PASSWORD=${MONGO_ADMIN_PASSWORD:-admin}
URL=http://127.0.0.1:8090

APIS="ping find_one find_100 count insert_1 insert_100 update delete_insert
find_and_modify gridfs_read auth connect_nopool reuse"

WORK=$(mktemp -d)
export WORK

# shellcheck disable=SC2317,SC2329 # called by the trap
stop() {
  local rc=$?
  trap - EXIT INT TERM
  if ! "$BENCH_DIR/ctl.sh" stop; then rc=1; fi
  rm -rf -- "${WORK:?}"
  exit "$rc"
}
trap stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
check() {
  if [[ $2 == 0 ]]; then
    echo "ok - $1"
  else
    echo "not ok - $1"
    failed=1
  fi
}

status() {
  curl -s -o /dev/null -w '%{http_code}' "$URL/$1"
}

seed() {
  "$BENCH_DIR/ctl.sh" seed
}

drop_read() {
  resty -I "$SEED_LIB" -e '
    local mongol = require "resty.mongol"
    local conn = mongol:new()
    assert(conn:connect(os.getenv("MONGO_HOST"), tonumber(os.getenv("MONGO_PORT"))))
    assert(conn:new_db_handle("admin"):auth(os.getenv("MONGO_ADMIN_USER"),
                                            os.getenv("MONGO_ADMIN_PASSWORD")))
    assert(conn:new_db_handle("bench"):get_col("read"):drop())
  '
}

"$BENCH_DIR/ctl.sh" start
seed

# smoke: all 200 (501: the old driver cannot run this API, see
# old_unsupported in handlers.lua)
rc=0
for api in $APIS; do
  code=$(status "$api")
  if [[ $code == 501 ]]; then
    echo "# /$api not supported by this driver: $(curl -s "$URL/$api")"
  elif [[ $code != 200 ]]; then
    echo "# /$api returned $code"
    rc=1
  fi
done
check "smoke: all 200" $rc

# smoke: empty collection
drop_read
code=$(status find_one)
rc=0
[[ $code == 500 ]] || rc=1
check "smoke: empty collection (/find_one returned $code)" $rc

# smoke: seed twice
rc=0
seed || rc=1
seed || rc=1
code=$(status find_one)
[[ $code == 200 ]] || rc=1
reused=$(curl -s "$URL/reuse")
[[ ${reused:-0} -gt 0 ]] || rc=1
check "smoke: seed twice (/find_one returned $code, reused $reused)" $rc

errors=$(grep -c '\[error\]' "$WORK/logs/error.log" || true)
echo "# error.log: $errors [error] lines (1 expected, from the empty collection)"
grep -E '\[(error|crit|alert|emerg)\]' "$WORK/logs/error.log" | grep -v 'find_one: no document' | sed 's/^/# /' || true
[[ $errors == 1 ]] || failed=1

exit $failed
