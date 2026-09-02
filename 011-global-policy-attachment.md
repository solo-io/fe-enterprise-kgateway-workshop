## Global Policy Attachment

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Understand global policy attachment using targetSelectors
- Apply policies to multiple routes using label selectors
- Test global policy behavior across different HTTPRoutes

## Understanding Global Policy Attachment

Instead of using `targetRefs` to attach policies to specific routes or gateways, you can use `targetSelectors` to attach policies globally based on labels. This allows you to:
- Apply a policy to multiple routes with a single resource
- Use Kubernetes label selectors for flexible targeting
- Manage policies centrally without referencing individual routes

**Key differences**:
- `targetRefs`: Explicitly references specific resources (Gateway or HTTPRoute) by name
- `targetSelectors`: Selects resources by label matching across the namespace

## Add labels to HTTPRoutes

First, add a label to the existing httpbin route:

```bash
kubectl label httproute -n httpbin httpbin-route app=httpbin
```

Verify the label was added:
```bash
kubectl get httproute -n httpbin httpbin-route --show-labels
```

Expected output:
```
NAME            HOSTNAMES                  AGE   LABELS
httpbin-route   ["httpbin.glootest.com"]   ...   app=httpbin
```

## Create a global timeout policy

Create an EnterpriseKgatewayTrafficPolicy using `targetSelectors` to match all HTTPRoutes with the label `app=httpbin`:

```bash
kubectl apply -f - <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: global-timeout-policy
  namespace: httpbin
spec:
  targetSelectors:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      matchLabels:
        app: httpbin
  timeouts:
    request: 3s
EOF
```

Verify the policy was created and attached:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
```

Expected output:
```
NAME                    ACCEPTED   ATTACHED
global-timeout-policy   True       True
```

## Test the global timeout policy

Test with a 2 second delay (should succeed):
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

time curl -i "$GATEWAY_IP/delay/2" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

Expected output (should succeed after ~2 seconds):
```
HTTP/1.1 200 OK
server: envoy
content-type: application/json
x-envoy-upstream-service-time: 2007
...
```

Notice the `X-Envoy-Expected-Rq-Timeout-Ms: 3000` header in the request, confirming the 3s timeout is applied.

Test with a 5 second delay (should timeout):
```bash
time curl -i "$GATEWAY_IP/delay/5" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

Expected output (should timeout after 3 seconds with HTTP 504):
```
HTTP/1.1 504 Gateway Timeout
content-length: 24
content-type: text/plain
server: envoy

upstream request timeout
```

## Apply the policy to multiple routes

Create a second HTTPRoute with the same label to demonstrate global policy attachment:

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-headers-route
  namespace: httpbin
  labels:
    app: httpbin
spec:
  hostnames:
  - "httpbin-headers.glootest.com"
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
            value: /headers
EOF
```

Verify both routes now have the timeout policy applied:
```bash
kubectl get enterprisekgatewaytrafficpolicy -n httpbin global-timeout-policy -o yaml | grep -A 20 "status:"
```

A `targetSelectors` policy reports a single ancestor — the `Gateway` serving the
selected routes — with an `Attached` condition of `Attached to all targets`. It
does **not** list one ancestor per matched HTTPRoute, so don't look for
`httpbin-route` here:

```yaml
status:
  ancestors:
  - ancestorRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: ingress
      namespace: enterprise-kgateway
    conditions:
    - message: Policy accepted
      reason: Valid
      status: "True"
      type: Accepted
    - message: Attached to all targets
      reason: Attached
      status: "True"
      type: Attached
    controllerName: solo.io/enterprise-kgateway
```

To confirm which routes actually picked the policy up, send traffic through each
one and check the `X-Envoy-Expected-Rq-Timeout-Ms` header, as below.

Test the second route:
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/headers" \
  -H "content-type: application/json" \
  -H "Host: httpbin-headers.glootest.com"
```

The response headers should show `X-Envoy-Expected-Rq-Timeout-Ms: 3000`, confirming the global policy is applied.

## targetSelectors vs targetRefs

Understanding when to use each approach:

**Use targetSelectors when**:
- You want to apply a policy to multiple routes based on labels
- You're managing many routes with similar requirements
- You want dynamic policy attachment as new routes are created with matching labels

**Use targetRefs when**:
- You need to attach a policy to a specific route or gateway
- You want explicit, direct reference to resources
- You need fine-grained control per route

**Important notes**:
- targetSelectors and targetRefs are mutually exclusive (you can't use both in the same policy)
- targetSelectors matches resources in the same namespace as the policy
- targetSelectors can match Gateway, HTTPRoute, or ListenerSet resources

## Label selector examples

You can use complex label selectors. Here are some examples:

Match multiple labels (AND logic):
```yaml
targetSelectors:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    matchLabels:
      app: httpbin
      environment: production
```

Create multiple policies with different selectors:
```yaml
# Policy 1: Timeout for production routes
targetSelectors:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    matchLabels:
      environment: production

# Policy 2: Retry for critical routes
targetSelectors:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    matchLabels:
      priority: critical
```

## Cleanup

Remove the label from httpbin-route:
```bash
kubectl label httproute -n httpbin httpbin-route app-
```

Delete the second HTTPRoute:
```bash
kubectl delete httproute -n httpbin httpbin-headers-route
```

Delete the global timeout policy:
```bash
kubectl delete enterprisekgatewaytrafficpolicy -n httpbin global-timeout-policy
```

Verify cleanup:
```bash
kubectl get enterprisekgatewaytrafficpolicies -n httpbin
kubectl get httproute -n httpbin
```
