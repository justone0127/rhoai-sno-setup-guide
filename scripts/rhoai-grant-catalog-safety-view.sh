#!/bin/bash
###############################################################################
# rhoai-grant-catalog-safety-view.sh
#
# Let non-cluster-admin workshop users see the "Safety and security insights"
# tab of Validated models in the Model Catalog (RHOAI 3.5.x).
#
# Why: the tab is served by the EvalHub BFF, which first runs an access check
#   get evaluations.trustyai.opendatahub.io  in the catalog namespace
# ('evaluations' is a virtual resource — no CRD exists). Users without it get
# a 403, which the UI shows as an endless spinner. cluster-admin passes.
#
# Creates in the catalog namespace (default: rhoai-model-registries):
#   Role        catalog-safety-insights-view  (get/list evaluations)
#   RoleBinding catalog-safety-insights-view  → the given group(s)
# Grants no access to real data. Re-running is safe (oc apply).
#
# Note: 'oc auth can-i get evaluations.trustyai.opendatahub.io' always says
# "no" because oc drops the API group for unknown resources. This script
# verifies with a SubjectAccessReview instead (same check as the BFF).
#
# Run as cluster-admin.
#
# Usage:
#   bash rhoai-grant-catalog-safety-view.sh                        # group: students
#   bash rhoai-grant-catalog-safety-view.sh --group workshop
#   bash rhoai-grant-catalog-safety-view.sh --group students,instructors
#   bash rhoai-grant-catalog-safety-view.sh --namespace <catalog-ns>
#   bash rhoai-grant-catalog-safety-view.sh --dry-run              # print YAML only
#   bash rhoai-grant-catalog-safety-view.sh --remove               # delete Role/RoleBinding
#   WORKSHOP_GROUP=workshop bash rhoai-grant-catalog-safety-view.sh
#   curl ... | bash -s -- --group workshop
###############################################################################
set -euo pipefail

GROUPS_CSV="${WORKSHOP_GROUP:-students}"
NAMESPACE=""
DRY_RUN=false
REMOVE=false
NAME="catalog-safety-insights-view"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --group|-g)     GROUPS_CSV="$2"; shift 2 ;;
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --remove)       REMOVE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--group <name>[,<name>...]] [--namespace <ns>] [--dry-run] [--remove]"
            echo "  default group: students (or \$WORKSHOP_GROUP)"
            echo "  default namespace: DSC modelregistry.registriesNamespace or rhoai-model-registries"
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
echo " RHOAI 3.5 — Model Catalog 'Safety and security insights' access"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if [ -z "$NAMESPACE" ]; then
    NAMESPACE=$(oc get datasciencecluster default-dsc \
        -o jsonpath='{.spec.components.modelregistry.registriesNamespace}' 2>/dev/null || true)
    NAMESPACE="${NAMESPACE:-rhoai-model-registries}"
fi

IFS=',' read -r -a GROUP_LIST <<< "$GROUPS_CSV"
info "Namespace: ${NAMESPACE}"
info "Groups:    ${GROUP_LIST[*]}"
echo ""

if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    error "Namespace ${NAMESPACE} not found — is the Model Catalog / Model Registry enabled?"
    exit 1
fi

###############################################################################
# Remove
###############################################################################
if [ "$REMOVE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
        info "Dry run — would delete role/rolebinding ${NAME} in ${NAMESPACE}"
        exit 0
    fi
    oc delete rolebinding "$NAME" -n "$NAMESPACE" --ignore-not-found
    oc delete role "$NAME" -n "$NAMESPACE" --ignore-not-found
    success "Removed ${NAME} from ${NAMESPACE}"
    exit 0
fi

###############################################################################
# Apply
###############################################################################
SUBJECTS=""
for G in "${GROUP_LIST[@]}"; do
    G="$(echo "$G" | xargs)"
    [ -z "$G" ] && continue
    if ! oc get group "$G" &>/dev/null; then
        warn "Group '${G}' does not exist yet — binding it anyway (takes effect once created)"
    else
        COUNT=$(oc get group "$G" -o jsonpath='{.users}' | tr -d '[]"' | tr ',' '\n' | grep -c . || true)
        info "Group '${G}': ${COUNT} user(s)"
    fi
    SUBJECTS+="- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: ${G}
"
done

if [ -z "$SUBJECTS" ]; then
    error "No group given"
    exit 1
fi

MANIFEST="apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
rules:
- apiGroups: [\"trustyai.opendatahub.io\"]
  resources: [\"evaluations\"]
  verbs: [\"get\", \"list\"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${NAME}
subjects:
${SUBJECTS}"

if [ "$DRY_RUN" = true ]; then
    info "Dry run — manifest:"
    echo "$MANIFEST"
    exit 0
fi

echo ""
echo "$MANIFEST" | oc apply -f -
echo ""

###############################################################################
# Verify with SubjectAccessReview (same check as the EvalHub BFF)
###############################################################################
info "=== Verify (SubjectAccessReview per group) ==="
FAILED=0
for G in "${GROUP_LIST[@]}"; do
    G="$(echo "$G" | xargs)"
    [ -z "$G" ] && continue
    ALLOWED=$(cat <<EOF | oc create -f - -o jsonpath='{.status.allowed}' 2>/dev/null || true
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: rhoai-access-probe
  groups: ["${G}", "system:authenticated"]
  resourceAttributes:
    group: trustyai.opendatahub.io
    resource: evaluations
    verb: get
    namespace: ${NAMESPACE}
EOF
)
    if [ "$ALLOWED" = "true" ]; then
        success "group ${G}: allowed"
    else
        error "group ${G}: not allowed (${ALLOWED:-no response})"
        FAILED=1
    fi
done

echo ""
echo "=============================================="
if [ "$FAILED" -eq 0 ]; then
    success "Done. Group members can now open 'Safety and security insights'"
    echo "  (refresh the Model Catalog page in the browser)."
else
    warn "Some checks failed — see above."
fi
echo "  Add users later: oc adm groups add-users <group> <user>"
echo "=============================================="
exit "$FAILED"
