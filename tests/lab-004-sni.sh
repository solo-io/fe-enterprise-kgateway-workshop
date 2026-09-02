# LAB: 004 — SNI matching: two domains, two certs, one port
LAB=lab-004-sni
source "$(dirname "$0")/lib.sh"
cleanup() {
  kubectl delete httproute -n "$APP_NS" httpbin-foo-route httpbin-bar-route httpbin-baz-route --ignore-not-found >/dev/null 2>&1
  kubectl delete secret -n "$GW_NS" foo bar --ignore-not-found >/dev/null 2>&1
  restore_baseline
  cleanup_certs
}
trap cleanup EXIT

FOO=httpbin-foo.glootest.com
BAR=httpbin-bar.glootest.com
BAZ=httpbin-baz.glootest.com

step "Generate a root CA and two hostname-specific server certs"
make_ca glootest '/O=Solo.io/CN=glootest.com'
make_leaf foo "/CN=${FOO}/O=httpbin organization" glootest 0
make_leaf bar "/CN=${BAR}/O=solo.io"              glootest 1
assert_contains "the foo certificate is issued for ${FOO}" "CN=${FOO}" "$(cert_subject "$CERTS/foo.crt")"
assert_contains "the bar certificate is issued for ${BAR}" "CN=${BAR}" "$(cert_subject "$CERTS/bar.crt")"

kubectl delete secret -n "$GW_NS" foo bar --ignore-not-found >/dev/null 2>&1
assert_ok "kubectl creates the foo TLS secret" kubectl create -n "$GW_NS" secret tls foo --key="$CERTS/foo.key" --cert="$CERTS/foo.crt"
assert_ok "kubectl creates the bar TLS secret" kubectl create -n "$GW_NS" secret tls bar --key="$CERTS/bar.key" --cert="$CERTS/bar.crt"

step "Two HTTPS listeners on port 443, selected by SNI hostname"
kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: ${GW_NS}
spec:
  gatewayClassName: enterprise-kgateway
  listeners:
    - protocol: HTTPS
      port: 443
      name: foo
      hostname: ${FOO}
      tls:
        mode: Terminate
        certificateRefs:
          - name: foo
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
    - protocol: HTTPS
      port: 443
      name: bar
      hostname: "${BAR}"
      tls:
        mode: Terminate
        certificateRefs:
          - name: bar
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
YAML
wait_for 90 "both listeners to be Programmed" bash -c \
  "kubectl get gateway -n $GW_NS ingress -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"
wait_for_service_port 120 443

for h in foo bar baz; do
  hostname_var="httpbin-${h}.glootest.com"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-${h}-route
  namespace: ${APP_NS}
spec:
  hostnames:
  - "${hostname_var}"
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
            value: /
YAML
done

step "Each hostname gets its own certificate"
wait_for_https 180 200 "$FOO" /get
assert_eq "HTTPS to ${FOO} returns 200" 200 "$(https_code "$FOO" /get)"
assert_eq "HTTPS to ${BAR} returns 200" 200 "$(https_code "$BAR" /get)"

for h in "$FOO" "$BAR"; do
  echo | openssl s_client -connect "${GATEWAY_IP}:443" -servername "$h" 2>/dev/null \
    | openssl x509 -out "$CERTS/served-$h.crt" 2>/dev/null
done
assert_contains "SNI ${FOO} is served the foo certificate" "CN=${FOO}" "$(cert_subject "$CERTS/served-$FOO.crt")"
assert_contains "SNI ${BAR} is served the bar certificate" "CN=${BAR}" "$(cert_subject "$CERTS/served-$BAR.crt")"

step "A host with a route but no matching listener fails at the TLS layer"
baz_code=$(https_code "$BAZ" /get)
assert_eq "HTTPS to ${BAZ} never reaches HTTP" 000 "$baz_code"
assert_ok "the ${BAZ} TLS handshake is rejected by the gateway" \
  test "$(https_exit "$BAZ" /get)" -ne 0
