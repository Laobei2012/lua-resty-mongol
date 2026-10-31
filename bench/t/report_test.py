"""Full synthetic workload fixtures; never use cluster diagnostics in tests."""

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location(
    "report", Path(__file__).parents[1] / "report.py"
)
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)
CANARY = "PRIVATE-CONTEXT-NODE-MODEL-IDENTITY-CANARY"


def test_bson_source_pin_matches_workload() -> None:
    content = (report.BENCH / "bson_micro.lua").read_bytes()
    header = f"blob {len(content)}\0".encode()
    assert (
        report.BLOBS["bench/bson_micro.lua"]
        == hashlib.sha1(header + content).hexdigest()
    )


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
        "placement": {key: CANARY for key in report.PLACEMENT_KEYS},
    }
    report.write_json(directory / "run-manifest.json", manifest)
    report.write_json(
        directory / "tool-versions.json",
        {"openresty": "1.31.1.1", "wrk": "4.1.0", "node": CANARY},
    )
    (directory / "pods.yaml").write_text(CANARY)
    (directory / "refs.txt").write_text(CANARY)
    (directory / "namespace-uid").write_text(CANARY)
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
            "interval_requests": 1001 + 3000 * len(runs),
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
        "legacy-bson-profile",
        "legacy-bson-source",
        "bson",
        "joined",
        "duplicate",
        "nonfinite",
        "tools",
        "source",
        "placement-missing",
        "placement-invalid",
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
    elif damage == "legacy-bson-profile":
        manifest = report.read_json(directory / "run-manifest.json")
        manifest["profile"]["bson_warmup"] = 100000
        for key in ("bson_warmup_seconds", "bson_warmup_batch", "bson_measure_batch"):
            del manifest["profile"][key]
        report.write_json(directory / "run-manifest.json", manifest)
    elif damage == "legacy-bson-source":
        manifest = report.read_json(directory / "run-manifest.json")
        manifest["source_blobs"]["bench/bson_micro.lua"] = (
            "ae48a3ade0f915b5171110e3a05570bcc0803b09"
        )
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
    elif damage.startswith("placement-"):
        manifest = report.read_json(directory / "run-manifest.json")
        if damage == "placement-missing":
            del manifest["placement"]
        else:
            manifest["placement"]["kube_context"] = 1
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
        return (
            f"| API | Result |\n| --- | --- |\n| ping | {state} |\n"
            "\nCPU validity per pass/API (warm-up, measurement and snapshot overhead):\n\n"
            "| Pass | API | Validity | Conditions |\n| --- | --- | --- | --- |\n"
            "| old-1 | ping | valid | nginx usage 0.95 cores |\n"
        )

    monkeypatch.setattr(report, "compare", compare)
    output = tmp_path / "public"
    report.render(runs, output)
    assert require_actual == [2, 5] * 3
    exported = "".join(path.read_text() for path in output.rglob("*") if path.is_file())
    assert CANARY not in exported
    assert "| ping | pass | fail | pass | yes |" in exported
    assert "Needs-triage issue candidates: ping" in exported
    assert "unavailable" in exported
    assert "at most 1,000 warm-up operations, stopping at 1s" in exported
    assert "measure in batches of 100 operations" in exported
    assert len(report.rows(output / "run-1/new-9.0.jsonl")) == 36
    with pytest.raises(ValueError, match="exactly three"):
        report.render(runs[:2], tmp_path / "partial")
    with pytest.raises(ValueError, match="distinct"):
        report.render([runs[0]] * 3, tmp_path / "duplicate")
    runs[2]["manifest"]["new_sha"] = "c" * 40
    with pytest.raises(ValueError, match="different source"):
        report.render(runs, tmp_path / "mixed")
    runs[2]["manifest"]["new_sha"] = runs[0]["manifest"]["new_sha"]
    runs[2]["placement"]["bench_node"] = "another-private-node"
    with pytest.raises(ValueError, match="private placement"):
        report.render(runs, tmp_path / "different-placement")


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


@pytest.fixture
def series_calls(monkeypatch: pytest.MonkeyPatch) -> list[Path]:
    calls = []

    def git(*args: str) -> str:
        if args[0] == "diff":
            return ""
        if args[0] == "hash-object":
            return report.BLOBS[str(Path(args[1]).relative_to(report.BENCH.parent))]
        if ":bench/" in args[-1]:
            return report.BLOBS[args[-1].split(":", 1)[1]]
        if args[-1] == "HEAD":
            return "b" * 40
        if args[-1].startswith("3eb6349"):
            return "3eb6349db4d30b11aab271fb14a82b8504f6aa8e"
        return "a" * 40

    def run_all(directory: Path, *, environment: dict) -> int:
        calls.append(directory)
        assert environment["NEW_REF"] == "a" * 40
        assert environment["OLD_REF"] == "3eb6349db4d30b11aab271fb14a82b8504f6aa8e"
        assert environment["RUN_RESULT_DIR"] == str(directory)
        fixture(directory)
        (directory / "run-manifest.json").unlink()
        return 1  # A complete performance gate failure is eligible for reporting.

    monkeypatch.setenv("NEW_REF", "test-new")
    for key in ("KUBE_CONTEXT", "MONGO_NODE", "BENCH_NODE"):
        monkeypatch.setenv(key, CANARY)
    monkeypatch.delenv("OLD_REF", raising=False)
    monkeypatch.setattr(report, "git", git)
    monkeypatch.setattr(report, "run_all", run_all)
    monkeypatch.setattr(
        report,
        "compare",
        lambda paths, *, trend: "| API | Result |\n| --- | --- |\n| ping | pass |\n",
    )
    return calls


@pytest.mark.parametrize("reuse_count", [0, 1, 2])
def test_series_reuses_only_completed_full_invocations(
    tmp_path: Path, series_calls: list[Path], reuse_count: int
) -> None:
    reused = [fixture(tmp_path / f"{CANARY}-{n}") for n in range(reuse_count)]
    original = {
        path: path.read_bytes()
        for directory in reused
        for path in directory.rglob("*")
        if path.is_file()
    }
    output = tmp_path / "series"
    if reuse_count:
        report.series(output, reuse=reused)
    else:
        report.series(output)
    assert series_calls == [output / f"run-{n}" for n in range(reuse_count + 1, 4)]
    assert all(path.read_bytes() == data for path, data in original.items())
    for n in (1, 2, 3):
        assert len(report.rows(output / f"public/run-{n}/new-9.0.jsonl")) == 36
    exported = "".join(
        path.read_text() for path in (output / "public").rglob("*") if path.is_file()
    )
    assert CANARY not in exported
    assert str(tmp_path) not in exported


@pytest.mark.parametrize(
    "damage",
    [
        "incomplete",
        "controller",
        "new-sha",
        "profile",
        "source",
        "tools",
        "coverage",
        "bson",
        "joined",
        "duplicate",
        "too-many",
        *report.PLACEMENT_KEYS,
    ],
)
def test_series_rejects_reuse_before_runner_calls(
    tmp_path: Path, series_calls: list[Path], damage: str
) -> None:
    directory = fixture(tmp_path / "previous")
    reused = [directory]
    manifest = report.read_json(directory / "run-manifest.json")
    if damage == "incomplete":
        (directory / "COMPLETE").unlink()
    elif damage == "controller":
        manifest["controller_sha"] = "c" * 40
    elif damage == "new-sha":
        manifest["new_sha"] = "c" * 40
        for path in (directory / "work/results").glob("new*.jsonl"):
            data = report.rows(path)
            for row in data:
                row["driver_sha"] = manifest["new_sha"]
            save(path, data)
    elif damage == "profile":
        manifest["profile"]["warmup_s"] = 1
    elif damage == "source":
        manifest["source_blobs"]["bench/load.sh"] = "c" * 40
    elif damage == "tools":
        report.write_json(directory / "tool-versions.json", {"wrk": "4.1.0"})
    elif damage == "coverage":
        save(directory / "work/results/new-9.0.jsonl", [])
    elif damage == "bson":
        save(directory / "bson-old.jsonl", [])
    elif damage == "joined":
        save(directory / "work/results/new.jsonl", [])
    elif damage == "duplicate":
        alias = tmp_path / "alias"
        alias.symlink_to(directory, target_is_directory=True)
        reused.append(alias)
    elif damage == "too-many":
        reused.extend(fixture(tmp_path / f"previous-{n}") for n in (2, 3))
    elif damage in report.PLACEMENT_KEYS:
        manifest["placement"][damage] = "another-private-placement"
    report.write_json(directory / "run-manifest.json", manifest)
    before = (directory / "run-manifest.json").read_bytes()
    with pytest.raises((ValueError, FileNotFoundError)):
        report.series(tmp_path / "series", reuse=reused)
    assert not series_calls
    assert not (tmp_path / "series").exists()
    assert (directory / "run-manifest.json").read_bytes() == before


def test_series_rejects_existing_recovery_directory(
    tmp_path: Path, series_calls: list[Path]
) -> None:
    directory = tmp_path / "series"
    directory.mkdir()
    with pytest.raises(ValueError, match="fresh"):
        report.series(directory)
    assert not series_calls


def test_series_does_not_attest_results_after_head_changes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, series_calls: list[Path]
) -> None:
    previous = [fixture(tmp_path / f"previous-{n}") for n in (1, 2)]
    original_git = report.git

    def git(*args: str) -> str:
        if args[-1] == "HEAD" and series_calls:
            return "c" * 40
        return original_git(*args)

    monkeypatch.setattr(report, "git", git)
    output = tmp_path / "series"
    with pytest.raises(ValueError, match="HEAD changed"):
        report.series(output, reuse=previous)
    assert series_calls == [output / "run-3"]
    assert (output / "run-3/COMPLETE").read_text() == "all\n"
    assert not (output / "run-3/run-manifest.json").exists()
    assert not (output / "public").exists()


def test_series_cli_accepts_reuse_paths(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    called = []
    reused = [tmp_path / "one", tmp_path / "two"]
    monkeypatch.setattr(
        sys,
        "argv",
        ["report.py", "series", str(tmp_path / "fresh"), "--reuse", *map(str, reused)],
    )
    monkeypatch.setattr(
        report, "series", lambda directory, *, reuse: called.append((directory, reuse))
    )
    report.main()
    assert called == [(tmp_path / "fresh", reused)]


@pytest.fixture
def launch_calls(monkeypatch: pytest.MonkeyPatch) -> list[dict]:
    calls = []

    class Child:
        pid = 12345

    def popen(command: list, **options: object) -> Child:
        calls.append({"command": command, **options})
        options["stdout"].write("child diagnostic\n")
        return Child()

    def unexpected(*args: object, **kwargs: object) -> None:
        pytest.fail("launcher must not run benchmarks or foreground series itself")

    monkeypatch.setattr(report.subprocess, "Popen", popen)
    monkeypatch.setattr(report, "series", unexpected)
    monkeypatch.setattr(report, "run_all", unexpected)
    return calls


@pytest.mark.parametrize("reuse_count", [0, 1, 2])
def test_launch_detaches_exact_series_with_private_artifacts(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    launch_calls: list[dict],
    reuse_count: int,
) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("KUBE_CONTEXT", CANARY)
    directory = Path("private/series")
    reused = [Path(f"previous-{n}") for n in range(reuse_count)]
    previous_umask = os.umask(0o022)
    try:
        pid = report.launch(directory, reuse=reused)
    finally:
        os.umask(previous_umask)
    assert pid == 12345
    assert len(launch_calls) == 1
    call = launch_calls[0]
    command = [
        sys.executable,
        "-u",
        str(report.BENCH / "report.py"),
        "series",
        str(directory.absolute()),
    ]
    if reused:
        command += ["--reuse", *(str(path.absolute()) for path in reused)]
    assert call["command"] == command
    assert call["stdin"] == report.subprocess.DEVNULL
    assert call["stderr"] == report.subprocess.STDOUT
    assert call["close_fds"] is True
    assert call["start_new_session"] is True
    assert set(call) == {
        "command",
        "stdin",
        "stdout",
        "stderr",
        "close_fds",
        "start_new_session",
    }
    assert call["stdout"].closed
    log = tmp_path / "private/series.controller.log"
    metadata = tmp_path / "private/series.launch.json"
    assert report.read_json(metadata) == {"pid": pid, "log": str(log)}
    assert log.read_text() == "child diagnostic\n"
    assert CANARY not in metadata.read_text()
    assert metadata.stat().st_mode & 0o777 == 0o600
    assert log.stat().st_mode & 0o777 == 0o600
    assert directory.parent.stat().st_mode & 0o777 == 0o700
    assert not directory.exists()  # Only the child series may create results.
    assert not (directory / "public").exists()


@pytest.mark.parametrize(
    "existing",
    ["series", "log", "metadata", "broken-series", "broken-log", "broken-metadata"],
)
def test_launch_refuses_existing_results_or_sidecars(
    tmp_path: Path, launch_calls: list[dict], existing: str
) -> None:
    directory = tmp_path / "series"
    paths = {
        "series": directory,
        "log": tmp_path / "series.controller.log",
        "metadata": tmp_path / "series.launch.json",
    }
    path = paths[existing.removeprefix("broken-")]
    if existing.startswith("broken-"):
        path.symlink_to(tmp_path / "missing")
    elif existing == "series":
        path.mkdir()
    else:
        path.write_text("do not overwrite\n")
    before = set(tmp_path.iterdir())
    with pytest.raises(ValueError, match="fresh"):
        report.launch(directory)
    assert not launch_calls
    assert set(tmp_path.iterdir()) == before
    if path.is_file():
        assert path.read_text() == "do not overwrite\n"


def test_launch_failure_preserves_private_diagnostics_without_pid(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, launch_calls: list[dict]
) -> None:
    attempts = []

    def popen(command: list, **options: object) -> None:
        attempts.append(command)
        raise OSError("fixture launch failure")

    monkeypatch.setattr(report.subprocess, "Popen", popen)
    directory = tmp_path / "series"
    with pytest.raises(OSError, match="fixture launch failure"):
        report.launch(directory)
    assert not directory.exists()
    assert not launch_calls
    assert len(attempts) == 1
    metadata = tmp_path / "series.launch.json"
    log = tmp_path / "series.controller.log"
    assert metadata.read_text() == ""
    assert log.read_text() == "Launch failed: fixture launch failure\n"
    assert metadata.stat().st_mode & 0o777 == log.stat().st_mode & 0o777 == 0o600
    with pytest.raises(ValueError, match="fresh"):
        report.launch(directory)


def test_launch_cli_prints_pid_and_forwards_reuse(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture,
    launch_calls: list[dict],
) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "report.py",
            "launch",
            str(tmp_path / "series"),
            "--reuse",
            str(tmp_path / "old"),
        ],
    )
    report.main()
    assert capsys.readouterr().out == "12345\n"
    assert launch_calls[0]["command"][-2:] == ["--reuse", str(tmp_path / "old")]


@pytest.mark.parametrize(
    "path",
    [
        "bench/load.sh",
        "bench/wrk_report.lua",
        "bench/k8s/bench.yaml",
        "bench/k8s/mongo.yaml",
    ],
)
def test_calibrated_source_pins(path: str) -> None:
    content = (report.BENCH.parent / path).read_bytes()
    assert (
        report.BLOBS[path]
        == hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest()
    )


def test_calibrated_profile() -> None:
    assert report.PROFILE["threads"] == 2
    assert report.PROFILE["connections"] == 16
    assert report.PROFILE["warmup_s"] == 10


@pytest.mark.parametrize("setting", [{"WRK_THREADS": "1"}, {"WRK_CONNECTIONS": "32"}])
def test_series_rejects_unapproved_load(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, setting: dict
) -> None:
    for key in ("NEW_REF", "KUBE_CONTEXT", "MONGO_NODE", "BENCH_NODE"):
        monkeypatch.setenv(key, "fixture")
    for key, value in setting.items():
        monkeypatch.setenv(key, value)
    with pytest.raises(ValueError, match="approved two-thread"):
        report.series(tmp_path / "series")


def test_compare_uses_public_cpu_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from types import SimpleNamespace

    (tmp_path / "cpu.jsonl").write_text("")
    calls = []

    def run(command: list, **kwargs: object) -> object:
        calls.append(command)
        return SimpleNamespace(returncode=0, stdout="table")

    monkeypatch.setattr(report.subprocess, "run", run)
    assert (
        report.compare([tmp_path / "old.jsonl", tmp_path / "new.jsonl"], trend=False)
        == "table"
    )
    assert calls[0][2:4] == ["--cpu-file", str(tmp_path / "cpu.jsonl")]


@pytest.mark.parametrize("value", [0, -1, 1.5, None, True, "400"])
def test_rejects_invalid_interval_request_count(tmp_path: Path, value: object) -> None:
    directory = fixture(tmp_path / "source")
    path = directory / "work/results/new-9.0.jsonl"
    data = report.rows(path)
    data[0]["interval_requests"] = value
    save(path, data)
    with pytest.raises(ValueError):
        report.validate(directory)


def test_exports_request_count_and_upstream_bson_case(tmp_path: Path) -> None:
    data = report.validate(fixture(tmp_path / "source"))
    assert data["files"]["new"][0]["interval_requests"] == 4001
    assert "decode_reply" in report.CASES


def test_rejects_inconsistent_interval_request_count(tmp_path: Path) -> None:
    directory = fixture(tmp_path / "source")
    path = directory / "work/results/new-9.0.jsonl"
    data = report.rows(path)
    data[0]["interval_requests"] += 1
    save(path, data)
    with pytest.raises(ValueError, match="inconsistent interval request counts"):
        report.validate(directory)


def test_approved_cpu_requests_and_limits() -> None:
    import re

    content = (report.BENCH / "k8s/bench.yaml").read_text()
    assert re.findall(r"cpu: (\d+m)", content) == [
        "200m",
        "200m",
        "900m",
        "1000m",
        "200m",
        "300m",
    ]
