# LAB: 005 — JWT validation at the gateway and at a single route rule
LAB=lab-005-jwt
source "$(dirname "$0")/lib.sh"
cleanup() {
  kubectl delete enterprisekgatewaytrafficpolicy -n "$GW_NS" jwt --ignore-not-found >/dev/null 2>&1
  kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" jwt --ignore-not-found >/dev/null 2>&1
  restore_baseline
}
trap cleanup EXIT

# Alice: iss=solo.io, org=solo.io, sub=alice, team=dev — signed by solo-public-key-001.
ALICE_TOKEN=eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InNvbG8tcHVibGljLWtleS0wMDEifQ.eyJpc3MiOiJzb2xvLmlvIiwib3JnIjoic29sby5pbyIsInN1YiI6ImFsaWNlIiwidGVhbSI6ImRldiIsImV4cCI6MjA3NDI3NDg4NCwibGxtcyI6eyJvcGVuYWkiOlsiZ3B0LTMuNS10dXJibyJdfX0.il5Rjsad65jpQR_pyRzBdEKFSj-ERmBf4K2VksvGvswWVv4n79lYERslr4KCECuiz9y_T-xUiQ9IkhW3YHzl5zo1kajhhIg7Nhnl1AvAqODbnF6wYpLRk0Npna_2T6lK3Yj54qQGi6vXG3IMRpo1_o2DrbdlKx2k_WFegCoQyyYazb4z3ZXfWvTiWqQDJA5wWcM3-jKzAWfNM8zgZWa-1BeAHDvpLcfWtuXEGSjkdCW0FQJOTjgIEqACnnXb2Jio0tWgelh9hDPILI-tvanj3iKCjpf3uF6g8QWSBNoVFfu7F1jJgj5Aj1sX8AV-CQVu2aQx3EHRZ1mL_3w3qSRWPw
BAD_TOKEN=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.invalidsig
JWKS='{"keys":[{"kty":"RSA","kid":"solo-public-key-001","use":"sig","alg":"RS256","n":"AOfIaJMUm7564sWWNHaXt_hS8H0O1Ew59-nRqruMQosfQqa7tWne5lL3m9sMAkfa3Twx0LMN_7QqRDoztvV3Wa_JwbMzb9afWE-IfKIuDqkvog6s-xGIFNhtDGBTuL8YAQYtwCF7l49SMv-GqyLe-nO9yJW-6wIGoOqImZrCxjxXFzF6mTMOBpIODFj0LUZ54QQuDcD1Nue2LMLsUvGa7V1ZHsYuGvUqzvXFBXMmMS2OzGir9ckpUhrUeHDCGFpEM4IQnu-9U8TbAJxKE5Zp8Nikefr2ISIG2Hk1K2rBAc_HwoPeWAcAWUAR5tWHAxx-UXClSZQ9TMFK850gQGenUp8","e":"AQAB"}]}'

jwt_policy() {  # jwt_policy <namespace> <targetRef-yaml-block>
  kubectl apply -f - >/dev/null <<YAML
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: jwt
  namespace: $1
spec:
  targetRefs:
$2
  entJWT:
    beforeExtAuth:
      providers:
        selfminted:
          issuer: solo.io
          tokenSource:
            headers:
            - header: "Authorization"
              prefix: "Bearer "
          keepToken: false
          jwks:
            local:
              key: '${JWKS}'
          claimsToHeaders:
          - claim: team
            header: x-team
          - claim: org
            header: x-org
YAML
}

step "Gateway-level JWT policy"
jwt_policy "$GW_NS" "    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ingress"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$GW_NS" jwt \
  && pass "the gateway JWT policy is Accepted" \
  || fail "the gateway JWT policy is Accepted"

wait_for_http 90 401 /get
assert_eq "a request with no token is rejected with 401" 401 "$(http_code /get -H 'content-type: application/json')"
assert_contains "the rejection says the JWT is missing" "Jwt is missing" "$(http_body /get)"
assert_eq "a request with an invalid signature is rejected with 401" 401 \
  "$(http_code /get -H "Authorization: Bearer ${BAD_TOKEN}")"
assert_eq "a request with Alice's valid token succeeds" 200 \
  "$(http_code /get -H "Authorization: Bearer ${ALICE_TOKEN}")"

body=$(http_body /get -H "Authorization: Bearer ${ALICE_TOKEN}")
assert_contains "the team claim is forwarded as x-team" '"X-Team"' "$body"
assert_contains "x-team carries the claim value" 'dev' "$body"
assert_contains "the org claim is forwarded as x-org" '"X-Org"' "$body"

step "keepToken: false strips the token before the backend sees it"
assert_not_contains "the Authorization header is not forwarded upstream" \
  "$ALICE_TOKEN" "$body"

kubectl delete enterprisekgatewaytrafficpolicy -n "$GW_NS" jwt >/dev/null 2>&1
wait_for_http 90 200 /get

step "Route-rule-level JWT policy via sectionName"
kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: ${APP_NS}
spec:
  hostnames:
  - "${HOST}"
  parentRefs:
    - name: ingress
      namespace: ${GW_NS}
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
YAML
jwt_policy "$APP_NS" "    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: httpbin-route
      sectionName: get"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" jwt \
  && pass "the route-scoped JWT policy is Accepted" \
  || fail "the route-scoped JWT policy is Accepted"

wait_for_http 90 401 /get
assert_eq "/get (sectionName: get) requires a token" 401 "$(http_code /get)"
assert_eq "/get with Alice's token succeeds" 200 "$(http_code /get -H "Authorization: Bearer ${ALICE_TOKEN}")"
assert_eq "/anything is untouched by the policy and needs no token" 200 "$(http_code /anything)"
