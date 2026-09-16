import Foundation

/// The schema for the durable sync operation queue.
///
/// The queue lives in plain SQLite rather than in the SwiftData object graph. That is a
/// deliberate split: the queue needs strict insertion order, cheap appends, and a
/// transactional pop, which a relational table gives directly and an object graph gives
/// awkwardly. The structured entity store stays in SwiftData, where the graph semantics
/// are worth having.
///
/// Two columns carry more weight than their size suggests.
///
/// `before_state` holds the prior value of every field the operation changed. It is what
/// lets an optimistic update be rolled back after the process has been terminated and
/// relaunched, which an in-memory undo stack cannot survive. It costs storage on every
/// update, and that cost is accepted knowingly.
///
/// `state` includes `inFlight`, which is what makes a termination mid-request safe: those
/// operations are re-driven on the next launch with their original idempotency key.
///
/// This DDL is verified by `scripts/verify_queue_schema.py`, which executes it against a
/// real SQLite engine in CI and asserts the constraints and index plans.
public enum SyncQueueSchema {
    public static let version = 1

    public static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_op (
          op_id           TEXT PRIMARY KEY,
          entity_type     TEXT NOT NULL,
          entity_id       TEXT NOT NULL,
          op              TEXT NOT NULL CHECK (op IN
                            ('create','update','delete','attach_media','submit','resolve_conflict')),
          payload         BLOB NOT NULL,
          before_state    BLOB,
          dirty_fields    TEXT NOT NULL,
          base_version    INTEGER NOT NULL,
          hlc             TEXT NOT NULL,
          state           TEXT NOT NULL CHECK (state IN ('pending','inFlight','failed','dead')),
          attempt_count   INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
          next_attempt_at INTEGER,
          last_error_code TEXT,
          created_at      INTEGER NOT NULL
        ) STRICT
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_sync_op_ready
          ON sync_op(state, next_attempt_at)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_sync_op_entity
          ON sync_op(entity_type, entity_id, created_at)
        """,
        """
        CREATE TABLE IF NOT EXISTS schema_metadata (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        ) STRICT
        """
    ]

    /// Operations ready to dispatch, oldest first, respecting the backoff schedule.
    /// Ordering is per entity rather than globally in the engine itself; this query is the
    /// candidate set the engine then groups.
    public static let selectDispatchable = """
        SELECT op_id, entity_type, entity_id, op, payload, dirty_fields,
               base_version, hlc, attempt_count
          FROM sync_op
         WHERE state = 'pending'
           AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
         ORDER BY created_at ASC
         LIMIT ?
        """

    /// Operations left in flight by a process that did not survive its own request.
    /// Re-driven with their original identifiers, which are also their idempotency keys.
    public static let selectOrphanedInFlight = """
        SELECT op_id FROM sync_op WHERE state = 'inFlight'
        """
}
