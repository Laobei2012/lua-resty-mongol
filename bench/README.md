# Driver performance harness

Requires `nginx` from OpenResty, its `resty` CLI, `envsubst`, Git, curl,
Bash, and wrk 4.1.0. MongoDB must have authentication enabled. Use MongoDB
4.4 for comparisons with the old driver.

The [first measured report](../docs/perf/perf-2026-10-29.md) records three
complete invocations, public data, gate failures and interpretation limits.
See the [Kubernetes instructions](k8s/README.md) for the fixed resource profile,
detached launch and recovery.

Run a local pass with the driver selected by its library directory:

```bash
MONGOL_LIB=/path/to/new/lib MONGO_HOST=127.0.0.1 \
  WORK=/tmp/mongol-bench bench/run.sh new-local find_one ping
```

With no API arguments, `run.sh` measures all twelve APIs. Each API gets
fresh fixtures, a ten second warm-up, and three thirty second runs with
`wrk -t2 -c16 --timeout 10s --latency`. `RUNS` changes the number of measured runs.
`WRK_THREADS` (default 2) and `WRK_CONNECTIONS` (default 16) apply to both
warm-up (`-d10s`) and measurement (`-d30s`). Both must be positive integers,
and threads must not exceed connections; invalid values exit 2. The Kubernetes
runner forwards them. Its `calibrate` mode compares 8, 16 and 32 connections
on Mongo 4.4. The full report profile uses 16 connections.
The ten second request timeout accommodates the constrained CPU profile;
any timeout still invalidates the run.
The coordinator checks socket reuse after `find_one`, the Mongo connection
limit after every API, and the nginx error log. It stops nginx on exit.
A label identifies one pass; `run.sh` rejects an existing result file.

`WORK` defaults to `bench/`. Logs go to `$WORK/logs/`, nginx configuration
to `$WORK/conf/`, and JSON lines to `$WORK/results/<label>.jsonl`.
These generated files are ignored by Git. Keep `WORK` separate for
independent servers. The nginx listen port is 8090.

For separate control and load containers, mount the same `WORK` directory
in both and use the same `URL` (default `http://127.0.0.1:8090`):

```bash
# Control host:
MONGOL_LIB=/path/to/old/lib WORK=/work bench/ctl.sh start
WORK=/work bench/ctl.sh seed

# Load host:
WORK=/work RUN_BASE=1 bench/load.sh old-2 find_one 1

# Control host:
WORK=/work bench/ctl.sh check-log
WORK=/work bench/ctl.sh check-conns
WORK=/work bench/ctl.sh check-reuse
WORK=/work bench/ctl.sh stop
```

Keep `MONGOL_LIB` and `SEED_LIB` consistent across control calls where
needed. `SEED_LIB` always points to the new driver and defaults to this
checkout's `lib/`. The control script passes `MONGO_HOST`, `MONGO_PORT`,
`MONGO_ADMIN_USER`, and `MONGO_ADMIN_PASSWORD` to the seed/status scripts;
defaults are `127.0.0.1`, `27017`, `admin`, and `admin`. The benchmark user
and fixtures are created by `ctl.sh seed`.

`ctl.sh start` records the selected driver's Git HEAD in
`$WORK/driver_sha` and the authenticated MongoDB `buildInfo` version in
`$WORK/mongo_version`. `load.sh` uses those files so every JSON line
identifies the driver and server, even when the load container has no
OpenResty installation. `RUN_BASE` defaults to zero; measured run numbers
start at `RUN_BASE + 1`. A 501 preflight response skips the API without a
JSON line. Any other non-2xx response, socket error, empty run or nginx
error invalidates the load and returns nonzero. A failed API does not
append partial results; earlier successful APIs may remain in the file,
so only use result files from passes that exited successfully.
Each measured JSON line includes its completed `requests` count and an
`interval_requests` count shared by all samples in that API/pass. The latter
sums the successful preflight request, warm-up requests and all measured requests
to match the CPU snapshot interval.

Run the BSON micro benchmark with
`resty -I /path/to/driver/lib bench/bson_micro.lua`. It measures small- and
large-document encode/decode, plus `decode_reply`: a cursor reply with one
small document in `firstBatch`, an int64 cursor ID, namespace, and `ok`.
The reply envelope works with both drivers. Each case
collects garbage, then warms up for at most 1,000 operations, stopping when
one second has elapsed (checked every 50 operations). Measurement uses batches
of 100 operations and checks the clock once per batch, stopping after the first
batch that ends at or after two seconds. Each JSON line reports `case` and
`ops_per_s`, calculated as the measured operation count divided by elapsed time.

Deterministic scaffold checks require Bash and a `lua` interpreter:

```bash
bench/t/runner_test.sh
shellcheck bench/{ctl,load,run,smoke}.sh bench/t/runner_test.sh
shfmt -d -i 2 -ci -bn -sr -s bench/{ctl,load,run,smoke}.sh \
  bench/t/runner_test.sh
```

The tests replace network/process tools with stubs. They check result
units and identity, run numbering, exact load defaults, rejected failures,
unsupported API skips, fixture counts, reuse/connection limits, reseeding
between APIs, and coordinator cleanup. `bench/smoke.sh` remains the live
handler check; it uses `ctl.sh` to manage nginx and fixtures and expects
one error from its intentionally empty read collection.

The owner-approved CPU requests/limits (2026-10-30) are Mongo 1000m/2000m,
nginx 1000m/1000m, wrk 100m/300m and clone init 200m/200m; memory is unchanged.
Mongo and wrk are Burstable by owner decision. The earlier limits throttled
nginx and Mongo while wrk was lightly used. The new requests fit the available
1100m on the Mongo node and 1110m on the bench node (1100m combined request).

Kubernetes comparisons always check CPU validity per API and pass. Nginx,
Mongo and wrk must each be throttled in less than 1% of
periods. Missing or unusable counters invalidate the API. An invalid interval
makes that API `invalid` in the comparison, counting as neither gate pass nor
gate fail; other APIs still gate at 0.90 rps and 1.20 p99 ratios. Reports include
conditions and values for every interval. Snapshots cover preflight, warm-up,
measurement and sequential snapshot overhead. Nginx CPU/request (microseconds)
divides its `usage_usec` delta by `interval_requests`; it is informational and
does not change the throughput/p99 gates. A/B CPU/request tables pool CPU usage
and requests across distinct passes, counting each interval once. Missing
request counts or unusable nginx counters show `unavailable` for CPU/request.

For standalone saved results, use `resty bench/compare.lua --cpu-dir <cpu-dir>
<old.jsonl> <new.jsonl>`. Without CPU arguments, legacy/local JSONL comparisons
retain their existing threshold-only behavior. `--single` accepts one measured
sample per API for calibration; full comparisons still require three.
