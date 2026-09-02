# Shared helpers for the workshop e2e suite.
#
# Every lab test sources this file. Assertions print a one-line ✓/✗ and append
# to $E2E_RESULTS so run-e2e.sh can total them up across test processes.

set -uo pipefail

: "${GATEWAY_IP:?GATEWAY_IP must be set (run-e2e.sh exports it)}"
: "${E2E_RESULTS:?E2E_RESULTS must be set (run-e2e.sh exports it)}"

GW_NS=enterprise-kgateway
APP_NS=httpbin
HOST=httpbin.glootest.com

# --- output ------------------------------------------------------------------

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_DIM=; C_OFF=
fi

step()  { printf '\n%s── %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
note()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

pass()  { printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$1"; echo "PASS $LAB :: $1" >>"$E2E_RESULTS"; }
fail()  { printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; echo "FAIL $LAB :: $1" >>"$E2E_RESULTS"; }
skip()  { printf '  %s-%s %s (skipped: %s)\n' "$C_YEL" "$C_OFF" "$1" "${2:-}"; echo "SKIP $LAB :: $1" >>"$E2E_RESULTS"; }

# --- assertions --------------------------------------------------------------

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *)      fail "$1" "expected to contain '$2'" ;;
  esac
}

# assert_not_contains <description> <needle> <haystack>
assert_not_contains() {
  case "$3" in
    *"$2"*) fail "$1" "expected NOT to contain '$2'" ;;
    *)      pass "$1" ;;
  esac
}

# assert_ok <description> <cmd...> — passes if the command exits 0
assert_ok() {
  local desc=$1; shift
  local out
  if out=$("$@" 2>&1); then pass "$desc"; else fail "$desc" "${out%%$'\n'*}"; fi
}

# --- HTTP --------------------------------------------------------------------

# http_code <path> [curl args...] — plain HTTP through the gateway, prints status
http_code() {
  local path=$1; shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "http://${GATEWAY_IP}${path}" -H "Host: ${HOST}" "$@" 2>/dev/null; true
}

# http_body <path> [curl args...]
http_body() {
  local path=$1; shift
  curl -s --max-time 20 "http://${GATEWAY_IP}${path}" -H "Host: ${HOST}" "$@" 2>/dev/null
}

# http_headers <path> [curl args...]
http_headers() {
  local path=$1; shift
  curl -s -D - -o /dev/null --max-time 20 "http://${GATEWAY_IP}${path}" -H "Host: ${HOST}" "$@" 2>/dev/null
}

# https_code <hostname> <path> [curl args...] — HTTPS with SNI pinned to the gateway
https_code() {
  local host=$1 path=$2; shift 2
  curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
    --resolve "${host}:443:${GATEWAY_IP}" "https://${host}${path}" "$@" 2>/dev/null; true
}

# https_exit <hostname> <path> [curl args...] — prints curl's exit code (for
# handshake failures, where there is no HTTP status at all)
https_exit() {
  local host=$1 path=$2; shift 2
  curl -sk -o /dev/null --max-time 20 \
    --resolve "${host}:443:${GATEWAY_IP}" "https://${host}${path}" "$@" >/dev/null 2>&1
  echo $?
}

# The source IP Envoy actually sees — what WAF REMOTE_ADDR rules match on. On a
# cloud LB or a local kind/vcluster this is the LB hop, not the public client IP.
observed_client_ip() {
  http_body /get | sed -n 's/.*"origin": *"\([^"]*\)".*/\1/p' | head -1
}

# --- waiting -----------------------------------------------------------------

# wait_for <timeout-seconds> <description> <cmd...> — poll until the command exits 0
wait_for() {
  local timeout=$1 desc=$2; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  note "timed out after ${timeout}s waiting for: ${desc}"
  return 1
}

# wait_for_http <timeout> <expected-code> <path> [curl args...]
wait_for_http() {
  local timeout=$1 want=$2 path=$3; shift 3
  local deadline=$(( $(date +%s) + timeout )) got=
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(http_code "$path" "$@")
    [ "$got" = "$want" ] && return 0
    sleep 2
  done
  note "timed out waiting for HTTP $want on $path (last: ${got:-none})"
  return 1
}

# wait_for_https <timeout> <expected-code> <hostname> <path> [curl args...]
wait_for_https() {
  local timeout=$1 want=$2 host=$3 path=$4; shift 4
  local deadline=$(( $(date +%s) + timeout )) got=
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(https_code "$host" "$path" "$@")
    [ "$got" = "$want" ] && return 0
    sleep 2
  done
  note "timed out waiting for HTTPS $want on ${host}${path} (last: ${got:-none})"
  return 1
}

# Wait until the gateway Service actually publishes a port. Changing a Gateway's
# listeners rewrites the Service, and the cloud/kind load balancer behind it needs
# a moment to re-provision — probing before that just times out on connect.
wait_for_service_port() {
  local timeout=$1 port=$2
  wait_for "$timeout" "the gateway service to publish port $port" bash -c \
    "kubectl get svc -n $GW_NS ingress -o jsonpath='{.spec.ports[*].port}' | tr ' ' '\n' | grep -qx $port"
}

# The proxy and controller images are distroless — they contain no shell and no
# curl — so admin endpoints have to be reached through a port-forward rather than
# `kubectl exec ... curl`. Prints the body; cleans the forward up either way.
admin_get() {  # admin_get <deployment> <remote-port> <path>
  local deploy=$1 port=$2 path=$3 local_port pf_pid out
  local_port=$(( 20000 + RANDOM % 20000 ))
  kubectl port-forward -n "$GW_NS" "deploy/$deploy" "${local_port}:${port}" >/dev/null 2>&1 &
  pf_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    out=$(curl -s --max-time 5 "http://127.0.0.1:${local_port}${path}" 2>/dev/null)
    [ -n "$out" ] && break
    sleep 1
  done
  kill "$pf_pid" >/dev/null 2>&1
  wait "$pf_pid" 2>/dev/null
  printf '%s' "$out"
}

# Wait for a policy to report Accepted=True in its status.
wait_policy_accepted() {
  local kind=$1 ns=$2 name=$3
  wait_for 60 "$kind/$name accepted" bash -c \
    "kubectl get $kind -n $ns $name -o jsonpath='{.status.ancestors[*].conditions[?(@.type==\"Accepted\")].status}' 2>/dev/null | grep -q True"
}

# --- PKI ---------------------------------------------------------------------

# Every cert helper writes into $CERTS, a per-test temp dir cleaned up on exit.
CERTS=$(mktemp -d)

# make_ca <name> <subject>
make_ca() {
  openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
    -subj "$2" -keyout "$CERTS/$1.key" -out "$CERTS/$1.crt" 2>/dev/null
}

# make_leaf <name> <subject> <ca-name> <serial> [san-config-file]
make_leaf() {
  local name=$1 subj=$2 ca=$3 serial=$4 cnf=${5:-}
  openssl req -new -nodes -keyout "$CERTS/$name.key" -out "$CERTS/$name.csr" \
    -newkey rsa:2048 ${subj:+-subj "$subj"} ${cnf:+-config "$cnf"} 2>/dev/null
  if [ -n "$cnf" ]; then
    openssl x509 -req -sha256 -days 365 -CA "$CERTS/$ca.crt" -CAkey "$CERTS/$ca.key" \
      -set_serial "$serial" -in "$CERTS/$name.csr" -out "$CERTS/$name.crt" \
      -extfile "$cnf" -extensions req_ext 2>/dev/null
  else
    openssl x509 -req -sha256 -days 365 -CA "$CERTS/$ca.crt" -CAkey "$CERTS/$ca.key" \
      -set_serial "$serial" -in "$CERTS/$name.csr" -out "$CERTS/$name.crt" 2>/dev/null
  fi
}

# cert_subject <cert-file> — the subject DN in the stable RFC2253 form
# (CN=host,O=org), so assertions do not depend on OpenSSL vs LibreSSL spacing.
cert_subject() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null; }

export -f https_code https_exit http_code http_body cert_subject 2>/dev/null || true

# --- cleanup / baseline ------------------------------------------------------

# Restore the lab 001 Gateway and lab 002 HTTPRoute. Every test that touches
# either one calls this on exit, so labs stay independent and re-runnable.
restore_baseline() {
  kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ingress
  namespace: ${GW_NS}
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
  namespace: ${APP_NS}
spec:
  hostnames:
  - "${HOST}"
  parentRefs:
    - name: ingress
      namespace: ${GW_NS}
  rules:
    - backendRefs:
        - name: httpbin
          port: 8000
      matches:
        - path:
            type: PathPrefix
            value: /
EOF
  wait_for_http 90 200 /get || true
}

# Registered by tests via `trap cleanup EXIT`.
cleanup_certs() { rm -rf "$CERTS"; }
