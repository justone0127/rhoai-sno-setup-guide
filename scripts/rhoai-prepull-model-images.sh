#!/bin/bash
###############################################################################
# rhoai-prepull-model-images.sh
#
# Pre-pull modelcar images onto every GPU node so the first model deployment
# skips the image download (~15GB for Gemma-4-E4B, ~5 min per node).
#
# How: a DaemonSet runs on each GPU node (nvidia.com/gpu.present=true by
# default — 16 nodes → 16 pods). Each image runs as a container doing
# 'sleep infinity' with tiny requests (no GPU), so the kubelet pulls it and
# keeps it from image garbage collection while the DaemonSet exists.
# New GPU nodes added later get the images automatically.
#
# Run as cluster-admin. Re-running is safe (oc apply).
#
# Usage:
#   bash rhoai-prepull-model-images.sh                     # Gemma-4-E4B, wait
#   bash rhoai-prepull-model-images.sh --image registry.redhat.io/rhai/modelcar-xxx:3.0 \
#                                      --image registry.redhat.io/rhai/modelcar-yyy:3.0
#   bash rhoai-prepull-model-images.sh --no-wait           # apply and exit
#   bash rhoai-prepull-model-images.sh --status            # show progress only
#   bash rhoai-prepull-model-images.sh --dry-run           # print YAML only
#   bash rhoai-prepull-model-images.sh --remove            # delete (images stay
#                                                          # until kubelet GC)
#
# Options (default):
#   --image          registry.redhat.io/rhai/modelcar-redhatai-gemma-4-e4b-it:3.0
#   --node-selector  nvidia.com/gpu.present=true
#   --namespace      model-prepull
#   --timeout        1800 (seconds to wait for all nodes)
###############################################################################
set -euo pipefail

DEFAULT_IMAGE="registry.redhat.io/rhai/modelcar-redhatai-gemma-4-e4b-it:3.0"
IMAGES=()
NODE_SELECTOR="nvidia.com/gpu.present=true"
NAMESPACE="model-prepull"
NAME="model-image-prepull"
TIMEOUT=1800
WAIT=true
DRY_RUN=false
MODE="apply"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)          IMAGES+=("$2"); shift 2 ;;
        --node-selector)  NODE_SELECTOR="$2"; shift 2 ;;
        --namespace)      NAMESPACE="$2"; shift 2 ;;
        --timeout)        TIMEOUT="$2"; shift 2 ;;
        --no-wait)        WAIT=false; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --status)         MODE="status"; shift ;;
        --remove)         MODE="remove"; shift ;;
        --help|-h)        sed -n '3,33p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
[ ${#IMAGES[@]} -eq 0 ] && IMAGES=("$DEFAULT_IMAGE")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " RHOAI — Pre-pull model images on GPU nodes"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

###############################################################################
# Status / progress
###############################################################################
show_status() {
    local DESIRED READY
    DESIRED=$(oc get ds "$NAME" -n "$NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    READY=$(oc get ds "$NAME" -n "$NAMESPACE" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    echo "${READY:-0}/${DESIRED:-0}"
}

print_pods() {
    oc get pods -n "$NAMESPACE" -l app="$NAME" -o wide --no-headers 2>/dev/null \
        | awk '{printf "  %-45s %-22s %s\n", $7, $3, $2}' | sort
}

wait_ready() {
    local START=$SECONDS STATE DESIRED READY
    local PULLING
    info "Waiting until every node has pulled the image(s) (timeout ${TIMEOUT}s)..."
    info "Nodes pull in parallel (~4-5 min for 16GB), so most finish at about the same time."
    while true; do
        STATE=$(show_status)
        READY=${STATE%/*}; DESIRED=${STATE#*/}
        PULLING=$(oc get pods -n "$NAMESPACE" -l app="$NAME" --no-headers 2>/dev/null | grep -c ContainerCreating || true)
        echo -e "  [$(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s] ready nodes: ${STATE}  (pulling: ${PULLING})"
        if [ "$DESIRED" -gt 0 ] && [ "$READY" -eq "$DESIRED" ]; then
            success "All ${DESIRED} node(s) have the image(s)"
            return 0
        fi
        if [ $(( SECONDS - START )) -ge "$TIMEOUT" ]; then
            warn "Timed out — check: oc get pods -n ${NAMESPACE} -o wide"
            print_pods
            return 1
        fi
        sleep 20
    done
}

if [ "$MODE" = "status" ]; then
    info "Ready nodes: $(show_status)"
    print_pods
    exit 0
fi

if [ "$MODE" = "remove" ]; then
    oc delete namespace "$NAMESPACE" --ignore-not-found
    success "Removed namespace ${NAMESPACE} (pulled images stay on nodes until kubelet GC)"
    exit 0
fi

###############################################################################
# Nodes
###############################################################################
NODE_COUNT=$(oc get nodes -l "$NODE_SELECTOR" --no-headers 2>/dev/null | wc -l | xargs)
info "Target nodes (${NODE_SELECTOR}): ${NODE_COUNT}"
[ "$NODE_COUNT" -eq 0 ] && warn "No node matches yet — pods start when GPU nodes are labelled"
info "Images:"
for IMG in "${IMAGES[@]}"; do echo "    - ${IMG}"; done
echo ""

SEL_KEY="${NODE_SELECTOR%%=*}"
SEL_VAL="${NODE_SELECTOR#*=}"

###############################################################################
# Manifest
###############################################################################
CONTAINERS=""
i=0
for IMG in "${IMAGES[@]}"; do
    CONTAINERS+="      - name: prepull-${i}
        image: ${IMG}
        imagePullPolicy: IfNotPresent
        command: [\"sh\", \"-c\", \"echo pulled ${IMG}; sleep infinity\"]
        resources:
          requests: {cpu: 1m, memory: 8Mi}
          limits: {cpu: 50m, memory: 32Mi}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: {drop: [ALL]}
"
    i=$((i + 1))
done

MANIFEST="apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    matchLabels:
      app: ${NAME}
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 100%
  template:
    metadata:
      labels:
        app: ${NAME}
    spec:
      nodeSelector:
        ${SEL_KEY}: \"${SEL_VAL}\"
      tolerations:
      - operator: Exists
      terminationGracePeriodSeconds: 1
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      containers:
${CONTAINERS}"

if [ "$DRY_RUN" = true ]; then
    info "Dry run — manifest:"
    echo "$MANIFEST"
    exit 0
fi

echo "$MANIFEST" | oc apply -f -
echo ""

if [ "$WAIT" = true ]; then
    wait_ready || true
    echo ""
    print_pods
fi

echo ""
echo "=============================================="
success "Done."
echo "  Progress : bash $0 --status"
echo "  Remove   : bash $0 --remove   (keep it during the workshop so images are not GC'd)"
echo "=============================================="
