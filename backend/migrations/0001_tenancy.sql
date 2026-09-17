-- 0001: tenants, users, devices, and the row-level security that isolates them.
--
-- Expand-contract from the start: every migration is backward compatible with the service
-- version deployed before it, so a rollback never meets a schema it cannot read.
--
-- The policies below are the real tenant boundary. Application-level filtering is defence
-- in depth, but a query that forgets its WHERE clause returns nothing here rather than
-- returning another carrier's inspections.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE tenants (
    id                  uuid PRIMARY KEY,
    name                text NOT NULL,
    retention_years     integer NOT NULL DEFAULT 7 CHECK (retention_years BETWEEN 1 AND 25),
    media_upload_policy text NOT NULL DEFAULT 'none'
                        CHECK (media_upload_policy IN ('none', 'required_only', 'all')),
    redact_on_upload    boolean NOT NULL DEFAULT true,
    training_consent    boolean NOT NULL DEFAULT false,
    oidc_issuer         text NOT NULL,
    oidc_client_id      text NOT NULL,
    email_domain        citext NOT NULL UNIQUE,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
    id                uuid PRIMARY KEY,
    tenant_id         uuid NOT NULL REFERENCES tenants(id),
    external_subject  text NOT NULL,
    email             citext NOT NULL,
    roles             text[] NOT NULL DEFAULT '{}',
    status            text NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'suspended', 'offboarded')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- Scoped to the tenant, not global. Two carriers can legitimately employ the same
    -- contract adjuster, and a global unique constraint would make the second onboarding
    -- fail for reasons nobody could explain.
    UNIQUE (tenant_id, external_subject),
    UNIQUE (tenant_id, email)
);

CREATE TABLE devices (
    id                uuid PRIMARY KEY,
    tenant_id         uuid NOT NULL REFERENCES tenants(id),
    user_id           uuid NOT NULL REFERENCES users(id),
    platform          text NOT NULL CHECK (platform IN ('ios', 'android')),
    model             text NOT NULL,
    os_version        text NOT NULL,
    app_version       text NOT NULL,
    capability_tier   char(1) NOT NULL CHECK (capability_tier IN ('A', 'B', 'C')),
    push_token        text,
    attestation_state text NOT NULL DEFAULT 'unsupported'
                      CHECK (attestation_state IN ('verified', 'failed', 'unsupported')),
    sync_cursor       text,
    last_seen_at      timestamptz NOT NULL DEFAULT now(),
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- Tenant leads every composite index. It enforces the access pattern and keeps per-tenant
-- scans physically local, which makes the eventual hash partitioning by tenant a change of
-- storage rather than a change of every query.
CREATE INDEX idx_users_tenant        ON users (tenant_id, status);
CREATE INDEX idx_devices_tenant_user ON devices (tenant_id, user_id);
CREATE INDEX idx_devices_last_seen   ON devices (last_seen_at);
CREATE INDEX idx_devices_push_token  ON devices (tenant_id) WHERE push_token IS NOT NULL;

-- Refresh token families, for rotation with reuse detection.
--
-- Only a hash is stored. A stolen database dump then yields no usable credential, and the
-- server never needs the original: verification is a hash comparison.
CREATE TABLE refresh_token_families (
    id             uuid PRIMARY KEY,
    tenant_id      uuid NOT NULL REFERENCES tenants(id),
    user_id        uuid NOT NULL REFERENCES users(id),
    device_id      uuid NOT NULL REFERENCES devices(id),
    token_hash     bytea NOT NULL,
    generation     integer NOT NULL DEFAULT 0,
    revoked_at     timestamptz,
    revoked_reason text CHECK (revoked_reason IN ('rotated', 'reuse_detected', 'signed_out', 'admin')),
    expires_at     timestamptz NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_refresh_token_hash ON refresh_token_families (token_hash);
CREATE INDEX idx_refresh_family_user ON refresh_token_families (tenant_id, user_id)
    WHERE revoked_at IS NULL;

-- Append-only audit. The application role holds no UPDATE or DELETE grant, so immutability
-- is a database permission rather than a promise in a code review.
CREATE TABLE audit_log (
    id              bigserial PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES tenants(id),
    actor_user_id   uuid,
    actor_device_id uuid,
    entity_type     text NOT NULL,
    entity_id       uuid,
    action          text NOT NULL,
    before          jsonb,
    after           jsonb,
    occurred_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_tenant_entity ON audit_log (tenant_id, entity_type, entity_id);
CREATE INDEX idx_audit_occurred      ON audit_log (occurred_at);

-- Row-level security.
--
-- The application role must not hold BYPASSRLS. Migrations run under a separate role that
-- does, which is why this file can create policies it is itself exempt from.
ALTER TABLE users                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices                ENABLE ROW LEVEL SECURITY;
ALTER TABLE refresh_token_families ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log              ENABLE ROW LEVEL SECURITY;

ALTER TABLE users                  FORCE ROW LEVEL SECURITY;
ALTER TABLE devices                FORCE ROW LEVEL SECURITY;
ALTER TABLE refresh_token_families FORCE ROW LEVEL SECURITY;
ALTER TABLE audit_log              FORCE ROW LEVEL SECURITY;

-- current_setting with missing_ok = true returns NULL rather than raising when the session
-- was never scoped. NULL never equals a tenant id, so an unscoped session sees no rows at
-- all. Failing closed is the only acceptable default here.
CREATE POLICY tenant_isolation ON users
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE POLICY tenant_isolation ON devices
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE POLICY tenant_isolation ON refresh_token_families
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

-- Audit rows are readable within the tenant and insertable, never updatable or deletable.
CREATE POLICY tenant_isolation_read ON audit_log FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

CREATE POLICY tenant_isolation_insert ON audit_log FOR INSERT
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid);

COMMIT;
