// Package store is the only package permitted to open a database connection.
//
// That restriction is the point. Tenant scoping is applied here, on every session, before
// any caller gets to run a statement, so "did you remember to filter by tenant" stops being
// a question a reviewer has to ask. A CI check asserts that the driver is imported by this
// package and no other; a boundary that is not enforced mechanically erodes within a
// quarter.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/talif/aperture/backend/internal/syncapi"
	"github.com/talif/aperture/backend/internal/tenancy"
)

// Postgres implements syncapi.Store.
type Postgres struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

// NewPostgres opens a pool and verifies it can reach the database.
//
// Verified at construction rather than on first use. A service that starts healthy and
// fails on its first real request reports the outage minutes later than it could, and
// reports it as an application error rather than as what it is.
func NewPostgres(ctx context.Context, databaseURL string, now func() time.Time) (*Postgres, error) {
	if now == nil {
		now = time.Now
	}

	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("store: parsing database url: %w", err)
	}

	// Bounded. An unbounded pool converts a slow query into a database-wide connection
	// exhaustion, and the first symptom is every other service failing rather than the one
	// with the slow query.
	config.MaxConns = 20
	config.MinConns = 2
	config.MaxConnLifetime = time.Hour
	config.MaxConnIdleTime = 15 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("store: opening pool: %w", err)
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: database unreachable: %w", err)
	}

	return &Postgres{pool: pool, now: now}, nil
}

// Close releases the pool.
func (p *Postgres) Close() {
	p.pool.Close()
}

// withTenantTx runs work inside a transaction scoped to the caller's tenant.
//
// Every read and every write in this package goes through here. The scope is set with
// set_config and is_local = true, so it lives exactly as long as the transaction: with a
// pooled connection and a session-scoped setting, one tenant's scope outlives its request
// and is inherited by whoever gets that connection next, which is not a hypothetical.
//
// The parameter is bound rather than interpolated. Building the statement by concatenation
// would put an attacker-influenced value into a statement that runs before any policy
// applies, which is the worst possible place for an injection.
func (p *Postgres) withTenantTx(
	ctx context.Context,
	work func(pgx.Tx) error,
) error {
	tenantID, err := tenancy.TenantFrom(ctx)
	if err != nil {
		return err
	}

	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: beginning transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenantID); err != nil {
		return fmt.Errorf("store: scoping session to tenant: %w", err)
	}

	if err := work(tx); err != nil {
		return err
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: committing: %w", err)
	}

	return nil
}

// Entity implements syncapi.Store.
func (p *Postgres) Entity(ctx context.Context, entityType, entityID string) (*syncapi.Entity, error) {
	var entity *syncapi.Entity

	err := p.withTenantTx(ctx, func(tx pgx.Tx) error {
		const query = `
			SELECT tenant_id, entity_type, entity_id, version, hlc,
			       fields, field_versions, deleted_at, updated_at
			FROM sync_entities
			WHERE entity_type = $1 AND entity_id = $2`

		var (
			found         syncapi.Entity
			fieldsJSON    []byte
			fieldVersions []byte
		)

		row := tx.QueryRow(ctx, query, entityType, entityID)
		scanErr := row.Scan(
			&found.TenantID, &found.EntityType, &found.EntityID,
			&found.Version, &found.HLC,
			&fieldsJSON, &fieldVersions,
			&found.DeletedAt, &found.UpdatedAt,
		)

		if errors.Is(scanErr, pgx.ErrNoRows) {
			// Indistinguishable from a row in another tenant, which is deliberate: the
			// policy filters it out, and reporting "exists but not yours" would confirm
			// the existence of data the caller cannot see.
			return syncapi.ErrEntityNotFound
		}
		if scanErr != nil {
			return fmt.Errorf("store: reading entity: %w", scanErr)
		}

		if err := json.Unmarshal(fieldsJSON, &found.Fields); err != nil {
			return fmt.Errorf("store: decoding fields: %w", err)
		}
		if err := json.Unmarshal(fieldVersions, &found.FieldVersions); err != nil {
			return fmt.Errorf("store: decoding field versions: %w", err)
		}

		entity = &found
		return nil
	})

	if err != nil {
		return nil, err
	}
	return entity, nil
}

// ApplyOperation implements syncapi.Store.
//
// The entity write and the change-log row commit together, or neither does. A record
// written without its change-log row is invisible to every other device forever, and no
// later reconciliation can discover it because nothing records that it is missing.
func (p *Postgres) ApplyOperation(
	ctx context.Context,
	op syncapi.Operation,
	next *syncapi.Entity,
) error {
	return p.withTenantTx(ctx, func(tx pgx.Tx) error {
		fields, err := json.Marshal(next.Fields)
		if err != nil {
			return fmt.Errorf("store: encoding fields: %w", err)
		}
		versions, err := json.Marshal(next.FieldVersions)
		if err != nil {
			return fmt.Errorf("store: encoding field versions: %w", err)
		}

		tenantID, err := tenancy.TenantFrom(ctx)
		if err != nil {
			return err
		}

		const upsert = `
			INSERT INTO sync_entities (
				tenant_id, entity_type, entity_id, version, hlc,
				fields, field_versions, deleted_at, updated_at
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
			ON CONFLICT (tenant_id, entity_type, entity_id) DO UPDATE SET
				version = EXCLUDED.version,
				hlc = EXCLUDED.hlc,
				fields = EXCLUDED.fields,
				field_versions = EXCLUDED.field_versions,
				deleted_at = EXCLUDED.deleted_at,
				updated_at = EXCLUDED.updated_at`

		updatedAt := p.now()
		if _, err := tx.Exec(ctx, upsert,
			tenantID, op.EntityType, op.EntityID, next.Version, next.HLC,
			fields, versions, next.DeletedAt, updatedAt,
		); err != nil {
			return fmt.Errorf("store: writing entity: %w", err)
		}

		const appendChange = `
			INSERT INTO sync_changes (
				tenant_id, entity_type, entity_id, server_version,
				hlc, changed_fields, is_deletion, occurred_at
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`

		if _, err := tx.Exec(ctx, appendChange,
			tenantID, op.EntityType, op.EntityID, next.Version,
			op.HLC, op.DirtyFields, op.Kind == syncapi.KindDelete, updatedAt,
		); err != nil {
			return fmt.Errorf("store: appending change: %w", err)
		}

		next.TenantID = tenantID
		next.UpdatedAt = updatedAt
		return nil
	})
}

// Changes implements syncapi.Store.
func (p *Postgres) Changes(
	ctx context.Context,
	cursor string,
	limit int,
) ([]syncapi.Change, string, bool, error) {
	after, err := syncapi.DecodeCursor(cursor)
	if err != nil {
		return nil, "", false, err
	}

	var (
		page    []syncapi.Change
		last    = after
		hasMore bool
	)

	err = p.withTenantTx(ctx, func(tx pgx.Tx) error {
		// One row beyond the page, so "is there more" is answered by the same query rather
		// than by a second count that can disagree with the first under concurrent writes.
		const query = `
			SELECT seq, entity_type, entity_id, server_version,
			       hlc, changed_fields, is_deletion, occurred_at
			FROM sync_changes
			WHERE seq > $1
			ORDER BY seq
			LIMIT $2`

		rows, queryErr := tx.Query(ctx, query, after, limit+1)
		if queryErr != nil {
			return fmt.Errorf("store: reading changes: %w", queryErr)
		}
		defer rows.Close()

		for rows.Next() {
			var (
				seq    int64
				change syncapi.Change
			)
			if scanErr := rows.Scan(
				&seq, &change.EntityType, &change.EntityID, &change.ServerVersion,
				&change.HLC, &change.ChangedFields, &change.IsDeletion, &change.OccurredAt,
			); scanErr != nil {
				return fmt.Errorf("store: scanning change: %w", scanErr)
			}

			if len(page) == limit {
				hasMore = true
				break
			}

			page = append(page, change)
			last = seq
		}

		return rows.Err()
	})

	if err != nil {
		return nil, "", false, err
	}

	if page == nil {
		// An empty slice rather than nil, so the field serializes as [] and not null. A
		// client decoding null into a non-optional array crashes, and it is the kind that
		// only happens on the one device that had nothing to pull.
		page = []syncapi.Change{}
	}

	return page, syncapi.EncodeCursor(last), hasMore, nil
}

// ResultForKey implements syncapi.Store.
func (p *Postgres) ResultForKey(
	ctx context.Context,
	key string,
) (*syncapi.StoredResult, bool, error) {
	var (
		stored syncapi.StoredResult
		found  bool
	)

	err := p.withTenantTx(ctx, func(tx pgx.Tx) error {
		const query = `
			SELECT response, created_at
			FROM sync_idempotency
			WHERE operation_id = $1 AND expires_at > now()`

		var response []byte
		row := tx.QueryRow(ctx, query, key)

		scanErr := row.Scan(&response, &stored.CreatedAt)
		if errors.Is(scanErr, pgx.ErrNoRows) {
			return nil
		}
		if scanErr != nil {
			return fmt.Errorf("store: reading stored result: %w", scanErr)
		}

		if err := json.Unmarshal(response, &stored.Result); err != nil {
			return fmt.Errorf("store: decoding stored result: %w", err)
		}

		found = true
		return nil
	})

	if err != nil {
		return nil, false, err
	}
	if !found {
		return nil, false, nil
	}
	return &stored, true, nil
}

// StoreResult implements syncapi.Store.
func (p *Postgres) StoreResult(ctx context.Context, key string, result syncapi.Result) error {
	return p.withTenantTx(ctx, func(tx pgx.Tx) error {
		response, err := json.Marshal(result)
		if err != nil {
			return fmt.Errorf("store: encoding result: %w", err)
		}

		tenantID, err := tenancy.TenantFrom(ctx)
		if err != nil {
			return err
		}

		// DO NOTHING rather than DO UPDATE. The first answer is the one the client must
		// keep receiving: re-evaluating on a retry lets the two sides disagree about what
		// was decided, which is the failure idempotency exists to prevent.
		const insert = `
			INSERT INTO sync_idempotency (tenant_id, operation_id, status, response)
			VALUES ($1, $2, $3, $4)
			ON CONFLICT (tenant_id, operation_id) DO NOTHING`

		if _, err := tx.Exec(ctx, insert, tenantID, key, result.Status, response); err != nil {
			return fmt.Errorf("store: writing stored result: %w", err)
		}

		return nil
	})
}
