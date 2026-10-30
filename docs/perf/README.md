# Performance reports

1. [Read the 2026-10-29 findings](perf-2026-10-29.md#findings).
   Four APIs fail the A/B gates consistently. `count` is unstable.
2. [Check the CPU limits](perf-2026-10-29.md#cpu-interpretation).
   Quotas affect latency. Full run 1's MongoDB 9.0.4 results are invalid for cross-version comparison.
   Contention is suspected but unconfirmed.
3. [Recompute the tables](perf-2026-10-29.md#public-data-and-reproduction)
   from the [public measurement data and manifest](perf-2026-10-29-data/).

The report covers three full runs and links five triage issues.
The measurements do not establish a driver cause.

See the [harness](../../bench/README.md),
[Kubernetes instructions](../../bench/k8s/README.md), and
[implementation plan](../superpowers/plans/2026-10-27-performance-test.md).
Name reports `perf-<start-date>.md`. Reports exclude private operational data.
`dist.ini` excludes this directory from the OPM package.
