# Workshop e2e suite

Each `lab-*.sh` file replays one workshop lab against a live cluster: it applies
the same manifests the lab tells you to apply, sends real requests through the
gateway, asserts the behaviour the lab documents, then cleans up after itself.

**A failing test means the lab no longer works as written.** That is the point —
the suite is a regression check on the workshop text, not on kgateway.

## Running

```bash
./run-e2e.sh                        # every lab
./run-e2e.sh --install              # install Enterprise kgateway first, then run
./run-e2e.sh --list                 # what the suite covers
./run-e2e.sh -k waf -k jwt          # only tests whose filename matches
./run-e2e.sh --gateway-ip 1.2.3.4   # override the gateway address
./run-e2e.sh --version 2.4.0        # check the labs against a different release
./run-e2e.sh --uninstall            # tear the workshop back out of the cluster
```

Requires `kubectl`, `curl` and `openssl`. `--install`/`--uninstall` also need
`helm` and `SOLO_TRIAL_LICENSE_KEY`.

## Layout

| Path | What it is |
|---|---|
| `run-e2e.sh` | Entry point: arg parsing, install/uninstall, preflight, per-lab reporting |
| `tests/lib.sh` | Assertions, HTTP/HTTPS helpers, PKI helpers, waits, baseline restore |
| `tests/manifests/001-gateway.yaml` | The lab 001 gateway config, used by `--install` |
| `tests/manifests/002-httpbin.yaml` | The lab 002 sample app and route, used by `--install` |
| `tests/lab-0NN-*.sh` | One file per lab |

## Writing a test

Source `lib.sh`, set `LAB`, and register a cleanup trap. Every lab must leave
the cluster in the lab 001 + 002 baseline state so the labs stay independent and
the suite is re-runnable.

```bash
# LAB: 0NN — one-line description shown by --list
LAB=lab-0NN-thing
source "$(dirname "$0")/lib.sh"
trap 'kubectl delete ... --ignore-not-found >/dev/null 2>&1; restore_baseline' EXIT

step "What this section demonstrates"
assert_eq "a plain-language claim about the gateway" 200 "$(http_code /get)"
```

Helpers worth knowing:

- `http_code` / `http_body` / `http_headers` — plain HTTP through the gateway
- `https_code <host> <path>` / `https_exit` — HTTPS with SNI pinned to the gateway
- `wait_for_http` / `wait_for_https` / `wait_for` — poll until a condition holds
- `wait_policy_accepted <kind> <ns> <name>` — wait for `Accepted=True`
- `wait_for_service_port <timeout> <port>` — wait out a Service rewrite after a
  listener change, before probing the new port
- `admin_get <deploy> <port> <path>` — reach an admin endpoint through a
  port-forward; the proxy and controller images are distroless, so
  `kubectl exec … curl` does not work
- `make_ca` / `make_leaf` / `cert_subject` — PKI in a per-test temp dir (`$CERTS`)
- `observed_client_ip` — the source IP Envoy actually sees, which is what WAF
  `REMOTE_ADDR` rules match on (behind a load balancer this is the LB hop, not
  your public IP)
- `restore_baseline` — reapply the lab 001 Gateway and lab 002 HTTPRoute

## Notes on specific labs

- **003, 004, 007, 008** replace the `ingress` Gateway's listeners. They restore
  the baseline on exit, including on failure.
- **013** uses randomised `x-user-id` values so a re-run inside the same minute
  is not blocked by the previous run's rate-limit buckets.
- **014** derives the allowlisted IP from what Envoy reports as `origin` rather
  than from `ifconfig.me`, so it works on local clusters and behind a load
  balancer.
