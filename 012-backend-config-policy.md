## Backend Config Policy

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Configure backend connection settings using BackendConfigPolicy
- Set maximum header count limits for backend connections
- Configure idle timeout for backend connections
- Test backend configuration behavior

## Understanding BackendConfigPolicy

BackendConfigPolicy allows you to configure how the gateway communicates with backend (upstream) services. Unlike EnterpriseKgatewayTrafficPolicy which focuses on request/response handling, BackendConfigPolicy configures the connection-level settings between the gateway and backends.

Key use cases:
- **maxHeadersCount**: Limit the number of headers accepted from backends to protect against header-based attacks
- **idleTimeout**: Control how long idle connections to backends stay open
- **Connection pooling**: Configure connection reuse and limits
- **Health checks**: Define backend health check behavior

## Configure maximum header count

Create a BackendConfigPolicy to limit the number of headers accepted from the httpbin backend. We'll set it to 10 headers to demonstrate the limit.

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: BackendConfigPolicy
metadata:
  name: httpbin-backend-config
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin
      kind: Service
      group: ""
  commonHttpProtocolOptions:
    maxHeadersCount: 10
EOF
```

Verify the policy was created and accepted:
```bash
kubectl get backendconfigpolicy -n httpbin
```

Expected output:
```
NAME                    ACCEPTED   ATTACHED
httpbin-backend-config  True       True
```

## Test header count limit

The httpbin service has a `/response-headers` endpoint that allows us to add custom headers to the response. The backend already returns several standard headers (server, date, content-type, content-length, access-control-allow-origin, access-control-allow-credentials, x-envoy-upstream-service-time), which is about 7 headers.

First, test with a small number of additional headers (should succeed):
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/response-headers?Custom-Header-1=value1&Custom-Header-2=value2" \
  -H "Host: httpbin.try-solo.io"
```

Expected output (should succeed with HTTP 200 - total ~9 headers):
```
HTTP/1.1 200 OK
server: envoy
date: Fri, 09 Jan 2026 12:00:00 GMT
content-type: application/json
content-length: 133
custom-header-1: value1
custom-header-2: value2
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 5
...
```

Now, test with many additional headers to exceed the 10 header limit:
```bash
curl -i "$GATEWAY_IP/response-headers?H1=v1&H2=v2&H3=v3&H4=v4&H5=v5&H6=v6&H7=v7&H8=v8" \
  -H "Host: httpbin.try-solo.io"
```

Expected output (should fail with HTTP 502 - total would be 15+ headers):
```
HTTP/1.1 502 Bad Gateway
content-length: 87
content-type: text/plain
date: Fri, 09 Jan 2026 12:00:00 GMT
server: envoy

upstream connect error or disconnect/reset before headers. reset reason: protocol error
```

The backend returned more than 10 headers (7 standard + 8 custom = 15 total), which exceeds the configured limit. Envoy treats this as a protocol violation and returns HTTP 502 with a "protocol error" message.

This demonstrates that the gateway is protecting against backends that return excessive headers. In production scenarios:
- **Default**: maxHeadersCount is 100
- **Strict backends**: Set lower (e.g., 20-50) for backends you control and know won't exceed the limit
- **Protection**: Guards against malicious or malfunctioning backends that might try to exhaust resources with header floods

## Configure idle timeout

Now let's configure the idle timeout for backend connections. This controls how long the gateway keeps idle connections to the backend open.

Update the BackendConfigPolicy to include a 30 second idle timeout:

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: BackendConfigPolicy
metadata:
  name: httpbin-backend-config
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin
      kind: Service
      group: ""
  commonHttpProtocolOptions:
    maxHeadersCount: 10
    idleTimeout: 30s
EOF
```

Verify the update:
```bash
kubectl get backendconfigpolicy -n httpbin httpbin-backend-config -o yaml | grep -A 5 commonHttpProtocolOptions
```

Expected output:
```yaml
commonHttpProtocolOptions:
  idleTimeout: 30s
  maxHeadersCount: 10
```

## Understanding idle timeout behavior

The `idleTimeout` setting controls backend connection lifecycle:

- **Default**: 1 hour if not specified
- **Custom value**: Set to your desired duration (e.g., `30s`, `5m`, `1h`)
- **Disabled**: Set to `0` to disable idle timeout (not recommended due to connection leak risk)

When the idle timeout is reached:
- The connection to the backend is closed
- For HTTP/2, a drain sequence occurs before closing
- New requests will establish new connections

**Use cases**:
- **Short timeouts (30s-5m)**: Useful when backends scale up/down frequently or have limited connection capacity
- **Long timeouts (30m-1h)**: Better for stable backends where connection reuse improves performance
- **Very short timeouts (5-10s)**: Useful in development/testing to quickly close idle connections

## Test idle timeout

Make a request to establish a connection:
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/get" \
  -H "Host: httpbin.try-solo.io"
```

The connection is now idle. After 30 seconds of no activity, the gateway will close this connection to the backend. Subsequent requests will create a new connection.

To observe this behavior, check the Envoy stats. The `envoy-wrapper` image is
distroless — it has no shell and no `curl` — so reach the admin endpoint through
a port-forward rather than `kubectl exec`:

```bash
kubectl -n enterprise-kgateway port-forward deployment/ingress 19000
```

In another terminal:
```bash
curl -s localhost:19000/stats | grep upstream_cx_destroy_local
```

This shows connections closed locally by the gateway due to idle timeout.

## Combine with other backend settings

BackendConfigPolicy supports many other configuration options. Here's a more comprehensive production-ready example:

```bash
kubectl apply -f - <<EOF
---
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
EOF
```

This production configuration:
- Limits headers to 100 (the default, but explicitly set)
- Sets idle timeout to 5 minutes
- Limits each connection to 1000 requests before being closed
- Sets connection timeout to 5 seconds
- Limits per-connection buffer to 32KB

**Note**: Don't apply this - it's just an example. The test policy with maxHeadersCount: 10 is already applied.

## BackendConfigPolicy vs EnterpriseKgatewayTrafficPolicy

Understanding when to use each:

**BackendConfigPolicy**:
- Configures backend/upstream connection settings
- Applied to Services (backends)
- Controls: connection timeouts, header limits, connection pooling, health checks
- Lives in the same namespace as the backend Service

**EnterpriseKgatewayTrafficPolicy**:
- Configures request/response handling
- Applied to HTTPRoutes or Gateways
- Controls: request timeouts, retries, buffering, transformations
- Lives in the same namespace as the HTTPRoute or Gateway

Both can be used together for comprehensive traffic management.

## Cleanup

Delete the BackendConfigPolicy:
```bash
kubectl delete backendconfigpolicy -n httpbin httpbin-backend-config
```

Verify cleanup:
```bash
kubectl get backendconfigpolicy -n httpbin
```
