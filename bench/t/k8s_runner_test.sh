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
if [[ ${1:-} == get && ${2:-} == node ]]; then
  [[ ${5:-} == 'jsonpath={.status.allocatable.cpu}' ]]
  case ${SCENARIO:-} in
    missing-node) exit 1 ;;
    missing-cpu) exit 0 ;;
    invalid-cpu) printf '1500u' ;;
    bench-low)
      if [[ $3 == bench-fixture ]]; then printf '2999m'; else printf '2'; fi ;;
    mongo-low) printf '1999m' ;;
    integer-low) printf '2' ;;
    capacity-units)
      if [[ $3 == bench-fixture ]]; then printf '3'; else printf '2000m'; fi ;;
    *)
      if [[ $3 == bench-fixture ]]; then printf '3000m'; else printf '2'; fi ;;
  esac
elif [[ ${1:-} == create ]]; then
  [[ ${SCENARIO:-} != existing ]] || exit 1
  printf 'owned-uid'
elif [[ " $* " == *' get service mongo '* ]]; then
  printf '192.0.2.1'
elif [[ ${1:-} == get && ${2:-} == namespace ]]; then
  if [[ ${SCENARIO:-} == changed ]]; then printf 'other-uid'; else printf 'owned-uid'; fi
elif [[ ${1:-} == -n && ${3:-} == cp ]]; then
  [[ ${SCENARIO:-} != copy-fail && ${SCENARIO:-} != fallback ]] || exit 1
elif [[ " $* " == *' tar -C /work '* ]]; then
  [[ ${SCENARIO:-} != copy-fail ]] || exit 1
  tar -cf - -T /dev/null
elif [[ ${SCENARIO:-} == load-fail && " $* " == *'/load.sh '* ]]; then
  exit 1
fi
MOCK
cat > "$TEMPORARY/bin/resty" << 'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'resty %s\n' "$*" >> "$CALLS"
printf 'mock report\n'
if [[ ${SCENARIO:-} == threshold && ${2:-} != --trend ]]; then exit 1; fi
MOCK
chmod +x "$TEMPORARY/bin/"*
export PATH="$TEMPORARY/bin:$PATH"
export KUBE_CONTEXT=fixture-context MONGO_NODE=mongo-fixture BENCH_NODE=bench-fixture
export NEW_REF=1111111111111111111111111111111111111111
export OLD_REF=2222222222222222222222222222222222222222
export CALLS="$TEMPORARY/calls" SCENARIO=
run_case() {
  SCENARIO=$1
  : > "$CALLS"
  local expected=$2 rc=0
  "$TEMPORARY/bench/k8s/run-k8s.sh" all > "$TEMPORARY/output" 2>&1 || rc=$?
  [[ $rc == "$expected" ]] || {
    cat -- "$TEMPORARY/output"
    exit 1
  }
}
for scenario in bench-low mongo-low integer-low missing-node missing-cpu invalid-cpu; do
  run_case "$scenario" 1
  if grep -q 'create namespace' "$CALLS"; then exit 1; fi
done
run_case capacity-units 0
grep -q 'create namespace mongol-bench' "$CALLS"
run_case threshold 1
# Six alternating A/B passes, then all four trends, despite failed comparison.
actual=$(awk '/\/ctl.sh start/ {for(i=1;i<=NF;i++) if($i ~ /^MONGOL_LIB=/) print $i}' "$CALLS")
expected=$(printf 'MONGOL_LIB=/src/%s/lib\n' old new old new old new new new new new)
[[ $actual == "$expected" ]]
[[ $(grep -c '/load.sh ' "$CALLS") == 120 ]]
[[ $(grep -c 'RUN_BASE=2 .* /src/new/bench/load.sh\|RUN_BASE=2 /src/new/bench/load.sh' "$CALLS") == 24 ]]
[[ $(grep -c '/load.sh new-9.0 .* 3$' "$CALLS") == 12 ]]
grep -q 'resty .*compare.lua --trend' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
# Collection must precede namespace deletion.
awk '/ cp / {copied=1} /delete namespace/ {if(!copied) exit 1}' "$CALLS"
run_case load-fail 1
grep -q ' cp ' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
run_case copy-fail 1
grep -q 'delete namespace mongol-bench' "$CALLS"
grep -q 'saved diagnostics' "$TEMPORARY/output"
run_case fallback 0
grep -q 'tar -C /work' "$CALLS"
grep -q 'delete namespace mongol-bench' "$CALLS"
run_case existing 1
if grep -q 'delete namespace' "$CALLS"; then exit 1; fi
run_case changed 1
if grep -q 'delete namespace' "$CALLS"; then exit 1; fi
unset KUBE_CONTEXT
rc=0
"$TEMPORARY/bench/k8s/run-k8s.sh" all > /dev/null 2>&1 || rc=$?
[[ $rc == 2 ]]
printf 'Kubernetes runner mock tests passed\n'
