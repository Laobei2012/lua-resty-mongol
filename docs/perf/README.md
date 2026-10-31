# Performance reports

## 2026-10-31 (latest)

1. [Read the findings](perf-2026-10-31.md#findings).
   The new driver meets the rps gate on all comparable APIs. `insert_100` misses the p99 gate in two of three full runs.
2. [Check the changes since the first report](perf-2026-10-31.md#changes-since-the-2026-10-29-report).
   Driver changes and test setup changes both affect the ratios.
3. [Recompute the tables](perf-2026-10-31.md#public-data-and-reproduction)
   from the [public measurement data and manifest](perf-2026-10-31-data/).

## 2026-10-29

1. [Read the findings](perf-2026-10-29.md#findings).
   Four APIs fail the A/B gates consistently. `count` is unstable. PRs #97 and #99 later closed these issues.
2. [Check the CPU limits](perf-2026-10-29.md#cpu-interpretation).
   Quotas affect latency. Full run 1's MongoDB 9.0.4 results are invalid for cross-version comparison.
   Contention is suspected but unconfirmed.
3. [Recompute the tables](perf-2026-10-29.md#public-data-and-reproduction)
   from the [public measurement data and manifest](perf-2026-10-29-data/).

See the [harness](../../bench/README.md),
[Kubernetes instructions](../../bench/k8s/README.md), and
[implementation plan](../superpowers/plans/2026-10-27-performance-test.md).
Name reports `perf-<start-date>.md`. Reports exclude private operational data.
`dist.ini` excludes this directory from the OPM package.
