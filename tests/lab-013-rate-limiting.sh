# LAB: 013 — global rate limiting with RateLimitConfig + entRateLimit
LAB=lab-013-rate-limiting
source "$(dirname "$0")/lib.sh"
cleanup() {
  kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-ratelimit-policy --ignore-not-found >/dev/null 2>&1
  kubectl delete enterprisekgatewaytrafficpolicy -n "$GW_NS" gateway-ratelimit-policy --ignore-not-found >/dev/null 2>&1
  kubectl delete ratelimitconfig -n "$APP_NS" httpbin-ratelimit-config per-user-ratelimit-config \
    tiered-ratelimit-config --ignore-not-found >/dev/null 2>&1
  wait_for_http 60 200 /get >/dev/null 2>&1
}
trap cleanup EXIT

apply_ratelimit_policy() {  # apply_ratelimit_policy <configName>
  kubectl apply -f - >/dev/null <<YAML
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-ratelimit-policy
  namespace: ${APP_NS}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: httpbin-route
  entRateLimit:
    global:
      rateLimitConfigRefs:
      - name: $1
        namespace: ${APP_NS}
YAML
}

step "Rate limit service"
assert_eq "the rate-limiter deployment has a ready replica" 1 \
  "$(kubectl get deploy -n "$GW_NS" rate-limiter-enterprise-kgateway -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

step "A simple 10-requests-per-minute limit on all traffic"
kubectl apply -f - >/dev/null <<YAML
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: httpbin-ratelimit-config
  namespace: ${APP_NS}
spec:
  raw:
    descriptors:
    - key: generic_key
      value: count
      rateLimit:
        requestsPerUnit: 10
        unit: MINUTE
    rateLimits:
    - actions:
      - genericKey:
          descriptorValue: count
YAML
assert_ok "the RateLimitConfig exists" kubectl get ratelimitconfig -n "$APP_NS" httpbin-ratelimit-config

apply_ratelimit_policy httpbin-ratelimit-config
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" httpbin-ratelimit-policy \
  && pass "the rate limit traffic policy is Accepted" \
  || fail "the rate limit traffic policy is Accepted"

step "The 11th request in the minute is rejected"
# Wait for the limit to actually be enforced before counting, so the config
# rollout does not eat part of the 10-request budget.
wait_for 120 "rate limiting to take effect" bash -c \
  "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
     c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${GATEWAY_IP}/get -H 'Host: ${HOST}')
     [ \"\$c\" = 429 ] && exit 0
   done; exit 1"
pass "requests start returning 429 once the limit is exceeded"

hdrs=$(http_headers /get)
assert_contains "the rejected response is marked x-envoy-ratelimited" "x-envoy-ratelimited" "$hdrs"
assert_eq "a further request in the same window is also limited" 429 "$(http_code /get)"

step "Per-user limits give each header value its own bucket"
kubectl apply -f - >/dev/null <<YAML
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: per-user-ratelimit-config
  namespace: ${APP_NS}
spec:
  raw:
    descriptors:
    - key: user_id
      rateLimit:
        requestsPerUnit: 5
        unit: MINUTE
    rateLimits:
    - actions:
      - requestHeaders:
          descriptorKey: user_id
          headerName: x-user-id
YAML
apply_ratelimit_policy per-user-ratelimit-config

# Fresh user ids per run, so a re-run is not blocked by the previous minute.
ALICE="alice-$RANDOM"
BOB="bob-$RANDOM"

wait_for 120 "the per-user config to take effect" bash -c \
  "probe=probe-\$RANDOM
   for i in 1 2 3 4 5 6 7; do
     c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${GATEWAY_IP}/get -H 'Host: ${HOST}' -H \"x-user-id: \$probe\")
     [ \"\$c\" = 429 ] && exit 0
   done; exit 1"
pass "the per-user rate limit config is live"

alice_codes=""
for i in 1 2 3 4 5 6; do
  alice_codes="$alice_codes$(http_code /get -H "x-user-id: ${ALICE}") "
done
assert_eq "alice's first five requests succeed and the sixth is limited" \
  "200 200 200 200 200 429 " "$alice_codes"

bob_codes=""
for i in 1 2 3; do
  bob_codes="$bob_codes$(http_code /get -H "x-user-id: ${BOB}") "
done
assert_eq "bob has an independent bucket and is not affected by alice" "200 200 200 " "$bob_codes"

step "Tiered descriptors and gateway-level attachment are schema-valid"
assert_ok "a two-tier RateLimitConfig is accepted by the API server" \
  kubectl apply -f - <<'YAML'
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: tiered-ratelimit-config
  namespace: httpbin
spec:
  raw:
    descriptors:
    - key: generic_key
      value: global
      rateLimit:
        requestsPerUnit: 100
        unit: MINUTE
    - key: generic_key
      value: global
      descriptors:
      - key: user_id
        rateLimit:
          requestsPerUnit: 10
          unit: MINUTE
    rateLimits:
    - actions:
      - genericKey:
          descriptorValue: global
      - requestHeaders:
          descriptorKey: user_id
          headerName: x-user-id
YAML

kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-ratelimit-policy >/dev/null 2>&1
kubectl apply -f - >/dev/null <<YAML
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: gateway-ratelimit-policy
  namespace: ${GW_NS}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ingress
  entRateLimit:
    global:
      rateLimitConfigRefs:
      - name: httpbin-ratelimit-config
        namespace: ${APP_NS}
YAML
wait_policy_accepted enterprisekgatewaytrafficpolicy "$GW_NS" gateway-ratelimit-policy \
  && pass "a gateway-level rate limit policy is Accepted" \
  || fail "a gateway-level rate limit policy is Accepted"
kubectl delete enterprisekgatewaytrafficpolicy -n "$GW_NS" gateway-ratelimit-policy >/dev/null 2>&1

step "Cleanup restores unlimited traffic"
kubectl delete ratelimitconfig -n "$APP_NS" httpbin-ratelimit-config per-user-ratelimit-config \
  tiered-ratelimit-config >/dev/null 2>&1
wait_for_http 120 200 /get
codes=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do codes="$codes$(http_code /get) "; done
assert_not_contains "no request is rate limited once the policies are gone" 429 "$codes"
