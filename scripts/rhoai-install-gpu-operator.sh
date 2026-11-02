#!/bin/bash
###############################################################################
# rhoai-install-gpu-operator.sh
#
# Install the NVIDIA GPU Operator and create the ClusterPolicy.
# Requires Node Feature Discovery (run rhoai-install-nfd.sh first).
#
# - Namespace nvidia-gpu-operator (labelled for OpenShift monitoring so the
#   DCGM exporter metrics are scraped), OperatorGroup (only if none exists),
#   Subscription 'gpu-operator-certified' from certified-operators
#   (default channel)
# - ClusterPolicy 'gpu-cluster-policy' built from the CSV example
#   (alm-examples), as recommended by NVIDIA for OpenShift, with the DCGM
#   exporter ServiceMonitor enabled
# - Optional time-slicing: --time-slicing <N> shares each GPU as N GPUs
#   (compute only — GPU memory is NOT split; label becomes <product>-SHARED)
# - Re-running is safe: existing Subscription / ClusterPolicy are kept
#   (time-slicing settings are re-applied)
#
# Run as cluster-admin. Driver build + validation takes ~10-20 min per node.
#
# Usage:
#   bash rhoai-install-gpu-operator.sh
#   bash rhoai-install-gpu-operator.sh --time-slicing 4
#   bash rhoai-install-gpu-operator.sh --channel v25.3
#   bash rhoai-install-gpu-operator.sh --no-wait
#   bash rhoai-install-gpu-operator.sh --dry-run
###############################################################################
set -euo pipefail

NS="nvidia-gpu-operator"
PACKAGE="gpu-operator-certified"
CATALOG="certified-operators"
CHANNEL=""
POLICY="gpu-cluster-policy"
TIME_SLICING=0
WAIT=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)       CHANNEL="$2"; shift 2 ;;
        --time-slicing)  TIME_SLICING="$2"; shift 2 ;;
        --no-wait)       WAIT=false; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help|-h)       sed -n '3,29p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " NVIDIA GPU Operator + ClusterPolicy"
echo "=============================================="
echo ""

if ! [[ "$TIME_SLICING" =~ ^[0-9]+$ ]] || [ "$TIME_SLICING" -eq 1 ]; then
    error "--time-slicing must be 0 (off) or >= 2"
    exit 1
fi
if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    error "python3 is required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if ! oc get crd nodefeaturediscoveries.nfd.openshift.io &>/dev/null \
   || ! oc get nodefeaturediscovery -A --no-headers 2>/dev/null | grep -q .; then
    error "Node Feature Discovery is not installed — run rhoai-install-nfd.sh first"
    exit 1
fi
GPU_NODES=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true --no-headers 2>/dev/null | wc -l | xargs)
if [ "$GPU_NODES" -eq 0 ]; then
    warn "No NVIDIA GPU node detected by NFD yet — the operator installs, but no driver pods start until GPU nodes exist"
else
    info "NVIDIA GPU nodes (NFD): ${GPU_NODES}"
fi

if ! oc get packagemanifest "$PACKAGE" -n openshift-marketplace &>/dev/null; then
    error "Package '${PACKAGE}' not found (is the ${CATALOG} catalog enabled?)"
    exit 1
fi
[ -z "$CHANNEL" ] && CHANNEL=$(oc get packagemanifest "$PACKAGE" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}')
info "Package: ${PACKAGE}  channel: ${CHANNEL}  namespace: ${NS}"
[ "$TIME_SLICING" -ge 2 ] && info "Time-slicing: each GPU shared as ${TIME_SLICING}" || info "Time-slicing: off"

if [ "$DRY_RUN" = true ]; then
    info "Dry run — would create: Namespace ${NS}, OperatorGroup (if none), Subscription ${PACKAGE} (${CHANNEL}), ClusterPolicy ${POLICY}"
    exit 0
fi
echo ""

###############################################################################
# 1. Operator
###############################################################################
info "=== 1. Operator ==="
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label namespace "$NS" openshift.io/cluster-monitoring=true --overwrite >/dev/null
success "Namespace ${NS} (monitoring enabled)"

OG_COUNT=$(oc get operatorgroup -n "$NS" --no-headers 2>/dev/null | wc -l | xargs)
if [ "$OG_COUNT" -eq 0 ]; then
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: ${NS}
spec:
  targetNamespaces:
  - ${NS}
EOF
    success "OperatorGroup created"
else
    [ "$OG_COUNT" -gt 1 ] && warn "${OG_COUNT} OperatorGroups in ${NS} — OLM cannot install with more than one"
    info "OperatorGroup exists — kept"
fi

SUB=$(oc get subscriptions.operators.coreos.com -n "$NS" \
    -o jsonpath="{range .items[?(@.spec.name==\"${PACKAGE}\")]}{.metadata.name}{end}" 2>/dev/null || true)
if [ -z "$SUB" ]; then
    SUB="gpu-operator-certified"
    STARTING_CSV=$(oc get packagemanifest "$PACKAGE" -n openshift-marketplace \
        -o jsonpath="{.status.channels[?(@.name==\"${CHANNEL}\")].currentCSV}")
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB}
  namespace: ${NS}
spec:
  name: ${PACKAGE}
  channel: "${CHANNEL}"
  source: ${CATALOG}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
  startingCSV: ${STARTING_CSV}
EOF
    success "Subscription ${SUB} created (${STARTING_CSV})"
else
    info "Subscription ${SUB} exists — kept"
fi

info "Waiting for the operator CSV (up to 10 min)..."
CSV=""
for _ in $(seq 1 60); do
    CSV=$(oc get subscriptions.operators.coreos.com "$SUB" -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$CSV" ]; then
        PHASE=$(oc get csv "$CSV" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [ "$PHASE" = "Succeeded" ] && break
    fi
    sleep 10
done
if [ -z "$CSV" ] || [ "$(oc get csv "$CSV" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Succeeded" ]; then
    error "Operator not ready — check: oc get csv,installplan -n ${NS}"
    exit 1
fi
success "Operator ready: ${CSV}"
echo ""

###############################################################################
# 2. Time-slicing config (optional)
###############################################################################
if [ "$TIME_SLICING" -ge 2 ]; then
    info "=== 2. Time-slicing config ==="
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: ${NS}
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: false
        resources:
        - name: nvidia.com/gpu
          replicas: ${TIME_SLICING}
EOF
    success "ConfigMap time-slicing-config (replicas: ${TIME_SLICING})"
    echo ""
fi

###############################################################################
# 3. ClusterPolicy (from the CSV example)
###############################################################################
info "=== 3. ClusterPolicy ==="
if oc get clusterpolicy "$POLICY" &>/dev/null || oc get clusterpolicy --no-headers 2>/dev/null | grep -q .; then
    POLICY=$(oc get clusterpolicy -o jsonpath='{.items[0].metadata.name}')
    info "ClusterPolicy exists — kept: ${POLICY}"
else
    oc get csv "$CSV" -n "$NS" -o jsonpath='{.metadata.annotations.alm-examples}' | \
        POLICY="$POLICY" python3 -c '
import json, os, sys
examples = json.load(sys.stdin)
cp = next(e for e in examples if e.get("kind") == "ClusterPolicy")
cp["metadata"] = {"name": os.environ["POLICY"]}
dcgm = cp.setdefault("spec", {}).setdefault("dcgmExporter", {})
dcgm["enabled"] = True
dcgm.setdefault("serviceMonitor", {})["enabled"] = True
print(json.dumps(cp))
' | oc apply -f -
    success "ClusterPolicy ${POLICY} created"
fi

if [ "$TIME_SLICING" -ge 2 ]; then
    oc patch clusterpolicy "$POLICY" --type=merge \
        -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}' >/dev/null
    success "Time-slicing enabled on ${POLICY}"
else
    CUR=$(oc get clusterpolicy "$POLICY" -o jsonpath='{.spec.devicePlugin.config.name}' 2>/dev/null || true)
    [ -n "$CUR" ] && warn "ClusterPolicy uses device plugin config '${CUR}' (time-slicing?) — left unchanged"
fi
echo ""

###############################################################################
# 4. Wait / verify
###############################################################################
if [ "$WAIT" = true ] && [ "$GPU_NODES" -gt 0 ]; then
    info "=== 4. Waiting for ClusterPolicy ready (driver build ~10-20 min, timeout 40 min) ==="
    START=$SECONDS
    while true; do
        STATE=$(oc get clusterpolicy "$POLICY" -o jsonpath='{.status.state}' 2>/dev/null || true)
        ALLOC=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
            2>/dev/null | grep -vc '^$' || true)
        NOT_RUNNING=$(oc get pods -n "$NS" --no-headers 2>/dev/null | grep -vcE 'Running|Completed' || true)
        echo "  [$(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s] state: ${STATE:-pending}  GPU nodes allocatable: ${ALLOC}/${GPU_NODES}  pods not ready: ${NOT_RUNNING}"
        if [ "$STATE" = "ready" ] && [ "$ALLOC" -ge "$GPU_NODES" ]; then
            success "ClusterPolicy ready"
            break
        fi
        if [ $(( SECONDS - START )) -ge 2400 ]; then
            warn "Timed out — check: oc get pods -n ${NS}"
            oc get pods -n "$NS" --no-headers | grep -vE 'Running|Completed' | sed 's/^/  /' || true
            break
        fi
        sleep 30
    done
    echo ""
fi

info "=== GPU nodes ==="
oc get nodes -l nvidia.com/gpu.present=true \
    -o custom-columns='NODE:.metadata.name,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,GPU:.status.allocatable.nvidia\.com/gpu,MEMORY(MiB):.metadata.labels.nvidia\.com/gpu\.memory' \
    2>/dev/null | sed 's/^/  /' || true

echo ""
echo "=============================================="
success "Done."
echo "  Status    : oc get clusterpolicy ${POLICY} -o jsonpath='{.status.state}'"
echo "  Pods      : oc get pods -n ${NS}"
echo "  Next      : bash rhoai-create-gpu-profile.sh   (uses label nvidia.com/gpu.product)"
[ "$TIME_SLICING" -ge 2 ] && echo "  Note      : with time-slicing the product label ends with -SHARED (e.g. NVIDIA-L4-SHARED)"
echo "=============================================="
