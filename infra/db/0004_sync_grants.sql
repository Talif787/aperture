-- 0004: application privileges on the sync tables.
--
-- Separate from the table definitions because the application role must not exist in the
-- same file that creates the objects it is deliberately restricted from.

BEGIN;

GRANT SELECT, INSERT, UPDATE ON sync_entities TO aperture_app;

-- No UPDATE and no DELETE on the change log. It is append-only, and that is a database
-- permission rather than a promise in a code review: a client's view of history cannot be
-- rewritten under it by any code path, including a buggy one.
GRANT SELECT, INSERT ON sync_changes TO aperture_app;
REVOKE UPDATE, DELETE ON sync_changes FROM aperture_app;
GRANT USAGE, SELECT ON SEQUENCE sync_changes_seq_seq TO aperture_app;

-- Idempotency records are written once and read many times. DELETE is granted for the
-- expiry sweep, which is the only thing that removes them.
GRANT SELECT, INSERT, DELETE ON sync_idempotency TO aperture_app;
REVOKE UPDATE ON sync_idempotency FROM aperture_app;

-- Entities are deleted softly, never removed, so the application needs no DELETE.
REVOKE DELETE ON sync_entities FROM aperture_app;

COMMIT;
