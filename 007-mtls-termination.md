## mTLS Termination

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Create a self-signed mTLS cert
- Configure our gateway to terminate mTLS
- Validate connectivity to the application over mTLS

## Create a self-signed TLS cert

Create a root certificate for the glootest.com domain. You use this certificate to sign the certificate for your client and gateway later.
```bash
mkdir example_certs
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=Solo.io/CN=glootest.com' -keyout example_certs/glootest.com.key -out example_certs/glootest.com.crt
```

Create a gateway certificate that is signed by the root CA certificate that you created in the previous step.
```bash
openssl req -out example_certs/gateway.csr -newkey rsa:2048 -nodes -keyout example_certs/gateway.key -subj "/CN=*/O=any domain"

openssl x509 -req -sha256 -days 365 -CA example_certs/glootest.com.crt -CAkey example_certs/glootest.com.key -set_serial 0 -in example_certs/gateway.csr -out example_certs/gateway.crt
```

Create a Kubernetes secret to store your gateway TLS certificate.
```bash
kubectl create secret tls -n enterprise-kgateway https \
  --key example_certs/gateway.key \
  --cert example_certs/gateway.crt
```

Create a ConfigMap to store the CA certificate for mTLS client validation.
```bash
kubectl create configmap -n enterprise-kgateway ca-cert \
  --from-file=ca.crt=example_certs/glootest.com.crt
```

Create a client certificate and private key. You use these credentials later when sending a request to the gateway proxy. The client certificate is signed with the same root CA certificate that you used for the gateway proxy.
```bash
openssl req -out example_certs/client.glootest.com.csr -newkey rsa:2048 -nodes -keyout example_certs/client.glootest.com.key -subj "/CN=client.glootest.com/O=client organization"

openssl x509 -req -sha256 -days 365 -CA example_certs/glootest.com.crt -CAkey example_certs/glootest.com.key -set_serial 1 -in example_certs/client.glootest.com.csr -out example_certs/client.glootest.com.crt
```

## Configure the gateway to terminate mTLS

Configure the gateway with frontend TLS validation to require client certificates. The `spec.tls.frontend.default.validation` section enables mTLS by referencing the CA certificate ConfigMap.

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: enterprise-kgateway
spec:
  gatewayClassName: enterprise-kgateway
  tls:
    frontend:
      default:
        validation:
          mode: AllowValidOnly
          caCertificateRefs:
            - name: ca-cert
              kind: ConfigMap
              group: ""
  listeners:
    - protocol: HTTPS
      port: 443
      name: https
      tls:
        mode: Terminate
        certificateRefs:
          - name: https
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
EOF
```

## Validate application access without a client mTLS certificate

curl httpbin without a client cert, this should fail with a TLS handshake error
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -ikv "https://$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

Expected output (connection should fail):
```
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Request CERT (13):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Certificate (11):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* TLSv1.3 (IN), TLS alert, unknown (628):
* OpenSSL/3.0.2: error:0A00045C:SSL routines::tlsv13 alert certificate required
* Closing connection
curl: (35) OpenSSL/3.0.2: error:0A00045C:SSL routines::tlsv13 alert certificate required
```

## Validate application access with a trusted client mTLS certificate

curl httpbin with the valid client cert that we created earlier, this should succeed
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -ik "https://$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com" \
  --cert example_certs/client.glootest.com.crt \
  --key example_certs/client.glootest.com.key \
  --cacert example_certs/gateway.crt
```

Expected output (should succeed with HTTP 200):
```
HTTP/2 200
server: envoy
date: Thu, 09 Jan 2026 03:45:00 GMT
content-type: application/json
content-length: 308
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 4

{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.glootest.com",
    "User-Agent": "curl/8.7.1",
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000",
    "X-Envoy-External-Address": "192.168.64.1"
  },
  "origin": "192.168.64.1",
  "url": "https://httpbin.glootest.com/get"
}
```


## Cleanup
```bash
rm -rf example_certs
kubectl delete gateway -n enterprise-kgateway ingress
kubectl delete secret -n enterprise-kgateway https
kubectl delete configmap -n enterprise-kgateway ca-cert
```

Deploy the default `Gateway` and `HTTPRoute` from lab `001` and `002`
```bash
kubectl apply -f - <<EOF
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
EOF
```
