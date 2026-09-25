"""
logger.py — Log de auditoria em SQLite.

TODA ação avaliada pelo guardrail é registrada aqui: aprovada, bloqueada,
sensível ou executada. O banco é a fonte de verdade para auditoria.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from datetime import datetime, timezone

_SCHEMA = """
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,              -- ISO 8601 UTC
    action_type TEXT NOT NULL,
    params TEXT,                   -- JSON da ação (snapshot)
    allowed INTEGER NOT NULL,      -- 1 permitida / 0 bloqueada
    executed INTEGER NOT NULL,     -- 1 executada de fato / 0 não
    reason TEXT,
    dry_run INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ts ON audit_log(ts);
"""


class AuditLogger:
    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.executescript(_SCHEMA)
        self._conn.commit()

    def log(self, action_type: str, params: dict, allowed: bool,
            executed: bool, reason: str, dry_run: bool) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO audit_log (ts, action_type, params, allowed, "
                "executed, reason, dry_run) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    datetime.now(timezone.utc).isoformat(),
                    action_type,
                    json.dumps(params, ensure_ascii=False, default=str),
                    int(allowed), int(executed), reason, int(dry_run),
                ),
            )
            self._conn.commit()

    def recent(self, limit: int = 50) -> list[dict]:
        """Últimos eventos, para o dashboard."""
        with self._lock:
            cur = self._conn.execute(
                "SELECT ts, action_type, allowed, executed, reason, dry_run "
                "FROM audit_log ORDER BY id DESC LIMIT ?", (limit,))
            return [
                {"ts": r[0], "action_type": r[1], "allowed": bool(r[2]),
                 "executed": bool(r[3]), "reason": r[4], "dry_run": bool(r[5])}
                for r in cur.fetchall()
            ]

    def stats(self) -> dict:
        with self._lock:
            cur = self._conn.execute(
                "SELECT COUNT(*), SUM(allowed), SUM(executed) FROM audit_log")
            total, allowed, executed = cur.fetchone()
        return {
            "total": total or 0,
            "allowed": allowed or 0,
            "blocked": (total or 0) - (allowed or 0),
            "executed": executed or 0,
        }

    def close(self) -> None:
        self._conn.close()
