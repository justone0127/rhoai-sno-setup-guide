#!/bin/bash
###############################################################################
# rhoai-create-gpu-profile.sh
#
# Create (or update) the GPU HardwareProfile used by the workshop for model
# deployment. Defaults: 1 CPU / 10Gi memory / 1 GPU, scheduled only on nodes
# labelled nvidia.com/gpu.product=<product> (auto-detected, e.g. NVIDIA-L4).
#
# The profile is copied into a model's spec at deploy time — changing it later
# does NOT affect models that are already deployed (redeploy them).
#
# Run as cluster-admin. Re-running is safe (oc apply).
#
# Usage:
#   bash rhoai-create-gpu-profile.sh                              # defaults
#   bash rhoai-create-gpu-profile.sh --gpu-product NVIDIA-L4-SHARED
#   bash rhoai-create-gpu-profile.sh --memory 12Gi --memory-max 16Gi
#   bash rhoai-create-gpu-profile.sh --name gpu-l4 --display-name "NVIDIA L4"
#   bash rhoai-create-gpu-profile.sh --dry-run                    # print YAML only
#   curl ... | bash -s -- --memory 10Gi
#
# Options (default):
#   --name           gpu-profile
#   --display-name   "GPU (<product>)"
#   --gpu-product    auto-detected from node label nvidia.com/gpu.product
#   --cpu / --cpu-max            1 / 8
#   --memory / --memory-min / --memory-max   10Gi / 1Gi / 16Gi
#   --gpu / --gpu-max            1 / 4
###############################################################################
set -euo pipefail

PROFILE_NAME="gpu-profile"
DISPLAY_NAME=""
GPU_PRODUCT=""
CPU_DEFAULT="1"
CPU_MAX="8"
MEM_DEFAULT="10Gi"
MEM_MIN="1Gi"
MEM_MAX="16Gi"
GPU_DEFAULT="1"
GPU_MAX="4"
DRY_RUN=false
APP_NS="redhat-ods-applications"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)          PROFILE_NAME="$2"; shift 2 ;;
        --display-name)  DISPLAY_NAME="$2"; shift 2 ;;
        --gpu-product)   GPU_PRODUCT="$2"; shift 2 ;;
        --cpu)           CPU_DEFAULT="$2"; shift 2 ;;
        --cpu-max)       CPU_MAX="$2"; shift 2 ;;
        --memory)        MEM_DEFAULT="$2"; shift 2 ;;
        --memory-min)    MEM_MIN="$2"; shift 2 ;;
        --memory-max)    MEM_MAX="$2"; shift 2 ;;
        --gpu)           GPU_DEFAULT="$2"; shift 2 ;;
        --gpu-max)       GPU_MAX="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help|-h)       sed -n '3,30p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " RHOAI 3.5 — GPU HardwareProfile"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if ! oc get crd hardwareprofiles.infrastructure.opendatahub.io &>/dev/null; then
    error "HardwareProfile CRD not found — is RHOAI installed?"
    exit 1
fi

###############################################################################
# GPU product label (from NVIDIA GPU Feature Discovery)
###############################################################################
PRODUCTS=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' \
    2>/dev/null | grep -v '^$' | sort | uniq -c || true)

if [ -z "$GPU_PRODUCT" ]; then
    if [ -z "$PRODUCTS" ]; then
        GPU_PRODUCT="NVIDIA-L4"
        warn "No node has nvidia.com/gpu.product yet (GPU nodes not ready?) — using ${GPU_PRODUCT}"
    elif [ "$(echo "$PRODUCTS" | wc -l | xargs)" -eq 1 ]; then
        GPU_PRODUCT=$(echo "$PRODUCTS" | awk '{print $2}')
        info "Detected GPU product: ${GPU_PRODUCT}"
    else
        error "Several GPU products found — choose one with --gpu-product:"
        echo "$PRODUCTS" | sed 's/^/    /'
        exit 1
    fi
fi
DISPLAY_NAME="${DISPLAY_NAME:-GPU (${GPU_PRODUCT})}"

MATCHING=$(oc get nodes -l "nvidia.com/gpu.product=${GPU_PRODUCT}" --no-headers 2>/dev/null | wc -l | xargs)
if [ "$MATCHING" -eq 0 ]; then
    warn "No node currently labelled nvidia.com/gpu.product=${GPU_PRODUCT} — models will stay Pending until one exists"
else
    info "Nodes matching nvidia.com/gpu.product=${GPU_PRODUCT}: ${MATCHING}"
    # Warn when the default request does not fit the smallest matching node
    MIN_MEM_KI=$(oc get nodes -l "nvidia.com/gpu.product=${GPU_PRODUCT}" \
        -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' \
        | sed 's/Ki$//' | sort -n | head -1)
    REQ_KI=""
    case "$MEM_DEFAULT" in
        *Gi) REQ_KI=$(( ${MEM_DEFAULT%Gi} * 1024 * 1024 )) ;;
        *Mi) REQ_KI=$(( ${MEM_DEFAULT%Mi} * 1024 )) ;;
    esac
    if [[ -n "$REQ_KI" && "$MIN_MEM_KI" =~ ^[0-9]+$ ]]; then
        info "Smallest node allocatable memory: $(( MIN_MEM_KI / 1024 / 1024 ))Gi"
        if [ "$REQ_KI" -gt "$MIN_MEM_KI" ]; then
            warn "Default memory ${MEM_DEFAULT} is larger than the smallest node can offer — pods may stay Pending"
        fi
    fi
fi
echo ""

###############################################################################
# Manifest
###############################################################################
MANIFEST="apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  name: ${PROFILE_NAME}
  namespace: ${APP_NS}
  annotations:
    opendatahub.io/display-name: \"${DISPLAY_NAME}\"
    opendatahub.io/description: \"${GPU_DEFAULT} x ${GPU_PRODUCT}, ${CPU_DEFAULT} CPU, ${MEM_DEFAULT} memory\"
spec:
  identifiers:
    - defaultCount: '${CPU_DEFAULT}'
      displayName: CPU
      identifier: cpu
      maxCount: '${CPU_MAX}'
      minCount: 1
      resourceType: CPU
    - defaultCount: ${MEM_DEFAULT}
      displayName: Memory
      identifier: memory
      maxCount: ${MEM_MAX}
      minCount: ${MEM_MIN}
      resourceType: Memory
    - defaultCount: ${GPU_DEFAULT}
      displayName: GPU
      identifier: nvidia.com/gpu
      maxCount: ${GPU_MAX}
      minCount: 1
      resourceType: Accelerator
  scheduling:
    node:
      nodeSelector:
        nvidia.com/gpu.product: ${GPU_PRODUCT}
      tolerations: []
    type: Node"

if [ "$DRY_RUN" = true ]; then
    info "Dry run — manifest:"
    echo "$MANIFEST"
    exit 0
fi

if oc get hardwareprofiles.infrastructure.opendatahub.io "$PROFILE_NAME" -n "$APP_NS" &>/dev/null; then
    info "HardwareProfile ${PROFILE_NAME} exists — updating"
fi
echo "$MANIFEST" | oc apply -f -
echo ""

###############################################################################
# Result
###############################################################################
info "=== HardwareProfile ${PROFILE_NAME} ==="
oc get hardwareprofiles.infrastructure.opendatahub.io "$PROFILE_NAME" -n "$APP_NS" \
    -o jsonpath='{range .spec.identifiers[*]}  {.identifier}: default={.defaultCount} min={.minCount} max={.maxCount}{"\n"}{end}'
echo "  nodeSelector: nvidia.com/gpu.product=${GPU_PRODUCT}"

echo ""
echo "=============================================="
success "Done. Select '${DISPLAY_NAME}' when deploying a model."
echo "  Already-deployed models keep their old resources — redeploy to apply changes."
echo "=============================================="
