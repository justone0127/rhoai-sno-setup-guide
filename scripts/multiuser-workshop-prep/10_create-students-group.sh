#!/bin/bash
###############################################################################
# create-students-group.sh
#
# Add existing workshop users (default: user1 .. user30) to the "students"
# group. The group is created if it does not exist; members already in the
# group are kept (add-only, nothing is removed).
#
# Run as cluster-admin. Re-running is safe.
#
# Usage:
#   bash 10_create-students-group.sh                  # user1..user30 -> students
#   bash 10_create-students-group.sh --count 40       # user1..user40
#   bash 10_create-students-group.sh --group students --prefix user --count 30
#
# Options (default):
#   --group     students
#   --prefix    user
#   --count     30
###############################################################################
set -euo pipefail

GROUP="students"
PREFIX="user"
COUNT=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --group)    GROUP="$2"; shift 2 ;;
        --prefix)   PREFIX="$2"; shift 2 ;;
        --count)    COUNT="$2"; shift 2 ;;
        --help|-h)  sed -n '3,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    error "--count must be a positive integer (got: ${COUNT})"
    exit 1
fi

echo "=============================================="
echo " Workshop students group"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"
info "Target: ${PREFIX}1 .. ${PREFIX}${COUNT} -> group '${GROUP}'"
echo ""

###############################################################################
# Check users exist
###############################################################################
CLUSTER_USERS=$(oc get users -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
USERS=()
NOT_FOUND=()
for i in $(seq 1 "$COUNT"); do
    U="${PREFIX}${i}"
    USERS+=("$U")
    grep -qx "$U" <<< "$CLUSTER_USERS" || NOT_FOUND+=("$U")
done
if [ ${#NOT_FOUND[@]} -gt 0 ]; then
    warn "Not found as User objects (added anyway): ${NOT_FOUND[*]}"
else
    success "All ${COUNT} users exist"
fi

###############################################################################
# Create group + add members
###############################################################################
if oc get group "$GROUP" &>/dev/null; then
    info "Group '${GROUP}' already exists"
else
    oc adm groups new "$GROUP" >/dev/null
    success "Group '${GROUP}' created"
fi

CURRENT=$(oc get group "$GROUP" -o jsonpath='{range .users[*]}{@}{"\n"}{end}' 2>/dev/null || true)
MISSING=()
for U in "${USERS[@]}"; do
    grep -qx "$U" <<< "$CURRENT" || MISSING+=("$U")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    oc adm groups add-users "$GROUP" "${MISSING[@]}" >/dev/null
    success "Added ${#MISSING[@]} users; $(( COUNT - ${#MISSING[@]} )) were already members"
else
    success "All ${COUNT} users are already members"
fi
echo ""

###############################################################################
# Result
###############################################################################
info "=== Group ${GROUP} ==="
oc get group "$GROUP"

echo ""
echo "=============================================="
success "Done."
echo "  Next: bash 11_deploy-curriculum-mcp.sh   (shared MCP + view role for '${GROUP}')"
echo "=============================================="
