#!/usr/bin/env bash
# Exercise orchestration and cleanup without contacting Kubernetes.
set -Eeuo pipefail
BENCH_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
TEMPORARY=$(mktemp -d)
trap 'rm -rf -- "${TEMPORARY:?}"' EXIT
mkdir -p -- "$TEMPORARY/bench/k8s" "$TEMPORARY/bin"
cp -- "$BENCH_DIR/k8s/"* "$TEMPORARY/bench/k8s/"
cat > "$TEMPORARY/bin/kubectl" << 'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$CALLS"
[[ $1 == --context && $2 == fixture-context ]]
shift 2
if [[ ${1:-} == get && ${2:-} == nodes ]]; then
  [[ ${3:-} == -l && ${4:-} == kubernetes.io/hostname=*-fixture ]]
  [[ ${6:-} == 'jsonpath={range .items[*]}{"["}{.status.allocatable.cpu}{"]"}{end}' ]]
  case ${SCENARIO:-} in
    missing-node) exit 1 ;;
    no-match) exit 0 ;;
    multiple-matches) printf '[1000m][1000m]' ;;
    multiple-missing-cpu) printf '[1000m][]' ;;
    missing-cpu) printf '[]' ;;
    invalid-cpu) printf '[1500u]' ;;
    bench-low)
      if [[ $4 == kubernetes.io/hostname=bench-fixture ]]; then printf '[1099m]'; else printf '[1000m]'; fi ;;
    mongo-low) printf '[999m]' ;;
    integer-low) printf '[0]' ;;
    capacity-units)
      if [[ $4 == kubernetes.io/hostname=bench-fixture ]]; then printf '[2]'; else printf '[1000m]'; fi ;;
    hostname-diff)
      # The matching objects have metadata.name values unrelated to these labels.
      if [[ $4 == kubernetes.io/hostname=bench-fixture ]]; then printf '[1100m]'; else printf '[1]'; fi ;;
    *)
      if [[ $4 == kubernetes.io/hostname=bench-fixture ]]; then printf '[1100m]'; else printf '[1000m]'; fi ;;
  esac
elif [[ ${1:-} == describe ]]; then
  [[ $2 == nodes && $3 == -l && $4 == kubernetes.io/hostname=*-fixture ]]
  case ${SCENARIO:-} in
    reservations-unreadable) exit 1 ;;
    reservations-missing) printf 'Allocated resources:\n'; exit 0 ;;
    mongo-reserved) reserved=1m ;;
    bench-reserved) if [[ $4 == kubernetes.io/hostname=bench-fixture ]]; then reserved=1m; else reserved=0m; fi ;;
    *) reserved=0m ;;
  esac
  printf 'Allocated resources:\n  Resource  Requests  Limits\n  cpu  %s (0%%)  2 (100%%)\nEvents:\n' "$reserved"
elif [[ ${1:-} == create ]]; then
  [[ ${SCENARIO:-} != existing ]] || exit 1
  printf 'owned-uid'
elif [[ " $* " == *' get service mongo '* ]]; then
  printf '192.0.2.1'
elif [[ ${1:-} == get && ${2:-} == namespace ]]; then
  if [[ $# == 3 ]]; then
    case ${SCENARIO:-} in
      leftover) exit 0 ;;
      namespace-forbidden)
        printf 'Error from server (Forbidden): fixture namespace access denied\n' >&2
        exit 1
        ;;
      namespace-transport)
        printf 'Unable to connect to the server: fixture connection refused\n' >&2
        exit 1
        ;;
      *)
        printf 'Error from server (NotFound): namespaces "mongol-bench" not found\n' >&2
        exit 1
        ;;
    esac
  fi
  if [[ ${SCENARIO:-} == changed ]]; then printf 'other-uid'; else printf 'owned-uid'; fi
elif [[ " $* " == *' nginx -v '* ]]; then
  printf 'nginx version: openresty/1.31.1.1\n' >&2
elif [[ " $* " == *'wrk --version'* ]]; then
  if [[ ${SCENARIO:-} == wrk-transport-fail ]]; then
    printf 'wrk debian/4.1.0-3build1 [epoll] Copyright (C) 2012 Will Glozer\n'
    exit 1
  fi
  while [[ $1 != -- ]]; do shift; done
  shift
  "$@"
elif [[ ${SCENARIO:-} == delete-fail && ${1:-} == delete ]]; then
  exit 1
elif [[ " $* " == *'cat /sys/fs/cgroup/cpu.stat'* ]]; then
  [[ ${SCENARIO:-} != diagnostics-unavailable ]] || exit 1
  printf 'cgroup v2\nusage_usec 100\nnr_periods 10\nnr_throttled 1\nthrottled_usec 20\n'
elif [[ ${1:-} == -n && ${3:-} == cp ]]; then
  [[ ${SCENARIO:-} != copy-fail && ${SCENARIO:-} != fallback ]] || exit 1
elif [[ " $* " == *' tar -C /work '* ]]; then
  [[ ${SCENARIO:-} != copy-fail ]] || exit 1
  tar -cf - -T /dev/null
elif [[ ${SCENARIO:-} == load-fail && " $* " == *'/load.sh '* ]]; then
  exit 1
fi
MOCK
cat > "$TEMPORARY/bin/wrk" << 'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $* == --version ]]
case ${SCENARIO:-} in
  wrk-empty) exit 1 ;;
  wrk-malformed) printf 'wrk 4.1.0invalid [epoll]\n' ;;
  wrk-upstream) printf 'wrk 4.1.0 [epoll] Copyright (C) 2012 Will Glozer\n' ;;
  *) printf 'wrk debian/4.1.0-3build1 [epoll] Copyright (C) 2012 Will Glozer\n' ;;
esac
case ${SCENARIO:-} in
  wrk-zero) exit 0 ;;
  wrk-fail) exit 2 ;;
  *) exit 1 ;;
esac
MOCK
cat > "$TEMPORARY/bin/resty" << 'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'resty %s\n' "$*" >> "$CALLS"
printf 'mock report\n'
if [[ ${SCENARIO:-} == no-gates ]]; then printf 'No API was gated.\n'; exit 1; fi
if [[ ${SCENARIO:-} == threshold && ${2:-} != --trend ]]; then exit 1; fi
if [[ ${SCENARIO:-} == invalid-compare && ${2:-} != --trend ]]; then exit 2; fi
MOCK
chmod +x "$TEMPORARY/bin/"*
export PATH="$TEMPORARY/bin:$PATH"
export KUBE_CONTEXT=fixture-context MONGO_NODE=mongo-fixture BENCH_NODE=bench-fixture
export NEW_REF=1111111111111111111111111111111111111111
export OLD_REF=2222222222222222222222222222222222222222
export CALLS="$TEMPORARY/calls" SCENARIO=
CASES_RUN=0
run_case() {
  CASES_RUN=$((CASES_RUN + 1))
  SCENARIO=$1
  : > "$CALLS"
  local expected=$2 rc=0
  "$TEMPORARY/bench/k8s/run-k8s.sh" "${TEST_MODE:-all}" > "$TEMPORARY/output" 2>&1 || rc=$?
  [[ $rc == "$expected" ]] || {
    printf 'Scenario %s: expected exit %s, got %s\n' "$SCENARIO" "$expected" "$rc" >&2
    cat -- "$TEMPORARY/output"
    exit 1
  }
}
for scenario in namespace-forbidden namespace-transport; do
  run_case "$scenario" 1
  case $scenario in
    namespace-forbidden) grep -q 'fixture namespace access denied' "$TEMPORARY/output" ;;
    namespace-transport) grep -q 'fixture connection refused' "$TEMPORARY/output" ;;
    *) exit 1 ;;
  esac
  if grep -qE 'get nodes|describe nodes|create namespace|delete namespace' "$CALLS"; then exit 1; fi
done
run_case leftover 1
grep -q 'namespace mongol-bench already exists' "$TEMPORARY/output"
if grep -qE 'get nodes|describe nodes|create namespace|delete namespace' "$CALLS"; then exit 1; fi
for scenario in bench-low mongo-low integer-low missing-node missing-cpu \
  invalid-cpu no-match multiple-matches multiple-missing-cpu mongo-reserved bench-reserved \
  reservations-unreadable reservations-missing; do
  run_case "$scenario" 1
  if grep -q 'create namespace' "$CALLS"; then exit 1; fi
done
for scenario in wrk-empty wrk-malformed wrk-fail wrk-transport-fail; do
  expected=1
  if [[ $scenario == wrk-fail ]]; then expected=2; fi
  run_case "$scenario" "$expected"
  result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
  [[ ! -e $result_dir/COMPLETE ]]
  if grep -q '/load.sh ' "$CALLS"; then exit 1; fi
  grep -q 'delete namespace mongol-bench' "$CALLS"
done
for scenario in wrk-upstream wrk-zero; do
  run_case "$scenario" 0
  result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
  [[ $(cat -- "$result_dir/tool-versions.json") == '{"openresty":"1.31.1.1","wrk":"4.1.0"}' ]]
  [[ $(cat -- "$result_dir/COMPLETE") == all ]]
  [[ $(grep -c '/load.sh ' "$CALLS") == 120 ]]
done
run_case hostname-diff 0
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
[[ $(cat -- "$result_dir/namespace-uid") == owned-uid ]]
[[ $(cat -- "$result_dir/tool-versions.json") == '{"openresty":"1.31.1.1","wrk":"4.1.0"}' ]]
[[ $(grep -c '/load.sh ' "$CALLS") == 120 ]]
grep -q 'get nodes -l kubernetes.io/hostname=mongo-fixture' "$CALLS"
grep -q 'get nodes -l kubernetes.io/hostname=bench-fixture' "$CALLS"
grep -q 'create namespace mongol-bench' "$CALLS"
run_case capacity-units 0
grep -q 'create namespace mongol-bench' "$CALLS"
run_case threshold 1
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
[[ $(cat -- "$result_dir/COMPLETE") == all ]]
# Six alternating A/B passes, then all four trends, despite failed comparison.
actual=$(awk '/\/ctl.sh start/ {for(i=1;i<=NF;i++) if($i ~ /^MONGOL_LIB=/) print $i}' "$CALLS")
expected=$(printf 'MONGOL_LIB=/src/%s/lib\n' old new old new old new new new new new)
[[ $actual == "$expected" ]]
[[ $(grep -c '/load.sh ' "$CALLS") == 120 ]]
[[ $(grep -c 'RUN_BASE=2 .* /src/new/bench/load.sh\|RUN_BASE=2 /src/new/bench/load.sh' "$CALLS") == 24 ]]
[[ $(grep -c '/load.sh new-9.0 .* 3$' "$CALLS") == 12 ]]
[[ $(grep -c 'cat /sys/fs/cgroup/cpu.stat' "$CALLS") == 720 ]]
# Nginx brackets load: last before it, first after it, on every API/pass.
awk 'BEGIN {split("mongo wrk nginx nginx wrk mongo", expected, " ")}
  / exec / {for(i=1;i<=NF;i++) if($i == "-c") {container=$(i+1); break}}
  /cat \/sys\/fs\/cgroup\/cpu.stat/ {
    if(container != expected[samples % 6 + 1]) exit 1
    samples++
  }
  END {if(samples != 720) exit 1}' "$CALLS"
# Each load has three container snapshots before it and three after it.
awk '/cat \/sys\/fs\/cgroup\/cpu.stat/ {samples++}
  /\/load.sh / {if(samples != 3) exit 1; samples=-3}
  END {if(samples != 0) exit 1}' "$CALLS"
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
grep -q '^sample_time_epoch ' "$result_dir/cpu/old-1-ping-before-nginx.stat"
grep -q '^usage_usec ' "$result_dir/cpu/new-9.0-connect_nopool-after-mongo.stat"
grep -q 'resty .*compare.lua --trend' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
# Collection must precede namespace deletion.
awk '/ cp / {copied=1} /delete namespace/ {if(!copied) exit 1}' "$CALLS"
run_case load-fail 1
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
[[ ! -e $result_dir/COMPLETE ]]
[[ $(grep -c 'cat /sys/fs/cgroup/cpu.stat' "$CALLS") == 6 ]]
grep -q ' cp ' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
run_case copy-fail 1
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
[[ ! -e $result_dir/COMPLETE ]]
grep -q 'delete namespace mongol-bench' "$CALLS"
grep -q 'saved diagnostics' "$TEMPORARY/output"
run_case fallback 0
grep -q 'tar -C /work' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
run_case existing 1
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
[[ ! -e $result_dir/namespace-uid ]]
if grep -q 'delete namespace' "$CALLS"; then exit 1; fi
run_case changed 1
if grep -q 'delete namespace' "$CALLS"; then exit 1; fi
for scenario in delete-fail invalid-compare; do
  expected=1
  if [[ $scenario == invalid-compare ]]; then expected=2; fi
  run_case "$scenario" "$expected"
  result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
  [[ ! -e $result_dir/COMPLETE ]]
done
run_case diagnostics-unavailable 0
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
grep -q '^unavailable: ' "$result_dir/cpu/old-1-ping-before-nginx.stat"
grep -q '^unavailable: ' "$result_dir/cpu/new-9.0-connect_nopool-after-mongo.stat"
[[ $(grep -c '/load.sh ' "$CALLS") == 120 ]]
grep -q 'delete namespace mongol-bench' "$CALLS"
unset KUBE_CONTEXT
rc=0
"$TEMPORARY/bench/k8s/run-k8s.sh" all > /dev/null 2>&1 || rc=$?
[[ $rc == 2 ]]
export KUBE_CONTEXT=fixture-context TEST_MODE=calibrate WRK_THREADS=2 WRK_CONNECTIONS=16
run_case calibration 0
result_dir=$(awk '/^Results: / {sub(/^Results: /, ""); print}' "$TEMPORARY/output")
[[ $(cat -- "$result_dir/COMPLETE") == calibrate ]]
[[ $(grep -c '/load.sh ' "$CALLS") == 12 ]]
actual=$(awk '/\/ctl.sh start/ {for(i=1;i<=NF;i++) if($i ~ /^MONGOL_LIB=/) print $i}' "$CALLS")
[[ $actual == "$(printf 'MONGOL_LIB=/src/%s/lib\n' old new old new old new)" ]]
for connections in 8 16 32; do
  [[ $(grep -c "WRK_CONNECTIONS=$connections .*load.sh" "$CALLS") == 4 ]]
  grep -q "compare.lua .*--single.*old-c$connections.jsonl.*new-c$connections.jsonl" "$CALLS"
done
if grep -qE 'bson_micro|compare.lua --trend|delete pod mongo' "$CALLS"; then exit 1; fi
grep -q 'delete namespace mongol-bench' "$CALLS"
run_case namespace-notfound 0
grep -q 'create namespace mongol-bench' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
run_case no-gates 1
grep -q 'No API was gated' "$TEMPORARY/output"
[[ $(grep -c '/load.sh ' "$CALLS") == 12 ]]
grep -q ' cp ' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
unset TEST_MODE
for setting in WRK_CONNECTIONS=0 WRK_THREADS=abc; do
  : > "$CALLS"
  rc=0
  env "$setting" "$TEMPORARY/bench/k8s/run-k8s.sh" ab > "$TEMPORARY/output" 2>&1 || rc=$?
  [[ $rc == 2 && ! -s $CALLS ]]
done
# Explicit custom bounds; no dependence on the calibration exports above.
: > "$CALLS"
rc=0
env WRK_THREADS=17 WRK_CONNECTIONS=16 "$TEMPORARY/bench/k8s/run-k8s.sh" ab > "$TEMPORARY/output" 2>&1 || rc=$?
[[ $rc == 2 && ! -s $CALLS ]]
: > "$CALLS"
rc=0
env WRK_THREADS=9 WRK_CONNECTIONS=32 "$TEMPORARY/bench/k8s/run-k8s.sh" calibrate > "$TEMPORARY/output" 2>&1 || rc=$?
[[ $rc == 2 && ! -s $CALLS ]]
grep -q 'calibration requires WRK_THREADS <= 8' "$TEMPORARY/output"
printf 'Kubernetes runner mock tests passed: %s scenarios plus 5 argument checks\n' "$CASES_RUN"
