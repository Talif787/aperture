-- Development seed data.
--
-- Fixed identifiers, so every command in the runbook can reference them literally and a
-- reset produces the same database. Two tenants, because a single-tenant fixture cannot
-- demonstrate the property that matters most: that one carrier cannot see another's data.
--
-- Run as the bootstrap role. The application role cannot insert here, and that is correct:
-- provisioning is an administrative action, not something the mobile client does.

BEGIN;

-- Tenant A: a property insurance carrier.
INSERT INTO tenants (id, name, retention_years, media_upload_policy, redact_on_upload,
                     training_consent, oidc_issuer, oidc_client_id, email_domain)
VALUES (
    '11111111-1111-4111-a111-111111111111',
    'Northwind Mutual',
    7,
    'required_only',
    true,
    false,
    'https://northwind.okta.example/oauth2/default',
    '0oaNORTHWIND01',
    'northwind-mutual.example'
) ON CONFLICT (id) DO NOTHING;

-- Tenant B: a utility. Different retention and a stricter media policy, so the fixtures
-- also exercise per-tenant configuration rather than only per-tenant rows.
INSERT INTO tenants (id, name, retention_years, media_upload_policy, redact_on_upload,
                     training_consent, oidc_issuer, oidc_client_id, email_domain)
VALUES (
    '22222222-2222-4222-a222-222222222222',
    'Pacific Grid Utilities',
    15,
    'none',
    true,
    true,
    'https://pacificgrid.entra.example/v2.0',
    '0oaPACIFICGRID1',
    'pacific-grid.example'
) ON CONFLICT (id) DO NOTHING;

-- Users. Roles mirror the three the authorization model defines.
INSERT INTO users (id, tenant_id, external_subject, email, roles, status) VALUES
    ('a1111111-1111-4111-a111-111111111111', '11111111-1111-4111-a111-111111111111',
     '00uDANA0001', 'dana.reyes@northwind-mutual.example', '{inspector}', 'active'),
    ('a2222222-2222-4222-a222-222222222222', '11111111-1111-4111-a111-111111111111',
     '00uPRIYA001', 'priya.shah@northwind-mutual.example', '{reviewer,admin}', 'active'),
    ('b1111111-1111-4111-a111-111111111111', '22222222-2222-4222-a222-222222222222',
     '00uMARCUS01', 'marcus.obi@pacific-grid.example', '{inspector}', 'active'),
    ('b2222222-2222-4222-a222-222222222222', '22222222-2222-4222-a222-222222222222',
     '00uSAM00001', 'sam.whitfield@pacific-grid.example', '{inspector}', 'suspended')
ON CONFLICT (id) DO NOTHING;

-- Devices, one per capability tier so the tier logic has fixtures to exercise.
INSERT INTO devices (id, tenant_id, user_id, platform, model, os_version, app_version,
                     capability_tier, push_token, attestation_state) VALUES
    ('d1111111-1111-4111-a111-111111111111', '11111111-1111-4111-a111-111111111111',
     'a1111111-1111-4111-a111-111111111111', 'ios', 'iPhone15,3', '27.0', '0.1.0',
     'A', 'apns-token-dana-pro', 'verified'),
    ('d2222222-2222-4222-a222-222222222222', '22222222-2222-4222-a222-222222222222',
     'b1111111-1111-4111-a111-111111111111', 'ios', 'iPhone12,1', '26.0', '0.1.0',
     'C', 'apns-token-marcus-11', 'verified'),
    ('d3333333-3333-4333-a333-333333333333', '22222222-2222-4222-a222-222222222222',
     'b2222222-2222-4222-a222-222222222222', 'ios', 'iPhone14,7', '27.0', '0.1.0',
     'B', NULL, 'failed')
ON CONFLICT (id) DO NOTHING;

-- Refresh token families. Only hashes are stored, so a stolen dump yields no usable
-- credential. These are SHA-256 digests of the literal strings named in the comments,
-- which is what lets the runbook demonstrate rotation without inventing a token format.
INSERT INTO refresh_token_families (id, tenant_id, user_id, device_id, token_hash,
                                    generation, expires_at) VALUES
    -- digest of 'dev-refresh-token-dana-gen0'
    ('f1111111-1111-4111-a111-111111111111', '11111111-1111-4111-a111-111111111111',
     'a1111111-1111-4111-a111-111111111111', 'd1111111-1111-4111-a111-111111111111',
     sha256('dev-refresh-token-dana-gen0'::bytea), 0, now() + interval '30 days'),
    -- digest of 'dev-refresh-token-marcus-gen0'
    ('f2222222-2222-4222-a222-222222222222', '22222222-2222-4222-a222-222222222222',
     'b1111111-1111-4111-a111-111111111111', 'd2222222-2222-4222-a222-222222222222',
     sha256('dev-refresh-token-marcus-gen0'::bytea), 0, now() + interval '30 days')
ON CONFLICT (id) DO NOTHING;

-- Audit rows, one per tenant, so the append-only checks have something to read.
-- Guarded by NOT EXISTS rather than ON CONFLICT, because the identifier is a sequence
-- and there is no natural key to conflict on. Without the guard, re-seeding would append
-- duplicate rows every time, and a fixture count that drifts makes every assertion that
-- depends on it unreliable.
INSERT INTO audit_log (tenant_id, actor_user_id, actor_device_id, entity_type, entity_id,
                       action, before, after)
SELECT '11111111-1111-4111-a111-111111111111', 'a1111111-1111-4111-a111-111111111111',
       'd1111111-1111-4111-a111-111111111111', 'device', 'd1111111-1111-4111-a111-111111111111',
       'registered', NULL, '{"capability_tier":"A"}'::jsonb
WHERE NOT EXISTS (
    SELECT 1 FROM audit_log
    WHERE entity_id = 'd1111111-1111-4111-a111-111111111111' AND action = 'registered'
);

INSERT INTO audit_log (tenant_id, actor_user_id, actor_device_id, entity_type, entity_id,
                       action, before, after)
SELECT '22222222-2222-4222-a222-222222222222', 'b1111111-1111-4111-a111-111111111111',
       'd2222222-2222-4222-a222-222222222222', 'device', 'd2222222-2222-4222-a222-222222222222',
       'registered', NULL, '{"capability_tier":"C"}'::jsonb
WHERE NOT EXISTS (
    SELECT 1 FROM audit_log
    WHERE entity_id = 'd2222222-2222-4222-a222-222222222222' AND action = 'registered'
);

COMMIT;
