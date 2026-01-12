## SNI Matching
In this guide, you learn how to set up an HTTPS Gateway that serves two different domains, `httpbin-foo.glootest.com` and `httpbin-bar.glootest.com` on the same port 443. When sending a request to the Gateway, you indicate the hostname you want to connect to. Based on the selected hostname, the Gateway presents the hostname-specific certificate.

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Create self-signed TLS certs for `httpbin-foo.glootest.com` and `httpbin-bar.glootest.com`
- Configure our gateway to terminate TLS with SNI matching
- Validate connectivity to the application over HTTPS

## References
- [Gloo Gateway Docs - SNI](https://docs.solo.io/gateway/latest/setup/listeners/sni/)

## Create a self-signed TLS cert

Create a root certificate for the glootest.com domain. You use this certificate to sign the certificate for your client and gateway later.
```bash
mkdir example_certs
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=Solo.io/CN=glootest.com' -keyout example_certs/glootest.com.key -out example_certs/glootest.com.crt
```

Create a gateway certificate that is signed by the root CA certificate that you created in the previous step.

First for httpbin-foo.glootest.com
```bash
openssl req -out example_certs/httpbin-foo.glootest.com.csr -newkey rsa:2048 -nodes -keyout example_certs/httpbin-foo.glootest.com.key -subj "/CN=httpbin-foo.glootest.com/O=httpbin organization"

openssl x509 -req -sha256 -days 365 -CA example_certs/glootest.com.crt -CAkey example_certs/glootest.com.key -set_serial 0 -in example_certs/httpbin-foo.glootest.com.csr -out example_certs/httpbin-foo.glootest.com.crt
```

Then for httpbin-bar.glootest.com
```bash
openssl req -out example_certs/httpbin-bar.glootest.com.csr -newkey rsa:2048 -nodes -keyout example_certs/httpbin-bar.glootest.com.key -subj "/CN=httpbin-bar.glootest.com/O=solo.io"

openssl x509 -req -sha256 -days 365 -CA example_certs/glootest.com.crt -CAkey example_certs/glootest.com.key -set_serial 1 -in example_certs/httpbin-bar.glootest.com.csr -out example_certs/httpbin-bar.glootest.com.crt
```

Store the credentials for the httpbin-foo.glootest.com domain in a Kubernetes secret.
```bash
kubectl create -n enterprise-kgateway secret tls foo \
--key=example_certs/httpbin-foo.glootest.com.key \
--cert=example_certs/httpbin-foo.glootest.com.crt

kubectl create -n enterprise-kgateway secret tls bar \
--key=example_certs/httpbin-bar.glootest.com.key \
--cert=example_certs/httpbin-bar.glootest.com.crt
```

## Set up SNI Routing

Set up an SNI Gateway that serves multiple hosts on the same port
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
  infrastructure:
    parametersRef:
      group: enterprisekgateway.solo.io
      kind: EnterpriseKgatewayParameters
      name: ingress-params
  listeners:
    - protocol: HTTPS
      port: 443
      name: foo
      hostname: httpbin-foo.glootest.com
      tls:
        mode: Terminate
        certificateRefs:
          - name: foo
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
    - protocol: HTTPS
      port: 443
      name: bar
      hostname: "httpbin-bar.glootest.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: bar
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All
EOF
```

Next create our HTTPRoutes. Here we are going to create `httpbin-foo`, `httpbin-bar`, and `httpbin-baz`. We should expect:
- A request to `httpbin-foo` and `httpbin-bar` will succeed
- A request to `httpbin-baz` will fail TLS

```bash
kubectl apply -f - <<EOF
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-foo-route
  namespace: httpbin
spec:
  hostnames:
  - "httpbin-foo.glootest.com"
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-bar-route
  namespace: httpbin
spec:
  hostnames:
  - "httpbin-bar.glootest.com"
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
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-baz-route
  namespace: httpbin
spec:
  hostnames:
  - "httpbin-baz.glootest.com"
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

## Validate connectivity to the application over HTTPS

curl httpbin-foo over https:
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -ikv --resolve "httpbin-foo.glootest.com:443:${GATEWAY_IP}" https://httpbin-foo.glootest.com:443/get
```

We can see the TLS handshake occurring
```
* Connected to httpbin-foo.glootest.com (192.168.64.2) port 443
* ALPN: curl offers h2,http/1.1
* (304) (OUT), TLS handshake, Client hello (1):
* (304) (IN), TLS handshake, Server hello (2):
* (304) (IN), TLS handshake, Unknown (8):
* (304) (IN), TLS handshake, Certificate (11):
* (304) (IN), TLS handshake, CERT verify (15):
* (304) (IN), TLS handshake, Finished (20):
* (304) (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / AEAD-CHACHA20-POLY1305-SHA256 / [blank] / UNDEF
* ALPN: server did not agree on a protocol. Uses default.
* Server certificate:
*  subject: CN=httpbin-foo.glootest.com; O=httpbin organization
*  start date: Dec  4 00:33:14 2025 GMT
*  expire date: Dec  4 00:33:14 2026 GMT
*  issuer: O=Solo.io; CN=glootest.com
```

curl httpbin-bar over http:
```bash
curl -ikv --resolve "httpbin-bar.glootest.com:443:${GATEWAY_IP}" https://httpbin-bar.glootest.com:443/get
```

Again we can see the TLS handshake occurring, but this time for `httpbin-bar.glootest.com`
```
* Connected to httpbin-bar.glootest.com (192.168.64.2) port 443
* ALPN: curl offers h2,http/1.1
* (304) (OUT), TLS handshake, Client hello (1):
* (304) (IN), TLS handshake, Server hello (2):
* (304) (IN), TLS handshake, Unknown (8):
* (304) (IN), TLS handshake, Certificate (11):
* (304) (IN), TLS handshake, CERT verify (15):
* (304) (IN), TLS handshake, Finished (20):
* (304) (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / AEAD-CHACHA20-POLY1305-SHA256 / [blank] / UNDEF
* ALPN: server did not agree on a protocol. Uses default.
* Server certificate:
*  subject: CN=httpbin-bar.glootest.com; O=solo.io
*  start date: Dec  4 00:33:14 2025 GMT
*  expire date: Dec  4 00:33:14 2026 GMT
*  issuer: O=Solo.io; CN=glootest.com
```

Now curl httpbin-baz over http:
```bash
curl -ikv --resolve "httpbin-baz.glootest.com:443:${GATEWAY_IP}" https://httpbin-baz.glootest.com:443/get
```

Although this is a valid route, this request should fail
```
* (304) (OUT), TLS handshake, Client hello (1):
* Recv failure: Connection reset by peer
```

✅ The TCP connection was accepted
✅ ClientHello was sent (with SNI)
❌ Envoy immediately reset the connection
❌ TLS never reached certificate negotiation
❌ HTTP never happened


## Cleanup

Clean up objects created in this lab
```bash
rm -rf example_certs
kubectl delete gateway -n enterprise-kgateway ingress
kubectl delete httproute -n httpbin httpbin-bar-route
kubectl delete httproute -n httpbin httpbin-baz-route
kubectl delete httproute -n httpbin httpbin-foo-route
kubectl delete secret -n enterprise-kgateway foo
kubectl delete secret -n enterprise-kgateway bar
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
  infrastructure:
    parametersRef:
      group: enterprisekgateway.solo.io
      kind: EnterpriseKgatewayParameters
      name: ingress-params
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
