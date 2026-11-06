# Issue #103 investigation

Issue: <https://github.com/Laobei2012/lua-resty-mongol/issues/103>

The published p99 failures reproduce. The available cluster measurements
do not establish a driver regression or identify the source of the delay.
Further local probes reproduce the higher new-driver HTTP p99 without CPU
quotas, but put most slow-insert time inside cosocket calls. The new
driver's measured local execution is faster. A paced comparison at about
1,000 requests/s favors the new driver. These findings narrow the next
cluster experiment; they do not establish the original cluster's cause.

A cluster run on 2026-11-04 found the source of the tail. It is in
MongoDB, not in the driver code. About every 6 to 30 seconds, all 16
in-flight inserts stop together for 100 to 270 ms. In these stalls, the
writer threads wait for a WiredTiger page that eviction holds locked.
The new/old p99 difference is not significant (p = 0.35 unpaced and 0.75
at an equal rate). The new driver has a lower p50 and a higher throughput.
A write-path test on 2026-11-05 shows that the OP_MSG insert path does
not cause more stalls than OP_INSERT with `getlasterror`.
See [Cluster run: source of the stalls](#cluster-run-source-of-the-stalls).

## Replay of the original results

Run from the repository root, replacing `run-1` with `run-2` and `run-3`:

```sh
data=docs/perf/perf-2026-10-31-data/run-1
resty bench/compare.lua --cpu-file "$data/cpu.jsonl" \
  "$data/old.jsonl" "$data/new.jsonl"
```

All three invocations were executed during this investigation:

| Full run | Old p99, ms | New p99, ms | Ratio | Comparison exit |
| --- | ---: | ---: | ---: | ---: |
| 1 | 71.204 | 108.312 | 1.521 | 1 |
| 2 | 77.387 | 77.118 | 0.997 | 0 |
| 3 | 79.437 | 97.829 | 1.232 | 1 |

Every `insert_100` CPU interval passes the existing validity check.
The recorded nginx CPU costs are respectively 565.531/414.448,
578.682/373.974 and 569.444/422.193 microseconds per request (old/new).

Here are all nine samples on each side. The values are sample p99s, not
individual request latencies. Numbered pass files and joined files contain
the same observations and must not both be counted.

| Full run | Old sample p99s, ms | New sample p99s, ms |
| --- | --- | --- |
| 1 | 98.169, 71.204, 62.520 | 57.021, 128.570, 108.312 |
| 2 | 77.387, 84.701, 52.562 | 56.582, 94.362, 77.118 |
| 3 | 79.437, 120.737, 59.690 | 104.693, 97.829, 61.876 |

Across these samples, median p50 is 13.525 ms old / 13.293 ms new;
median p90 is 28.210 / 28.420 ms. The instability is in the tail,
and the old driver also has large outliers. This does not disprove a
new-driver tail regression.

## What the benchmark does

- `bench/handlers.lua:insert_100` allocates 100 documents and performs one
  acknowledged collection insert. It writes into the collection with both
  the `_id` index and the `age_1` index created by `bench/seed.lua`.
- `bench/k8s/run-k8s.sh:pass` reseeds before each API/pass. The original A/B
  calls use one measured sample per pass; each starts with fresh fixtures
  followed by a ten-second warm-up and a thirty-second measurement.
- At roughly 1,100 requests/s, those forty seconds insert roughly 4.4 million
  documents. Trend passes reseed once before three consecutive measurements,
  so they have a different collection-growth history. They are not repeated
  A/B trials on the same server version.
- The old driver uses OP_INSERT followed by getLastError. The new driver
  sends an acknowledged write command with an OP_MSG document sequence.
  The write comparison includes this server protocol difference.
- CPU snapshots cover a whole API/pass, not individual slow requests.
  The quota-throttling rule does not measure scheduling waits, disk stalls,
  WiredTiger eviction, or Lua GC pauses. Public rows have no request-level
  server/driver timing that could assign the p99 spikes to one of these.

## Local diagnostic run (2026-11-03 UTC)

A Docker probe used the exact old/new driver commits, authenticated MongoDB
4.4.30, OpenResty 1.31.1.1 and wrk 4.1.0 on ARM64. It ran only `insert_100`,
old first then new, with the existing `ctl.sh` and `load.sh`: a fresh seed
per driver, ten seconds of warm-up and five consecutive thirty-second samples
at two threads / sixteen connections. It did not reseed between samples.

This probe is **invalid for regression attribution**. An initial attempt
combined nginx and wrk under a one-core quota and throttled; it was stopped
and discarded. The retained attempt raised that combined quota to four
cores and Mongo's quota to four cores. Nginx/wrk then had no throttled
periods, but Mongo still throttled. It also uses one Docker VM instead of
two Kubernetes nodes, different CPU quotas and a longer collection-growth
history. It cannot reproduce the original environment or pass its validity
requirements. A higher new-driver p99 here cannot confirm issue #103.

Raw samples are `local-old.jsonl` and `local-new.jsonl`. Per-driver
`local-*-cpu-*.stat` files measure the combined nginx/wrk cgroup over the
whole pass. The Mongo observation snapshots start during the first old
pass and end after the new pass; they prove throttling occurred during the
probe, but cannot attribute it to a particular request or pass. They must
not be substituted for the original runner's per-container/per-pass CPU
diagnostics.

| Driver | Five sample p99s, ms | Median p99, ms | Median requests/s |
| --- | --- | ---: | ---: |
| Old | 18.974, 11.589, 16.262, 17.779, 12.042 | 16.262 | 4899.06 |
| New | 37.615, 43.875, 44.155, 46.463, 40.623 | 43.875 | 5807.71 |

All ten samples have zero HTTP/socket errors. The combined nginx/wrk cgroup
has zero throttled periods in both pass intervals. Across the Mongo observation
window, 1,469 of 3,178 periods were throttled (46.224%); the original gate
requires less than 1%. These local p99 medians are descriptive only and must
not be presented as a valid failed gate. The old samples do not show a
monotonic increase with collection growth; the probe does not establish
collection growth as the cause of the original tail.

Image identities:

- Mongo: `sha256:92b9fc17da1b28044672708bca03e23948e0965110cdad3aefbe46ab506d03e9`.
- Local bench image: `sha256:3602d845bda87010398bda10d12328eb91c169e55bfff73aef957580d48e237d`.

## Continued investigation: no CPU quotas

The continued probes use the same ARM64 Docker VM, MongoDB 4.4.30 and
driver commits, with no CPU quotas on either container (`cpu.max` is
`max 100000`). Mongo keeps its 4Gi memory limit and 1.5GiB WiredTiger cache.
Nginx and wrk share a 512Mi container. CPU pressure counters are unavailable
in this VM, so zero quota throttling does not exclude scheduling delays.

Three old/new pairs use the original handler and wrk reporter, a new seed
before each pass, a 10s warm-up and one 30s sample at `-t2 -c16`. All six
intervals have zero throttled periods and zero HTTP/socket errors.

| Pair | Old requests/s | New requests/s | Old p99, ms | New p99, ms |
| --- | ---: | ---: | ---: | ---: |
| 1 | 5259.15 | 8051.45 | 12.991 | 27.912 |
| 2 | 5201.53 | 7827.58 | 16.424 | 14.456 |
| 3 | 5269.56 | 8057.21 | 14.229 | 25.938 |

The median p99 ratio is 1.823, while the throughput ratio is 1.531.
The tail is still unstable without quotas. This is a mechanism probe,
not a run of the approved Kubernetes resource profile or its validity gate.
The workload reaches substantially higher rates than in the issue.

Mongo `opLatencies.writes` mean latency over these API intervals is
524.5 / 747.1 microseconds (old/new) in pair 1, 539.6 / 776.9 in pair 2,
and 543.3 / 794.8 in pair 3. These intervals include warm-up as well as
measurement. They cannot correlate an individual HTTP outlier with a
server operation. The histogram counters are captured using
[`serverStatus` with `opLatencies.histograms`](https://www.mongodb.com/docs/manual/reference/command/serverstatus/#oplatencies).

## Timing the driver and socket calls

`profile_handler.lua` is a separate diagnostic endpoint. It uses the same
100-document fixture and acknowledged insert, wraps the connection's
socket for that insert, then restores it before returning to the pool.
It never changes a driver module or the standard handler.

It measures elapsed time using Linux `CLOCK_MONOTONIC`:

- `total_ms`: the collection insert, excluding connection/authentication,
  document construction, keepalive and HTTP processing.
- `socket_ms`: elapsed time inside socket `send` and `receive` calls.
- `local_ms`: insert time minus socket time.
- `encode_ms`: insert entry to first socket send; this includes collection
  setup and encoding, rather than timing BSON alone.
- `build_ms`: construction of the 100 document tables.

The worker stores counters in 10-microsecond histogram bins. The reported
p99 values below are upper bounds for the selected bins, with up to
0.01ms rounding. Percentiles cannot be subtracted or added to assign time
to a particular request. The slow-request sums below *do* use the same
requests on both sides of the sum.

The load client uses the original reporter, with optional pacing through
[wrk's `delay()` hook](https://github.com/wg/wrk/blob/4.1.0/SCRIPTING).
Timing collection stays in nginx. Each driver is freshly seeded for each
mode; there is a 10s warm-up followed by one 30s measurement. Server timing
counters reset after warm-up. A few in-flight requests that complete after
wrk exits can appear in server counters but not wrk's completed count.

| Mode | Driver | Requests/s | HTTP p99, ms | Insert p99 upper, ms | Socket p99 upper, ms | Local p99 upper, ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Unpaced | Old | 4919.18 | 14.674 | 9.81 | 9.61 | 0.44 |
| Unpaced | New | 7430.61 | 18.696 | 9.55 | 9.44 | 0.30 |
| Paced | Old | 995.44 | 9.153 | 8.07 | 7.74 | 0.94 |
| Paced | New | 997.02 | 7.668 | 6.58 | 6.47 | 0.63 |

For unpaced inserts lasting at least 20ms, socket calls account for 99.33%
of summed insert time in the old driver (172 requests), and 99.66% in the
new driver (383 requests). The new driver's maximum measured local insert
time is below 1.52ms; its maximum insert time is below 72.45ms. The observed
tail is not explained by a long synchronous encoding interval in that run.

**Limits:** Socket time includes Mongo/network waits and the time until a
Lua coroutine resumes. It cannot distinguish those from event-loop or OS
scheduling delays, including delays caused by other requests. The profiler
allocates wrappers and samples clocks, so it is not identical to the standard
benchmark. The paced comparison is one pair and changes both offered load
and collection growth: it ends with about four million documents per side,
versus roughly 20/30 million unpaced. It supports a load/state-sensitive
explanation but cannot distinguish queueing from cache/storage behavior.
All four instrumented intervals have zero quota throttling and HTTP/socket
errors. No production driver optimization follows from these probes.

## Raw versus adjusted HTTP p99 on the same requests

The standard reporter calls `latency:percentile(99)` in wrk's `done()`
callback. In [wrk 4.1.0](https://github.com/wg/wrk/blob/4.1.0/src/wrk.c),
`stats_correct()` runs **before** that callback. It adds synthetic histogram
observations to compensate for coordinated omission. Its expected interval
is derived from total elapsed time, completed requests and connection count.
Consequently, the published HTTP p99 is not the unadjusted percentile of
completed requests, and the adjustment can differ between drivers with
different achieved rates.

`wrk-raw-p99.patch` adds two diagnostic prints to upstream wrk 4.1.0,
commit `7594a95186ebdfa7cb35477a8a811f84e2a31b62`: one before correction
and one after. It changes neither the request path nor `stats_correct()`.
Both prints happen after measurement has ended, and the ordinary Lua
reporter still receives the adjusted histogram. The diagnostic client was
built in a separate Docker image using the existing image's OpenResty LuaJIT
and OpenSSL libraries, rather than overwriting a running container's binary.
It therefore differs from the distro-packaged wrk in the earlier probes;
the raw/adjusted numbers within each sample use exactly the same requests.

The original, uninstrumented handler is used. The separate client container
shares the bench network namespace and has no CPU quota. The old/new sequence
repeats three times, reseeding before each pass, with a 10s warm-up and a
30s measurement at `-t2 -c16`. Mongo snapshots cover the measurement and
in-flight completion, excluding the warm-up in this probe.

| Pair | Old raw p99, ms | New raw p99, ms | Raw ratio | Old adjusted p99, ms | New adjusted p99, ms | Adjusted ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10.371 | 10.326 | 0.996 | 19.772 | 3024.578 | 152.973 |
| 2 | 9.459 | 9.755 | 1.031 | 14.253 | 18.958 | 1.330 |
| 3 | 11.656 | 9.491 | 0.814 | 25.284 | 12.844 | 0.508 |

All raw ratios are below 1.20. Two individual adjusted ratios exceed 1.20.
These are per-sample illustrations, **not** formal gate verdicts. The
median-of-three comparison in this probe passes for both raw p99
(10.371 / 9.755 ms old/new) and adjusted p99 (19.772 / 18.958 ms).

In new sample 1, wrk reports a real 4.14s maximum. Raw p99 is 10.326ms over
204,625 observations; correction raises p99 to 3,024.578ms over 258,384
observations. The additional 53,759 observations are synthetic. This
demonstrates amplification of a rare stall; it does not make the real stall
harmless or establish whether Mongo, the network, nginx, the client or VM
scheduling caused it. The original cluster's missing raw distributions
cannot be reconstructed from its three saved percentile values.

All six intervals have zero quota throttling and zero HTTP/socket errors.
The raw histogram count equals completed requests in each sample, and the
post-correction percentile exactly matches the standard reporter. Keep the
approved gates unchanged. For the next cluster reproduction, capture both
histograms and server/socket timings before assigning a driver cause.

## Sensitivity of the cluster p99 to one pause

In a closed loop, wrk's expected interval is the mean latency.
The original cluster samples ran at about 1,050 requests/s with 16
connections, so the interval is 14.1 to 15.9 ms. Each real request that
takes at least twice that interval adds synthetic observations.

`co_model.lua` applies the wrk 4.1.0 correction loop to a model sample.
The sample has 31,500 requests at 13 ms, except one pause that holds all
16 connections. Run it from the repository root:

```sh
resty bench/issue103/co_model.lua
```

| Pause, ms | Corrected p99, ms | Synthetic observations |
| ---: | ---: | ---: |
| 300 | 13.000 | 288 |
| 350 | 60.383 | 336 |
| 400 | 110.383 | 400 |
| 500 | 210.383 | 496 |

The pause adds 16 real requests, about 0.05% of the sample. It cannot
move the raw p99. But one pause of about 0.4 s in 30 s moves the
corrected p99 from 13 ms to above 100 ms. Above that point, the corrected
p99 rises by about 1 ms for each 1 ms of pause length. The difference
between 71.204 and 108.312 ms in run 1 is a 37 ms difference in pause
length under this model.

This is a model, not a measurement of the cluster. The real samples also
have a slow tail, which lowers the pause length that is necessary. The
cluster data does not record the maximum latency, so it cannot show
whether such pauses occurred. Standard wrk exposes `latency.max` to the
`done()` callback, and the correction does not change it. For the next
cluster run, record `latency.max` and the raw p99 with each sample.

`max_wrk.lua` loads the standard reporter and adds `max_ms` to its JSON
line. It does not change `bench/wrk_report.lua`, which `bench/report.py`
pins as part of the approved full-run profile. Thus `max_wrk.lua` is
for diagnostic runs only. Use it in place of `profile_wrk.lua` in the
timing endpoint procedure below, or with the standard bench server:

```sh
export ISSUE103_BASE_REPORT="$PWD/bench/wrk_report.lua"
wrk -t2 -c16 -d30s --timeout 10s --latency \
  -s bench/issue103/max_wrk.lua http://127.0.0.1:8090/insert_100
```

Set the same `BENCH_*` variables as the standard reporter needs. To test
the wrapper without wrk, run this from the repository root:

```sh
ISSUE103_BASE_REPORT=bench/wrk_report.lua BENCH_LABEL=t \
  BENCH_DRIVER_SHA=s BENCH_MONGO_VERSION=4.4.30 BENCH_API=insert_100 \
  BENCH_RUN=1 lua bench/issue103/max_wrk_test.lua bench/issue103/max_wrk.lua
```

## Cluster run: source of the stalls

On 2026-11-04, `k8s/storage-ab.sh` ran `insert_100` on the same OCI
cluster as the original report. Mongo ran on one 2-CPU arm64 node and the
bench pod on another. The CPU and memory limits match the approved
profile. The CPU requests were lower (Mongo 600m, nginx 300m, wrk 100m),
because no node had the approved requests free. Each sample has a fresh
seed, a 10 s warm-up and a 30 s measurement at `-t2 -c16`. All 30 samples
have zero HTTP and socket errors and zero throttled CPU periods.

The run has three parts:

1. Unpaced, with the Mongo data directory on the node disk (5 pairs).
2. Unpaced, with the data directory in memory (5 pairs).
3. Paced to 500 requests/s per wrk thread, on disk (5 pairs).

The disk pairs ran before and after the memory pairs. A change in node
load over time therefore cannot appear as a storage effect.

| Part | Old req/s | New req/s | Old p99, ms | New p99, ms | Old max, ms | New max, ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Disk, unpaced | 1052 | 1161 | 68.9 | 76.0 | 172 | 218 |
| Memory, unpaced | 1040 | 1139 | 72.7 | 82.7 | 180 | 196 |
| Disk, paced | 891 | 894 | 58.2 | 63.2 | 148 | 162 |

Each value is a median over five samples. The unpaced rates and p99 values
match the original report (about 1,050 requests/s and 71 to 108 ms).

A paired sign-flip test compares the new/old ratio of each pair:

| Samples | Metric | Geometric mean ratio | p | New higher |
| --- | --- | ---: | ---: | ---: |
| Unpaced (10 pairs) | p50 | 0.910 | 0.002 | 0/10 |
| Unpaced (10 pairs) | p99 | 1.083 | 0.347 | 8/10 |
| Unpaced (10 pairs) | max | 1.152 | 0.043 | 7/10 |
| Paced (5 pairs) | p50 | 0.730 | 0.060 | 0/5 |
| Paced (5 pairs) | p99 | 1.051 | 0.750 | 3/5 |

Single pairs range from 0.62 to 1.67 unpaced and from 0.68 to 1.44
paced. Three of 15 pairs exceed the 1.20 gate, but the drivers do not
differ significantly at p99. Thus three samples per side cannot decide
the gate for this API.

### Where the time goes

Mongo logs every insert slower than 100 ms. These slow inserts arrive in
groups of 16 that start within 50 ms of each other. So all 16 connections
stall at the same moment. The slow-log entries show no lock wait, no
flow-control wait and no storage read wait.

Four results exclude the first suspects:

- Storage: with the data directory in memory, the stalls stay. On disk,
  only 4 of 40 stall seconds have a disk write burst. In the other
  seconds, disk writes wait about 1 to 2 ms each.
- Checkpoints: no checkpoint ran during any measured sample.
- Memory reclaim: the Mongo cgroup uses 1.9 of 4 GiB, with zero reclaim
  scans and zero limit events.
- CPU starvation: in 100 ms windows, Mongo uses 1.17 to 1.26 CPUs during
  stalls and 0.99 to 1.20 CPUs at other times. Hypervisor steal is not
  higher during stalls (about 6%, against 8 to 10%).

`k8s/wt_sampler.js` reads WiredTiger counters about every 200 ms.
`k8s/stall_wt.py` ranks each counter by the share of its increase that
falls in windows with a stall. In the paced part, 14 stalls cover 0.5% of
the windows, and the stall windows hold these shares:

| WiredTiger counter | Share in stall windows |
| --- | ---: |
| `thread-yield: page acquire locked blocked` | 8.4% |
| `thread-yield: page acquire time sleeping (usecs)` | 8.1% |
| `cache: leaf pages split during eviction` | 4.6% |

The unpaced disk samples give the same order, with 9.4% for the first
counter at a 0.9% time share. During a stall, the writer threads sleep
while they wait for a page that another thread locked for eviction. In
the same windows, `forced eviction - pages selected unable to be evicted`
counts 10,791 of 11,287 forced evictions. Mongo keeps using CPU during
the stall, so the time goes to eviction work, not to waiting for a CPU.

### What this means for issue 103

The tail comes from MongoDB 4.4 WiredTiger eviction stalls on this
2-CPU node. The wrk correction then enlarges each stall, as the model in
[Sensitivity of the cluster p99 to one pause](#sensitivity-of-the-cluster-p99-to-one-pause)
shows. The driver code does not add delay. The new driver is faster at p50
in every pair.

In 15 samples, the new driver had 33 of these 16-wide stalls and the old
driver had 19. Per sample, that is 3 against 1.5 unpaced and 2 against 1
paced. This difference is at the edge of significance (two-sided p of
about 0.05). The next test shows that the write path does not cause it.

### Write path test

On 2026-11-05, one driver build (`6cf0584`) sent the same insert through
two server write paths. `write_path.lua` provides both endpoints. Both use
the new driver's connection, login and BSON encoder:

- msg: the driver's OP_MSG `insert` command, as in the new driver.
- legacy: OP_INSERT followed by `getlasterror` over OP_QUERY on
  `bench.$cmd`. These are the same messages that the old driver sends.

Mongo's log confirms the two paths. The legacy inserts arrive with type
`insert` and no protocol field, and each `getlasterror` arrives over
`op_query`. The run used 10 pairs, paced to 500 requests/s per wrk
thread, with msg first in each pair. The Mongo CPU request was 400m,
because the node had less free CPU than on 2026-11-04. All 20 samples
have zero HTTP and socket errors.

| legacy/msg | Geometric mean ratio | p | Legacy higher |
| --- | ---: | ---: | ---: |
| p50 | 1.140 | 0.005 | 9/10 |
| p99 | 1.111 | 0.167 | 8/10 |
| max | 0.914 | 0.406 | 6/10 |
| Requests/s | 0.982 | 0.007 | 2/10 |

| Path | Samples | Stalls | Median per sample | Mean stall, ms |
| --- | ---: | ---: | ---: | ---: |
| legacy | 10 | 22 | 2.5 | 140 |
| msg | 10 | 18 | 1.0 | 144 |

The OP_MSG path does not cause more stalls, and its p99 is not higher.
Its p50 is lower, because the legacy path needs a second round trip for
`getlasterror`. `k8s/stall_count.py` gives these stall counts, and it
gives the earlier counts again from the same rules.

All three cluster runs ran the same side first in every pair. The side
that ran second had more stalls each time: 25 against 15, 8 against 4
and 22 against 18, or 55 against 37 in total (two-sided p of about
0.06). In the first two runs, the second side was the new driver. So
the order can explain the earlier gap, and the counts also vary widely
between samples (0 to 6). The approved A/B runner also runs the old
driver first in every pair.

### Conclusions for the gate

Issue 103 does not show a driver regression. The p99 failures come from
WiredTiger eviction stalls that the wrk correction enlarges, and from
too few samples. To make the gate reliable for this API:

1. Compare more pairs per API, on a node with free CPU.
2. Change the order of old and new between pairs, for example ABBA.
3. Report the raw p99 and `max_ms` next to the adjusted p99.

Do not change the driver insert path on the basis of this data.

The runner, samplers and analysis scripts are in `k8s/`:

```sh
KUBE_CONTEXT='<context>' MONGO_NODE='<node>' BENCH_NODE='<node>' \
  bench/issue103/k8s/storage-ab.sh
PLAN=disk:5 RATE_PER_THREAD=500 KUBE_CONTEXT='<context>' \
  MONGO_NODE='<node>' BENCH_NODE='<node>' bench/issue103/k8s/storage-ab.sh
python3 -I bench/issue103/k8s/analyze.py <result-dir>
python3 -I bench/issue103/k8s/stall_cpu.py <mongo-log> <hostcpu-file> <result-dir>
python3 -I bench/issue103/k8s/stall_wt.py <mongo-log> <wt-file>
```

The runner refuses an existing `mongol-bench-103` namespace and deletes
only the namespace that it created. It writes the raw results to the
ignored `bench/results/` directory, because they name the cluster nodes.

## Data and checks

- `uncapped.jsonl`: six standard-handler observations, including before/after
  Mongo status and container CPU counters. These intervals include warm-up.
- `profile.jsonl`: four timing observations with the same diagnostics;
  measurement snapshots exclude warm-up.
- `raw.jsonl`: six same-request raw/adjusted comparisons and diagnostics.
- `raw-wrk.log`: the diagnostic client's measured output, with trailing spaces removed.
- `continued-manifest.json`: driver, image and probe identities.
- `co_model.lua`: the arithmetic model of the wrk correction for one pause.
- `max_wrk.lua` and `max_wrk_test.lua`: the diagnostic reporter that adds
  `max_ms`, and its test.
- `cluster-unpaced.jsonl`: the 20 unpaced cluster samples of 2026-11-04.
  Labels name the block, medium, pair and driver.
- `cluster-paced.jsonl`: the 10 paced cluster samples of 2026-11-04.
- `cluster-writepath.jsonl`: the 20 write-path samples of 2026-11-05.
- `write_path.lua` and `write_path.conf.in`: the msg and legacy endpoints.
- `k8s/`: the cluster runner, its manifests, the samplers and the
  analysis scripts.

Extended-JSON integers from the Mongo shell are converted to JSON integers
without changing their values. Each Mongo write-count delta was checked
against collection growth: 100 new documents per write operation. All 16
new observations have zero HTTP/socket errors and zero changes in the
recorded throttled-period counters. Both Lua probe files compile with the
image's LuaJIT; both drivers successfully ran the endpoint, and the reset
endpoint excluded the warm-up from the timing histograms.

## Running the timing endpoint

Use a dedicated authenticated MongoDB 4.4.30 fixture instance, OpenResty,
wrk 4.1.0 and `envsubst` on Linux. Run from this repository root. Use the
new driver for seeding, even when `MONGOL_LIB` selects the old driver.

```sh
export MONGO_HOST='<numeric-fixture-IP>'
export MONGOL_LIB='/path/to/selected-driver/lib'
export BENCH_DIR="$PWD/bench"
export WORK="$(mktemp -d)"
mkdir -p "$WORK/conf" "$WORK/logs"
SEED_LIB="$PWD/lib" bench/ctl.sh seed
envsubst '$MONGOL_LIB $BENCH_DIR' < bench/issue103/profile.conf.in \
  > "$WORK/conf/nginx.conf"
nginx -p "$WORK/" -c conf/nginx.conf
export ISSUE103_BASE_REPORT="$PWD/bench/wrk_report.lua"
export BENCH_LABEL=probe BENCH_API=insert_100 BENCH_RUN=1
export BENCH_DRIVER_SHA="$(git -C "$MONGOL_LIB" rev-parse HEAD)"
export BENCH_MONGO_VERSION=4.4.30
# For the paced variant, export ISSUE103_RATE_PER_THREAD=500 before warm-up.
wrk -t2 -c16 -d10s --timeout 10s -s bench/issue103/profile_wrk.lua \
  http://127.0.0.1:8090/insert_100
curl -fsS 'http://127.0.0.1:8090/profile_stats?reset=1'
wrk -t2 -c16 -d30s --timeout 10s --latency \
  -s bench/issue103/profile_wrk.lua http://127.0.0.1:8090/insert_100
curl -fsS http://127.0.0.1:8090/profile_stats
nginx -p "$WORK/" -c conf/nginx.conf -s quit
```

Stop nginx, select the other driver, reseed and start a fresh worker before
the next pass. This is a diagnostic workload, not the published full-report
profile. To repeat the raw/adjusted check, apply `wrk-raw-p99.patch` to the
pinned upstream wrk source using `git apply --unidiff-zero`, rebuild it,
and run it with the standard
`bench/wrk_report.lua` and standard bench server. Retain both prefixed
diagnostic lines and the ordinary JSON reporter line.

## Experiments needed to identify the original cluster cause

These remain hypotheses, not findings about the original cluster:

1. **Mongo cache/storage stalls.** On MongoDB 4.4.30, interleave at least ten
   old/new pairs with a fresh seed and identical warm-up for every sample.
   Capture server-side insert latency, WiredTiger eviction/checkpoint/log
   counters, and collection/index size. A server stall should appear in
   Mongo timing as well as HTTP timing. Separately test consecutive samples
   without reseeding to measure collection growth; do not mix this variant
   into the reseeded comparison.
2. **Shared-node scheduling.** Repeat the same sequence with isolated CPU
   placement, retaining the same load. Collect CPU pressure/scheduling delay
   alongside per-container quota counters. A scheduling explanation predicts
   that isolation reduces the tail without a driver change.
3. **Driver allocation/GC.** If Mongo latency stays low while HTTP p99 spikes,
   time document construction, BSON/wire encoding and socket waits separately
   for both drivers. Sample GC activity and profile the encoding section.
   A driver explanation predicts that the additional delay occurs before
   sending or after receiving, and persists with isolated resources.

Do not relax the p99 gate, change write concern, or optimize the insert path
until those measurements distinguish the hypotheses.
