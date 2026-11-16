#!/usr/bin/env bash
#
# ROLE: AWS account owner (aws cli, EC2 + IAM write)        RUN ORDER: 2 of 3
#
# Consumes state/handoff.env from the cluster admin and builds the AWS side: Route Server,
# endpoints, route propagation, security group rules and the IAM role the operator assumes.
# Writes state/handback.env to send back.
#
# You do NOT need oc, the rosa CLI, or cluster access — the cluster-side values you need
# were collected for you in script 01.
#
# Every create is idempotent: re-running adopts what already exists rather than duplicating.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: 02-aws-setup.sh [options]

  --with-test-client   Also launch a small EC2 instance to test from (SSM-managed)
  --with-ephemeral     Add the ephemeral-port ingress rules for asymmetric return traffic
  --dry-run            Print what would change, change nothing
  --yes                Do not prompt
  -h, --help           This text
USAGE
}

WITH_TEST_CLIENT=false; WITH_EPHEMERAL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --with-test-client) WITH_TEST_CLIENT=true; shift ;;
    --with-ephemeral)   WITH_EPHEMERAL=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
DRY_RUN="${DRY_RUN:-false}"; ASSUME_YES="${ASSUME_YES:-false}"

load_config
load_state "$HANDOFF_FILE" "handoff file from the cluster admin"
require_cmd aws
require_aws

[ -n "${INSTANCE_IDS:-}" ] || fail "handoff.env has no INSTANCE_IDS — re-run script 01"
[ -n "${OIDC:-}" ]         || fail "handoff.env has no OIDC — re-run script 01"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
info "AWS account: $ACCOUNT   region: $REGION"

# ---------------------------------------------------------------------------- discovery
step "Discovering VPC, subnets and security groups from the router nodes"

# shellcheck disable=SC2086
aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].[InstanceId,SubnetId,VpcId,SecurityGroups[0].GroupId,Placement.AvailabilityZone]' \
  --output table

# shellcheck disable=SC2086
ROUTER_SUBNETS=$(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].SubnetId' --output text | tr '\t' '\n' | sort -u | tr '\n' ' ')
# shellcheck disable=SC2086
VPC_ID=$(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[0].Instances[0].VpcId' --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text)

# All router nodes' groups, not just the first — if they differ, rules applied to one group
# leave the other nodes' BGP sessions permanently down.
# shellcheck disable=SC2086
WORKER_SGS=$(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort -u | tr '\n' ' ')

info "VPC      : $VPC_ID ($VPC_CIDR)"
info "subnets  : $ROUTER_SUBNETS"
info "sec grps : $WORKER_SGS"
[ "$(printf '%s' "$WORKER_SGS" | wc -w)" -eq 1 ] || \
  warn "router nodes span multiple security groups — rules will be applied to all of them"

# The check the whole design rests on. The VPC's local route is undeletable and always beats
# a propagated BGP route, so an overlapping CUDN prefix blackholes instead of working.
if cidr_overlap "$CUDN_CIDR" "$VPC_CIDR"; then
  fail_ref "CUDN_CIDR $CUDN_CIDR overlaps the VPC CIDR $VPC_CIDR" "Why not an address from the VPC CIDR?"
fi
ok "CUDN prefix $CUDN_CIDR does not overlap the VPC"

# ---------------------------------------------------------------------------- route server
step "Route Server"

# Find an existing one by Name tag before creating, so re-runs do not leave orphans behind
# that keep billing.
RS_ID=$(aws ec2 describe-route-servers --region "$REGION" \
  --filters "Name=tag:Name,Values=$RS_NAME_TAG" \
  --query 'RouteServers[?State!=`deleted`].RouteServerId | [0]' --output text 2>/dev/null || echo "None")

if [ "$RS_ID" = "None" ] || [ -z "$RS_ID" ]; then
  info "creating a Route Server (Amazon ASN $AMAZON_ASN)"
  if [ "$DRY_RUN" = "true" ]; then
    RS_ID="rs-DRYRUN"
  else
    # persist-routes disable: routes are withdrawn the instant a session drops, which is what
    # makes the failover demo immediate instead of delayed by up to five minutes.
    RS_ID=$(aws ec2 create-route-server --region "$REGION" \
      --amazon-side-asn "$AMAZON_ASN" --persist-routes disable \
      --tag-specifications "ResourceType=route-server,Tags=[{Key=Name,Value=$RS_NAME_TAG}]" \
      --query 'RouteServer.RouteServerId' --output text)
    aws ec2 wait route-server-available --region "$REGION" --route-server-ids "$RS_ID" 2>/dev/null || sleep 60
  fi
else
  ok "reusing existing Route Server $RS_ID"
fi
info "RS_ID=$RS_ID"

# Association scopes the Route Server to this VPC; without it the endpoints have nothing to
# attach to. Tolerated because re-runs hit an already-associated VPC.
tolerate 'already|Duplicate|exists' \
  aws ec2 associate-route-server --region "$REGION" --route-server-id "$RS_ID" --vpc-id "$VPC_ID" >/dev/null

# ---------------------------------------------------------------------------- propagation
step "Route table propagation"

# Include the main route table: it serves every subnet without an explicit association, and
# a hand-created test client subnet very often lives there. Missing it produces healthy BGP
# sessions and zero reachability.
ROUTE_TABLES=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[?Associations[?SubnetId!=null || Main==`true`]].RouteTableId' \
  --output text | tr '\t' '\n' | sort -u | tr '\n' ' ')
info "route tables: $ROUTE_TABLES"

for RTB in $ROUTE_TABLES; do
  tolerate 'already|Duplicate|exists' \
    aws ec2 enable-route-server-propagation --region "$REGION" \
      --route-table-id "$RTB" --route-server-id "$RS_ID" >/dev/null
done
ok "propagation enabled"

# ---------------------------------------------------------------------------- endpoints
step "Route Server endpoints (one per router subnet)"

EXISTING_EP_SUBNETS=$(aws ec2 describe-route-server-endpoints --region "$REGION" \
  --filters "Name=route-server-id,Values=$RS_ID" \
  --query 'RouteServerEndpoints[?State!=`deleted`].SubnetId' --output text 2>/dev/null | tr '\t' '\n' | sort -u)

for SUBNET in $ROUTER_SUBNETS; do
  if printf '%s\n' "$EXISTING_EP_SUBNETS" | grep -qx "$SUBNET"; then
    ok "endpoint already present in $SUBNET"
    continue
  fi
  info "creating endpoint in $SUBNET"
  run aws ec2 create-route-server-endpoint --region "$REGION" \
    --route-server-id "$RS_ID" --subnet-id "$SUBNET" >/dev/null
done

if [ "$DRY_RUN" != "true" ]; then
  EXPECTED=$(printf '%s' "$ROUTER_SUBNETS" | wc -w)
  # Count endpoints that ARE available against the number expected. Counting the ones that
  # are *not* available would pass instantly if creation had failed and there were none.
  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    READY=$(aws ec2 describe-route-server-endpoints --region "$REGION" \
      --filters "Name=route-server-id,Values=$RS_ID" \
      --query 'length(RouteServerEndpoints[?State==`available`])' --output text)
    [ "$READY" -ge "$EXPECTED" ] && break
    info "waiting for endpoints: $READY/$EXPECTED available"
    sleep "$WAIT_INTERVAL"
  done
  [ "${READY:-0}" -ge "$EXPECTED" ] || warn "only $READY/$EXPECTED endpoints became available — check the table below"
  aws ec2 describe-route-server-endpoints --region "$REGION" \
    --filters "Name=route-server-id,Values=$RS_ID" \
    --query 'RouteServerEndpoints[].[RouteServerEndpointId,SubnetId,EniAddress,State]' --output table
fi

# ---------------------------------------------------------------------------- security groups
step "Security group rules"

add_rule() {  # add_rule <sg> <shorthand permission>
  tolerate 'InvalidPermission.Duplicate|already exists' \
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$1" --ip-permissions "$2" >/dev/null
}

for SG in $WORKER_SGS; do
  info "securing $SG"
  # BGP itself — without this, sessions sit in Active/Connect forever.
  add_rule "$SG" "IpProtocol=tcp,FromPort=179,ToPort=179,IpRanges=[{CidrIp=$VPC_CIDR,Description='BGP'}]"
  # BFD, only when the cluster is configured to use it. Omitting it when bfd is enabled
  # prevents the peers establishing at all, which looks like an operator fault.
  if [ "${LIVENESS_DETECTION:-bfd}" = "bfd" ]; then
    add_rule "$SG" "IpProtocol=udp,FromPort=3784,ToPort=3784,IpRanges=[{CidrIp=$VPC_CIDR,Description='BFD'}]"
  fi
  # ICMP is not just for ping: path MTU discovery needs "fragmentation needed" to get back,
  # and without it large transfers hang while small ones look fine.
  add_rule "$SG" "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=$VPC_CIDR,Description='demo ICMP'}]"
  add_rule "$SG" "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$VPC_CIDR,Description='demo HTTP'}]"

  if [ "$WITH_EPHEMERAL" = "true" ]; then
    # Replies to VM-initiated flows arrive on whichever node the route table elects, which
    # may not be the node that saw the outbound half — so no stateful entry matches them.
    # Off by default because it is a wide opening the inbound demo does not need.
    add_rule "$SG" "IpProtocol=tcp,FromPort=32768,ToPort=60999,IpRanges=[{CidrIp=$VPC_CIDR,Description='async return TCP'}]"
    add_rule "$SG" "IpProtocol=udp,FromPort=32768,ToPort=60999,IpRanges=[{CidrIp=$VPC_CIDR,Description='async return UDP'}]"
  fi
done
ok "ingress rules in place"

# ---------------------------------------------------------------------------- IAM
step "IAM role for the operator (CCO/STS)"

TRUST=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC}:aud": ["openshift", "sts.amazonaws.com"],
        "${OIDC}:sub": "system:serviceaccount:${OPERATOR_NS}:${OPERATOR_SA}"
      }
    }
  }]
}
EOF
)
# aud "openshift" is what the Cloud Credential Operator mints; "sts.amazonaws.com" covers the
# pod-identity-webhook path. sub pins the role to one ServiceAccount so nothing else in the
# cluster can assume it — and it must match the name script 01 reported.

POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "sts:GetCallerIdentity",
      "ec2:DescribeRouteServers",
      "ec2:DescribeRouteServerEndpoints",
      "ec2:DescribeRouteServerPeers",
      "ec2:DescribeSubnets",
      "ec2:DescribeInstances",
      "ec2:CreateRouteServerPeer",
      "ec2:DeleteRouteServerPeer",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateTags",
      "ec2:ModifyNetworkInterfaceAttribute"
    ],
    "Resource": "*"
  }]
}
EOF
)
# Describe* = discovery (the operator is given only Route Server IDs and derives the rest).
# Create/DeleteRouteServerPeer = the peering lifecycle, including cleanup on delete.
# Authorize/RevokeSecurityGroupIngress = required by AWS for peer create/delete.
# CreateTags = managed-by tagging, so several clusters can share one Route Server.
# ModifyNetworkInterfaceAttribute = disables source/dest check. NOT ModifyInstanceAttribute.
# Resource "*" is demo-grade; scope the write actions for production.

if [ "$DRY_RUN" = "true" ]; then
  info "[dry] would create/update IAM role $IAM_ROLE_NAME"
else
  if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
    ok "role exists; updating trust policy in place"
    aws iam update-assume-role-policy --role-name "$IAM_ROLE_NAME" --policy-document "$TRUST"
  else
    aws iam create-role --role-name "$IAM_ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
    ok "role created"
  fi
  aws iam put-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-name bgp-cloud-connector --policy-document "$POLICY"
fi
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${IAM_ROLE_NAME}"
info "ROLE_ARN=$ROLE_ARN"

# ---------------------------------------------------------------------------- test client
TEST_CLIENT_ID=""; TEST_CLIENT_IP=""
if [ "$WITH_TEST_CLIENT" = "true" ]; then
  step "Test client"
  # Latest AL2023 AMI via the SSM public parameter, so this does not rot as AMIs are replaced.
  AMI=$(aws ssm get-parameters --region "$REGION" \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameters[0].Value' --output text 2>/dev/null || echo "")
  FIRST_SUBNET=$(printf '%s' "$ROUTER_SUBNETS" | awk '{print $1}')
  if [ -z "$AMI" ] || [ "$AMI" = "None" ]; then
    warn "could not resolve an AL2023 AMI — create the test client by hand"
  elif [ "$DRY_RUN" = "true" ]; then
    info "[dry] would launch $TEST_CLIENT_INSTANCE_TYPE in $FIRST_SUBNET"
  else
    TEST_CLIENT_ID=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" \
      --instance-type "$TEST_CLIENT_INSTANCE_TYPE" --subnet-id "$FIRST_SUBNET" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${RS_NAME_TAG}-client}]" \
      --query 'Instances[0].InstanceId' --output text)
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$TEST_CLIENT_ID"
    TEST_CLIENT_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$TEST_CLIENT_ID" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
    ok "test client $TEST_CLIENT_ID at $TEST_CLIENT_IP"
    # No instance profile is attached here on purpose: attaching one silently is a privilege
    # decision that belongs to the account owner, not to a script.
    warn "attach an instance profile with AmazonSSMManagedInstanceCore for SSM access,"
    warn "and in a private subnet add VPC endpoints for ssm, ssmmessages and ec2messages"
  fi
fi

# ---------------------------------------------------------------------------- handback
if [ "$DRY_RUN" != "true" ]; then
  : > "$HANDBACK_FILE"
  save_var "$HANDBACK_FILE" REGION         "$REGION"
  save_var "$HANDBACK_FILE" RS_ID          "$RS_ID"
  save_var "$HANDBACK_FILE" ROLE_ARN       "$ROLE_ARN"
  save_var "$HANDBACK_FILE" VPC_ID         "$VPC_ID"
  save_var "$HANDBACK_FILE" VPC_CIDR       "$VPC_CIDR"
  save_var "$HANDBACK_FILE" WORKER_SGS     "$WORKER_SGS"
  save_var "$HANDBACK_FILE" ROUTE_TABLES   "$ROUTE_TABLES"
  save_var "$HANDBACK_FILE" ROUTER_SUBNETS "$ROUTER_SUBNETS"
  save_var "$HANDBACK_FILE" INSTANCE_IDS   "$INSTANCE_IDS"
  save_var "$HANDBACK_FILE" TEST_CLIENT_ID "$TEST_CLIENT_ID"
  save_var "$HANDBACK_FILE" TEST_CLIENT_IP "$TEST_CLIENT_IP"
fi

step "Done"
cat <<EOF

  Send this file back to the cluster admin:

      $HANDBACK_FILE

  They run:  ./03-cluster-deploy.sh

  Still manual, if on-prem reachability is in scope (see "VPC and address design"):
    - Transit Gateway: add a STATIC route $CUDN_CIDR -> the VPC attachment.
      VPC attachments propagate only the VPC's own CIDRs, so this is never learned.
    - Direct Connect gateway: add $CUDN_CIDR to the allowed-prefixes list.
      Do this AFTER the TGW static route, or you advertise a prefix nothing can deliver.

EOF
