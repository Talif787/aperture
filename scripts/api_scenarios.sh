#!/usr/bin/env bash
# Exercises every Phase 6a endpoint against a running service and asserts the outcome.
#
#   make api-scenarios
#
# Requires the service running with APERTURE_JWKS_PATH set, and the development key that
# minted the tokens it verifies. `make api-up` arranges both.
set -uo pipefail

cd "$(dirname "$0")/.."

BASE_URL="${BASE_URL:-http://localhost:8080}"
DEV_DIR="${DEV_DIR:-$(pwd)/.dev}"
KEY="${DEV_DIR}/dev-key.pem"
DEVTOKEN="${DEV_DIR}/devtoken"

TENANT_A="11111111-1111-4111-a111-111111111111"
TENANT_B="22222222-2222-4222-a222-222222222222"
DANA="00uDANA0001"
MARCUS="00uMARCUS01"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[1;34m'; DIM=$'\033[2m'; OFF=$'\033[0m'
FAILURES=0

section() { printf "\n${BLUE}==>${OFF} %s\n" "$*"; }
pass()    { printf "  ${GREEN}pass${OFF}  %s\n" "$*"; }
fail()    { printf "  ${RED}FAIL${OFF}  %s\n" "$*"; FAILURES=$((FAILURES + 1)); }
detail()  { printf "        ${DIM}%s${OFF}\n" "$*"; }

require() {
  if [[ ! -x "${DEVTOKEN}" ]]; then
    echo "devtoken binary missing. Run: make api-build" >&2
    exit 1
  fi
  if [[ ! -f "${KEY}" ]]; then
    echo "development key missing. Run: make api-keygen" >&2
    exit 1
  fi
  if ! curl -sf "${BASE_URL}/healthz" >/dev/null; then
    echo "service is not answering at ${BASE_URL}. Run: make api-up" >&2
    exit 1
  fi
}

mint() {
  local tenant="$1" subject="$2" roles="${3:-inspector}" ttl="${4:-15m}"
  "${DEVTOKEN}" mint -key "${KEY}" -tenant "${tenant}" -subject "${subject}" \
    -roles "${roles}" -ttl "${ttl}"
}

# Prints the HTTP status on the first line and the body on the rest, so a single call can
# assert on both without a second request.
call() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(-s -o /tmp/api_body -w '%{http_code}' -X "${method}" "${BASE_URL}${path}")
  [[ -n "${token}" ]] && args+=(-H "Authorization: Bearer ${token}")
  [[ -n "${body}" ]] && args+=(-H "Content-Type: application/json" -d "${body}")
  local status
  status=$(curl "${args[@]}")
  echo "${status}"
  cat /tmp/api_body
}

json_field() {
  python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(''); raise SystemExit
for key in sys.argv[1].split('.'):
    if isinstance(data, list):
        data = data[int(key)] if key.isdigit() and int(key) < len(data) else None
    elif isinstance(data, dict):
        data = data.get(key)
    else:
        data = None
    if data is None:
        print(''); raise SystemExit
print(json.dumps(data) if isinstance(data, (dict, list, bool)) else data)
" "$1"
}

status_of() { head -1; }
body_of()   { tail -n +2; }

require

TOKEN_A=$(mint "${TENANT_A}" "${DANA}")
TOKEN_B=$(mint "${TENANT_B}" "${MARCUS}")

# Preflight. Without it, a key mismatch presents as twenty assertion failures across six
# unrelated sections, and the real cause (the service verifying against a key set that no
# longer matches the signing key) is nowhere in the output.
preflight=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN_A}" "${BASE_URL}/v1/me")

if [[ "${preflight}" != "200" ]]; then
  echo
  printf "${RED}A freshly minted token was refused with HTTP %s.${OFF}\n" "${preflight}"
  echo
  echo "The service is verifying against a key set that does not match ${KEY}."
  echo "Most often the key was regenerated after the service cached the old one."
  echo
  echo "  Signing key id:   $(python3 -c "
import json,sys
print(json.load(open('${DEV_DIR}/dev-jwks.json'))['keys'][0]['kid'])
" 2>/dev/null || echo 'could not read the key set')"
  echo "  Token key id:     $(python3 -c "
import base64, json, sys
header = '${TOKEN_A}'.split('.')[0]
header += '=' * (-len(header) % 4)
print(json.loads(base64.urlsafe_b64decode(header)).get('kid', '?'))
" 2>/dev/null || echo 'could not decode the token')"
  echo
  echo "Fix with:"
  echo "  make api-down && make api-up"
  echo
  echo "The service log records why each token was refused:"
  echo "  grep 'token rejected' ${DEV_DIR}/aperture.log | tail -3"
  exit 1
fi

# ---------------------------------------------------------------- authentication

section "Authentication"

result=$(call GET /v1/me)
[[ "$(echo "${result}" | status_of)" == "401" ]] \
  && pass "no token is refused" \
  || fail "no token returned $(echo "${result}" | status_of)"

result=$(call GET /v1/me "not-a-token")
[[ "$(echo "${result}" | status_of)" == "401" ]] \
  && pass "a malformed token is refused" \
  || fail "malformed token returned $(echo "${result}" | status_of)"

# Same token with one character of the signature changed.
TAMPERED="${TOKEN_A%?}X"
result=$(call GET /v1/me "${TAMPERED}")
[[ "$(echo "${result}" | status_of)" == "401" ]] \
  && pass "a tampered signature is refused" \
  || fail "tampered token returned $(echo "${result}" | status_of)"

EXPIRED=$(mint "${TENANT_A}" "${DANA}" inspector -5m)
result=$(call GET /v1/me "${EXPIRED}")
[[ "$(echo "${result}" | status_of)" == "401" ]] \
  && pass "an expired token is refused" \
  || fail "expired token returned $(echo "${result}" | status_of)"

result=$(call GET /v1/me "${TOKEN_A}")
tenant=$(echo "${result}" | body_of | json_field tenant_id)
[[ "${tenant}" == "${TENANT_A}" ]] \
  && pass "a valid token resolves to its tenant" \
  || fail "expected ${TENANT_A}, got '${tenant}'"

detail "the tenant comes from the signed token, never from a header"

# ---------------------------------------------------------------- push and replay

section "Push, replay, and conflict"

FINDING="f-$(date +%s)"

create_body() {
  cat <<JSON
{"operations":[{
  "operation_id":"$1","entity_type":"finding","entity_id":"${FINDING}",
  "kind":"$2","dirty_fields":["$3"],"base_version":$4,
  "hlc":"2026-09-10T00:26:40.123Z-0000-devA","payload":{"$3":"$5"}
}]}
JSON
}

result=$(call POST /v1/sync/deltas "${TOKEN_A}" "$(create_body op-create-1 create note 0 'first observation')")
status=$(echo "${result}" | body_of | json_field results.0.status)
version=$(echo "${result}" | body_of | json_field results.0.server_version)
[[ "${status}" == "applied" && "${version}" == "1" ]] \
  && pass "a create applies at version 1" \
  || fail "expected applied/1, got ${status}/${version}"

result=$(call POST /v1/sync/deltas "${TOKEN_A}" "$(create_body op-create-1 create note 0 'first observation')")
status=$(echo "${result}" | body_of | json_field results.0.status)
[[ "${status}" == "replayed" ]] \
  && pass "the same operation identifier replays rather than reapplying" \
  || fail "expected replayed, got ${status}"
detail "exactly-once effect over an at-least-once channel"

result=$(call POST /v1/sync/deltas "${TOKEN_A}" "$(create_body op-sev-1 update severity 0 'major')")
status=$(echo "${result}" | body_of | json_field results.0.status)
[[ "${status}" == "applied" ]] \
  && pass "a concurrent edit to a different field applies" \
  || fail "expected applied, got ${status}"
detail "a version mismatch alone is not a conflict, only an overlapping field is"

result=$(call POST /v1/sync/deltas "${TOKEN_A}" "$(create_body op-note-2 update note 0 'contradicting note')")
status=$(echo "${result}" | body_of | json_field results.0.status)
fields=$(echo "${result}" | body_of | json_field results.0.conflicting_fields)
[[ "${status}" == "conflict" ]] \
  && pass "an overlapping field conflicts, naming the field" \
  || fail "expected conflict, got ${status}"
detail "conflicting_fields = ${fields}"

# ---------------------------------------------------------------- validation

section "Validation"

result=$(call POST /v1/sync/deltas "${TOKEN_A}" '{"operations":[]}')
[[ "$(echo "${result}" | status_of)" == "400" ]] \
  && pass "an empty batch is refused" \
  || fail "empty batch returned $(echo "${result}" | status_of)"

result=$(call POST /v1/sync/deltas "${TOKEN_A}" \
  '{"operations":[{"operation_id":"op-x","entity_type":"finding","entity_id":"f-x","kind":"create","dirty_fields":["note"],"hlc":"h","surprise":"value"}]}')
[[ "$(echo "${result}" | status_of)" == "400" ]] \
  && pass "an unknown field is refused rather than ignored" \
  || fail "unknown field returned $(echo "${result}" | status_of)"
detail "silently discarding it is how a protocol drifts unnoticed"

result=$(call POST /v1/sync/deltas "${TOKEN_A}" \
  '{"operations":[{"operation_id":"op-y","entity_type":"finding","entity_id":"f-y","kind":"update","base_version":0,"hlc":"h"}]}')
status=$(echo "${result}" | body_of | json_field results.0.status)
[[ "${status}" == "rejected" ]] \
  && pass "an operation without dirty_fields is rejected" \
  || fail "expected rejected, got ${status}"
detail "without them the server can only compare versions, clobbering untouched fields"

result=$(call POST /v1/sync/deltas "${TOKEN_A}" \
  '{"operations":[
     {"operation_id":"op-ok-1","entity_type":"finding","entity_id":"f-batch","kind":"create","dirty_fields":["note"],"base_version":0,"hlc":"h","payload":{"note":"a"}},
     {"operation_id":"op-bad-1","entity_type":"finding","entity_id":"f-batch2","kind":"nonsense","dirty_fields":["note"],"hlc":"h"},
     {"operation_id":"op-ok-2","entity_type":"finding","entity_id":"f-batch3","kind":"create","dirty_fields":["note"],"base_version":0,"hlc":"h","payload":{"note":"b"}}
   ]}')
first=$(echo "${result}" | body_of | json_field results.0.status)
second=$(echo "${result}" | body_of | json_field results.1.status)
third=$(echo "${result}" | body_of | json_field results.2.status)
[[ "${first}" == "applied" && "${second}" == "rejected" && "${third}" == "applied" ]] \
  && pass "one bad operation does not fail the batch" \
  || fail "expected applied/rejected/applied, got ${first}/${second}/${third}"
detail "otherwise one poisoned record stops a device syncing anything at all"

# ---------------------------------------------------------------- pull

section "Pull and cursors"

result=$(call GET "/v1/sync/changes?limit=2" "${TOKEN_A}")
count=$(echo "${result}" | body_of | python3 -c "import json,sys; print(len(json.load(sys.stdin)['changes']))")
cursor=$(echo "${result}" | body_of | json_field next_cursor)
more=$(echo "${result}" | body_of | json_field has_more)
[[ "${count}" == "2" && "${more}" == "true" ]] \
  && pass "a page respects the limit and reports more" \
  || fail "expected 2 changes with has_more, got ${count}/${more}"

result=$(call GET "/v1/sync/changes?cursor=${cursor}&limit=2" "${TOKEN_A}")
next=$(echo "${result}" | body_of | json_field next_cursor)
[[ "${next}" != "${cursor}" ]] \
  && pass "the cursor advances between pages" \
  || fail "cursor did not advance from ${cursor}"

result=$(call GET "/v1/sync/changes?cursor=99999" "${TOKEN_A}")
[[ "$(echo "${result}" | status_of)" == "200" ]] \
  && pass "a cursor past the end is not an error" \
  || fail "far cursor returned $(echo "${result}" | status_of)"
detail "happens after a restore from backup; the device recovers on the next change"

result=$(call GET "/v1/sync/changes?cursor=not-a-cursor" "${TOKEN_A}")
[[ "$(echo "${result}" | status_of)" == "400" ]] \
  && pass "a malformed cursor is refused" \
  || fail "malformed cursor returned $(echo "${result}" | status_of)"

# ---------------------------------------------------------------- tenant isolation

section "Tenant isolation"

result=$(call GET /v1/sync/changes "${TOKEN_B}")
count=$(echo "${result}" | body_of | python3 -c "import json,sys; print(len(json.load(sys.stdin)['changes']))")
[[ "${count}" == "0" ]] \
  && pass "tenant B sees none of tenant A's changes" \
  || fail "tenant B saw ${count} changes belonging to tenant A"

result=$(call POST /v1/sync/deltas "${TOKEN_B}" "$(create_body op-create-1 create note 0 'tenant B work')")
status=$(echo "${result}" | body_of | json_field results.0.status)
[[ "${status}" == "applied" ]] \
  && pass "an identical operation id in another tenant is not a replay" \
  || fail "tenant B received tenant A's cached result: ${status}"
detail "a globally keyed idempotency table would disclose one tenant's response to another"

# ---------------------------------------------------------------- version gate

section "Client version gate"

status=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN_A}" \
  -H "X-Aperture-Client-Version: 0.0.1" \
  "${BASE_URL}/v1/me")
[[ "${status}" == "426" ]] \
  && pass "a client below the minimum is refused with 426" \
  || fail "old client returned ${status}"

status=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN_A}" \
  -H "X-Aperture-Client-Version: 9.9.9" \
  "${BASE_URL}/v1/me")
[[ "${status}" == "200" ]] \
  && pass "a current client passes the gate" \
  || fail "current client returned ${status}"

# ---------------------------------------------------------------- correlation

section "Diagnostics"

header=$(curl -sD - -o /dev/null -H "Authorization: Bearer ${TOKEN_A}" \
  -H 'X-Correlation-Id: scenario-run-001' "${BASE_URL}/v1/me" \
  | grep -i '^x-correlation-id' | tr -d '\r' | awk '{print $2}')
[[ "${header}" == "scenario-run-001" ]] \
  && pass "a client correlation identifier is echoed unchanged" \
  || fail "expected scenario-run-001, got '${header}'"

body=$(curl -s -H "Authorization: Bearer ${TOKEN_A}" "${BASE_URL}/v1/sync/changes?cursor=bad")
correlation=$(echo "${body}" | python3 -c "import json,sys; print(json.load(sys.stdin)['error'].get('correlation_id',''))")
[[ -n "${correlation}" ]] \
  && pass "an error envelope carries a correlation identifier" \
  || fail "error envelope had no correlation identifier"

echo
if [[ ${FAILURES} -eq 0 ]]; then
  printf "${GREEN}All API scenarios passed.${OFF}\n"
else
  printf "${RED}%d scenario(s) failed.${OFF}\n" "${FAILURES}"
  exit 1
fi
