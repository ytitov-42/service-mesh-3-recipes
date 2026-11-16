#!/usr/bin/env bash
#
# ROLE: cluster admin (oc)          RUN ORDER: 1 of 3
#
# Validates the cluster, labels the BGP router nodes, and writes state/handoff.env for the
# AWS owner. Nothing is created in AWS here and nothing is installed on the cluster — this
# step is deliberately safe to re-run.
#
# Why this runs first: step 2.1 of the runbook discovers VPC subnets from the router node
# labels, so the labels must exist before anyone touches AWS.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: 01-cluster-prepare.sh [options]

  --nodes "<node-a> <node-b>"  Label these nodes instead of auto-selecting one per AZ
  --dry-run                    Print what would change, change nothing
  --yes                        Do not prompt
  -h, --help                   This text
USAGE
}

NODES_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --nodes) NODES_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
DRY_RUN="${DRY_RUN:-false}"; ASSUME_YES="${ASSUME_YES:-false}"

load_config
require_cmd oc awk
require_oc_login

# ---------------------------------------------------------------------------- platform
step "Cluster preflight"

PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
[ "$PLATFORM" = "AWS" ] || fail_ref "platform is $PLATFORM, expected AWS" "Section 1"
ok "platform: AWS"

INFRA_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
info "infrastructure name: $INFRA_NAME"

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
info "OpenShift version: $OCP_VERSION"
# The operator's file-based catalogs ship for 4.22 and 5.0 only. On 4.21 the package is
# simply absent from OperatorHub, which is confusing if you only know the code supports it.
case "$OCP_VERSION" in
  4.2[2-9]*|4.[3-9]*|5.*) ok "version supports the operator catalog" ;;
  *) warn "the operator catalog ships for 4.22+/5.0 — expect the package to be missing here" ;;
esac

# ---------------------------------------------------------------------------- CNV
if oc get csv -n openshift-cnv 2>/dev/null | grep -qi kubevirt; then
  ok "OpenShift Virtualization present"
else
  warn "OpenShift Virtualization not detected in openshift-cnv — script 03 cannot create a VM"
fi

# ---------------------------------------------------------------------------- addressing
step "Address plan"

POD_CIDRS=$(oc get network.config/cluster -o jsonpath='{.spec.clusterNetwork[*].cidr}')
SVC_CIDRS=$(oc get network.config/cluster -o jsonpath='{.spec.serviceNetwork[*]}')
info "CUDN    : $CUDN_CIDR"
info "pod     : $POD_CIDRS"
info "service : $SVC_CIDRS"

# An overlap does not fail at apply time — it fails later as unexplained traffic loss, so it
# is worth refusing to continue rather than warning.
for c in $POD_CIDRS $SVC_CIDRS; do
  if cidr_overlap "$CUDN_CIDR" "$c"; then
    fail_ref "CUDN_CIDR $CUDN_CIDR overlaps the cluster range $c" "VPC and address design"
  fi
done
ok "no overlap with pod or service networks (VPC CIDR is checked in script 02)"

# ---------------------------------------------------------------------------- router nodes
step "Selecting BGP router nodes"

LABEL="${ROUTER_NODE_LABEL_KEY}=${ROUTER_NODE_LABEL_VALUE}"

if [ -n "$NODES_OVERRIDE" ]; then
  SELECTED="$NODES_OVERRIDE"
  info "using nodes given on the command line"
else
  # Prefer bare-metal nodes: CNV on ROSA needs them, and co-locating the router role keeps
  # the demo's moving parts on the same pool. One per AZ — a second node in the same zone
  # peers with the same Route Server endpoint and adds cost without adding resilience.
  SELECTED=$(oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.topology\.kubernetes\.io/zone}{"\t"}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' \
    | awk -F'\t' '$3 ~ /metal/ && !seen[$2]++ {print $1}')
  [ -n "$SELECTED" ] || warn "no bare-metal workers found; falling back to any worker"
  if [ -z "$SELECTED" ]; then
    SELECTED=$(oc get nodes -l node-role.kubernetes.io/worker \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' \
      | awk -F'\t' '!seen[$2]++ {print $1}')
  fi
fi

[ -n "$SELECTED" ] || fail "could not select any router nodes"
info "candidates:"; for n in $SELECTED; do info "  - $n"; done

if confirm "Label these nodes with $LABEL ?"; then
  for n in $SELECTED; do run oc label node "$n" "$LABEL" --overwrite; done
else
  info "skipped labelling"
fi

LABELLED=$(oc get nodes -l "$LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)
[ -n "$LABELLED" ] || [ "$DRY_RUN" = "true" ] || fail "no nodes carry $LABEL"

ZONES=$(oc get nodes -l "$LABEL" -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | sort -u | tr '\n' ' ')
ZONE_COUNT=$(printf '%s' "$ZONES" | wc -w)
info "router zones: $ZONES"
# Below two AZs there is no failover to demonstrate — beat 6 of the demo has nowhere to go.
[ "$ZONE_COUNT" -ge 2 ] || warn "only $ZONE_COUNT AZ — the failover demo will have no surviving peer"

# ---------------------------------------------------------------------------- handoff data
step "Collecting values for the AWS owner"

# providerID is the only field on a Node that records its EC2 instance ID — the join key
# between the cluster view and the AWS view.
INSTANCE_IDS=$(oc get nodes -l "$LABEL" \
  -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | awk -F/ '{print $NF}' | tr '\n' ' ')
info "instance IDs: $INSTANCE_IDS"

# The OIDC issuer ties the IAM role to this specific cluster. Try the rosa CLI, then fall
# back to the cluster itself — the AWS owner frequently has neither, which is why we collect
# it here rather than there.
OIDC=""
if command -v rosa >/dev/null 2>&1; then
  OIDC=$(rosa describe cluster -c "$CLUSTER_NAME" -o json 2>/dev/null \
    | jq -r '.aws.sts.oidc_endpoint_url // empty' 2>/dev/null | sed 's|^https://||' || true)
fi
if [ -z "$OIDC" ]; then
  OIDC=$(oc get authentication.config/cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
  info "OIDC taken from the cluster (rosa CLI unavailable or not logged in)"
fi
[ -n "$OIDC" ] || fail "could not determine the OIDC issuer — the IAM trust policy cannot be built without it"
info "OIDC issuer: $OIDC"

# The ServiceAccount the operator will run as. Passed along so the AWS owner can build the
# trust policy `sub` correctly; a mismatch here is the top cause of CloudCredentialsInvalid.
SA_NAME="openshift-bgp-cloud-connector-controller-manager"

if [ "$DRY_RUN" != "true" ]; then
  : > "$HANDOFF_FILE"
  save_var "$HANDOFF_FILE" REGION          "$REGION"
  save_var "$HANDOFF_FILE" CLUSTER_NAME    "$CLUSTER_NAME"
  save_var "$HANDOFF_FILE" INFRA_NAME      "$INFRA_NAME"
  save_var "$HANDOFF_FILE" CUDN_CIDR       "$CUDN_CIDR"
  save_var "$HANDOFF_FILE" AMAZON_ASN      "$AMAZON_ASN"
  save_var "$HANDOFF_FILE" CLUSTER_ASN     "$CLUSTER_ASN"
  save_var "$HANDOFF_FILE" INSTANCE_IDS    "$INSTANCE_IDS"
  save_var "$HANDOFF_FILE" OIDC            "$OIDC"
  save_var "$HANDOFF_FILE" OPERATOR_NS     "$OPERATOR_NS"
  save_var "$HANDOFF_FILE" OPERATOR_SA     "$SA_NAME"
  save_var "$HANDOFF_FILE" LIVENESS_DETECTION "$LIVENESS_DETECTION"
fi

step "Done"
cat <<EOF

  Send these two files to whoever owns the AWS account:

      $SCRIPT_DIR/config.env
      $HANDOFF_FILE

  They run:   ./02-aws-setup.sh
  They return: state/handback.env

  Then you run: ./03-cluster-deploy.sh

EOF
