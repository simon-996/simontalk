import json

import pytest
from test_deletion_archive import deleted as deleted
from test_deletion_archive import restore_rows
from test_deletion_archive import scope as scope
from test_deletion_archive import target_source as target_source
from test_rehearsal_targets import rows

from simontalk_api import cli
from simontalk_api.deletion_archive import write_archive


def configure(monkeypatch, factory, arguments):
    monkeypatch.setenv(
        "SIMONTALK_DATABASE_URL", factory.kw["bind"].url.render_as_string(hide_password=False)
    )
    monkeypatch.setenv("SIMONTALK_ENVIRONMENT", "test")
    monkeypatch.setattr("sys.argv", ["simontalk-admin", *arguments])


def test_cli_defaults_to_preflight_with_no_business_writes(
    deleted, factory, tmp_path, monkeypatch, capsys
):
    path = tmp_path / "deletions.json"
    write_archive(path, deleted.archive)
    restore_rows(factory, deleted.backup)
    before = rows(factory)
    configure(monkeypatch, factory, ["replay-deletions", "--input", str(path)])
    cli.main()
    result = json.loads(capsys.readouterr().out)
    assert result["applied"] is False and result["present_records"] == 3
    assert rows(factory) == before


def test_cli_apply_requires_target_then_replays(deleted, factory, tmp_path, monkeypatch, capsys):
    path = tmp_path / "deletions.json"
    write_archive(path, deleted.archive)
    restore_rows(factory, deleted.backup)
    before = rows(factory)
    configure(
        monkeypatch,
        factory,
        ["replay-deletions", "--input", str(path), "--apply", "--confirm-database", "wrong"],
    )
    with pytest.raises(SystemExit) as error:
        cli.main()
    assert error.value.code == 1
    assert rows(factory) == before
    capsys.readouterr()
    configure(
        monkeypatch,
        factory,
        [
            "replay-deletions",
            "--input",
            str(path),
            "--apply",
            "--confirm-database",
            factory.kw["bind"].url.database,
        ],
    )
    cli.main()
    assert json.loads(capsys.readouterr().out)["applied"] is True


def test_cli_export_and_existing_file_error_do_not_expose_connection_or_content(
    deleted, factory, tmp_path, monkeypatch, capsys
):
    path = tmp_path / "deletions.json"
    configure(monkeypatch, factory, ["export-deletions", "--output", str(path)])
    cli.main()
    message = capsys.readouterr().out
    assert json.loads(message)["receipt_count"] == 2
    assert deleted.source.original["text"] not in message and "postgresql" not in message
    original = path.read_bytes()
    with pytest.raises(SystemExit) as error:
        cli.main()
    assert error.value.code == 1 and path.read_bytes() == original
    output = capsys.readouterr()
    assert output.out == "" and "postgresql" not in output.err and str(path) not in output.err


def test_cli_bad_manifest_never_echoes_private_payload(factory, tmp_path, monkeypatch, capsys):
    path = tmp_path / "invalid.json"
    path.write_text('{"unexpected":"PRIVATE-TEXT-AND-CREDENTIAL"}')
    configure(
        monkeypatch,
        factory,
        [
            "replay-deletions",
            "--input",
            str(path),
            "--apply",
            "--confirm-database",
            factory.kw["bind"].url.database,
        ],
    )
    with pytest.raises(SystemExit) as error:
        cli.main()
    assert error.value.code == 1
    output = capsys.readouterr()
    assert output.out == "" and "PRIVATE-TEXT" not in output.err
