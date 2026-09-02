# LAB: 008 — per-listener mTLS CA isolation with ListenerPolicy
LAB=lab-008-multi-tenant-mtls
source "$(dirname "$0")/lib.sh"
cleanup() {
  kubectl delete listenerpolicy -n "$GW_NS" per-listener-mtls-a per-listener-mtls-b --ignore-not-found >/dev/null 2>&1
  kubectl delete httproute -n "$APP_NS" tenant-a-route tenant-b-route tenant-c-route --ignore-not-found >/dev/null 2>&1
  kubectl delete secret -n "$GW_NS" server-cert-a server-cert-b server-cert-c \
    tenant-a-ca-cert tenant-b-ca-cert gateway-ca-cert --ignore-not-found >/dev/null 2>&1
  restore_baseline
  cleanup_certs
}
trap cleanup EXIT

A=tenant-a.glootest.com
B=tenant-b.glootest.com
C=tenant-c.glootest.com

step "PKI: one server root, three independent client CAs"
make_ca glootest    '/O=Solo.io/CN=glootest.com'
make_ca tenant-a-ca '/O=TenantA/CN=tenant-a.com'
make_ca tenant-b-ca '/O=TenantB/CN=tenant-b.com'
make_ca gateway-ca  '/O=GatewayOrg/CN=gateway-ca.com'

make_leaf tenant-a-server "/CN=${A}/O=Solo.io" glootest 100
make_leaf tenant-b-server "/CN=${B}/O=Solo.io" glootest 101
make_leaf tenant-c-server "/CN=${C}/O=Solo.io" glootest 102

make_leaf client-tenant-a '/CN=client.tenant-a.com/O=TenantA'    tenant-a-ca 1
make_leaf client-tenant-b '/CN=client.tenant-b.com/O=TenantB'    tenant-b-ca 1
make_leaf client-tenant-c '/CN=client.tenant-c.com/O=GatewayOrg' gateway-ca  1
make_leaf client-invalid  '/CN=client.invalid.com/O=Invalid'      glootest    999
pass "generated server certs and four client certs across four CAs"

kubectl delete secret -n "$GW_NS" server-cert-a server-cert-b server-cert-c \
  tenant-a-ca-cert tenant-b-ca-cert gateway-ca-cert --ignore-not-found >/dev/null 2>&1
for t in a b c; do
  kubectl create secret tls -n "$GW_NS" "server-cert-$t" \
    --key "$CERTS/tenant-$t-server.key" --cert "$CERTS/tenant-$t-server.crt" >/dev/null
done
kubectl create secret generic -n "$GW_NS" tenant-a-ca-cert --from-file=ca.crt="$CERTS/tenant-a-ca.crt" >/dev/null
kubectl create secret generic -n "$GW_NS" tenant-b-ca-cert --from-file=ca.crt="$CERTS/tenant-b-ca.crt" >/dev/null
kubectl create secret generic -n "$GW_NS" gateway-ca-cert  --from-file=ca.crt="$CERTS/gateway-ca.crt"  >/dev/null
pass "created the server TLS secrets and the three CA secrets"

step "Three HTTPS listeners on port 443, one per tenant"
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
          - name: gateway-ca-cert
            kind: Secret
            group: ""
  listeners:
  - name: tenant-a-https
    protocol: HTTPS
    port: 443
    hostname: ${A}
    tls:
      mode: Terminate
      certificateRefs:
      - name: server-cert-a
    allowedRoutes:
      namespaces:
        from: All
  - name: tenant-b-https
    protocol: HTTPS
    port: 443
    hostname: ${B}
    tls:
      mode: Terminate
      certificateRefs:
      - name: server-cert-b
    allowedRoutes:
      namespaces:
        from: All
  - name: tenant-c-https
    protocol: HTTPS
    port: 443
    hostname: ${C}
    tls:
      mode: Terminate
      certificateRefs:
      - name: server-cert-c
    allowedRoutes:
      namespaces:
        from: All
YAML

wait_for_service_port 120 443

step "ListenerPolicy overrides the CA trust store per listener"
kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.kgateway.dev/v1alpha1
kind: ListenerPolicy
metadata:
  name: per-listener-mtls-a
  namespace: ${GW_NS}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ingress
    sectionName: tenant-a-https
  default:
    clientCertificateValidation:
      mode: Require
      caCertificateRefs:
      - name: tenant-a-ca-cert
        kind: Secret
        group: ""
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: ListenerPolicy
metadata:
  name: per-listener-mtls-b
  namespace: ${GW_NS}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ingress
    sectionName: tenant-b-https
  default:
    clientCertificateValidation:
      mode: Require
      caCertificateRefs:
      - name: tenant-b-ca-cert
        kind: Secret
        group: ""
YAML
wait_policy_accepted listenerpolicy "$GW_NS" per-listener-mtls-a \
  && pass "ListenerPolicy per-listener-mtls-a is Accepted" \
  || fail "ListenerPolicy per-listener-mtls-a is Accepted"
wait_policy_accepted listenerpolicy "$GW_NS" per-listener-mtls-b \
  && pass "ListenerPolicy per-listener-mtls-b is Accepted" \
  || fail "ListenerPolicy per-listener-mtls-b is Accepted"

for t in a b c; do
  host="tenant-${t}.glootest.com"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-${t}-route
  namespace: ${APP_NS}
spec:
  hostnames:
  - ${host}
  parentRefs:
  - name: ingress
    namespace: ${GW_NS}
    sectionName: tenant-${t}-https
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

step "Each tenant's own certificate is accepted"
wait_for_https 180 200 "$A" /get --cert "$CERTS/client-tenant-a.crt" --key "$CERTS/client-tenant-a.key"
assert_eq "tenant A cert on tenant A listener returns 200" 200 \
  "$(https_code "$A" /get --cert "$CERTS/client-tenant-a.crt" --key "$CERTS/client-tenant-a.key")"
assert_eq "tenant B cert on tenant B listener returns 200" 200 \
  "$(https_code "$B" /get --cert "$CERTS/client-tenant-b.crt" --key "$CERTS/client-tenant-b.key")"
assert_eq "tenant C cert on the listener inheriting the gateway CA returns 200" 200 \
  "$(https_code "$C" /get --cert "$CERTS/client-tenant-c.crt" --key "$CERTS/client-tenant-c.key")"

step "Cross-tenant certificates are rejected at the TLS handshake"
assert_eq "tenant B cert is rejected on tenant A's listener" 000 \
  "$(https_code "$A" /get --cert "$CERTS/client-tenant-b.crt" --key "$CERTS/client-tenant-b.key")"
assert_eq "tenant A cert is rejected on tenant B's listener" 000 \
  "$(https_code "$B" /get --cert "$CERTS/client-tenant-a.crt" --key "$CERTS/client-tenant-a.key")"
assert_eq "tenant A cert is rejected on tenant C's listener" 000 \
  "$(https_code "$C" /get --cert "$CERTS/client-tenant-a.crt" --key "$CERTS/client-tenant-a.key")"
assert_eq "a cert signed by the server root CA is rejected everywhere" 000 \
  "$(https_code "$A" /get --cert "$CERTS/client-invalid.crt" --key "$CERTS/client-invalid.key")"
assert_eq "no client certificate at all is rejected" 000 "$(https_code "$A" /get)"
