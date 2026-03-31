# Observability

## Gateway Metrics

By default, Envoy generates a comprehensive set of per-request and proxy-level metrics. These metrics are exposed through the Envoy `/stats` endpoint, enabling out-of-the-box integration with telemetry collectors like Prometheus for observability and monitoring

Port-forward the gateway deployment on port 19000
```bash
kubectl -n enterprise-kgateway port-forward deployment/ingress 19000
```

In another terminal, query the gateway metrics using Prometheus format
```bash
curl localhost:19000/stats/prometheus
```

Example output:
```
# TYPE envoy_cluster_external_upstream_rq counter
envoy_cluster_external_upstream_rq{envoy_response_code="200",envoy_cluster_name="kube_httpbin_httpbin_8000"} 5
```

or if you prefer native Envoy stats format:
```bash
curl localhost:19000/stats
```

## Control Plane Metrics

Similarly, the Enterprise Kgateway control plane also exposes a `/metrics` endpoint to monitor telemetry about the gateway environment

Port-forward the control plane deployment on port 9092
```bash
kubectl -n enterprise-kgateway port-forward deployment/enterprise-kgateway 9092
```

In another terminal, query the control plane metrics endpoint
```bash
curl localhost:9092/metrics
```

Example output
```
# HELP kgateway_controller_reconciliations_total Total controller reconciliations
# TYPE kgateway_controller_reconciliations_total counter
kgateway_controller_reconciliations_total{controller="gateway",result="success"} 1
kgateway_controller_reconciliations_total{controller="gatewayclass",result="success"} 2
kgateway_controller_reconciliations_total{controller="gatewayclass-provisioner",result="success"} 2
```


## Access Logs
Access logs, sometimes referred to as audit logs, represent all traffic requests that pass through the gateway proxy. The access log entries can be customized to include data from the request, the routing destination, and the response.

In lab `001` we configured a `ListenerPolicy` to set up access logging for our gateway. Access logs are printed to stdout

```bash
kubectl logs -n enterprise-kgateway deploy/ingress
```

Example access log
```json
{
  "authority": "httpbin.glootest.com",
  "backendCluster": "kube_httpbin_httpbin_8000",
  "backendHost": "10.42.0.12:80",
  "bytes_received": 0,
  "bytes_sent": 342,
  "method": "GET",
  "path": "/get",
  "protocol": "HTTP/1.1",
  "req_x_forwarded_for": "192.168.64.1",
  "request_id": "e2d79b3c-d1af-4961-9624-cd565dea4137",
  "resp_backend_service_time": "4",
  "response_code": 200,
  "response_flags": "-",
  "start_time": "2025-12-04T06:00:07.203Z",
  "total_duration": 4,
  "user_agent": "curl/8.7.1"
}
```

## OpenTelemetry
Gloo Gateway also supports OTEL, a flexible, open source framework that provides a set of APIs, libraries, and instrumentation to help capture and export observability data. Please refer to the [OTEL stack docs](https://docs.solo.io/gateway/latest/observability/otel-stack/) for more details
