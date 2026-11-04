"""Summarize one storage-ab.sh result directory as a Markdown table.

Usage: python3 -I bench/issue103/k8s/analyze.py <result-dir>
"""

import itertools
import json
import re
import sys
from pathlib import Path


def num(value):
    if isinstance(value, dict):
        return int(value.get("$numberLong", 0))
    return value or 0


def wrk_row(path):
    lines = [line for line in path.read_text().splitlines() if line.startswith("{")]
    return json.loads(lines[-1])


def slow_writes(before, after, floor_us):
    def counts(snapshot):
        return {
            num(b["micros"]): num(b["count"]) for b in snapshot["writes"]["histogram"]
        }

    old, new = counts(before), counts(after)
    return sum(new[k] - old.get(k, 0) for k in new if k >= floor_us)


def disk(series):
    """Return the busiest device's write MB/s (mean, max) and write await ms."""
    rows = []
    for item in series:
        fields = {}
        for line in item["disks"] or []:
            parts = line.split()
            fields[parts[2]] = (int(parts[7]), int(parts[9]), int(parts[10]))
        rows.append((item["t_ms"], fields))
    if len(rows) < 2:
        return None
    first, last = rows[0][1], rows[-1][1]
    name = max(first, key=lambda d: last.get(d, first[d])[1] - first[d][1])
    rates = []
    for (t0, a), (t1, b) in itertools.pairwise(rows):
        rates.append((b[name][1] - a[name][1]) * 512 / 1e6 / ((t1 - t0) / 1000))
    writes = last[name][0] - first[name][0]
    wait_ms = last[name][2] - first[name][2]
    return name, sum(rates) / len(rates), max(rates), wait_ms / max(writes, 1)


def psi_max(series, key):
    best = 0.0
    for item in series:
        text = item.get(key) or ""
        match = re.search(r"some avg10=([0-9.]+)", text)
        if match:
            best = max(best, float(match.group(1)))
    return best


def throttled(before_path, after_path):
    def parse(path):
        out, name = {}, None
        for line in path.read_text().splitlines():
            if line.startswith("== "):
                name = line[3:]
            elif name and " " in line:
                key, value = line.split()
                out[(name, key)] = int(value)
        return out

    a, b = parse(before_path), parse(after_path)
    parts = []
    for name in ("mongo", "nginx", "wrk"):
        periods = b.get((name, "nr_periods"), 0) - a.get((name, "nr_periods"), 0)
        hits = b.get((name, "nr_throttled"), 0) - a.get((name, "nr_throttled"), 0)
        parts.append(f"{100 * hits / periods:.1f}" if periods else "0.0")
    return "/".join(parts)


def main():
    out = Path(sys.argv[1])
    print(
        "| Sample | Requests/s | p99, ms | max_ms | Server writes >= 49 ms "
        "| Checkpoints | Checkpoint ms | Journal sync ms/op | Disk MB/s mean/max "
        "| Disk write wait, ms | Host IO PSI avg10 max | Throttled % mongo/nginx/wrk |"
    )
    print("| --- |" + " ---: |" * 11)
    for wrk in sorted(out.glob("*-wrk.log"), key=lambda p: p.stat().st_mtime):
        label = wrk.name[: -len("-wrk.log")]
        row = wrk_row(wrk)
        before = json.loads((out / f"{label}-before.json").read_text())
        after = json.loads((out / f"{label}-after.json").read_text())
        series = [
            json.loads(line)
            for line in (out / f"{label}-series.jsonl").read_text().splitlines()
            if line.startswith("{")
        ]
        log = [after["log"][k] - before["log"][k] for k in after["log"]]
        sync_ops = max(log[1], 1)
        sync_ms = log[2] / 1000 / sync_ops
        txn_b, txn_a = before["txn"], after["txn"]
        ckpts = txn_a["transaction checkpoints"] - txn_b["transaction checkpoints"]
        ckpt_ms = (
            txn_a["transaction checkpoint total time (msecs)"]
            - txn_b["transaction checkpoint total time (msecs)"]
        )
        d = disk(series)
        disk_text = f"{d[1]:.1f}/{d[2]:.1f}" if d else "n/a"
        wait_text = f"{d[3]:.2f}" if d else "n/a"
        print(
            f"| {label} | {row['rps']:.1f} | {row['p99_ms']:.3f} | {row['max_ms']:.3f} "
            f"| {slow_writes(before, after, 49152)} | {ckpts} | {ckpt_ms} "
            f"| {sync_ms:.2f} | {disk_text} | {wait_text} "
            f"| {psi_max(series, 'host_io_psi'):.2f} "
            f"| {throttled(out / f'{label}-cpu-before.txt', out / f'{label}-cpu-after.txt')} |"
        )


main()
