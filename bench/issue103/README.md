# Issue #103 investigation

Issue: <https://github.com/Laobei2012/lua-resty-mongol/issues/103>

The published p99 failures reproduce. The available cluster measurements
do not establish a driver regression or identify the source of the delay.
No driver change is justified by those measurements alone.

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

## Experiments needed to identify the cause

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
