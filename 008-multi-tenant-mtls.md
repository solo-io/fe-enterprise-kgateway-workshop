## Multi-Tenant mTLS with Per-Listener CA Isolation

This lab demonstrates how to enforce per-listener mTLS CA isolation using `ListenerPolicy`. Each tenant listener trusts only its own CA — cross-tenant client certificates are rejected at the TLS handshake, before any HTTP routing occurs.

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`.

## Lab Objectives
- Generate PKI for three tenants
- Configure the `ingress` gateway with three HTTPS listeners on port 443
- Apply `ListenerPolicy` resources to isolate CA trust per listener
- Verify that cross-tenant client certificates are rejected at the TLS layer

## References
- [Gloo Gateway Docs - mTLS](https://docs.solo.io/gateway/latest/setup/listeners/mtls/)
- [Gloo Gateway Docs - ListenerPolicy](https://docs.solo.io/gateway/latest/reference/api/listener_policy/)

## Architecture

```
Tenant A client cert (signed by Tenant A CA)
  → port 443 / tenant-a.try-solo.io → ListenerPolicy: CA = tenant-a-ca-cert → HTTP 200 ✅
  → port 443 / tenant-b.try-solo.io → ListenerPolicy: CA = tenant-b-ca-cert → rejected ✅

Tenant B client cert (signed by Tenant B CA)
  → port 443 / tenant-b.try-solo.io → ListenerPolicy: CA = tenant-b-ca-cert → HTTP 200 ✅
  → port 443 / tenant-a.try-solo.io → ListenerPolicy: CA = tenant-a-ca-cert → rejected ✅

Tenant C client cert (signed by Gateway CA)
  → port 443 / tenant-c.try-solo.io → no ListenerPolicy → inherits gateway default CA → HTTP 200 ✅
```

All three listeners share port 443. The gateway selects the listener by SNI hostname, then the `ListenerPolicy` (if present) enforces the per-listener CA trust store.

---

## Step 1: Generate PKI Certificates

Create a working directory and generate all certificates from scratch. This makes the lab self-contained.

### Root CA for server certificates

```bash
mkdir example_certs

openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=Solo.io/CN=try-solo.io' \
  -keyout example_certs/try-solo.io.key \
  -out example_certs/try-solo.io.crt
```

### Tenant A CA

Used by `ListenerPolicy` on the `tenant-a-https` listener. Only client certs signed by this CA are accepted on that listener.

```bash
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=TenantA/CN=tenant-a.com' \
  -keyout example_certs/tenant-a-ca.key \
  -out example_certs/tenant-a-ca.crt
```

### Tenant B CA

Used by `ListenerPolicy` on the `tenant-b-https` listener. Only client certs signed by this CA are accepted on that listener.

```bash
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=TenantB/CN=tenant-b.com' \
  -keyout example_certs/tenant-b-ca.key \
  -out example_certs/tenant-b-ca.crt
```

### Gateway CA

Used as the gateway-level default. Tenant C's listener has no `ListenerPolicy` and inherits this CA.

```bash
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=GatewayOrg/CN=gateway-ca.com' \
  -keyout example_certs/gateway-ca.key \
  -out example_certs/gateway-ca.crt
```

### Server certificates (one per listener, signed by try-solo.io root)

```bash
# Tenant A server cert
openssl req -out example_certs/tenant-a-server.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/tenant-a-server.key \
  -subj "/CN=tenant-a.try-solo.io/O=Solo.io"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/try-solo.io.crt \
  -CAkey example_certs/try-solo.io.key \
  -set_serial 100 \
  -in example_certs/tenant-a-server.csr \
  -out example_certs/tenant-a-server.crt

# Tenant B server cert
openssl req -out example_certs/tenant-b-server.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/tenant-b-server.key \
  -subj "/CN=tenant-b.try-solo.io/O=Solo.io"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/try-solo.io.crt \
  -CAkey example_certs/try-solo.io.key \
  -set_serial 101 \
  -in example_certs/tenant-b-server.csr \
  -out example_certs/tenant-b-server.crt

# Tenant C server cert
openssl req -out example_certs/tenant-c-server.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/tenant-c-server.key \
  -subj "/CN=tenant-c.try-solo.io/O=Solo.io"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/try-solo.io.crt \
  -CAkey example_certs/try-solo.io.key \
  -set_serial 102 \
  -in example_certs/tenant-c-server.csr \
  -out example_certs/tenant-c-server.crt
```

### Client certificates for testing

```bash
# Tenant A client cert (signed by Tenant A CA)
openssl req -out example_certs/client-tenant-a.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/client-tenant-a.key \
  -subj "/CN=client.tenant-a.com/O=TenantA"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/tenant-a-ca.crt \
  -CAkey example_certs/tenant-a-ca.key \
  -set_serial 1 \
  -in example_certs/client-tenant-a.csr \
  -out example_certs/client-tenant-a.crt

# Tenant B client cert (signed by Tenant B CA)
openssl req -out example_certs/client-tenant-b.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/client-tenant-b.key \
  -subj "/CN=client.tenant-b.com/O=TenantB"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/tenant-b-ca.crt \
  -CAkey example_certs/tenant-b-ca.key \
  -set_serial 1 \
  -in example_certs/client-tenant-b.csr \
  -out example_certs/client-tenant-b.crt

# Tenant C client cert (signed by Gateway CA)
openssl req -out example_certs/client-tenant-c.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/client-tenant-c.key \
  -subj "/CN=client.tenant-c.com/O=GatewayOrg"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/gateway-ca.crt \
  -CAkey example_certs/gateway-ca.key \
  -set_serial 1 \
  -in example_certs/client-tenant-c.csr \
  -out example_certs/client-tenant-c.crt

# Invalid client cert (signed by try-solo.io root — not a tenant CA)
openssl req -out example_certs/client-invalid.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/client-invalid.key \
  -subj "/CN=client.invalid.com/O=Invalid"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/try-solo.io.crt \
  -CAkey example_certs/try-solo.io.key \
  -set_serial 999 \
  -in example_certs/client-invalid.csr \
  -out example_certs/client-invalid.crt
```

---

## Step 2: Create Kubernetes Secrets

All secrets are created in the `enterprise-kgateway` namespace.

### Server TLS secrets

```bash
kubectl create secret tls -n enterprise-kgateway server-cert-a \
  --key example_certs/tenant-a-server.key \
  --cert example_certs/tenant-a-server.crt

kubectl create secret tls -n enterprise-kgateway server-cert-b \
  --key example_certs/tenant-b-server.key \
  --cert example_certs/tenant-b-server.crt

kubectl create secret tls -n enterprise-kgateway server-cert-c \
  --key example_certs/tenant-c-server.key \
  --cert example_certs/tenant-c-server.crt
```

### CA secrets for ListenerPolicy and gateway default

`ListenerPolicy` references CA certs as `Secret` resources with a `ca.crt` key.

```bash
# Tenant A CA — referenced by per-listener-mtls-a
kubectl create secret generic -n enterprise-kgateway tenant-a-ca-cert \
  --from-file=ca.crt=example_certs/tenant-a-ca.crt

# Tenant B CA — referenced by per-listener-mtls-b
kubectl create secret generic -n enterprise-kgateway tenant-b-ca-cert \
  --from-file=ca.crt=example_certs/tenant-b-ca.crt

# Gateway CA — used as the gateway-level default (Tenant C inherits this)
kubectl create secret generic -n enterprise-kgateway gateway-ca-cert \
  --from-file=ca.crt=example_certs/gateway-ca.crt
```

---

## Step 3: Configure the Gateway

This replaces the existing `ingress` gateway configuration to add three HTTPS listeners. After the lab, the cleanup step restores the gateway to its original HTTP configuration.

The gateway sets a default CA (`gateway-ca-cert`) at the `spec.tls.frontend.default` level. Listeners A and B will override this with their own `ListenerPolicy`. Listener C has no `ListenerPolicy` and inherits the gateway default.

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: enterprise-kgateway
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
    hostname: tenant-a.try-solo.io
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
    hostname: tenant-b.try-solo.io
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
    hostname: tenant-c.try-solo.io
    tls:
      mode: Terminate
      certificateRefs:
      - name: server-cert-c
    allowedRoutes:
      namespaces:
        from: All
EOF
```

**Key Configuration Points:**
- `spec.tls.frontend.default`: Gateway-wide default CA (`gateway-ca-cert`) used by any listener without a `ListenerPolicy`
- `listeners[].tls.certificateRefs`: Per-listener server certificate (SNI-based selection)
- `allowedRoutes.namespaces.from: All`: Allows HTTPRoutes from the `httpbin` namespace

---

## Step 4: Apply ListenerPolicy Resources

`ListenerPolicy` overrides the gateway-level CA for a specific listener. The policy must be in the same namespace as the gateway.

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: ListenerPolicy
metadata:
  name: per-listener-mtls-a
  namespace: enterprise-kgateway
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
  namespace: enterprise-kgateway
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
EOF
```

**Note**: There is no `ListenerPolicy` for `tenant-c-https`. Listener C inherits the gateway-level default CA (`gateway-ca-cert`), so only Tenant C client certs are accepted on that listener.

---

## Step 5: Create HTTPRoutes

Routes are created in the `httpbin` namespace and attached to the appropriate listener via `sectionName`.

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-a-route
  namespace: httpbin
spec:
  hostnames:
  - tenant-a.try-solo.io
  parentRefs:
  - name: ingress
    namespace: enterprise-kgateway
    sectionName: tenant-a-https
  rules:
  - backendRefs:
    - name: httpbin
      port: 8000
    matches:
    - path:
        type: PathPrefix
        value: /
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-b-route
  namespace: httpbin
spec:
  hostnames:
  - tenant-b.try-solo.io
  parentRefs:
  - name: ingress
    namespace: enterprise-kgateway
    sectionName: tenant-b-https
  rules:
  - backendRefs:
    - name: httpbin
      port: 8000
    matches:
    - path:
        type: PathPrefix
        value: /
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-c-route
  namespace: httpbin
spec:
  hostnames:
  - tenant-c.try-solo.io
  parentRefs:
  - name: ingress
    namespace: enterprise-kgateway
    sectionName: tenant-c-https
  rules:
  - backendRefs:
    - name: httpbin
      port: 8000
    matches:
    - path:
        type: PathPrefix
        value: /
EOF
```

---

## Step 6: Testing

Get the gateway IP first:

```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway \
  --selector=gateway.networking.k8s.io/gateway-name=ingress \
  -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

echo "Gateway IP: $GATEWAY_IP"
```

### Test Summary

| # | Client Cert | Hostname (all port 443) | Expected |
|---|-------------|------------------------|----------|
| 1 | tenant-a | tenant-a.try-solo.io | HTTP 200 ✅ |
| 2 | tenant-b | tenant-b.try-solo.io | HTTP 200 ✅ |
| 3 | tenant-c | tenant-c.try-solo.io | HTTP 200 ✅ |
| 4 | tenant-a | tenant-b.try-solo.io | Connection dropped ✅ |
| 5 | tenant-b | tenant-a.try-solo.io | Connection dropped ✅ |
| 6 | invalid  | tenant-a.try-solo.io | Connection dropped ✅ |
| 7 | none     | tenant-a.try-solo.io | Connection dropped ✅ |

---

### Test 1: Tenant A — own listener (expect 200)

```bash
curl -ik --resolve "tenant-a.try-solo.io:443:$GATEWAY_IP" \
  "https://tenant-a.try-solo.io:443/get" \
  --cert example_certs/client-tenant-a.crt \
  --key example_certs/client-tenant-a.key \
  --cacert example_certs/tenant-a-server.crt
```

Expected: **HTTP 200** ✅

### Test 2: Tenant B — own listener (expect 200)

```bash
curl -ik --resolve "tenant-b.try-solo.io:443:$GATEWAY_IP" \
  "https://tenant-b.try-solo.io:443/get" \
  --cert example_certs/client-tenant-b.crt \
  --key example_certs/client-tenant-b.key \
  --cacert example_certs/tenant-b-server.crt
```

Expected: **HTTP 200** ✅

### Test 3: Tenant C — inherits gateway default CA (expect 200)

```bash
curl -ik --resolve "tenant-c.try-solo.io:443:$GATEWAY_IP" \
  "https://tenant-c.try-solo.io:443/get" \
  --cert example_certs/client-tenant-c.crt \
  --key example_certs/client-tenant-c.key \
  --cacert example_certs/tenant-c-server.crt
```

Expected: **HTTP 200** ✅

### Test 4: Tenant A cert against Tenant B listener (expect rejection)

Tenant A's CA is not trusted by the `tenant-b-https` listener.

```bash
curl -ikv --resolve "tenant-b.try-solo.io:443:$GATEWAY_IP" \
  "https://tenant-b.try-solo.io:443/get" \
  --cert example_certs/client-tenant-a.crt \
  --key example_certs/client-tenant-a.key \
  --cacert example_certs/tenant-b-server.crt
```

Expected: **connection dropped** ✅

### Test 5: Tenant B cert against Tenant A listener (expect rejection)

Tenant B's CA is not trusted by the `tenant-a-https` listener.

```bash
curl -ikv --resolve "tenant-a.try-solo.io:443:$GATEWAY_IP" \
  "https://tenant-a.try-solo.io:443/get" \
  --cert example_certs/client-tenant-b.crt \
  --key example_certs/client-tenant-b.key \
  --cacert example_certs/tenant-a-server.crt
```

Expected: **connection dropped** ✅

### Test 6: Invalid certificate (expect rejection)

The invalid cert is signed by the try-solo.io root, which is not a trusted CA on any listener.

```bash
curl -ikv --resolve "tenant-a.try-solo.io:443:$GATEWAY_IP" \
  "https://tenant-a.try-solo.io:443/get" \
  --cert example_certs/client-invalid.crt \
  --key example_certs/client-invalid.key \
  --cacert example_certs/tenant-a-server.crt
```

Expected: **connection dropped** ✅

### Test 7: No client certificate (expect rejection)

```bash
curl -ikv --resolve "tenant-a.try-solo.io:443:$GATEWAY_IP" \
  "https://tenant-a.try-solo.io:443/get" \
  --cacert example_certs/tenant-a-server.crt
```

Expected: **connection dropped** ✅

---

## Verification Checklist

- ✅ Tenant A client can access `tenant-a.try-solo.io:443`
- ✅ Tenant B client can access `tenant-b.try-solo.io:443`
- ✅ Tenant C client can access `tenant-c.try-solo.io:443` (gateway default CA)
- ✅ Tenant A client cannot access `tenant-b.try-solo.io:443`
- ✅ Tenant B client cannot access `tenant-a.try-solo.io:443`
- ✅ Invalid client certs are rejected on all listeners
- ✅ Requests without a client cert are rejected on all listeners

---

## Cleanup

Remove the lab resources and restore the `ingress` gateway to its original HTTP configuration.

```bash
kubectl delete listenerpolicy -n enterprise-kgateway per-listener-mtls-a per-listener-mtls-b
kubectl delete httproute -n httpbin tenant-a-route tenant-b-route tenant-c-route
kubectl delete secret -n enterprise-kgateway server-cert-a server-cert-b server-cert-c \
  tenant-a-ca-cert tenant-b-ca-cert gateway-ca-cert
rm -rf example_certs
```

Restore the default gateway and httpbin route:

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: enterprise-kgateway
spec:
  gatewayClassName: enterprise-kgateway
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: httpbin
spec:
  hostnames:
  - "httpbin.try-solo.io"
  parentRefs:
  - name: ingress
    namespace: enterprise-kgateway
  rules:
  - backendRefs:
    - name: httpbin
      port: 8000
    matches:
    - path:
        type: PathPrefix
        value: /
EOF
```

---

## Key Takeaways

1. **`ListenerPolicy` targets a specific listener**: Use `sectionName` to bind the policy to one listener by name
2. **Policy must be co-located with the Gateway**: `ListenerPolicy` must be in the same namespace as the Gateway it targets
3. **Inheritance**: Listeners without a `ListenerPolicy` inherit the `spec.tls.frontend.default` CA from the Gateway
4. **TLS-layer rejection**: Cross-tenant certs are rejected at the TLS handshake — no HTTP routing occurs, no application-level validation needed
