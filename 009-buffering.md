## Buffering

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Configure buffer limits on routes using EnterpriseKgatewayTrafficPolicy
- Test buffering behavior with large request payloads
- Validate that requests exceeding buffer limits are rejected

## Understanding Buffering

Envoy buffers requests by default to handle scenarios where the upstream service may process data slower than it arrives. By setting buffer limits, you can:
- Protect upstream services from large request payloads
- Prevent memory exhaustion from malicious or misconfigured clients
- Control resource usage in your gateway

## Set up buffer limits per route

Create an EnterpriseKgatewayTrafficPolicy to set a buffer limit on the httpbin route. This policy will limit request payloads to 1KB.

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-buffer-policy
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  buffer:
    maxRequestSize: 1Ki
EOF
```

Verify the policy was created and accepted:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
```

Expected output:
```
NAME                    ACCEPTED   ATTACHED
httpbin-buffer-policy   True       True
```

## Test with a small request (should succeed)

Send a small request (less than 1KB) to the httpbin service. This should succeed.

```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/post" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io" \
  -d '{"message": "This is a small payload that should be accepted"}'
```

Expected output (should succeed with HTTP 200):
```
HTTP/1.1 200 OK
server: envoy
date: Wed, 08 Jan 2026 12:00:00 GMT
content-type: application/json
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 5

{
  "args": {},
  "data": "{\"message\": \"This is a small payload that should be accepted\"}",
  "files": {},
  "form": {},
  "headers": {
    "Accept": "*/*",
    "Content-Length": "59",
    "Content-Type": "application/json",
    "Host": "httpbin.try-solo.io",
    ...
  },
  "json": {
    "message": "This is a small payload that should be accepted"
  },
  ...
}
```

## Test with a large request (should fail)

Send a request larger than 1KB to test the buffer limit. This should fail with a 413 Payload Too Large error.

```bash
# Create a large payload (approximately 2KB)
LARGE_PAYLOAD=$(python3 -c "import json; print(json.dumps({'data': 'x' * 2048}))")

curl -i "$GATEWAY_IP/post" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io" \
  -d "$LARGE_PAYLOAD"
```

Expected output (should fail with HTTP 413):
```
HTTP/1.1 413 Payload Too Large
content-length: 17
content-type: text/plain
date: Wed, 08 Jan 2026 12:00:00 GMT
server: envoy
connection: close

Payload Too Large
```

## Test at the buffer limit boundary

Test with a payload right at the 1KB limit to verify the exact threshold.

```bash
# Create a payload close to 1KB (accounting for JSON overhead)
BOUNDARY_PAYLOAD=$(python3 -c "import json; print(json.dumps({'data': 'x' * 950}))")

curl -i "$GATEWAY_IP/post" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io" \
  -d "$BOUNDARY_PAYLOAD"
```

This should succeed as it's within the limit.

## Update buffer limit

You can update the buffer limit by modifying the policy. Let's increase it to 5KB:

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-buffer-policy
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  buffer:
    maxRequestSize: 5Ki
EOF
```

Now test with the 2KB payload again - it should succeed:
```bash
LARGE_PAYLOAD=$(python3 -c "import json; print(json.dumps({'data': 'x' * 2048}))")

curl -i "$GATEWAY_IP/post" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io" \
  -d "$LARGE_PAYLOAD"
```

Expected output (should now succeed with HTTP 200):
```
HTTP/1.1 200 OK
server: envoy
...
```

## Disable buffering limits

To disable buffering limits and revert to default behavior, update the policy:

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-buffer-policy
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  buffer:
    disable: {}
EOF
```

## Cleanup

Delete the buffering policy:
```bash
kubectl delete enterprisekgatewaytrafficpolicy -n httpbin httpbin-buffer-policy
```

Verify the policy has been deleted:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
```
