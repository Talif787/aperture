-- 0003: the entities, change log, and idempotency records the sync protocol needs.
--
-- Three tables, each with row-level security, because every one of them can leak across a
-- tenant boundary and each leaks differently: entities expose content, the change log
-- exposes activity and timing even without content, and the idempotency table exposes
-- another tenant's stored response to whoever guesses a key.

BEGIN;

-- The authoritative record for one syncable entity.
CREATE TABLE sync_entities (
    tenant_id    uuid NOT NULL REFERENCES tenants(id),
    entity_type  text NOT NULL,
    entity_id    text NOT NULL,
    version      bigint NOT NULL CHECK (version > 0),
    hlc          text NOT NULL,

    -- Field values and, separately, the version that last touched each field.
    --
    -- The second map is what makes per-field conflict detection possible. Without it the
    -- server can only compare entity versions, so any concurrent edit becomes a
    -- whole-entity conflict that clobbers a reviewer's change to a field the inspector
    -- never touched.
    fields         jsonb NOT NULL DEFAULT '{}'::jsonb,
    field_versions jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Soft delete. A deletion must reach replicas that are currently in a crawl space
    -- with no signal, and a removed row propagates nothing.
    deleted_at   timestamptz,
    updated_at   timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (tenant_id, entity_type, entity_id)
);

-- Tenant leads the key and every index. It enforces the access pattern, keeps per-tenant
-- scans physically local, and makes eventual hash partitioning by tenant a change of
-- storage rather than a change of every query.
CREATE INDEX idx_sync_entities_updated ON sync_entities (tenant_id, updated_at);

-- The append-only change log devices page through.
--
-- A single global sequence rather than a per-tenant counter. Postgres gives monotonicity
-- for free with bigserial, and filtering by tenant costs one index lookup; maintaining a
-- counter per tenant would mean a write-time contention point for no read-time benefit.
CREATE TABLE sync_changes (
    seq            bigserial PRIMARY KEY,
    tenant_id      uuid NOT NULL REFERENCES tenants(id),
    entity_type    text NOT NULL,
    entity_id      text NOT NULL,
    server_version bigint NOT NULL,
    hlc            text NOT NULL,
    changed_fields text[] NOT NULL DEFAULT '{}',
    is_deletion    boolean NOT NULL DEFAULT false,
    occurred_at    timestamptz NOT NULL DEFAULT now()
);

-- The cursor query: everything for one tenant after a sequence, in order.
CREATE INDEX idx_sync_changes_cursor ON sync_changes (tenant_id, seq);

-- Stored responses, keyed by the operation identifier the device minted.
--
-- Scoped to the tenant in the primary key, not merely filtered. A globally keyed table
-- would let one tenant's operation identifier collide with another's, and the second
-- caller would receive the first caller's response: a correctness failure and a
-- cross-tenant disclosure in one.
CREATE TABLE sync_idempotency (
    tenant_id    uuid NOT NULL REFERENCES tenants(id),
    operation_id text NOT NULL,
    status       text NOT NULL CHECK (status IN ('applied', 'replayed', 'conflict', 'rejected')),
    response     jsonb NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),

    -- Retention is bounded. A device retries for at most twenty-four hours under the
    -- backoff schedule, so a week is generous, and keeping these forever turns a hot table
    -- into a permanent one.
    expires_at   timestamptz NOT NULL DEFAULT now() + interval '7 days',

    PRIMARY KEY (tenant_id, operation_id)
);

CREATE INDEX idx_sync_idempotency_expiry ON sync_idempotency (expires_at);

-- Row-level security on all three.
ALTER TABLE sync_entities    ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_changes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_idempotency ENABLE ROW LEVEL SECURITY;

ALTER TABLE sync_entities    FORCE ROW LEVEL SECURITY;
ALTER TABLE sync_changes     FORCE ROW LEVEL SECURITY;
ALTER TABLE sync_idempotency FORCE ROW LEVEL SECURITY;

-- current_setting with missing_ok = true returns NULL rather than raising when the session
-- was never scoped. NULL never equals a tenant id, so an unscoped session sees nothing.
-- Failing closed is the only acceptable default: a policy that fails open is worse than no
-- policy, because it looks like protection.
CREATE POLICY tenant_isolation ON sync_entities
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE POLICY tenant_isolation ON sync_changes
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE POLICY tenant_isolation ON sync_idempotency
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

COMMIT;
