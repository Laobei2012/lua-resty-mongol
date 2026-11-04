"""Rank WiredTiger counters by how much they rise during insert stalls.

Usage: python3 -I stall_wt.py <mongo-log> <wt_sampler-output>

A stall is a group of at least 8 slow inserts that started within 50 ms.
For each counter, "share" is the part of its total increase that falls in
100 ms windows overlapping a stall. "Time" is the part of all windows that
overlap a stall. A share far above the time share marks a suspect.
"""

import datetime
import itertools
import json
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
        starts.append((end - attr["durationMillis"] / 1000, end))
    starts.sort()
    groups, current = [], []
    for item in starts:
        if current and item[0] - current[0][0] > 0.05:
            groups.append(current)
            current = []
        current.append(item)
    if current:
        groups.append(current)
    return [(g[0][0], max(e for _, e in g)) for g in groups if len(g) >= 8]


def main():
    spans = stalls(sys.argv[1])
    rows = [
        json.loads(x)
        for x in Path(sys.argv[2]).read_text().splitlines()
        if x.startswith("{")
    ]
    lo, hi = rows[0]["t_ms"] / 1000, rows[-1]["t_ms"] / 1000
    spans = [s for s in spans if lo <= s[0] <= hi]
    hit_windows, total_windows = 0, 0
    totals, inside = {}, {}
    for a, b in itertools.pairwise(rows):
        t0, t1 = a["t_ms"] / 1000, b["t_ms"] / 1000
        hit = any(t1 > s and t0 < e for s, e in spans)
        total_windows += 1
        hit_windows += hit
        for key, value in b.items():
            if key == "t_ms" or not isinstance(value, (int, float)):
                continue
            delta = value - a.get(key, value)
            if delta <= 0:
                continue
            totals[key] = totals.get(key, 0) + delta
            if hit:
                inside[key] = inside.get(key, 0) + delta
    time_share = hit_windows / max(total_windows, 1)
    print(f"stalls={len(spans)} windows={total_windows} time_share={time_share:.3f}")
    ranked = sorted(totals, key=lambda k: inside.get(k, 0) / totals[k], reverse=True)
    print("| Counter | Total increase | Share in stall windows |")
    print("| --- | ---: | ---: |")
    for key in ranked[:25]:
        print(f"| {key} | {totals[key]} | {inside.get(key, 0) / totals[key]:.3f} |")


main()
