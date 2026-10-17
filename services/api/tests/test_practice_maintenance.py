import os
import subprocess
import sys
from datetime import timedelta
from threading import Event
from time import monotonic

import pytest
from conftest import TEST_URL
from fastapi.testclient import TestClient
from sqlalchemy import text
from test_connection_reservations import path, reserve
from test_connection_reservations import prepared as prepared
from test_preparation_cleanup import age

from simontalk_api.config import Settings
from simontalk_api.main import create_app
from simontalk_api.security import now


def test_batch_expires_connection_then_preserves_recent_safe_ending(
    client, prepared, factory, monkeypatch
):
    from simontalk_api import preparation_cleanup
    from simontalk_api.practice_maintenance import run_maintenance_batch

    saved = reserve(client, prepared).json()
    age(factory, prepared, now() - timedelta(hours=1))
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
            {"past": now() - timedelta(seconds=1), "id": saved["id"]},
        )
    result = run_maintenance_batch(factory)
    assert (result.connections_expired, result.preparations_expired) == (1, 0)
    monkeypatch.setattr(preparation_cleanup, "now", lambda: now() + timedelta(seconds=301))
    result = run_maintenance_batch(factory)
    assert (result.connections_expired, result.preparations_expired) == (0, 1)


def test_batch_failure_rolls_back_connection_and_parent_changes(
    client, prepared, factory, monkeypatch
):
    from simontalk_api import practice_maintenance

    saved = reserve(client, prepared).json()
    with factory.begin() as db:
        db.execute(
            text("UPDATE realtime_connections SET lease_expires_at=:past WHERE id=:id"),
            {"past": now() - timedelta(seconds=1), "id": saved["id"]},
        )

    def fail(*args, **kwargs):
        raise RuntimeError("failure after connection changes")

    monkeypatch.setattr(practice_maintenance, "expire_idle_preparations", fail)
    with pytest.raises(RuntimeError):
        practice_maintenance.run_maintenance_batch(factory)
    assert (
        client.get(path(prepared, saved), headers=prepared.headers).json()["status"] == "preparing"
    )


def test_batch_timeout_settings_are_transaction_local(factory, monkeypatch):
    from simontalk_api import practice_maintenance

    def inspect(db, *, limit):
        assert limit == 7
        assert db.scalar(text("SHOW transaction_timeout")) == "5s"
        assert db.scalar(text("SHOW statement_timeout")) == "2s"
        assert db.scalar(text("SHOW lock_timeout")) == "100ms"
        return 0

    with factory() as db:
        previous = db.scalar(text("SHOW transaction_timeout"))
    monkeypatch.setattr(practice_maintenance, "expire_connection_leases", inspect)
    monkeypatch.setattr(practice_maintenance, "expire_idle_preparations", lambda db, *, limit: 0)
    practice_maintenance.run_maintenance_batch(factory, limit=7)
    with factory() as db:
        assert db.scalar(text("SHOW transaction_timeout")) == previous


def test_runner_commits_real_cleanup_and_stops_without_more_batches(
    client, prepared, factory, monkeypatch
):
    from simontalk_api import practice_maintenance

    age(factory, prepared, now() - timedelta(hours=1))
    completed = Event()
    original = practice_maintenance.run_maintenance_batch
    results = []

    def observe(factory, *, limit):
        result = original(factory, limit=limit)
        results.append(result)
        completed.set()
        return result

    monkeypatch.setattr(practice_maintenance, "run_maintenance_batch", observe)
    runner = practice_maintenance.PracticeMaintenanceRunner(TEST_URL, interval_seconds=0.01)
    runner.start()
    try:
        assert completed.wait(3)
    finally:
        runner.stop()
    assert not runner.running
    assert sum(r.preparations_expired for r in results) == 1
    count = len(results)
    completed.clear()
    assert not completed.wait(0.03)
    assert len(results) == count
    assert (
        client.get("/v1/practice-sessions/current", headers=prepared.headers).json()["practice"]
        is None
    )


def test_runner_retries_failure_without_logging_exception_secrets(database, monkeypatch, caplog):
    from simontalk_api import practice_maintenance

    completed = Event()
    calls = []

    def flaky(*args, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("private-credential-never-log")
        completed.set()
        return practice_maintenance.MaintenanceResult(0, 0)

    monkeypatch.setattr(practice_maintenance, "run_maintenance_batch", flaky)
    runner = practice_maintenance.PracticeMaintenanceRunner(TEST_URL, interval_seconds=0.01)
    runner.start()
    try:
        assert completed.wait(3)
    finally:
        runner.stop()
    assert len(calls) >= 2
    assert "Practice maintenance batch failed" in caplog.text
    assert "private-credential-never-log" not in caplog.text


def test_runner_stop_interrupts_wait_and_cannot_be_started_twice(database):
    from simontalk_api.practice_maintenance import PracticeMaintenanceRunner

    runner = PracticeMaintenanceRunner(TEST_URL, interval_seconds=300)
    runner.start()
    try:
        with pytest.raises(RuntimeError):
            runner.start()
    finally:
        before = monotonic()
        runner.stop()
    assert monotonic() - before < 1
    runner.stop()
    with pytest.raises(RuntimeError):
        runner.start()


def test_application_lifespan_automatically_cleans_and_joins_runner(
    client, app, prepared, factory, monkeypatch
):
    from simontalk_api import practice_maintenance

    age(factory, prepared, now() - timedelta(hours=1))
    committed = Event()
    original = practice_maintenance.run_maintenance_batch

    def observe(factory, *, limit):
        result = original(factory, limit=limit)
        if result.preparations_expired:
            committed.set()
        return result

    monkeypatch.setattr(practice_maintenance, "run_maintenance_batch", observe)
    settings = Settings(
        database_url=TEST_URL, environment="test", practice_maintenance_interval_seconds=1
    )
    other = create_app(settings)
    try:
        with TestClient(other) as restored:
            assert other.state.practice_maintenance.running
            assert committed.wait(4)
            assert (
                restored.get("/v1/practice-sessions/current", headers=prepared.headers).json()[
                    "practice"
                ]
                is None
            )
        assert not other.state.practice_maintenance.running
    finally:
        other.state.engine.dispose()


@pytest.mark.parametrize("interval", [0, -1, 301, float("inf"), float("nan")])
def test_maintenance_interval_configuration_is_bounded(interval):
    with pytest.raises(ValueError):
        Settings(practice_maintenance_interval_seconds=interval)


def test_default_interval_is_fifteen_seconds():
    assert Settings().practice_maintenance_interval_seconds == 15


def test_cleanup_cli_commits_counts_and_repeating_is_safe(client, prepared, factory):
    age(factory, prepared, now() - timedelta(hours=1))
    command = [
        sys.executable,
        "-c",
        "from simontalk_api.cli import main; main()",
        "cleanup-preparations",
        "--limit",
        "1",
    ]
    env = {**os.environ, "SIMONTALK_DATABASE_URL": TEST_URL}
    first = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
    assert first.returncode == 0, first.stderr
    assert first.stdout.strip() == "Expired connection leases: 0; expired preparations: 1."
    second = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
    assert second.returncode == 0
    assert second.stdout.strip() == "Expired connection leases: 0; expired preparations: 0."
