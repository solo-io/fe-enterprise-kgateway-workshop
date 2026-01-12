## JWT Validation

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Configure JWT validation
- Validate that our endpoint is protected by JWT
- Confirm that our request is successful with a valid JWT
- Explore additional capabilities such as `tokenSource`, `keepToken` and `claimsToHeaders`

## References
- [Gloo Gateway Docs - JWT](https://docs.solo.io/gateway/latest/security/jwt/basic/)

## Configure JWT validation at the gateway

Create an EnterpriseKgatewayTrafficPolicy to enforce JWT authentication at the gateway-level. Note that the policy is configured in the `enterprise-kgateway` namespace because the `targetRef` is to the `ingress` gateway in the same namespace
```bash
kubectl apply -f- <<EOF
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: jwt
  namespace: enterprise-kgateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ingress
  entJWT:
    beforeExtAuth:
      providers:
        selfminted:
          issuer: solo.io
          ## -- expect the token header to come in the form of Authorization: bearer --
          tokenSource:
            headers:
            - header: "Authorization"
              prefix: "Bearer "
          ## -- set to true if the upstream application requires the token --
          keepToken: false
          jwks:
            local:
              key: '{"keys":[{"kty":"RSA","kid":"solo-public-key-001","use":"sig","alg":"RS256","n":"AOfIaJMUm7564sWWNHaXt_hS8H0O1Ew59-nRqruMQosfQqa7tWne5lL3m9sMAkfa3Twx0LMN_7QqRDoztvV3Wa_JwbMzb9afWE-IfKIuDqkvog6s-xGIFNhtDGBTuL8YAQYtwCF7l49SMv-GqyLe-nO9yJW-6wIGoOqImZrCxjxXFzF6mTMOBpIODFj0LUZ54QQuDcD1Nue2LMLsUvGa7V1ZHsYuGvUqzvXFBXMmMS2OzGir9ckpUhrUeHDCGFpEM4IQnu-9U8TbAJxKE5Zp8Nikefr2ISIG2Hk1K2rBAc_HwoPeWAcAWUAR5tWHAxx-UXClSZQ9TMFK850gQGenUp8","e":"AQAB"}]}'
          ## -- define claims that should be copied to upstream headers --
          claimsToHeaders:
          - claim: team
            header: x-team
          - claim: org
            header: x-org
EOF
```

## Validate that our gateway is protected by JWT

Send a request to the httpbin app. Verify that your request is denied and that you get back a 401 HTTP response code, because all routes on the gateway now require a valid JWT token from the provider.

First with no JWT, we should see a `401 Unauthorized` with an error stating `Jwt is missing`
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

Next with an invalid JWT we should also be denied access
```bash
curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.invalidsig"
```

## Confirm that our request is successful with a valid JWT

Save the JWT token for Alice. Alice works in the dev team.
```
export ALICE_TOKEN=eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InNvbG8tcHVibGljLWtleS0wMDEifQ.eyJpc3MiOiJzb2xvLmlvIiwib3JnIjoic29sby5pbyIsInN1YiI6ImFsaWNlIiwidGVhbSI6ImRldiIsImV4cCI6MjA3NDI3NDg4NCwibGxtcyI6eyJvcGVuYWkiOlsiZ3B0LTMuNS10dXJibyJdfX0.il5Rjsad65jpQR_pyRzBdEKFSj-ERmBf4K2VksvGvswWVv4n79lYERslr4KCECuiz9y_T-xUiQ9IkhW3YHzl5zo1kajhhIg7Nhnl1AvAqODbnF6wYpLRk0Npna_2T6lK3Yj54qQGi6vXG3IMRpo1_o2DrbdlKx2k_WFegCoQyyYazb4z3ZXfWvTiWqQDJA5wWcM3-jKzAWfNM8zgZWa-1BeAHDvpLcfWtuXEGSjkdCW0FQJOTjgIEqACnnXb2Jio0tWgelh9hDPILI-tvanj3iKCjpf3uF6g8QWSBNoVFfu7F1jJgj5Aj1sX8AV-CQVu2aQx3EHRZ1mL_3w3qSRWPw
```

If you decode this token at [jwt.io](jwt.io) we should see the following claims
```
{
  "iss": "solo.io",
  "org": "solo.io",
  "sub": "alice",
  "team": "dev",
  "exp": 2074274884,
  "llms": {
    "openai": [
      "gpt-3.5-turbo"
    ]
  }
}
```

Send another request to the httpbin app. This time, you include Alice's JWT token in the Authorization header. Because these JWT tokens were signed by the JWT issuer that is used in the JWT policy, the request now succeeds. Verify that you get back a 200 HTTP response code.

This request should be successful
```bash
curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com" \
  -H "Authorization: Bearer $ALICE_TOKEN"
```

We should expect a response similar to below
```
{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InNvbG8tcHVibGljLWtleS0wMDEifQ.eyJpc3MiOiJzb2xvLmlvIiwib3JnIjoic29sby5pbyIsInN1YiI6ImFsaWNlIiwidGVhbSI6ImRldiIsImV4cCI6MjA3NDI3NDg4NCwibGxtcyI6eyJvcGVuYWkiOlsiZ3B0LTMuNS10dXJibyJdfX0.il5Rjsad65jpQR_pyRzBdEKFSj-ERmBf4K2VksvGvswWVv4n79lYERslr4KCECuiz9y_T-xUiQ9IkhW3YHzl5zo1kajhhIg7Nhnl1AvAqODbnF6wYpLRk0Npna_2T6lK3Yj54qQGi6vXG3IMRpo1_o2DrbdlKx2k_WFegCoQyyYazb4z3ZXfWvTiWqQDJA5wWcM3-jKzAWfNM8zgZWa-1BeAHDvpLcfWtuXEGSjkdCW0FQJOTjgIEqACnnXb2Jio0tWgelh9hDPILI-tvanj3iKCjpf3uF6g8QWSBNoVFfu7F1jJgj5Aj1sX8AV-CQVu2aQx3EHRZ1mL_3w3qSRWPw",
    "Content-Type": "application/json",
    "Host": "httpbin.glootest.com",
    "User-Agent": "curl/8.7.1",
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000",
    "X-Envoy-External-Address": "192.168.64.1",
    "X-Org": "solo.io",
    "X-Team": "dev"
  },
  "origin": "192.168.64.1",
  "url": "http://httpbin.glootest.com/get"
}
```

Now, lets remove this policy so that we can test JWT validation at the route-level next
```bash
kubectl delete enterprisekgatewaytrafficpolicy -n enterprise-kgateway jwt
```

## Configure JWT validation at the route-level

First let's update our route to include multiple matchers `/get` and `/anything`
```bash
kubectl apply -f - <<EOF
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
    - name: get
      backendRefs:
        - name: httpbin
          port: 8000
      matches:
        - path:
            type: PathPrefix
            value: /get
    - name: anything
      backendRefs:
        - name: httpbin
          port: 8000
      matches:
        - path:
            type: PathPrefix
            value: /anything
EOF
```

Create an EnterpriseKgatewayTrafficPolicy to enforce JWT authentication targeting a `HTTPRoute` or even a `sectionName` of a specific route rule. Note that the policy is configured in the `httpbin` namespace because the `targetRef` is to the `httpbin-route` in the same namespace. Also note that we are targeting the `sectionName: get` so this policy will only apply to the `/get` route rule, but not `/anything`
```bash
kubectl apply -f- <<EOF
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: jwt
  namespace: httpbin
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: httpbin-route
      sectionName: get
  entJWT:
    beforeExtAuth:
      providers:
        selfminted:
          issuer: solo.io
          ## -- expect the token header to come in the form of Authorization: bearer --
          tokenSource:
            headers:
            - header: "Authorization"
              prefix: "Bearer "
          ## -- set to true if the upstream application requires the token --
          keepToken: false
          jwks:
            local:
              key: '{"keys":[{"kty":"RSA","kid":"solo-public-key-001","use":"sig","alg":"RS256","n":"AOfIaJMUm7564sWWNHaXt_hS8H0O1Ew59-nRqruMQosfQqa7tWne5lL3m9sMAkfa3Twx0LMN_7QqRDoztvV3Wa_JwbMzb9afWE-IfKIuDqkvog6s-xGIFNhtDGBTuL8YAQYtwCF7l49SMv-GqyLe-nO9yJW-6wIGoOqImZrCxjxXFzF6mTMOBpIODFj0LUZ54QQuDcD1Nue2LMLsUvGa7V1ZHsYuGvUqzvXFBXMmMS2OzGir9ckpUhrUeHDCGFpEM4IQnu-9U8TbAJxKE5Zp8Nikefr2ISIG2Hk1K2rBAc_HwoPeWAcAWUAR5tWHAxx-UXClSZQ9TMFK850gQGenUp8","e":"AQAB"}]}'
          ## -- define claims that should be copied to upstream headers --
          claimsToHeaders:
          - claim: team
            header: x-team
          - claim: org
            header: x-org
EOF
```

## Validate that our route is protected by JWT

Send a request to the httpbin app. Verify that your request is denied and that you get back a 401 HTTP response code, because all routes on the gateway now require a valid JWT token from the provider.

First with no JWT, we should see a `401 Unauthorized` with an error stating `Jwt is missing`
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

Next with an invalid JWT we should also be denied access
```bash
curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.invalidsig"
```

## Confirm that our request is successful with a valid JWT

Save the JWT token for Alice. Alice works in the dev team.
```
export ALICE_TOKEN=eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InNvbG8tcHVibGljLWtleS0wMDEifQ.eyJpc3MiOiJzb2xvLmlvIiwib3JnIjoic29sby5pbyIsInN1YiI6ImFsaWNlIiwidGVhbSI6ImRldiIsImV4cCI6MjA3NDI3NDg4NCwibGxtcyI6eyJvcGVuYWkiOlsiZ3B0LTMuNS10dXJibyJdfX0.il5Rjsad65jpQR_pyRzBdEKFSj-ERmBf4K2VksvGvswWVv4n79lYERslr4KCECuiz9y_T-xUiQ9IkhW3YHzl5zo1kajhhIg7Nhnl1AvAqODbnF6wYpLRk0Npna_2T6lK3Yj54qQGi6vXG3IMRpo1_o2DrbdlKx2k_WFegCoQyyYazb4z3ZXfWvTiWqQDJA5wWcM3-jKzAWfNM8zgZWa-1BeAHDvpLcfWtuXEGSjkdCW0FQJOTjgIEqACnnXb2Jio0tWgelh9hDPILI-tvanj3iKCjpf3uF6g8QWSBNoVFfu7F1jJgj5Aj1sX8AV-CQVu2aQx3EHRZ1mL_3w3qSRWPw
```

If you decode this token at [jwt.io](jwt.io) we should see the following claims
```
{
  "iss": "solo.io",
  "org": "solo.io",
  "sub": "alice",
  "team": "dev",
  "exp": 2074274884,
  "llms": {
    "openai": [
      "gpt-3.5-turbo"
    ]
  }
}
```

Send another request to the httpbin app. This time, you include Alice's JWT token in the Authorization header. Because these JWT tokens were signed by the JWT issuer that is used in the JWT policy, the request now succeeds. Verify that you get back a 200 HTTP response code.

This request should be successful
```bash
curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com" \
  -H "Authorization: Bearer $ALICE_TOKEN"
```

We should expect a response similar to below
```
{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InNvbG8tcHVibGljLWtleS0wMDEifQ.eyJpc3MiOiJzb2xvLmlvIiwib3JnIjoic29sby5pbyIsInN1YiI6ImFsaWNlIiwidGVhbSI6ImRldiIsImV4cCI6MjA3NDI3NDg4NCwibGxtcyI6eyJvcGVuYWkiOlsiZ3B0LTMuNS10dXJibyJdfX0.il5Rjsad65jpQR_pyRzBdEKFSj-ERmBf4K2VksvGvswWVv4n79lYERslr4KCECuiz9y_T-xUiQ9IkhW3YHzl5zo1kajhhIg7Nhnl1AvAqODbnF6wYpLRk0Npna_2T6lK3Yj54qQGi6vXG3IMRpo1_o2DrbdlKx2k_WFegCoQyyYazb4z3ZXfWvTiWqQDJA5wWcM3-jKzAWfNM8zgZWa-1BeAHDvpLcfWtuXEGSjkdCW0FQJOTjgIEqACnnXb2Jio0tWgelh9hDPILI-tvanj3iKCjpf3uF6g8QWSBNoVFfu7F1jJgj5Aj1sX8AV-CQVu2aQx3EHRZ1mL_3w3qSRWPw",
    "Content-Type": "application/json",
    "Host": "httpbin.glootest.com",
    "User-Agent": "curl/8.7.1",
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000",
    "X-Envoy-External-Address": "192.168.64.1",
    "X-Org": "solo.io",
    "X-Team": "dev"
  },
  "origin": "192.168.64.1",
  "url": "http://httpbin.glootest.com/get"
}
```

### Notes to consider:
- The `EnterpriseKgatewayTrafficPolicy` specifies `keepToken: false` which will instruct Envoy to sanitize the JWT token before sending to upstream, set to `true` if you would rather keep the token in the request
- The `EnterpriseKgatewayTrafficPolicy` configures a claims-to-headers which extracts the contents of the `org` and `team` claims into `x-org` and `x-team` headers and forwarded upstream
- The `EnterpriseKgatewayTrafficPolicy` configures `tokenSource` to expect a JWT in a header with `Authorization: Bearer`, but can be customized

## Confirm behavior of request to /anything

This request should be successful without a token, becuase the JWT policy is applied to the `sectionName: get` and not the `sectionName: anything`
```bash
curl -i "$GATEWAY_IP/anything" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

## Cleanup
```
kubectl delete enterprisekgatewaytrafficpolicy -n enterprise-kgateway jwt
kubectl delete enterprisekgatewaytrafficpolicy -n httpbin jwt
```

Deploy the default `HTTPRoute` from lab `002`
```bash
kubectl apply -f - <<EOF
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
