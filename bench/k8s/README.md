Run from a host with Bash, kubectl, git, gettext `envsubst`, and OpenResty `resty`.
Authenticate through Teleport, verify the exact context and both node hostnames,
then copy `environment.example` to `environment.local` and fill its values.
The file is ignored; do not commit cluster details. Push the complete benchmark
implementation and set NEW_REF to that commit before starting.

Before checking free CPU, the runner refuses an existing `mongol-bench`
namespace with a message naming it; it never deletes or adopts that namespace.
Before creating the namespace, the runner checks each selected node's allocatable
CPU: Mongo needs at least 1000m and the bench pod needs at least 1100m. Missing
or ambiguous hostname-label matches and missing CPU values fail the check.
MONGO_NODE and BENCH_NODE select `kubernetes.io/hostname` labels, which can differ
from node object names. The runner also reads current CPU requests from `kubectl describe nodes`'s
Allocated resources section and subtracts them from allocatable CPU. Before
namespace creation, free CPU must cover Mongo's 1000m request and the bench
pod's combined 1100m request. Missing reservations fail preflight; insufficient
free CPU reports the free/requested values and explains that the pod would stay
Pending. Memory, storage, placement rules and later reservation changes can
still prevent scheduling.

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
measured sample is 30 seconds with two wrk threads, 16 connections
(4 for `connect_nopool`), and a
10-second socket timeout.

Owner decision (2026-10-30): reduce nginx/Mongo throttling observed in the
first report while fitting existing CPU reservations. The Mongo node has 1100m
free to reserve; the bench node has 1110m, covering nginx plus wrk's 1100m.

| Container | CPU request | CPU limit | Memory request/limit |
| --- | ---: | ---: | ---: |
| Mongo | 1000m | 2000m | 4Gi |
| nginx | 900m | 1000m | 512Mi |
| wrk | 200m | 300m | 512Mi |
| clone init | 200m | 200m | 128Mi |

Mongo, nginx and wrk have CPU requests below limits and are Burstable by owner decision; both pods therefore have
Burstable QoS. Memory, Mongo cache and storage are unchanged. The throughput
and p99 thresholds (0.90 and 1.20), interleaved runs and three complete `all`
invocations remain unchanged. BSON timing is described below.

Run `bench/k8s/run-k8s.sh calibrate` after reviewing and publishing the complete
implementation. On Mongo 4.4 it runs old then new at 8 connections, old then new
at 16, then old then new at 32. Each pass runs `ping` and `find_one`, each with
one 10-second warm-up and one 30-second measured run. It skips trends and BSON,
collects shared results and CPU snapshots, and deletes only its owned namespace.
Results include `old-c8.jsonl`/`new-c8.jsonl` (and c16/c32) under `work/results/`,
plus `calibrate-c8.md`, `calibrate-c16.md` and `calibrate-c32.md` with CPU validity.
The timed HTTP workload is `3 * 2 * 2 * (10 + 30) = 480s`, or 8 minutes.
Allow roughly 20 minutes including cloning, package installation, seeding,
remote snapshot calls, readiness and collection; actual overhead is unmeasured.

`WRK_THREADS` defaults to 2 and `WRK_CONNECTIONS` to 16, for warm-up and
measurement, except `connect_nopool`, which always uses two threads and four
connections regardless of these settings. Both must be positive integers and threads cannot exceed
connections (exit 2). Calibration fixes connections to 8/16/32 and requires
threads <= 8. Full report series require the approved 2/16 profile, with 2/4 for `connect_nopool`.

The bench pod sets the pod-level sysctl `net.ipv4.ip_local_port_range` to
`1024 65535`, keeping the CPU and memory profile above. `connect_nopool` closes
a socket on every request, leaving a local port in TIME_WAIT for about 60s.
At the observed 1,395 connections/s this would require about 84,000 ports;
using four connections reduces the rate. The actual connection count is saved
as `connections` in every measured JSON row.

For a focused port-exhaustion check after publishing the committed workload:

```bash
source bench/k8s/environment.local
bench/k8s/run-k8s.sh connect-check
```

`connect-check` creates its owned namespace, starts Mongo 7.0 and runs only the
new driver's `connect_nopool`: one 10s warm-up and three 30s measured samples,
the same sequence as a trend pass. Timed load is 100 seconds; allow roughly
5–10 minutes including setup, readiness, seeding, collection and cleanup
(overhead is unmeasured). It skips A/B, BSON, comparison gates and other trends.
Both `connect-check` and `all` read `/proc/sys/net/ipv4/ip_local_port_range`
from the bench `nginx` container, print it and save it as `ip_local_port_range`
in the local result directory. A range other than `1024 65535` fails before
any load. Socket errors and non-2xx responses fail the check through the normal
load validation. Collection precedes deletion of only the owned namespace;
`COMPLETE` is written only after successful work, collection and cleanup.

Each API saves before/after cgroup v2 `cpu.stat` for nginx, wrk and Mongo in the
local result directory's `cpu/` folder, with sample timestamps. The interval
includes warm-up and measured runs. Compare `usage_usec`, `nr_periods`,
`nr_throttled`, and `throttled_usec` deltas to assess CPU use and throttling under
these caps. Every API/pass is invalid if nginx, Mongo or wrk is throttled in
>=1% of periods. There is no minimum nginx core usage requirement.
Missing, reset or unusable counters also invalidate the API. The comparison
shows `invalid` if any interval for that API is invalid, excluding it from both
gate passes and gate failures; valid APIs still gate normally. An A/B or
calibration comparison with zero gated APIs exits 1 and prints "No API was gated";
bad input still exits 2. Trend comparisons have no gates. Per-pass tables
name each condition and its values. Trend cells also show `invalid`.
Nginx is sampled last before load (Mongo, wrk, nginx) and first after load
(nginx, wrk, Mongo), excluding the other containers' snapshot calls from its
interval. The interval includes the successful preflight, warm-up, measured
requests and nginx's own snapshot overhead. Each measured JSON line records
its completed `requests` and the shared API/pass `interval_requests` total.
Nginx CPU/request (microseconds) is `usage_usec / interval_requests`, shown per
pass and side by side for old/new. The A/B value pools usage and request counts
across distinct passes, without counting a shared interval once per sample.
This metric is informational and never gates; missing counts or unusable nginx
counters yield `unavailable`. CPU attribution includes background work and
snapshot overhead, rather than measuring isolated handler CPU time.

The script creates only `mongol-bench` and refuses an existing namespace. Every
kubectl operation uses KUBE_CONTEXT explicitly. It copies all shared results,
wrk output, nginx logs and pod diagnostics before deleting its own namespace.
If copying fails it saves diagnostics, deletes its namespace, and exits nonzero.
The private `namespace-uid` result file records the UID immediately after namespace
creation. If expired credentials prevent cleanup, renew them and compare this
saved UID with the current namespace UID before any manual deletion; delete only
when they match. The runner never adopts a namespace using this file.
Threshold failures exit nonzero after all trends finish and results are saved.
The Mongo and bench pods need separate nodes, outbound GitHub/Ubuntu access, and
the resource capacity specified in the manifests. No custom image is needed.

`bson_micro.lua` also runs directly with
`resty -I /path/to/driver/lib bench/bson_micro.lua`. Its five cases each warm up
for at most 1,000 operations, stopping when one second has elapsed (checked every
50 operations). Measurement runs in batches of 100 operations, checking the
clock once per batch and stopping after the first batch that ends at or after
two seconds. `ops_per_s` is the measured operation count divided by elapsed time.

The runner falls back from kubectl cp to a tar stream before cleanup. If both
methods fail, shared files cannot be recovered; local pod and container diagnostics
remain available. Cleanup still deletes the owned namespace and the run fails.

## Three-invocation reports

The [2026-10-29 report](../../docs/perf/perf-2026-10-29.md) contains the first
three complete invocations, all measured tables, public data and triage issues.

After accepting the initial live A/B validation, run the series from a clean,
committed controller checkout with Python 3.9+ and the prerequisites above:

```bash
source bench/k8s/environment.local
# NEW_REF must resolve locally to the pushed driver/workload commit.
/usr/bin/python3 bench/report.py launch bench/results/first-report
```

`launch` prints the child series PID after recording it and the private log path
in `bench/results/first-report.launch.json`. The child starts a new POSIX session,
reads stdin from `/dev/null`, and writes stdout/stderr to the private sibling
`first-report.controller.log`; it does not retain the launcher's terminal or tool
session descriptors. Both sidecars must be fresh and are created with mode 600.
The series directory is created by the child after its existing preflight checks.
Use the printed PID with `ps -p PID` and monitor the private files:

```bash
cat bench/results/first-report.launch.json
tail -f bench/results/first-report.controller.log
# Per-invocation progress is in run-1.log, then run-2.log and run-3.log.
tail -f bench/results/first-report/run-1.log
```

Launch success means the child started; check its logs for preflight or runtime
errors. A launch OS error is recorded in the controller log without a PID in the
reserved metadata file. Keep failed-launch artifacts and choose a fresh name.
Detachment does not renew credentials or retry failed work. `series` remains
available for running the same workflow in the foreground.

By default this runs three fresh complete `all` invocations sequentially. A
performance gate failure continues the series when the invocation is complete.
CPU-invalid APIs remain in the report without counting as gate passes or fails.
Malformed comparison inputs, incomplete results, failed collection or failed
namespace cleanup stop the series. It never changes the resource profile,
durations or thresholds. The runner accepts an optional fresh `RUN_RESULT_DIR`
and writes `COMPLETE` only after all requested work and successful cleanup;
`all` is required for reporting. Tool versions are queried from the containers.

The series records resolved public SHAs, approved workload/resource Git blob
IDs, the fixed workload arguments and private placement (context and both node
hostnames) in each private `run-manifest.json`.
The new workload and local manifest sources must match the approved blobs in
`report.py`. This prevents a shorter workload from being reported as a full
run. Commit the controller before running and keep HEAD unchanged throughout
the series; the controller SHA is separate from the frozen driver/workload
`NEW_REF`. Raw results, logs, manifests, node details
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
total), six correctly numbered interleaved A/B pass files and ten BSON cases.
Result manifests attest a run produced by this controller; they do not prove
authenticity of manually fabricated inputs. Do not hand-edit completion or
provenance files to import older runs. If credentials expire after one or two
complete invocations, renew them, fix the cause and use a fresh series directory
with those completed directories:

```bash
/usr/bin/python3 bench/report.py launch bench/results/first-report-recovery \
  --reuse bench/results/first-report/run-1 bench/results/first-report/run-2
```

`--reuse` accepts at most two distinct complete `all` directories. Every reused
invocation must pass the same full validation and match the current committed
controller HEAD, resolved old/new SHAs, approved workload/resource blobs,
full profile, tool versions and exact context/node placement before any runner
starts. Offline reporting also requires the same private placement across all
three runs and excludes it from public output. In this example only
`first-report-recovery/run-3` runs fresh, then `public/` reports exactly three
distinct complete invocations. Reused provenance and COMPLETE files are never
rewritten; their paths stay private. Incomplete runs and their diagnostics remain
in the original directory and cannot be reused. There are no automatic retries
or namespace adoption. Three complete invocations, all 213 HTTP samples and
ten BSON cases per invocation, the full warm-ups, durations, resources and
thresholds remain required.

For later reports, review only the generated `public/` files for a `docs/perf/`
commit. The controller neither publishes reports nor creates issues; open
failed or unstable API issues separately with `needs-triage` after reviewing
real data. The first report and its copied public data are committed under
[`docs/perf/`](../../docs/perf/README.md).

Fixture checks (pytest is a development dependency):

```bash
python3 -m pytest -q bench/t/report_test.py
bench/t/k8s_runner_test.sh
resty bench/t/compare_test.lua
```

Owner decision (2026-10-30): wrk requests 200m. The bench node has 1110m
free to reserve, so nginx requests 900m and keeps its 1000m limit; nginx used
at most 0.67 cores in calibration. The combined request stays 1100m, preserving
the preflight minimum. Mongo stays at 1000m/2000m and clone at 200m/200m.
All three runtime containers have requests below limits; clone remains equal.
Memory is unchanged. The owner removed the minimum nginx CPU usage rule:
nginx did not saturate in calibration (0.34–0.67 cores), and throttling is the
check for whether the setup distorts a result. Throughput stopped rising at
16 connections, so the default is `-t2 -c16`, including warm-up,
with the `connect_nopool` exception of `-t2 -c4`.
