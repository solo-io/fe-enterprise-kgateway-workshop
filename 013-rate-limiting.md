## Rate Limiting

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Understand rate limiting concepts in Enterprise Kgateway
- Configure rate limiting using RateLimitConfig
- Apply rate limiting policies using EnterpriseKgatewayTrafficPolicy
- Test rate limiting behavior with different request patterns

## Understanding Rate Limiting

Rate limiting is a critical feature for API gateway deployments that helps:
- Protect backend services from being overwhelmed by too many requests
- Ensure fair usage across different clients or API consumers
- Prevent abuse and DoS attacks
- Enforce SLA tiers (e.g., free tier vs. paid tier)

Enterprise Kgateway provides global rate limiting through:
1. **RateLimitConfig**: Defines the rate limit rules and descriptors
2. **EnterpriseKgatewayTrafficPolicy**: Applies rate limiting to specific routes or gateways using the `entRateLimit` field

## Rate Limiting Architecture

Enterprise Kgateway uses a distributed rate limiting architecture:
- **Envoy proxies**: Extract rate limit descriptors from requests and call the rate limit service
- **Rate limit service**: A stateful service (deployed with Enterprise Kgateway) that tracks request counts and enforces limits
- **Redis**: Optional backend for the rate limit service to share state across multiple replicas

## Create a RateLimitConfig

First, create a `RateLimitConfig` that defines a simple rate limit of 10 requests per minute:

```bash
kubectl apply -f - <<EOF
---
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: httpbin-ratelimit-config
  namespace: httpbin
spec:
  raw:
    descriptors:
    - key: generic_key
      value: count
      rateLimit:
        requestsPerUnit: 10
        unit: MINUTE
    rateLimits:
    - actions:
      - genericKey:
          descriptorValue: count
EOF
```

This configuration:
- Defines a rate limit descriptor using a `generic_key` with value `count`
- Sets a limit of 10 requests per minute
- Uses a simple action that adds the generic key to all requests

Verify the RateLimitConfig was created:
```bash
kubectl get ratelimitconfig -n httpbin
```

Expected output:
```
NAME                       AGE
httpbin-ratelimit-config   5s
```

## Apply Rate Limiting to the HTTPRoute

Create an `EnterpriseKgatewayTrafficPolicy` to apply rate limiting to the httpbin route:

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-ratelimit-policy
  namespace: httpbin
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: httpbin-route
  entRateLimit:
    global:
      rateLimitConfigRefs:
      - name: httpbin-ratelimit-config
        namespace: httpbin
EOF
```

This policy:
- Uses `entRateLimit` (the Enterprise Kgateway field name)
- References the `httpbin-ratelimit-config` we created
- Targets the `httpbin-route` HTTPRoute

Verify the policy was created and attached:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
```

Expected output:
```
NAME                       ACCEPTED   ATTACHED
httpbin-ratelimit-policy   True       True
```

## Test the Rate Limiting

Set up the gateway IP for testing:
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')
```

Send a few requests to verify they succeed:
```bash
for i in {1..5}; do
  curl -i "$GATEWAY_IP/get" \
    -H "content-type: application/json" \
    -H "Host: httpbin.try-solo.io"
  echo "Request $i completed"
done
```

Expected output for the first few requests:
```
HTTP/1.1 200 OK
content-type: application/json
x-envoy-upstream-service-time: 5
...
Request 1 completed
...
```

Now send more requests to exceed the rate limit (10 per minute):
```bash
for i in {1..15}; do
  curl -i "$GATEWAY_IP/get" \
    -H "content-type: application/json" \
    -H "Host: httpbin.try-solo.io" 2>/dev/null | head -1
  echo "Request $i"
done
```

Expected output (requests 11-15 should be rate limited):
```
HTTP/1.1 200 OK
Request 1
HTTP/1.1 200 OK
Request 2
...
HTTP/1.1 200 OK
Request 10
HTTP/1.1 429 Too Many Requests
Request 11
HTTP/1.1 429 Too Many Requests
Request 12
...
```

The rate-limited response includes:
```
HTTP/1.1 429 Too Many Requests
x-envoy-ratelimited: true
content-length: 18
content-type: text/plain

local_rate_limited
```

## Advanced: Per-User Rate Limiting

Now let's implement a more sophisticated rate limit based on a user identifier. This is useful for implementing user-specific quotas.

Create a RateLimitConfig that rate limits based on a header value:

```bash
kubectl apply -f - <<EOF
---
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: per-user-ratelimit-config
  namespace: httpbin
spec:
  raw:
    descriptors:
    - key: user_id
      rateLimit:
        requestsPerUnit: 5
        unit: MINUTE
    rateLimits:
    - actions:
      - requestHeaders:
          descriptorKey: user_id
          headerName: x-user-id
EOF
```

This configuration:
- Extracts the `x-user-id` header value
- Rate limits to 5 requests per minute per unique user ID
- Different users get independent rate limit buckets

Update the EnterpriseKgatewayTrafficPolicy to use the per-user rate limit:

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: httpbin-ratelimit-policy
  namespace: httpbin
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: httpbin-route
  entRateLimit:
    global:
      rateLimitConfigRefs:
      - name: per-user-ratelimit-config
        namespace: httpbin
EOF
```

Test the per-user rate limiting:

```bash
# User 'alice' sends 3 requests (should all succeed)
for i in {1..3}; do
  curl -i "$GATEWAY_IP/get" \
    -H "content-type: application/json" \
    -H "Host: httpbin.try-solo.io" \
    -H "x-user-id: alice" 2>/dev/null | head -1
  echo "Alice request $i"
done

# User 'bob' sends 3 requests (should all succeed - independent bucket)
for i in {1..3}; do
  curl -i "$GATEWAY_IP/get" \
    -H "content-type: application/json" \
    -H "Host: httpbin.try-solo.io" \
    -H "x-user-id: bob" 2>/dev/null | head -1
  echo "Bob request $i"
done

# Alice sends 3 more requests (should hit rate limit)
for i in {4..6}; do
  curl -i "$GATEWAY_IP/get" \
    -H "content-type: application/json" \
    -H "Host: httpbin.try-solo.io" \
    -H "x-user-id: alice" 2>/dev/null | head -1
  echo "Alice request $i"
done
```

Expected output:
```
HTTP/1.1 200 OK
Alice request 1
HTTP/1.1 200 OK
Alice request 2
HTTP/1.1 200 OK
Alice request 3
HTTP/1.1 200 OK
Bob request 1
HTTP/1.1 200 OK
Bob request 2
HTTP/1.1 200 OK
Bob request 3
HTTP/1.1 200 OK
Alice request 4
HTTP/1.1 200 OK
Alice request 5
HTTP/1.1 429 Too Many Requests
Alice request 6
```

Notice that:
- Alice's first 5 requests succeed (requests 1-3 and 4-5)
- Bob's requests succeed independently (separate rate limit bucket)
- Alice's 6th request is rate limited

## Advanced: Multiple Rate Limit Descriptors

You can combine multiple rate limit descriptors for more complex scenarios:

```bash
kubectl apply -f - <<EOF
---
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: tiered-ratelimit-config
  namespace: httpbin
spec:
  raw:
    descriptors:
    # Global rate limit (all traffic)
    - key: generic_key
      value: global
      rateLimit:
        requestsPerUnit: 100
        unit: MINUTE
    # Per-user rate limit
    - key: generic_key
      value: global
      descriptors:
      - key: user_id
        rateLimit:
          requestsPerUnit: 10
          unit: MINUTE
    rateLimits:
    - actions:
      - genericKey:
          descriptorValue: global
      - requestHeaders:
          descriptorKey: user_id
          headerName: x-user-id
EOF
```

This creates a two-tier rate limit:
1. Global limit: 100 requests/minute across all users
2. Per-user limit: 10 requests/minute per user

Both limits must be satisfied for a request to proceed.

## Rate Limiting on the Gateway

You can also apply rate limiting at the Gateway level (instead of per-route):

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: gateway-ratelimit-policy
  namespace: enterprise-kgateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ingress
      namespace: enterprise-kgateway
  entRateLimit:
    global:
      rateLimitConfigRefs:
      - name: httpbin-ratelimit-config
        namespace: httpbin
EOF
```

This applies rate limiting to all routes served by the Gateway.

## Understanding Rate Limit Actions

Rate limit actions determine what descriptors are generated for each request. Common actions include:

1. **genericKey**: Adds a static key-value pair to all requests
   ```yaml
   - genericKey:
       descriptorValue: count
   ```

2. **requestHeaders**: Extracts a descriptor from a request header
   ```yaml
   - requestHeaders:
       descriptorKey: user_id
       headerName: x-user-id
   ```

3. **remoteAddress**: Uses the client's IP address
   ```yaml
   - remoteAddress: {}
   ```

4. **destinationCluster**: Uses the upstream cluster name
   ```yaml
   - destinationCluster: {}
   ```

5. **requestPath**: Uses the request path
   ```yaml
   - requestPath: {}
   ```

## Cleanup

Remove the rate limiting policy:
```bash
kubectl delete enterprisekgatewaytrafficpolicy -n httpbin httpbin-ratelimit-policy
```

Remove the RateLimitConfigs:
```bash
kubectl delete ratelimitconfig -n httpbin httpbin-ratelimit-config
kubectl delete ratelimitconfig -n httpbin per-user-ratelimit-config
kubectl delete ratelimitconfig -n httpbin tiered-ratelimit-config
```

If you created a gateway-level policy, remove it:
```bash
kubectl delete enterprisekgatewaytrafficpolicy -n enterprise-kgateway gateway-ratelimit-policy 2>/dev/null || true
```

Verify cleanup:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
kubectl get ratelimitconfig -n httpbin
```

Test that requests are no longer rate limited:
```bash
for i in {1..15}; do
  curl -i "$GATEWAY_IP/get" \
    -H "content-type: application/json" \
    -H "Host: httpbin.try-solo.io" 2>/dev/null | head -1
  echo "Request $i"
done
```

All requests should now return `HTTP/1.1 200 OK`.

## Key Takeaways

- Rate limiting in Enterprise Kgateway uses `RateLimitConfig` (defines limits) and `EnterpriseKgatewayTrafficPolicy` with `entRateLimit` (applies limits)
- Rate limiting can be applied at the HTTPRoute or Gateway level
- Descriptors and actions allow flexible rate limiting based on headers, IP addresses, paths, etc.
- Multiple rate limit descriptors can be combined for tiered rate limiting
- The rate limit service is stateful and can optionally use Redis for shared state
