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

`all` takes about 2 hours 10 minutes. Run it three separate times for the first
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
