## TLS Termination

## Pre-requisites
This lab assumes that you have completed the setup in `001` and `002`

## Lab Objectives
- Create a self-signed TLS cert
- Configure our gateway to terminate TLS
- Validate connectivity to the application over HTTPS

## References
- [Gloo Gateway Docs - HTTPS](https://docs.solo.io/gateway/latest/setup/listeners/https/)

## Create a self-signed TLS cert

Create a self-signed root certificate. The following command creates a root certificate that is valid for a year and can serve any hostname. You use this certificate to sign the server certificate for the gateway later
```bash
mkdir example_certs
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=any domain/CN=*' -keyout example_certs/root.key -out example_certs/root.crt
```

Create an OpenSSL configuration that matches the HTTPS hostname you plan to use. Replace every glootest.com reference with the base domain that your listener serves.
```bash
cat <<'EOF' > example_certs/gateway.cnf
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[ dn ]
CN = *.glootest.com
O = any domain

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = *.glootest.com
DNS.2 = glootest.com
EOF
```

Use the configuration and root certificate to create and sign the gateway certificate.
```bash
openssl req -new -nodes -keyout example_certs/gateway.key -out example_certs/gateway.csr -config example_certs/gateway.cnf

openssl x509 -req -sha256 -days 365 \
  -CA example_certs/root.crt -CAkey example_certs/root.key -set_serial 0 \
  -in example_certs/gateway.csr -out example_certs/gateway.crt \
  -extfile example_certs/gateway.cnf -extensions req_ext
```

Create a Kubernetes secret to store your server TLS certificate. You create the secret in the same cluster and namespace that the gateway is deployed to.
```bash
kubectl create secret tls -n enterprise-kgateway https \
  --key example_certs/gateway.key \
  --cert example_certs/gateway.crt
```

## Configure the gateway to terminate TLS

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

## Validate connectivity to the application over HTTPS

curl httpbin over http:
```bash
export GATEWAY_IP=$(kubectl get svc -n enterprise-kgateway --selector=gateway.networking.k8s.io/gateway-name=ingress -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}')

curl -i "$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

This should fail because we no longer have a listener on port 80
```
curl: (7) Failed to connect to 192.168.64.2 port 80 after 91 ms: Couldn't connect to server
```

curl httpbin over https, this should succeed
```bash
curl -ik "https://$GATEWAY_IP/get" \
  -H "content-type: application/json" \
  -H "Host: httpbin.glootest.com"
```

## Cleanup

Clean up objects created in this lab
```bash
rm -rf example_certs
kubectl delete gateway -n enterprise-kgateway ingress
kubectl delete httproute httpbin-route -n httpbin
kubectl delete secret -n enterprise-kgateway https
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
