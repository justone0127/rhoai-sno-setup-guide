#!/bin/bash
###############################################################################
# rhoai-prepull-model-images.sh
#
# Pre-pull modelcar images onto every GPU node so the first model deployment
# skips the image download (~15GB for Gemma-4-E4B, ~5 min per node when the
# registry is not congested; 4-20 min observed with 30 nodes pulling at once).
#
# How: a DaemonSet runs on each GPU node (nvidia.com/gpu.present=true by
# default). Each image runs as a container doing 'sleep infinity' with tiny
# requests (no GPU), so the kubelet pulls it and keeps it from image garbage
# collection while the DaemonSet exists. New GPU nodes added later get the
# images automatically.
#
# Timing: per-node time = pod creation -> pod Ready (pod timestamps stay as long
# as the pod exists, so --status can report it any time, even after events
# have expired). Total time = DaemonSet creation -> last pod Ready.
# Requires 'jq' for the timing report (falls back to a plain pod list).
#
# Run as cluster-admin. Re-running is safe (oc apply).
#
# Usage:
#   bash rhoai-prepull-model-images.sh                     # Gemma-4-E4B, wait
#   bash rhoai-prepull-model-images.sh --expected-nodes 30 # wait for 30 nodes
#   bash rhoai-prepull-model-images.sh --image registry.redhat.io/rhai/modelcar-xxx:3.0 \
#                                      --image registry.redhat.io/rhai/modelcar-yyy:3.0
#   bash rhoai-prepull-model-images.sh --no-wait           # apply and exit
#   bash rhoai-prepull-model-images.sh --status            # progress + timing
#   bash rhoai-prepull-model-images.sh --dry-run           # print YAML only
#   bash rhoai-prepull-model-images.sh --remove            # delete (images stay
#                                                          # until kubelet GC)
#
# Options (default):
#   --image           registry.redhat.io/rhai/modelcar-redhatai-gemma-4-e4b-it:3.0
#   --node-selector   nvidia.com/gpu.present=true
#   --namespace       model-prepull
#   --expected-nodes  0 (do not finish waiting until the DaemonSet targets at
#                     least this many nodes; e.g. 30)
#   --timeout         3600 (seconds to wait for all nodes)
###############################################################################
set -euo pipefail

DEFAULT_IMAGE="registry.redhat.io/rhai/modelcar-redhatai-gemma-4-e4b-it:3.0"
IMAGES=()
NODE_SELECTOR="nvidia.com/gpu.present=true"
NAMESPACE="model-prepull"
NAME="model-image-prepull"
TIMEOUT=3600
EXPECTED_NODES=0
WAIT=true
DRY_RUN=false
MODE="apply"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)          IMAGES+=("$2"); shift 2 ;;
        --node-selector)  NODE_SELECTOR="$2"; shift 2 ;;
        --namespace)      NAMESPACE="$2"; shift 2 ;;
        --expected-nodes) EXPECTED_NODES="$2"; shift 2 ;;
        --timeout)        TIMEOUT="$2"; shift 2 ;;
        --no-wait)        WAIT=false; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --status)         MODE="status"; shift ;;
        --remove)         MODE="remove"; shift ;;
        --help|-h)        sed -n '3,43p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Builds one JSON row per pod: node, state, created, ready (epoch), pull time
# from 'Pulled' events (only while events still exist), restarts.
build_rows() {
    local PODS_JSON="$1" EVENTS_JSON="$2"
    jq -c --argjson ev "$EVENTS_JSON" '
      [ .items[]
        | . as $p
        | ($p.metadata.creationTimestamp | fromdateiso8601) as $c
        | ([($p.status.conditions // [])[]
            | select(.type == "Ready" and .status == "True")
            | .lastTransitionTime] | .[0]) as $r
        | ([($p.status.containerStatuses // [])[]
            | .state.waiting.reason // empty] | .[0]) as $w
        | ([ $ev.items[]
             | select(.reason == "Pulled" and .involvedObject.name == $p.metadata.name)
             | .message
             | capture("\\sin\\s(?<d>[0-9hms.]+)\\s\\(")
             | .d ] | join(",")) as $pull
        | { node: ($p.spec.nodeName // "-"),
            state: (if $r != null then "Ready" else ($w // $p.status.phase) end),
            created: $c,
            ready: (if $r != null then ($r | fromdateiso8601) else null end),
            pull: (if $pull == "" then "-" else $pull end),
            restarts: ([($p.status.containerStatuses // [])[] | .restartCount] | add // 0) }
      ]' <<<"$PODS_JSON"
}

JQ_FMT='def fmt(s): if s == null then "-" else
  (s | floor) as $t
  | (($t / 3600) | floor) as $h
  | ((($t % 3600) / 60) | floor) as $m
  | ($t % 60) as $x
  | (if $h > 0 then "\($h)h" else "" end) + "\($m)m\($x)s" end;'

print_timing() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found — showing plain pod list (install jq for timing report)"
        print_pods
        return 0
    fi
    local PODS EVENTS DS_CREATED ROWS N
    PODS=$(oc get pods -n "$NAMESPACE" -l app="$NAME" -o json 2>/dev/null || echo '{"items":[]}')
    EVENTS=$(oc get events -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
    DS_CREATED=$(oc get ds "$NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
    ROWS=$(build_rows "$PODS" "$EVENTS")
    N=$(jq 'length' <<<"$ROWS")
    if [ "$N" -eq 0 ]; then
        warn "No pre-pull pods found in ${NAMESPACE}"
        return 0
    fi

    echo ""
    echo "Per-node timing (times are local to this machine; '+' = still running)"
    {
        printf 'NODE\tSTATE\tPOD_CREATED\tREADY_AT\tELAPSED\tPULL(event)\tRESTARTS\n'
        jq -r "${JQ_FMT}"'
          now as $now
          | sort_by(.created) | .[]
          | (((if .ready != null then .ready else $now end) - .created)) as $e
          | [ .node, .state,
              (.created | strflocaltime("%H:%M:%S")),
              (if .ready != null then (.ready | strflocaltime("%H:%M:%S")) else "-" end),
              (fmt($e) + (if .ready != null then "" else "+" end)),
              .pull, .restarts ]
          | @tsv' <<<"$ROWS"
    } | { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }

    echo ""
    echo "Summary"
    jq -r --arg ds "$DS_CREATED" "${JQ_FMT}"'
      now as $now
      | length as $n
      | map(select(.ready != null)) as $done
      | ($done | map(.ready - .created)) as $d
      | (map(.created) | min) as $c0
      | (map(.created) | max) as $c1
      | ($done | map(.ready) | max) as $last
      | (if $ds == "" then $c0 else ($ds | fromdateiso8601) end) as $start
      | "  Nodes ready        : \($done | length)/\($n)",
        "  Pod creation spread: \(fmt($c1 - $c0))  (large = nodes joined/got labelled in waves)",
        (if ($d | length) > 0 then
           "  Per-node time      : min \(fmt($d | min)) / avg \(fmt(($d | add) / ($d | length))) / max \(fmt($d | max))"
         else empty end),
        (if ($done | length) == $n then
           "  Total elapsed      : \(fmt($last - $start))  (DaemonSet created -> last node Ready)"
         else
           "  Elapsed so far     : \(fmt($now - $start))  (not all nodes ready yet)"
         end),
        "  Total restarts     : \(map(.restarts) | add)"' <<<"$ROWS"
    echo ""
    echo "  Note: 'PULL(event)' comes from Kubernetes events, which expire after ~1h."
}

wait_ready() {
    local START=$SECONDS STATE DESIRED READY PENDING
    info "Waiting until every node has pulled the image(s) (timeout ${TIMEOUT}s)..."
    [ "$EXPECTED_NODES" -gt 0 ] && info "Will not finish until the DaemonSet targets >= ${EXPECTED_NODES} nodes."
    info "All nodes pull from the registry at once; with ~30 nodes expect roughly 5-20 min per node."
    while true; do
        STATE=$(show_status)
        READY=${STATE%/*}; DESIRED=${STATE#*/}
        PENDING=$(( DESIRED - READY ))
        echo -e "  [$(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s] ready nodes: ${STATE}  (not ready yet: ${PENDING})"
        if [ "$DESIRED" -gt 0 ] && [ "$READY" -eq "$DESIRED" ] && [ "$DESIRED" -ge "$EXPECTED_NODES" ]; then
            success "All ${DESIRED} node(s) have the image(s) (waited $(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s)"
            return 0
        fi
        if [ $(( SECONDS - START )) -ge "$TIMEOUT" ]; then
            warn "Timed out — check: oc get pods -n ${NAMESPACE} -o wide"
            return 1
        fi
        sleep 20
    done
}

if [ "$MODE" = "status" ]; then
    info "Ready nodes: $(show_status)"
    print_timing
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
if [ "$EXPECTED_NODES" -gt 0 ] && [ "$NODE_COUNT" -lt "$EXPECTED_NODES" ]; then
    warn "Only ${NODE_COUNT}/${EXPECTED_NODES} expected nodes match the selector right now"
fi
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
    print_timing
fi

echo ""
echo "=============================================="
success "Done."
echo "  Progress : bash $0 --status   (per-node timing + total)"
echo "  Remove   : bash $0 --remove   (keep it during the workshop so images are not GC'd)"
echo "=============================================="
