#!/usr/bin/env bash
# Run the Enterprise kgateway workshop e2e suite.
#
# Each tests/lab-*.sh file mirrors one workshop lab: it applies the same
# manifests the lab tells you to apply, sends real requests through the
# gateway, asserts the behaviour the lab documents, and cleans up after
# itself. A failing test means the lab no longer works as written.
#
# Usage:
#   ./run-e2e.sh                        # every lab (needs a live cluster)
#   ./run-e2e.sh --install              # install Enterprise kgateway first, then run
#   ./run-e2e.sh --list                 # list the labs the suite covers
#   ./run-e2e.sh -k waf -k jwt          # only tests whose filename matches
#   ./run-e2e.sh --gateway-ip 1.2.3.4   # override the gateway address
#   ./run-e2e.sh --keep-going           # don't stop reporting on the first failed lab
#   ./run-e2e.sh --uninstall            # tear the workshop back out of the cluster
#
# Requires: kubectl, curl, openssl, helm (only for --install/--uninstall).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KGW_VERSION="${KGW_VERSION:-2.3.3}"
GWAPI_VERSION="${GWAPI_VERSION:-1.5.0}"
GW_NS=enterprise-kgateway
APP_NS=httpbin

DO_INSTALL=0
DO_UNINSTALL=0
DO_LIST=0
KEEP_GOING=0
GATEWAY_IP="${GATEWAY_IP:-}"
FILTERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --install)     DO_INSTALL=1 ;;
    --uninstall)   DO_UNINSTALL=1 ;;
    --list)        DO_LIST=1 ;;
    --keep-going)  KEEP_GOING=1 ;;
    --gateway-ip)  GATEWAY_IP="$2"; shift ;;
    --version)     KGW_VERSION="$2"; shift ;;
    -k)            FILTERS+=("$2"); shift ;;
    -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLD=; C_DIM=; C_OFF=
fi
die() { printf '%s\n' "$*" >&2; exit 1; }

# ---- select tests -----------------------------------------------------------

ALL_TESTS=()
while IFS= read -r t; do ALL_TESTS+=("$t"); done < <(ls tests/lab-*.sh 2>/dev/null | sort)
[ ${#ALL_TESTS[@]} -gt 0 ] || die "no tests found in $SCRIPT_DIR/tests"

TESTS=()
if [ ${#FILTERS[@]} -eq 0 ]; then
  TESTS=("${ALL_TESTS[@]}")
else
  for t in "${ALL_TESTS[@]}"; do
    for f in "${FILTERS[@]}"; do
      case "$t" in *"$f"*) TESTS+=("$t"); break ;; esac
    done
  done
fi

if [ "$DO_LIST" -eq 1 ]; then
  printf '%sLabs covered by the suite:%s\n' "$C_BLD" "$C_OFF"
  for t in "${ALL_TESTS[@]}"; do
    printf '  %-34s %s\n' "$(basename "$t")" "$(sed -n 's/^# LAB: //p' "$t" | head -1)"
  done
  exit 0
fi
[ ${#TESTS[@]} -gt 0 ] || die "no tests matched: ${FILTERS[*]}"

# ---- install / uninstall ----------------------------------------------------

CRD_CHART=oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds
GW_CHART=oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway

if [ "$DO_UNINSTALL" -eq 1 ]; then
  echo "Removing the workshop from context '$(kubectl config current-context)'..."
  kubectl delete ns "$APP_NS" --ignore-not-found --wait=false
  kubectl delete gateway -n "$GW_NS" ingress --ignore-not-found
  helm uninstall enterprise-kgateway -n "$GW_NS" 2>/dev/null
  helm uninstall enterprise-kgateway-crds -n "$GW_NS" 2>/dev/null
  # GatewayClasses are cluster-scoped and outlive both the release and the namespace.
  kubectl delete gatewayclass enterprise-kgateway kgateway-waypoint --ignore-not-found
  kubectl delete ns "$GW_NS" --ignore-not-found --wait=false
  echo "Done. Gateway API CRDs were left in place."
  exit 0
fi

if [ "$DO_INSTALL" -eq 1 ]; then
  command -v helm >/dev/null || die "helm not found on PATH (needed for --install)"
  [ -n "${SOLO_TRIAL_LICENSE_KEY:-}" ] || die "SOLO_TRIAL_LICENSE_KEY is not set (needed for --install)"

  printf '%sInstalling Enterprise kgateway %s (lab 001)%s\n' "$C_BLD" "$KGW_VERSION" "$C_OFF"
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/experimental-install.yaml" >/dev/null \
    || die "failed to install the Gateway API experimental CRDs"

  helm upgrade -i enterprise-kgateway-crds "$CRD_CHART" \
    --version "$KGW_VERSION" --namespace "$GW_NS" --create-namespace >/dev/null \
    || die "failed to install the Enterprise kgateway CRDs"

  helm upgrade -i -n "$GW_NS" enterprise-kgateway "$GW_CHART" \
    --create-namespace --version "$KGW_VERSION" \
    --set-string "licensing.licenseKey=$SOLO_TRIAL_LICENSE_KEY" \
    -f - >/dev/null <<YAML || die "failed to install the Enterprise kgateway controller"
gatewayClassParametersRefs:
  enterprise-kgateway:
    group: enterprisekgateway.solo.io
    kind: EnterpriseKgatewayParameters
    name: ingress-params
    namespace: $GW_NS
YAML

  kubectl apply -f tests/manifests/001-gateway.yaml >/dev/null || die "failed to apply the lab 001 gateway"
  kubectl apply -f tests/manifests/002-httpbin.yaml  >/dev/null || die "failed to apply the lab 002 httpbin app"

  kubectl rollout status -n "$GW_NS" deploy/enterprise-kgateway --timeout=180s >/dev/null || die "controller never became ready"
  kubectl rollout status -n "$GW_NS" deploy/ingress --timeout=180s >/dev/null || die "gateway proxy never became ready"
  kubectl rollout status -n "$APP_NS" deploy/httpbin --timeout=180s >/dev/null || die "httpbin never became ready"
  echo "Installed."
  echo
fi

# ---- preflight --------------------------------------------------------------

echo "${C_BLD}Preflight${C_OFF}"
fail=0
for bin in kubectl curl openssl; do
  command -v "$bin" >/dev/null || { echo "  ${C_RED}✗${C_OFF} $bin not found on PATH"; fail=1; }
done

CTX=$(kubectl config current-context 2>/dev/null)
if [ -z "$CTX" ]; then
  echo "  ${C_RED}✗${C_OFF} no active kubectl context"; fail=1
else
  echo "  ${C_GRN}✓${C_OFF} context: $CTX"
fi

if ! kubectl get gatewayclass enterprise-kgateway >/dev/null 2>&1; then
  echo "  ${C_RED}✗${C_OFF} GatewayClass 'enterprise-kgateway' not found — run ./run-e2e.sh --install"
  fail=1
else
  ver=$(kubectl get deploy -n "$GW_NS" enterprise-kgateway \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
  echo "  ${C_GRN}✓${C_OFF} Enterprise kgateway installed (controller image tag: ${ver:-unknown})"
  if [ -n "$ver" ] && [ "$ver" != "$KGW_VERSION" ]; then
    echo "  ${C_YEL}!${C_OFF} cluster is running $ver, the workshop documents $KGW_VERSION"
  fi
fi

for ns in "$GW_NS" "$APP_NS"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || { echo "  ${C_RED}✗${C_OFF} namespace '$ns' missing — run ./run-e2e.sh --install"; fail=1; }
done

if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP=$(kubectl get svc -n "$GW_NS" \
    --selector=gateway.networking.k8s.io/gateway-name=ingress \
    -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}{.items[*].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
fi
if [ -z "$GATEWAY_IP" ]; then
  echo "  ${C_RED}✗${C_OFF} the 'ingress' Gateway service has no LoadBalancer address — expose it, or pass --gateway-ip"
  fail=1
else
  echo "  ${C_GRN}✓${C_OFF} gateway address: $GATEWAY_IP"
fi

[ "$fail" -eq 0 ] || { echo; echo "Preflight failed — aborting." >&2; exit 1; }

# ---- run --------------------------------------------------------------------

E2E_RESULTS=$(mktemp)
export GATEWAY_IP E2E_RESULTS KGW_VERSION
trap 'rm -f "$E2E_RESULTS"' EXIT

# grep -c prints the count and exits non-zero when it is zero, so swallow the
# status rather than adding a fallback that would emit a second line.
count() { grep -c "^$1" "$E2E_RESULTS" 2>/dev/null || true; }

printf '\n%sRunning %d lab test(s)%s\n' "$C_BLD" "${#TESTS[@]}" "$C_OFF"
printf '%s(tests apply real manifests and wait on rate-limit windows and TLS rollouts; ~8 min for the full suite)%s\n' "$C_DIM" "$C_OFF"

failed_labs=()
for t in "${TESTS[@]}"; do
  name=$(basename "$t" .sh)
  desc=$(sed -n 's/^# LAB: //p' "$t" | head -1)
  printf '\n%s%s%s — %s\n' "$C_BLD" "$name" "$C_OFF" "$desc"
  before=$(count FAIL)
  bash "$t"
  rc=$?
  after=$(count FAIL)
  if [ "$rc" -ne 0 ] || [ "$after" -gt "$before" ]; then
    failed_labs+=("$name")
    if [ "$rc" -ne 0 ] && [ "$after" -eq "$before" ]; then
      printf '  %s✗%s the test script itself exited %s\n' "$C_RED" "$C_OFF" "$rc"
      echo "FAIL $name :: test script exited $rc" >>"$E2E_RESULTS"
    fi
    [ "$KEEP_GOING" -eq 1 ] || { printf '%s   (continuing; pass --keep-going to suppress this note)%s\n' "$C_DIM" "$C_OFF"; }
  fi
done

# ---- summary ----------------------------------------------------------------

p=$(count PASS)
f=$(count FAIL)
s=$(count SKIP)

printf '\n%s────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
printf '%s%s passed%s' "$C_GRN" "$p" "$C_OFF"
[ "$s" -gt 0 ] && printf ', %s%s skipped%s' "$C_YEL" "$s" "$C_OFF"
[ "$f" -gt 0 ] && printf ', %s%s failed%s' "$C_RED" "$f" "$C_OFF"
printf '\n'

if [ "$f" -gt 0 ]; then
  printf '\n%sFailures%s\n' "$C_BLD" "$C_OFF"
  grep '^FAIL' "$E2E_RESULTS" | sed 's/^FAIL /  /'
  printf '\nLabs needing attention: %s\n' "${failed_labs[*]}"
  exit 1
fi
echo "All labs work as written."
