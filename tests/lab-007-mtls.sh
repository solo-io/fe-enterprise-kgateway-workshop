# LAB: 007 — mTLS termination with gateway-level frontend validation
LAB=lab-007-mtls
source "$(dirname "$0")/lib.sh"
cleanup() {
  kubectl delete secret -n "$GW_NS" https --ignore-not-found >/dev/null 2>&1
  kubectl delete configmap -n "$GW_NS" ca-cert --ignore-not-found >/dev/null 2>&1
  restore_baseline
  cleanup_certs
}
trap cleanup EXIT

step "PKI: one root CA signing both the gateway and the client certificate"
make_ca glootest '/O=Solo.io/CN=glootest.com'
make_leaf gateway '/CN=*/O=any domain'                          glootest 0
make_leaf client  '/CN=client.glootest.com/O=client organization' glootest 1
assert_ok "the gateway certificate was created" test -s "$CERTS/gateway.crt"
assert_ok "the client certificate was created"  test -s "$CERTS/client.crt"

kubectl delete secret -n "$GW_NS" https --ignore-not-found >/dev/null 2>&1
kubectl delete configmap -n "$GW_NS" ca-cert --ignore-not-found >/dev/null 2>&1
assert_ok "the https TLS secret is created" \
  kubectl create secret tls -n "$GW_NS" https --key "$CERTS/gateway.key" --cert "$CERTS/gateway.crt"
assert_ok "the CA ConfigMap for client validation is created" \
  kubectl create configmap -n "$GW_NS" ca-cert --from-file=ca.crt="$CERTS/glootest.crt"

step "Gateway with spec.tls.frontend validation set to AllowValidOnly"
kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: ${GW_NS}
spec:
  gatewayClassName: enterprise-kgateway
  tls:
    frontend:
      default:
        validation:
          mode: AllowValidOnly
          caCertificateRefs:
            - name: ca-cert
              kind: ConfigMap
              group: ""
  listeners:
    - protocol: HTTPS
      port: 443
      name: https
      tls:
        mode: Terminate
        certificateRefs:
          - name: https
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
YAML
wait_for 90 "the mTLS listener to be Programmed" bash -c \
  "kubectl get gateway -n $GW_NS ingress -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"
wait_for_service_port 120 443
pass "the mTLS gateway is Programmed"

step "A client certificate is now mandatory"
wait_for_https 180 200 "$HOST" /get --cert "$CERTS/client.crt" --key "$CERTS/client.key"
assert_eq "a request with a trusted client certificate returns 200" 200 \
  "$(https_code "$HOST" /get -H 'content-type: application/json' \
     --cert "$CERTS/client.crt" --key "$CERTS/client.key")"
assert_eq "a request with no client certificate never reaches HTTP" 000 \
  "$(https_code "$HOST" /get -H 'content-type: application/json')"

step "A client certificate from an untrusted CA is rejected"
make_ca rogue '/O=Rogue/CN=rogue.com'
make_leaf rogue-client '/CN=client.rogue.com/O=Rogue' rogue 1
assert_eq "a certificate signed by an untrusted CA is rejected at the handshake" 000 \
  "$(https_code "$HOST" /get --cert "$CERTS/rogue-client.crt" --key "$CERTS/rogue-client.key")"
