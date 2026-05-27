# Install Enterprise Kgateway on OpenShift

In this workshop, you'll deploy Solo Enterprise for Kgateway on OpenShift and complete hands-on labs that showcase routing, security, observability features.

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

Installing the Kubernetes Gateway API custom resources is a pre-requisite to using Enterprise Kgateway.

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
```

To check if the Kubernetes Gateway API CRDs are installed

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

### Configure Required Variables
Export your Solo Trial license key variable and Enterprise Kgateway version
```bash
export SOLO_TRIAL_LICENSE_KEY=$SOLO_TRIAL_LICENSE_KEY
export KGW_VERSION=2.2.0-beta.19
```

### Enterprise Kgateway CRDs
```bash
kubectl create namespace enterprise-kgateway
```

```bash
helm upgrade -i --create-namespace --namespace enterprise-kgateway \
    --version $KGW_VERSION enterprise-kgateway-crds \
    oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds
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
--version $KGW_VERSION \
--set-string licensing.licenseKey=$SOLO_TRIAL_LICENSE_KEY \
-f -<<EOF
#--- Optional: override for image registry/tag for the controller
#image:
#  registry: us-docker.pkg.dev/solo-public/enterprise-kgateway
#  repository: enterprise-kgateway-controller
#  tag: "$KGW_VERSION"
#  pullPolicy: IfNotPresent
# --- Override the default Kgateway parameters used by this GatewayClass
# If the referenced parameters are not found, the controller will use the defaults
gatewayClassParametersRefs:
  enterprise-kgateway:
    group: enterprisekgateway.solo.io
    kind: EnterpriseKgatewayParameters
    name: kgateway-params
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
enterprise-kgateway-64ff8f5c96-sjv7p   1/1     Running   0          87s
```

## Deploy Envoy gateway with customizations
The configuration below demonstrates how to deploy Enterprise Kgateway on OpenShift with required security context configurations. The `EnterpriseKgatewayParameters` resource provides customization for deployment settings, service annotations, shared extensions (ExtAuth, RateLimit, Cache), and observability features. While this example uses the default public images, it illustrates how those images can be replaced with ones hosted in a private repository for air-gapped environments.

```bash
kubectl apply -f- <<'EOF'
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayParameters
metadata:
  name: kgateway-params
  namespace: enterprise-kgateway
spec:
  #--- Required for OpenShift---
  kube:
    deployment:
      replicas: 1
    # --- Omit default security contexts to allow OpenShift to manage UIDs
    omitDefaultSecurityContext: true
    # --- Pod-level security context
    podTemplate:
      securityContext:
        sysctls:
        - name: net.ipv4.ip_unprivileged_port_start
          value: "0"
    # --- Container-level configuration for Envoy
    envoyContainer:
      #--- Uncomment to override envoy proxy image ---
      #image:
      #  registry: us-docker.pkg.dev/solo-public/enterprise-kgateway
      #  repository: envoy-wrapper
      #  tag: ""
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          add:
          - NET_BIND_SERVICE
          drop:
          - ALL
        readOnlyRootFilesystem: true
        runAsNonRoot: true
    # --- Service configuration
    service:
      extraAnnotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      type: LoadBalancer
    ### -- Shared extensions configuration -- ###
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

Check that the Envoy gateway proxy is now running:

```bash
kubectl get pods -n enterprise-kgateway
```

Expected Output:

```bash
NAME                                                    READY   STATUS    RESTARTS   AGE
enterprise-kgateway-59747bd5b4-p4q2j                    1/1     Running   0          5m2s
ext-auth-service-enterprise-kgateway-55b85d8cf5-txctf   1/1     Running   0          4m9s
ext-cache-enterprise-kgateway-55b6f48d58-ghspc          1/1     Running   0          4m10s
ingress-7cd48bc556-h72p7                                1/1     Running   0          4m10s
rate-limiter-enterprise-kgateway-8cdb4495c-dzr4d        1/1     Running   0          4m9s
```
