# LAB: 006 — observability: Envoy stats, control plane metrics, access logs
LAB=lab-006-observability
source "$(dirname "$0")/lib.sh"

step "Generate some traffic to have something to observe"
for _ in 1 2 3 4 5; do http_code /get >/dev/null; done
pass "sent 5 requests through the gateway"

step "Envoy admin stats on the proxy (port 19000)"
prom=$(admin_get ingress 19000 /stats/prometheus)
assert_contains "the proxy serves Prometheus-format stats" "envoy_cluster_upstream_rq" "$prom"
assert_contains "the httpbin backend cluster appears in the stats" "kube_httpbin_httpbin_8000" "$prom"

native=$(admin_get ingress 19000 /stats)
assert_contains "the proxy also serves native Envoy stats" "cluster.kube_httpbin_httpbin_8000" "$native"

step "Control plane metrics (port 9092)"
cp=$(admin_get enterprise-kgateway 9092 /metrics)
assert_contains "the control plane serves a /metrics endpoint" "kgateway_" "$cp"
assert_contains "controller reconciliations are counted" "kgateway_controller_reconciliations_total" "$cp"

step "Access logs from the lab 001 ListenerPolicy"
assert_eq "the access-logging ListenerPolicy is Accepted" True \
  "$(kubectl get listenerpolicy -n "$GW_NS" ingress-gateway-access-logging \
     -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' | head -c4)"

http_code /get >/dev/null
sleep 3
logs=$(kubectl logs -n "$GW_NS" deploy/ingress --tail=200 2>/dev/null)
assert_contains "access logs are written as JSON to stdout" '"authority"' "$logs"
assert_contains "access logs record the backend cluster" '"backendCluster"' "$logs"
assert_contains "access logs record the response code" '"response_code"' "$logs"
assert_contains "access logs record the routed hostname" "$HOST" "$logs"
