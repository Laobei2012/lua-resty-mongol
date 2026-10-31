#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${TRACE:-0} == 1 ]] && set -x

BENCH_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
readonly BENCH_DIR
readonly REPOSITORY=https://github.com/Laobei2012/lua-resty-mongol
readonly NAMESPACE=mongol-bench
APIS=(ping find_one find_100 count insert_1 insert_100 update
  delete_insert find_and_modify gridfs_read auth connect_nopool)
OWNED_UID=
RESULT_DIR=
COLLECTED=0
STATUS=0
FINISHED=0

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
usage() {
  printf 'Usage: KUBE_CONTEXT=... MONGO_NODE=... BENCH_NODE=... NEW_REF=... %s <ab|trend|all|calibrate>\n' "$0" >&2
}
kube() { kubectl --context "$KUBE_CONTEXT" "$@"; }
check_node_cpu() {
  local node=$1 minimum=$2 role=$3 quantity millicores reservations reserved
  quantity=$(kube get nodes -l "kubernetes.io/hostname=$node" \
    -o 'jsonpath={range .items[*]}{"["}{.status.allocatable.cpu}{"]"}{end}') \
    || die "cannot read allocatable CPU for $role hostname $node"
  # Brackets preserve every match, including nodes with a missing CPU value.
  [[ $quantity =~ ^\[([0-9]+m?)\]$ ]] \
    || die "$role hostname $node must match exactly one node with valid allocatable CPU"
  quantity=${BASH_REMATCH[1]}
  if [[ $quantity =~ ^([0-9]+)m$ ]]; then
    millicores=$((10#${BASH_REMATCH[1]}))
  elif [[ $quantity =~ ^[0-9]+$ ]]; then
    millicores=$((10#$quantity * 1000))
  else
    die "missing or invalid allocatable CPU for $role node $node: $quantity"
  fi
  ((millicores >= minimum)) \
    || die "$role node $node has ${millicores}m allocatable CPU; needs at least ${minimum}m"
  # describe reports scheduler-effective requests, including init containers and
  # pod overhead. Select by hostname label, not metadata.name.
  reservations=$(kube describe nodes -l "kubernetes.io/hostname=$node") \
    || die "cannot read current CPU reservations for $role node $node"
  reserved=$(printf '%s\n' "$reservations" | awk '
    /^Allocated resources:/ {allocated=1; next}
    allocated && $1 == "cpu" {print $2; exit}')
  if [[ $reserved =~ ^([0-9]+)m$ ]]; then
    reserved=$((10#${BASH_REMATCH[1]}))
  elif [[ $reserved =~ ^[0-9]+$ ]]; then
    reserved=$((10#$reserved * 1000))
  else
    die "cannot parse current CPU reservations for $role node $node"
  fi
  ((millicores - reserved >= minimum)) \
    || die "$role node $node has $((millicores - reserved))m free CPU after ${reserved}m reserved; pod requests ${minimum}m and would stay Pending"
}
ctl() {
  kube -n "$NAMESPACE" exec bench -c nginx -- env WORK=/work \
    SEED_LIB=/src/new/lib MONGO_HOST="$MONGO_HOST" "$@"
}
control() { ctl /src/new/bench/ctl.sh "$@"; }
resolve_ref() {
  local ref=$1 sha
  if [[ $ref =~ ^[a-f0-9]{40}$ ]]; then
    printf '%s\n' "$ref"
    return
  fi
  if sha=$(git -C "$BENCH_DIR/.." rev-parse --verify "$ref^{commit}" 2> /dev/null); then
    printf '%s\n' "$sha"
    return
  fi
  sha=$(git ls-remote "$REPOSITORY" "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}")
  # Prefer an annotated tag's peeled commit. Reject ambiguous branch/tag names.
  if [[ $sha == *'^{}'* ]]; then
    sha=$(printf '%s\n' "$sha" | awk '/\^\{\}$/ {print $1}')
  else
    sha=$(printf '%s\n' "$sha" | awk '{print $1}')
  fi
  [[ $sha =~ ^[a-f0-9]{40}$ ]] || die "cannot resolve unambiguous ref: $ref"
  printf '%s\n' "$sha"
}
collect() {
  [[ -n $OWNED_UID ]] || return 0
  # Always save diagnostics before attempting deletion, including on failure.
  kube -n "$NAMESPACE" get pods -o yaml > "$RESULT_DIR/pods.yaml" 2>&1 || true
  kube -n "$NAMESPACE" get events -o yaml > "$RESULT_DIR/events.yaml" 2>&1 || true
  local container
  for container in clone nginx wrk; do
    kube -n "$NAMESPACE" logs bench -c "$container" \
      > "$RESULT_DIR/container-$container.log" 2>&1 || true
  done
  kube -n "$NAMESPACE" logs mongo > "$RESULT_DIR/container-mongo.log" 2>&1 || true
  mkdir -p -- "$RESULT_DIR/work"
  if kube -n "$NAMESPACE" cp -c nginx bench:/work/. "$RESULT_DIR/work"; then
    COLLECTED=1
  elif kube -n "$NAMESPACE" exec bench -c nginx -- tar -C /work -cf - . \
    | tar -C "$RESULT_DIR/work" -xf -; then
    COLLECTED=1
  else
    COLLECTED=2
    printf 'Both copy methods failed; saved diagnostics locally before namespace cleanup.\n' >&2
    return 1
  fi
}
cleanup() {
  local rc=$? uid cleaned=0
  trap - EXIT INT TERM ERR
  if [[ -n $OWNED_UID ]]; then
    if ((COLLECTED == 0)); then collect || rc=1; fi
    if ((COLLECTED > 0)); then
      uid=$(kube get namespace "$NAMESPACE" -o jsonpath='{.metadata.uid}') || uid=
      if [[ $uid == "$OWNED_UID" ]]; then
        if kube delete namespace "$NAMESPACE" --wait=true --timeout=180s; then
          cleaned=1
        else
          rc=1
        fi
      else
        printf 'Namespace ownership changed; refusing cleanup.\n' >&2
        rc=1
      fi
    fi
  fi
  if ((FINISHED == 1 && COLLECTED == 1 && cleaned == 1)); then
    printf '%s\n' "$MODE" > "$RESULT_DIR/COMPLETE"
  fi
  printf 'Results: %s\n' "$RESULT_DIR" >&2
  exit "$rc"
}
wait_mongo() {
  kube -n "$NAMESPACE" wait --for=condition=Ready pod/mongo --timeout=600s
  local attempt
  for ((attempt = 1; attempt <= 120; attempt++)); do
    if control check-conns > "$RESULT_DIR/mongo-ready.log" 2>&1; then return; fi
    sleep 2
  done
  die "Mongo did not accept authenticated connections"
}
replace_mongo() {
  export MONGO_TAG=$1
  control stop
  kube -n "$NAMESPACE" logs mongo > "$RESULT_DIR/mongo-before-$MONGO_TAG.log" 2>&1 || true
  kube -n "$NAMESPACE" delete pod mongo --wait=true --timeout=180s
  render_mongo
  wait_mongo
}
render_mongo() {
  # shellcheck disable=SC2016
  envsubst '$MONGO_NODE $MONGO_TAG' < "$BENCH_DIR/k8s/mongo.yaml" \
    > "$RESULT_DIR/mongo-$MONGO_TAG.yaml"
  kube -n "$NAMESPACE" apply -f "$RESULT_DIR/mongo-$MONGO_TAG.yaml"
  MONGO_HOST=$(kube -n "$NAMESPACE" get service mongo -o jsonpath='{.spec.clusterIP}')
  [[ $MONGO_HOST =~ ^[0-9.]+$ || $MONGO_HOST =~ ^[a-fA-F0-9:]+$ ]] \
    || die "Mongo Service did not return a numeric ClusterIP"
}
cpu_snapshot() {
  local label=$1 api=$2 phase=$3 target pod container file
  mkdir -p -- "$RESULT_DIR/cpu"
  for target in bench:nginx bench:wrk mongo:mongo; do
    pod=${target%:*}
    container=${target#*:}
    file=$RESULT_DIR/cpu/$label-$api-$phase-$container.stat
    printf 'sample_time_epoch %s\n' "$(date +%s)" > "$file"
    if ! kube -n "$NAMESPACE" exec "$pod" -c "$container" -- sh -c '
      if [ -r /sys/fs/cgroup/cpu.stat ]; then
        printf "cgroup v2\n"
        cat /sys/fs/cgroup/cpu.stat
      else
        printf "unavailable: cgroup v2 cpu.stat is not readable\n"
        exit 1
      fi' >> "$file" 2>&1; then
      printf 'unavailable: CPU diagnostics command failed\n' >> "$file"
    fi
  done
}
pass() {
  local side=$1 label=$2 runs=$3 base=$4 api load_rc
  printf 'Starting %s, Mongo %s\n' "$label" "$MONGO_TAG" >&2
  control stop
  ctl MONGOL_LIB="/src/$side/lib" /src/new/bench/ctl.sh start
  for api in "${APIS[@]}"; do
    control seed
    cpu_snapshot "$label" "$api" before
    load_rc=0
    kube -n "$NAMESPACE" exec bench -c wrk -- env WORK=/work \
      RUN_BASE="$base" WRK_THREADS="$WRK_THREADS" WRK_CONNECTIONS="$WRK_CONNECTIONS" /src/new/bench/load.sh "$label" "$api" "$runs" \
      || load_rc=$?
    cpu_snapshot "$label" "$api" after
    ((load_rc == 0)) || return "$load_rc"
    control check-log
    control check-conns
    if [[ $api == find_one ]]; then control check-reuse; fi
  done
  control stop
  # ctl start truncates error.log: preserve every completed pass separately.
  ctl mkdir -p /work/archive
  ctl cp /work/logs/error.log "/work/archive/$label-error.log"
}
compare() {
  local rc=0
  resty "$BENCH_DIR/compare.lua" --cpu-dir "$RESULT_DIR/cpu" "$RESULT_DIR/work/results/old.jsonl" \
    "$RESULT_DIR/work/results/new.jsonl" > "$RESULT_DIR/ab.md" || rc=$?
  cat -- "$RESULT_DIR/ab.md"
  return "$rc"
}
main() {
  if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    return
  fi
  if [[ $# != 1 || -z ${KUBE_CONTEXT:-} || -z ${MONGO_NODE:-} ||
    -z ${BENCH_NODE:-} || -z ${NEW_REF:-} ]]; then
    usage
    exit 2
  fi
  local mode=$1 command replicate side tag
  MODE=$mode
  case $mode in ab | trend | all | calibrate) ;; *)
    usage
    exit 2
    ;;
  esac
  WRK_THREADS=${WRK_THREADS-2}
  WRK_CONNECTIONS=${WRK_CONNECTIONS-32}
  if [[ ! $WRK_THREADS =~ ^[1-9][0-9]*$ || ! $WRK_CONNECTIONS =~ ^[1-9][0-9]*$ ]] \
    || ! awk -v threads="$WRK_THREADS" -v connections="$WRK_CONNECTIONS" 'BEGIN {exit !(threads <= connections)}'; then
    printf 'Error: WRK_THREADS and WRK_CONNECTIONS must be positive integers; threads must not exceed connections\n' >&2
    exit 2
  fi
  if [[ $mode == calibrate ]] && ((WRK_THREADS > 8)); then
    printf 'Error: calibration requires WRK_THREADS <= 8\n' >&2
    exit 2
  fi
  [[ $MONGO_NODE != "$BENCH_NODE" ]] || die "Mongo and bench nodes must differ"
  for command in kubectl envsubst git resty; do
    command -v "$command" > /dev/null || die "$command is required"
  done
  # Check both capacity and current reservations before creating any resources.
  check_node_cpu "$MONGO_NODE" 1000 Mongo
  check_node_cpu "$BENCH_NODE" 1100 bench
  export OLD_SHA NEW_SHA MONGO_NODE BENCH_NODE MONGO_TAG=4.4
  OLD_SHA=$(resolve_ref "${OLD_REF:-3eb6349db4d30b11aab271fb14a82b8504f6aa8e}")
  NEW_SHA=$(resolve_ref "$NEW_REF")
  mkdir -p -- "$BENCH_DIR/results"
  if [[ -n ${RUN_RESULT_DIR:-} ]]; then
    mkdir -- "$RUN_RESULT_DIR"
    RESULT_DIR=$RUN_RESULT_DIR
  else
    RESULT_DIR=$(mktemp -d "$BENCH_DIR/results/k8s-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
  fi
  printf 'old=%s\nnew=%s\nmode=%s\n' "$OLD_SHA" "$NEW_SHA" "$mode" \
    > "$RESULT_DIR/refs.txt"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Create fails if the namespace exists; never adopt an existing namespace.
  OWNED_UID=$(kube create namespace "$NAMESPACE" -o jsonpath='{.metadata.uid}')
  [[ -n $OWNED_UID ]] || die "namespace creation did not return a UID"
  printf '%s\n' "$OWNED_UID" > "$RESULT_DIR/namespace-uid"
  render_mongo
  # shellcheck disable=SC2016
  envsubst '$BENCH_NODE $OLD_SHA $NEW_SHA' < "$BENCH_DIR/k8s/bench.yaml" \
    > "$RESULT_DIR/bench.yaml"
  kube -n "$NAMESPACE" apply -f "$RESULT_DIR/bench.yaml"
  kube -n "$NAMESPACE" wait --for=condition=Ready pod/bench --timeout=900s
  wait_mongo
  local openresty_version wrk_version wrk_banner
  openresty_version=$(ctl nginx -v 2>&1 | sed -n 's/.*openresty\/\([0-9.]*\).*/\1/p')
  # wrk 4.1.0 prints its version then exits 1 without a URL. Normalize that
  # inside the pod so kubectl/transport errors still fail the outer command.
  # shellcheck disable=SC2016 # status expands inside the pod
  wrk_banner=$(kube -n "$NAMESPACE" exec bench -c wrk -- sh -c '
    wrk --version
    status=$?
    case "$status" in 0|1) exit 0;; *) exit "$status";; esac')
  # Ubuntu packages prefix the upstream version with debian/ and add a revision.
  [[ $wrk_banner =~ ^wrk\ (debian/)?([0-9]+\.[0-9]+\.[0-9]+)(-[[:alnum:].+~]+)?([[:space:]].*)?$ ]] \
    || die "cannot identify benchmark tools"
  wrk_version=${BASH_REMATCH[2]}
  [[ $openresty_version =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "cannot identify benchmark tools"
  printf '{"openresty":"%s","wrk":"%s"}\n' "$openresty_version" "$wrk_version" \
    > "$RESULT_DIR/tool-versions.json"
  if [[ $mode == calibrate ]]; then
    APIS=(ping find_one)
    for WRK_CONNECTIONS in 8 16 32; do
      for side in old new; do pass "$side" "$side-c$WRK_CONNECTIONS" 1 0; done
    done
  fi
  if [[ $mode == ab || $mode == all ]]; then
    for replicate in 1 2 3; do
      for side in old new; do pass "$side" "$side-$replicate" 1 "$((replicate - 1))"; done
    done
    for side in old new; do
      # shellcheck disable=SC2016 # arguments expand inside the pod
      ctl sh -c 'cat "/work/results/$1-1.jsonl" "/work/results/$1-2.jsonl" "/work/results/$1-3.jsonl" > "/work/results/$1.jsonl"' sh "$side"
      ctl resty -I "/src/$side/lib" /src/new/bench/bson_micro.lua \
        > "$RESULT_DIR/bson-$side.jsonl"
    done
  fi
  if [[ $mode == trend || $mode == all ]]; then
    for tag in 6.0 7.0 8.0 9.0; do
      replace_mongo "$tag"
      pass new "new-$tag" 3 0
    done
  fi
  collect
  if [[ $mode == calibrate ]]; then
    local connections calibration_rc
    for connections in 8 16 32; do
      calibration_rc=0
      resty "$BENCH_DIR/compare.lua" --cpu-dir "$RESULT_DIR/cpu" --single \
        "$RESULT_DIR/work/results/old-c$connections.jsonl" \
        "$RESULT_DIR/work/results/new-c$connections.jsonl" \
        > "$RESULT_DIR/calibrate-c$connections.md" || calibration_rc=$?
      cat -- "$RESULT_DIR/calibrate-c$connections.md"
      ((calibration_rc <= 1)) || return "$calibration_rc"
      if ((calibration_rc == 1)); then STATUS=1; fi
    done
  fi
  # Compare only after collecting every pass: threshold failures do not abort trends.
  if [[ $mode == ab || $mode == all ]]; then
    local compare_rc=0
    compare || compare_rc=$?
    ((compare_rc <= 1)) || return "$compare_rc"
    STATUS=$compare_rc
  fi
  if [[ $mode == trend || $mode == all ]]; then
    local files=()
    if [[ $mode == all ]]; then files+=("$RESULT_DIR/work/results/new.jsonl"); fi
    for tag in 6.0 7.0 8.0 9.0; do files+=("$RESULT_DIR/work/results/new-$tag.jsonl"); done
    resty "$BENCH_DIR/compare.lua" --trend --cpu-dir "$RESULT_DIR/cpu" "${files[@]}" > "$RESULT_DIR/trend.md"
    cat -- "$RESULT_DIR/trend.md"
  fi
  FINISHED=1
  return "$STATUS"
}
main "$@"
