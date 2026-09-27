#!/usr/bin/env bash
# Exercises the rate limiter against a running service and asserts the outcome.
#
#   make api-up-limited && make ratelimit-scenarios
#
# Needs the service started with a limit in place. Without one every request is allowed and
# the assertions below would all fail for a reason that has nothing to do with the limiter.
set -uo pipefail

cd "$(dirname "$0")/.."

BASE_URL="${BASE_URL:-http://localhost:8080}"
METRICS_URL="${METRICS_URL:-http://localhost:9090/metrics}"
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
    echo "devtoken binary missing. Run: make api-build" >&2; exit 1
  fi
  if ! curl -sf "${BASE_URL}/healthz" >/dev/null; then
    echo "service is not answering at ${BASE_URL}. Run: make api-up-limited" >&2; exit 1
  fi
  if ! grep -q "rate limiting enabled" "${DEV_DIR}/aperture.log" 2>/dev/null; then
    echo "The running service has rate limiting disabled." >&2
    echo "Every request would be allowed and every assertion below would fail for the" >&2
    echo "wrong reason. Restart with:" >&2
    echo "  make api-down && make api-up-limited" >&2
    exit 1
  fi
}

status_for() {
  local token="$1"
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" "${BASE_URL}/v1/me"
}

# Sends requests until one is refused, printing how many were allowed. Bounded so a
# misconfigured limit cannot loop forever.
exhaust() {
  local token="$1" allowed=0
  for _ in $(seq 1 40); do
    if [[ "$(status_for "${token}")" == "200" ]]; then
      allowed=$((allowed + 1))
    else
      break
    fi
  done
  echo "${allowed}"
}

metric_value() {
  curl -s "${METRICS_URL}" | python3 -c "
import sys
needle = sys.argv[1]
for line in sys.stdin:
    name, _, value = line.strip().rpartition(' ')
    if name == needle:
        print(value); raise SystemExit
print('0')
" "$1"
}

require

TOKEN_A=$("${DEVTOKEN}" mint -key "${KEY}" -tenant "${TENANT_A}" -subject "${DANA}")
TOKEN_B=$("${DEVTOKEN}" mint -key "${KEY}" -tenant "${TENANT_B}" -subject "${MARCUS}")

configured=$(grep -o 'per_second":[0-9.]*' "${DEV_DIR}/aperture.log" | tail -1 | cut -d: -f2)
detail "service reports ${configured:-unknown} requests per second per tenant"

# ---------------------------------------------------------------- the budget

section "The budget"

allowed=$(exhaust "${TOKEN_A}")
[[ "${allowed}" -ge 1 ]] \
  && pass "the first ${allowed} request(s) were allowed" \
  || fail "nothing was allowed; the burst may be zero"

[[ "${allowed}" -lt 40 ]] \
  && pass "requests are refused once the budget is spent" \
  || fail "40 requests passed; the limiter is not engaging"
detail "a full bucket at startup is deliberate: a device's first request after a restart"
detail "is the one it has the most to send"

# ---------------------------------------------------------------- the refusal

section "What a refusal tells the client"

# Drained immediately before, for the same reason as the recovery section: relying on the
# previous section to have left the bucket empty makes the assertion depend on how long
# that section took.
exhaust "${TOKEN_A}" > /dev/null

response=$(curl -s -D /tmp/rl_headers -H "Authorization: Bearer ${TOKEN_A}" "${BASE_URL}/v1/me")
status=$(grep -i '^HTTP/' /tmp/rl_headers | tail -1 | awk '{print $2}')

[[ "${status}" == "429" ]] \
  && pass "a refused request returns 429" \
  || fail "expected 429, got ${status}"

retry_after=$(grep -i '^retry-after:' /tmp/rl_headers | tr -d '\r' | awk '{print $2}')
if [[ -n "${retry_after}" ]] && [[ "${retry_after}" -ge 1 ]]; then
  pass "Retry-After is present and at least one second"
else
  fail "Retry-After was '${retry_after}'"
fi
detail "RFC 9110 has no sub-second form, so rounding down would advertise a moment"
detail "that is still too early"

echo "${response}" | python3 -c "
import json, sys
try:
    body = json.load(sys.stdin)
except Exception as error:
    print('NOTJSON'); raise SystemExit
error = body.get('error', {})
print(error.get('code'), error.get('retryable'), error.get('details', {}).get('retry_after_seconds'))
" > /tmp/rl_body

read -r code retryable seconds < /tmp/rl_body

[[ "${code}" == "RATE_LIMITED" ]] \
  && pass "the body uses the standard error envelope" \
  || fail "code was '${code}'"

[[ "${retryable}" == "True" ]] \
  && pass "the refusal is marked retryable" \
  || fail "retryable was '${retryable}'"
detail "the sync engine dead-letters permanent rejections; a throttle that looked"
detail "permanent would make a device discard work it should simply resend"

[[ -n "${seconds}" && "${seconds}" != "None" ]] \
  && pass "the envelope carries the retry delay as well as the header" \
  || fail "details.retry_after_seconds was '${seconds}'"

# ---------------------------------------------------------------- isolation

section "Tenant isolation"

# Both halves are asserted. Checking only that tenant B succeeds would pass even if nothing
# were throttled at all, which makes the test weaker than its name claims: it has to be
# true that A is refused at the same moment B is served.
exhaust "${TOKEN_A}" > /dev/null

noisy=$(status_for "${TOKEN_A}")
quiet=$(status_for "${TOKEN_B}")

[[ "${noisy}" == "429" ]] \
  && pass "tenant A is throttled" \
  || fail "tenant A was not throttled (${noisy}), so the next check proves nothing"

[[ "${quiet}" == "200" ]] \
  && pass "tenant B is served at the same moment" \
  || fail "tenant B was refused (${quiet}) because tenant A was noisy"
detail "keying on the address instead would throttle a whole crew behind one carrier NAT"

# ---------------------------------------------------------------- recovery

section "Recovery"

# Drained here rather than relying on the earlier sections having left it empty.
#
# The first version assumed tenant A was still exhausted from three sections back. At two
# tokens per second, the JSON parsing in between accrued one, so the check read 200 and
# failed for a reason that had nothing to do with recovery. A scenario that depends on how
# long the previous scenario took is a scenario that fails on a slow morning.
exhaust "${TOKEN_A}" > /dev/null

refused=$(status_for "${TOKEN_A}")
[[ "${refused}" == "429" ]] \
  && pass "the bucket is empty immediately after being drained" \
  || fail "expected 429 straight after draining, got ${refused}"

sleep 3
recovered=$(status_for "${TOKEN_A}")

[[ "${recovered}" == "200" ]] \
  && pass "the bucket refills and the tenant recovers" \
  || fail "still ${recovered} after three seconds"
detail "tokens accrue continuously rather than on a timer, so a fleet retrying in"
detail "lockstep does not all land on the same tick"

# ---------------------------------------------------------------- metrics

section "Metrics"

throttled=$(metric_value 'aperture_http_throttled_total{route="/v1/me"}')
python3 -c "import sys; sys.exit(0 if float('${throttled}') >= 1 else 1)" \
  && pass "refusals are counted, by route" \
  || fail "the throttle counter reads ${throttled}"

if curl -s "${METRICS_URL}" | grep -q "aperture_http_throttled_total.*${TENANT_A}"; then
  fail "the throttle counter is labelled by tenant"
else
  pass "the throttle counter carries no tenant label"
fi
detail "tenant identifiers are unbounded, and this counter rises fastest exactly when"
detail "the system is already under strain"

series=$(curl -s "${METRICS_URL}" | grep -c '^aperture_http_throttled_total{')
[[ "${series}" -lt 10 ]] \
  && pass "the throttle metric has ${series} series" \
  || fail "the throttle metric has ${series} series; cardinality is not bounded"

echo
if [[ ${FAILURES} -eq 0 ]]; then
  printf "${GREEN}All rate limit scenarios passed.${OFF}\n"
else
  printf "${RED}%d scenario(s) failed.${OFF}\n" "${FAILURES}"
  exit 1
fi
