"""Match Mongo slow-insert stalls with 100 ms host CPU samples.

Usage: python3 -I stall_cpu.py <mongo-log> <hostcpu-file> <result-dir>

The host CPU file has one "<epoch_ns> cpu <jiffies...>" line and one
"mongo usage_usec <n>" line per sample, from /proc/stat and the Mongo cgroup.
A stall is a group of at least 8 slow inserts that started within 50 ms.
"""

import datetime
import itertools
import json
import statistics
import sys
from pathlib import Path


def stalls(path):
    starts = []
    for line in Path(path).read_text().splitlines():
        if '"Slow query"' not in line:
            continue
        row = json.loads(line)
        attr = row["attr"]
        if attr.get("ninserted") is None:
            continue
        end = datetime.datetime.fromisoformat(row["t"]["$date"]).timestamp()
        starts.append((end - attr["durationMillis"] / 1000, attr["durationMillis"]))
    starts.sort()
    groups, current = [], []
    for start, duration in starts:
        if current and start - current[0][0] > 0.05:
            groups.append(current)
            current = []
        current.append((start, duration))
    if current:
        groups.append(current)
    return [g for g in groups if len(g) >= 8]


def samples(path):
    rows, stamp, cpu = [], None, None
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) > 2 and parts[1] == "cpu":
            stamp = int(parts[0]) / 1e9
            cpu = [int(v) for v in parts[2:]]
        elif parts[:2] == ["mongo", "usage_usec"] and stamp is not None:
            rows.append((stamp, cpu, int(parts[2])))
    out = []
    for (t0, c0, m0), (t1, c1, m1) in itertools.pairwise(rows):
        dt = t1 - t0
        d = [b - a for a, b in zip(c0, c1, strict=True)]
        total = sum(d[:8]) or 1
        out.append(
            {
                "t0": t0,
                "t1": t1,
                "idle": (d[3] + d[4]) / total,
                "steal": d[7] / total,
                "mongo_cpus": (m1 - m0) / 1e6 / dt,
                "busy_cpus": 2 * (1 - (d[3] + d[4]) / total),
            }
        )
    return out


def main():
    groups = stalls(sys.argv[1])
    # Keep only CPU windows inside a 30 s measurement (the sampler series).
    spans = []
    for series in Path(sys.argv[3]).glob("*-series.jsonl"):
        stamps = [
            json.loads(x)["t_ms"] / 1000
            for x in series.read_text().splitlines()
            if x.startswith("{")
        ]
        if stamps:
            spans.append((stamps[0], stamps[-1]))
    windows = [
        w
        for w in samples(sys.argv[2])
        if any(a <= w["t0"] and w["t1"] <= b for a, b in spans)
    ]
    if not windows:
        sys.exit("no host CPU samples")
    lo, hi = windows[0]["t0"], windows[-1]["t1"]
    inside, outside = [], []
    print("| Stall start (UTC) | Inserts | Max ms | Host idle | Steal | Mongo CPUs |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    for group in groups:
        start = group[0][0]
        longest = max(d for _, d in group)
        if not lo <= start <= hi:
            continue
        span = [
            w for w in windows if w["t1"] > start and w["t0"] < start + longest / 1000
        ]
        if not span:
            continue
        idle = statistics.mean(w["idle"] for w in span)
        steal = statistics.mean(w["steal"] for w in span)
        mongo = statistics.mean(w["mongo_cpus"] for w in span)
        inside.append((idle, steal, mongo))
        when = datetime.datetime.fromtimestamp(start, datetime.UTC).strftime(
            "%H:%M:%S.%f"
        )[:-3]
        print(
            f"| {when} | {len(group)} | {longest} | {idle:.2f} | {steal:.2f} | {mongo:.2f} |"
        )
    stall_times = [(g[0][0], g[0][0] + max(d for _, d in g) / 1000) for g in groups]
    for w in windows:
        if not any(w["t1"] > a and w["t0"] < b for a, b in stall_times):
            outside.append((w["idle"], w["steal"], w["mongo_cpus"]))
    for name, rows in (("stall windows", inside), ("other windows", outside)):
        if rows:
            print(
                f"\n{name}: n={len(rows)} idle={statistics.mean(r[0] for r in rows):.2f} "
                f"steal={statistics.mean(r[1] for r in rows):.3f} "
                f"mongo_cpus={statistics.mean(r[2] for r in rows):.2f}"
            )


main()
