#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${TRACE:-0} == 1 ]] && set -x

BENCH_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
readonly BENCH_DIR
readonly REPOSITORY=https://github.com/Laobei2012/lua-resty-mongol
readonly NAMESPACE=mongol-bench
readonly APIS=(ping find_one find_100 count insert_1 insert_100 update
  delete_insert find_and_modify gridfs_read auth connect_nopool)
OWNED_UID=
RESULT_DIR=
COLLECTED=0
STATUS=0

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
usage() {
  printf 'Usage: KUBE_CONTEXT=... MONGO_NODE=... BENCH_NODE=... NEW_REF=... %s <ab|trend|all>\n' "$0" >&2
}
kube() { kubectl --context "$KUBE_CONTEXT" "$@"; }
check_node_cpu() {
  local node=$1 minimum=$2 role=$3 quantity millicores
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
  local rc=$? uid
  trap - EXIT INT TERM ERR
  if [[ -n $OWNED_UID ]]; then
    if ((COLLECTED == 0)); then collect || rc=1; fi
    if ((COLLECTED > 0)); then
      uid=$(kube get namespace "$NAMESPACE" -o jsonpath='{.metadata.uid}') || uid=
      if [[ $uid == "$OWNED_UID" ]]; then
        kube delete namespace "$NAMESPACE" --wait=true --timeout=180s || rc=1
      else
        printf 'Namespace ownership changed; refusing cleanup.\n' >&2
        rc=1
      fi
    fi
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
pass() {
  local side=$1 label=$2 runs=$3 base=$4 api
  printf 'Starting %s, Mongo %s\n' "$label" "$MONGO_TAG" >&2
  control stop
  ctl MONGOL_LIB="/src/$side/lib" /src/new/bench/ctl.sh start
  for api in "${APIS[@]}"; do
    control seed
    kube -n "$NAMESPACE" exec bench -c wrk -- env WORK=/work \
      RUN_BASE="$base" /src/new/bench/load.sh "$label" "$api" "$runs"
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
  if ! resty "$BENCH_DIR/compare.lua" "$RESULT_DIR/work/results/old.jsonl" \
    "$RESULT_DIR/work/results/new.jsonl" > "$RESULT_DIR/ab.md"; then rc=1; fi
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
  case $mode in ab | trend | all) ;; *)
    usage
    exit 2
    ;;
  esac
  [[ $MONGO_NODE != "$BENCH_NODE" ]] || die "Mongo and bench nodes must differ"
  for command in kubectl envsubst git resty; do
    command -v "$command" > /dev/null || die "$command is required"
  done
  # Absolute node capacity only; existing reservations may still prevent scheduling.
  check_node_cpu "$MONGO_NODE" 2000 Mongo
  check_node_cpu "$BENCH_NODE" 3000 bench
  export OLD_SHA NEW_SHA MONGO_NODE BENCH_NODE MONGO_TAG=4.4
  OLD_SHA=$(resolve_ref "${OLD_REF:-3eb6349db4d30b11aab271fb14a82b8504f6aa8e}")
  NEW_SHA=$(resolve_ref "$NEW_REF")
  mkdir -p -- "$BENCH_DIR/results"
  RESULT_DIR=$(mktemp -d "$BENCH_DIR/results/k8s-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
  printf 'old=%s\nnew=%s\nmode=%s\n' "$OLD_SHA" "$NEW_SHA" "$mode" \
    > "$RESULT_DIR/refs.txt"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Create fails if the namespace exists; never adopt an existing namespace.
  OWNED_UID=$(kube create namespace "$NAMESPACE" -o jsonpath='{.metadata.uid}')
  [[ -n $OWNED_UID ]] || die "namespace creation did not return a UID"
  render_mongo
  # shellcheck disable=SC2016
  envsubst '$BENCH_NODE $OLD_SHA $NEW_SHA' < "$BENCH_DIR/k8s/bench.yaml" \
    > "$RESULT_DIR/bench.yaml"
  kube -n "$NAMESPACE" apply -f "$RESULT_DIR/bench.yaml"
  kube -n "$NAMESPACE" wait --for=condition=Ready pod/bench --timeout=900s
  wait_mongo
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
  # Compare only after collecting every pass: threshold failures do not abort trends.
  if [[ $mode == ab || $mode == all ]]; then compare || STATUS=1; fi
  if [[ $mode == trend || $mode == all ]]; then
    local files=()
    if [[ $mode == all ]]; then files+=("$RESULT_DIR/work/results/new.jsonl"); fi
    for tag in 6.0 7.0 8.0 9.0; do files+=("$RESULT_DIR/work/results/new-$tag.jsonl"); done
    resty "$BENCH_DIR/compare.lua" --trend "${files[@]}" > "$RESULT_DIR/trend.md"
    cat -- "$RESULT_DIR/trend.md"
  fi
  return "$STATUS"
}
main "$@"
