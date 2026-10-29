Run from a host with Bash, kubectl, git, gettext `envsubst`, and OpenResty `resty`.
Authenticate through Teleport, verify the exact context and both node hostnames,
then copy `environment.example` to `environment.local` and fill its values.
The file is ignored; do not commit cluster details. Push the complete benchmark
implementation and set NEW_REF to that commit before starting.

Before creating the namespace, the runner checks each selected node's allocatable
CPU: Mongo needs at least 400m and the bench pod needs at least 1100m. Missing
or ambiguous hostname-label matches and missing CPU values fail the check.
MONGO_NODE and BENCH_NODE select `kubernetes.io/hostname` labels, which can differ
from node object names. This checks absolute node capacity; existing
workload reservations, memory, storage, or placement rules can still prevent
scheduling after it passes.

```bash
source bench/k8s/environment.local
bench/k8s/run-k8s.sh all
```

HTTP measurements alone take roughly two hours per `all` invocation; setup and
the full BSON warm-ups add time. At the configured CPU caps, BSON warm-ups can
take tens of minutes per driver. Run `all` three separate times for the first
report. Each invocation creates a unique local `bench/results/k8s-*` directory.
`ab` runs old/new alternately three times on Mongo 4.4; `trend` runs three measured
samples on each of Mongo 6, 7, 8, and 9. Warm-up is always 10 seconds and each
measured sample is 30 seconds with one wrk thread, eight connections, and a
10-second socket timeout.

Owner decision (2026-10-28): fit the existing node capacity with Mongo at 400m,
nginx at 300m and wrk at 800m CPU, on a fixed pair of nodes in the same region.
Requests equal limits for every container, including the 200m clone init
container, preserving Guaranteed QoS. Memory, Mongo cache and storage are
unchanged. The throughput and p99 thresholds, interleaved runs, three complete
`all` invocations, and BSON warm-ups and measurement durations remain unchanged.

Each API saves before/after cgroup v2 `cpu.stat` for nginx, wrk and Mongo in the
local result directory's `cpu/` folder, with sample timestamps. The interval
includes warm-up and measured runs. Compare `usage_usec`, `nr_periods`,
`nr_throttled`, and `throttled_usec` deltas to assess CPU use and throttling under
these caps. Missing diagnostics are explicitly marked `unavailable`; a successful
benchmark without those counters does not establish that CPU was unsaturated.

The script creates only `mongol-bench` and refuses an existing namespace. Every
kubectl operation uses KUBE_CONTEXT explicitly. It copies all shared results,
wrk output, nginx logs and pod diagnostics before deleting its own namespace.
If copying fails it saves diagnostics, deletes its namespace, and exits nonzero.
Threshold failures exit nonzero after all trends finish and results are saved.
The Mongo and bench pods need separate nodes, outbound GitHub/Ubuntu access, and
the resource capacity specified in the manifests. No custom image is needed.

`bson_micro.lua` also runs directly with
`resty -I /path/to/driver/lib bench/bson_micro.lua`. Its four cases each warm up
for 100,000 operations and then measure for two seconds. Large-case warm-up can
take several minutes on the old driver.

The runner falls back from kubectl cp to a tar stream before cleanup. If both
methods fail, shared files cannot be recovered; local pod and container diagnostics
remain available. Cleanup still deletes the owned namespace and the run fails.

## Reproducible first-report scaffold

After accepting the initial live A/B validation, run the series from a clean,
committed controller checkout with Python 3.9+ and the prerequisites above:

```bash
source bench/k8s/environment.local
# NEW_REF must resolve locally to the pushed driver/workload commit.
/usr/bin/python3 bench/report.py series bench/results/first-report
```

This runs exactly three complete `all` invocations sequentially. A performance
gate failure continues the series only when the invocation is complete and
valid. An invalid comparison, incomplete result set, failed collection or failed
namespace cleanup stops the series. It never changes the resource profile,
durations or thresholds. The runner accepts an optional fresh `RUN_RESULT_DIR`
and writes `COMPLETE` only after all requested work and successful cleanup;
`all` is required for reporting. Tool versions are queried from the containers.

The series records resolved public SHAs, approved workload/resource Git blob
IDs and the fixed workload arguments in each private `run-manifest.json`.
The new workload and local manifest sources must match the approved blobs in
`report.py`. This prevents a shorter workload from being reported as a full
run. Commit the controller before running; the controller SHA is separate from
the frozen driver/workload `NEW_REF`. Raw results, logs, manifests, node details
and context stay private under the ignored `bench/results/` directory.

Only after all three directories validate does the script create
`bench/results/first-report/public/`. That directory contains reconstructed
allowlisted metric JSONL, numeric CPU deltas, a public source/profile manifest
and `report.md`. It includes three A/B and trend tables, three BSON matrices,
cross-repetition API stability and failed API issue candidates. It calls the
existing `compare.lua` for medians and gate decisions. CPU intervals include
warm-up, measurement and snapshot overhead; missing diagnostics remain
unavailable. The constrained CPU results cannot alone establish a driver cause.

Regenerate into a fresh output directory from the same three valid directories:

```bash
/usr/bin/python3 bench/report.py report /tmp/public-perf-report \
  bench/results/first-report/run-1 bench/results/first-report/run-2 \
  bench/results/first-report/run-3
```

Reports reject missing or duplicate samples, errors, wrong labels/SHAs/server
versions, incomplete BSON cases, altered joined A/B files and profiles. Each
invocation requires 33 old samples, 36 new samples and 144 trend samples (213
total), six correctly numbered interleaved A/B pass files and eight BSON cases.
Result manifests attest a run produced by this controller; they do not prove
authenticity of manually fabricated inputs. Do not hand-edit completion or
provenance files to import older runs. To recover from an incomplete series,
fix the cause and use a fresh series directory.

Review only the generated `public/` files for a future `docs/perf/` commit.
The scaffold neither publishes a report nor creates issues; open failed or
unstable API issues separately with `needs-triage` after reviewing real data.
No first performance report is included until three valid full runs exist.

Fixture checks (pytest is a development dependency):

```bash
python3 -m pytest -q bench/t/report_test.py
bench/t/k8s_runner_test.sh
resty bench/t/compare_test.lua
```
