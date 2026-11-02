#!/bin/bash
###############################################################################
# rhoai-install-nfd.sh
#
# Install the Node Feature Discovery (NFD) Operator and create the
# NodeFeatureDiscovery instance. NFD labels nodes with their hardware
# (e.g. feature.node.kubernetes.io/pci-10de.present=true for NVIDIA GPUs),
# which the NVIDIA GPU Operator needs. Run this before
# rhoai-install-gpu-operator.sh.
#
# - Namespace openshift-nfd, OperatorGroup (only if none exists),
#   Subscription 'nfd' from redhat-operators (default channel)
# - NodeFeatureDiscovery 'nfd-instance' built from the CSV example
#   (alm-examples), so the operand image matches the installed operator
# - Re-running is safe: existing Subscription / instance are kept
#
# Run as cluster-admin.
#
# Usage:
#   bash rhoai-install-nfd.sh
#   bash rhoai-install-nfd.sh --channel stable
#   bash rhoai-install-nfd.sh --dry-run          # show what would be created
###############################################################################
set -euo pipefail

NS="openshift-nfd"
PACKAGE="nfd"
CATALOG="redhat-operators"
CHANNEL=""
INSTANCE="nfd-instance"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)  CHANNEL="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)  sed -n '3,23p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " Node Feature Discovery Operator + instance"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    error "python3 is required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if ! oc get packagemanifest "$PACKAGE" -n openshift-marketplace &>/dev/null; then
    error "Package '${PACKAGE}' not found in the catalog (is ${CATALOG} available?)"
    exit 1
fi
[ -z "$CHANNEL" ] && CHANNEL=$(oc get packagemanifest "$PACKAGE" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}')
info "Package: ${PACKAGE}  channel: ${CHANNEL}  namespace: ${NS}"

if [ "$DRY_RUN" = true ]; then
    info "Dry run — would create: Namespace ${NS}, OperatorGroup (if none), Subscription ${PACKAGE} (${CHANNEL}), NodeFeatureDiscovery ${INSTANCE}"
    exit 0
fi
echo ""

###############################################################################
# 1. Operator
###############################################################################
info "=== 1. Operator ==="
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null
success "Namespace ${NS}"

OG_COUNT=$(oc get operatorgroup -n "$NS" --no-headers 2>/dev/null | wc -l | xargs)
if [ "$OG_COUNT" -eq 0 ]; then
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
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
    SUB="nfd"
    cat <<EOF | oc apply -f - >/dev/null
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB}
  namespace: ${NS}
spec:
  name: ${PACKAGE}
  channel: ${CHANNEL}
  source: ${CATALOG}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    success "Subscription ${SUB} created"
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
# 2. NodeFeatureDiscovery instance (from the CSV example)
###############################################################################
info "=== 2. NodeFeatureDiscovery ==="
if oc get nodefeaturediscovery -n "$NS" --no-headers 2>/dev/null | grep -q .; then
    info "NodeFeatureDiscovery exists — kept: $(oc get nodefeaturediscovery -n "$NS" -o name | xargs)"
else
    oc get csv "$CSV" -n "$NS" -o jsonpath='{.metadata.annotations.alm-examples}' | \
        NS="$NS" INSTANCE="$INSTANCE" python3 -c '
import json, os, sys
examples = json.load(sys.stdin)
cr = next(e for e in examples if e.get("kind") == "NodeFeatureDiscovery")
cr["metadata"]["name"] = os.environ["INSTANCE"]
cr["metadata"]["namespace"] = os.environ["NS"]
print(json.dumps(cr))
' | oc apply -f -
    success "NodeFeatureDiscovery ${INSTANCE} created"
fi
echo ""

###############################################################################
# 3. Verify
###############################################################################
info "=== 3. Verify ==="
info "Waiting for NFD worker pods and node labels (up to 5 min)..."
GPU_NODES=0
for _ in $(seq 1 30); do
    GPU_NODES=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true --no-headers 2>/dev/null | wc -l | xargs)
    LABELED=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.feature\.node\.kubernetes\.io/system-os_release\.ID}{"\n"}{end}' \
        2>/dev/null | grep -c . || true)
    [ "$LABELED" -gt 0 ] && break
    sleep 10
done
oc get pods -n "$NS" --no-headers 2>/dev/null | awk '{printf "  %-55s %s\n", $1, $3}'
echo ""
info "Nodes with NFD labels: ${LABELED:-0} / $(oc get nodes --no-headers | wc -l | xargs)"
if [ "$GPU_NODES" -gt 0 ]; then
    success "NVIDIA GPU nodes detected (pci-10de): ${GPU_NODES}"
    oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true --no-headers | awk '{print "    " $1}'
else
    warn "No NVIDIA GPU node detected yet (label feature.node.kubernetes.io/pci-10de.present=true)."
    warn "Create GPU nodes first (rhoai-create-gpu-machineset.sh) — labels appear a few minutes after they are Ready."
fi

echo ""
echo "=============================================="
success "Done. Next: bash rhoai-install-gpu-operator.sh"
echo "=============================================="
