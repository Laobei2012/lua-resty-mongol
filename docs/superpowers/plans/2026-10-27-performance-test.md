# Performance Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure the throughput and latency of each public API of the modernized driver. Compare them with the old driver on the same server and machine.

**Architecture:** One OpenResty server loads the driver from a directory that you select with `MONGOL_LIB`. It has one HTTP location for each API under test. `bench/ctl.sh` starts, stops, seeds and checks the server; `bench/load.sh` runs `wrk` against one location at a time and writes one JSON line for each run. `bench/run.sh` combines both on one host; on Kubernetes, `run-k8s.sh` calls `ctl.sh` in the `nginx` container and `load.sh` in the `wrk` container. A compare script reads two result files and writes a Markdown report with a pass or fail for each API. A separate `resty` script measures BSON encode and decode without the network.

**Tech Stack:** OpenResty 1.31.1.1, `wrk` 4.1.0 (the Ubuntu jammy package) with its Lua hooks, `resty` CLI and `cjson`. MongoDB Docker images `mongo:4.4` and `mongo:6.0` to `mongo:9.0`. Kubernetes through Teleport (`tsh kube login`), with `kubectl` and the official image `openresty/openresty:1.31.1.1-jammy`.

**Spec:** No separate spec. This plan follows `docs/superpowers/specs/2026-10-25-modernize-driver-design.md` and `docs/superpowers/plans/2026-10-25-modernize-driver.md`.

## Global Constraints

- Old driver: commit `3eb6349`, the last commit before the modernization. It speaks `OP_QUERY`, and it writes with the legacy `OP_INSERT` / `OP_UPDATE` / `OP_DELETE` opcodes followed by `getLastError`. `mongo:4.4` is the last server that accepts all of these, so the old driver runs only against `mongo:4.4`. Do not move the A/B pair to a newer server.
- New driver: `master` at 1.0.0 (`173b314`) or a later ref. Record its commit SHA in every result line.
- A/B rule: the old and new driver run on `mongo:4.4`, on the same machine, in the same job, one after the other. Only this pair decides pass or fail.
- Trend rule: the new driver also runs on `mongo:6.0`, `mongo:7.0`, `mongo:8.0` and `mongo:9.0`. These numbers are for information. They do not gate.
- Handlers use only the API forms that both drivers accept: no arrays in documents, whole numbers below 2^31, no BSON types that Phase 4 adds.
- Auth is always on: Mongo starts with a root user, both locally and on Kubernetes. Auth is per connection, and both drivers keep one shared pool per host and port for all locations. So every handler that calls `set_keepalive`, `/ping`, `/reuse` and `/auth` included, logs in with `db:auth_scram_sha1("bench", "bench")` when `conn:get_reused_times() == 0`. Otherwise `/ping` would return unauthenticated sockets to the pool, and later APIs would reuse them and fail with `Unauthorized`. Only `/connect_nopool` skips the login, since it closes its socket. Pooled requests then measure the API alone, without SCRAM.
- Handlers check results in a way that is true for both drivers. Insert handlers check only that the result is not `nil`: the old `insert(..., safe)` returns `getlasterror.n`, which is 0 for inserts. Build every `options` or document table inside the handler, once per request. The old `find_and_modify` changes its `options` table (it sets `options.findAndModify`), so a table defined at module level must never be reused.
- Nginx: `worker_processes 1`, `lua_code_cache on`, `access_log off`, `error_log` at `warn`.
- Connection reuse: every handler ends with `conn:set_keepalive(10000, 100)`. The `connect_nopool` location is the only exception.
- Load: `wrk -t2 -c32 -d30s --latency` after a 10 second warm-up. Three runs for each API. The report uses the median run.
- Pass threshold (owner decision, 2026-10-27): for each API on `mongo:4.4`, new req/s is at least 90% of old req/s. New p99 latency is at most 120% of old p99.
- Cluster: Kubernetes, reached through Teleport. `run-k8s.sh` requires `KUBE_CONTEXT` and passes `--context "$KUBE_CONTEXT"` to every `kubectl` call. It never uses the current context.
- Namespace: `mongol-bench`, created and deleted by `run-k8s.sh`. The script changes no other namespace.
- Placement: the Mongo Pod and the bench Pod run on two different nodes, set with `nodeSelector` values from `MONGO_NODE` and `BENCH_NODE`. The same two nodes serve all runs.
- Resources, with requests equal to limits on every container, init containers included: Mongo 2 CPU and 4Gi. Container `nginx` 1 CPU and 512Mi. Container `wrk` 2 CPU and 512Mi. Init container `clone` 200m CPU and 128Mi.
- Mongo memory and disk: mongod starts with `--wiredTigerCacheSizeGB 1.5`, because older mongod versions may not detect cgroup v2 limits. Storage is an `emptyDir` with `sizeLimit: 10Gi`, and the Mongo container sets `ephemeral-storage` request and limit to 12Gi, so `/insert_100` (millions of documents per API) does not get the Pod evicted.
- Code: an init container (`alpine/git`) clones `https://github.com/Laobei2012/lua-resty-mongol` at `OLD_REF` and `NEW_REF` into an `emptyDir`. There is no custom image and no registry. The cluster needs network egress to `github.com` for the clone and to the Ubuntu mirrors for `apt-get install wrk`.
- Trigger: by hand only (owner decision, 2026-10-27). There is no GitHub Actions job.
- A run with any non-2xx response or any `[error]` line in `error.log` is invalid. The runner exits non-zero.
- The bench files live under `bench/` and reports under `docs/perf/`. They are not installed by `make install` and not run by `make test`. `dist.ini` gets `exclude_files` patterns for both, so `opm build` does not package them.
- Commit style: `type(scope): description`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A handler that fails silently, for example `find_one` returns `nil` because the seed data is missing. Expected: the handler returns HTTP 500 and wrk counts it as a non-2xx response, so the run is invalid. Test: Task 1, `smoke: empty collection`.
2. A socket leak, where the new driver closes or does not return sockets to the pool. Expected: after a run, `get_reused_times()` is above 0 in the `reuse` location, and the server `connections.current` stays at most 100 + 5. Test: Task 2, `reuse check`.
3. Writes that grow the collection during a run, so later runs read more data than earlier runs. Expected: write handlers use the `write` collection, never `read`, and the runner drops and re-seeds both before each API. Test: Task 2, `reseed between APIs`.
4. Noise from other workloads on the cluster nodes. Expected: the old and new runs alternate (old, new, old, new, old, new), so drift affects both sides. The pods have the Guaranteed QoS class (CPU requests equal limits). Test: Task 4, `interleaved order`.
5. The old driver raising a Lua error on an API that it does not support. Expected: the report marks the API `n/a (old)`, not `fail`. Test: Task 3, `missing side`.

---

## File Structure

| File | Responsibility |
|---|---|
| `bench/nginx.conf.in` | Template for the server on port 8090. One location for each API. `lua_package_path` does not expand environment variables, so `ctl.sh` renders it with `envsubst '$MONGOL_LIB'` into `<prefix>/conf/nginx.conf` before `nginx -p <prefix>` |
| `bench/handlers.lua` | One function for each API. Each one does one driver call, checks the result, returns 200 or 500 |
| `bench/seed.lua` | `resty -I /src/new/lib` script: always the new driver, whatever `MONGOL_LIB` is, so every pass reads the same fixtures. Logs in as the admin user. Drops only the `read`, `write`, `fs.files` and `fs.chunks` collections, never the whole database, and inserts the fixtures. Creates the user `bench` only when `usersInfo` shows it is missing: `dropDatabase` would not remove the user, so a second `createUser` would fail (code 51003). Recreating the user would also break the pooled sockets that nginx holds logged in as it |
| `bench/server_status.lua` | `resty -I /src/new/lib` script: always the new driver, like `seed.lua`. Logs in as the admin user and prints `serverStatus().connections.current`, through the driver. Exits non-zero when Mongo is not reachable, so it also serves as the "Mongo is up" check |
| `bench/ctl.sh` | `ctl.sh <start\|stop\|seed\|check-log\|check-conns>`. Runs on the nginx host: renders the conf, starts and stops nginx, seeds, checks `error.log` and the connection count |
| `bench/load.sh` | `load.sh <label> <api> <runs>`. Runs on the wrk host: 10 s warm-up, then `<runs>` wrk runs, appends to `results/<label>.jsonl` |
| `bench/wrk_report.lua` | wrk `done()` hook. Prints one JSON line: req/s, p50, p90, p99, errors |
| `bench/run.sh` | Single host: for each API calls `ctl.sh` and `load.sh` in turn, writes `results/<label>.jsonl` |
| `bench/compare.lua` | `resty` script. Reads two `.jsonl` files and writes a Markdown table with pass or fail. With `--trend`, reads one file per Mongo tag and writes a table without pass or fail |
| `bench/bson_micro.lua` | `resty` script. Encode and decode loops, prints ops/s. Uses a small adapter for each driver (see Task 4) |
| `bench/k8s/mongo.yaml` | Mongo Pod and Service. The image tag is a template value |
| `bench/k8s/bench.yaml` | Bench Pod: init container clones both refs, container `nginx`, container `wrk`. Both containers mount `/src` and `/work` (logs and results) from shared `emptyDir` volumes |
| `bench/k8s/run-k8s.sh` | Applies the manifests, runs the A/B and trend runs, copies the results back, deletes the namespace |
| `docs/perf/perf-<date>.md` | First report, written in Task 5 |

## APIs under test

Fixtures: collections `read` and `write` each have 1,000 documents `{_id = i, name = "user" .. i, age = i % 100, tags = "a b c", body = <200 byte string>}` with an index on `age`. GridFS bucket `fs` has one file `f1m` of 1 MiB. The user `bench` / `bench` has role `readWrite` on database `bench` and is created with `mechanisms = {"SCRAM-SHA-1"}`.

Read handlers use `read`. Write handlers use `write`, so the `$inc age` of `/update` and `/find_and_modify` never changes what `/count` returns. Inserted documents never set `_id`: the server assigns it (neither driver adds one), so the 32 connections never get duplicate-key errors.

| Location | Driver call | Notes |
|---|---|---|
| `/ping` | `db:cmd({ping = 1})` | Wire round trip floor |
| `/find_one` | `col:find_one({_id = rand(1, 1000)})` | Point read |
| `/find_100` | `col:find(...)` with `limit(100)`, iterate all | Cursor and `getMore`, batch size 50 |
| `/count` | `col:count({age = 7})` | |
| `/insert_1` | `col:insert({doc}, nil, true)` into `write`, no `_id` | Acknowledged. Checks only for not `nil` |
| `/insert_100` | `col:insert(docs, nil, true)` into `write`, 100 docs, no `_id` | Batch encode. Checks only for not `nil` |
| `/update` | `col:update({_id = rand(1, 1000)}, {["$inc"] = {age = 1}}, nil, nil, true)` on `write` | |
| `/delete_insert` | on `write`: insert one doc with `_id = next_id()`, then `col:delete({_id = id}, 1, true)` | Keeps the size flat. `next_id()` is a module-level counter from 1,000,001; it is unique because `worker_processes 1` and the collection is re-seeded before each API |
| `/find_and_modify` | `col:find_and_modify({query = {_id = rand(1, 1000)}, update = {["$inc"] = {age = 1}}})` on `write` | Builds a new `options` table for each request |
| `/gridfs_read` | `fs:find_one({filename = "f1m"}):read(1048576, 0)` | Large reply |
| `/auth` | `db:auth_scram_sha1("bench", "bench")` on a pooled socket | SCRAM-SHA-1 on 4.4 for both drivers. Not `db:auth`: the old one is MONGODB-CR (removed in 4.0), the new one picks SCRAM-SHA-256 after an extra `hello` |
| `/connect_nopool` | `connect`, `ping`, `close` | Cost of a new socket |
| `/reuse` | `connect`, then return `conn:get_reused_times()` as the body | Not benchmarked. Used by `reuse check` only |

Expected in the report: the new driver caches the salted password (`lib/resty/mongol/scram.lua`), while the old one runs PBKDF2 in Lua on every call. A large `/auth` gain is expected, not a measurement error.

---

## Task 1: Bench server and handlers

**Files:**
- Create: `bench/nginx.conf.in`, `bench/handlers.lua`, `bench/seed.lua`, `bench/server_status.lua`
- Test: `bench/smoke.sh`

**Interfaces:**
- Produces: `MONGOL_LIB` (directory that holds `resty/mongol/`), used only by `ctl.sh` to render `nginx.conf.in` with `envsubst`.
- Produces: `MONGO_HOST`, `MONGO_PORT`, `MONGO_ADMIN_USER`, `MONGO_ADMIN_PASSWORD` (default `admin` / `admin`) environment variables, passed to Lua with `env` directives and read with `os.getenv`. Only `seed.lua` and `server_status.lua` use the admin credentials. Both always load the new driver (`resty -I <new>/lib`, `/src/new/lib` on Kubernetes), because the old driver would write GridFS with its own chunking and run `createUser` through `OP_QUERY`, and only the new driver works on the `trend` servers.
- Produces: `handlers.<name>()` for each location in the table above, including `/reuse`. Each one calls `ngx.exit(200)` on success and `ngx.exit(500)` with the error in `ngx.log(ngx.ERR, ...)` on failure.
- Produces: `resty bench/seed.lua` logs in to `admin` with the admin credentials, drops and re-creates the fixture collections, creates the user `bench` / `bench` (role `readWrite` on database `bench`, mechanism SCRAM-SHA-1 only) if `usersInfo` does not list it, and exits 0. It is safe to run any number of times while nginx is up; the smoke test runs it twice in a row.

- [ ] **Step 1: Write `bench/smoke.sh`.** Mongo runs with `MONGO_INITDB_ROOT_USERNAME=admin` and `MONGO_INITDB_ROOT_PASSWORD=admin`. The script renders the conf and starts nginx with `-p` on a temp prefix, runs the seed, and sends one `curl` to each location. Cases: `smoke: all 200` (every location returns 200), `smoke: empty collection` (drop `read`, then `/find_one` returns 500), `smoke: seed twice` (a second `seed.lua` run exits 0, and `/find_one` on a pooled socket still returns 200).
- [ ] **Step 2: Run `MONGOL_LIB=<new>/lib bench/smoke.sh` against `mongo:4.4`.** Expected: fails, because no handlers exist.
- [ ] **Step 3: Write `nginx.conf.in`, `handlers.lua`, `seed.lua`, `server_status.lua`.** Use `math.random` seeded once in `init_worker_by_lua_block`. Add `exclude_files` patterns for `bench/` and `docs/perf/` to `dist.ini`, and check with `opm build` that the tarball does not contain them.
- [ ] **Step 4: Run the smoke test with the new driver and with the old driver (`MONGOL_LIB=<3eb6349 checkout>/lib`, for example from `git worktree add ../mongol-old 3eb6349`), both against `mongo:4.4`.** Expected: both pass. If the old driver fails one location, find the API form that both accept, or mark the location old-unsupported in `handlers.lua` with the reason.
- [ ] **Step 5: Commit** `test(bench): add bench server, handlers and seed`.

## Task 2: Load runner

**Files:**
- Create: `bench/ctl.sh`, `bench/load.sh`, `bench/run.sh`, `bench/wrk_report.lua`
- Modify: `bench/smoke.sh` (use `ctl.sh` to start and stop nginx)

**Interfaces:**
- Consumes: Task 1 locations and environment variables.
- Produces: `bench/ctl.sh` and `bench/load.sh` as in the File Structure table. `load.sh` reads `RUN_BASE` (default 0) and numbers its runs `RUN_BASE + 1` to `RUN_BASE + RUNS`. Logs go to `$WORK/logs/` and results to `$WORK/results/` (`WORK` defaults to `bench/`), so on Kubernetes both containers see them on the shared `/work` volume.
- Produces: `bench/run.sh <label> [api ...]`. With no API names, it runs all of them. `RUNS` (default 3) sets the wrk runs for each API. It writes `$WORK/results/<label>.jsonl`.
- Produces: one JSON line for each run: `{"label", "driver_sha", "mongo_version", "api", "run", "rps", "p50_ms", "p90_ms", "p99_ms", "non2xx", "socket_errors"}`.

- [ ] **Step 1: Write the checks in `ctl.sh` as subcommands that exit non-zero.** Case `reuse check`: after the `/find_one` run, `curl /reuse` returns a reused count above 0. Also, `ctl.sh check-conns` (which runs `resty bench/server_status.lua`; no Mongo shell is needed) reports `connections.current` at most 105. Other cases: `reseed between APIs` (the count of `read` is 1,000 before each API), `error log clean` (no `[error]` line in `error.log`).
- [ ] **Step 2: Write `wrk_report.lua`.** It uses `done(summary, latency, requests)` and prints the JSON line to stdout. The latency values come from `latency:percentile(50)` and so on, converted from microseconds to milliseconds.
- [ ] **Step 3: Write `ctl.sh`, `load.sh` and `run.sh`.** For each API: `ctl.sh seed` (drops and re-seeds the `read`, `write`, `fs.files` and `fs.chunks` collections; keeps the database and the `bench` user), `load.sh` (warm up for 10 seconds, `RUNS` wrk runs of 30 seconds, append each line), `ctl.sh check-log`. `run.sh` starts nginx once with `ctl.sh start` and stops it on exit with a `trap`.
- [ ] **Step 4: Run `bench/run.sh new-local find_one ping` against `mongo:4.4`.** Expected: 6 lines in `results/new-local.jsonl`, `non2xx` is 0, and the script exits 0.
- [ ] **Step 5: Run `shellcheck` and `shfmt -w -i 2 -ci -bn -sr -s` on the scripts, then commit** `test(bench): add wrk runner and JSON report`.

## Task 3: Compare and report

**Files:**
- Create: `bench/compare.lua`
- Test: `bench/t/compare_test.lua` with fixture files `bench/t/old.jsonl` and `bench/t/new.jsonl`

**Interfaces:**
- Consumes: the JSON line format from Task 2.
- Produces: `resty bench/compare.lua <old.jsonl> <new.jsonl>` prints a Markdown table: API, old rps, new rps, ratio, old p99, new p99, ratio, result. If any API is `fail`, it exits 1.
- Produces: `resty bench/compare.lua --trend <new-4.4.jsonl> <new-6.0.jsonl> ...` prints one row per API and one column pair (median rps, median p99) per file, labelled by the file's `mongo_version`. It has no pass or fail and always exits 0. Task 5 uses it for the trend table.

- [ ] **Step 1: Write the test cases.**
  - `pass`: new rps 95% of old, p99 110%.
  - `fail on rps`: new rps 85%.
  - `fail on p99`: p99 130%.
  - `median of three`: runs 100, 300, 200 give 200.
  - `missing side`: an API only in new gives `n/a (old)` and does not fail.
  - `trend`: three files give one row per API with three column pairs, and exit 0.
- [ ] **Step 2: Run `resty bench/t/compare_test.lua`.** Expected: fails, no `compare.lua`.
- [ ] **Step 3: Write `compare.lua`.** The thresholds are constants at the top of the file: `MIN_RPS_RATIO = 0.90`, `MAX_P99_RATIO = 1.20`.
- [ ] **Step 4: Run the test.** Expected: all cases pass.
- [ ] **Step 5: Commit** `test(bench): add result compare script`.

## Task 4: BSON micro benchmark and Kubernetes runner

**Files:**
- Create: `bench/bson_micro.lua`, `bench/k8s/mongo.yaml`, `bench/k8s/bench.yaml`, `bench/k8s/run-k8s.sh`

**Interfaces:**
- Consumes: `run.sh`, `compare.lua`.
- Produces: `resty -I <lib> bench/bson_micro.lua` picks an adapter by driver: the new driver has `bson.to_bson(t)` and `bson.decode(s)` (`lib/resty/mongol/bson.lua`); the old one has `to_bson(t)` and `from_bson(get.get_from_string(s))`, using the reader from its `get.lua`. It prints one JSON line for each case: `encode_small`, `decode_small` (the fixture doc), `encode_large`, `decode_large` (a doc with 1,000 string fields). Each line has `ops_per_s` over 2 seconds after 100,000 warm-up loops.
- Produces: `bench/k8s/run-k8s.sh <ab|trend|all>`. Required variables: `KUBE_CONTEXT`, `MONGO_NODE`, `BENCH_NODE`, `NEW_REF`. Optional: `OLD_REF` (default `3eb6349`). It writes `bench/results/k8s-<date>/` on your machine.
- Produces: `bench.yaml` paths in the Pod: `/src/old/lib`, `/src/new/lib`, `/src/new/bench`, and `/work` (logs and results), all mounted in both containers. The `wrk` container calls the `nginx` container on `127.0.0.1:8090`. `run-k8s.sh` restarts nginx with a different `MONGOL_LIB` through `kubectl exec -c nginx -- /src/new/bench/ctl.sh ...`, and runs load through `kubectl exec -c wrk -- /src/new/bench/load.sh ...`.

- [ ] **Step 1: Write `bson_micro.lua`.** Use `ngx.update_time()` and `ngx.now()` for timing. Call `collectgarbage()` before each case.
- [ ] **Step 2: Run it with both `lib` directories.** Expected: 4 lines each, no Lua error.
- [ ] **Step 3: Write `mongo.yaml` and `bench.yaml`.** Mongo starts with `MONGO_INITDB_ROOT_USERNAME=admin`, `MONGO_INITDB_ROOT_PASSWORD=admin` and `--wiredTigerCacheSizeGB 1.5`, with the storage limits from Global Constraints. Its readiness probe is a `tcpSocket` probe on 27017, because `mongo:4.4` has only the `mongo` shell and `mongo:6.0` and later have only `mongosh`. After the Pods are ready, `run-k8s.sh` also waits until `ctl.sh check-conns` succeeds, which proves that auth works. The `wrk` container installs `wrk` with `apt-get` when it starts. `run-k8s.sh` fills the template values with `envsubst`.
- [ ] **Step 4: Write `run-k8s.sh`.** Order of work:
  1. If `KUBE_CONTEXT` or a node variable is empty, exit 2 with a usage line.
  2. Create the namespace, apply `mongo.yaml` with tag `4.4`, apply `bench.yaml`, wait for both Pods to be ready.
  3. Mode `ab`: run `interleaved order` with `RUNS=1`: `old-1`, `new-1`, `old-2`, `new-2`, `old-3`, `new-3`, each one a full pass over all APIs. That gives 3 runs per API per side. Then concatenate `old-1..3.jsonl` into `old.jsonl` and `new-1..3.jsonl` into `new.jsonl`; each line keeps its `label`. `run-k8s.sh` passes `RUN_BASE=N-1` to `load.sh`, which writes `run = RUN_BASE + i`, so the joined file has runs 1, 2 and 3 and `compare.lua` takes the median of the three lines per API. Run `bson_micro.lua` for both libs.
  4. Mode `trend`: for each tag `6.0`, `7.0`, `8.0`, `9.0`, replace the Mongo Pod and run `new` once with `RUNS=3`, into `new-<tag>.jsonl`. In mode `all`, the joined `new.jsonl` from `ab` is the 4.4 column. `run-k8s.sh` prints the table from `compare.lua --trend`.
  5. Copy `/src/new/bench/results/` back with `kubectl cp`. Run `compare.lua` on your machine.
  6. Delete the namespace in a `trap`, also when a step fails.
- [ ] **Step 5: Run `shellcheck` and `shfmt -w -i 2 -ci -bn -sr -s` on `run-k8s.sh`.**

  Time budget, with about 10 s of warm-up and re-seed per API: `RUNS=3` takes about 100 s per API, so about 20 minutes per pass over 12 APIs. `ab` is 6 passes with `RUNS=1` (about 40 s per API), so about 50 minutes. `trend` is 4 passes with `RUNS=3`, so about 80 minutes. `all` takes about 2 hours 10 minutes, and Task 5's three runs of `all` about 6.5 hours.
- [ ] **Step 6: Run `bench/k8s/run-k8s.sh ab` with `NEW_REF` set to the pushed branch.** Expected: the script prints the compare table, `bench/results/k8s-<date>/` has `old.jsonl` and `new.jsonl`, and `kubectl --context "$KUBE_CONTEXT" get ns mongol-bench` reports `NotFound`.
  Example, with placeholders for the real names:
  ```bash
  tsh kube login <cluster>
  KUBE_CONTEXT=<context> MONGO_NODE=<node-a> BENCH_NODE=<node-b> \
    NEW_REF=<branch-or-sha> bench/k8s/run-k8s.sh ab
  ```
- [ ] **Step 7: Commit** `test(bench): add Kubernetes runner`.

## Task 5: First run and report

**Files:**
- Create: `docs/perf/perf-2026-10-27.md` (use the date of the run)

- [ ] **Step 1: Run `bench/k8s/run-k8s.sh all` three times.** Write down each API that passes in one run and fails in another. The report lists it as unstable.
- [ ] **Step 2: Write the report.** It has these sections:
  - Setup: cluster context, node types, Pod resources, SHAs, server versions.
  - A/B table, trend table, BSON micro table.
  - A note that the `/auth` gain comes from the cached salted password in the new driver.
  - Failed or unstable APIs, with the cause when a profile shows it.
- [ ] **Step 3: If an API fails, open a GitHub issue for it with label `needs-triage`.** Do not fix the driver in this plan.
- [ ] **Step 4: Commit** `docs(bench): add first performance report`.
