#!/usr/bin/env bash
# Issue 103 storage experiment: insert_100 old/new pairs with the Mongo data
# directory on the node disk or in memory. Diagnostic only: CPU requests are
# lowered to fit free capacity, so this is not the approved full-run profile.
set -Eeuo pipefail

: "${KUBE_CONTEXT:?set KUBE_CONTEXT}" "${MONGO_NODE:?set MONGO_NODE}"
: "${BENCH_NODE:?set BENCH_NODE}"
# Blocks of "medium:pairs". Each block restarts Mongo on that volume medium.
PLAN=${PLAN:-disk:3 memory:5 disk:2}
export MONGO_CPU_REQUEST=${MONGO_CPU_REQUEST:-600m}
export NGINX_CPU_REQUEST=${NGINX_CPU_REQUEST:-300m}
export WRK_CPU_REQUEST=${WRK_CPU_REQUEST:-100m}
export OLD_SHA=3eb6349db4d30b11aab271fb14a82b8504f6aa8e
export NEW_SHA=6cf0584ffe3e16008b73d695107e5430820f3159
export MONGO_NODE BENCH_NODE
NS=mongol-bench-103
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
OUT=${OUT:-$HERE/../../results/issue103-storage-$(date -u +%Y%m%dT%H%M%SZ)}
OWNED_UID=
MONGO_HOST=

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
kube() { kubectl --context "$KUBE_CONTEXT" "$@"; }
k() { kube -n "$NS" "$@"; }
ctl() {
  k exec bench -c nginx -- env WORK=/work SEED_LIB=/src/new/lib \
    MONGO_HOST="$MONGO_HOST" "$@"
}
mongo_js() {
  k exec mongo -c mongo -- mongo --quiet -u admin -p admin \
    --authenticationDatabase admin --eval "var SAMPLES=$1" /tools/sampler.js
}
cpu_stat() {
  local pod container
  for target in mongo:mongo bench:nginx bench:wrk; do
    pod=${target%:*}
    container=${target#*:}
    printf '== %s\n' "$container"
    k exec "$pod" -c "$container" -- cat /sys/fs/cgroup/cpu.stat
  done
}
cleanup() {
  local rc=$? uid
  trap - EXIT INT TERM
  if [[ -n $OWNED_UID ]]; then
    k logs mongo > "$OUT/mongo-final.log" 2>&1 || true
    uid=$(kube get namespace "$NS" -o jsonpath='{.metadata.uid}') || uid=
    if [[ $uid == "$OWNED_UID" ]]; then
      kube delete namespace "$NS" --wait=true --timeout=300s || rc=1
    else
      printf 'Namespace ownership changed; refusing cleanup.\n' >&2
      rc=1
    fi
  fi
  printf 'Results: %s\n' "$OUT" >&2
  exit "$rc"
}
start_mongo() {
  local medium=$1 block=$2 attempt
  if k get pod mongo > /dev/null 2>&1; then
    k logs mongo > "$OUT/mongo-block$((block - 1)).log" 2>&1 || true
    ctl /src/new/bench/ctl.sh stop
    k delete pod mongo --wait=true --timeout=300s
  fi
  if [[ $medium == memory ]]; then export MONGO_MEDIUM=Memory; else export MONGO_MEDIUM=; fi
  # shellcheck disable=SC2016 # substitute only template variables
  envsubst '$MONGO_NODE $MONGO_CPU_REQUEST $MONGO_MEDIUM' < "$HERE/mongo.yaml" \
    > "$OUT/mongo-block$block.yaml"
  k apply -f "$OUT/mongo-block$block.yaml"
  k wait --for=condition=Ready pod/mongo --timeout=600s
  k exec -i mongo -c mongo -- sh -c 'cat > /tools/sampler.js' < "$HERE/sampler.js"
  for ((attempt = 1; attempt <= 120; attempt++)); do
    if mongo_js 0 > /dev/null 2>&1; then
      k exec mongo -c mongo -- df -h /data/db > "$OUT/mongo-block$block-df.txt"
      return
    fi
    sleep 2
  done
  die "Mongo did not accept authenticated connections"
}
wrk_run() {
  local seconds=$1 label=$2
  k exec bench -c wrk -- env ISSUE103_BASE_REPORT=/src/new/bench/wrk_report.lua \
    BENCH_LABEL="$label" BENCH_API=insert_100 BENCH_RUN=1 \
    BENCH_MONGO_VERSION="$(ctl cat /work/mongo_version)" \
    BENCH_DRIVER_SHA="$(ctl cat /work/driver_sha)" \
    wrk -t2 -c16 "-d${seconds}s" --timeout 10s --latency -s /work/max_wrk.lua \
    http://127.0.0.1:8090/insert_100
}
sample() {
  local label=$1 side=$2 series_pid
  log "sample $label"
  ctl /src/new/bench/ctl.sh seed
  ctl env MONGOL_LIB="/src/$side/lib" /src/new/bench/ctl.sh start
  wrk_run 10 "$label" > "$OUT/$label-warmup.log"
  mongo_js 0 > "$OUT/$label-before.json"
  cpu_stat > "$OUT/$label-cpu-before.txt"
  mongo_js 32 > "$OUT/$label-series.jsonl" &
  series_pid=$!
  wrk_run 30 "$label" > "$OUT/$label-wrk.log"
  wait "$series_pid"
  cpu_stat > "$OUT/$label-cpu-after.txt"
  mongo_js 0 > "$OUT/$label-after.json"
  grep '^{' "$OUT/$label-wrk.log" | tail -1
  ctl /src/new/bench/ctl.sh check-log
  ctl /src/new/bench/ctl.sh stop
}
main() {
  local block=0 entry medium pairs pair side
  command -v envsubst > /dev/null || die "envsubst is required"
  [[ $MONGO_NODE != "$BENCH_NODE" ]] || die "Mongo and bench nodes must differ"
  if kube get namespace "$NS" > /dev/null 2>&1; then
    die "namespace $NS already exists; refusing to reuse it"
  fi
  mkdir -p -- "$OUT"
  printf 'plan=%s mongo_node=%s bench_node=%s requests=%s/%s/%s\n' "$PLAN" \
    "$MONGO_NODE" "$BENCH_NODE" "$MONGO_CPU_REQUEST" "$NGINX_CPU_REQUEST" \
    "$WRK_CPU_REQUEST" > "$OUT/run.txt"
  trap cleanup EXIT INT TERM
  kube create namespace "$NS"
  OWNED_UID=$(kube get namespace "$NS" -o jsonpath='{.metadata.uid}')
  # shellcheck disable=SC2016 # substitute only template variables
  envsubst '$BENCH_NODE $OLD_SHA $NEW_SHA $NGINX_CPU_REQUEST $WRK_CPU_REQUEST' \
    < "$HERE/bench.yaml" > "$OUT/bench.yaml"
  k apply -f "$OUT/bench.yaml"
  k wait --for=condition=Ready pod/bench --timeout=900s
  k exec -i bench -c nginx -- sh -c 'cat > /work/max_wrk.lua' < "$HERE/../max_wrk.lua"
  MONGO_HOST=
  for entry in $PLAN; do
    block=$((block + 1))
    medium=${entry%%:*}
    pairs=${entry#*:}
    [[ $medium == disk || $medium == memory ]] || die "invalid medium: $medium"
    start_mongo "$medium" "$block"
    MONGO_HOST=$(k get service mongo -o jsonpath='{.spec.clusterIP}')
    for ((pair = 1; pair <= pairs; pair++)); do
      for side in old new; do
        sample "b$block-$medium-p$pair-$side" "$side" | tee -a "$OUT/results.jsonl"
      done
    done
  done
  k logs mongo > "$OUT/mongo-block$block.log" 2>&1 || true
}
main "$@"
