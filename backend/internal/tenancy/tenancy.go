// Package tenancy owns tenant scoping.
//
// This package exists to make tenant isolation structural rather than a rule engineers
// must remember. Cross-tenant exposure is the highest-severity failure this system can
// produce: one insurance carrier seeing another's inspections is a contract termination
// and a notifiable breach, not a bug report.
//
// The mechanism is deliberately narrow. This is the only package permitted to open a
// database session, and it always sets the row-level-security context before handing one
// back. No repository can obtain a connection any other way, so "did you remember to
// filter by tenant" stops being a question a reviewer has to ask.
//
// A CI check asserts that the database driver is imported by exactly this package. A
// boundary that is not enforced mechanically erodes within a quarter.
package tenancy

import (
	"context"
	"errors"
	"fmt"
)

// Errors callers distinguish.
var (
	ErrNoTenantInContext = errors.New("tenancy: no tenant in context")
	ErrTenantMismatch    = errors.New("tenancy: resource belongs to a different tenant")
)

type contextKey string

const (
	tenantKey contextKey = "tenant_id"
	actorKey  contextKey = "actor_id"
	rolesKey  contextKey = "actor_roles"
)

// Principal is the authenticated caller, derived from a verified token and nothing else.
type Principal struct {
	TenantID string
	UserID   string
	Roles    []string
}

// HasRole reports whether the principal holds a role.
func (p Principal) HasRole(role string) bool {
	for _, held := range p.Roles {
		if held == role {
			return true
		}
	}
	return false
}

// WithPrincipal attaches the caller to a context.
//
// Called once, by the authentication middleware, from claims on a verified token. Nothing
// downstream may construct one, which is what keeps a forged header from ever becoming a
// tenant scope.
func WithPrincipal(ctx context.Context, principal Principal) context.Context {
	ctx = context.WithValue(ctx, tenantKey, principal.TenantID)
	ctx = context.WithValue(ctx, actorKey, principal.UserID)
	return context.WithValue(ctx, rolesKey, principal.Roles)
}

// PrincipalFrom returns the caller, or an error when the context was never scoped.
//
// Returning an error rather than a zero value is the important part. A zero tenant would
// silently widen every query to "no tenant filter", which is the exact failure this
// package exists to prevent, and it would do so without anything looking wrong.
func PrincipalFrom(ctx context.Context) (Principal, error) {
	tenantID, ok := ctx.Value(tenantKey).(string)
	if !ok || tenantID == "" {
		return Principal{}, ErrNoTenantInContext
	}

	userID, _ := ctx.Value(actorKey).(string)
	roles, _ := ctx.Value(rolesKey).([]string)

	return Principal{TenantID: tenantID, UserID: userID, Roles: roles}, nil
}

// TenantFrom is a convenience for callers that need only the scope.
func TenantFrom(ctx context.Context) (string, error) {
	principal, err := PrincipalFrom(ctx)
	if err != nil {
		return "", err
	}
	return principal.TenantID, nil
}

// SessionOpener is implemented by the database layer in Phase 6.
//
// Declared here so the contract is visible now: whatever opens a session must be handed a
// tenant, and the statement that sets it is not optional.
type SessionOpener interface {
	// Exec runs the statement that binds row-level security to a tenant.
	Exec(ctx context.Context, statement string, args ...any) error
}

// SetSessionTenant applies the row-level-security context to a freshly opened session.
//
// Parameterized rather than interpolated. set_config with a bound parameter cannot be
// escaped out of, whereas building "SET app.tenant_id = '" + id + "'" would put an
// attacker-influenced value into a statement that runs before any policy applies, which is
// the worst possible place for an injection.
func SetSessionTenant(ctx context.Context, session SessionOpener) error {
	tenantID, err := TenantFrom(ctx)
	if err != nil {
		return err
	}

	// is_local = true scopes the setting to the current transaction, so a pooled
	// connection cannot carry one tenant's scope into another tenant's request. With a
	// connection pool and is_local = false, that is not a hypothetical.
	const statement = `SELECT set_config('app.tenant_id', $1, true)`

	if err := session.Exec(ctx, statement, tenantID); err != nil {
		return fmt.Errorf("tenancy: binding session to tenant: %w", err)
	}
	return nil
}

// Guard verifies that a resource belongs to the caller's tenant.
//
// The database policy is the real boundary; this is defence in depth for code paths that
// receive an already-loaded record. Two independent checks that must both fail before data
// crosses a tenant line is the shape this deserves.
func Guard(ctx context.Context, resourceTenantID string) error {
	tenantID, err := TenantFrom(ctx)
	if err != nil {
		return err
	}
	if tenantID != resourceTenantID {
		return ErrTenantMismatch
	}
	return nil
}
