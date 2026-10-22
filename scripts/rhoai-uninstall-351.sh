#!/bin/bash
###############################################################################
# rhoai-uninstall-351.sh
#
# Remove RHOAI and everything the *-enable-all-features / *-setup-maas
# scripts installed, so the scripts can be re-verified from a clean cluster
# (including Step 0: fresh install pinned to RHOAI 3.5.1).
# Works on both Single Node OpenShift and multi-node clusters.
#
# Removed (in this order):
#   1. Custom resources while their operators are still running
#      (models, MaaS CRs, OGX, MLflow, EvalHub, Model Registry, Kueue queues,
#       Kuadrant, LWS CR, UIPlugins, CheCluster, gateways/EnvoyFilters)
#   2. DataScienceCluster → DSCInitialization
#   3. RHOAI operator (Subscription, CSV)
#   4. Add-on operators installed by the scripts:
#      Kueue, LWS, OpenTelemetry, Tempo, Cluster Observability, RHCL (+Authorino,
#      Limitador, DNS), Dev Spaces
#   5. Leftover webhooks, CRDs and namespaces
#
# Kept by default:
#   - cert-manager (often pre-installed by RHDP for ingress certificates)
#     → remove with --include-cert-manager
#   - GPU Operator, NFD, Web Terminal / DevWorkspace, users and groups
#   - User Workload Monitoring config
#
# Usage:
#   bash rhoai-uninstall-351.sh --dry-run                # list what would be removed
#   bash rhoai-uninstall-351.sh                          # asks for confirmation
#   bash rhoai-uninstall-351.sh --yes                    # no prompt
#   bash rhoai-uninstall-351.sh --keep-addon-operators   # remove RHOAI only
#   bash rhoai-uninstall-351.sh --keep-demo              # keep the 'demo' namespace
#   bash rhoai-uninstall-351.sh --include-cert-manager   # also remove cert-manager
#   curl ... | bash -s -- --yes
#
# After it finishes, re-run:
#   1. rhoai-enable-all-features-351.sh or -352.sh   (Step 0 installs 3.5.1 or 3.5.2)
#   2. rhoai-setup-maas-351.sh
###############################################################################
set -uo pipefail

DRY_RUN=false
ASSUME_YES=false
KEEP_ADDONS=false
KEEP_DEMO=false
INCLUDE_CERT_MANAGER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)               DRY_RUN=true; shift ;;
        --yes|-y)                ASSUME_YES=true; shift ;;
        --keep-addon-operators)  KEEP_ADDONS=true; shift ;;
        --keep-demo)             KEEP_DEMO=true; shift ;;
        --include-cert-manager)  INCLUDE_CERT_MANAGER=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--yes] [--keep-addon-operators] [--keep-demo] [--include-cert-manager]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " RHOAI — Full uninstall (for re-verifying the 3.5.1 scripts)"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"
echo ""

###############################################################################
# Definitions
###############################################################################
# Custom resources deleted cluster-wide while operators still run (order matters)
CR_LIST=(
  llminferenceservices.serving.kserve.io
  inferenceservices.serving.kserve.io
  servingruntimes.serving.kserve.io
  maassubscriptions.maas.opendatahub.io
  maasauthpolicies.maas.opendatahub.io
  maasmodelrefs.maas.opendatahub.io
  externalmodels.maas.opendatahub.io
  ogxservers.ogx.io
  notebooks.kubeflow.org
  datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io
  modelregistries.modelregistry.opendatahub.io
  evalhubs.trustyai.opendatahub.io
  trustyaiservices.trustyai.opendatahub.io
  mlflows.mlflow.opendatahub.io
  localqueues.kueue.x-k8s.io
  clusterqueues.kueue.x-k8s.io
  resourceflavors.kueue.x-k8s.io
  checlusters.org.eclipse.che
  uiplugins.observability.openshift.io
  leaderworkersetoperators.operator.openshift.io
  kuadrants.kuadrant.io
)

# Add-on operators: "namespace|package|delete-namespace(yes/no)"
ADDON_OPS=(
  "openshift-operators|kueue-operator|no"
  "openshift-operators|devspaces|no"
  "openshift-lws-operator|leader-worker-set|yes"
  "openshift-opentelemetry-operator|opentelemetry-product|yes"
  "openshift-tempo-operator|tempo-product|yes"
  "openshift-cluster-observability-operator|cluster-observability-operator|yes"
  "redhat-connectivity-link-operator|rhcl-operator|yes"
  "redhat-connectivity-link-operator|authorino-operator|yes"
  "redhat-connectivity-link-operator|limitador-operator|yes"
  "redhat-connectivity-link-operator|dns-operator|yes"
)
[ "$INCLUDE_CERT_MANAGER" = true ] && ADDON_OPS+=("cert-manager-operator|openshift-cert-manager-operator|yes")

# Namespaces created by RHOAI or the scripts
RHOAI_NAMESPACES=(redhat-ods-applications redhat-ods-monitoring redhat-ai-gateway-infra
                  models-as-a-service ai-tenants rhoai-model-registries redhat-ods-operator)
ADDON_NAMESPACES=(kuadrant-system openshift-devspaces)
[ "$INCLUDE_CERT_MANAGER" = true ] && ADDON_NAMESPACES+=(cert-manager)
[ "$KEEP_DEMO" != true ] && RHOAI_NAMESPACES=(demo "${RHOAI_NAMESPACES[@]}")

# CRD groups owned by RHOAI (operator-applied at runtime or via OLM)
RHOAI_CRD_REGEX='(\.opendatahub\.io$|\.kserve\.io$|^ogxservers\.ogx\.io$|\.ray\.io$|kubeflow\.org$|\.trustyai\.opendatahub\.io$)'
ADDON_CRD_REGEX='(\.kuadrant\.io$|kueue\.x-k8s\.io$|leaderworkerset\.x-k8s\.io$|\.observability\.openshift\.io$|opentelemetry\.io$|tempo\.grafana\.com$|org\.eclipse\.che$|perses\.dev$)'
[ "$INCLUDE_CERT_MANAGER" = true ] && ADDON_CRD_REGEX="${ADDON_CRD_REGEX%)}|cert-manager\\.io\$)"

WEBHOOK_REGEX='opendatahub|odh-|rhods|kserve|modelregistry|trustyai|mlflow|maas|ogx|kubeflow|kuberay|ray-'
[ "$KEEP_ADDONS" != true ] && WEBHOOK_REGEX="${WEBHOOK_REGEX}|kueue|kuadrant|authorino|limitador|lws|leaderworkerset|opentelemetry|tempo|che-|devworkspace-che"

###############################################################################
# Inventory
###############################################################################
info "=== Inventory ==="
RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | awk '/^rhods-operator/{print $1}' | head -1)
echo "  RHOAI: ${RHOAI_CSV:-not installed}"
echo "  Custom resources:"
for RES in "${CR_LIST[@]}"; do
    oc get crd "$RES" &>/dev/null || continue
    N=$(oc get "$RES" -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "${N:-0}" -gt 0 ] && echo "    • ${RES}: ${N}"
done
for OBJ in "datasciencecluster default-dsc" "dscinitialization default-dsci"; do
    oc get $OBJ &>/dev/null && echo "    • ${OBJ}"
done
if [ "$KEEP_ADDONS" != true ]; then
    echo "  Add-on operators:"
    for E in "${ADDON_OPS[@]}"; do
        IFS='|' read -r NS PKG _ <<< "$E"
        SUB=$(oc get sub -n "$NS" -o go-template='{{range .items}}{{if eq .spec.name "'"$PKG"'"}}{{.metadata.name}}{{end}}{{end}}' 2>/dev/null)
        [ -n "$SUB" ] && echo "    • ${PKG} (ns: ${NS})"
    done
fi
echo "  Namespaces:"
for NS in "${RHOAI_NAMESPACES[@]}" $([ "$KEEP_ADDONS" != true ] && echo "${ADDON_NAMESPACES[@]}"); do
    oc get ns "$NS" &>/dev/null && echo "    • ${NS}"
done
CRD_REGEX="$RHOAI_CRD_REGEX"
[ "$KEEP_ADDONS" != true ] && CRD_REGEX="${RHOAI_CRD_REGEX}|${ADDON_CRD_REGEX}"
CRD_COUNT=$(oc get crd -o name 2>/dev/null | sed 's#.*/##' | grep -Ec "$CRD_REGEX" || true)
echo "  CRDs to delete: ${CRD_COUNT}"
[ "$INCLUDE_CERT_MANAGER" != true ] && echo "  (cert-manager kept — use --include-cert-manager to remove it)"
echo ""

if [ "$DRY_RUN" = true ]; then
    info "Dry run — nothing deleted."
    exit 0
fi

###############################################################################
# Confirmation
###############################################################################
warn "This removes RHOAI, all models, notebooks, pipelines, MaaS data and the listed operators."
if [ "$ASSUME_YES" != true ]; then
    ANSWER=""
    if [ -r /dev/tty ]; then
        printf "Type 'uninstall' to continue: " > /dev/tty
        read -r ANSWER < /dev/tty || ANSWER=""
    fi
    if [ "$ANSWER" != "uninstall" ]; then
        error "Aborted (no confirmation). Use --yes to skip the prompt."
        exit 1
    fi
fi
echo ""

###############################################################################
# Helpers
###############################################################################
# Delete every object of a resource type; strip finalizers of leftovers after timeout
delete_all_of() {
    local RES="$1" TIMEOUT="${2:-120}"
    oc get crd "$RES" &>/dev/null || return 0
    local N
    N=$(oc get "$RES" -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "${N:-0}" -eq 0 ] && return 0
    info "Deleting ${N} ${RES}..."
    oc delete "$RES" --all -A --wait=false >/dev/null 2>&1 || true
    local WAIT=0
    while [ $WAIT -lt "$TIMEOUT" ]; do
        [ "$(oc get "$RES" -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] && { success "  ${RES} removed"; return 0; }
        sleep 5; WAIT=$((WAIT + 5))
    done
    warn "  ${RES}: still present after ${TIMEOUT}s — removing finalizers"
    oc get "$RES" -A -o go-template='{{range .items}}{{if .metadata.namespace}}{{.metadata.namespace}}{{else}}-{{end}} {{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null \
      | while read -r NS NAME; do
            [ -z "$NAME" ] && continue
            if [ "$NS" = "-" ]; then
                oc patch "$RES" "$NAME" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
            else
                oc patch "$RES" "$NAME" -n "$NS" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
            fi
        done
}

delete_single() {   # kind name [timeout]
    local KIND="$1" NAME="$2" TIMEOUT="${3:-300}"
    oc get "$KIND" "$NAME" &>/dev/null || return 0
    info "Deleting ${KIND} ${NAME} (up to ${TIMEOUT}s)..."
    oc delete "$KIND" "$NAME" --wait=false >/dev/null 2>&1 || true
    local WAIT=0
    while oc get "$KIND" "$NAME" &>/dev/null; do
        if [ $WAIT -ge "$TIMEOUT" ]; then
            warn "  ${KIND} ${NAME} stuck — removing finalizers"
            oc patch "$KIND" "$NAME" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
            break
        fi
        sleep 10; WAIT=$((WAIT + 10))
    done
    success "  ${KIND} ${NAME} removed"
}

remove_operator() {   # namespace package
    local NS="$1" PKG="$2" SUB CSV
    SUB=$(oc get sub -n "$NS" -o go-template='{{range .items}}{{if eq .spec.name "'"$PKG"'"}}{{.metadata.name}}{{end}}{{end}}' 2>/dev/null)
    [ -z "$SUB" ] && return 0
    CSV=$(oc get sub "$SUB" -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    oc delete sub "$SUB" -n "$NS" >/dev/null 2>&1 || true
    [ -n "$CSV" ] && oc delete csv "$CSV" -n "$NS" >/dev/null 2>&1 || true
    success "  operator ${PKG} removed (ns: ${NS}${CSV:+, csv: $CSV})"
}

###############################################################################
# 1. Custom resources (operators still running → finalizers resolve)
###############################################################################
info "=== 1/5: Custom resources ==="
for RES in "${CR_LIST[@]}"; do
    if [ "$KEEP_ADDONS" = true ]; then
        case "$RES" in *kueue*|*eclipse.che|*observability.openshift.io|leaderworkersetoperators*|kuadrants*) continue ;; esac
    fi
    delete_all_of "$RES" 120
done
# Gateways / filters created by RHOAI or the scripts
for GW in maas-default-gateway openshift-ai-inference data-science-gateway; do
    oc delete gateway "$GW" -n openshift-ingress --ignore-not-found >/dev/null 2>&1 && true
done
oc delete envoyfilter healthcheck-filter increase-ratelimit-cluster-timeout -n openshift-ingress --ignore-not-found >/dev/null 2>&1 || true
oc delete gatewayclass maas-gateway-class data-science-gateway-class --ignore-not-found >/dev/null 2>&1 || true
oc delete prometheusrule accelerator-recording-rules -n nvidia-gpu-operator --ignore-not-found >/dev/null 2>&1 || true
success "Gateways, EnvoyFilters and recording rules removed"
echo ""

###############################################################################
# 2. DataScienceCluster → DSCInitialization
###############################################################################
info "=== 2/5: DataScienceCluster / DSCInitialization ==="
delete_single datasciencecluster default-dsc 600
delete_single dscinitialization default-dsci 300
echo ""

###############################################################################
# 3/4. Operators
###############################################################################
info "=== 3/5: RHOAI operator ==="
remove_operator redhat-ods-operator rhods-operator
echo ""

if [ "$KEEP_ADDONS" != true ]; then
    info "=== 4/5: Add-on operators ==="
    for E in "${ADDON_OPS[@]}"; do
        IFS='|' read -r NS PKG _ <<< "$E"
        remove_operator "$NS" "$PKG"
    done
    # Remove the RHCL console plugin entry from the console config
    PLUGINS=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || true)
    if echo "$PLUGINS" | grep -q kuadrant-console-plugin; then
        IDX=$(oc get console.operator.openshift.io cluster -o go-template='{{range $i, $p := .spec.plugins}}{{if eq $p "kuadrant-console-plugin"}}{{$i}}{{end}}{{end}}')
        [ -n "$IDX" ] && oc patch console.operator.openshift.io cluster --type=json \
            -p "[{\"op\":\"remove\",\"path\":\"/spec/plugins/${IDX}\"}]" >/dev/null 2>&1 && success "  kuadrant-console-plugin disabled"
    fi
else
    info "=== 4/5: Add-on operators [KEPT] ==="
fi
echo ""

###############################################################################
# 5. Webhooks, CRDs, namespaces
###############################################################################
info "=== 5/5: Webhooks, CRDs, namespaces ==="
# Webhooks whose services are gone would block API calls → remove first
for KIND in validatingwebhookconfiguration mutatingwebhookconfiguration; do
    for WH in $(oc get "$KIND" -o name 2>/dev/null | sed 's#.*/##' | grep -E "$WEBHOOK_REGEX" || true); do
        oc delete "$KIND" "$WH" --ignore-not-found >/dev/null 2>&1 && echo "    - ${KIND} ${WH}"
    done
done
success "Webhooks removed"

for CRD in $(oc get crd -o name 2>/dev/null | sed 's#.*/##' | grep -E "$CRD_REGEX" || true); do
    oc delete crd "$CRD" --wait=false >/dev/null 2>&1 || true
done
# CRDs stuck on remaining CRs → strip CR finalizers, CRD then completes
sleep 20
for CRD in $(oc get crd -o name 2>/dev/null | sed 's#.*/##' | grep -E "$CRD_REGEX" || true); do
    oc get "$CRD" -A -o go-template='{{range .items}}{{if .metadata.namespace}}{{.metadata.namespace}}{{else}}-{{end}} {{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null \
      | while read -r NS NAME; do
            [ -z "$NAME" ] && continue
            if [ "$NS" = "-" ]; then
                oc patch "$CRD" "$NAME" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
            else
                oc patch "$CRD" "$NAME" -n "$NS" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
            fi
        done
done
success "CRDs deleted ($(oc get crd -o name 2>/dev/null | sed 's#.*/##' | grep -Ec "$CRD_REGEX" || true) remaining)"

NS_LIST=("${RHOAI_NAMESPACES[@]}")
if [ "$KEEP_ADDONS" != true ]; then
    NS_LIST+=("${ADDON_NAMESPACES[@]}")
    for E in "${ADDON_OPS[@]}"; do
        IFS='|' read -r NS _ DEL <<< "$E"
        [ "$DEL" = "yes" ] && NS_LIST+=("$NS")
    done
fi
for NS in $(printf '%s\n' "${NS_LIST[@]}" | awk '!seen[$0]++'); do
    oc get ns "$NS" &>/dev/null && oc delete ns "$NS" --wait=false >/dev/null 2>&1 && echo "    - namespace ${NS}"
done
info "Waiting for namespaces to terminate (up to 5 min)..."
WAIT=0
while [ $WAIT -lt 300 ]; do
    LEFT=""
    for NS in "${NS_LIST[@]}"; do oc get ns "$NS" &>/dev/null && LEFT="$LEFT $NS"; done
    [ -z "$LEFT" ] && break
    sleep 15; WAIT=$((WAIT + 15))
done
if [ -n "${LEFT:-}" ]; then
    warn "Still terminating:${LEFT}"
    echo "  Check what blocks them:"
    echo "    oc get ns <name> -o jsonpath='{.status.conditions}'"
    echo "    oc api-resources --verbs=list --namespaced -o name | xargs -n1 oc get -n <name> --ignore-not-found --show-kind"
else
    success "Namespaces removed"
fi
echo ""

###############################################################################
# Result
###############################################################################
info "=== Remaining ==="
echo "  RHOAI CSV:  $(oc get csv -A --no-headers 2>/dev/null | awk '/rhods-operator/{print $2}' | head -1 || true)"
echo "  DSC/DSCI:   $(oc get datasciencecluster,dscinitialization --no-headers 2>/dev/null | wc -l | tr -d ' ') objects"
echo "  RHOAI CRDs: $(oc get crd -o name 2>/dev/null | sed 's#.*/##' | grep -Ec "$RHOAI_CRD_REGEX" || true)"

echo ""
echo "=============================================="
success "Uninstall finished."
echo ""
echo "  Re-install and verify:"
echo "   1. rhoai-enable-all-features-351.sh or -352.sh   (Step 0 installs 3.5.1 or 3.5.2)"
echo "   2. rhoai-setup-maas-351.sh (or -352.sh)"
echo "  (SNO: sno-enable-all-features-351.sh / sno-setup-maas-351.sh)"
echo "=============================================="
