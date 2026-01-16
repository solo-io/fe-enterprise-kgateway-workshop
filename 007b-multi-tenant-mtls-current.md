## Multi-Tenant mTLS with SNI Matching (Current Implementation)

> **Note**: This exercise shows what ACTUALLY WORKS with the current Enterprise Kgateway API. Due to API limitations, true per-listener mTLS CA isolation is not supported.

This guide demonstrates multi-tenant mTLS with SNI matching using the current API. While SNI-based routing works perfectly, all listeners share a common CA trust pool for mTLS validation.

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Create separate CA certificates for multiple tenants
- Configure gateway with SNI-based listener selection
- Apply gateway-level mTLS validation
- Understand current API limitations for tenant isolation

## References
- [Gloo Gateway Docs - SNI](https://docs.solo.io/gateway/latest/setup/listeners/sni/)
- [Gloo Gateway Docs - Frontend TLS](https://docs.solo.io/gateway/latest/setup/listeners/mtls/)

## Current API Limitation

**The current Gateway API does not support per-listener CA isolation for mTLS validation.**

The `spec.tls.frontend.default` configuration applies to ALL listeners on the gateway. This means:
- ✅ SNI-based routing works (different certs per hostname)
- ✅ mTLS validation works (client certs must be trusted)
- ✅ Multiple CA certificates can be referenced
- ❌ Cannot use different CA certificates per listener
- ⚠️ All tenant CAs are trusted by all listeners (combined trust pool)

## Architecture (Current Limitations)
```
┌─────────────┐                    ┌──────────────────────────────┐
│  Tenant A   │──mtls─────────────▶│  tenant-a.glootest.com:443   │
│  (CA-A)     │   (validates w/     │  Listener                    │
└─────────────┘    CA-A OR CA-B)   │  (uses combined CA pool)     │
                                   │  ✅ TenantA cert accepted    │
┌─────────────┐                    │  ⚠️ TenantB cert also works │
│  Tenant B   │──mtls─────────────▶│                              │
│  (CA-B)     │   (validates w/     │  tenant-b.glootest.com:443   │
└─────────────┘    CA-A OR CA-B)   │  Listener                    │
                                   │  (uses combined CA pool)     │
                                   │  ⚠️ TenantA cert also works │
                                   │  ✅ TenantB cert accepted    │
                                   └──────────────────────────────┘
```

**Result**: Tenant A's certificate can access Tenant B's endpoint and vice versa. True tenant isolation requires application-level validation.

## Step 1: Create Root CA for Gateway Certificates

Create a root CA for signing the gateway's server certificates:
```bash
mkdir example_certs
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=Solo.io/CN=glootest.com' \
  -keyout example_certs/glootest.com.key \
  -out example_certs/glootest.com.crt
```

## Step 2: Create Tenant-Specific CA Certificates

Each tenant gets their own Certificate Authority for issuing client certificates:

### Tenant A CA
```bash
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=TenantA/CN=tenant-a.com' \
  -keyout example_certs/tenant-a-ca.key \
  -out example_certs/tenant-a-ca.crt
```

### Tenant B CA
```bash
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -subj '/O=TenantB/CN=tenant-b.com' \
  -keyout example_certs/tenant-b-ca.key \
  -out example_certs/tenant-b-ca.crt
```

## Step 3: Create Gateway Server Certificates

Create TLS certificates for the gateway listeners (one per tenant hostname):

### Gateway certificate for Tenant A
```bash
openssl req -out example_certs/tenant-a-gateway.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/tenant-a-gateway.key \
  -subj "/CN=tenant-a.glootest.com/O=gateway"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/glootest.com.crt \
  -CAkey example_certs/glootest.com.key \
  -set_serial 100 \
  -in example_certs/tenant-a-gateway.csr \
  -out example_certs/tenant-a-gateway.crt
```

### Gateway certificate for Tenant B
```bash
openssl req -out example_certs/tenant-b-gateway.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/tenant-b-gateway.key \
  -subj "/CN=tenant-b.glootest.com/O=gateway"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/glootest.com.crt \
  -CAkey example_certs/glootest.com.key \
  -set_serial 101 \
  -in example_certs/tenant-b-gateway.csr \
  -out example_certs/tenant-b-gateway.crt
```

## Step 4: Create Client Certificates for Each Tenant

### Tenant A Client Certificate
Signed by Tenant A's CA:
```bash
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
```

### Tenant B Client Certificate
Signed by Tenant B's CA:
```bash
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
```

### Create an Invalid Client Certificate
This client cert is signed by the root CA (not a tenant CA) and should be rejected:
```bash
openssl req -out example_certs/client-invalid.csr \
  -newkey rsa:2048 -nodes \
  -keyout example_certs/client-invalid.key \
  -subj "/CN=client.invalid.com/O=Invalid"

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/glootest.com.crt \
  -CAkey example_certs/glootest.com.key \
  -set_serial 999 \
  -in example_certs/client-invalid.csr \
  -out example_certs/client-invalid.crt
```

## Step 5: Create Kubernetes Secrets and ConfigMaps

### Gateway TLS Secrets
```bash
kubectl create secret tls -n enterprise-kgateway tenant-a-tls \
  --key example_certs/tenant-a-gateway.key \
  --cert example_certs/tenant-a-gateway.crt

kubectl create secret tls -n enterprise-kgateway tenant-b-tls \
  --key example_certs/tenant-b-gateway.key \
  --cert example_certs/tenant-b-gateway.crt
```

### Tenant CA ConfigMaps for mTLS Validation
Create separate ConfigMaps for each tenant CA:

```bash
# Create ConfigMap for Tenant A CA
kubectl create configmap -n enterprise-kgateway tenant-a-ca-cert \
  --from-file=ca.crt=example_certs/tenant-a-ca.crt

# Create ConfigMap for Tenant B CA
kubectl create configmap -n enterprise-kgateway tenant-b-ca-cert \
  --from-file=ca.crt=example_certs/tenant-b-ca.crt
```

**Note**: The Gateway API supports multiple `caCertificateRefs`. Both ConfigMaps will be combined into a single trust pool.

**Implication**: Both Tenant A and Tenant B client certificates will be trusted by all listeners.

## Step 6: Configure Gateway with SNI + mTLS (Current API)

Apply the Gateway configuration with SNI-based listeners and gateway-level mTLS:

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
  infrastructure:
    parametersRef:
      group: enterprisekgateway.solo.io
      kind: EnterpriseKgatewayParameters
      name: ingress-params
  tls:
    frontend:
      default:
        validation:
          mode: AllowValidOnly
          caCertificateRefs:
            - name: tenant-a-ca-cert
              kind: ConfigMap
              group: ""
            - name: tenant-b-ca-cert
              kind: ConfigMap
              group: ""
  listeners:
    # Tenant A listener - uses SNI for routing
    - protocol: HTTPS
      port: 443
      name: tenant-a
      hostname: tenant-a.glootest.com
      tls:
        mode: Terminate
        certificateRefs:
          - name: tenant-a-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All

    # Tenant B listener - uses SNI for routing
    - protocol: HTTPS
      port: 443
      name: tenant-b
      hostname: tenant-b.glootest.com
      tls:
        mode: Terminate
        certificateRefs:
          - name: tenant-b-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
EOF
```

**Key Configuration Points:**
- `spec.tls.frontend.default.validation`: Gateway-wide mTLS configuration (applies to ALL listeners)
- `spec.tls.frontend.default.caCertificateRefs`: Array of CA certificate references (supports multiple CAs)
- `listeners[].hostname`: SNI-based routing works perfectly
- `listeners[].tls.certificateRefs`: Different server certs per listener (SNI)
- **Limitation**: No per-listener `frontendRef` to specify different CA validation per listener

## Step 7: Create HTTPRoutes for Each Tenant

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
  - "tenant-a.glootest.com"
  parentRefs:
    - name: ingress
      namespace: enterprise-kgateway
      sectionName: tenant-a
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
  - "tenant-b.glootest.com"
  parentRefs:
    - name: ingress
      namespace: enterprise-kgateway
      sectionName: tenant-b
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

## Step 8: Testing - Positive Cases

### Test Tenant A with Valid Certificate
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -ik --resolve "tenant-a.glootest.com:443:$GATEWAY_IP" \
  "https://tenant-a.glootest.com:443/get" \
  --cert example_certs/client-tenant-a.crt \
  --key example_certs/client-tenant-a.key \
  --cacert example_certs/tenant-a-gateway.crt
```

Expected output: **HTTP 200** ✅

### Test Tenant B with Valid Certificate
```bash
curl -ik --resolve "tenant-b.glootest.com:443:$GATEWAY_IP" \
  "https://tenant-b.glootest.com:443/get" \
  --cert example_certs/client-tenant-b.crt \
  --key example_certs/client-tenant-b.key \
  --cacert example_certs/tenant-b-gateway.crt
```

Expected output: **HTTP 200** ✅

## Step 9: Testing - Demonstrating the Limitation

> **Understanding the Limitation:**
>
> The tests below demonstrate that tenant isolation is not achieved at the gateway level:
> - Multiple `caCertificateRefs` are under `spec.tls.frontend.default`
> - This creates a combined trust pool for all listeners
> - Both tenant CAs are trusted by all listeners
> - Tenant A clients can access Tenant B endpoints (and vice versa)

### Test 1: Tenant A Client Accessing Tenant B
Due to the combined CA trust pool, Tenant A's cert can access Tenant B's endpoint:

```bash
curl -ik --resolve "tenant-b.glootest.com:443:$GATEWAY_IP" \
  "https://tenant-b.glootest.com:443/get" \
  --cert example_certs/client-tenant-a.crt \
  --key example_certs/client-tenant-a.key \
  --cacert example_certs/tenant-b-gateway.crt
```

Expected output: **HTTP 200** ⚠️ (This SHOULD fail for true tenant isolation, but doesn't)

### Test 2: Tenant B Client Accessing Tenant A
Similarly, Tenant B's cert can access Tenant A's endpoint:

```bash
curl -ik --resolve "tenant-a.glootest.com:443:$GATEWAY_IP" \
  "https://tenant-a.glootest.com:443/get" \
  --cert example_certs/client-tenant-b.crt \
  --key example_certs/client-tenant-b.key \
  --cacert example_certs/tenant-a-gateway.crt
```

Expected output: **HTTP 200** ⚠️ (This SHOULD fail for true tenant isolation, but doesn't)

---

**What These Tests Show:**

Tests 1 and 2 demonstrate that tenant isolation is not achieved at the gateway level. Even though we use separate ConfigMaps (`tenant-a-ca-cert` and `tenant-b-ca-cert`), the result is the same:

- Both CAs are trusted by all listeners
- Any client certificate signed by either CA can access any tenant's endpoint
- Multi-tenant isolation requires additional application-level validation

**Why This Happens:**
All `caCertificateRefs` under `spec.tls.frontend.default` are combined into a single trust pool that applies to every listener on the gateway.

---

### Test 3: Invalid Certificate (Correctly Rejected)
Certificates NOT signed by either tenant CA are rejected:

```bash
curl -ikv --resolve "tenant-a.glootest.com:443:$GATEWAY_IP" \
  "https://tenant-a.glootest.com:443/get" \
  --cert example_certs/client-invalid.crt \
  --key example_certs/client-invalid.key \
  --cacert example_certs/tenant-a-gateway.crt
```

Expected output: **TLS alert unknown ca** ✅ (Correctly rejected)

### Test 4: No Client Certificate (Correctly Rejected)
Requests without a client certificate fail:

```bash
curl -ikv --resolve "tenant-a.glootest.com:443:$GATEWAY_IP" \
  "https://tenant-a.glootest.com:443/get" \
  --cacert example_certs/tenant-a-gateway.crt
```

Expected output: **Certificate required error** ✅ (Correctly rejected)

## What Works vs What Doesn't

### ✅ What Works
- SNI-based routing (different server certs per hostname)
- mTLS validation (client must present a trusted cert)
- Rejecting untrusted certificates (Test 3)
- Rejecting requests without certificates (Test 4)
- Multiple tenants on the same port (443)
- Multiple `caCertificateRefs` (simplified CA management)

### ❌ What Doesn't Work
- Per-listener CA isolation (all listeners share the same CA trust pool)
- Tenant isolation at the TLS layer (Tests 1 & 2 demonstrate this)
- Preventing Tenant A from accessing Tenant B's endpoints with valid cert (Test 1)
- Preventing Tenant B from accessing Tenant A's endpoints with valid cert (Test 2)

## Current Verification Checklist

- ✅ Tenant A client can access tenant-a.glootest.com
- ✅ Tenant B client can access tenant-b.glootest.com
- ⚠️ Tenant A client **CAN** access tenant-b.glootest.com (limitation)
- ⚠️ Tenant B client **CAN** access tenant-a.glootest.com (limitation)
- ✅ Invalid client certs are rejected
- ✅ Requests without client certs are rejected

## Workarounds for Tenant Isolation

Since gateway-level isolation isn't possible with the current API, here are alternatives:

### Option 1: Application-Level Validation
Extract certificate information and validate in your application:

```yaml
# The gateway can forward client cert info to backends
# Use an EnterpriseKgatewayTrafficPolicy to extract cert fields
# Then validate in your application:
# - Check certificate CN matches expected tenant
# - Check certificate O (organization) field
# - Validate against tenant-specific allowlist
```

Your application code would check:
```python
# Example Python backend validation
def validate_tenant_access(request, expected_tenant):
    cert_cn = request.headers.get('X-Forwarded-Client-Cert-CN')
    cert_org = request.headers.get('X-Forwarded-Client-Cert-Org')

    if cert_org != expected_tenant:
        raise Unauthorized(f"Certificate from {cert_org} cannot access {expected_tenant}")
```

### Option 2: Separate Gateway Instances
Deploy separate Gateway resources per tenant:

```yaml
# Gateway for Tenant A (separate IP/port or namespace)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: tenant-a-gateway
  namespace: tenant-a-ns
spec:
  # Only trusts Tenant A CA
  tls:
    frontend:
      default:
        validation:
          caCertificateRefs:
            - name: tenant-a-ca-cert
```

**Trade-off**: More infrastructure overhead, but true isolation.

### Option 3: Different Ports Per Tenant
Use different ports for different tenants:

```yaml
listeners:
  - name: tenant-a
    port: 8443  # Tenant A on port 8443
    hostname: tenant-a.glootest.com
  - name: tenant-b
    port: 9443  # Tenant B on port 9443
    hostname: tenant-b.glootest.com
```

Then use separate `tls.frontend` configs... but this still requires API support for named frontend configs.

### Option 4: Wait for API Enhancement
Request the `frontendRef` feature from the Enterprise Kgateway team.

## Recommended Approach

For production multi-tenant mTLS with current APIs:

1. **Use SNI + mTLS as shown** (provides some security)
2. **Add application-level validation** (check cert CN/O fields)
3. **Implement authorization policies** (validate tenant in application logic)
4. **Monitor access patterns** (detect cross-tenant access attempts)
5. **Document the limitation** (make security team aware)

## Cleanup

```bash
# Remove Kubernetes resources
kubectl delete gateway -n enterprise-kgateway ingress
kubectl delete httproute -n httpbin tenant-a-route tenant-b-route
kubectl delete secret -n enterprise-kgateway tenant-a-tls tenant-b-tls
kubectl delete configmap -n enterprise-kgateway tenant-a-ca-cert tenant-b-ca-cert

# Remove certificates
rm -rf example_certs
```

## Restore Default Configuration

Deploy the default `Gateway` and `HTTPRoute` from lab `001` and `002`:

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
  infrastructure:
    parametersRef:
      group: enterprisekgateway.solo.io
      kind: EnterpriseKgatewayParameters
      name: ingress-params
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
  - "httpbin.glootest.com"
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

## Key Takeaways

1. **SNI Works**: Different server certificates per hostname via SNI
2. **mTLS Works**: Client certificate validation is enforced
3. **Tenant Isolation Doesn't Work**: All listeners share the same CA trust pool
4. **Application Validation Needed**: For true tenant isolation, validate cert fields in application
5. **API Limitation**: Current Gateway API lacks per-listener frontend TLS references

## Further Reading

- Exercise 004: Basic SNI matching without mTLS
- Exercise 007: Basic mTLS with single CA (foundation for this exercise)
