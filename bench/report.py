#!/usr/bin/env python3
"""Run three complete invocations, or export a validated three-run report."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BENCH = Path(__file__).resolve().parent
APIS = [
    "ping",
    "find_one",
    "find_100",
    "count",
    "insert_1",
    "insert_100",
    "update",
    "delete_insert",
    "find_and_modify",
    "gridfs_read",
    "auth",
    "connect_nopool",
]
HTTP_KEYS = [
    "label",
    "driver_sha",
    "mongo_version",
    "api",
    "run",
    "rps",
    "p50_ms",
    "p90_ms",
    "p99_ms",
    "non2xx",
    "socket_errors",
    "interval_requests",
]
CASES = {"encode_small", "decode_small", "encode_large", "decode_large", "decode_reply"}
PLACEMENT_KEYS = ("kube_context", "mongo_node", "bench_node")
PROFILE = {
    "threads": 2,
    "connections": 16,
    "connect_nopool_connections": 4,
    "timeout_s": 10,
    "warmup_s": 10,
    "sample_s": 30,
    "samples": 3,
    "bson_warmup": 1000,
    "bson_warmup_seconds": 1,
    "bson_warmup_batch": 50,
    "bson_measure_batch": 100,
    "bson_seconds": 2,
}
# Git blobs pin the approved workload and configured resource limits, not refs or identities.
BLOBS = dict(
    zip(
        [
            "bench/load.sh",
            "bench/bson_micro.lua",
            "bench/wrk_report.lua",
            "bench/k8s/bench.yaml",
            "bench/k8s/mongo.yaml",
        ],
        [
            "5f8f3530bad14d84530de74cae041a6328cee7fe",
            "bebf6354c6b13e4217048acbc14f3ac0cfd38b49",
            "6a75cd693cb6f83ae88fb3af2510ffa35ab58241",
            "3df10199e3f1c22904e13e3941c42ac7aad91ac7",
            "7c87be1096f958d8f92d8b10a12e578f78e6a6c4",
        ],
    )
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def number(value: object) -> bool:
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text())
    require(isinstance(value, dict), "expected JSON object")
    return value


def rows(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()]


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True) + "\n")


def sha(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{40}", value) is not None


def validate_manifest(directory: Path) -> tuple[dict, dict]:
    complete = directory / "COMPLETE"
    require(
        complete.is_file() and complete.read_text() == "all\n",
        f"incomplete all invocation: {directory}; inspect log: {directory}.log",
    )
    data = read_json(directory / "run-manifest.json")
    placement = data.get("placement")
    require(
        isinstance(placement, dict)
        and set(placement) == set(PLACEMENT_KEYS)
        and all(
            isinstance(value, str) and value.strip() for value in placement.values()
        ),
        "missing or invalid private placement",
    )
    require(
        data.get("profile") == PROFILE and data.get("source_blobs") == BLOBS,
        "workload or resource profile differs from approved full profile",
    )
    require(
        all(sha(data.get(key)) for key in ("old_sha", "new_sha", "controller_sha")),
        "invalid source SHA",
    )
    require(
        data["old_sha"] == "3eb6349db4d30b11aab271fb14a82b8504f6aa8e",
        "unexpected old driver",
    )
    versions = read_json(directory / "tool-versions.json")
    require(
        versions.get("openresty") == "1.31.1.1" and versions.get("wrk") == "4.1.0",
        "unexpected tool versions",
    )
    return {
        **{key: data[key] for key in ("old_sha", "new_sha", "controller_sha")},
        "profile": PROFILE,
        "source_blobs": BLOBS,
        "tools": {"openresty": "1.31.1.1", "wrk": "4.1.0"},
    }, placement


def validate_http(
    path: Path, *, label: str, side: str, version: str, manifest: dict, runs: list[int]
) -> list[dict]:
    data = rows(path)
    expected = {
        (api, run) for api in APIS if side != "old" or api != "find_100" for run in runs
    }
    seen = set()
    for row in data:
        require(
            isinstance(row, dict) and all(key in row for key in HTTP_KEYS),
            "invalid HTTP schema",
        )
        key = (row["api"], row["run"])
        require(
            key in expected and key not in seen and type(row["run"]) is int,
            "unexpected or duplicate API/run",
        )
        seen.add(key)
        require(
            row["label"] == label and row["driver_sha"] == manifest[side + "_sha"],
            "incorrect label or driver",
        )
        require(
            isinstance(row["mongo_version"], str)
            and re.fullmatch(re.escape(version) + r"\.\d+", row["mongo_version"]),
            "incorrect Mongo version",
        )
        require(all(number(row[k]) for k in HTTP_KEYS[4:]), "invalid HTTP metric")
        require(
            type(row["interval_requests"]) is int and row["interval_requests"] > 0,
            "invalid interval request count",
        )
        require(
            row["rps"] > 0
            and 0 <= row["p50_ms"] <= row["p90_ms"] <= row["p99_ms"]
            and row["p99_ms"] > 0,
            "invalid throughput or latency",
        )
        require(
            row["non2xx"] == row["socket_errors"] == 0, "invalid HTTP/socket errors"
        )
    require(seen == expected, "incomplete HTTP API/run coverage")
    for api in {row["api"] for row in data}:
        require(
            len({row["interval_requests"] for row in data if row["api"] == api}) == 1,
            "inconsistent interval request counts",
        )
    return [{key: row[key] for key in HTTP_KEYS} for row in data]


def cpu(directory: Path, *, label: str, api: str, container: str) -> dict:
    result = {"label": label, "api": api, "container": container, "available": False}
    snapshots = []
    for phase in ("before", "after"):
        path = directory / "cpu" / f"{label}-{api}-{phase}-{container}.stat"
        if not path.is_file():
            return result
        content = path.read_text()
        if "unavailable:" in content or "cgroup v2\n" not in content:
            return result
        values = dict(
            re.findall(
                r"^(sample_time_epoch|usage_usec|nr_periods|nr_throttled|throttled_usec) ([0-9]+)$",
                content,
                re.MULTILINE,
            )
        )
        if len(values) != 5:
            return result
        snapshots.append({key: int(value) for key, value in values.items()})
    delta = {key: snapshots[1][key] - snapshots[0][key] for key in snapshots[0]}
    if (
        any(value < 0 for value in delta.values())
        or delta["sample_time_epoch"] <= 0
        or delta["nr_throttled"] > delta["nr_periods"]
    ):
        return result
    return {**result, "available": True, **delta}


def validate(directory: Path) -> dict:
    manifest, placement = validate_manifest(directory)
    files, counters = {}, []
    for side in ("old", "new"):
        joined = []
        for run in (1, 2, 3):
            label = f"{side}-{run}"
            data = validate_http(
                directory / "work/results" / f"{label}.jsonl",
                label=label,
                side=side,
                version="4.4",
                manifest=manifest,
                runs=[run],
            )
            files[label] = data
            joined.extend(data)
        actual = rows(directory / "work/results" / f"{side}.jsonl")
        require(
            [{key: row[key] for key in HTTP_KEYS} for row in actual] == joined,
            "joined A/B differs from interleaved passes",
        )
        files[side] = joined
        bson = rows(directory / f"bson-{side}.jsonl")
        require(
            len(bson) == len(CASES) and {row.get("case") for row in bson} == CASES,
            "incomplete BSON cases",
        )
        require(
            all(number(row.get("ops_per_s")) and row["ops_per_s"] > 0 for row in bson),
            "invalid BSON metric",
        )
        files[f"bson-{side}"] = [
            {"case": row["case"], "ops_per_s": row["ops_per_s"]} for row in bson
        ]
    for version in ("6.0", "7.0", "8.0", "9.0"):
        label = "new-" + version
        files[label] = validate_http(
            directory / "work/results" / f"{label}.jsonl",
            label=label,
            side="new",
            version=version,
            manifest=manifest,
            runs=[1, 2, 3],
        )
    require(
        sum(
            len(data)
            for label, data in files.items()
            if label not in ("old", "new") and not label.startswith("bson")
        )
        == 213,
        "expected 213 HTTP samples",
    )
    require(
        len({row["mongo_version"] for side in ("old", "new") for row in files[side]})
        == 1,
        "A/B server versions differ",
    )
    require(
        all(
            len({row["mongo_version"] for row in data}) == 1
            for label, data in files.items()
            if not label.startswith("bson")
        ),
        "mixed server versions",
    )
    for label, data in files.items():
        if label in ("old", "new") or label.startswith("bson"):
            continue
        for api in sorted({row["api"] for row in data}):
            for container in ("nginx", "wrk", "mongo"):
                counters.append(
                    cpu(directory, label=label, api=api, container=container)
                )
    return {
        "manifest": manifest,
        "placement": placement,
        "files": files,
        "cpu": counters,
        "directory": directory.resolve(),
    }


def compare(paths: list[Path], *, trend: bool) -> str:
    command = ["resty", str(BENCH / "compare.lua")]
    cpu_file = paths[0].parent / "cpu.jsonl"
    if cpu_file.is_file():
        command += ["--cpu-file", str(cpu_file)]
    result = subprocess.run(
        command + (["--trend"] if trend else []) + [str(path) for path in paths],
        text=True,
        capture_output=True,
        check=False,
    )
    require(
        result.returncode in ((0,) if trend else (0, 1)), "comparison rejected data"
    )
    return result.stdout


def render(runs: list[dict], output: Path) -> None:
    require(len(runs) == 3, "exactly three complete all invocations required")
    require(
        len({run["directory"] for run in runs}) == 3,
        "three distinct all directories required",
    )
    require(
        all(run["manifest"] == runs[0]["manifest"] for run in runs),
        "repetitions use different source SHAs or profiles",
    )
    require(
        all(run["placement"] == runs[0]["placement"] for run in runs),
        "repetitions use different private placement",
    )
    require(not output.exists(), "public output must be a fresh directory")
    manifest = runs[0]["manifest"]
    lines = [
        "# Driver performance report",
        "",
        "## Setup",
        "",
        (
            "Three complete all invocations; each API uses the median of three measured samples. "
            "Only valid Mongo 4.4 A/B APIs gate: rps ratio >= 0.90 and p99 ratio <= 1.20. Invalid APIs count as neither pass nor fail. Trends do not gate."
        ),
        "",
        (
            "Cluster context, node identities and node types are private. CPU request/limit and memory: "
            "Mongo 1000m/2000m and 4Gi, nginx 900m/1000m and 512Mi, wrk 200m/300m and 512Mi, clone 200m/200m and 128Mi. Mongo, nginx and wrk have CPU requests below limits and are Burstable; clone has equal requests and limits by owner decision (2026-10-30). "
            "Mongo cache is 1.5GiB; data emptyDir is 10Gi and ephemeral storage limit 12Gi."
        ),
        "",
        (
            f"Old `{manifest['old_sha']}`; new `{manifest['new_sha']}`; controller `{manifest['controller_sha']}`. "
            "OpenResty 1.31.1.1; wrk 4.1.0. Full source blobs and workload parameters are in manifest.json."
        ),
        "",
        (
            "Two threads, 16 connections (connect_nopool: 4), 10s socket timeout, 10s warm-up and 30s samples. "
            "BSON: at most 1,000 warm-up operations, stopping at 1s (checked every 50 operations); "
            "measure in batches of 100 operations until the first batch ends at or after 2s per case. "
            "Authentication is enabled; a gain on /auth includes the new driver's cached salted password optimization."
        ),
        "",
    ]
    outcomes = {}
    with tempfile.TemporaryDirectory() as temporary:
        staging = Path(temporary)
        for repetition, run in enumerate(runs, 1):
            target = staging / f"run-{repetition}"
            target.mkdir()
            for label, data in run["files"].items():
                (target / f"{label}.jsonl").write_text(
                    "".join(json.dumps(row, sort_keys=True) + "\n" for row in data)
                )
            (target / "cpu.jsonl").write_text(
                "".join(json.dumps(row, sort_keys=True) + "\n" for row in run["cpu"])
            )
            table = compare([target / "old.jsonl", target / "new.jsonl"], trend=False)
            for line in table.split("\nCPU validity", 1)[0].strip().splitlines()[2:]:
                cells = [cell.strip() for cell in line.split("|")[1:-1]]
                outcomes.setdefault(cells[0], []).append(cells[-1])
            lines += [
                f"## Repetition {repetition}: A/B",
                "",
                table,
                f"## Repetition {repetition}: trends",
                "",
                compare(
                    [
                        target / f"{label}.jsonl"
                        for label in ("new", "new-6.0", "new-7.0", "new-8.0", "new-9.0")
                    ],
                    trend=True,
                ),
                f"## Repetition {repetition}: BSON",
                "",
                "| Case | Old ops/s | New ops/s |",
                "| --- | ---: | ---: |",
            ]
            bson = {
                side: {
                    row["case"]: row["ops_per_s"]
                    for row in run["files"][f"bson-{side}"]
                }
                for side in ("old", "new")
            }
            lines += [
                f"| {case} | {bson['old'][case]:.2f} | {bson['new'][case]:.2f} |"
                for case in sorted(CASES)
            ]
            lines += [
                "",
                f"## Repetition {repetition}: CPU diagnostics",
                "",
                "| Container | Available intervals | Approx mean cores | Throttled periods | Throttled seconds |",
                "| --- | ---: | ---: | ---: | ---: |",
            ]
            for container in ("nginx", "wrk", "mongo"):
                all_counters = [
                    row for row in run["cpu"] if row["container"] == container
                ]
                available = [row for row in all_counters if row["available"]]

                def total(key: str, available: list = available) -> float:
                    return sum(row[key] for row in available)

                mean = (
                    f"{total('usage_usec') / 1e6 / total('sample_time_epoch'):.3f}"
                    if available
                    else "unavailable"
                )
                throttle = (
                    f"{100 * total('nr_throttled') / total('nr_periods'):.2f}%"
                    if total("nr_periods")
                    else "unavailable"
                )
                seconds = (
                    f"{total('throttled_usec') / 1e6:.3f}"
                    if available
                    else "unavailable"
                )
                lines.append(
                    f"| {container} | {len(available)}/{len(all_counters)} | {mean} | {throttle} | {seconds} |"
                )
            lines += [
                "",
                (
                    "CPU intervals include warm-up and measurement and sequential snapshot overhead; these are approximate cgroup deltas, "
                    "nginx CPU/request divides usage_usec by completed preflight, warm-up and measured requests in the same interval. "
                    "It is informational and does not gate; A/B costs pool CPU and request counts across distinct passes. "
                    "Every container must have less than 1% throttled periods for an API/pass to be valid. "
                    "Missing counters are unavailable. CPU caps and throttling can limit these measurements; "
                    "missing diagnostics cannot establish absence of saturation."
                ),
                "",
            ]
        lines += [
            "## Failed and unstable APIs",
            "",
            "| API | Repetition 1 | Repetition 2 | Repetition 3 | Unstable |",
            "| --- | --- | --- | --- | --- |",
        ]
        for api, states in sorted(outcomes.items()):
            require(len(states) == 3, "incomplete comparison output")
            lines.append(
                f"| {api} | {' | '.join(states)} | {'yes' if 'pass' in states and 'fail' in states else 'no'} |"
            )
        failed = [api for api, states in sorted(outcomes.items()) if "fail" in states]
        lines += [
            "",
            "Needs-triage issue candidates: "
            + (", ".join(failed) if failed else "none")
            + ". "
            "No driver cause is inferred without profiling evidence; issue creation is a separate reviewed step.",
        ]
        write_json(staging / "manifest.json", manifest)
        (staging / "report.md").write_text("\n".join(lines) + "\n")
        shutil.copytree(staging, output)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(BENCH.parent), *args],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def run_all(directory: Path, *, environment: dict) -> int:
    with directory.with_suffix(".log").open("w") as log:
        return subprocess.run(
            [str(BENCH / "k8s/run-k8s.sh"), "all"],
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        ).returncode


def series(directory: Path, *, reuse: list[Path] | None = None) -> None:
    os.umask(0o077)
    require(not directory.exists(), "series directory must be fresh")
    require(len(reuse or []) <= 2, "reuse at most two complete all invocations")
    require(
        all(
            os.environ.get(key)
            for key in ("NEW_REF", "KUBE_CONTEXT", "MONGO_NODE", "BENCH_NODE")
        ),
        "required runner environment is missing",
    )
    require(
        os.environ.get("WRK_THREADS", "2") == "2"
        and os.environ.get("WRK_CONNECTIONS", "16") == "16",
        "series requires the approved two-thread, 16-connection profile",
    )
    new_sha = git("rev-parse", os.environ["NEW_REF"] + "^{commit}")
    old_sha = git("rev-parse", os.environ.get("OLD_REF", "3eb6349") + "^{commit}")
    source = {path: git("rev-parse", f"{new_sha}:{path}") for path in BLOBS}
    require(source == BLOBS, "NEW_REF workload differs from approved full profile")
    require(
        all(
            git("hash-object", str(BENCH.parent / path)) == BLOBS[path]
            for path in BLOBS
        ),
        "local workload/resources differ from approved profile",
    )
    controller_sha = git("rev-parse", "HEAD")
    require(
        not git(
            "diff",
            controller_sha,
            "--",
            "bench/report.py",
            "bench/compare.lua",
            "bench/k8s/run-k8s.sh",
        ),
        "controller must match its committed SHA",
    )
    manifest = {
        "old_sha": old_sha,
        "new_sha": new_sha,
        "controller_sha": controller_sha,
        "source_blobs": source,
        "profile": PROFILE,
    }
    placement = {key: os.environ[key.upper()] for key in PLACEMENT_KEYS}
    validated = [validate(path) for path in reuse or []]
    require(
        len({run["directory"] for run in validated}) == len(validated),
        "reused all directories must be distinct",
    )
    require(
        all(
            run["manifest"]
            == {**manifest, "tools": {"openresty": "1.31.1.1", "wrk": "4.1.0"}}
            and run["placement"] == placement
            for run in validated
        ),
        "reused invocation differs from current controller, sources, profile or placement",
    )
    directory.mkdir(parents=True)
    for repetition in range(len(validated) + 1, 4):
        require(
            git("rev-parse", "HEAD") == controller_sha,
            "controller HEAD changed during series",
        )
        result_dir = directory / f"run-{repetition}"
        environment = {
            **os.environ,
            **{key.upper(): value for key, value in placement.items()},
            "NEW_REF": new_sha,
            "OLD_REF": old_sha,
            "RUN_RESULT_DIR": str(result_dir),
            "WRK_THREADS": "2",
            "WRK_CONNECTIONS": "16",
        }
        returncode = run_all(result_dir, environment=environment)
        require(returncode in (0, 1), "all runner failed; inspect private series log")
        require(
            git("rev-parse", "HEAD") == controller_sha,
            "controller HEAD changed during series; results not attested",
        )
        write_json(
            result_dir / "run-manifest.json",
            {**manifest, "placement": placement},
        )
        validated.append(validate(result_dir))
    require(
        git("rev-parse", "HEAD") == controller_sha,
        "controller HEAD changed during series",
    )
    render(validated, directory / "public")


def launch(directory: Path, *, reuse: list[Path] | None = None) -> int:
    os.umask(0o077)
    directory = directory.absolute()
    log_path = directory.with_name(directory.name + ".controller.log")
    metadata_path = directory.with_name(directory.name + ".launch.json")
    require(
        all(
            not path.exists() and not path.is_symlink()
            for path in (directory, log_path, metadata_path)
        ),
        "series directory, controller log and launch metadata must be fresh",
    )
    directory.parent.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, "-u", str(BENCH / "report.py"), "series", str(directory)]
    if reuse:
        command += ["--reuse", *(str(path.absolute()) for path in reuse)]
    with metadata_path.open("x") as metadata, log_path.open("x") as log:
        try:
            child = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                close_fds=True,
                start_new_session=True,
            )
        except OSError as error:
            log.write(f"Launch failed: {error}\n")
            raise
        json.dump({"pid": child.pid, "log": str(log_path)}, metadata)
        metadata.write("\n")
    return child.pid


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    series_parser = commands.add_parser("series")
    series_parser.add_argument("directory", type=Path)
    series_parser.add_argument("--reuse", type=Path, nargs="+", default=[])
    launch_parser = commands.add_parser("launch")
    launch_parser.add_argument("directory", type=Path)
    launch_parser.add_argument("--reuse", type=Path, nargs="+", default=[])
    report = commands.add_parser("report")
    report.add_argument("output", type=Path)
    report.add_argument("runs", type=Path, nargs=3)
    args = parser.parse_args()
    if args.command == "series":
        series(args.directory.absolute(), reuse=args.reuse)
    elif args.command == "launch":
        print(launch(args.directory.absolute(), reuse=args.reuse))
    else:
        render([validate(path) for path in args.runs], args.output.absolute())


if __name__ == "__main__":
    main()
