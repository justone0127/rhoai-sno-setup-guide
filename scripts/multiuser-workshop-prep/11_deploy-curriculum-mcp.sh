#!/bin/bash
###############################################################################
# deploy-curriculum-mcp.sh
#
# Deploy shared curriculum MCP servers into a common namespace and let
# workshop students view it (read-only). Pick the MCP(s) you want each time.
#
# MCP catalog = every 09_*.yaml next to this script. The MCP name is the
# Deployment name inside the YAML (see --list). Add a new MCP by dropping in
# another 09_<name>.yaml.
#
#   1. Create namespace (default: mcp-servers)
#   2. oc apply the selected MCP YAML(s) -n <namespace>
#   3. Wait for the Deployment rollout
#   4. Register the MCP in the RHOAI dashboard (AI asset endpoints → MCP
#      servers) via ConfigMap gen-ai-aa-mcp-servers in redhat-ods-applications
#      (Technology Preview). Other entries in that ConfigMap are kept.
#   5. oc adm policy add-role-to-group view <group> -n <namespace>
#
# Students get the "view" role only — they can see the project, pods, logs
# and services but cannot change the shared servers.
# --remove deletes the MCP and its dashboard entry.
#
# Run as cluster-admin. Re-running is safe.
#
# Usage:
#   bash 10_create-students-group.sh                    # run first: user1..user30 -> students
#   bash 11_deploy-curriculum-mcp.sh --list             # show MCP catalog + deployed state
#   bash 11_deploy-curriculum-mcp.sh                    # interactive selection
#   bash 11_deploy-curriculum-mcp.sh --mcp pnu-ai-curriculum-mcp
#   bash 11_deploy-curriculum-mcp.sh --mcp pnu-ai-curriculum-mcp,pnu-cse-curriculum-mcp
#   bash 11_deploy-curriculum-mcp.sh --mcp all
#   bash 11_deploy-curriculum-mcp.sh --remove pnu-cse-curriculum-mcp
#   bash 11_deploy-curriculum-mcp.sh --skip-deploy      # namespace + role binding only
#
# Options (default):
#   --mcp           MCP name(s), comma separated, or "all"
#   --remove        delete MCP(s) from the namespace (comma separated, or "all")
#   --list          print catalog and exit
#   --namespace     mcp-servers
#   --group         students
#   --role          view
#   --timeout       300s   (rollout wait; first start runs pip install)
#   --skip-deploy   only create namespace + role binding
#   --no-dashboard  do not register/unregister in the RHOAI dashboard
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
NAMESPACE="mcp-servers"
GROUP="students"
ROLE="view"
TIMEOUT="300s"
SELECT=""
REMOVE=""
LIST=false
SKIP_DEPLOY=false
DASHBOARD=true
DASH_NS="redhat-ods-applications"
DASH_CM="gen-ai-aa-mcp-servers"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mcp)           SELECT="$2"; shift 2 ;;
        --remove)        REMOVE="$2"; shift 2 ;;
        --list)          LIST=true; shift ;;
        --namespace|-n)  NAMESPACE="$2"; shift 2 ;;
        --group)         GROUP="$2"; shift 2 ;;
        --role)          ROLE="$2"; shift 2 ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        --skip-deploy)   SKIP_DEPLOY=true; shift ;;
        --no-dashboard)  DASHBOARD=false; shift ;;
        --help|-h)       sed -n '3,47p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

###############################################################################
# MCP catalog (09_*.yaml)
###############################################################################
NAMES=(); FILES=(); DESCS=()
for f in "$SCRIPT_DIR"/09_*.yaml; do
    [ -f "$f" ] || continue
    n=$(awk '/^kind: Deployment/{d=1} d && /^  name:/{print $2; exit}' "$f")
    [ -n "$n" ] || continue
    NAMES+=("$n"); FILES+=("$f")
    # Description: first line mentioning "MCP 서버" (header comment or server.py docstring)
    DESCS+=("$(grep -m1 'MCP 서버' "$f" | sed -e 's/^[[:space:]#"]*//' -e 's/ *(Streamable HTTP)\.*"*$//')")
done
if [ ${#NAMES[@]} -eq 0 ]; then
    error "No MCP YAML (09_*.yaml) found in ${SCRIPT_DIR}"
    exit 1
fi

file_of() {
    local i
    for i in "${!NAMES[@]}"; do
        [ "${NAMES[$i]}" = "$1" ] && { echo "${FILES[$i]}"; return 0; }
    done
    return 1
}

# Expand "a,b" / "all" into validated names
resolve() {
    local item
    if [ "$1" = "all" ]; then printf '%s\n' "${NAMES[@]}"; return; fi
    for item in ${1//,/ }; do
        if ! file_of "$item" >/dev/null; then
            error "Unknown MCP: ${item} (see --list)"
            exit 1
        fi
        echo "$item"
    done
}

desc_of() {
    local i
    for i in "${!NAMES[@]}"; do
        [ "${NAMES[$i]}" = "$1" ] && { echo "${DESCS[$i]}"; return 0; }
    done
}

# RHOAI dashboard: one key per MCP in ConfigMap gen-ai-aa-mcp-servers.
# JSON merge patch keeps the other keys (e.g. MCPs registered by hand).
dashboard_register() {
    local n="$1" url desc value
    url="http://${n}.${NAMESPACE}.svc.cluster.local:8000/mcp"
    desc="$(desc_of "$n" | sed 's/["\\]//g')"
    value="{\\\"url\\\": \\\"${url}\\\", \\\"description\\\": \\\"${desc}\\\"}"
    if ! oc get configmap "$DASH_CM" -n "$DASH_NS" &>/dev/null; then
        oc create configmap "$DASH_CM" -n "$DASH_NS" >/dev/null
        info "Created ConfigMap ${DASH_CM} in ${DASH_NS}"
    fi
    oc patch configmap "$DASH_CM" -n "$DASH_NS" --type=merge \
        -p "{\"data\":{\"${n}\":\"${value}\"}}" >/dev/null
    success "Dashboard: registered ${n} → ${url}"
}

dashboard_unregister() {
    local n="$1"
    oc get configmap "$DASH_CM" -n "$DASH_NS" &>/dev/null || return 0
    oc patch configmap "$DASH_CM" -n "$DASH_NS" --type=merge \
        -p "{\"data\":{\"${n}\":null}}" >/dev/null
    success "Dashboard: unregistered ${n}"
}

print_catalog() {
    local i state
    for i in "${!NAMES[@]}"; do
        state="-"
        if oc get deployment "${NAMES[$i]}" -n "$NAMESPACE" &>/dev/null; then state="deployed"; fi
        printf "  %d) %-26s %-9s %s\n" $((i + 1)) "${NAMES[$i]}" "$state" "${DESCS[$i]}"
    done
}

echo "=============================================="
echo " Curriculum MCP servers — shared deployment"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"
echo ""

if [ "$LIST" = true ]; then
    info "MCP catalog (namespace ${NAMESPACE}):"
    print_catalog
    exit 0
fi

###############################################################################
# Remove
###############################################################################
if [ -n "$REMOVE" ]; then
    resolve "$REMOVE" >/dev/null   # validate (exits on unknown name)
    for n in $(resolve "$REMOVE"); do
        oc delete -f "$(file_of "$n")" -n "$NAMESPACE" --ignore-not-found
        success "Removed ${n}"
        [ "$DASHBOARD" = true ] && dashboard_unregister "$n"
    done
    echo ""
    info "Remaining:"
    print_catalog
    exit 0
fi

###############################################################################
# Selection
###############################################################################
SELECTED=()
if [ "$SKIP_DEPLOY" = false ]; then
    if [ -z "$SELECT" ]; then
        if [ ! -t 0 ]; then
            error "No terminal for selection — use --mcp <name>|all (see --list)"
            exit 1
        fi
        info "Select MCP(s) to deploy (e.g. 1 or 1,3 or all):"
        print_catalog
        read -r -p "> " ANSWER
        if [ "$ANSWER" = "all" ]; then
            SELECT="all"
        else
            SELECT=""
            for x in ${ANSWER//,/ }; do
                if ! [[ "$x" =~ ^[0-9]+$ ]] || [ "$x" -lt 1 ] || [ "$x" -gt ${#NAMES[@]} ]; then
                    error "Invalid choice: ${x}"
                    exit 1
                fi
                SELECT="${SELECT:+${SELECT},}${NAMES[$((x - 1))]}"
            done
        fi
        [ -n "$SELECT" ] || { error "Nothing selected"; exit 1; }
        echo ""
    fi
    resolve "$SELECT" >/dev/null   # validate (exits on unknown name)
    while read -r n; do SELECTED+=("$n"); done < <(resolve "$SELECT")
fi

###############################################################################
# 1. Namespace
###############################################################################
if oc get namespace "$NAMESPACE" &>/dev/null; then
    info "Namespace ${NAMESPACE} already exists"
else
    oc create namespace "$NAMESPACE"
    success "Namespace ${NAMESPACE} created"
fi
echo ""

###############################################################################
# 2-3. Deploy selected MCP servers
###############################################################################
for n in ${SELECTED[@]+"${SELECTED[@]}"}; do
    f=$(file_of "$n")
    info "Applying $(basename "$f") -n ${NAMESPACE}"
    EXISTED=false
    oc get deployment "$n" -n "$NAMESPACE" &>/dev/null && EXISTED=true
    oc apply -f "$f" -n "$NAMESPACE"
    # ConfigMap changes are not picked up by a running pod — restart on re-run
    if [ "$EXISTED" = true ]; then
        oc rollout restart deployment/"$n" -n "$NAMESPACE" >/dev/null
        info "Restarted ${n} to pick up the latest ConfigMap"
    fi
done

for n in ${SELECTED[@]+"${SELECTED[@]}"}; do
    info "Waiting for ${n} rollout (timeout ${TIMEOUT}, first start runs pip install)..."
    if oc rollout status deployment/"$n" -n "$NAMESPACE" --timeout="$TIMEOUT"; then
        success "${n} is ready"
    else
        warn "Rollout not finished within ${TIMEOUT} — check: oc logs deploy/${n} -n ${NAMESPACE}"
    fi
done
[ "$SKIP_DEPLOY" = true ] && info "--skip-deploy: skipping MCP server deployment"
echo ""

###############################################################################
# 4. RHOAI dashboard registration (AI asset endpoints → MCP servers)
###############################################################################
if [ "$DASHBOARD" = true ] && [ ${#SELECTED[@]} -gt 0 ]; then
    if oc get namespace "$DASH_NS" &>/dev/null; then
        for n in "${SELECTED[@]}"; do dashboard_register "$n"; done
    else
        warn "Namespace ${DASH_NS} not found — is RHOAI installed? Skipping dashboard registration"
    fi
    echo ""
fi

###############################################################################
# 5. Role binding for students
###############################################################################
if ! oc get group "$GROUP" &>/dev/null; then
    warn "Group '${GROUP}' does not exist yet — binding anyway; it takes effect once the group is created"
else
    info "Group '${GROUP}' members: $(oc get group "$GROUP" -o jsonpath='{.users}' | tr -d '[]"' | tr ',' ' ' | wc -w | xargs)"
fi
oc adm policy add-role-to-group "$ROLE" "$GROUP" -n "$NAMESPACE"
success "Granted role '${ROLE}' to group '${GROUP}' in ${NAMESPACE}"
echo ""

###############################################################################
# Result
###############################################################################
info "=== MCP servers in ${NAMESPACE} ==="
print_catalog
echo ""
info "=== RoleBindings in ${NAMESPACE} ==="
oc get rolebindings -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name' 2>/dev/null || true

echo ""
echo "=============================================="
success "Done."
echo "  MCP endpoints (in-cluster):"
for n in "${NAMES[@]}"; do
    if oc get deployment "$n" -n "$NAMESPACE" &>/dev/null; then
        echo "    http://${n}.${NAMESPACE}.svc.cluster.local:8000/mcp"
    fi
done
echo "  Verify as a student:  oc auth can-i list pods -n ${NAMESPACE} --as=user1 --as-group=${GROUP}"
echo "=============================================="
