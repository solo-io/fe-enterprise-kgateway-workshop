## Timeouts and Retries

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Configure request timeouts using EnterpriseKgatewayTrafficPolicy
- Configure retry policies with per-try timeouts
- Test timeout behavior with delayed responses
- Understand the difference between request timeout and per-try timeout

## Understanding Timeouts and Retries

Request timeouts protect your system from slow or unresponsive upstream services:
- **Request timeout**: Maximum time to wait for the entire request to complete
- **Stream idle timeout**: Maximum time of inactivity on a stream
- **Per-try timeout**: Maximum time for each retry attempt (used with retries)

Retries help improve reliability by automatically retrying failed requests.

## Set up request timeout

Create an EnterpriseKgatewayTrafficPolicy to set a request timeout of 3 seconds on the httpbin route.

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-timeout-policy
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  timeouts:
    request: 3s
EOF
```

Verify the policy was created and accepted:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
```

Expected output:
```
NAME                     ACCEPTED   ATTACHED
httpbin-timeout-policy   True       True
```

## Test with a fast response (should succeed)

Send a request to httpbin's /delay endpoint with a 1 second delay. This should succeed since it's within the 3 second timeout.

```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

time curl -i "$GATEWAY_IP/delay/1" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io"
```

Expected output (should succeed with HTTP 200 after ~1 second):
```
HTTP/1.1 200 OK
server: envoy
date: Fri, 09 Jan 2026 12:00:00 GMT
content-type: application/json
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 1004

{
  "args": {},
  "data": "",
  "files": {},
  "form": {},
  "headers": {
    "Accept": "*/*",
    ...
  },
  "origin": "...",
  "url": "http://httpbin.try-solo.io/delay/1"
}
```

## Test with a slow response (should timeout)

Send a request with a 5 second delay. This should fail with a timeout since it exceeds the 3 second limit.

```bash
time curl -i "$GATEWAY_IP/delay/5" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io"
```

Expected output (should timeout after 3 seconds with HTTP 504):
```
HTTP/1.1 504 Gateway Timeout
content-length: 24
content-type: text/plain
date: Fri, 09 Jan 2026 12:00:00 GMT
server: envoy

upstream request timeout
```

## Apply policies to multiple routes

Instead of using `targetRefs` to target individual routes, you can use `targetSelectors` with labels to apply a policy to multiple routes at once. This is useful when you want to apply the same timeout or retry policy across multiple HTTPRoutes without creating individual policies for each.

This approach:
- Uses Kubernetes label selectors to match routes
- Allows you to apply one policy to multiple routes
- Provides more flexibility than Gateway-level targeting

For a detailed example of global policy attachment using `targetSelectors`, see **lab 010**.

## Configure retry with per-try timeout

Now let's add retry behavior with per-try timeouts. This policy will:
- Retry up to 3 times on 5xx errors or timeouts
- Use a 2 second timeout for each attempt
- Use a 5 second overall request timeout

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-timeout-policy
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  timeouts:
    request: 5s
  retry:
    attempts: 3
    perTryTimeout: 2s
    retryOn:
      - 5xx
      - gateway-error
      - reset
      - connect-failure
EOF
```

Verify the policy was updated:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin httpbin-timeout-policy -o yaml | grep -A 10 retry
```

## Test retry behavior with per-try timeout

Send a request with a 3 second delay. Each attempt will timeout after 2 seconds, and it will retry up to 3 times.

```bash
time curl -i "$GATEWAY_IP/delay/3" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io"
```

Expected output (should timeout after ~5 seconds total, having attempted 2-3 retries):
```
HTTP/1.1 504 Gateway Timeout
content-length: 24
content-type: text/plain
date: Fri, 09 Jan 2026 12:00:00 GMT
server: envoy

upstream request timeout
```

The request should take approximately 5 seconds (the overall request timeout), which allows for 2 full retry attempts at 2 seconds each, plus part of a third.

## Test successful request with retry policy

Send a request with a 1 second delay. This should succeed on the first try without needing retries.

```bash
time curl -i "$GATEWAY_IP/delay/1" \
  -H "content-type: application/json" \
  -H "Host: httpbin.try-solo.io"
```

Expected output (should succeed after ~1 second):
```
HTTP/1.1 200 OK
server: envoy
...
```

## Configure retry on specific status codes

You can also configure retries based on specific HTTP status codes. Let's retry on 503 errors:

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-timeout-policy
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  timeouts:
    request: 10s
  retry:
    attempts: 3
    perTryTimeout: 3s
    backoffBaseInterval: 100ms
    statusCodes:
      - 503
      - 504
EOF
```

## Test with httpbin status endpoint

Test the retry behavior by requesting a 503 status:

```bash
curl -i "$GATEWAY_IP/status/503" \
  -H "Host: httpbin.try-solo.io"
```

The gateway will retry the request 3 times before returning the 503 error.

## Understanding timeout behavior

Key points about timeouts and retries:
- **Request timeout** is the total time budget for the entire request, including all retries
- **Per-try timeout** is the time budget for each individual attempt
- If `perTryTimeout` is not set, each retry gets the full request timeout
- The number of retries depends on: retry attempts, per-try timeout, and overall request timeout
- Retries stop when either the request succeeds, max attempts is reached, or request timeout expires

Example scenarios:
- Request timeout: 10s, Per-try timeout: 2s, Attempts: 5
  - Maximum possible retries: 5 attempts (limited by attempts setting)
  - Total time: Up to 10s (limited by request timeout)

- Request timeout: 5s, Per-try timeout: 2s, Attempts: 10
  - Maximum possible retries: 2-3 attempts (limited by request timeout)
  - Total time: 5s (request timeout)

## Configure stream idle timeout

You can also configure stream idle timeout, which is the maximum time of inactivity on a stream:

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-timeout-policy
  namespace: httpbin
spec:
  targetRefs:
    - name: httpbin-route
      kind: HTTPRoute
      group: gateway.networking.k8s.io
  timeouts:
    request: 30s
    streamIdle: 10s
EOF
```

## Cleanup

Delete the timeout and retry policy:
```bash
kubectl delete enterprisekgatewaytrafficpolicy -n httpbin httpbin-timeout-policy
```

Verify the policy has been deleted:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
```
