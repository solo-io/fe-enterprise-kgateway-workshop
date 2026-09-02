# LAB: 001 — install: Gateway API CRDs, Enterprise kgateway CRDs, controller, proxy
LAB=lab-001-install
source "$(dirname "$0")/lib.sh"

step "Gateway API CRDs"
gwapi=$(kubectl api-resources --api-group=gateway.networking.k8s.io -o name 2>/dev/null)
for r in gatewayclasses gateways httproutes grpcroutes backendtlspolicies referencegrants \
         listenersets tcproutes tlsroutes udproutes; do
  assert_contains "Gateway API resource $r exists" "$r.gateway.networking.k8s.io" "$gwapi"
done

step "Enterprise kgateway CRDs"
crds=$(kubectl get crds -o name 2>/dev/null)
for c in authconfigs.extauth.solo.io \
         backendconfigpolicies.gateway.kgateway.dev \
         backends.gateway.kgateway.dev \
         directresponses.gateway.kgateway.dev \
         enterprisekgatewayparameters.enterprisekgateway.solo.io \
         enterprisekgatewaytrafficpolicies.enterprisekgateway.solo.io \
         gatewayextensions.gateway.kgateway.dev \
         gatewayparameters.gateway.kgateway.dev \
         httplistenerpolicies.gateway.kgateway.dev \
         listenerpolicies.gateway.kgateway.dev \
         ratelimitconfigs.ratelimit.solo.io \
         trafficpolicies.gateway.kgateway.dev \
         wafpolicies.waf.solo.io; do
  assert_contains "CRD $c installed" "$c" "$crds"
done

step "GatewayClass"
assert_eq "GatewayClass enterprise-kgateway is Accepted" True \
  "$(kubectl get gatewayclass enterprise-kgateway -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')"

step "Control plane and data plane"
for d in enterprise-kgateway ingress ext-auth-service-enterprise-kgateway \
         ext-cache-enterprise-kgateway rate-limiter-enterprise-kgateway \
         waf-server-enterprise-kgateway; do
  ready=$(kubectl get deploy -n "$GW_NS" "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  assert_eq "deployment $d has a ready replica" 1 "${ready:-0}"
done

step "Version"
tag=$(kubectl get deploy -n "$GW_NS" enterprise-kgateway -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
assert_eq "controller image tag matches the documented version" "$KGW_VERSION" "$tag"
proxy=$(kubectl get deploy -n "$GW_NS" ingress -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
assert_eq "envoy-wrapper image tag matches the documented version" "$KGW_VERSION" "$proxy"

step "Gateway"
assert_eq "Gateway ingress is Accepted" True \
  "$(kubectl get gateway -n "$GW_NS" ingress -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')"
assert_eq "Gateway ingress is Programmed" True \
  "$(kubectl get gateway -n "$GW_NS" ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
