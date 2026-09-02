# LAB: 010 — request timeouts, per-try timeouts and retries
LAB=lab-010-timeouts-retries
source "$(dirname "$0")/lib.sh"
trap 'kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-timeout-policy --ignore-not-found >/dev/null 2>&1' EXIT

timeout_policy() {  # timeout_policy <spec-body>
  kubectl apply -f - >/dev/null <<YAML
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-timeout-policy
  namespace: ${APP_NS}
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
$1
YAML
}

step "A 3s request timeout"
timeout_policy "  timeouts:
    request: 3s"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" httpbin-timeout-policy \
  && pass "the timeout policy is Accepted" \
  || fail "the timeout policy is Accepted"

wait_for_http 90 504 /delay/5 -H 'content-type: application/json'
assert_eq "a 1s upstream delay completes with 200" 200 "$(http_code /delay/1 -H 'content-type: application/json')"
assert_eq "a 5s upstream delay is cut off with 504" 504 "$(http_code /delay/5 -H 'content-type: application/json')"
assert_contains "the 504 body says the upstream request timed out" "upstream request timeout" \
  "$(http_body /delay/5)"

step "Envoy advertises the effective timeout to the backend"
assert_contains "the backend sees X-Envoy-Expected-Rq-Timeout-Ms: 3000" '"3000"' \
  "$(http_body /get)"

step "The timeout is enforced at roughly the configured budget"
t0=$(date +%s); http_code /delay/10 >/dev/null; t1=$(date +%s)
elapsed=$(( t1 - t0 ))
if [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 6 ]; then
  pass "a 10s delay was cut off after ${elapsed}s (3s budget)"
else
  fail "a 10s delay was cut off after ${elapsed}s (3s budget)" "expected 2-6s"
fi

step "Retries with a per-try timeout inside a 5s overall budget"
timeout_policy "  timeouts:
    request: 5s
  retry:
    attempts: 3
    perTryTimeout: 2s
    retryOn:
      - 5xx
      - gateway-error
      - reset
      - connect-failure"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" httpbin-timeout-policy \
  && pass "the retry policy is Accepted" \
  || fail "the retry policy is Accepted"
assert_eq "the policy stores the configured retry attempts" 3 \
  "$(kubectl get enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-timeout-policy -o jsonpath='{.spec.retry.attempts}')"
assert_eq "the policy stores the per-try timeout" 2s \
  "$(kubectl get enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-timeout-policy -o jsonpath='{.spec.retry.perTryTimeout}')"

wait_for_http 90 200 /delay/1
assert_eq "a 1s delay still succeeds on the first attempt" 200 "$(http_code /delay/1)"

t0=$(date +%s)
code=$(http_code /delay/3 -H 'content-type: application/json')
t1=$(date +%s); elapsed=$(( t1 - t0 ))
assert_eq "a 3s delay exceeds the 2s per-try timeout on every attempt and ends in 504" 504 "$code"
if [ "$elapsed" -ge 3 ] && [ "$elapsed" -le 8 ]; then
  pass "retries were bounded by the 5s overall budget (took ${elapsed}s)"
else
  fail "retries were bounded by the 5s overall budget (took ${elapsed}s)" "expected 3-8s"
fi

step "Retrying on explicit status codes"
timeout_policy "  timeouts:
    request: 10s
  retry:
    attempts: 3
    perTryTimeout: 3s
    backoffBaseInterval: 100ms
    statusCodes:
      - 503
      - 504"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" httpbin-timeout-policy \
  && pass "the status-code retry policy is Accepted" \
  || fail "the status-code retry policy is Accepted"
wait_for_http 90 503 /status/503
assert_eq "a backend 503 is still surfaced as 503 after the retries are exhausted" 503 \
  "$(http_code /status/503)"

step "Stream idle timeout"
timeout_policy "  timeouts:
    request: 30s
    streamIdle: 10s"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" httpbin-timeout-policy \
  && pass "the streamIdle policy is Accepted" \
  || fail "the streamIdle policy is Accepted"
wait_for_http 90 200 /delay/5
assert_eq "a 5s delay now succeeds under the 30s budget" 200 "$(http_code /delay/5)"

step "Cleanup"
kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-timeout-policy >/dev/null 2>&1
wait_for_http 60 200 /get
assert_eq "traffic is unaffected once the policy is removed" 200 "$(http_code /get)"
