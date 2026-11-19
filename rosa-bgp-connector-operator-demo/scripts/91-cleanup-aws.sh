#!/usr/bin/env bash
#
# ROLE: AWS account owner           RUN ORDER: cleanup, 2 of 2
#
# Run AFTER 90-cleanup-cluster.sh. Removes the Route Server, its endpoints and the IAM role,
# and repairs SourceDestCheck if the operator was torn down before its finalizer completed.
#
# This is the script that actually stops the hourly endpoint charges.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ASSUME_YES="${ASSUME_YES:-false}"; DRY_RUN="${DRY_RUN:-false}"
KEEP_ROLE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-role) KEEP_ROLE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) echo "Usage: 91-cleanup-aws.sh [--keep-role] [--dry-run] [--yes]"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

load_config
load_state "$HANDBACK_FILE" "handback file (needed for RS_ID and instance IDs)"
require_aws

[ -n "${RS_ID:-}" ] || fail "no RS_ID in handback.env — nothing to clean up, or wrong directory"
info "Route Server: $RS_ID"

confirm "Delete Route Server $RS_ID, its endpoints, and the IAM role $IAM_ROLE_NAME?" || fail "aborted"

# ---- source/destination check ---------------------------------------------------------
# Do this first and unconditionally. Leaving it disabled is the one genuinely security-
# relevant leftover: those workers would keep forwarding traffic for addresses they do not
# own, long after the demo is forgotten.
if [ -n "${INSTANCE_IDS:-}" ]; then
  step "Restoring source/destination check"
  # shellcheck disable=SC2086
  aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
    --query 'Reservations[].Instances[].[InstanceId,SourceDestCheck]' --output table || true

  # shellcheck disable=SC2086
  for ENI in $(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
      --query 'Reservations[].Instances[].NetworkInterfaces[].NetworkInterfaceId' \
      --output text 2>/dev/null | tr '\t' '\n'); do
    # Every interface, not just the primary — the operator disables the check per ENI.
    run aws ec2 modify-network-interface-attribute --region "$REGION" \
      --network-interface-id "$ENI" --source-dest-check "Value=true"
  done
  ok "source/destination check re-enabled on all router node ENIs"
fi

# ---- peers, then endpoints, then the server -------------------------------------------
step "Route Server peers"
# Normally the operator removed these already; this catches anything stranded by a
# controller that was killed mid-finalizer. An endpoint with a live peer will not delete.
# Do not use --filters Name=route-server-id: the API rejects it. See rs_* in common.sh.
PEERS=$(rs_peer_ids "$RS_ID")
if [ -z "$PEERS" ]; then
  ok "no peers left (the operator cleaned up properly)"
else
  for P in $PEERS; do
    info "deleting peer $P"
    run aws ec2 delete-route-server-peer --region "$REGION" --route-server-peer-id "$P" >/dev/null
  done
  [ "$DRY_RUN" = "true" ] || sleep 30   # peers take a moment to clear before endpoints go
fi

step "Route Server endpoints (this stops the hourly charge)"
EPS=$(rs_endpoint_ids "$RS_ID")
for E in $EPS; do
  [ -z "$E" ] && continue
  info "deleting endpoint $E"
  run aws ec2 delete-route-server-endpoint --region "$REGION" --route-server-endpoint-id "$E" >/dev/null
done
if [ "$DRY_RUN" != "true" ]; then
  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    LEFT=$(rs_endpoint_ids "$RS_ID")
    [ -z "$LEFT" ] && break
    info "waiting for endpoints to finish deleting"
    sleep "$WAIT_INTERVAL"
  done
  [ -z "$(rs_endpoint_ids "$RS_ID")" ] \
    || fail "Route Server endpoints still present — wait and re-run, or delete them in the console"
fi

# Propagation must be cleared before disassociate, or AWS returns IncorrectState:
# "Route Server has non-deleted propagation to Route Table: rtb-…"
step "Disable route table propagation"
PROP_RTBS=$(aws ec2 get-route-server-propagations --region "$REGION" \
  --route-server-id "$RS_ID" \
  --query 'RouteServerPropagations[].RouteTableId' --output text 2>/dev/null \
  | tr '\t' '\n' | sed '/^$/d' | sort -u || true)
# Fall back to handback if the API returns nothing mid-delete but tables are still listed.
[ -n "$PROP_RTBS" ] || PROP_RTBS="${ROUTE_TABLES:-}"
if [ -z "$PROP_RTBS" ]; then
  ok "no route table propagations to disable"
else
  for RTB in $PROP_RTBS; do
    [ -z "$RTB" ] && continue
    info "disabling propagation on $RTB"
    tolerate 'not found|does not exist|InvalidRouteServer|InvalidRouteTable' \
      aws ec2 disable-route-server-propagation --region "$REGION" \
        --route-server-id "$RS_ID" --route-table-id "$RTB" >/dev/null
  done
  if [ "$DRY_RUN" != "true" ]; then
    # States are pending|available|deleting — there is no "deleted"; they vanish when gone.
    for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
      LEFT=$(aws ec2 get-route-server-propagations --region "$REGION" \
        --route-server-id "$RS_ID" \
        --query 'length(RouteServerPropagations)' --output text 2>/dev/null || echo 0)
      [ "${LEFT:-0}" = "0" ] || [ "$LEFT" = "None" ] && break
      info "waiting for propagations to clear ($LEFT left)"
      sleep "$WAIT_INTERVAL"
    done
    LEFT=$(aws ec2 get-route-server-propagations --region "$REGION" \
      --route-server-id "$RS_ID" \
      --query 'length(RouteServerPropagations)' --output text 2>/dev/null || echo 0)
    [ "${LEFT:-0}" = "0" ] || [ "$LEFT" = "None" ] \
      || fail "route table propagations still present after wait — re-run 91 once AWS finishes deleting"
  fi
  ok "propagation disabled"
fi

step "Disassociate and delete the Route Server"
RS_STATE=$(aws ec2 describe-route-servers --region "$REGION" --route-server-ids "$RS_ID" \
  --query 'RouteServers[0].State' --output text 2>/dev/null || echo missing)
case "$RS_STATE" in
  deleted|missing|None)
    ok "Route Server already gone (state=$RS_STATE)"
    ;;
  deleting)
    ok "Route Server already deleting — nothing to do"
    ;;
  *)
    # Still associated with a VPC will not delete; order matters here too.
    tolerate 'not associated|InvalidRouteServer|does not exist|IncorrectState' \
      aws ec2 disassociate-route-server --region "$REGION" --route-server-id "$RS_ID" --vpc-id "$VPC_ID" >/dev/null
    [ "$DRY_RUN" = "true" ] || sleep 15
    # Re-runs often hit IncorrectState while AWS is still finishing disassociate/delete.
    tolerate 'InvalidRouteServer|does not exist|has dependencies|IncorrectState|invalid state' \
      aws ec2 delete-route-server --region "$REGION" --route-server-id "$RS_ID" >/dev/null
    if [ "$DRY_RUN" != "true" ]; then
      for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
        RS_STATE=$(aws ec2 describe-route-servers --region "$REGION" --route-server-ids "$RS_ID" \
          --query 'RouteServers[0].State' --output text 2>/dev/null || echo missing)
        case "$RS_STATE" in deleted|missing|None|deleting) break ;; esac
        info "waiting for Route Server delete (state=$RS_STATE)"
        sleep "$WAIT_INTERVAL"
      done
    fi
    ok "Route Server removed (verify below)"
    ;;
esac

# ---- IAM -------------------------------------------------------------------------------
if [ "$KEEP_ROLE" = "true" ]; then
  info "keeping IAM role $IAM_ROLE_NAME (--keep-role)"
else
  step "IAM role"
  # Inline policies must go first — IAM refuses to delete a role that still has them.
  tolerate 'NoSuchEntity' \
    aws iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name bgp-cloud-connector >/dev/null
  tolerate 'NoSuchEntity|DeleteConflict' \
    aws iam delete-role --role-name "$IAM_ROLE_NAME" >/dev/null
  ok "IAM role removed"
fi

# ---- test client ------------------------------------------------------------------------
if [ -n "${TEST_CLIENT_ID:-}" ]; then
  step "Test client"
  if confirm "Terminate the test EC2 instance $TEST_CLIENT_ID?"; then
    run aws ec2 terminate-instances --region "$REGION" --instance-ids "$TEST_CLIENT_ID" >/dev/null
    ok "terminating $TEST_CLIENT_ID"
  fi
fi

step "Verify nothing is left billing"
# describe can still return recently deleted servers; ignore those.
aws ec2 describe-route-servers --region "$REGION" \
  --filters "Name=tag:Name,Values=$RS_NAME_TAG" \
  --query 'RouteServers[?State!=`deleted`].[RouteServerId,State]' --output table || true

cat <<EOF

  Security group rules added by script 02 were left in place — they are scoped to the VPC
  CIDR and harmless, but remove them from $WORKER_SGS if this was a shared cluster.

  If you added a Transit Gateway static route or a Direct Connect allowed prefix for
  $CUDN_CIDR, remove those too. Neither was created by these scripts, so neither is
  removed here.

EOF
