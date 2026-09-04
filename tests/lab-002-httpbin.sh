# LAB: 002 — deploy httpbin and route to it over HTTP
LAB=lab-002-httpbin
source "$(dirname "$0")/lib.sh"

step "httpbin app"
assert_eq "httpbin deployment has a ready replica" 1 \
  "$(kubectl get deploy -n "$APP_NS" httpbin -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

step "HTTPRoute"
assert_eq "httpbin-route is Accepted by the gateway" True \
  "$(kubectl get httproute -n "$APP_NS" httpbin-route \
     -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
assert_eq "httpbin-route resolved its backendRefs" True \
  "$(kubectl get httproute -n "$APP_NS" httpbin-route \
     -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')"

step "Traffic"
wait_for_http 60 200 /get -H 'content-type: application/json'
assert_eq "GET /get through the gateway returns 200" 200 "$(http_code /get -H 'content-type: application/json')"

body=$(http_body /get -H 'content-type: application/json')
assert_contains "response echoes the request URL for the routed host" \
  "http://${HOST}/get" "$body"

hdrs=$(http_headers /get)
assert_contains "response is served by Envoy" "server: envoy" "$hdrs"
assert_contains "Envoy adds its upstream timing header" "x-envoy-upstream-service-time" "$hdrs"
assert_contains "Envoy propagates the default 15s route timeout to the backend" \
  '"X-Envoy-Expected-Rq-Timeout-Ms"' "$body"

step "Unrouted host is rejected"
assert_eq "a request for an unrouted Host gets 404" 404 \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://${GATEWAY_IP}/get" -H 'Host: nope.try-solo.io')"
