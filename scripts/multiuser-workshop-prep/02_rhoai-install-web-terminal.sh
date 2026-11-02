#!/bin/bash
###############################################################################
# rhoai-install-web-terminal.sh
#
# Install the Web Terminal Operator so every user gets the ">_" terminal
# icon in the OpenShift console (oc / kubectl / helm preinstalled, logged in
# as that user — handy for workshop students without a local CLI).
#
# - Subscription 'web-terminal' in openshift-operators (all namespaces,
#   redhat-operators, default channel). OLM installs the DevWorkspace
#   Operator automatically as a dependency.
# - No instance/CR is needed: the console shows the icon once the CSV is
#   Succeeded (reload the console page).
# - Re-running is safe: an existing Subscription is kept.
#
# Run as cluster-admin.
#
# Usage:
#   bash rhoai-install-web-terminal.sh
#   bash rhoai-install-web-terminal.sh --channel fast
#   bash rhoai-install-web-terminal.sh --dry-run          # show what would be created
###############################################################################
set -euo pipefail

NS="openshift-operators"
PACKAGE="web-terminal"
CATALOG="redhat-operators"
CHANNEL=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)  CHANNEL="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)  sed -n '3,22p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " Web Terminal Operator"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
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

SUB=$(oc get subscriptions.operators.coreos.com -n "$NS" \
    -o jsonpath="{range .items[?(@.spec.name==\"${PACKAGE}\")]}{.metadata.name}{end}" 2>/dev/null || true)
DWO_SUB=$(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath='{range .items[?(@.spec.name=="devworkspace-operator")]}{.metadata.namespace}/{.metadata.name}{end}' 2>/dev/null || true)
[ -n "$DWO_SUB" ] && info "DevWorkspace Operator already subscribed (${DWO_SUB}) — reused (e.g. installed with Dev Spaces)"

if [ "$DRY_RUN" = true ]; then
    if [ -n "$SUB" ]; then
        info "Dry run — Subscription ${SUB} already exists, nothing to create"
    else
        info "Dry run — would create: Subscription ${PACKAGE} (${CHANNEL}) in ${NS}; DevWorkspace Operator comes as a dependency"
    fi
    exit 0
fi
echo ""

###############################################################################
# 1. Operator
###############################################################################
info "=== 1. Operator ==="
# openshift-operators ships with the 'global-operators' OperatorGroup (all namespaces)
if ! oc get operatorgroup -n "$NS" --no-headers 2>/dev/null | grep -q .; then
    error "No OperatorGroup in ${NS} — expected the default 'global-operators'"
    exit 1
fi

if [ -z "$SUB" ]; then
    SUB="web-terminal"
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
# 2. Verify (DevWorkspace dependency)
###############################################################################
info "=== 2. Verify ==="
DWO_CSV=$(oc get csv -n "$NS" --no-headers 2>/dev/null | awk '/^devworkspace-operator/ {print $1" "$NF}' | head -1)
if [ -n "$DWO_CSV" ]; then
    success "DevWorkspace Operator: ${DWO_CSV}"
else
    warn "DevWorkspace Operator CSV not found in ${NS} — check: oc get csv -A | grep devworkspace"
fi

info "Waiting for the DevWorkspace webhook server (up to 5 min)..."
if oc rollout status deployment/devworkspace-webhook-server -n "$NS" --timeout=300s &>/dev/null; then
    success "devworkspace-webhook-server ready"
else
    warn "devworkspace-webhook-server not ready yet — terminals fail to start until it is: oc get pods -n ${NS}"
fi
oc get pods -n "$NS" --no-headers 2>/dev/null | grep -E 'devworkspace|web-terminal' \
    | awk '{printf "  %-55s %s\n", $1, $3}' || true

echo ""
echo "=============================================="
success "Done. Reload the OpenShift console — the '>_' icon appears in the top-right masthead."
echo "  Users need a project to start a terminal in (it runs as a DevWorkspace pod there)."
echo "  Idle timeout (default 15 min): Administration > Cluster Settings > Configuration > Console > Web Terminal"
echo "=============================================="
