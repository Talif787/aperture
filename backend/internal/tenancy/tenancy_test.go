package tenancy

import (
	"context"
	"errors"
	"testing"
)

func TestPrincipalRoundTrips(t *testing.T) {
	t.Parallel()

	ctx := WithPrincipal(context.Background(), Principal{
		TenantID: "tnt-1",
		UserID:   "usr-9",
		Roles:    []string{"inspector"},
	})

	principal, err := PrincipalFrom(ctx)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if principal.TenantID != "tnt-1" || principal.UserID != "usr-9" {
		t.Fatalf("unexpected principal: %+v", principal)
	}
	if !principal.HasRole("inspector") || principal.HasRole("admin") {
		t.Fatalf("role check is wrong: %+v", principal.Roles)
	}
}

func TestUnscopedContextIsAnErrorNotAZeroValue(t *testing.T) {
	t.Parallel()

	_, err := PrincipalFrom(context.Background())

	// The important assertion in this package. A zero tenant would silently widen every
	// query to "no tenant filter", which is the exact failure row-level security exists to
	// prevent, and nothing about the code would look wrong.
	if !errors.Is(err, ErrNoTenantInContext) {
		t.Fatalf("expected ErrNoTenantInContext, got %v", err)
	}
}

func TestEmptyTenantIsTreatedAsAbsent(t *testing.T) {
	t.Parallel()

	ctx := WithPrincipal(context.Background(), Principal{TenantID: "", UserID: "usr-9"})

	if _, err := PrincipalFrom(ctx); !errors.Is(err, ErrNoTenantInContext) {
		t.Fatalf("an empty tenant must not pass as scoped, got %v", err)
	}
}

func TestGuardRejectsAForeignResource(t *testing.T) {
	t.Parallel()

	ctx := WithPrincipal(context.Background(), Principal{TenantID: "tnt-1", UserID: "usr-9"})

	if err := Guard(ctx, "tnt-1"); err != nil {
		t.Fatalf("same tenant must pass: %v", err)
	}
	if err := Guard(ctx, "tnt-2"); !errors.Is(err, ErrTenantMismatch) {
		t.Fatalf("expected ErrTenantMismatch, got %v", err)
	}
}

func TestGuardRefusesAnUnscopedContext(t *testing.T) {
	t.Parallel()

	if err := Guard(context.Background(), "tnt-1"); !errors.Is(err, ErrNoTenantInContext) {
		t.Fatalf("an unscoped context must fail closed, got %v", err)
	}
}

type recordingSession struct {
	statement string
	args      []any
	err       error
}

func (r *recordingSession) Exec(_ context.Context, statement string, args ...any) error {
	r.statement = statement
	r.args = args
	return r.err
}

func TestSetSessionTenantBindsTheScopeAsAParameter(t *testing.T) {
	t.Parallel()

	ctx := WithPrincipal(context.Background(), Principal{TenantID: "tnt-1", UserID: "usr-9"})
	session := &recordingSession{}

	if err := SetSessionTenant(ctx, session); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Bound, never interpolated. An interpolated tenant identifier would place an
	// attacker-influenced value into a statement that runs before any policy applies.
	if session.statement != `SELECT set_config('app.tenant_id', $1, true)` {
		t.Fatalf("unexpected statement: %q", session.statement)
	}
	if len(session.args) != 1 || session.args[0] != "tnt-1" {
		t.Fatalf("unexpected args: %v", session.args)
	}
}

func TestSetSessionTenantScopesToTheTransaction(t *testing.T) {
	t.Parallel()

	ctx := WithPrincipal(context.Background(), Principal{TenantID: "tnt-1"})
	session := &recordingSession{}

	if err := SetSessionTenant(ctx, session); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// is_local = true. With a connection pool and a session-scoped setting, one tenant's
	// scope outlives its request and is inherited by whoever gets that connection next.
	if !contains(session.statement, "true)") {
		t.Fatalf("set_config must be transaction-local: %q", session.statement)
	}
}

func TestSetSessionTenantRefusesAnUnscopedContext(t *testing.T) {
	t.Parallel()

	session := &recordingSession{}

	if err := SetSessionTenant(context.Background(), session); !errors.Is(err, ErrNoTenantInContext) {
		t.Fatalf("expected ErrNoTenantInContext, got %v", err)
	}
	if session.statement != "" {
		t.Fatal("no statement should run for an unscoped context")
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (haystack == needle ||
		len(needle) == 0 || indexOf(haystack, needle) >= 0)
}

func indexOf(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
