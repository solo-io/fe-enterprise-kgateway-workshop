# Enterprise Kgateway Workshop

This workshop demonstrates Solo Enterprise for Kgateway with hands-on labs covering routing, security, and observability features.

# Labs
- [001-set-up-enterprise-kgateway.md](001-set-up-enterprise-kgateway.md)
- [002-deploy-and-route-to-httpbin.md](002-deploy-and-route-to-httpbin.md)
- [003-tls-termination.md](003-tls-termination.md)
- [004-SNI-matching.md](004-SNI-matching.md)
- [005-JWT-validation.md](005-JWT-validation.md)
- [006-observability.md](006-observability.md)
- [007-mtls-termination.md](007-mtls-termination.md)
- [008-multi-tenant-mtls.md](008-multi-tenant-mtls.md)
- [009-buffering.md](009-buffering.md)
- [010-timeouts-and-retries.md](010-timeouts-and-retries.md)
- [011-global-policy-attachment.md](011-global-policy-attachment.md)
- [012-backend-config-policy.md](012-backend-config-policy.md)
- [013-rate-limiting.md](013-rate-limiting.md)
- [014-waf.md](014-waf.md)

# Use Cases
- Support Kubernetes Gateway API
- Install Enterprise Kgateway
- Configure kgateway for production-grade traffic management
- Advanced Traffic Routing
    - HTTP/HTTPS traffic routing
    - Path-based routing
    - Host-based routing
    - Header-based routing
- TLS/SSL Management
    - TLS termination
    - SNI (Server Name Indication) matching
    - Multi-tenant mTLS configurations
    - Certificate management
- Security & Access Control
    - JWT authentication and validation
    - mTLS (mutual TLS) termination
    - Token-based authentication
    - Role-Based Access Control (RBAC)
    - Multi-tenant security isolation
- Observability & Monitoring
    - Request/response metrics
    - Distributed tracing
    - Access logging
    - Integration with monitoring tools
- Traffic Management & Resilience
    - Request buffering
    - Timeout configuration
    - Retry policies
    - Rate limiting (request-based)
    - Backend failover
- Policy Management
    - Global policy attachment
    - Backend configuration policies
    - Hierarchical policy application
- Enterprise Features
    - Multi-tenant support
    - Production-grade security
    - Advanced traffic shaping
    - Policy-based governance


## End-to-end tests

Every lab in this repo has a matching test that replays it against a live
cluster. Run the whole thing with:

```bash
export SOLO_TRIAL_LICENSE_KEY=<your key>
./run-e2e.sh --install     # install Enterprise kgateway, then run every lab
./run-e2e.sh               # re-run against an already-installed cluster
./run-e2e.sh --list        # see what is covered
./run-e2e.sh -k waf        # run one lab
```

A failing test means the lab text no longer matches what the product does. See
[tests/README.md](tests/README.md) for the helpers and how to add a lab.

## Validated on
- Kubernetes 1.29.4 - 1.33.5
- Enterprise Kgateway 2.3.3
- Kubernetes Gateway API 1.5.0 (experimental channel)


## User Stories / Acceptance Criteria

As a platform operator, I want to deploy a production-grade Kubernetes Gateway API implementation that provides advanced traffic management, security, and observability capabilities, so that I can deliver reliable, secure, and observable application networking for multiple teams and tenants.

---

This section is a comprehensive list of all the functionality and data requirements.

#### Gateway API Compliance
- The Enterprise Kgateway must fully implement the Kubernetes Gateway API specification.
- Support for HTTPRoute, Gateway, and GatewayClass resources.
- The gateway can be configured to handle multiple tenants with isolated traffic routing and security policies.

#### Advanced Traffic Routing
- The platform operator can configure traffic routing based on multiple criteria: paths, hosts, headers, and query parameters.
- Support for weighted traffic splitting for canary deployments and A/B testing.
- Backend service discovery and load balancing across multiple endpoints.

#### Comprehensive Security
- The gateway must support TLS termination with certificate management.
- SNI-based routing for multiple domains and certificates.
- JWT validation for API authentication with configurable claim extraction and validation.
- Mutual TLS (mTLS) support for service-to-service authentication.
- Multi-tenant mTLS configurations with isolated certificate authorities per tenant.

#### Enterprise-Grade Resilience
- Configurable timeout policies at the route and backend levels.
- Retry policies with configurable conditions and backoff strategies.
- Request buffering to handle slow clients and protect backend services.
- Rate limiting to protect backends from traffic spikes and ensure fair resource usage.

#### Observability & Monitoring
- The gateway must expose detailed metrics for requests, responses, latencies, and error rates.
- Integration with distributed tracing systems (Jaeger, Zipkin) for request flow visibility.
- Structured access logging with request metadata and identifiers.
- Health check endpoints for monitoring gateway status.

#### Policy Management
- Support for hierarchical policy attachment (global, gateway, route levels).
- Backend configuration policies for timeout, retry, and connection settings.
- Policy inheritance and override mechanisms for flexible configuration.
- Audit trail for policy changes and configuration updates.

#### Multi-Tenant Support
- Isolated routing configurations per tenant or namespace.
- Tenant-specific security policies and certificates.
- Resource quotas and limits per tenant.
- Clear separation of concerns for tenant workloads.

---

### Why This is Important

This functionality is crucial for operating a production-grade Kubernetes Gateway and directly addresses critical business needs:

- **Operational Excellence:** Advanced traffic management, resilience, and observability features ensure reliable application delivery and quick problem resolution.
- **Security at Scale:** Multi-layered security with TLS, mTLS, and JWT validation protects applications and data across all tenants and services.
- **Multi-Tenant Isolation:** Clear separation of routing, security, and policies enables platform teams to serve multiple applications and tenants safely on shared infrastructure.
- **Developer Productivity:** Standardized Gateway API resources and policy abstractions make it easier for application teams to configure networking without deep infrastructure knowledge.
- **Cost Efficiency:** Rate limiting, buffering, and resilient backend connections protect infrastructure and prevent resource waste from misconfigured or misbehaving applications.
- **Compliance & Governance:** Policy-based configuration and detailed audit logs support regulatory requirements and organizational governance standards.
