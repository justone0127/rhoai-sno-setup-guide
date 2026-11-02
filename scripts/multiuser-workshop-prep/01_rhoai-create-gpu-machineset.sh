#!/bin/bash
###############################################################################
# rhoai-create-gpu-machineset.sh
#
# Create a GPU MachineSet (default: g6.xlarge = 1 x NVIDIA L4, 4 vCPU, 16GiB)
# by copying an existing worker MachineSet on AWS
# (e.g. ocp-94h2l-worker-us-east-2a-compute).
#
# Copied from the source: AMI, subnet/AZ, security groups, IAM profile, tags,
# user-data secret. Changed: name, replicas, instance type, selector labels.
# Capacity annotations (vCPU/memory/GPU) are dropped — the machine-api
# controller fills them in for the new instance type.
#
# Run as cluster-admin. Requires python3 on the machine running the script.
#
# Usage:
#   bash rhoai-create-gpu-machineset.sh --name <name> --replicas <n>
#   bash rhoai-create-gpu-machineset.sh --name gpu-l4 --replicas 16
#   bash rhoai-create-gpu-machineset.sh --name gpu-l4 --replicas 2 \
#        --source ocp-94h2l-worker-us-east-2a-compute --instance-type g6.2xlarge
#   bash rhoai-create-gpu-machineset.sh --name gpu-l4 --replicas 16 --dry-run
#   bash rhoai-create-gpu-machineset.sh --name gpu-l4 --replicas 16 --wait
#
# Options (default):
#   --name           (required) new MachineSet name. A name without the cluster
#                    infra ID gets it prefixed, e.g. gpu-l4 → ocp-94h2l-gpu-l4
#   --replicas       (required) number of nodes
#   --source         auto: first worker MachineSet that is not a GPU instance
#   --instance-type  g6.xlarge
#   --volume-size    keep source value (GiB)
#   --wait           wait until all new nodes are Ready (timeout 30 min)
#   --dry-run        print YAML only
#
# Note: AWS limits G/VT instances by vCPU quota per account (often 64 vCPU).
# g6.xlarge uses 4 vCPU → 16 instances max at 64. Machines over the quota stay
# in 'Failed' with VcpuLimitExceeded.
###############################################################################
set -euo pipefail

NAME=""
REPLICAS=""
SOURCE=""
INSTANCE_TYPE="g6.xlarge"
VOLUME_SIZE=""
WAIT=false
DRY_RUN=false
NS="openshift-machine-api"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           NAME="$2"; shift 2 ;;
        --replicas)       REPLICAS="$2"; shift 2 ;;
        --source)         SOURCE="$2"; shift 2 ;;
        --instance-type)  INSTANCE_TYPE="$2"; shift 2 ;;
        --volume-size)    VOLUME_SIZE="$2"; shift 2 ;;
        --wait)           WAIT=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --help|-h)        sed -n '3,40p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " OpenShift — Create GPU MachineSet (${INSTANCE_TYPE})"
echo "=============================================="
echo ""

if [ -z "$NAME" ] || [ -z "$REPLICAS" ]; then
    error "--name and --replicas are required"
    echo "  e.g. bash $0 --name gpu-l4 --replicas 16"
    exit 1
fi
if ! [[ "$REPLICAS" =~ ^[0-9]+$ ]]; then
    error "--replicas must be a number: ${REPLICAS}"
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    error "python3 is required"
    exit 1
fi
if ! oc whoami &>/dev/null; then
    error "oc login required (cluster-admin)"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || true)
if [ "$PLATFORM" != "AWS" ]; then
    error "This script supports AWS only (platform: ${PLATFORM:-unknown})"
    exit 1
fi
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')

# Prefix the infra ID so the name follows the cluster convention
if [[ "$NAME" != "${INFRA_ID}-"* ]]; then
    NAME="${INFRA_ID}-${NAME}"
fi
info "Infra ID:      ${INFRA_ID}"
info "New name:      ${NAME}"

###############################################################################
# Existing MachineSets
###############################################################################
echo ""
info "=== Existing MachineSets ==="
oc get machineset -n "$NS" \
    -o custom-columns='NAME:.metadata.name,TYPE:.spec.template.spec.providerSpec.value.instanceType,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
    | sed 's/^/  /'
echo ""

if oc get machineset "$NAME" -n "$NS" &>/dev/null; then
    error "MachineSet ${NAME} already exists — choose another --name, or scale it:"
    echo "  oc scale machineset ${NAME} -n ${NS} --replicas=${REPLICAS}"
    exit 1
fi

if [ -z "$SOURCE" ]; then
    # First worker MachineSet whose instance type is not a GPU family (g*, p*)
    SOURCE=$(oc get machineset -n "$NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.providerSpec.value.instanceType}{"\n"}{end}' \
        | awk '$1 ~ /worker/ && $2 !~ /^(g|p)[0-9]/ {print $1; exit}')
    if [ -z "$SOURCE" ]; then
        error "No non-GPU worker MachineSet found — pass --source <name>"
        exit 1
    fi
fi
if ! oc get machineset "$SOURCE" -n "$NS" &>/dev/null; then
    error "Source MachineSet not found: ${SOURCE}"
    exit 1
fi
SRC_TYPE=$(oc get machineset "$SOURCE" -n "$NS" -o jsonpath='{.spec.template.spec.providerSpec.value.instanceType}')
SRC_AZ=$(oc get machineset "$SOURCE" -n "$NS" -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}')
info "Source:        ${SOURCE} (${SRC_TYPE}, ${SRC_AZ})"
info "Instance type: ${INSTANCE_TYPE}"
info "Replicas:      ${REPLICAS}"

###############################################################################
# vCPU quota hint (G/VT family shares one quota per region)
###############################################################################
vcpu_of() {
    case "$1" in
        *.xlarge) echo 4 ;; *.2xlarge) echo 8 ;; *.4xlarge) echo 16 ;;
        *.8xlarge) echo 32 ;; *.12xlarge) echo 48 ;; *.16xlarge) echo 64 ;;
        *.24xlarge) echo 96 ;; *.48xlarge) echo 192 ;; *) echo 0 ;;
    esac
}
if [[ "$INSTANCE_TYPE" =~ ^g[0-9] ]]; then
    NEW_VCPU=$(( $(vcpu_of "$INSTANCE_TYPE") * REPLICAS ))
    EXISTING_VCPU=0
    while read -r MS TYPE REP; do
        [[ "$TYPE" =~ ^g[0-9] ]] || continue
        EXISTING_VCPU=$(( EXISTING_VCPU + $(vcpu_of "$TYPE") * ${REP:-0} ))
    done < <(oc get machineset -n "$NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.providerSpec.value.instanceType}{" "}{.spec.replicas}{"\n"}{end}')
    TOTAL_VCPU=$(( NEW_VCPU + EXISTING_VCPU ))
    info "G-family vCPU: new ${NEW_VCPU} + existing ${EXISTING_VCPU} = ${TOTAL_VCPU}"
    if [ "$TOTAL_VCPU" -gt 64 ]; then
        warn "Over 64 vCPU — if the AWS account quota is 64, some Machines will fail (VcpuLimitExceeded)."
        warn "Scale other GPU MachineSets to 0 first, or lower --replicas."
    fi
fi
echo ""

###############################################################################
# Build the new MachineSet from the source
###############################################################################
MANIFEST=$(oc get machineset "$SOURCE" -n "$NS" -o json | \
    NAME="$NAME" REPLICAS="$REPLICAS" INSTANCE_TYPE="$INSTANCE_TYPE" VOLUME_SIZE="$VOLUME_SIZE" \
    python3 -c '
import json, os, sys
ms = json.load(sys.stdin)
name = os.environ["NAME"]
md = ms["metadata"]
for k in ("uid", "resourceVersion", "creationTimestamp", "generation", "managedFields", "ownerReferences"):
    md.pop(k, None)
# capacity annotations are recomputed by the controller for the new type
md["annotations"] = {k: v for k, v in (md.get("annotations") or {}).items()
                     if not k.startswith("machine.openshift.io/") and "last-applied" not in k}
if not md["annotations"]:
    md.pop("annotations")
md["name"] = name
ms.pop("status", None)

spec = ms["spec"]
spec["replicas"] = int(os.environ["REPLICAS"])
spec["selector"]["matchLabels"]["machine.openshift.io/cluster-api-machineset"] = name
tmpl = spec["template"]
tmpl["metadata"]["labels"]["machine.openshift.io/cluster-api-machineset"] = name
tmpl["metadata"]["labels"]["machine.openshift.io/cluster-api-machine-type"] = "worker"
tmpl["metadata"]["labels"]["machine.openshift.io/cluster-api-machine-role"] = "worker"

pv = tmpl["spec"]["providerSpec"]["value"]
pv["instanceType"] = os.environ["INSTANCE_TYPE"]
vol = os.environ.get("VOLUME_SIZE")
if vol:
    for bd in pv.get("blockDevices", []):
        if "ebs" in bd:
            bd["ebs"]["volumeSize"] = int(vol)
            break
print(json.dumps(ms, indent=2))
')

if [ "$DRY_RUN" = true ]; then
    info "Dry run — manifest (JSON):"
    echo "$MANIFEST"
    echo ""
    info "Server-side validation:"
    echo "$MANIFEST" | oc apply --dry-run=server -f -
    exit 0
fi

echo "$MANIFEST" | oc apply -f -
success "MachineSet ${NAME} created (${REPLICAS} x ${INSTANCE_TYPE})"
echo ""

###############################################################################
# Wait / status
###############################################################################
show_machines() {
    oc get machine -n "$NS" -l "machine.openshift.io/cluster-api-machineset=${NAME}" \
        -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,TYPE:.spec.providerSpec.value.instanceType,NODE:.status.nodeRef.name' \
        2>/dev/null | sed 's/^/  /'
}

if [ "$WAIT" = true ] && [ "$REPLICAS" -gt 0 ]; then
    info "Waiting for ${REPLICAS} node(s) to become Ready (timeout 30 min)..."
    START=$SECONDS
    while true; do
        READY=$(oc get machineset "$NAME" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
        FAILED=$(oc get machine -n "$NS" -l "machine.openshift.io/cluster-api-machineset=${NAME}" \
            -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Failed || true)
        echo "  [$(( (SECONDS - START) / 60 ))m$(( (SECONDS - START) % 60 ))s] ready: ${READY:-0}/${REPLICAS}  failed: ${FAILED}"
        if [ "${READY:-0}" -ge "$REPLICAS" ]; then
            success "All ${REPLICAS} node(s) Ready"
            break
        fi
        if [ "$FAILED" -gt 0 ]; then
            warn "Some Machines failed — reason:"
            oc get machine -n "$NS" -l "machine.openshift.io/cluster-api-machineset=${NAME}" \
                -o jsonpath='{range .items[?(@.status.phase=="Failed")]}  {.metadata.name}: {.status.errorMessage}{"\n"}{end}'
            break
        fi
        if [ $(( SECONDS - START )) -ge 1800 ]; then
            warn "Timed out"
            break
        fi
        sleep 30
    done
    echo ""
fi

info "=== Machines of ${NAME} ==="
show_machines

echo ""
echo "=============================================="
success "Done."
echo "  Watch   : oc get machine -n ${NS} -l machine.openshift.io/cluster-api-machineset=${NAME} -w"
echo "  Scale   : oc scale machineset ${NAME} -n ${NS} --replicas=<n>"
echo "  Delete  : oc scale machineset ${NAME} -n ${NS} --replicas=0 && oc delete machineset ${NAME} -n ${NS}"
echo "  GPU labels (nvidia.com/gpu.product) appear a few minutes after the node is Ready"
echo "  (NFD + GPU Operator must be installed)."
echo "=============================================="
