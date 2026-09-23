#!/usr/bin/env bash
# Drives traffic and asserts the metrics moved the way they should.
#
#   make metrics-scenarios
#
# Requires the service running with token verification enabled (`make api-up` or
# `make api-up-postgres`) and the development key that minted its tokens.
set -uo pipefail

cd "$(dirname "$0")/.."

BASE_URL="${BASE_URL:-http://localhost:8080}"
METRICS_URL="${METRICS_URL:-http://localhost:9090/metrics}"
DEV_DIR="${DEV_DIR:-$(pwd)/.dev}"
KEY="${DEV_DIR}/dev-key.pem"
DEVTOKEN="${DEV_DIR}/devtoken"

TENANT_A="11111111-1111-4111-a111-111111111111"
DANA="00uDANA0001"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[1;34m'; DIM=$'\033[2m'; OFF=$'\033[0m'
FAILURES=0

section() { printf "\n${BLUE}==>${OFF} %s\n" "$*"; }
pass()    { printf "  ${GREEN}pass${OFF}  %s\n" "$*"; }
fail()    { printf "  ${RED}FAIL${OFF}  %s\n" "$*"; FAILURES=$((FAILURES + 1)); }
detail()  { printf "        ${DIM}%s${OFF}\n" "$*"; }

require() {
  if [[ ! -x "${DEVTOKEN}" ]]; then
    echo "devtoken binary missing. Run: make api-build" >&2; exit 1
  fi
  if ! curl -sf "${BASE_URL}/healthz" >/dev/null; then
    echo "service is not answering at ${BASE_URL}. Run: make api-up" >&2; exit 1
  fi
  if ! curl -sf "${METRICS_URL}" >/dev/null; then
    echo "metrics endpoint is not answering at ${METRICS_URL}." >&2
    echo "It listens on 127.0.0.1:9090 by default; set APERTURE_METRICS_ADDR to change it," >&2
    echo "or empty to disable it." >&2
    exit 1
  fi
}

# Reads one series value. Absent series read as zero, which is correct: a counter that has
# never been incremented is not exported at all, and treating that as an error would make
# every first-run assertion fail.
value_of() {
  local series="$1"
  curl -s "${METRICS_URL}" | python3 -c "
import sys
needle = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if line.startswith('#') or not line:
        continue
    name, _, value = line.rpartition(' ')
    if name == needle:
        print(value); raise SystemExit
print('0')
" "${series}"
}

require

TOKEN=$("${DEVTOKEN}" mint -key "${KEY}" -tenant "${TENANT_A}" -subject "${DANA}")

# ---------------------------------------------------------------- exposition format

section "Exposition format"

body=$(curl -s "${METRICS_URL}")

echo "${body}" | grep -q '^# HELP ' \
  && pass "HELP lines are present" || fail "no HELP lines"
echo "${body}" | grep -q '^# TYPE ' \
  && pass "TYPE lines are present" || fail "no TYPE lines"

content_type=$(curl -sI "${METRICS_URL}" | grep -i '^content-type' | tr -d '\r')
echo "${content_type}" | grep -qi 'text/plain' \
  && pass "content type is the exposition format" || fail "unexpected: ${content_type}"

first=$(curl -s "${METRICS_URL}")
second=$(curl -s "${METRICS_URL}")
[[ "${first}" == "${second}" ]] \
  && pass "output is byte-identical between scrapes" \
  || fail "output reordered between scrapes"
detail "Go randomises map iteration; unsorted output makes every diff unreadable"

# ---------------------------------------------------------------- request counters

section "Request counters"

before=$(value_of 'aperture_http_requests_total{method="GET",route="/v1/me",status="200"}')
for _ in 1 2 3; do
  curl -s -o /dev/null -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/v1/me"
done
after=$(value_of 'aperture_http_requests_total{method="GET",route="/v1/me",status="200"}')

moved=$(python3 -c "print(int(float('${after}') - float('${before}')))")
[[ "${moved}" == "3" ]] \
  && pass "three successful requests counted three times" \
  || fail "counter moved by ${moved}, expected 3"

before=$(value_of 'aperture_http_requests_total{method="GET",route="/v1/me",status="401"}')
curl -s -o /dev/null "${BASE_URL}/v1/me"
after=$(value_of 'aperture_http_requests_total{method="GET",route="/v1/me",status="401"}')

moved=$(python3 -c "print(int(float('${after}') - float('${before}')))")
[[ "${moved}" == "1" ]] \
  && pass "a rejected request is counted too" \
  || fail "unauthenticated counter moved by ${moved}, expected 1"
detail "the middleware sits outside authentication, so an auth outage is visible"

# ---------------------------------------------------------------- cardinality

section "Cardinality control"

before=$(value_of 'aperture_http_requests_total{method="GET",route="other",status="404"}')

# Fifty distinct paths a caller invented. Each would be its own time series if the route
# label came from the path.
for i in $(seq 1 50); do
  curl -s -o /dev/null "${BASE_URL}/v1/attacker/controlled/path-${i}"
done

after=$(value_of 'aperture_http_requests_total{method="GET",route="other",status="404"}')
moved=$(python3 -c "print(int(float('${after}') - float('${before}')))")

[[ "${moved}" == "50" ]] \
  && pass "fifty invented paths collapsed into one series" \
  || fail "the 'other' series moved by ${moved}, expected 50"

series_count=$(curl -s "${METRICS_URL}" | grep -c '^aperture_http_requests_total{')
[[ "${series_count}" -lt 20 ]] \
  && pass "the request counter has ${series_count} series, not fifty-something" \
  || fail "series count is ${series_count}; cardinality is not bounded"
detail "one series per entity id is how a monitoring system dies during an incident"

# ---------------------------------------------------------------- latency histogram

section "Latency histogram"

body=$(curl -s "${METRICS_URL}")

echo "${body}" | grep -q 'aperture_http_request_duration_seconds_bucket{.*le="+Inf"}' \
  && pass "the +Inf bucket is present" \
  || fail "the +Inf bucket is missing, so quantiles cannot be computed"

echo "${body}" | grep -q 'aperture_http_request_duration_seconds_bucket{.*le="0.3"' \
  && pass "a bucket boundary sits at the 300ms objective" \
  || fail "no boundary at the objective; compliance cannot be measured"

echo "${body}" | grep 'aperture_http_request_duration_seconds' | grep -q 'status=' \
  && fail "duration is labelled by status" \
  || pass "duration is not labelled by status"
detail "mixing them means fast failures improve the quantile during an incident"

# ---------------------------------------------------------------- auth failures

section "Authentication failures, by reason"

before_expired=$(value_of 'aperture_auth_failures_total{reason="expired"}')
before_missing=$(value_of 'aperture_auth_failures_total{reason="missing"}')

expired=$("${DEVTOKEN}" mint -key "${KEY}" -tenant "${TENANT_A}" -subject "${DANA}" -ttl -5m)
curl -s -o /dev/null -H "Authorization: Bearer ${expired}" "${BASE_URL}/v1/me"
curl -s -o /dev/null "${BASE_URL}/v1/me"

after_expired=$(value_of 'aperture_auth_failures_total{reason="expired"}')
after_missing=$(value_of 'aperture_auth_failures_total{reason="missing"}')

[[ "$(python3 -c "print(int(float('${after_expired}') - float('${before_expired}')))")" == "1" ]] \
  && pass "an expired token is counted as 'expired'" \
  || fail "the expired counter did not move"

[[ "$(python3 -c "print(int(float('${after_missing}') - float('${before_missing}')))")" == "1" ]] \
  && pass "a missing token is counted as 'missing'" \
  || fail "the missing counter did not move"

detail "the caller is told neither; this counter is where the distinction survives"
detail "a spike in 'expired' is a clock problem, in 'bad_signature' a rotation or an attack"

# ---------------------------------------------------------------- sync outcomes

section "Sync outcomes"

# Unique per run, both of them.
#
# Idempotency is keyed by tenant and operation id, not by entity, so a fixed operation id
# replays on the second run against a persistent store: the first push returns `replayed`
# rather than `applied` and the assertions below fail for a reason that has nothing to do
# with the service. Making the entity unique was not enough.
run_id="$(date +%s)-$$"
entity="f-metrics-${run_id}"
push() {
  curl -s -o /dev/null -X POST "${BASE_URL}/v1/sync/deltas" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"operations\":[{\"operation_id\":\"$1\",\"entity_type\":\"finding\",
         \"entity_id\":\"${entity}\",\"kind\":\"$2\",\"dirty_fields\":[\"$3\"],
         \"base_version\":$4,\"hlc\":\"h\",\"payload\":{\"$3\":\"v\"}}]}"
}

before_applied=$(value_of 'aperture_sync_operations_total{status="applied"}')
before_replayed=$(value_of 'aperture_sync_operations_total{status="replayed"}')
before_conflict=$(value_of 'aperture_sync_conflicts_total{field="measurement_value"}')

push "mx-1-${run_id}" create measurement_value 0
push "mx-1-${run_id}" create measurement_value 0
push "mx-2-${run_id}" update measurement_value 0

after_applied=$(value_of 'aperture_sync_operations_total{status="applied"}')
after_replayed=$(value_of 'aperture_sync_operations_total{status="replayed"}')
after_conflict=$(value_of 'aperture_sync_conflicts_total{field="measurement_value"}')

[[ "$(python3 -c "print(int(float('${after_applied}') - float('${before_applied}')))")" == "1" ]] \
  && pass "one apply counted" || fail "applied counter did not move by 1"

[[ "$(python3 -c "print(int(float('${after_replayed}') - float('${before_replayed}')))")" == "1" ]] \
  && pass "one replay counted separately from applies" \
  || fail "replayed counter did not move by 1"
detail "a rising replay rate is a client retry storm; folding it into applies hides it"

[[ "$(python3 -c "print(int(float('${after_conflict}') - float('${before_conflict}')))")" == "1" ]] \
  && pass "the conflict is attributed to measurement_value" \
  || fail "conflict counter did not move by 1"
detail "attribution matters: disagreement over a number is worth paging about"

# ---------------------------------------------------------------- exposure

section "Exposure"

if curl -sf --max-time 3 "${BASE_URL}/metrics" >/dev/null 2>&1; then
  fail "the metrics endpoint is reachable on the public listener"
else
  pass "metrics are not served from the API listener"
fi
detail "volumes and error rates are competitive intelligence about a customer"

echo
if [[ ${FAILURES} -eq 0 ]]; then
  printf "${GREEN}All metrics scenarios passed.${OFF}\n"
else
  printf "${RED}%d scenario(s) failed.${OFF}\n" "${FAILURES}"
  exit 1
fi
