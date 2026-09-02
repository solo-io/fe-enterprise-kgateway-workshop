# LAB: 009 — request buffer limits via EnterpriseKgatewayTrafficPolicy
LAB=lab-009-buffering
source "$(dirname "$0")/lib.sh"
trap 'kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-buffer-policy --ignore-not-found >/dev/null 2>&1' EXIT

buffer_policy() {  # buffer_policy <spec-body>
  kubectl apply -f - >/dev/null <<YAML
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-buffer-policy
  namespace: ${APP_NS}
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  buffer:
$1
YAML
}

payload() { printf '{"data":"%s"}' "$(head -c "$1" /dev/zero | tr '\0' x)"; }
SMALL=$(printf '{"message": "This is a small payload that should be accepted"}')
BOUNDARY=$(payload 950)
LARGE=$(payload 2048)

step "Set a 1Ki request buffer limit"
buffer_policy "    maxRequestSize: 1Ki"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" httpbin-buffer-policy \
  && pass "the buffer policy is Accepted" \
  || fail "the buffer policy is Accepted"
assert_eq "the policy reports Attached to the route" True \
  "$(kubectl get enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-buffer-policy \
     -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Attached")].status}' | head -c4)"

step "Requests are accepted below the limit and rejected above it"
wait_for_http 90 413 /post -H 'content-type: application/json' -d "$LARGE"
assert_eq "a 59-byte POST body is accepted" 200 \
  "$(http_code /post -H 'content-type: application/json' -d "$SMALL")"
assert_eq "a ~965-byte POST body is still under the 1Ki limit" 200 \
  "$(http_code /post -H 'content-type: application/json' -d "$BOUNDARY")"
assert_eq "a ~2Ki POST body is rejected with 413" 413 \
  "$(http_code /post -H 'content-type: application/json' -d "$LARGE")"
assert_contains "the rejection body says the payload is too large" "Payload Too Large" \
  "$(http_body /post -H 'content-type: application/json' -d "$LARGE")"

step "Raising the limit to 5Ki lets the same body through"
buffer_policy "    maxRequestSize: 5Ki"
wait_for_http 90 200 /post -H 'content-type: application/json' -d "$LARGE"
assert_eq "the ~2Ki body is accepted once the limit is 5Ki" 200 \
  "$(http_code /post -H 'content-type: application/json' -d "$LARGE")"

step "buffer.disable removes the limit entirely"
buffer_policy "    disable: {}"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" httpbin-buffer-policy \
  && pass "the disabled buffer policy is Accepted" \
  || fail "the disabled buffer policy is Accepted"
big=$(payload 65536)
wait_for_http 90 200 /post -H 'content-type: application/json' -d "$big"
assert_eq "a 64Ki body is accepted with buffering disabled" 200 \
  "$(http_code /post -H 'content-type: application/json' -d "$big")"

step "Cleanup"
kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" httpbin-buffer-policy >/dev/null 2>&1
assert_eq "no traffic policies are left in the ${APP_NS} namespace" "" \
  "$(kubectl get enterprisekgatewaytrafficpolicy -n "$APP_NS" -o name 2>/dev/null)"
