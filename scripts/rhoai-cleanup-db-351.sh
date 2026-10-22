#!/bin/bash
###############################################################################
# rhoai-cleanup-db-351.sh
#
# Remove the database-related resources created by the earlier setup scripts
# so the current *-enable-all-features-351.sh / *-setup-maas-351.sh can be
# re-applied cleanly (MLflow on PostgreSQL from the start, shared POC
# PostgreSQL reused by MaaS, Model Registry with its own PostgreSQL).
# Works on both Single Node OpenShift and multi-node clusters.
#
# Deleted:
#   - MLflow CR 'mlflow' (cluster-scoped) + its PVCs + mlflow-db-credentials
#   - POC PostgreSQL in redhat-ods-applications (Deployment, Service,
#     PVC postgres-data, Secret postgres-creds)
#   - maas-db-config Secret (redhat-ai-gateway-infra, redhat-ods-applications)
#   - ModelRegistry instance (default: default-registry) + its generated DB
#
# NOT deleted:
#   - Operators, DSC/DSCI, gateways, Kuadrant/Authorino, dashboard settings
#   - Models (LLMInferenceService) and MaaSSubscription / MaaSAuthPolicy CRs
#
# Data loss: MLflow experiments/traces, MaaS API keys (stored in PostgreSQL),
# registered models in the Model Registry.
#
# After cleanup, re-run in order:
#   1. rhoai-enable-all-features-351.sh   (or sno-...)  → PostgreSQL, MLflow, Model Registry
#   2. rhoai-setup-maas-351.sh            (or sno-...)  → maas-db-config, maas-api restart
#
# Usage:
#   bash rhoai-cleanup-db-351.sh --dry-run                 # show what would be deleted
#   bash rhoai-cleanup-db-351.sh                           # asks for confirmation
#   bash rhoai-cleanup-db-351.sh --yes                     # no prompt
#   bash rhoai-cleanup-db-351.sh --registry-name <name>    # default: default-registry
#   curl ... | bash -s -- --yes
###############################################################################
set -euo pipefail

DRY_RUN=false
ASSUME_YES=false
REGISTRY_NAME="${MODEL_REGISTRY_NAME:-default-registry}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true; shift ;;
        --yes|-y)         ASSUME_YES=true; shift ;;
        --registry-name)  REGISTRY_NAME="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--yes] [--registry-name <name>]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

APP_NS="redhat-ods-applications"
MAAS_INFRA_NS="redhat-ai-gateway-infra"
MR_CRD="modelregistries.modelregistry.opendatahub.io"

echo "=============================================="
echo " RHOAI 3.5.1 — Cleanup DB resources (MLflow / PostgreSQL / Model Registry)"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"
echo ""

MR_NS=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.spec.components.modelregistry.registriesNamespace}' 2>/dev/null || true)
MR_NS="${MR_NS:-rhoai-model-registries}"

###############################################################################
# Inventory
###############################################################################
info "=== Resources found ==="
declare -a TARGETS=()   # "<kind>|<namespace or ->|<name>"

add_if_exists() {
    local KIND="$1" NS="$2" NAME="$3"
    if [ "$NS" = "-" ]; then
        oc get "$KIND" "$NAME" &>/dev/null || return 0
    else
        oc get "$KIND" "$NAME" -n "$NS" &>/dev/null || return 0
    fi
    TARGETS+=("${KIND}|${NS}|${NAME}")
    echo "  • ${KIND} ${NAME}$([ "$NS" != "-" ] && echo " (ns: ${NS})")"
}

oc get crd mlflows.mlflow.opendatahub.io &>/dev/null && add_if_exists mlflow - mlflow
add_if_exists secret "$APP_NS" mlflow-db-credentials
for PVC in $(oc get pvc -n "$APP_NS" --no-headers 2>/dev/null | awk '/^mlflow/{print $1}'); do
    add_if_exists pvc "$APP_NS" "$PVC"
done
add_if_exists deployment "$APP_NS" postgres
add_if_exists service "$APP_NS" postgres
add_if_exists pvc "$APP_NS" postgres-data
add_if_exists secret "$APP_NS" postgres-creds
add_if_exists secret "$APP_NS" maas-db-config
add_if_exists secret "$MAAS_INFRA_NS" maas-db-config
oc get crd "$MR_CRD" &>/dev/null && add_if_exists "$MR_CRD" "$MR_NS" "$REGISTRY_NAME"

if [ ${#TARGETS[@]} -eq 0 ]; then
    success "Nothing to clean up"
    exit 0
fi
echo ""

if [ "$DRY_RUN" = true ]; then
    info "Dry run — nothing deleted."
    exit 0
fi

###############################################################################
# Confirmation (reads from /dev/tty so it also works with curl | bash)
###############################################################################
warn "This permanently deletes MLflow data, MaaS API keys and Model Registry entries."
warn "Models, MaaSSubscriptions and MaaSAuthPolicies are kept."
if [ "$ASSUME_YES" != true ]; then
    if [ -r /dev/tty ]; then
        printf "Type 'yes' to continue: " > /dev/tty
        read -r ANSWER < /dev/tty || ANSWER=""
    else
        ANSWER=""
    fi
    if [ "$ANSWER" != "yes" ]; then
        error "Aborted (no confirmation). Use --yes to skip the prompt."
        exit 1
    fi
fi
echo ""

###############################################################################
# Delete — CRs first so their operators remove owned resources, then the rest
###############################################################################
info "=== Deleting ==="

delete_target() {
    local KIND="$1" NS="$2" NAME="$3"
    if [ "$NS" = "-" ]; then
        oc delete "$KIND" "$NAME" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 \
            && success "deleted ${KIND} ${NAME}" || warn "could not delete ${KIND} ${NAME} (check finalizers)"
    else
        oc delete "$KIND" "$NAME" -n "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 \
            && success "deleted ${KIND} ${NAME} (ns: ${NS})" || warn "could not delete ${KIND} ${NAME} in ${NS} (check finalizers)"
    fi
}

# Pass 1: custom resources (MLflow, ModelRegistry)
for T in "${TARGETS[@]}"; do
    IFS='|' read -r KIND NS NAME <<< "$T"
    case "$KIND" in mlflow|"$MR_CRD") delete_target "$KIND" "$NS" "$NAME" ;; esac
done
# Pass 2: workloads, then secrets and PVCs
for PHASE in deployment service secret pvc; do
    for T in "${TARGETS[@]}"; do
        IFS='|' read -r KIND NS NAME <<< "$T"
        [ "$KIND" = "$PHASE" ] && delete_target "$KIND" "$NS" "$NAME"
    done
done

# PVCs created by the MLflow operator after inventory (e.g. during deletion)
for PVC in $(oc get pvc -n "$APP_NS" --no-headers 2>/dev/null | awk '/^mlflow/{print $1}'); do
    delete_target pvc "$APP_NS" "$PVC"
done
echo ""

###############################################################################
# Result
###############################################################################
info "=== Remaining (should be empty) ==="
oc get mlflow 2>/dev/null | sed 's/^/  /' || true
oc get deployment,service,pvc -n "$APP_NS" 2>/dev/null | grep -E 'postgres|mlflow' | sed 's/^/  /' || true
oc get "$MR_CRD" -n "$MR_NS" 2>/dev/null | sed 's/^/  /' || true

echo ""
echo "=============================================="
success "Cleanup done."
echo ""
echo "  Re-apply in order:"
echo "   1. rhoai-enable-all-features-351.sh  (SNO: sno-enable-all-features-351.sh)"
echo "      → POC PostgreSQL, MLflow on PostgreSQL, Model Registry"
echo "   2. rhoai-setup-maas-351.sh           (SNO: sno-setup-maas-351.sh)"
echo "      → reuses PostgreSQL, recreates maas-db-config, restarts maas-api"
echo "  Add --allow-other-version to both on RHOAI 3.5.2 clusters."
echo "=============================================="
