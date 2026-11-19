#!/usr/bin/env bash
#
# ROLE: cluster admin               RUN ORDER: cleanup, 1 of 2
#
# Order is the whole point of this script. Deleting BGPCloudConfiguration is what makes the
# operator remove its AWS Route Server peers and re-enable SourceDestCheck on the worker
# ENIs. Remove the Subscription first and OLM kills the controller mid-finalizer, leaving
# orphaned peers and — worse — source/destination check disabled on production workers,
# which nobody will notice.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ASSUME_YES="${ASSUME_YES:-false}"; DRY_RUN="${DRY_RUN:-false}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) echo "Usage: 90-cleanup-cluster.sh [--dry-run] [--yes]"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

load_config
require_oc_login
[ -f "$HANDBACK_FILE" ] && . "$HANDBACK_FILE"

confirm "Delete the demo VM, CUDN, BGP configuration and the operator from this cluster?" \
  || fail "aborted"

# ---- 1. workload first, so the CUDN is unused before the network config goes ----------
step "Workload"
run oc delete vm "$VM_NAME" -n "$DEMO_NAMESPACE" --ignore-not-found
run oc delete bgprouting "$BGPROUTING_NAME" --ignore-not-found
run oc delete namespace "$DEMO_NAMESPACE" --ignore-not-found

# ---- 2. BGP config, then WAIT for the finalizer to finish its AWS cleanup -------------
step "BGP configuration"
run oc delete bgpcloudconfiguration cluster --ignore-not-found

if [ "$DRY_RUN" != "true" ]; then
  info "waiting for the finalizer to complete its AWS cleanup"
  # `|| true` because oc wait errors when the object is already gone, which is success here.
  oc wait --for=delete bgpcloudconfiguration/cluster --timeout=180s || true
  if oc get bgpcloudconfiguration cluster >/dev/null 2>&1; then
    fail "BGPCloudConfiguration still exists after 180s — do NOT remove the operator yet.
    Check: oc logs -n $OPERATOR_NS deploy/openshift-bgp-cloud-connector-controller-manager"
  fi
  ok "finalizer completed"
fi

# ---- 3. opportunistic AWS verification, if this operator happens to have credentials --
if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 \
   && [ -n "${RS_ID:-}" ]; then
  step "AWS state after the finalizer"
  rs_peer_table "$RS_ID" || true
  if [ -n "${INSTANCE_IDS:-}" ]; then
    # Expect True everywhere. False means the operator did not get to re-enable it.
    # shellcheck disable=SC2086
    aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
      --query 'Reservations[].Instances[].[InstanceId,SourceDestCheck]' --output table || true
  fi
else
  warn "no AWS credentials here — have the AWS owner confirm peers are gone and"
  warn "SourceDestCheck is back to True before considering this finished (script 91 does it)"
fi

# ---- 4. only now remove the operator --------------------------------------------------
step "Operator"
run oc delete subscription "$OPERATOR_PKG" -n "$OPERATOR_NS" --ignore-not-found
run oc delete csv -n "$OPERATOR_NS" --all --ignore-not-found

step "Done"
cat <<EOF

  Cluster side is clean.

  Note: FRR stays enabled on the cluster network. Reverting that patches
  Network.operator.openshift.io/cluster again and triggers another rollout — leave it
  alone on a shared cluster.

  Now have the AWS owner run:  ./91-cleanup-aws.sh
  (That is what actually stops the hourly Route Server endpoint charges.)

EOF
