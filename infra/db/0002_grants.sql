-- 0002: the application role, and the grants that make row-level security meaningful.
--
-- This file exists because of a detail that silently defeats RLS in development and then
-- surprises people in production: PostgreSQL superusers bypass row security entirely,
-- regardless of FORCE ROW LEVEL SECURITY. A local stack whose application connects as the
-- bootstrap superuser will appear to isolate tenants while actually isolating nothing,
-- and every policy in 0001 will be dead code that nobody notices until an audit.
--
-- The application therefore connects as aperture_app, which is NOSUPERUSER and NOBYPASSRLS.
-- Migrations run as the bootstrap role, which is why this file can grant privileges it is
-- itself exempt from.

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aperture_app') THEN
        CREATE ROLE aperture_app
            LOGIN
            PASSWORD 'local-development-only'
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOBYPASSRLS;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE aperture TO aperture_app;
GRANT USAGE ON SCHEMA public TO aperture_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON tenants, users, devices, refresh_token_families
    TO aperture_app;

-- The audit log is append-only, and that is enforced as a database permission rather than
-- as a promise in a code review. No UPDATE, no DELETE, for anyone the application can be.
GRANT SELECT, INSERT ON audit_log TO aperture_app;
REVOKE UPDATE, DELETE ON audit_log FROM aperture_app;
GRANT USAGE, SELECT ON SEQUENCE audit_log_id_seq TO aperture_app;

-- Tenants is the one table not under a tenant policy: a caller must be able to resolve
-- their own tenant before a scope exists. Read-only for the application, and it holds no
-- inspection data.
REVOKE INSERT, UPDATE, DELETE ON tenants FROM aperture_app;

COMMIT;
