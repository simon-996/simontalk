"""Required restores cannot skip; generated Docker tools preserve process boundaries."""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from test_backup_bundle_integration import pg_tools

SCRIPT = Path(__file__).resolve().parents[3] / "scripts/prepare_test_postgres_tools.py"


@pytest.mark.parametrize("provided", [None, "dump", "restore"])
def test_required_real_restore_cannot_silently_skip(monkeypatch, provided):
    monkeypatch.setenv("SIMONTALK_REQUIRE_REAL_BACKUP_TESTS", "1")
    for key in ("SIMONTALK_BACKUP_TEST_PG_DUMP", "SIMONTALK_BACKUP_TEST_PG_RESTORE"):
        monkeypatch.delenv(key, raising=False)
    if provided:
        monkeypatch.setenv("SIMONTALK_BACKUP_TEST_PG_" + provided.upper(), "/absolute/tool")
    try:
        with pytest.raises(pytest.fail.Exception):
            pg_tools.__wrapped__()
    except pytest.skip.Exception:
        pytest.fail("Required restore incorrectly skipped")


def test_optional_local_restore_still_reports_skip(monkeypatch):
    monkeypatch.delenv("SIMONTALK_REQUIRE_REAL_BACKUP_TESTS", raising=False)
    monkeypatch.delenv("SIMONTALK_BACKUP_TEST_PG_DUMP", raising=False)
    monkeypatch.delenv("SIMONTALK_BACKUP_TEST_PG_RESTORE", raising=False)
    with pytest.raises(pytest.skip.Exception):
        pg_tools.__wrapped__()


@pytest.fixture
def generator():
    assert SCRIPT.is_file(), "Missing CI PostgreSQL tool generator"
    spec = importlib.util.spec_from_file_location("postgres_test_tools", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def docker(tmp_path, monkeypatch):
    target = tmp_path / "docker"
    target.write_text(
        f"#!{sys.executable}\n"
        "import json,os,sys\nfrom pathlib import Path\n"
        "assert os.environ['PGHOST']=='127.0.0.1' and os.environ['PGPORT']=='5432'\n"
        "assert os.environ['PGPASSWORD']=='private-fixture-password'\n"
        "Path(os.environ['CAPTURE']).write_text(json.dumps(sys.argv[1:]))\n"
        "sys.stdout.buffer.write(sys.stdin.buffer.read()+b'\\x00\\xff')\n"
        "sys.stderr.write('controlled-stderr')\nsys.exit(7)\n"
    )
    target.chmod(0o700)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ.get("PATH", ""))
    return target


@pytest.mark.parametrize("tool", ["pg_dump", "pg_restore"])
def test_generated_tools_forward_binary_streams_env_names_and_exit_code(
    generator, docker, tmp_path, tool
):
    directory = tmp_path / "tools"
    generator.prepare_tools("a" * 64, directory)
    assert directory.stat().st_mode & 0o777 == 0o700
    assert {p.name for p in directory.iterdir()} == {"pg_dump", "pg_restore"}
    for path in directory.iterdir():
        assert path.stat().st_mode & 0o777 == 0o700
        assert "private-fixture-password" not in path.read_text()
    capture = tmp_path / "capture.json"
    result = subprocess.run(
        [str(directory / tool), "--dbname=fixture_test"],
        input=b"binary\x00\x80",
        capture_output=True,
        timeout=5,
        env={
            "PATH": os.environ["PATH"],
            "PGHOST": "different-host",
            "PGPORT": "9999",
            "PGUSER": "fixture",
            "PGDATABASE": "fixture_test",
            "PGPASSWORD": "private-fixture-password",
            "CAPTURE": str(capture),
        },
    )
    assert result.returncode == 7
    assert result.stdout == b"binary\x00\x80\x00\xff" and result.stderr == b"controlled-stderr"
    args = json.loads(capture.read_text())
    assert args[:2] == ["exec", "-i"]
    assert args[-3:] == ["a" * 64, tool, "--dbname=fixture_test"]
    assert "PGPASSWORD" in args and "PGDATABASE" in args
    assert "private-fixture-password" not in repr(args)


@pytest.mark.parametrize("container", ["", "--privileged", "a" * 11, "a" * 65, "container/name"])
def test_invalid_container_is_rejected_before_creating_output(
    generator, docker, tmp_path, container
):
    target = tmp_path / "tools"
    with pytest.raises(ValueError):
        generator.prepare_tools(container, target)
    assert not target.exists()


@pytest.mark.parametrize("kind", ["directory", "file", "symlink"])
def test_existing_output_is_never_overwritten(generator, docker, tmp_path, kind):
    target = tmp_path / "tools"
    if kind == "directory":
        target.mkdir()
        (target / "keep").write_text("original")
    elif kind == "file":
        target.write_text("original")
    else:
        source = tmp_path / "source"
        source.write_text("original")
        target.symlink_to(source)
    with pytest.raises(FileExistsError):
        generator.prepare_tools("a" * 64, target)
    assert (target / "keep" if kind == "directory" else target).read_text() == "original"


def test_relative_directory_is_rejected(generator, docker):
    with pytest.raises(ValueError):
        generator.prepare_tools("a" * 64, Path("relative-tools"))


def test_generated_tools_refuse_non_test_database(generator, docker, tmp_path):
    directory = tmp_path / "tools"
    generator.prepare_tools("a" * 64, directory)
    capture = tmp_path / "capture.json"
    result = subprocess.run(
        [str(directory / "pg_dump")],
        capture_output=True,
        timeout=5,
        env={"PATH": os.environ["PATH"], "PGDATABASE": "production", "CAPTURE": str(capture)},
    )
    assert result.returncode != 0 and not capture.exists()
    assert b"production" not in result.stderr
