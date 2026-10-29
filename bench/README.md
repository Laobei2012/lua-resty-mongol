# Driver performance harness

Requires `nginx` from OpenResty, its `resty` CLI, `envsubst`, Git, curl,
Bash, and wrk 4.1.0. MongoDB must have authentication enabled. Use MongoDB
4.4 for comparisons with the old driver.

Run a local pass with the driver selected by its library directory:

```bash
MONGOL_LIB=/path/to/new/lib MONGO_HOST=127.0.0.1 \
  WORK=/tmp/mongol-bench bench/run.sh new-local find_one ping
```

With no API arguments, `run.sh` measures all twelve APIs. Each API gets
fresh fixtures, a ten second warm-up, and three thirty second runs with
`wrk -t2 -c32 --latency`. `RUNS` changes the number of measured runs.
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
