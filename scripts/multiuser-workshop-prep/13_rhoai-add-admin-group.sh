#!/bin/bash
###############################################################################
# rhoai-add-admin-group.sh
#
# Add a group (default: students) to the OpenShift AI administrator groups —
# same as Dashboard → Settings → User management → Administrator groups.
#
# Why: MaaS governance (Dashboard → Settings → MaaS governance) is admin-only.
# Students must create a MaaSSubscription + MaaSAuthPolicy for the model they
# deploy; until both exist the model stays Pending and is hidden from AI asset
# endpoints (and /v1/models returns nothing for them).
#
# How: appends the group to spec.adminGroups of the RHOAI Auth resource
# (auths.services.platform.opendatahub.io, usually named "auth"). Existing
# admin groups (e.g. rhods-admins) are kept. Re-running is safe.
#
# Members become OpenShift AI administrators: they can open Settings, manage
# workbenches and configure pipelines for any project. This does NOT give
# OpenShift cluster-admin.
#
# Run as cluster-admin.
#
# Usage:
#   bash 13_rhoai-add-admin-group.sh                    # students -> admin groups
#   bash 13_rhoai-add-admin-group.sh --group workshop
#   bash 13_rhoai-add-admin-group.sh --remove           # take students out again
#   bash 13_rhoai-add-admin-group.sh --dry-run          # show current/new list only
#
# Options (default):
#   --group     students
#   --remove    remove the group from admin groups
#   --dry-run   print the change, do not apply
###############################################################################
set -euo pipefail

GROUP="students"
REMOVE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --group)    GROUP="$2"; shift 2 ;;
        --remove)   REMOVE=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --help|-h)  sed -n '3,32p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

echo "=============================================="
echo " OpenShift AI — administrator groups"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

RES="auths.services.platform.opendatahub.io"
AUTH=$(oc get "$RES" -o name 2>/dev/null | head -1 || true)
if [ -z "$AUTH" ]; then
    error "RHOAI Auth resource not found (${RES}) — is OpenShift AI installed?"
    echo "  Fallback: Dashboard → Settings → User management → Administrator groups"
    exit 1
fi
info "Auth resource: ${AUTH}"

if ! oc get group "$GROUP" &>/dev/null; then
    warn "Group '${GROUP}' does not exist yet — run 10_create-students-group.sh first (adding anyway)"
fi

CURRENT=$(oc get "$AUTH" -o jsonpath='{range .spec.adminGroups[*]}{@}{"\n"}{end}')
info "Current admin groups: $(echo "$CURRENT" | xargs | sed 's/ /, /g')"

if [ "$REMOVE" = true ]; then
    if ! grep -qx "$GROUP" <<< "$CURRENT"; then
        success "'${GROUP}' is not an admin group — nothing to do"
        exit 0
    fi
    NEW=$(grep -vx "$GROUP" <<< "$CURRENT" || true)
    if [ -z "$NEW" ]; then
        error "Refusing to remove the last admin group"
        exit 1
    fi
else
    if grep -qx "$GROUP" <<< "$CURRENT"; then
        success "'${GROUP}' is already an admin group — nothing to do"
        exit 0
    fi
    NEW=$(printf '%s\n%s\n' "$CURRENT" "$GROUP" | grep -v '^$')
fi

# Full list (JSON array) so other admin groups are kept
LIST=$(echo "$NEW" | sed 's/.*/"&"/' | paste -sd, -)
PATCH="{\"spec\":{\"adminGroups\":[${LIST}]}}"
info "New admin groups:     $(echo "$NEW" | xargs | sed 's/ /, /g')"

if [ "$DRY_RUN" = true ]; then
    info "Dry run — patch: ${PATCH}"
    exit 0
fi

oc patch "$AUTH" --type=merge -p "$PATCH" >/dev/null
echo ""
info "=== ${AUTH} ==="
echo "  adminGroups:   $(oc get "$AUTH" -o jsonpath='{.spec.adminGroups}')"
echo "  allowedGroups: $(oc get "$AUTH" -o jsonpath='{.spec.allowedGroups}')"

echo ""
echo "=============================================="
if [ "$REMOVE" = true ]; then
    success "Done. '${GROUP}' removed from OpenShift AI administrator groups."
else
    success "Done. Members of '${GROUP}' are now OpenShift AI administrators."
fi
echo "  Users must log out and back in to the dashboard to see the change."
echo "  Check: Dashboard → Settings → User management"
echo "=============================================="
