#!/usr/bin/env bash
# Deterministic control/load checks; no nginx, Mongo or timed load required.
set -Eeuo pipefail
BENCH_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEMPORARY=$(mktemp -d)
trap 'rm -rf -- "${TEMPORARY:?}"' EXIT
trap 'cat "$WORK/logs/"*.log >&2' ERR
export WORK=$TEMPORARY/work
export TEST_CALLS=$TEMPORARY/calls TEST_BENCH_DIR=$BENCH_DIR
mkdir -p -- "$TEMPORARY/bin" "$WORK/logs" "$WORK/results"
export PATH=$TEMPORARY/bin:$PATH
command -v lua > /dev/null
cat > "$TEMPORARY/bin/curl" << 'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${*: -1} in
  */reuse) printf '%s' "${TEST_REUSE:-3}" ;;
  *) printf '%s' "${TEST_CODE:-200}" ;;
esac
STUB
cat > "$TEMPORARY/bin/resty" << 'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${*: -1} in
  --read-count) printf '%s\n' "${TEST_COUNT:-1000}" ;;
  --version) printf '4.4.29\n' ;;
  */seed.lua) printf 'seed\n' >> "$TEST_CALLS" ;;
  *) printf '%s\n' "${TEST_CONNS:-35}" ;;
esac
STUB
cat > "$TEMPORARY/bin/wrk" << 'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$TEST_CALLS"
if [[ ${TEST_MODE:-ok} == log ]]; then
  printf '[error] fixture failure\n' >> "$WORK/logs/error.log"
fi
mode=${TEST_MODE:-ok}
if [[ $mode == later_socket && $BENCH_RUN == 2 ]]; then mode=socket; fi
lua "$TEST_BENCH_DIR/t/wrk_report_test.lua" \
  "$TEST_BENCH_DIR/wrk_report.lua" "$mode"
STUB
chmod +x "$TEMPORARY/bin/"*
reset_work() {
  rm -f -- "$WORK/results/test.jsonl"
  : > "$WORK/logs/error.log"
  : > "$TEST_CALLS"
  printf '%040d\n' 1 > "$WORK/driver_sha"
  printf '4.4.29\n' > "$WORK/mongo_version"
}
fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}
expect_failure() {
  if "$@" > "$TEMPORARY/output" 2>&1; then
    fail "unexpected success: $*"
  fi
}
reset_work
RUN_BASE=2 "$BENCH_DIR/load.sh" test find_one 3
[[ $(wc -l < "$WORK/results/test.jsonl") -eq 3 ]] || fail 'three results'
for run in 3 4 5; do
  grep -q '"run":'"$run" "$WORK/results/test.jsonl" || fail 'run numbering'
done
grep -q '"rps":60.000000,"p50_ms":50.000000' \
  "$WORK/results/test.jsonl" || fail 'report units'
grep -q '"driver_sha":"0000000000000000000000000000000000000001"' \
  "$WORK/results/test.jsonl" || fail 'driver identity'
grep -q '"mongo_version":"4.4.29"' \
  "$WORK/results/test.jsonl" || fail 'server identity'
[[ $(grep -c -- '-t1 -c8 --timeout 10s -d30s --latency' "$TEST_CALLS") == 3 ]] \
  || fail 'measured defaults'
[[ $(grep -c -- '-t1 -c8 --timeout 10s -d10s --latency' "$TEST_CALLS") == 1 ]] \
  || fail 'warmup defaults'
printf 'ok - report, run numbering, metadata and load defaults\n'
for mode in redirect socket status empty log; do
  reset_work
  expect_failure env TEST_MODE="$mode" "$BENCH_DIR/load.sh" test ping 1
  [[ ! -e $WORK/results/test.jsonl ]] || fail "$mode wrote results"
done
printf 'ok - HTTP redirects/status, socket errors, empty runs and logs invalidate load\n'
reset_work
expect_failure env TEST_MODE=later_socket "$BENCH_DIR/load.sh" test ping 2
[[ ! -e $WORK/results/test.jsonl ]] || fail 'partial API results appended'
printf 'ok - failed later run discards earlier staged API results\n'
reset_work
TEST_CODE=501 "$BENCH_DIR/load.sh" test find_100 1
[[ ! -e $WORK/results/test.jsonl && ! -s $TEST_CALLS ]] || fail '501 skip'
expect_failure env TEST_CODE=500 "$BENCH_DIR/load.sh" test ping 1
printf 'ok - unsupported APIs skipped and HTTP failures rejected\n'
reset_work
"$BENCH_DIR/ctl.sh" seed
"$BENCH_DIR/ctl.sh" seed
[[ $(grep -c '^seed$' "$TEST_CALLS") == 2 ]] || fail 'seed twice'
expect_failure env TEST_COUNT=999 "$BENCH_DIR/ctl.sh" seed
"$BENCH_DIR/ctl.sh" check-conns > /dev/null
expect_failure env TEST_CONNS=106 "$BENCH_DIR/ctl.sh" check-conns
"$BENCH_DIR/ctl.sh" check-reuse
expect_failure env TEST_REUSE=0 "$BENCH_DIR/ctl.sh" check-reuse
"$BENCH_DIR/ctl.sh" check-log
printf '[error] failed\n' > "$WORK/logs/error.log"
expect_failure "$BENCH_DIR/ctl.sh" check-log
printf 'ok - reseed count, connection limit, reuse and error checks\n'
# Exercise the full coordinator without starting services or waiting for load.
cat > "$TEMPORARY/bin/nginx" << 'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *' -s quit')
    printf 'stop\n' >> "$TEST_CALLS"
    rm -f -- "$WORK/logs/nginx.pid"
    ;;
  *' -t') ;;
  *) printf '123\n' > "$WORK/logs/nginx.pid" ;;
esac
STUB
cat > "$TEMPORARY/bin/envsubst" << 'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
cat
STUB
chmod +x "$TEMPORARY/bin/nginx" "$TEMPORARY/bin/envsubst"
reset_work
MONGOL_LIB=$BENCH_DIR/../lib RUNS=1 \
  "$BENCH_DIR/run.sh" test find_one ping > "$TEMPORARY/output" 2>&1
[[ $(wc -l < "$WORK/results/test.jsonl") -eq 2 ]] || fail 'coordinator output'
[[ $(grep -c '^seed$' "$TEST_CALLS") == 2 ]] || fail 'reseed per API'
[[ $(grep -c '^stop$' "$TEST_CALLS") == 1 ]] || fail 'stop on success'
[[ ! -e $WORK/logs/nginx.pid ]] || fail 'nginx pid cleanup'
reset_work
expect_failure env MONGOL_LIB="$BENCH_DIR/../lib" TEST_MODE=socket RUNS=1 \
  "$BENCH_DIR/run.sh" test find_one ping
[[ $(grep -c '^stop$' "$TEST_CALLS") == 1 ]] || fail 'stop on failure'
[[ ! -e $WORK/results/test.jsonl ]] || fail 'coordinator failure output'
printf 'ok - coordinator reseeds each API and stops on success/failure\n'
