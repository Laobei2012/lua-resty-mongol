"""Full synthetic workload fixtures; never use cluster diagnostics in tests."""

import importlib.util
import json
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location(
    "report", Path(__file__).parents[1] / "report.py"
)
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)
CANARY = "PRIVATE-CONTEXT-NODE-MODEL-IDENTITY-CANARY"


def fixture(directory: Path) -> Path:
    (directory / "work/results").mkdir(parents=True)
    (directory / "COMPLETE").write_text("all\n")
    manifest = {
        "old_sha": "3eb6349db4d30b11aab271fb14a82b8504f6aa8e",
        "new_sha": "a" * 40,
        "controller_sha": "b" * 40,
        "profile": report.PROFILE,
        "source_blobs": report.BLOBS,
        "context": CANARY,
    }
    report.write_json(directory / "run-manifest.json", manifest)
    report.write_json(
        directory / "tool-versions.json",
        {"openresty": "1.31.1.1", "wrk": "4.1.0", "node": CANARY},
    )
    (directory / "pods.yaml").write_text(CANARY)
    (directory / "refs.txt").write_text(CANARY)
    for side in ("old", "new"):
        combined = []
        for run in (1, 2, 3):
            label = f"{side}-{run}"
            data = samples(
                label=label, side=side, version="4.4.29", runs=[run], manifest=manifest
            )
            save(directory / "work/results" / f"{label}.jsonl", data)
            combined.extend(data)
        save(directory / "work/results" / f"{side}.jsonl", combined)
        save(
            directory / f"bson-{side}.jsonl",
            [
                {"case": case, "ops_per_s": 100, "secret": CANARY}
                for case in sorted(report.CASES)
            ],
        )
    for version in ("6.0", "7.0", "8.0", "9.0"):
        label = "new-" + version
        save(
            directory / "work/results" / f"{label}.jsonl",
            samples(
                label=label,
                side="new",
                version=version + ".1",
                runs=[1, 2, 3],
                manifest=manifest,
            ),
        )
    return directory


def samples(*, label: str, side: str, version: str, runs: list, manifest: dict) -> list:
    return [
        {
            "label": label,
            "driver_sha": manifest[side + "_sha"],
            "mongo_version": version,
            "api": api,
            "run": run,
            "rps": 100,
            "p50_ms": 1,
            "p90_ms": 2,
            "p99_ms": 3,
            "non2xx": 0,
            "socket_errors": 0,
            "private": CANARY,
        }
        for api in report.APIS
        if side != "old" or api != "find_100"
        for run in runs
    ]


def save(path: Path, data: list) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in data))


@pytest.mark.parametrize(
    "damage",
    [
        "incomplete",
        "coverage",
        "label",
        "run",
        "errors",
        "version",
        "sha",
        "short",
        "bson",
        "joined",
        "duplicate",
        "nonfinite",
        "tools",
        "source",
    ],
)
def test_rejects_invalid_invocations(tmp_path: Path, damage: str) -> None:
    directory = fixture(tmp_path / "source")
    data_path = directory / "work/results/new-9.0.jsonl"
    data = report.rows(data_path)
    if damage == "incomplete":
        (directory / "COMPLETE").unlink()
    elif damage == "coverage":
        data.pop()
    elif damage == "label":
        data[0]["label"] = "new-8.0"
    elif damage == "run":
        data[0]["run"] = 0
    elif damage == "errors":
        data[0]["socket_errors"] = 1
    elif damage == "version":
        data[0]["mongo_version"] = "8.0.1"
    elif damage == "sha":
        data[0]["driver_sha"] = "c" * 40
    elif damage == "short":
        manifest = report.read_json(directory / "run-manifest.json")
        manifest["profile"]["sample_s"] = 1
        report.write_json(directory / "run-manifest.json", manifest)
    elif damage == "bson":
        save(directory / "bson-old.jsonl", [])
    elif damage == "joined":
        save(directory / "work/results/new.jsonl", [])
    elif damage == "duplicate":
        data.append(data[0])
    elif damage == "nonfinite":
        data[0]["rps"] = float("nan")
    elif damage == "tools":
        report.write_json(
            directory / "tool-versions.json", {"openresty": "1.0", "wrk": "4.1.0"}
        )
    elif damage == "source":
        manifest = report.read_json(directory / "run-manifest.json")
        manifest["source_blobs"]["bench/load.sh"] = "c" * 40
        report.write_json(directory / "run-manifest.json", manifest)
    save(data_path, data)
    with pytest.raises((ValueError, FileNotFoundError)):
        report.validate(directory)


def test_allowlist_export(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    runs = [report.validate(fixture(tmp_path / f"source-{n}")) for n in range(3)]
    require_actual = []

    def compare(paths: list, *, trend: bool) -> str:
        require_actual.append(len(paths))
        if trend:
            return "| API | 4.4.29 rps |\n| --- | --- |\n| ping | 100 |\n"
        state = "fail" if paths[0].parent.name == "run-2" else "pass"
        return f"| API | Result |\n| --- | --- |\n| ping | {state} |\n"

    monkeypatch.setattr(report, "compare", compare)
    output = tmp_path / "public"
    report.render(runs, output)
    assert require_actual == [2, 5] * 3
    exported = "".join(path.read_text() for path in output.rglob("*") if path.is_file())
    assert CANARY not in exported
    assert "| ping | pass | fail | pass | yes |" in exported
    assert "Needs-triage issue candidates: ping" in exported
    assert "unavailable" in exported
    assert len(report.rows(output / "run-1/new-9.0.jsonl")) == 36
    with pytest.raises(ValueError, match="exactly three"):
        report.render(runs[:2], tmp_path / "partial")
    with pytest.raises(ValueError, match="distinct"):
        report.render([runs[0]] * 3, tmp_path / "duplicate")
    runs[2]["manifest"]["new_sha"] = "c" * 40
    with pytest.raises(ValueError, match="different source"):
        report.render(runs, tmp_path / "mixed")


def test_cpu_deltas_and_unavailable(tmp_path: Path) -> None:
    (tmp_path / "cpu").mkdir()
    for phase, epoch, usage in (("before", 10, 100), ("after", 20, 200)):
        (tmp_path / "cpu" / f"old-1-ping-{phase}-nginx.stat").write_text(
            f"sample_time_epoch {epoch}\ncgroup v2\nusage_usec {usage}\nnr_periods {usage}\nnr_throttled {usage // 10}\nthrottled_usec {usage}\n{CANARY}\n"
        )
    result = report.cpu(tmp_path, label="old-1", api="ping", container="nginx")
    assert (
        result["available"]
        and result["usage_usec"] == 100
        and result["sample_time_epoch"] == 10
    )
    assert CANARY not in json.dumps(result)
    (tmp_path / "cpu/old-1-ping-after-nginx.stat").write_text("unavailable: " + CANARY)
    assert not report.cpu(tmp_path, label="old-1", api="ping", container="nginx")[
        "available"
    ]


@pytest.mark.parametrize("failure", [None, "incomplete", "invalid-return"])
def test_series_continues_only_complete_gate_failures(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, failure: str
) -> None:
    calls = []

    def git(*args: str) -> str:
        if args[0] == "diff":
            return ""
        if args[0] == "hash-object":
            return report.BLOBS[str(Path(args[1]).relative_to(report.BENCH.parent))]
        if ":bench/" in args[-1]:
            return report.BLOBS[args[-1].split(":", 1)[1]]
        return (
            "3eb6349db4d30b11aab271fb14a82b8504f6aa8e"
            if args[-1].startswith("3eb6349")
            else "a" * 40
        )

    def run_all(directory: Path, *, environment: dict) -> int:
        calls.append(directory.name)
        assert environment["NEW_REF"] == "a" * 40
        fixture(directory)
        if failure == "incomplete":
            (directory / "COMPLETE").unlink()
        return 2 if failure == "invalid-return" else 1

    monkeypatch.setenv("NEW_REF", "test-new")
    for key in ("KUBE_CONTEXT", "MONGO_NODE", "BENCH_NODE"):
        monkeypatch.setenv(key, CANARY)
    monkeypatch.delenv("OLD_REF", raising=False)
    monkeypatch.setattr(report, "git", git)
    monkeypatch.setattr(report, "run_all", run_all)
    monkeypatch.setattr(
        report,
        "render",
        lambda runs, output: output.mkdir() if len(runs) == 3 else None,
    )
    if failure:
        with pytest.raises((ValueError, FileNotFoundError)):
            report.series(tmp_path / "series")
        assert calls == ["run-1"]
        assert not (tmp_path / "series/public").exists()
    else:
        report.series(tmp_path / "series")
        assert calls == ["run-1", "run-2", "run-3"]
        assert (tmp_path / "series/public").is_dir()
