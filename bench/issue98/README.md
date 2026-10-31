# Issue 98: remaining low-level helpers

Baseline: `d38bc7e034fa6643d58fad4f94a8f5775e94b0e0`, fetched from
`origin/master` before measuring. This includes decoder specialization
`68eaefdd4beeff64c34cceb48e01a3849ab864ed` (#97) and writer specialization
`5696ad09b6912ddf01134c69d21bd5e74cba1e4b` (#99).

Harness and compatibility-test commit: `3319e14`.
`bench/bson_micro.lua` is unchanged from #99. Original candidate (`018b55a`) source blob:
`c90313436023b9659a886c05b02530f80f4b246b`; SHA-256 of the library patch
against master: `bb7d2a97a33cec4033c4314e187898f8f289183b95c06bfa4a202ea7bf990699`.
That candidate adds 22 lines to `ll.lua`; all other library files are unchanged.

Timing environment: native macOS/Darwin 25.5.0, arm64, OpenResty 1.31.8.1,
resty CLI 0.29, LuaJIT 2.1.ROLLING. These are local, uncapped measurements.
Test environment: Docker Linux/aarch64, OpenResty 1.31.1.1,
Test::Nginx 0.32, MongoDB 8.0.34 where a server is needed.

## Review follow-up: non-string inputs

Regression-test commit: `7c5549f`. The reader fast path now also requires
`type(s) == "string"`, so numeric inputs retain string.byte coercion and nil,
boolean and cdata inputs retain their original error messages. The new test
passes on `d38bc7e`, fails on `018b55a`, and passes with the guard. It checks
`be_uint_to_num(12345678, 1, 4) == 825373492` and exact error text, excluding
checkout-dependent source paths and line numbers.

Final library blob: `3b61fcf4f0e0d64b7d99704962dd586eb4085dcd`;
SHA-256 of the final library patch against `d38bc7e`:
`7354aa37eeae3468683cf1d5951f6f8aba8d60799423b93c4dee01c1290977f1`.
The original helper/control files below remain historical measurements of
`018b55a`. For the final guard, three new interleaved baseline/candidate pairs
are recorded in [objectid-nonstring-results.md](objectid-nonstring-results.md),
with all CPU/wall samples and medians. Reproduce using
`git worktree add /tmp/mongol-i98-baseline d38bc7e`, then
`ruby bench/issue98/measure_objectid.rb`. The existing batched Lua harness and
runtime are unchanged. Each case runs in a fresh process; all 12 measurements
completed successfully before starting MongoDB or running other suites.

## Method and scope

The baseline checkout was created with
`git worktree add /tmp/mongol-i98-master origin/master`.
Run `ruby bench/issue98/measure.rb` from this repository root to reproduce.
It waits for each process and rejects nonzero exit codes. The exact sequential
order is master 1, candidate 1, master 2, candidate 2, master 3, candidate 3.
Each side runs helpers, callers, then the existing BSON benchmark. All
measurement processes succeeded; `measure.log` records their start times.

Each helper/caller case runs in a separate resty process. Inputs vary across
100 values, and outputs are retained in a table. This avoids constant-folded
reads and cross-case JIT state. Each case uses the timing loop from
`bench/bson_micro.lua`: collect garbage, warm up at most 1,000 operations
(check every 50; stop after one second), then batches of 100 operations until
at least two wall seconds have elapsed. The clock is checked once per batch.
`os.clock()` measures process CPU seconds separately from `ngx.now()` wall
seconds. JSON rows retain counts, both elapsed times, CPU ns/op, and wall ops/s.
The unchanged BSON script reports wall throughput only; it cannot support a
CPU-time claim. CPU timings for BSON encoding are available in the caller cases.

The wire cases exercise real `wire.encode_msg` for ping and an insert with a
document sequence. They exclude sockets and MongoDB response latency. ObjectID
generation exercises the real constructor after process-random initialization;
access measures all three numeric getters across 100 IDs. Typed BSON cases
exercise a double and an exact int64. These are CPU caller measurements, not
live request-throughput or end-to-end latency results.

Before selecting a change, `resty -I /tmp/mongol-i98-master/lib
bench/ll_micro.lua profile` sampled the current callers with LuaJIT's
`jit.profile` (`li1`). Raw stacks are in `profile-master.jsonl`. Profiled
throughput is excluded from the timing comparisons. Sampling attribution in
JIT code is approximate; inclusive helper-frame counts locate costs rather
than establish precise percentages of CPU time.

Initial exploratory timings were superseded when an extra compatibility probe
found that a cdata width could enter the candidate's fast path. The baseline
throws for these widths. The added regression check failed on that exploratory
implementation (9/12 TAP checks passed), then passed after adding a numeric-width
guard. The original timing files were regenerated after that numeric-width
fix. The review follow-up above repeats ObjectID timings after the additional
string-input guard. No exploratory timing is used in the conclusions.

## Compatibility and validation

`t/ll_be.t` tests unsigned byte order and boundaries at widths 1–6, width 8,
default/zero/negative widths, invalid ranges, fractions, infinities, NaN,
unsupported argument types, string widths and cdata-width errors. It compares
6,000 deterministic encodings against reversed little-endian bytes. Readers
are compared with the original loop across negative, zero, fractional,
embedded, truncated and out-of-bounds offsets. The ObjectID seam checks exact
timestamp/process/counter bytes, counter wraparound, invalid lengths, and BSON
round trips. Exact signed int64 extrema and values around 2^53 retain their
Lua-number/cdata representations; signed int32 boundaries and doubles are
also checked.

Each command below ran separately and completed successfully. Tests used the
image built from `Dockerfile`, with `--rm --init` and the repository mounted
at `/work`. Mongo-dependent suites shared the network namespace of the local
`mongol-i98-mongo` container. See the corresponding log files for full results.

| Command inside test container | Passed |
| --- | --- |
| `prove -I t/lib t/ll_be.t` on baseline | 15/15 |
| `prove -I t/lib t/ll_be.t` on final candidate | 15/15 |
| `luacheck -q lib` | clean, exit 0 |
| `prove -I t/lib t/bson.t` | 78/78 |
| `prove -I t/lib t/ll.t` | 21/21 |
| `prove -I t/lib t/objid.t` | 15/15 |
| `prove -I t/lib t/wire.t` | 42/42 |
| `prove -I t/lib t/bson_corpus.t` on `018b55a` | 3/3 TAP checks, full corpus loop; not rerun for this guard |

Review follow-up total: 171 TAP checks across the five requested suites.
Logs for this follow-up use the `nonstring-` prefix. Before the fix, the extended
suite passed 12/15 checks on `018b55a`, failing the new regression block.
The earlier `make spec-data` fetched the repository's pinned BSON corpus.
No Kubernetes cluster, quota, validity rule, historical `docs/perf/` data, or
`bench/k8s/` file was touched. Local MongoDB containers were removed after use.
No `mongol-i98-` containers remain.

Not run: full MongoDB 6–9 CI, authentication, TLS and replica-set configurations.
These remain required acceptance checks; this report does not claim they passed.
The original CPU-quota comparison and CPU-throttling diagnostics remain for the
owner's live run, as explicitly instructed. There is no live `/ping` claim.

## Samples and profile

See [results.md](results.md) for the original individual CPU/wall samples, medians,
relative wall changes, and the baseline profile table. Rebuild that table with
`ruby bench/issue98/summarize.rb > bench/issue98/results.md`. The JSONL files
are the raw measurement evidence.

## Disposition of every issue candidate

CPU values below are original median ns/op, master → `018b55a`. Width lists are 2/3/4
bytes respectively. Only the two big-endian helpers were edited.

| Candidate | CPU measurements | Disposition and caller evidence |
| --- | --- | --- |
| `num_to_le_uint` | 9.06 → 9.21 | #99 already implements the proposed checked four-byte writer. It is **still hot**: 175/558 profile samples in wire ping, 260/764 in small encoding, 347/858 in large encoding contain this helper. No additional improvement demonstrated; defer further work. |
| `num_to_le_int` | 9.59 → 9.53 | Already inherits #99; signed-writer frames appear in 61/764 small-encode samples. No incremental proposal demonstrated; defer. |
| `le_int_to_num` | 1.69 → 1.69 | Already inherits #97; only 19/643 small-decode samples contain this wrapper. No additional benefit demonstrated; defer. |
| `num_to_be_uint` | 57.42/124.34/125.63 → 7.99/9.53/9.41 | Keep direct checked 2/3/4-byte writes. Writer frames occur in 270/688 ObjectID-generation profile samples. Generation improves in every pair, including real timestamp and counter writes. |
| `be_uint_to_num` | 22.36/47.47/5071.08 → 1.08/1.32/2.46 | Keep direct complete 2/3/4-byte reads; retain generic fallback and offset coercion/error behavior. Reader frames occur in 943/952 ObjectID-access profile samples. Access improves in every pair. |
| `to_double` | 5.31 → 5.16 | Existing FFI path retained; no alternative with demonstrated incremental caller benefit. |
| `from_double` | 4.76 → 4.95 | Existing FFI path and substring behavior retained; no alternative with demonstrated incremental caller benefit. |
| `int64_to_le` | 4.88 → 4.95 | Existing exact FFI writer retained; no alternative with demonstrated incremental caller benefit. |
| `le_to_int64` | 17.59 → 16.85 | Existing exact FFI reader and return types retained; no alternative with demonstrated incremental caller benefit. |
| `is_int64` | 2.00 → 2.00 | Existing type check retained; no demonstrated need for a rewrite. |
| `extract_bits` | 22.55 → 1.28 | No direct edit or driver callers outside ll.lua. It incidentally inherits the two-byte BE-reader improvement; this micro-only benefit is not used to justify the patch. |
| `le_bpeek` | 7.01 → 6.57 | No driver callers outside ll.lua; no direct edit, retain public export. |
| `be_bpeek` | 6.91 → 6.93 | No driver callers outside ll.lua; no direct edit, retain public export. |

All FFI frames together appear in 48/570 typed-encode and 66/646 typed-decode
profile samples. Typed caller CPU medians are 146.68 → 146.14 ns for encoding
and 95.81 → 96.26 ns for decoding. This is no evidence for changing any FFI
implementation, removing substring copies, or weakening input handling.

With the final string-input guard, ObjectID generation wall samples are
**1.90155, 2.08785, 2.13245 M ops/s** on master and
**4.99500, 5.26120, 5.29790 M ops/s** on the candidate.
Medians are **2.08785 → 5.26120 M ops/s (2.52x)**. CPU samples are
525.44, 476.43, 468.40 → 197.42, 189.55, 188.50 ns/op;
medians **476.43 → 189.55 ns/op**.

ObjectID access wall samples are **0.20540, 0.21120, 0.20680 M ops/s** and
**232.04065, 230.63190, 225.35310 M ops/s**, respectively. Medians are
**0.20680 → 230.63190 M ops/s**. CPU samples are
4841.76, 4728.19, 4828.53 → 4.30, 4.33, 4.41 ns/op;
medians **4828.53 → 4.33 ns/op**. The very large read ratio is specific to
this warm arm64 LuaJIT workload and its slow generic four-byte read; it must
not be extrapolated to live requests, x86, or other runtimes.

No regression was measured in either relevant ObjectID caller. The original
three-pair control samples remain in `results.md`. The reviewer subsequently
ran five interleaved pairs: `wire_insert` was −0.2% and `encode_small` −6.6%,
with fully overlapping ranges and about 20–35% run-to-run spread. Neither path
calls the edited helpers. The reviewer concluded that these differences are
within noise. These five-pair results are reviewer-provided; their raw samples
are not part of this checkout. They do not justify further LE changes.

## Draft issue comment (not posted)

Reprofiled current master `d38bc7e` after both #97 and #99. #99 already covers
the first proposed four-byte writer optimization; `num_to_le_uint` remains
visible in the fresh profile (175/558 wire-ping samples), but no further LE
change earned inclusion.

The retained patch specializes complete two-, three-, and four-byte BE reads
and checked BE writes. Three interleaved local arm64/OpenResty 1.31.8.1 pairs
after the final string-input compatibility guard improved ObjectID generation
from median 2.08785 to 5.26120 M ops/s, with CPU cost 476.43 to 189.55 ns/op.
All three ObjectID-access pairs also improved (CPU median 4828.53 to 4.33 ns/op).
The guard preserves numeric coercion and baseline errors for non-string inputs.
The unusually large access gain is specific
to this warm runtime/workload; it is not a live-throughput claim. Other helpers
remain unchanged, with measured deferrals. The reviewer measured five
interleaved control pairs: `wire_insert` −0.2% and `encode_small` −6.6%, with
fully overlapping ranges and about 20–35% run-to-run spread. Neither path calls
the changed helpers; these differences are within noise.

The committed `bench/issue98/` report includes raw samples, medians, fresh
sampling stacks, source/harness provenance and every candidate's disposition.
Compatibility tests cover bounds, byte order, validation/errors, widths and
offsets, ObjectID counter wraparound, and exact int64 representations. Lint
and 171 requested local checks passed with the final guard, including MongoDB
8.0.34 caller tests. The BSON corpus passed on the original optimization.
Full MongoDB 6–9/auth/TLS/replica-set CI and the owner's live CPU-quota
comparison remain outstanding. No cluster or historical performance data was
changed.
