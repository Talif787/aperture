#!/usr/bin/env bash
# Database lifecycle for local development.
#
#   ./scripts/db.sh status        what exists right now
#   ./scripts/db.sh migrate       apply migrations and grants
#   ./scripts/db.sh seed          insert the development fixtures
#   ./scripts/db.sh verify-rls    prove tenant isolation, adversarially
#   ./scripts/db.sh psql          interactive shell as the bootstrap role
#   ./scripts/db.sh app-psql      interactive shell as the application role
#   ./scripts/db.sh reset         destroy and rebuild from nothing
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="infra/docker-compose.yml"
SERVICE="postgres"
DB_USER="${POSTGRES_USER:-aperture}"
DB_NAME="${POSTGRES_DB:-aperture}"
APP_USER="aperture_app"
APP_PASSWORD="local-development-only"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[1;34m'; OFF=$'\033[0m'
log()  { printf "${BLUE}==>${OFF} %s\n" "$*"; }
pass() { printf "  ${GREEN}pass${OFF}  %s\n" "$*"; }
fail() { printf "  ${RED}FAIL${OFF}  %s\n" "$*"; FAILURES=$((FAILURES + 1)); }
warn() { printf "  ${YELLOW}note${OFF}  %s\n" "$*"; }


# --- migration tracking -------------------------------------------------------------
#
# A migration that has run must not run again. Without a record of what has been applied,
# `migrate` is a one-shot command that errors on every subsequent invocation, and the only
# way to tell whether a file has been applied is to read the schema and guess.
#
# The checksum matters as much as the version. Editing a migration after it has run
# produces a database whose schema does not match its own history, and the difference is
# invisible until a fresh environment is built from the same files and behaves differently.

ensure_migration_table() {
  root_sql -tAc "CREATE TABLE IF NOT EXISTS schema_migrations (
      version    text PRIMARY KEY,
      checksum   text NOT NULL,
      applied_at timestamptz NOT NULL DEFAULT now())" >/dev/null
}

migration_files() {
  for file in backend/migrations/*.sql infra/db/*.sql; do
    [[ -f "${file}" ]] && printf '%s|%s\n' "$(basename "${file}")" "${file}"
  done | sort | cut -d'|' -f2
}

recorded_checksum() {
  root_sql -tAc "SELECT checksum FROM schema_migrations WHERE version='$1'" 2>/dev/null </dev/null \
    | tr -d '[:space:]'
}

apply_migration() {
  local file="$1"
  local version checksum recorded
  version="$(basename "${file}")"
  checksum="$(sha256sum "${file}" | cut -d' ' -f1)"
  recorded="$(recorded_checksum "${version}")"

  if [[ -n "${recorded}" ]]; then
    if [[ "${recorded}" == "${checksum}" ]]; then
      printf "  ${YELLOW}skip${OFF}  %s already applied\n" "${version}"
      return 0
    fi
    printf "  ${RED}FAIL${OFF}  %s was edited after it was applied\n" "${version}" >&2
    echo "        recorded ${recorded:0:12}, on disk ${checksum:0:12}" >&2
    echo "        A migration is history, not source. Write a new one, or rebuild with:" >&2
    echo "          make db-reset" >&2
    exit 1
  fi

  log "Applying ${version}"
  root_sql < "${file}"
  root_sql -tAc "INSERT INTO schema_migrations (version, checksum)
                 VALUES ('${version}', '${checksum}')" >/dev/null </dev/null
  pass "${version} applied"
}

FAILURES=0

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

require_running() {
  if ! compose ps --status running --services 2>/dev/null | grep -q "^${SERVICE}$"; then
    echo "Postgres is not running. Start it with: make backend-up" >&2
    exit 1
  fi
}

# Runs SQL as the bootstrap role, which is a superuser and therefore bypasses RLS.
# Used for migrations and seeding only.
root_sql() {
  compose exec -T "${SERVICE}" psql -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" "$@"
}

# Runs SQL as the application role, which is NOSUPERUSER and NOBYPASSRLS.
# Every isolation assertion must go through this, or it proves nothing.
app_sql() {
  compose exec -T -e PGPASSWORD="${APP_PASSWORD}" "${SERVICE}" \
    psql -v ON_ERROR_STOP=1 -U "${APP_USER}" -d "${DB_NAME}" -h 127.0.0.1 "$@"
}

# Runs a scoped read and returns only the value.
#
# Each statement is a separate -c, wrapped in one transaction by -1. The earlier version
# put BEGIN, set_config, the query, and COMMIT into a single -c and then took the tail of
# the collapsed output, which returned the "COMMIT" command tag rather than the count.
# Separate statements mean the last line is the answer, with nothing to parse around.
app_scoped_value() {
  local tenant="$1" query="$2"
  app_sql -tA -1 \
    -c "SELECT set_config('app.tenant_id','${tenant}',true)" \
    -c "${query}" 2>/dev/null | tail -1 | tr -d '[:space:]'
}

app_value() {
  app_sql -tAc "$1" 2>/dev/null | tail -1 | tr -d '[:space:]'
}

# Runs a scoped statement and reports only whether it succeeded.
app_scoped_succeeds() {
  local tenant="$1" statement="$2"
  app_sql -tA -1 \
    -c "SELECT set_config('app.tenant_id','${tenant}',true)" \
    -c "${statement}" >/dev/null 2>&1
}

case "${1:-status}" in

status)
  log "Container"
  if compose ps --status running --services 2>/dev/null | grep -q "^${SERVICE}$"; then
    pass "postgres is running"
  else
    warn "postgres is not running (make backend-up)"
    exit 0
  fi

  log "Schema"
  tables=$(root_sql -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" | tr -d '[:space:]')
  if [[ "${tables}" -gt 0 ]]; then
    pass "${tables} table(s) present"
    root_sql -tAc "SELECT '    ' || table_name FROM information_schema.tables
                   WHERE table_schema='public' ORDER BY table_name"
  else
    warn "no tables (./scripts/db.sh migrate)"
  fi

  log "Migrations"
  mapfile -t on_disk < <(migration_files)
  if [[ "${tables}" -gt 0 ]] && root_sql -tAc \
      "SELECT 1 FROM information_schema.tables WHERE table_name='schema_migrations'" </dev/null \
      | grep -q 1; then
    root_sql -tAc "SELECT '    ' || version || '  ' || to_char(applied_at, 'YYYY-MM-DD HH24:MI')
                   FROM schema_migrations ORDER BY version" </dev/null
    recorded=$(root_sql -tAc "SELECT count(*) FROM schema_migrations" </dev/null | tr -d '[:space:]')
    if [[ "${recorded}" == "${#on_disk[@]}" ]]; then
      pass "${recorded} of ${#on_disk[@]} migration file(s) recorded"
    else
      # Stated explicitly rather than left to be noticed by eye. A file present on disk and
      # absent from the table is either unapplied work or a gap in the record, and both are
      # worth seeing at a glance.
      warn "${recorded} of ${#on_disk[@]} recorded (./scripts/db.sh migrate, or baseline)"
    fi
  else
    warn "no migration tracking (./scripts/db.sh baseline, or make db-reset)"
  fi

  log "Application role"
  if [[ "$(root_sql -tAc "SELECT count(*) FROM pg_roles WHERE rolname='${APP_USER}'" | tr -d '[:space:]')" == "1" ]]; then
    pass "${APP_USER} exists"
    root_sql -tAc "SELECT '    superuser=' || rolsuper || ' bypassrls=' || rolbypassrls
                   FROM pg_roles WHERE rolname='${APP_USER}'"
  else
    warn "${APP_USER} missing (./scripts/db.sh migrate)"
  fi

  log "Seed data"
  if [[ "${tables}" -gt 0 ]]; then
    root_sql -tAc "SELECT '    tenants=' || (SELECT count(*) FROM tenants)
                        || ' users='   || (SELECT count(*) FROM users)
                        || ' devices=' || (SELECT count(*) FROM devices)
                        || ' audit='   || (SELECT count(*) FROM audit_log)"
  fi
  ;;

migrate)
  require_running
  ensure_migration_table
  log "Pending migrations"
  # Collected up front rather than streamed into a while-read loop. `docker compose exec`
  # forwards stdin to the container, so a psql call inside the loop consumes the rest of
  # the stream feeding it: the loop runs once and stops, with no error and no output to
  # suggest anything was skipped.
  mapfile -t pending < <(migration_files)
  for file in "${pending[@]}"; do
    apply_migration "${file}"
  done
  log "Schema is current."
  ;;

baseline)
  # Adopts a database whose schema was created before migration tracking existed.
  # Records every file as applied without running any of it, which is what a real
  # migration tool offers when it is introduced to a live database.
  require_running
  ensure_migration_table
  log "Recording existing migrations as applied, without running them"
  mapfile -t existing < <(migration_files)
  for file in "${existing[@]}"; do
    version="$(basename "${file}")"
    checksum="$(sha256sum "${file}" | cut -d' ' -f1)"
    root_sql -tAc "INSERT INTO schema_migrations (version, checksum)
                   VALUES ('${version}', '${checksum}')
                   ON CONFLICT (version) DO NOTHING" >/dev/null </dev/null
    pass "${version} recorded"
  done
  log "Baseline complete. 'make db-migrate' is now a no-op until a new file is added."
  ;;

seed)
  require_running
  log "Seeding infra/seed/dev_seed.sql"
  root_sql < infra/seed/dev_seed.sql
  log "Done."
  ;;

verify-rls)
  require_running
  TENANT_A="11111111-1111-4111-a111-111111111111"
  TENANT_B="22222222-2222-4222-a222-222222222222"
  USER_B="b1111111-1111-4111-a111-111111111111"

  log "Row-level security, as ${APP_USER} (NOSUPERUSER, NOBYPASSRLS)"

  # Guard against a false pass. A superuser bypasses row security regardless of FORCE ROW
  # LEVEL SECURITY, so if the role attributes were wrong every check below would succeed
  # while proving nothing at all.
  #
  # The verdict is computed in SQL and returned as one word, rather than reading the
  # boolean columns and comparing them in the shell. Booleans render as 'f' or 'true'
  # depending on the cast and the output mode, and a guard that fails on a formatting
  # difference is a guard nobody will trust the second time it cries wolf.
  role_safety=$(root_sql -tAc "
    SELECT coalesce(
      (SELECT CASE WHEN rolsuper OR rolbypassrls THEN 'bypasses_rls' ELSE 'subject_to_rls' END
         FROM pg_roles WHERE rolname='${APP_USER}'),
      'role_missing')" | tr -d '[:space:]')

  case "${role_safety}" in
    subject_to_rls)
      pass "${APP_USER} is NOSUPERUSER and NOBYPASSRLS, so policies actually apply"
      ;;
    bypasses_rls)
      fail "${APP_USER} can bypass row security. Every check below would be meaningless"
      ;;
    *)
      fail "${APP_USER} does not exist. Run: make db-migrate"
      ;;
  esac

  a_users=$(app_scoped_value "${TENANT_A}" "SELECT count(*) FROM users")
  b_users=$(app_scoped_value "${TENANT_B}" "SELECT count(*) FROM users")
  no_scope=$(app_value "SELECT count(*) FROM users")

  [[ "${a_users}" == "2" ]] && pass "tenant A sees its 2 users" \
                            || fail "tenant A saw '${a_users}', expected 2"
  [[ "${b_users}" == "2" ]] && pass "tenant B sees its 2 users" \
                            || fail "tenant B saw '${b_users}', expected 2"

  # The most important assertion here. An unscoped session must see nothing, not
  # everything. A policy that fails open is worse than no policy, because it looks like
  # protection.
  [[ "${no_scope}" == "0" ]] && pass "an unscoped session sees 0 rows (fails closed)" \
                             || fail "an unscoped session saw '${no_scope}', expected 0"

  # The adversarial case: ask directly for another tenant's row by primary key.
  cross=$(app_scoped_value "${TENANT_A}" "SELECT count(*) FROM users WHERE id='${USER_B}'")
  [[ "${cross}" == "0" ]] && pass "tenant A cannot read tenant B's user by id" \
                          || fail "cross-tenant read returned '${cross}', expected 0"

  # Writing a row into another tenant must be refused by the WITH CHECK clause.
  if app_scoped_succeeds "${TENANT_A}" \
      "INSERT INTO audit_log (tenant_id, entity_type, action) VALUES ('${TENANT_B}','device','forged')"; then
    fail "tenant A was able to write a row attributed to tenant B"
  else
    pass "a cross-tenant insert is rejected by the policy"
  fi

  # Append-only, enforced as a grant rather than as a convention.
  if app_scoped_succeeds "${TENANT_A}" "UPDATE audit_log SET action='rewritten'"; then
    fail "the audit log was updatable by the application role"
  else
    pass "the audit log rejects UPDATE"
  fi

  if app_scoped_succeeds "${TENANT_A}" "DELETE FROM audit_log"; then
    fail "the audit log was deletable by the application role"
  else
    pass "the audit log rejects DELETE"
  fi

  # --- sync tables, added in Phase 6b ---------------------------------------------
  #
  # Checked separately because they fail differently. Entities expose content, the change
  # log exposes activity and timing even without content, and the idempotency table exposes
  # another tenant's stored response to whoever guesses a key.

  if root_sql -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='sync_entities'" \
      </dev/null | grep -q 1; then

    # Asserted on specific rows rather than on counts.
    #
    # A count assumes nothing else shares the table, and the store integration tests write
    # into it legitimately. A check that breaks because unrelated valid data appeared is a
    # check people start ignoring, and the property being tested here is visibility of a
    # known row, not the size of the table.
    a_own=$(app_scoped_value "${TENANT_A}" \
        "SELECT count(*) FROM sync_entities WHERE entity_id = 'seed-finding-a'")
    a_foreign=$(app_scoped_value "${TENANT_A}" \
        "SELECT count(*) FROM sync_entities WHERE entity_id = 'seed-finding-b'")
    b_own=$(app_scoped_value "${TENANT_B}" \
        "SELECT count(*) FROM sync_entities WHERE entity_id = 'seed-finding-b'")
    no_scope_entities=$(app_value "SELECT count(*) FROM sync_entities")

    [[ "${a_own}" == "1" ]] && pass "tenant A sees its own sync entity" \
                            || fail "tenant A could not see seed-finding-a (got '${a_own}')"
    [[ "${a_foreign}" == "0" ]] && pass "tenant A cannot see tenant B's sync entity" \
                                || fail "tenant A saw seed-finding-b (got '${a_foreign}')"
    [[ "${b_own}" == "1" ]] && pass "tenant B sees its own sync entity" \
                            || fail "tenant B could not see seed-finding-b (got '${b_own}')"
    [[ "${no_scope_entities}" == "0" ]] && pass "an unscoped session sees no sync entities" \
                                        || fail "an unscoped session saw '${no_scope_entities}'"

    a_changes=$(app_scoped_value "${TENANT_A}" \
        "SELECT count(*) FROM sync_changes WHERE entity_id = 'seed-finding-b'")
    [[ "${a_changes}" == "0" ]] && pass "the change log is scoped to the tenant" \
                                || fail "tenant A saw tenant B's change (got '${a_changes}')"

    # Append-only, as a grant rather than a convention: a client's view of history cannot
    # be rewritten under it by any code path, including a buggy one.
    if app_scoped_succeeds "${TENANT_A}" "UPDATE sync_changes SET hlc='rewritten'"; then
      fail "the change log was updatable by the application role"
    else
      pass "the change log rejects UPDATE"
    fi

    if app_scoped_succeeds "${TENANT_A}" "DELETE FROM sync_changes"; then
      fail "the change log was deletable by the application role"
    else
      pass "the change log rejects DELETE"
    fi

    # Writing a row attributed to another tenant must be refused by WITH CHECK.
    if app_scoped_succeeds "${TENANT_A}" \
        "INSERT INTO sync_entities (tenant_id, entity_type, entity_id, version, hlc)
         VALUES ('${TENANT_B}','finding','forged',1,'h')"; then
      fail "tenant A wrote a sync entity attributed to tenant B"
    else
      pass "a cross-tenant sync write is rejected by the policy"
    fi
  else
    warn "sync tables absent; run make db-migrate to apply 0003"
  fi

  echo
  if [[ ${FAILURES} -eq 0 ]]; then
    printf "${GREEN}Tenant isolation verified.${OFF}\n"
  else
    printf "${RED}%d isolation check(s) failed.${OFF}\n" "${FAILURES}"
    exit 1
  fi
  ;;

psql)
  require_running
  compose exec "${SERVICE}" psql -U "${DB_USER}" -d "${DB_NAME}"
  ;;

app-psql)
  require_running
  compose exec -e PGPASSWORD="${APP_PASSWORD}" "${SERVICE}" \
    psql -U "${APP_USER}" -d "${DB_NAME}" -h 127.0.0.1
  ;;

reset)
  log "Destroying the local database volume"
  compose down -v
  log "Rebuilding"
  compose up -d
  log "Waiting for readiness"
  for _ in $(seq 1 30); do
    if compose exec -T "${SERVICE}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  "$0" migrate
  "$0" seed
  log "Reset complete."
  ;;

*)
  echo "usage: $0 {status|migrate|baseline|seed|verify-rls|psql|app-psql|reset}" >&2
  exit 1
  ;;
esac
