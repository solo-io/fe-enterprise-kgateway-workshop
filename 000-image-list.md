# Image list - Solo Enterprise for Kgateway

**2.3.3**

## Helm Charts

### Enterprise Kgateway CRD Helm chart

```bash
oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds
```

### Enterprise Kgateway Helm Chart

```bash
oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway
```

## Images

As of 2.3.x, every Solo-built component ships from the same
`us-docker.pkg.dev/solo-public/enterprise-kgateway` registry at the release tag.
`ext-auth-service` and `rate-limiter` used to come from `gcr.io/gloo-mesh` — if
you are mirroring images into a private registry, update those two paths.

### controller

```bash
us-docker.pkg.dev/solo-public/enterprise-kgateway/enterprise-kgateway-controller:2.3.3
```

### kgateway-proxy

```bash
us-docker.pkg.dev/solo-public/enterprise-kgateway/envoy-wrapper:2.3.3
```

### ext-auth-service

```bash
us-docker.pkg.dev/solo-public/enterprise-kgateway/ext-auth-service:2.3.3
```

### rate-limiter

```bash
us-docker.pkg.dev/solo-public/enterprise-kgateway/rate-limiter:2.3.3
```

### waf-server

```bash
us-docker.pkg.dev/solo-public/enterprise-kgateway/waf-server:2.3.3
```

### ext-cache (redis)

```bash
docker.io/redis:8.6.4-alpine
```

## Verifying the list against a running install

```bash
kubectl get pods -n enterprise-kgateway \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
```
