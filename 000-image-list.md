# Image list - Solo Enterprise for Kgateway

**2.1.0:**

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

### controller

```bash
us-docker.pkg.dev/solo-public/enterprise-kgateway/enterprise-kgateway-controller:2.1.0
```

### kgateway-proxy

```bash
us-docker.pkg.dev/solo-public/enterprise-kgateway/envoy-wrapper:2.1.0
```

### ext-cache (redis)

```bash
docker.io/redis:7.2.12-alpine
```

### ext-auth-service

```bash
gcr.io/gloo-mesh/ext-auth-service:0.71.4
```

### rate-limiter

```bash
gcr.io/gloo-mesh/rate-limiter:0.17.2
```
