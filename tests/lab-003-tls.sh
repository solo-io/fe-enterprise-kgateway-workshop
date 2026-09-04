# LAB: 003 — TLS termination on the gateway
LAB=lab-003-tls
source "$(dirname "$0")/lib.sh"
trap 'kubectl delete secret -n "$GW_NS" https --ignore-not-found >/dev/null 2>&1; restore_baseline; cleanup_certs' EXIT

step "Create a self-signed server certificate"
make_ca root '/O=any domain/CN=*'
cat > "$CERTS/gateway.cnf" <<'CNF'
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[ dn ]
CN = *.try-solo.io
O = any domain

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = *.try-solo.io
DNS.2 = try-solo.io
CNF
make_leaf gateway '' root 0 "$CERTS/gateway.cnf"
assert_ok "openssl produced a gateway certificate" test -s "$CERTS/gateway.crt"
assert_contains "the certificate carries the *.try-solo.io SAN" "DNS:*.try-solo.io" \
  "$(openssl x509 -in "$CERTS/gateway.crt" -noout -text 2>/dev/null)"

kubectl delete secret -n "$GW_NS" https --ignore-not-found >/dev/null 2>&1
assert_ok "kubectl creates the https TLS secret" \
  kubectl create secret tls -n "$GW_NS" https --key "$CERTS/gateway.key" --cert "$CERTS/gateway.crt"

step "Replace the HTTP listener with an HTTPS listener"
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
wait_for 90 "the https listener to be Programmed" bash -c \
  "kubectl get gateway -n $GW_NS ingress -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"
wait_for_service_port 120 443
assert_eq "the gateway service now publishes port 443" 443 \
  "$(kubectl get svc -n "$GW_NS" ingress -o jsonpath='{.spec.ports[0].port}')"

step "HTTPS succeeds, plain HTTP no longer has a listener"
wait_for_https 180 200 "$HOST" /get
assert_eq "HTTPS GET /get returns 200" 200 "$(https_code "$HOST" /get -H 'content-type: application/json')"
assert_eq "plain HTTP on port 80 no longer connects" 000 "$(http_code /get)"

step "The gateway presents the certificate we supplied"
echo | openssl s_client -connect "${GATEWAY_IP}:443" -servername "$HOST" 2>/dev/null \
  | openssl x509 -out "$CERTS/served.crt" 2>/dev/null
assert_contains "the served leaf certificate is the *.try-solo.io cert" 'CN=*.try-solo.io' \
  "$(cert_subject "$CERTS/served.crt")"
