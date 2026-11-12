#!/bin/bash
###############################################################################
# perses-gpu-dashboard.sh
#
# Try the Perses dashboards in the OpenShift console with an NVIDIA GPU
# dashboard (Observe → Dashboards (Perses) → project "gpu-monitoring" →
# "NVIDIA GPU Overview"): GPU card list (node/model/UUID/memory), utilization,
# memory, temperature, power, clocks, tensor cores, and GPU usage per pod.
# Separate from 14_nvidia-gpu-monitoring-dashboard.sh
# (the Grafana-JSON ConfigMap dashboard); both can exist at the same time.
#
# How:
#   1. Installs the Cluster Observability Operator (COO) if missing
#      (namespace openshift-cluster-observability-operator, channel stable).
#   2. Creates/patches UIPlugin "monitoring" with spec.monitoring.perses.enabled.
#   3. Creates a Thanos Querier datasource (Perses has none by default):
#      PersesGlobalDatasource thanos-querier-global-datasource (cluster-wide,
#      default) — or a PersesDatasource in the namespace if that CRD is missing.
#      Skipped when another PersesGlobalDatasource already exists.
#   3b.Creates namespace gpu-monitoring and a PersesDashboard CR in it.
#   4. Optionally (--group) lets a group view (or edit with --editor) the
#      dashboards in that namespace.
#
# The dashboard is a normal CR: edit it in the console (Edit button) or with
#   oc edit persesdashboard nvidia-gpu-overview -n gpu-monitoring
# Re-running this script overwrites console edits made to that dashboard.
#
# Needs DCGM metrics in cluster monitoring (04_rhoai-install-gpu-operator.sh).
# Tensor core panel needs DCGM profiling metrics (DCGM_FI_PROF_*); empty if not
# collected. Run as cluster-admin.
#
# Usage:
#   bash 15_perses-gpu-dashboard.sh
#   bash 15_perses-gpu-dashboard.sh --group students            # students can view
#   bash 15_perses-gpu-dashboard.sh --group students --editor   # ...and edit/create
#   bash 15_perses-gpu-dashboard.sh --dry-run                   # print manifests only
#   bash 15_perses-gpu-dashboard.sh --remove                    # delete the namespace
#
# Options (default):
#   --namespace   gpu-monitoring
#   --group       (none)  group given access to the dashboard namespace
#   --editor      give --group create/update/delete on Perses dashboards
#   --channel     stable  COO subscription channel
#   --dry-run     print the manifests, do not apply
#   --remove      delete the dashboard namespace (COO and UIPlugin are kept)
###############################################################################
set -euo pipefail

NS="gpu-monitoring"
GROUP=""
EDITOR=false
CHANNEL="stable"
DRY_RUN=false
REMOVE=false
COO_NS="openshift-cluster-observability-operator"
DASH="nvidia-gpu-overview"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)  NS="$2"; shift 2 ;;
        --group)      GROUP="$2"; shift 2 ;;
        --editor)     EDITOR=true; shift ;;
        --channel)    CHANNEL="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --remove)     REMOVE=true; shift ;;
        --help|-h)    sed -n '3,45p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

###############################################################################
# Manifests
###############################################################################
coo_manifest() {
cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${COO_NS}
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: ${COO_NS}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: ${COO_NS}
spec:
  channel: ${CHANNEL}
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
}

uiplugin_manifest() {
cat <<EOF
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF
}

# Quoted heredoc: $hostname / {{label}} are Perses syntax, not shell.
dashboard_manifest() {
cat <<'EOF' | sed -e "s/__NS__/${NS}/g" -e "s/__DASH__/${DASH}/g"
apiVersion: perses.dev/v1alpha1
kind: PersesDashboard
metadata:
  name: __DASH__
  namespace: __NS__
spec:
  display:
    name: NVIDIA GPU Overview
  duration: 1h
  refreshInterval: 30s
  variables:
    - kind: ListVariable
      spec:
        name: hostname
        display:
          name: Node
        allowAllValue: true
        allowMultiple: true
        plugin:
          kind: PrometheusLabelValuesVariable
          spec:
            labelName: Hostname
            matchers:
              - DCGM_FI_DEV_GPU_UTIL
  panels:
    gpuCount:
      kind: Panel
      spec:
        display:
          name: GPUs
        plugin:
          kind: StatChart
          spec:
            calculation: last-number
            format:
              unit: decimal
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: count(DCGM_FI_DEV_GPU_UTIL{Hostname=~"$hostname"})
    avgUtil:
      kind: Panel
      spec:
        display:
          name: Average GPU utilization
        plugin:
          kind: GaugeChart
          spec:
            calculation: last-number
            max: 100
            format:
              unit: percent
            thresholds:
              steps:
                - value: 70
                  color: "#f0ab00"
                - value: 90
                  color: "#c9190b"
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: avg(DCGM_FI_DEV_GPU_UTIL{Hostname=~"$hostname"})
    fbUsedTotal:
      kind: Panel
      spec:
        display:
          name: GPU memory used (total)
        plugin:
          kind: StatChart
          spec:
            calculation: last-number
            format:
              unit: bytes
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: sum(DCGM_FI_DEV_FB_USED{Hostname=~"$hostname"}) * 1048576
    powerTotal:
      kind: Panel
      spec:
        display:
          name: Power draw (W, total)
        plugin:
          kind: StatChart
          spec:
            calculation: last-number
            format:
              unit: decimal
              decimalPlaces: 0
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: sum(DCGM_FI_DEV_POWER_USAGE{Hostname=~"$hostname"})
    gpuList:
      kind: Panel
      spec:
        display:
          name: GPU cards
          description: One row per GPU (memory = FB used + free, approx.)
        plugin:
          kind: Table
          spec:
            columnSettings:
              - name: Hostname
                header: Node
              - name: gpu
                header: GPU
              - name: modelName
                header: Model
              - name: UUID
                header: UUID
              - name: value
                header: Memory (GiB)
              - name: timestamp
                hide: true
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: >-
                    max by (Hostname, gpu, modelName, UUID) (
                    DCGM_FI_DEV_FB_USED{Hostname=~"$hostname"} + DCGM_FI_DEV_FB_FREE{Hostname=~"$hostname"}
                    ) / 1024
    gpuUtil:
      kind: Panel
      spec:
        display:
          name: GPU utilization (%)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
              mode: list
            yAxis:
              format:
                unit: percent
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: DCGM_FI_DEV_GPU_UTIL{Hostname=~"$hostname"}
                  seriesNameFormat: "{{Hostname}} / GPU {{gpu}}"
    fbUsedPct:
      kind: Panel
      spec:
        display:
          name: GPU memory used (%)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
              mode: list
            yAxis:
              format:
                unit: percent
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: >-
                    100 * DCGM_FI_DEV_FB_USED{Hostname=~"$hostname"}
                    / (DCGM_FI_DEV_FB_USED{Hostname=~"$hostname"} + DCGM_FI_DEV_FB_FREE{Hostname=~"$hostname"})
                  seriesNameFormat: "{{Hostname}} / GPU {{gpu}}"
    temperature:
      kind: Panel
      spec:
        display:
          name: GPU temperature (°C)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
              mode: list
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: DCGM_FI_DEV_GPU_TEMP{Hostname=~"$hostname"}
                  seriesNameFormat: "{{Hostname}} / GPU {{gpu}}"
    power:
      kind: Panel
      spec:
        display:
          name: Power draw (W)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
              mode: list
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: DCGM_FI_DEV_POWER_USAGE{Hostname=~"$hostname"}
                  seriesNameFormat: "{{Hostname}} / GPU {{gpu}}"
    smClock:
      kind: Panel
      spec:
        display:
          name: SM clock (MHz)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
              mode: list
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: DCGM_FI_DEV_SM_CLOCK{Hostname=~"$hostname"}
                  seriesNameFormat: "{{Hostname}} / GPU {{gpu}}"
    tensorActive:
      kind: Panel
      spec:
        display:
          name: Tensor core active (%)
          description: Needs DCGM profiling metrics (DCGM_FI_PROF_PIPE_TENSOR_ACTIVE)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: bottom
              mode: list
            yAxis:
              format:
                unit: percent
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 100 * DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{Hostname=~"$hostname"}
                  seriesNameFormat: "{{Hostname}} / GPU {{gpu}}"
    podUtil:
      kind: Panel
      spec:
        display:
          name: GPU utilization by pod (%)
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: right
              mode: table
            yAxis:
              format:
                unit: percent
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: DCGM_FI_DEV_GPU_UTIL{Hostname=~"$hostname", exported_pod!=""}
                  seriesNameFormat: "{{exported_namespace}}/{{exported_pod}}"
    podMem:
      kind: Panel
      spec:
        display:
          name: GPU memory used by pod
        plugin:
          kind: TimeSeriesChart
          spec:
            legend:
              position: right
              mode: table
            yAxis:
              format:
                unit: bytes
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: DCGM_FI_DEV_FB_USED{Hostname=~"$hostname", exported_pod!=""} * 1048576
                  seriesNameFormat: "{{exported_namespace}}/{{exported_pod}}"
  layouts:
    - kind: Grid
      spec:
        display:
          title: Summary
          collapse:
            open: true
        items:
          - { x: 0,  y: 0, width: 6, height: 5, content: { $ref: "#/spec/panels/gpuCount" } }
          - { x: 6,  y: 0, width: 6, height: 5, content: { $ref: "#/spec/panels/avgUtil" } }
          - { x: 12, y: 0, width: 6, height: 5, content: { $ref: "#/spec/panels/fbUsedTotal" } }
          - { x: 18, y: 0, width: 6, height: 5, content: { $ref: "#/spec/panels/powerTotal" } }
          - { x: 0,  y: 5, width: 24, height: 7, content: { $ref: "#/spec/panels/gpuList" } }
    - kind: Grid
      spec:
        display:
          title: Per GPU
          collapse:
            open: true
        items:
          - { x: 0,  y: 0,  width: 12, height: 8, content: { $ref: "#/spec/panels/gpuUtil" } }
          - { x: 12, y: 0,  width: 12, height: 8, content: { $ref: "#/spec/panels/fbUsedPct" } }
          - { x: 0,  y: 8,  width: 12, height: 8, content: { $ref: "#/spec/panels/temperature" } }
          - { x: 12, y: 8,  width: 12, height: 8, content: { $ref: "#/spec/panels/power" } }
          - { x: 0,  y: 16, width: 12, height: 8, content: { $ref: "#/spec/panels/smClock" } }
          - { x: 12, y: 16, width: 12, height: 8, content: { $ref: "#/spec/panels/tensorActive" } }
    - kind: Grid
      spec:
        display:
          title: Workloads (which pod uses the GPU)
          collapse:
            open: true
        items:
          - { x: 0,  y: 0, width: 12, height: 9, content: { $ref: "#/spec/panels/podUtil" } }
          - { x: 12, y: 0, width: 12, height: 9, content: { $ref: "#/spec/panels/podMem" } }
EOF
}

rbac_manifest() {
    local verbs='["get", "list", "watch"]'
    [ "$EDITOR" = true ] && verbs='["get", "list", "watch", "create", "update", "patch", "delete"]'
cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: perses-dashboard-access
  namespace: ${NS}
rules:
  - apiGroups: ["perses.dev"]
    resources: ["persesdashboards", "persesdatasources"]
    verbs: ${verbs}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: perses-dashboard-access-${GROUP}
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: perses-dashboard-access
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${GROUP}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: view-${GROUP}
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${GROUP}
EOF
}

# Thanos Querier datasource. Perses has no built-in default: without one the
# panels show a datasource error and the Node variable stays empty.
# datasource_manifest <apiVersion> <kind> <name> [namespace]
# The operator creates the referenced secret from the service CA.
datasource_manifest() {
    local api="$1" kind="$2" name="$3" ns="${4:-}"
cat <<EOF
apiVersion: ${api}
kind: ${kind}
metadata:
  name: ${name}
$( [ -n "$ns" ] && echo "  namespace: ${ns}" )
spec:
  config:
    display:
      name: Thanos Querier
    default: true
    plugin:
      kind: PrometheusDatasource
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
            secret: ${name}-secret
  client:
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
EOF
}

if [ "$DRY_RUN" = true ]; then
    echo "# --- COO (applied only if not installed) ---"; coo_manifest
    echo "---"; uiplugin_manifest
    echo "---"; echo "# --- applied only if no PersesGlobalDatasource exists (namespaced PersesDatasource if the CRD is missing) ---"
    datasource_manifest perses.dev/v1alpha2 PersesGlobalDatasource thanos-querier-global-datasource
    echo "---"; printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$NS"
    echo "---"; dashboard_manifest
    if [ -n "$GROUP" ]; then echo "---"; rbac_manifest; fi
    exit 0
fi

echo "=============================================="
echo " Perses GPU dashboard (Cluster Observability Operator)"
echo "=============================================="
echo ""

if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if [ "$REMOVE" = true ]; then
    oc delete namespace "$NS" --ignore-not-found
    success "Done. Namespace ${NS} (dashboard) removed. COO, UIPlugin and global datasource kept."
    echo "  To remove the datasource: oc delete persesglobaldatasource thanos-querier-global-datasource"
    echo "  To disable Perses: oc patch uiplugin monitoring --type merge -p '{\"spec\":{\"monitoring\":{\"perses\":{\"enabled\":false}}}}'"
    exit 0
fi

wait_for() {  # wait_for <description> <timeout-sec> <command...>
    local desc="$1" timeout="$2"; shift 2
    local waited=0
    until "$@" &>/dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            return 1
        fi
        sleep 10; waited=$((waited + 10))
        info "Waiting for ${desc}... (${waited}s)"
    done
}

###############################################################################
# 1. Cluster Observability Operator
###############################################################################
coo_ready() {
    oc get csv -n "$COO_NS" --no-headers 2>/dev/null \
        | grep cluster-observability-operator | grep -q Succeeded
}
if coo_ready; then
    success "Cluster Observability Operator already installed: $(oc get csv -n "$COO_NS" --no-headers | awk '/cluster-observability-operator/{print $1}')"
else
    info "Installing Cluster Observability Operator (channel ${CHANNEL})"
    # Do not create a second OperatorGroup if one already exists in the namespace
    if oc get operatorgroup -n "$COO_NS" --no-headers 2>/dev/null | grep -q .; then
        coo_manifest | awk 'BEGIN{RS="---\n"; ORS="---\n"} !/kind: OperatorGroup/' | oc apply -f - >/dev/null
    else
        coo_manifest | oc apply -f - >/dev/null
    fi
    if ! wait_for "COO CSV" 600 coo_ready; then
        error "COO did not reach Succeeded in 10 min — check: oc get csv,subscription,installplan -n ${COO_NS}"
        exit 1
    fi
    success "Cluster Observability Operator installed"
fi

for crd in uiplugins.observability.openshift.io persesdashboards.perses.dev; do
    if ! wait_for "CRD ${crd}" 300 oc get crd "$crd"; then
        error "CRD ${crd} not found — this COO version may not ship Perses"
        exit 1
    fi
done
if ! oc get crd persesdashboards.perses.dev \
        -o jsonpath='{.spec.versions[?(@.served==true)].name}' | grep -qw v1alpha1; then
    error "persesdashboards.perses.dev does not serve v1alpha1 (served: $(oc get crd persesdashboards.perses.dev -o jsonpath='{.spec.versions[?(@.served==true)].name}'))"
    echo "  The dashboard manifest needs updating for this COO version."
    exit 1
fi

###############################################################################
# 2. UIPlugin monitoring with Perses
###############################################################################
if oc get uiplugin monitoring &>/dev/null; then
    oc patch uiplugin monitoring --type merge \
        -p '{"spec":{"monitoring":{"perses":{"enabled":true}}}}' >/dev/null
    info "UIPlugin monitoring patched (perses.enabled=true)"
else
    uiplugin_manifest | oc apply -f - >/dev/null
    info "UIPlugin monitoring created (perses.enabled=true)"
fi

perses_running() {
    oc get pods -n "$COO_NS" --no-headers 2>/dev/null | grep -i perses | grep -q Running
}
if wait_for "Perses pod in ${COO_NS}" 300 perses_running; then
    success "Perses is running"
else
    warn "No running Perses pod in ${COO_NS} after 5 min — check: oc get uiplugin monitoring -o yaml"
fi

###############################################################################
# 3. Datasource (Thanos Querier)
#    Prefer a cluster-wide PersesGlobalDatasource (all projects can use it);
#    fall back to a PersesDatasource in ${NS} if that CRD does not exist.
###############################################################################
oc get namespace "$NS" &>/dev/null || oc create namespace "$NS" >/dev/null

served_version() {  # newest served version of a CRD (v1alpha2 over v1alpha1)
    local v
    v=$(oc get crd "$1" -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null)
    if echo "$v" | grep -qw v1alpha2; then echo v1alpha2
    elif echo "$v" | grep -qw v1alpha1; then echo v1alpha1
    fi
}

GDS_VER=$(served_version persesglobaldatasources.perses.dev)
if [ -n "$GDS_VER" ]; then
    EXISTING=$(oc get persesglobaldatasources -o name 2>/dev/null | grep -v thanos-querier-global-datasource || true)
    if [ -n "$EXISTING" ]; then
        info "PersesGlobalDatasource already exists, not adding another: ${EXISTING//$'\n'/ }"
    else
        datasource_manifest "perses.dev/${GDS_VER}" PersesGlobalDatasource thanos-querier-global-datasource \
            | oc apply -f - >/dev/null
        success "PersesGlobalDatasource thanos-querier-global-datasource applied (${GDS_VER}, default)"
    fi
else
    DS_VER=$(served_version persesdatasources.perses.dev)
    if [ -z "$DS_VER" ]; then
        error "Neither persesglobaldatasources nor persesdatasources CRD found"
        exit 1
    fi
    datasource_manifest "perses.dev/${DS_VER}" PersesDatasource thanos-querier-datasource "$NS" \
        | oc apply -f - >/dev/null
    success "PersesDatasource ${NS}/thanos-querier-datasource applied (${DS_VER}, default)"
fi

###############################################################################
# 4. Dashboard
###############################################################################
dashboard_manifest | oc apply -f - >/dev/null
success "PersesDashboard ${NS}/${DASH} applied"

if [ -n "$GROUP" ]; then
    rbac_manifest | oc apply -f - >/dev/null
    if [ "$EDITOR" = true ]; then
        success "Group ${GROUP}: view namespace + edit Perses dashboards in ${NS}"
    else
        success "Group ${GROUP}: view namespace + Perses dashboards in ${NS}"
    fi
fi

###############################################################################
# DCGM metrics (warn only)
###############################################################################
if ! oc get namespace nvidia-gpu-operator &>/dev/null; then
    warn "nvidia-gpu-operator namespace not found — panels stay empty until the GPU operator is installed"
elif [ "$(oc get pods -n nvidia-gpu-operator -l app=nvidia-dcgm-exporter --no-headers 2>/dev/null | grep -c Running || true)" -eq 0 ]; then
    warn "No DCGM exporter pod running yet — graphs appear once GPU nodes are ready"
fi

echo ""
info "=== Perses resources in ${NS} ==="
oc get persesdashboards,persesdatasources -n "$NS" 2>/dev/null || true

CONSOLE=$(oc whoami --show-console 2>/dev/null || true)
echo ""
echo "=============================================="
success "Done. Console → Observe → Dashboards (Perses) → project '${NS}' → 'NVIDIA GPU Overview'"
[ -n "$CONSOLE" ] && echo "  ${CONSOLE}/monitoring/v2/dashboards  (menu path may differ by console version)"
echo "  Console may need a browser refresh after the UIPlugin is enabled."
echo "  Edit: dashboard → Edit, or oc edit persesdashboard ${DASH} -n ${NS}"
echo "=============================================="
