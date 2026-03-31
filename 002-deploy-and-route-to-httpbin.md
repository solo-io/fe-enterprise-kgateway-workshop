## Deploy and Route to httpbin

## Pre-requisites
This lab assumes that you have completed the setup in `001`

## Lab Objectives
- Deploy `httpbin` app
- Configure `HTTPRoute`
- Validate connectivity to the application

Deploy httpbin as our sample app
```bash
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: httpbin
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: httpbin
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
    - name: http
      port: 8000
      targetPort: 8080
    - name: tcp
      port: 9000
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
        - image: docker.io/mccutchen/go-httpbin:v2.6.0
          imagePullPolicy: IfNotPresent
          name: httpbin
          command: [ go-httpbin ]
          args:
            - "-port"
            - "8080"
            - "-max-duration"
            - "600s" # override default 10s
          ports:
            - containerPort: 8080
        - name: curl
          image: curlimages/curl:7.83.1
          resources:
            requests:
              cpu: "100m"
            limits:
              cpu: "200m"
          imagePullPolicy: IfNotPresent
          command:
            - "tail"
            - "-f"
            - "/dev/null"
EOF
```

Check to see that the httpbin application has been deployed
```bash
kubectl get pods -n httpbin
```

## Configure routing to sample app

Route to httpbin
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
        ## -- we can also use regex matching -- ##
        #- path:
        #    type: RegularExpression
        #    value: ".*"
EOF
```

## curl httpbin
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

Output should look similar to below
```
HTTP/1.1 200 OK
server: envoy
date: Tue, 02 Dec 2025 18:32:29 GMT
content-type: application/json
content-length: 334
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 10

{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Content-Type": "application/json",
    "Host": "httpbin.glootest.com",
    "User-Agent": "curl/8.7.1",
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000",
    "X-Envoy-External-Address": "10.42.0.1"
  },
  "origin": "10.42.0.1",
  "url": "http://httpbin.glootest.com/get"
}
```
