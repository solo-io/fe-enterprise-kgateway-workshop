# Install Enterprise Kgateway

In this workshop, you'll deploy Solo Enterprise for Kgateway with Envoy and complete hands-on labs that showcase routing, security, observability features.

## Pre-requisites
- Kubernetes > 1.30
- Kubernetes Gateway API

## Lab Objectives
- Configure Kubernetes Gateway API CRDs
- Configure Enterprise Kgateway CRDs
- Install Enterprise Kgateway Controller
- Configure Envoy gateway
- Validate that components are installed

### Kubernetes Gateway API CRDs

Installing the Kubernetes Gateway API custom resources is a pre-requisite to using Enterprise Kgateway. We're using the experimental CRDs to enable advanced features like mTLS frontend validation (lab 007).

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/experimental-install.yaml
```

To check if the the Kubernetes Gateway API CRDS are installed

```bash
kubectl api-resources --api-group=gateway.networking.k8s.io
```

Expected Output (experimental CRDs include additional resources like TCPRoute, TLSRoute, UDPRoute):

```bash
NAME                 SHORTNAMES   APIVERSION                          NAMESPACED   KIND
backendtlspolicies   btlspolicy   gateway.networking.k8s.io/v1        true         BackendTLSPolicy
gatewayclasses       gc           gateway.networking.k8s.io/v1        false        GatewayClass
gateways             gtw          gateway.networking.k8s.io/v1        true         Gateway
grpcroutes                        gateway.networking.k8s.io/v1        true         GRPCRoute
httproutes                        gateway.networking.k8s.io/v1        true         HTTPRoute
referencegrants      refgrant     gateway.networking.k8s.io/v1beta1   true         ReferenceGrant
tcproutes                         gateway.networking.k8s.io/v1alpha2  true         TCPRoute
tlsroutes                         gateway.networking.k8s.io/v1alpha2  true         TLSRoute
udproutes                         gateway.networking.k8s.io/v1alpha2  true         UDPRoute
```

## Install Enterprise Kgateway

### License Key Details

Solo Trial License Key - Expires: X-XX-XX
```
<TRIAL_LICENSE_HERE>
```

### Configure Required Variables
Export your Solo Trial license key variable and Enterprise Kgateway version
```bash
export SOLO_TRIAL_LICENSE_KEY=$SOLO_TRIAL_LICENSE_KEY
export GLOO_VERSION=2.2.0-beta.9
```

### Enterprise Kgateway CRDs
```bash
helm install enterprise-kgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds \
  --version $GLOO_VERSION \
  --namespace enterprise-kgateway \
  --create-namespace
```

To check if the Enterprise Kgateway CRDs are installed:

```bash
kubectl get crds | grep -E "solo.io|kgateway" | awk '{ print $1 }'
```

Expected output

```bash
authconfigs.extauth.solo.io
backendconfigpolicies.gateway.kgateway.dev
backends.gateway.kgateway.dev
directresponses.gateway.kgateway.dev
enterprisekgatewayparameters.enterprisekgateway.solo.io
enterprisekgatewaytrafficpolicies.enterprisekgateway.solo.io
gatewayextensions.gateway.kgateway.dev
gatewayparameters.gateway.kgateway.dev
httplistenerpolicies.gateway.kgateway.dev
listenerpolicies.gateway.kgateway.dev
ratelimitconfigs.ratelimit.solo.io
trafficpolicies.gateway.kgateway.dev
```

## Install Enterprise Kgateway Controller
Using Helm:
```bash
helm upgrade -i -n enterprise-kgateway enterprise-kgateway oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway \
--create-namespace \
--version $GLOO_VERSION \
--set-string licensing.licenseKey=$SOLO_TRIAL_LICENSE_KEY \
-f -<<EOF
#--- Optional: override for image registry/tag for the controller
#image:
#  registry: us-docker.pkg.dev/solo-public/enterprise-kgateway
#  repository: enterprise-kgateway-controller
#  tag: "$GLOO_VERSION"
#  pullPolicy: IfNotPresent
# --- Override the default Kgateway parameters used by this GatewayClass
# If the referenced parameters are not found, the controller will use the defaults
gatewayClassParametersRefs:
  enterprise-kgateway:
    group: enterprisekgateway.solo.io
    kind: EnterpriseKgatewayParameters
    name: ingress-params
    namespace: enterprise-kgateway
EOF
```

Check that the Enterprise Kgateway Controller is now running:

```bash
kubectl get pods -n enterprise-kgateway -l app.kubernetes.io/name=enterprise-kgateway
```

Expected Output:

```bash
NAME                                   READY   STATUS    RESTARTS   AGE
enterprise-kgateway-64ff8f5c96-sjv7p   1/1     Running   0          3h17m
```

## Configure Envoy

We configure Envoy by applying a `Gateway` resource with the new `enterprise-kgateway` GatewayClass. We are also going to apply the `ListenerPolicy` to enable access logging
```bash
kubectl apply -f- <<EOF
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayParameters
metadata:
  name: ingress-params
  namespace: enterprise-kgateway
spec:
  kube:
    #--- Image overrides for deployment ---
    #envoyContainer:
    #  image:
    #    registry: us-docker.pkg.dev/solo-public/enterprise-kgateway
    #    repository: envoy-wrapper
    #    tag: ""
    # --- uncomment to override service fields
    service:
      extraAnnotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        service.beta.kubernetes.io/aws-load-balancer-source-ranges: 0.0.0.0/0
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
      extraLabels:
        foo: bar
      type: LoadBalancer
      externalTrafficPolicy: Local
    sharedExtensions:
      extauth:
        enabled: true
        replicas: 1
        #--- Image overrides for deployment ---
        #container:
        #  image:
        #    registry: gcr.io
        #    repository: gloo-mesh/ext-auth-service
        #    tag: ""
      ratelimiter:
        enabled: true
        replicas: 1
        #--- Image overrides for deployment ---
        #container:
        #  image:
        #    registry: gcr.io
        #    repository: gloo-mesh/rate-limiter
        #    tag: ""
      extCache:
        enabled: true
        replicas: 1
        #--- Image overrides for deployment ---
        #container:
        #  image:
        #    registry: docker.io
        #    repository: redis
        #    tag: ""
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: enterprise-kgateway
spec:
  gatewayClassName: enterprise-kgateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
---
apiVersion: gateway.kgateway.dev/v1alpha1
kind: ListenerPolicy
metadata:
  name: ingress-gateway-access-logging
  namespace: enterprise-kgateway
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ingress
  default:
    httpSettings:
      accessLog:
        - fileSink:
            path: /dev/stdout
            jsonFormat:
              start_time: "%START_TIME%"
              method: "%REQ(X-ENVOY-ORIGINAL-METHOD?:METHOD)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              protocol: "%PROTOCOL%"
              response_code: "%RESPONSE_CODE%"
              response_flags: "%RESPONSE_FLAGS%"
              bytes_received: "%BYTES_RECEIVED%"
              bytes_sent: "%BYTES_SENT%"
              total_duration: "%DURATION%"
              resp_backend_service_time: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
              req_x_forwarded_for: "%REQ(X-FORWARDED-FOR)%"
              user_agent: "%REQ(USER-AGENT)%"
              request_id: "%REQ(X-REQUEST-ID)%"
              authority: "%REQ(:AUTHORITY)%"
              backendHost: "%UPSTREAM_HOST%"
              backendCluster: "%UPSTREAM_CLUSTER%"
EOF
```

Check that our ingress pod is now running:

```bash
kubectl get pods -n enterprise-kgateway
```

Expected Output:

```bash
NAME                                                     READY   STATUS    RESTARTS   AGE
enterprise-kgateway-64775757bb-95p2k                     1/1     Running   0          6m19s
ext-auth-service-enterprise-kgateway-77b54676fd-nc7bh    1/1     Running   0          2m52s
gloo-ext-cache-enterprise-kgateway-6b7fd78658-t5w6v      1/1     Running   0          2m53s
ingress-5b4b77984d-dj9c4                                 1/1     Running   0          2m53s
rate-limiter-enterprise-kgateway-747f464cbd-jm5g7        1/1     Running   0          2m52s
```
