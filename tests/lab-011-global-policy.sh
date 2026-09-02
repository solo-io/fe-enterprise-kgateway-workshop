# LAB: 011 — global policy attachment with targetSelectors
LAB=lab-011-global-policy
source "$(dirname "$0")/lib.sh"
cleanup() {
  kubectl label httproute -n "$APP_NS" httpbin-route app- >/dev/null 2>&1
  kubectl delete httproute -n "$APP_NS" httpbin-headers-route --ignore-not-found >/dev/null 2>&1
  kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" global-timeout-policy --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

HEADERS_HOST=httpbin-headers.glootest.com

step "Label the existing route"
kubectl label --overwrite httproute -n "$APP_NS" httpbin-route app=httpbin >/dev/null
assert_eq "httpbin-route carries app=httpbin" httpbin \
  "$(kubectl get httproute -n "$APP_NS" httpbin-route -o jsonpath='{.metadata.labels.app}')"

step "A policy selected by label, not by name"
kubectl apply -f - >/dev/null <<YAML
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: global-timeout-policy
  namespace: ${APP_NS}
spec:
  targetSelectors:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      matchLabels:
        app: httpbin
  timeouts:
    request: 3s
YAML
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" global-timeout-policy \
  && pass "the label-selected policy is Accepted" \
  || fail "the label-selected policy is Accepted"

wait_for_http 90 504 /delay/5
assert_eq "a 2s delay succeeds under the 3s budget" 200 "$(http_code /delay/2 -H 'content-type: application/json')"
assert_eq "a 5s delay is cut off with 504" 504 "$(http_code /delay/5 -H 'content-type: application/json')"
assert_contains "the backend sees the 3s timeout the selector applied" '"3000"' "$(http_body /get)"

step "A brand new route with the same label picks the policy up automatically"
kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-headers-route
  namespace: ${APP_NS}
  labels:
    app: httpbin
spec:
  hostnames:
  - "${HEADERS_HOST}"
  parentRefs:
    - name: ingress
      namespace: ${GW_NS}
  rules:
    - backendRefs:
        - name: httpbin
          port: 8000
      matches:
        - path:
            type: PathPrefix
            value: /headers
YAML
wait_for 90 "the second route to serve traffic" bash -c \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${GATEWAY_IP}/headers -H 'Host: ${HEADERS_HOST}')\" = 200 ]"

headers_body=$(curl -s --max-time 20 "http://${GATEWAY_IP}/headers" -H "Host: ${HEADERS_HOST}")
assert_contains "the second route serves traffic" '"Host"' "$headers_body"
assert_contains "the second route also inherits the 3s timeout" '"3000"' "$headers_body"

# A targetSelectors policy reports the serving Gateway as its ancestor, not one
# entry per matched HTTPRoute.
assert_eq "the policy status names the serving Gateway as its ancestor" "ingress" \
  "$(kubectl get enterprisekgatewaytrafficpolicy -n "$APP_NS" global-timeout-policy \
     -o jsonpath='{.status.ancestors[*].ancestorRef.name}')"
assert_contains "the Attached condition covers every selected target" "Attached to all targets" \
  "$(kubectl get enterprisekgatewaytrafficpolicy -n "$APP_NS" global-timeout-policy \
     -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Attached")].message}')"

step "Removing the label detaches the policy"
kubectl label httproute -n "$APP_NS" httpbin-route app- >/dev/null
wait_for_http 90 200 /delay/5
assert_eq "the unlabelled route no longer has a 3s timeout" 200 "$(http_code /delay/5)"
