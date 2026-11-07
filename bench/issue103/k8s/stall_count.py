"""Count 16-wide insert stalls per sample in a storage-ab.sh result directory.

Usage: python3 -I stall_count.py <result-dir>

A stall is a group of at least 8 slow inserts (over Mongo's 100 ms slow-op
limit) that started within 50 ms. A stall belongs to a sample when it starts
inside that sample's 30 s sampler series. The last label part names the side.
"""

import collections
import datetime
import json
import statistics
import sys
from pathlib import Path


def groups(logs):
    starts = set()
    for log in logs:
        for line in log.read_text().splitlines():
            if '"Slow query"' not in line:
                continue
            row = json.loads(line)
            attr = row["attr"]
            if attr.get("ninserted") is None:
                continue
            end = datetime.datetime.fromisoformat(row["t"]["$date"]).timestamp()
            starts.add((end - attr["durationMillis"] / 1000, attr["durationMillis"]))
    found, current = [], []
    for item in sorted(starts):
        if current and item[0] - current[0][0] > 0.05:
            found.append(current)
            current = []
        current.append(item)
    if current:
        found.append(current)
    return [(g[0][0], max(d for _, d in g)) for g in found if len(g) >= 8]


def main():
    out = Path(sys.argv[1])
    stalls = groups(sorted(out.glob("mongo-block*.log")))
    sides = collections.defaultdict(list)
    for series in sorted(out.glob("*-series.jsonl")):
        label = series.name[: -len("-series.jsonl")]
        stamps = [
            json.loads(x)["t_ms"] / 1000
            for x in series.read_text().splitlines()
            if x.startswith("{")
        ]
        inside = [d for s, d in stalls if stamps[0] <= s <= stamps[-1]]
        sides[label.rsplit("-", 1)[1]].append((label, inside))
    print(
        "| Side | Samples | Stalls | Median per sample | Mean stall, ms | Per sample |"
    )
    print("| --- | ---: | ---: | ---: | ---: | --- |")
    for side, rows in sides.items():
        counts = [len(d) for _, d in rows]
        lengths = [x for _, d in rows for x in d]
        mean = f"{statistics.mean(lengths):.0f}" if lengths else "n/a"
        print(
            f"| {side} | {len(rows)} | {sum(counts)} | {statistics.median(counts)} "
            f"| {mean} | {', '.join(map(str, counts))} |"
        )


main()
