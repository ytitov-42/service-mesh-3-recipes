#!/usr/bin/env bash
#
# ROLE: either (aws; oc optional for VM_IP fallback)
#
# Demo helper: from the VPC test client, prove direct reachability to the VM
# (ping + curl). Uses SSM SendCommand by default so you do not need an interactive
# shell or the Session Manager plugin. --shell opens an interactive session.
#
# Prerequisites: ./02-aws-setup.sh --with-test-client and a running demo VM.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SSM_ROLE_NAME="${SSM_ROLE_NAME:-bgp-demo-ssm-role}"
SSM_PROFILE_NAME="${SSM_PROFILE_NAME:-bgp-demo-ssm-profile}"

usage() {
  cat <<'USAGE'
Usage: 05-demo-reachability.sh [options]

  (default)              Run ping + curl on the test client via SSM SendCommand
  --shell                Interactive SSM session on the test client
  --ensure-ssm-profile   Create/attach an SSM instance profile if missing
  --dry-run              Print what would run, change nothing
  --yes                  Do not prompt
  -h, --help             This text

Reads TEST_CLIENT_ID / VM_IP from state/handback.env (VM_IP can also come from oc).
USAGE
}

MODE=commands
ENSURE_PROFILE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) MODE=shell; shift ;;
    --ensure-ssm-profile) ENSURE_PROFILE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
DRY_RUN="${DRY_RUN:-false}"; ASSUME_YES="${ASSUME_YES:-false}"

load_config
load_state "$HANDBACK_FILE" "handback file from script 02"
require_aws

[ -n "${TEST_CLIENT_ID:-}" ] || fail "handback.env has no TEST_CLIENT_ID — re-run ./02-aws-setup.sh --with-test-client"
[ -n "${REGION:-}" ] || fail "REGION missing"

# Prefer saved VM_IP; fall back to the live VMI.
if [ -z "${VM_IP:-}" ] && command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
  VM_IP=$(oc get vmi "${VM_NAME:-demo-vm}" -n "${DEMO_NAMESPACE:-bgp-demo}" \
    -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true)
fi
[ -n "${VM_IP:-}" ] || fail "no VM_IP in handback.env and could not read it from the cluster"

step "Demo reachability"
info "test client : $TEST_CLIENT_ID (${TEST_CLIENT_IP:-unknown})"
info "VM address  : $VM_IP"
info "region      : $REGION"

ensure_ssm_profile() {
  local trust
  trust=$(mktemp)
  cat > "$trust" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
  if [ "$DRY_RUN" = "true" ]; then
    info "[dry] would ensure IAM role $SSM_ROLE_NAME and profile $SSM_PROFILE_NAME"
    rm -f "$trust"
    return 0
  fi
  if ! aws iam get-role --role-name "$SSM_ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$SSM_ROLE_NAME" --assume-role-policy-document "file://$trust" >/dev/null
    ok "created role $SSM_ROLE_NAME"
  fi
  aws iam attach-role-policy --role-name "$SSM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
  if ! aws iam get-instance-profile --instance-profile-name "$SSM_PROFILE_NAME" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$SSM_PROFILE_NAME" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$SSM_PROFILE_NAME" --role-name "$SSM_ROLE_NAME"
    ok "created instance profile $SSM_PROFILE_NAME"
    sleep 8
  fi
  rm -f "$trust"

  local assoc profile_arn
  assoc=$(aws ec2 describe-iam-instance-profile-associations --region "$REGION" \
    --filters "Name=instance-id,Values=$TEST_CLIENT_ID" \
    --query 'IamInstanceProfileAssociations[0].AssociationId' --output text 2>/dev/null || echo None)
  profile_arn=$(aws iam get-instance-profile --instance-profile-name "$SSM_PROFILE_NAME" \
    --query 'InstanceProfile.Arn' --output text)
  if [ "$assoc" = "None" ] || [ -z "$assoc" ] || [ "$assoc" = "null" ]; then
    aws ec2 associate-iam-instance-profile --region "$REGION" \
      --instance-id "$TEST_CLIENT_ID" --iam-instance-profile "Name=$SSM_PROFILE_NAME" >/dev/null
    ok "attached $SSM_PROFILE_NAME to $TEST_CLIENT_ID"
    info "rebooting instance so SSM picks up credentials"
    aws ec2 reboot-instances --region "$REGION" --instance-ids "$TEST_CLIENT_ID"
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$TEST_CLIENT_ID"
  else
    ok "instance already has an IAM instance profile"
  fi
  : "${profile_arn:=}"
}

wait_ssm_online() {
  local status i
  info "waiting for SSM PingStatus=Online"
  for i in $(seq 1 36); do
    status=$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$TEST_CLIENT_ID" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
    [ "$status" = "Online" ] && { ok "SSM Online"; return 0; }
    info "SSM status: ${status:-None}"
    sleep 5
  done
  fail "test client never registered with SSM.
    Fix: ./05-demo-reachability.sh --ensure-ssm-profile
    Or use the console: Systems Manager → Session Manager → Start session"
}

if [ "$ENSURE_PROFILE" = "true" ]; then
  step "Ensuring SSM instance profile"
  ensure_ssm_profile
fi

# Profile present?
if ! aws ec2 describe-instances --region "$REGION" --instance-ids "$TEST_CLIENT_ID" \
     --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text 2>/dev/null \
   | grep -q arn:; then
  warn "test client has no IAM instance profile — SSM will not work"
  if confirm "Create and attach $SSM_PROFILE_NAME now?"; then
    ensure_ssm_profile
  else
    fail "attach an SSM instance profile, or re-run with --ensure-ssm-profile"
  fi
fi

wait_ssm_online

if [ "$MODE" = "shell" ]; then
  step "Interactive SSM session"
  require_cmd session-manager-plugin
  if [ "$DRY_RUN" = "true" ]; then
    info "[dry] aws ssm start-session --region $REGION --target $TEST_CLIENT_ID"
    info "[dry] then: ping -c4 $VM_IP && curl -sS http://$VM_IP/"
    exit 0
  fi
  info "starting session — once connected, run:"
  info "  ping -c4 $VM_IP"
  info "  curl -sS http://$VM_IP/"
  exec aws ssm start-session --region "$REGION" --target "$TEST_CLIENT_ID"
fi

step "Remote ping + curl via SSM SendCommand"
if [ "$DRY_RUN" = "true" ]; then
  info "[dry] would run on $TEST_CLIENT_ID:"
  info "  ping -c4 $VM_IP"
  info "  curl -sS -m 10 http://$VM_IP/"
  exit 0
fi

CMD_ID=$(aws ssm send-command --region "$REGION" \
  --instance-ids "$TEST_CLIENT_ID" \
  --document-name AWS-RunShellScript \
  --comment "BGP demo reachability to $VM_IP" \
  --parameters "commands=[\"set -e\",\"echo '=== ping ==='\",\"ping -c4 $VM_IP\",\"echo\",\"echo '=== curl ==='\",\"curl -sS -m 10 http://$VM_IP/\",\"echo\"]" \
  --query 'Command.CommandId' --output text)
info "command id: $CMD_ID"

for _ in $(seq 1 36); do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$TEST_CLIENT_ID" \
    --query 'Status' --output text 2>/dev/null || echo Pending)
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  info "command status: $STATUS"
  sleep 3
done

OUT=$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$TEST_CLIENT_ID" \
  --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
  --output json)

printf '%s\n' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("    status:", d.get("Status"))
print("---- stdout ----")
print(d.get("Stdout") or "")
err=d.get("Stderr") or ""
if err.strip():
    print("---- stderr ----")
    print(err)
sys.exit(0 if d.get("Status")=="Success" else 1)
' || fail "reachability command did not succeed — see output above"

ok "VM $VM_IP is reachable from the VPC test client (no NAT / no Service)"
cat <<EOF

  Optional interactive shell:
    ./05-demo-reachability.sh --shell

EOF
