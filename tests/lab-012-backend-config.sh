# LAB: 012 — BackendConfigPolicy: upstream connection settings
LAB=lab-012-backend-config
source "$(dirname "$0")/lib.sh"
trap 'kubectl delete backendconfigpolicy -n "$APP_NS" httpbin-backend-config --ignore-not-found >/dev/null 2>&1; wait_for_http 60 200 /get >/dev/null 2>&1' EXIT

backend_policy() {  # backend_policy <commonHttpProtocolOptions-body>
  kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.kgateway.dev/v1alpha1
kind: BackendConfigPolicy
metadata:
  name: httpbin-backend-config
  namespace: ${APP_NS}
spec:
  targetRefs:
    - name: httpbin
      kind: Service
      group: ""
  commonHttpProtocolOptions:
$1
YAML
}

step "Cap the header count Envoy will accept from the backend at 10"
backend_policy "    maxHeadersCount: 10"
wait_policy_accepted backendconfigpolicy "$APP_NS" httpbin-backend-config \
  && pass "the BackendConfigPolicy is Accepted" \
  || fail "the BackendConfigPolicy is Accepted"
assert_eq "the policy reports Attached to the httpbin Service" True \
  "$(kubectl get backendconfigpolicy -n "$APP_NS" httpbin-backend-config \
     -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Attached")].status}' | head -c4)"

step "A modest response header count is fine; a flood is a protocol error"
wait_for_http 90 502 '/response-headers?H1=v1&H2=v2&H3=v3&H4=v4&H5=v5&H6=v6&H7=v7&H8=v8'
assert_eq "two extra response headers stay under the limit" 200 \
  "$(http_code '/response-headers?Custom-Header-1=value1&Custom-Header-2=value2')"
assert_eq "eight extra response headers breach the limit and yield 502" 502 \
  "$(http_code '/response-headers?H1=v1&H2=v2&H3=v3&H4=v4&H5=v5&H6=v6&H7=v7&H8=v8')"
assert_contains "the 502 explains that the upstream broke the protocol" "protocol error" \
  "$(http_body '/response-headers?H1=v1&H2=v2&H3=v3&H4=v4&H5=v5&H6=v6&H7=v7&H8=v8')"

step "Add a backend idle timeout"
backend_policy "    maxHeadersCount: 10
    idleTimeout: 30s"
wait_policy_accepted backendconfigpolicy "$APP_NS" httpbin-backend-config \
  && pass "the updated policy is Accepted" \
  || fail "the updated policy is Accepted"
assert_eq "the idle timeout is stored on the policy" 30s \
  "$(kubectl get backendconfigpolicy -n "$APP_NS" httpbin-backend-config -o jsonpath='{.spec.commonHttpProtocolOptions.idleTimeout}')"
assert_eq "the header cap is still stored on the policy" 10 \
  "$(kubectl get backendconfigpolicy -n "$APP_NS" httpbin-backend-config -o jsonpath='{.spec.commonHttpProtocolOptions.maxHeadersCount}')"

step "Envoy exposes the upstream connection stats the lab points at"
http_code /get >/dev/null
stats=$(admin_get ingress 19000 /stats)
assert_contains "upstream_cx_destroy_local is reported for the httpbin cluster" \
  "kube_httpbin_httpbin_8000.upstream_cx_destroy_local" "$stats"

step "The broader production example is schema-valid"
assert_ok "a comprehensive BackendConfigPolicy passes server-side validation" \
  kubectl apply --dry-run=server -f - <<'YAML'
apiVersion: gateway.kgateway.dev/v1alpha1
kind: BackendConfigPolicy
metadata:
  name: httpbin-backend-config-comprehensive
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin
      kind: Service
      group: ""
  commonHttpProtocolOptions:
    maxHeadersCount: 100
    idleTimeout: 5m
    maxRequestsPerConnection: 1000
  connectTimeout: 5s
  perConnectionBufferLimitBytes: 32768
YAML

step "Cleanup"
kubectl delete backendconfigpolicy -n "$APP_NS" httpbin-backend-config >/dev/null 2>&1
wait_for_http 90 200 '/response-headers?H1=v1&H2=v2&H3=v3&H4=v4&H5=v5&H6=v6&H7=v7&H8=v8'
assert_eq "the header flood is accepted again once the policy is gone" 200 \
  "$(http_code '/response-headers?H1=v1&H2=v2&H3=v3&H4=v4&H5=v5&H6=v6&H7=v7&H8=v8')"
