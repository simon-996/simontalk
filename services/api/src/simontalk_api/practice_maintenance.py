import logging
import math
from dataclasses import dataclass
from threading import Event, Lock, Thread

from sqlalchemy import text

from simontalk_api.connections import expire_connection_leases
from simontalk_api.db import create_database
from simontalk_api.preparation_cleanup import expire_idle_preparations

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class MaintenanceResult:
    connections_expired: int
    preparations_expired: int


def run_maintenance_batch(factory, *, limit=100):
    if type(limit) is not int or not 1 <= limit <= 1000:
        raise ValueError("Invalid scan limit")
    with factory.begin() as db:
        # PostgreSQL 17: bound the entire transaction as well as individual SQL.
        # LOCAL settings do not escape into another pooled request/transaction.
        db.execute(text("SET LOCAL transaction_timeout = '5s'"))
        db.execute(text("SET LOCAL statement_timeout = '2s'"))
        db.execute(text("SET LOCAL lock_timeout = '100ms'"))
        connections = expire_connection_leases(db, limit=limit)
        preparations = expire_idle_preparations(db, limit=limit)
    return MaintenanceResult(connections, preparations)


class PracticeMaintenanceRunner:
    """One serial loop per API process; database locks coordinate multiple processes."""

    def __init__(self, database_url, *, interval_seconds=15, limit=100):
        if (
            type(interval_seconds) not in {int, float}
            or not math.isfinite(interval_seconds)
            or not 0.01 <= interval_seconds <= 300
        ):
            raise ValueError("Invalid maintenance interval")
        if type(limit) is not int or not 1 <= limit <= 1000:
            raise ValueError("Invalid scan limit")
        # A private pool prevents request pool saturation from delaying shutdown.
        self._engine, self._factory = create_database(database_url)
        self._interval = interval_seconds
        self._limit = limit
        self._stop = Event()
        self._guard = Lock()
        self._thread = None

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        with self._guard:
            if self._thread is not None or self._stop.is_set():
                raise RuntimeError("Maintenance runner already started or closed")
            self._thread = Thread(
                target=self._run, name="simontalk-practice-maintenance", daemon=True
            )
            self._thread.start()

    def stop(self):
        with self._guard:
            self._stop.set()
            thread = self._thread
            if thread is None:
                self._engine.dispose()
                return
        thread.join(timeout=10)
        if thread.is_alive():
            raise RuntimeError("Practice maintenance did not stop within its deadline")

    def _run(self):
        try:
            # Wait before the first batch too; startup never synchronously scans data.
            while not self._stop.wait(self._interval):
                try:
                    result = run_maintenance_batch(self._factory, limit=self._limit)
                    if result.connections_expired or result.preparations_expired:
                        logger.info(
                            "Practice maintenance committed connections=%d preparations=%d",
                            result.connections_expired,
                            result.preparations_expired,
                        )
                except Exception:
                    # Driver exception strings may contain connection or input details.
                    logger.warning("Practice maintenance batch failed")
        finally:
            self._engine.dispose()
