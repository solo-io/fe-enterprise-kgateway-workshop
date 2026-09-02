# LAB: 014 — WAF: Coraza IP allowlisting, OWASP layering, per-rule policies
LAB=lab-014-waf
source "$(dirname "$0")/lib.sh"
cleanup() {
  kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" \
    waf-ip-policy waf-ip-policy-team-a waf-ip-policy-team-b --ignore-not-found >/dev/null 2>&1
  kubectl delete wafpolicy -n "$APP_NS" \
    ip-allowlist ip-allowlist-with-owasp ip-allowlist-team-a ip-allowlist-team-b --ignore-not-found >/dev/null 2>&1
  restore_baseline
}
trap cleanup EXIT

step "WAF server"
assert_eq "the waf-server deployment has a ready replica" 1 \
  "$(kubectl get deploy -n "$GW_NS" waf-server-enterprise-kgateway -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

# REMOTE_ADDR is whatever Envoy sees as the peer — behind a LoadBalancer that is
# the LB hop, not your public IP. Read it back off /get rather than guessing.
MY_IP=$(observed_client_ip)
if [ -z "$MY_IP" ]; then
  fail "could not determine the client IP Envoy sees" "GET /get returned no origin field"
  exit 1
fi
note "Envoy sees REMOTE_ADDR = ${MY_IP} (this is what @ipMatch tests against)"

waf_policy() {  # waf_policy <name> <customDirectives-body>
  kubectl apply -f - >/dev/null <<YAML
apiVersion: waf.solo.io/v1alpha1
kind: WAFPolicy
metadata:
  name: $1
  namespace: ${APP_NS}
spec:
  ruleEngineSettings:
    inline: |
      SecRuleEngine On
  customDirectives:
$2
YAML
}

attach_waf() {  # attach_waf <policyName> <wafPolicyRef> [sectionName]
  kubectl apply -f - >/dev/null <<YAML
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: $1
  namespace: ${APP_NS}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: httpbin-route${3:+
      sectionName: $3}
  entWAF:
    wafPolicyRef:
      name: $2
YAML
}

step "An allowlist that excludes this client blocks the request"
waf_policy ip-allowlist '    - inline: |
        SecRule REMOTE_ADDR "!@ipMatch 203.0.113.0/24,198.51.100.50" \
          "phase:1,deny,status:403,id:1,msg:'"'"'IP not in allowlist'"'"'"'
assert_ok "the WAFPolicy exists" kubectl get wafpolicy -n "$APP_NS" ip-allowlist

attach_waf waf-ip-policy ip-allowlist
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" waf-ip-policy \
  && pass "the WAF traffic policy is Accepted" \
  || fail "the WAF traffic policy is Accepted"

wait_for_http 120 403 /get -H 'content-type: application/json'
assert_eq "a client outside the allowlist gets 403" 403 "$(http_code /get -H 'content-type: application/json')"

step "Adding this client's observed IP lets it through"
waf_policy ip-allowlist "    - inline: |
        SecRule REMOTE_ADDR \"!@ipMatch ${MY_IP},203.0.113.0/24,198.51.100.50\" \\
          \"phase:1,deny,status:403,id:1,msg:'IP not in allowlist'\""
wait_for_http 120 200 /get -H 'content-type: application/json'
assert_eq "the allowlisted client now gets 200" 200 "$(http_code /get -H 'content-type: application/json')"

step "Layering OWASP-style SQLi and XSS rules on top of the allowlist"
waf_policy ip-allowlist-with-owasp "    - inline: |
        SecRule REMOTE_ADDR \"!@ipMatch ${MY_IP},203.0.113.0/24,198.51.100.50\" \\
          \"phase:1,deny,status:403,id:1,msg:'IP not in allowlist'\"
    - inline: |
        SecRule QUERY_STRING \"@rx (?i:union.*select|select.*from|drop\\\\s+table|insert\\\\s+into)\" \\
          \"phase:1,deny,status:403,id:2,msg:'SQL injection detected'\"
    - inline: |
        SecRule QUERY_STRING \"@rx (?i:%3Cscript|<script|javascript:|onerror=|onload=)\" \\
          \"phase:1,deny,status:403,id:3,msg:'XSS detected'\""
attach_waf waf-ip-policy ip-allowlist-with-owasp
wait_for_http 120 403 '/get?id=1%20UNION%20SELECT%20*%20FROM%20users'
assert_eq "a UNION SELECT query string is blocked even from an allowed IP" 403 \
  "$(http_code '/get?id=1%20UNION%20SELECT%20*%20FROM%20users')"
assert_eq "a URL-encoded <script> query string is blocked" 403 \
  "$(http_code '/get?name=%3Cscript%3Ealert(1)%3C/script%3E')"
assert_eq "a benign query string is still allowed" 200 "$(http_code '/get?name=alice')"

kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" waf-ip-policy >/dev/null 2>&1
kubectl delete wafpolicy -n "$APP_NS" ip-allowlist ip-allowlist-with-owasp >/dev/null 2>&1
wait_for_http 120 200 /get

step "Per-route-rule WAF policies via sectionName"
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
    - name: team-a
      backendRefs:
        - name: httpbin
          port: 8000
      matches:
        - path:
            type: PathPrefix
            value: /get
    - name: team-b
      backendRefs:
        - name: httpbin
          port: 8000
      matches:
        - path:
            type: PathPrefix
            value: /anything
YAML
wait_for_http 90 200 /get
assert_eq "the team-a rule serves /get" 200 "$(http_code /get)"
assert_eq "the team-b rule serves /anything" 200 "$(http_code /anything)"

waf_policy ip-allowlist-team-a '    - inline: |
        SecRule REMOTE_ADDR "!@ipMatch 203.0.113.0/24" \
          "phase:1,deny,status:403,id:1,msg:'"'"'IP not in team-a allowlist'"'"'"'
waf_policy ip-allowlist-team-b '    - inline: |
        SecRule REMOTE_ADDR "!@ipMatch 198.51.100.0/24" \
          "phase:1,deny,status:403,id:1,msg:'"'"'IP not in team-b allowlist'"'"'"'
attach_waf waf-ip-policy-team-a ip-allowlist-team-a team-a
attach_waf waf-ip-policy-team-b ip-allowlist-team-b team-b
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" waf-ip-policy-team-a \
  && pass "the team-a WAF policy is Accepted" || fail "the team-a WAF policy is Accepted"
wait_policy_accepted enterprisekgatewaytrafficpolicy "$APP_NS" waf-ip-policy-team-b \
  && pass "the team-b WAF policy is Accepted" || fail "the team-b WAF policy is Accepted"

wait_for_http 120 403 /get
assert_eq "/get is blocked by team-a's allowlist" 403 "$(http_code /get)"
assert_eq "/anything is blocked by team-b's allowlist" 403 "$(http_code /anything)"

step "Allowing this client on team-a only proves the rules are independent"
waf_policy ip-allowlist-team-a "    - inline: |
        SecRule REMOTE_ADDR \"!@ipMatch ${MY_IP},203.0.113.0/24\" \\
          \"phase:1,deny,status:403,id:1,msg:'IP not in team-a allowlist'\""
wait_for_http 120 200 /get
assert_eq "/get is allowed after updating only team-a" 200 "$(http_code /get)"
assert_eq "/anything is still blocked by team-b" 403 "$(http_code /anything)"

step "Cleanup"
kubectl delete enterprisekgatewaytrafficpolicy -n "$APP_NS" waf-ip-policy-team-a waf-ip-policy-team-b >/dev/null 2>&1
kubectl delete wafpolicy -n "$APP_NS" ip-allowlist-team-a ip-allowlist-team-b >/dev/null 2>&1
restore_baseline
assert_eq "traffic flows unfiltered once every WAF policy is removed" 200 "$(http_code /get)"
assert_eq "no WAF policies remain" "" "$(kubectl get wafpolicy -n "$APP_NS" -o name 2>/dev/null)"
