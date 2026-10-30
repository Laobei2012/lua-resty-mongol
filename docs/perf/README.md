# Performance reports

- [2026-10-29: first performance report](perf-2026-10-29.md) — three complete
  invocations, all A/B/trend/BSON/CPU tables and five linked triage issues.
  Four APIs fail the A/B gates consistently; `count` is unstable. Results use
  the fixed constrained CPU profile and do not establish a driver cause.
- [Public measurement data and manifest](perf-2026-10-29-data/) — reconstructed
  allowlisted metrics, with comparator reproduction instructions in the report.

See the [harness](../../bench/README.md),
[Kubernetes instructions](../../bench/k8s/README.md), and
[implementation plan](../superpowers/plans/2026-10-27-performance-test.md).
Reports are named `perf-<start-date>.md`; private operational data is excluded.
`dist.ini` excludes this directory from the OPM package.
