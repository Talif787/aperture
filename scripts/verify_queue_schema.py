#!/usr/bin/env python3
"""Execute the sync queue DDL against a real SQLite engine and assert its behavior.

The schema lives in Swift as a string constant, which means nothing verifies it until the
app runs on a device. This script extracts it and runs it, so a malformed CHECK
constraint, a missing index, or a typo in a column name fails the pull request instead of
failing on an inspector's phone.

Checks performed:
  * every statement executes
  * STRICT typing rejects a wrong-typed value
  * the state and operation CHECK constraints reject invalid values
  * the dispatch query uses the ready index rather than scanning
  * the orphan query finds operations abandoned by a terminated process

Requires only the Python standard library.
"""

from __future__ import annotations

import re
import sqlite3
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_SOURCE = (
    REPO_ROOT
    / "ios/Packages/AperturePlatform/Sources/ApertureData/SyncQueueSchema.swift"
)

TRIPLE_QUOTED = re.compile(r'"""\s*\n(.*?)\n\s*"""', re.DOTALL)

failures: list[str] = []


def check(condition: bool, description: str) -> None:
    if condition:
        print(f"  ok    {description}")
    else:
        print(f"  FAIL  {description}")
        failures.append(description)


def extract_statements(text: str) -> tuple[list[str], str, str]:
    blocks = [block.strip() for block in TRIPLE_QUOTED.findall(text)]
    creates = [b for b in blocks if b.upper().startswith("CREATE")]
    selects = [b for b in blocks if b.upper().startswith("SELECT")]
    dispatch = next((s for s in selects if "state = 'pending'" in s), "")
    orphan = next((s for s in selects if "inFlight" in s), "")
    return creates, dispatch, orphan


def main() -> int:
    if not SCHEMA_SOURCE.is_file():
        print(f"error: schema source not found at {SCHEMA_SOURCE}", file=sys.stderr)
        return 1

    text = SCHEMA_SOURCE.read_text(encoding="utf-8")
    creates, dispatch, orphan = extract_statements(text)

    print(f"Verifying sync queue schema ({len(creates)} DDL statements)")

    connection = sqlite3.connect(":memory:")
    connection.execute("PRAGMA foreign_keys = ON")

    for statement in creates:
        connection.execute(statement)
    check(len(creates) >= 3, "all DDL statements executed")

    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    check("sync_op" in tables, "sync_op table exists")
    check("schema_metadata" in tables, "schema_metadata table exists")

    indexes = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='index'")}
    check("idx_sync_op_ready" in indexes, "dispatch index exists")
    check("idx_sync_op_entity" in indexes, "per-entity index exists")

    def insert(op_id: str, state: str = "pending", op: str = "update", attempts: int = 0, next_at=None):
        connection.execute(
            "INSERT INTO sync_op (op_id, entity_type, entity_id, op, payload, before_state,"
            " dirty_fields, base_version, hlc, state, attempt_count, next_attempt_at,"
            " last_error_code, created_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (op_id, "finding", "01J8ZQ", op, b"{}", b"{}", '["note"]', 3,
             "2026-09-14T09:41:22.905Z-0042-devA", state, attempts, next_at, None, 1_789_000_000),
        )

    insert("op-1")
    insert("op-2", state="inFlight")
    insert("op-3", state="pending", next_at=1_789_000_500)
    connection.commit()
    check(True, "representative rows insert cleanly")

    try:
        insert("op-bad-state", state="zombie")
        check(False, "CHECK rejects an invalid state")
    except sqlite3.IntegrityError:
        check(True, "CHECK rejects an invalid state")

    try:
        insert("op-bad-kind", op="teleport")
        check(False, "CHECK rejects an unknown operation kind")
    except sqlite3.IntegrityError:
        check(True, "CHECK rejects an unknown operation kind")

    try:
        insert("op-negative", attempts=-1)
        check(False, "CHECK rejects a negative attempt count")
    except sqlite3.IntegrityError:
        check(True, "CHECK rejects a negative attempt count")

    try:
        connection.execute(
            "INSERT INTO sync_op (op_id, entity_type, entity_id, op, payload, dirty_fields,"
            " base_version, hlc, state, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            ("op-wrong-type", "finding", "01J8ZQ", "update", b"{}", "[]",
             "not-an-integer", "hlc", "pending", 1),
        )
        check(False, "STRICT typing rejects a text value in an INTEGER column")
    except sqlite3.IntegrityError:
        check(True, "STRICT typing rejects a text value in an INTEGER column")

    if dispatch:
        rows = connection.execute(dispatch, (1_789_000_100, 10)).fetchall()
        ids = {row[0] for row in rows}
        check(ids == {"op-1"}, "dispatch query respects state and the backoff schedule")

        plan = " ".join(str(row) for row in connection.execute("EXPLAIN QUERY PLAN " + dispatch, (0, 1)))
        check("idx_sync_op_ready" in plan, "dispatch query uses the ready index rather than scanning")
    else:
        check(False, "dispatch query found in source")

    if orphan:
        rows = connection.execute(orphan).fetchall()
        check({row[0] for row in rows} == {"op-2"}, "orphan query finds operations abandoned in flight")
    else:
        check(False, "orphan query found in source")

    connection.close()

    print()
    if failures:
        print(f"{len(failures)} schema check(s) failed.")
        return 1
    print("Sync queue schema verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
