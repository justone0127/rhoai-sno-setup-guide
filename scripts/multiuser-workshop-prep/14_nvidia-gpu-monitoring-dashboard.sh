#!/bin/bash
###############################################################################
# nvidia-gpu-monitoring-dashboard.sh
#
# Add the NVIDIA DCGM Exporter dashboard to the OpenShift console
# (Observe → Dashboards → "NVIDIA DCGM Exporter Dashboard"): GPU temperature,
# power, SM clock, utilization, framebuffer memory, tensor core usage.
#
# Based on: https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/
#           enable-gpu-monitoring-dashboard.html
#
# How: downloads dcgm-exporter-dashboard.json, stores it in ConfigMap
# nvidia-dcgm-exporter-dashboard (openshift-config-managed) and labels it
# console.openshift.io/dashboard=true (Administrator) and
# console.openshift.io/odc-dashboard=true (Developer). Re-running updates it.
#
# Needs DCGM metrics in cluster monitoring — 04_rhoai-install-gpu-operator.sh
# already enables the DCGM exporter ServiceMonitor and labels
# nvidia-gpu-operator with openshift.io/cluster-monitoring=true.
#
# Run as cluster-admin.
#
# Usage:
#   bash 14_nvidia-gpu-monitoring-dashboard.sh
#   bash 14_nvidia-gpu-monitoring-dashboard.sh --no-developer   # admin view only
#   bash 14_nvidia-gpu-monitoring-dashboard.sh --file ./dcgm-exporter-dashboard.json
#   bash 14_nvidia-gpu-monitoring-dashboard.sh --remove
#
# Options (default):
#   --file           download from the DCGM exporter GitHub repository
#   --url            https://github.com/NVIDIA/dcgm-exporter/raw/main/grafana/dcgm-exporter-dashboard.json
#   --no-developer   do not show the dashboard in the Developer perspective
#   --remove         delete the dashboard ConfigMap
###############################################################################
set -euo pipefail

URL="https://github.com/NVIDIA/dcgm-exporter/raw/main/grafana/dcgm-exporter-dashboard.json"
FILE=""
DEVELOPER=true
REMOVE=false
NS="openshift-config-managed"
CM="nvidia-dcgm-exporter-dashboard"
GPU_NS="nvidia-gpu-operator"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)          FILE="$2"; shift 2 ;;
        --url)           URL="$2"; shift 2 ;;
        --no-developer)  DEVELOPER=false; shift ;;
        --remove)        REMOVE=true; shift ;;
        --help|-h)       sed -n '3,33p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

echo "=============================================="
echo " NVIDIA GPU monitoring dashboard"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if [ "$REMOVE" = true ]; then
    oc delete configmap "$CM" -n "$NS" --ignore-not-found
    success "Done. Dashboard removed."
    exit 0
fi

###############################################################################
# DCGM exporter (warn only — the dashboard is created either way)
###############################################################################
if ! oc get namespace "$GPU_NS" &>/dev/null; then
    warn "Namespace ${GPU_NS} not found — install the GPU operator first (04_rhoai-install-gpu-operator.sh)"
else
    if [ "$(oc get namespace "$GPU_NS" -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}')" != "true" ]; then
        warn "${GPU_NS} lacks openshift.io/cluster-monitoring=true — the dashboard will be empty"
        echo "  Fix: oc label namespace ${GPU_NS} openshift.io/cluster-monitoring=true"
    fi
    DCGM=$(oc get pods -n "$GPU_NS" -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | grep -c Running || true)
    info "Running DCGM exporter pods: ${DCGM}"
    [ "$DCGM" -eq 0 ] && warn "No DCGM exporter pod running yet — graphs appear once GPU nodes are ready"
fi

###############################################################################
# Dashboard JSON
###############################################################################
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
JSON="${TMP_DIR}/dcgm-exporter-dashboard.json"

if [ -n "$FILE" ]; then
    [ -f "$FILE" ] || { error "File not found: ${FILE}"; exit 1; }
    cp "$FILE" "$JSON"
    info "Dashboard file: ${FILE}"
else
    info "Downloading ${URL}"
    if ! curl -sSLf -o "$JSON" "$URL"; then
        error "Download failed — download it elsewhere and pass --file <path>"
        exit 1
    fi
fi
if ! grep -q '"panels"' "$JSON"; then
    error "Not a Grafana dashboard JSON: $(head -c 80 "$JSON")"
    exit 1
fi

###############################################################################
# ConfigMap + labels (create or replace, so re-running picks up a new JSON)
###############################################################################
oc create configmap "$CM" -n "$NS" --from-file=dcgm-exporter-dashboard.json="$JSON" \
    --dry-run=client -o yaml > "${TMP_DIR}/cm.yaml"
if oc get configmap "$CM" -n "$NS" &>/dev/null; then
    oc replace -f "${TMP_DIR}/cm.yaml" >/dev/null
    info "ConfigMap ${CM} updated"
else
    oc create -f "${TMP_DIR}/cm.yaml" >/dev/null
    info "ConfigMap ${CM} created"
fi

oc label configmap "$CM" -n "$NS" console.openshift.io/dashboard=true --overwrite >/dev/null
if [ "$DEVELOPER" = true ]; then
    oc label configmap "$CM" -n "$NS" console.openshift.io/odc-dashboard=true --overwrite >/dev/null
else
    oc label configmap "$CM" -n "$NS" console.openshift.io/odc-dashboard- >/dev/null 2>&1 || true
fi

echo ""
info "=== ${NS}/${CM} ==="
oc get configmap "$CM" -n "$NS" --show-labels

echo ""
echo "=============================================="
success "Done. Console → Observe → Dashboards → 'NVIDIA DCGM Exporter Dashboard'"
echo "  Graphs can take a few minutes to fill in after GPU nodes become Ready."
echo "=============================================="
