# Performance Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure the throughput and latency of each public API of the modernized driver. Compare them with the old driver on the same server and machine.

**Architecture:** One OpenResty server loads the driver from a directory that you select with `MONGOL_LIB`. It has one HTTP location for each API under test. `wrk` sends load to one location at a time and writes one JSON line for each run. A compare script reads two result files and writes a Markdown report with a pass or fail for each API. A separate `resty` script measures BSON encode and decode without the network.

**Tech Stack:** OpenResty 1.31.1.1, `wrk` 4.2.0 with its Lua hooks, `resty` CLI and `cjson`. MongoDB Docker images `mongo:4.4` and `mongo:6.0` to `mongo:9.0`. Kubernetes through Teleport (`tsh kube login`), with `kubectl` and the official image `openresty/openresty:1.31.1.1-jammy`.

**Spec:** No separate spec. This plan follows `docs/superpowers/specs/2026-10-25-modernize-driver-design.md` and `docs/superpowers/plans/2026-10-25-modernize-driver.md`.

## Global Constraints

- Old driver: commit `3eb6349`, the last commit before the modernization. It speaks `OP_QUERY`, so it runs only against `mongo:4.4`.
- New driver: `master` at 1.0.0 (`173b314`) or a later ref. Record its commit SHA in every result line.
- A/B rule: the old and new driver run on `mongo:4.4`, on the same machine, in the same job, one after the other. Only this pair decides pass or fail.
- Trend rule: the new driver also runs on `mongo:6.0`, `mongo:7.0`, `mongo:8.0` and `mongo:9.0`. These numbers are for information. They do not gate.
- Handlers use only the API forms that both drivers accept: no arrays in documents, whole numbers below 2^31, no BSON types that Phase 4 adds.
- Nginx: `worker_processes 1`, `lua_code_cache on`, `access_log off`, `error_log` at `warn`.
- Connection reuse: every handler ends with `conn:set_keepalive(10000, 100)`. The `connect_nopool` location is the only exception.
- Load: `wrk -t2 -c32 -d30s --latency` after a 10 second warm-up. Three runs for each API. The report uses the median run.
- Pass threshold (owner decision, 2026-10-27): for each API on `mongo:4.4`, new req/s is at least 90% of old req/s. New p99 latency is at most 120% of old p99.
- Cluster: Kubernetes, reached through Teleport. `run-k8s.sh` requires `KUBE_CONTEXT` and passes `--context "$KUBE_CONTEXT"` to every `kubectl` call. It never uses the current context.
- Namespace: `mongol-bench`, created and deleted by `run-k8s.sh`. The script changes no other namespace.
- Placement: the Mongo Pod and the bench Pod run on two different nodes, set with `nodeSelector` values from `MONGO_NODE` and `BENCH_NODE`. The same two nodes serve all runs.
- Resources, with requests equal to limits: Mongo 2 CPU and 4Gi, storage on an `emptyDir`. Container `nginx` 1 CPU and 512Mi. Container `wrk` 2 CPU and 512Mi.
- Code: an init container (`alpine/git`) clones `https://github.com/Laobei2012/lua-resty-mongol` at `OLD_REF` and `NEW_REF` into an `emptyDir`. There is no custom image and no registry.
- Trigger: by hand only (owner decision, 2026-10-27). There is no GitHub Actions job.
- A run with any non-2xx response or any `[error]` line in `error.log` is invalid. The runner exits non-zero.
- The bench files live under `bench/`. They are not installed by `make install` and not run by `make test`.
- Commit style: `type(scope): description`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A handler that fails silently, for example `find_one` returns `nil` because the seed data is missing. Expected: the handler returns HTTP 500 and wrk counts it as a non-2xx response, so the run is invalid. Test: Task 1, `smoke: empty collection`.
2. A socket leak, where the new driver closes or does not return sockets to the pool. Expected: after a run, `get_reused_times()` is above 0 in the `reuse` location, and the server `connections.current` stays at most 100 + 5. Test: Task 2, `reuse check`.
3. Writes that grow the collection during a run, so later runs read more data than earlier runs. Expected: write handlers use their own collection, and the runner drops and re-seeds before each API. Test: Task 2, `reseed between APIs`.
4. Noise from other workloads on the cluster nodes. Expected: the old and new runs alternate (old, new, old, new, old, new), so drift affects both sides. The pods have the Guaranteed QoS class (CPU requests equal limits). Test: Task 4, `interleaved order`.
5. The old driver raising a Lua error on an API that it does not support. Expected: the report marks the API `n/a (old)`, not `fail`. Test: Task 3, `missing side`.

---

## File Structure

| File | Responsibility |
|---|---|
| `bench/nginx.conf` | Server on port 8090. `lua_package_path` built from `MONGOL_LIB`. One location for each API |
| `bench/handlers.lua` | One function for each API. Each one does one driver call, checks the result, returns 200 or 500 |
| `bench/seed.lua` | `resty` script. Drops `bench` database, inserts fixtures |
| `bench/wrk_report.lua` | wrk `done()` hook. Prints one JSON line: req/s, p50, p90, p99, errors |
| `bench/run.sh` | Starts nginx, seeds, warms up, runs wrk for each API, writes `results/<label>.jsonl` |
| `bench/compare.lua` | `resty` script. Reads two `.jsonl` files and writes a Markdown table with pass or fail |
| `bench/bson_micro.lua` | `resty` script. Encode and decode loops, prints ops/s |
| `bench/k8s/mongo.yaml` | Mongo Pod and Service. The image tag is a template value |
| `bench/k8s/bench.yaml` | Bench Pod: init container clones both refs, container `nginx`, container `wrk` |
| `bench/k8s/run-k8s.sh` | Applies the manifests, runs the A/B and trend runs, copies the results back, deletes the namespace |
| `REPORT/perf-<date>.md` | First report, written in Task 5 |

## APIs under test

Fixtures: collection `read` has 1,000 documents `{_id = i, name = "user" .. i, age = i % 100, tags = "a b c", body = <200 byte string>}` with an index on `age`. GridFS bucket `fs` has one file `f1m` of 1 MiB.

| Location | Driver call | Notes |
|---|---|---|
| `/ping` | `db:cmd({ping = 1})` | Wire round trip floor |
| `/find_one` | `col:find_one({_id = rand(1, 1000)})` | Point read |
| `/find_100` | `col:find(...)` with `limit(100)`, iterate all | Cursor and `getMore`, batch size 50 |
| `/count` | `col:count({age = 7})` | |
| `/insert_1` | `col:insert({doc}, nil, true)` into `write` | Acknowledged |
| `/insert_100` | `col:insert(docs, nil, true)`, 100 docs | Batch encode |
| `/update` | `col:update({_id = rand}, {["$inc"] = {age = 1}}, nil, nil, true)` | |
| `/delete_insert` | insert one doc, then `col:delete({_id = id}, 1, true)` | Keeps the size flat |
| `/find_and_modify` | `col:find_and_modify({query = ..., update = ...})` | |
| `/gridfs_read` | `fs:find_one({filename = "f1m"}):read(1048576, 0)` | Large reply |
| `/auth` | `db:auth("bench", "bench")` on a pooled socket | SCRAM-SHA-1 on 4.4 for both drivers |
| `/connect_nopool` | `connect`, `ping`, `close` | Cost of a new socket |

---

## Task 1: Bench server and handlers

**Files:**
- Create: `bench/nginx.conf`, `bench/handlers.lua`, `bench/seed.lua`
- Test: `bench/smoke.sh`

**Interfaces:**
- Produces: `MONGOL_LIB` (directory that holds `resty/mongol/`), `MONGO_HOST`, `MONGO_PORT`, `MONGO_AUTH` (`0` or `1`) environment variables, read with `env` directives and `os.getenv`.
- Produces: `handlers.<name>()` for each location in the table above. Each one calls `ngx.exit(200)` on success and `ngx.exit(500)` with the error in `ngx.log(ngx.ERR, ...)` on failure.
- Produces: `resty bench/seed.lua` exits 0 after it creates the fixtures and the user `bench` / `bench` with role `readWrite` on database `bench`.

- [ ] **Step 1: Write `bench/smoke.sh`.** It starts nginx with `-p` on a temp prefix, runs the seed, and sends one `curl` to each location. Cases: `smoke: all 200` (every location returns 200), `smoke: empty collection` (drop `read`, then `/find_one` returns 500).
- [ ] **Step 2: Run `MONGOL_LIB=<new>/lib bench/smoke.sh` against `mongo:4.4`.** Expected: fails, because no handlers exist.
- [ ] **Step 3: Write `nginx.conf`, `handlers.lua`, `seed.lua`.** Use `math.random` seeded once in `init_worker_by_lua_block`.
- [ ] **Step 4: Run the smoke test with the new driver and with the old driver (`MONGOL_LIB=<master>/lib`), both against `mongo:4.4`.** Expected: both pass. If the old driver fails one location, find the API form that both accept, or mark the location old-unsupported in `handlers.lua` with the reason.
- [ ] **Step 5: Commit** `test(bench): add bench server, handlers and seed`.

## Task 2: Load runner

**Files:**
- Create: `bench/run.sh`, `bench/wrk_report.lua`
- Modify: `bench/smoke.sh` (reuse the start and stop functions from `run.sh`)

**Interfaces:**
- Consumes: Task 1 locations and environment variables.
- Produces: `bench/run.sh <label> [api ...]`. With no API names, it runs all of them. It writes `bench/results/<label>.jsonl`.
- Produces: one JSON line for each run: `{"label", "driver_sha", "mongo_version", "api", "run", "rps", "p50_ms", "p90_ms", "p99_ms", "non2xx", "socket_errors"}`.

- [ ] **Step 1: Write the checks in `run.sh` as functions that exit non-zero.** Case `reuse check`: after the `/find_one` run, `/reuse` returns a reused count above 0. Also, `db.serverStatus().connections.current` is at most 105. Other cases: `reseed between APIs` (the count of `read` is 1,000 before each API), `error log clean` (no `[error]` line in `error.log`).
- [ ] **Step 2: Write `wrk_report.lua`.** It uses `done(summary, latency, requests)` and prints the JSON line to stdout. The latency values come from `latency:percentile(50)` and so on, converted from microseconds to milliseconds.
- [ ] **Step 3: Write `run.sh`.** For each API: re-seed, warm up for 10 seconds, three wrk runs of 30 seconds, append each line. Stop nginx on exit with a `trap`.
- [ ] **Step 4: Run `bench/run.sh new-local find_one ping` against `mongo:4.4`.** Expected: 6 lines in `results/new-local.jsonl`, `non2xx` is 0, and the script exits 0.
- [ ] **Step 5: Run `shellcheck` and `shfmt -w -i 2 -ci -bn -sr -s` on the scripts, then commit** `test(bench): add wrk runner and JSON report`.

## Task 3: Compare and report

**Files:**
- Create: `bench/compare.lua`
- Test: `bench/t/compare_test.lua` with fixture files `bench/t/old.jsonl` and `bench/t/new.jsonl`

**Interfaces:**
- Consumes: the JSON line format from Task 2.
- Produces: `resty bench/compare.lua <old.jsonl> <new.jsonl>` prints a Markdown table: API, old rps, new rps, ratio, old p99, new p99, ratio, result. If any API is `fail`, it exits 1.

- [ ] **Step 1: Write the test cases.**
  - `pass`: new rps 95% of old, p99 110%.
  - `fail on rps`: new rps 85%.
  - `fail on p99`: p99 130%.
  - `median of three`: runs 100, 300, 200 give 200.
  - `missing side`: an API only in new gives `n/a (old)` and does not fail.
- [ ] **Step 2: Run `resty bench/t/compare_test.lua`.** Expected: fails, no `compare.lua`.
- [ ] **Step 3: Write `compare.lua`.** The thresholds are constants at the top of the file: `MIN_RPS_RATIO = 0.90`, `MAX_P99_RATIO = 1.20`.
- [ ] **Step 4: Run the test.** Expected: all cases pass.
- [ ] **Step 5: Commit** `test(bench): add result compare script`.

## Task 4: BSON micro benchmark and Kubernetes runner

**Files:**
- Create: `bench/bson_micro.lua`, `bench/k8s/mongo.yaml`, `bench/k8s/bench.yaml`, `bench/k8s/run-k8s.sh`

**Interfaces:**
- Consumes: `run.sh`, `compare.lua`.
- Produces: `resty -I <lib> bench/bson_micro.lua` prints one JSON line for each case: `encode_small`, `decode_small` (the fixture doc), `encode_large`, `decode_large` (a doc with 1,000 string fields). Each line has `ops_per_s` over 2 seconds after 100,000 warm-up loops.
- Produces: `bench/k8s/run-k8s.sh <ab|trend|all>`. Required variables: `KUBE_CONTEXT`, `MONGO_NODE`, `BENCH_NODE`, `NEW_REF`. Optional: `OLD_REF` (default `3eb6349`). It writes `bench/results/k8s-<date>/` on your machine.
- Produces: `bench.yaml` paths in the Pod: `/src/old/lib`, `/src/new/lib`, `/src/new/bench`. The `wrk` container calls the `nginx` container on `127.0.0.1:8090`.

- [ ] **Step 1: Write `bson_micro.lua`.** Use `ngx.update_time()` and `ngx.now()` for timing. Call `collectgarbage()` before each case.
- [ ] **Step 2: Run it with both `lib` directories.** Expected: 4 lines each, no Lua error.
- [ ] **Step 3: Write `mongo.yaml` and `bench.yaml`.** Mongo starts with `MONGO_INITDB_ROOT_USERNAME=admin` and `MONGO_INITDB_ROOT_PASSWORD=admin`, and has a readiness probe that runs `ping`. The `wrk` container installs `wrk` with `apt-get` when it starts. `run-k8s.sh` fills the template values with `envsubst`.
- [ ] **Step 4: Write `run-k8s.sh`.** Order of work:
  1. If `KUBE_CONTEXT` or a node variable is empty, exit 2 with a usage line.
  2. Create the namespace, apply `mongo.yaml` with tag `4.4`, apply `bench.yaml`, wait for both Pods to be ready.
  3. Mode `ab`: run `interleaved order` with `kubectl exec`: `old-1`, `new-1`, `old-2`, `new-2`, `old-3`, `new-3`. Run `bson_micro.lua` for both libs.
  4. Mode `trend`: for each tag `6.0`, `7.0`, `8.0`, `9.0`, replace the Mongo Pod and run `new` once.
  5. Copy `/src/new/bench/results/` back with `kubectl cp`. Run `compare.lua` on your machine.
  6. Delete the namespace in a `trap`, also when a step fails.
- [ ] **Step 5: Run `shellcheck` and `shfmt -w -i 2 -ci -bn -sr -s` on `run-k8s.sh`.**
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
- Create: `REPORT/perf-2026-10-27.md` (use the date of the run)

- [ ] **Step 1: Run `bench/k8s/run-k8s.sh all` three times.** Write down each API that passes in one run and fails in another. The report lists it as unstable.
- [ ] **Step 2: Write the report.** It has these sections:
  - Setup: cluster context, node types, Pod resources, SHAs, server versions.
  - A/B table, trend table, BSON micro table.
  - Failed or unstable APIs, with the cause when a profile shows it.
- [ ] **Step 3: If an API fails, open a GitHub issue for it with label `needs-triage`.** Do not fix the driver in this plan.
- [ ] **Step 4: Commit** `docs(bench): add first performance report`.
