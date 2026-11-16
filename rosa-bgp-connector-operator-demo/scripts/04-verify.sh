#!/usr/bin/env bash
#
# ROLE: either (read-only)
#
# Demo-readiness check. Changes nothing. Cluster checks always run; AWS checks run only if
# usable credentials are present, so the cluster admin can run this without AWS access.
#
# Run it the morning of the demo, not just after the build — Route Server endpoints bill
# hourly and clusters get reaped.
#
set -uo pipefail     # deliberately not -e: this script reports failures, it does not abort
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

load_config
[ -f "$HANDBACK_FILE" ] && . "$HANDBACK_FILE"

PASS=0; FAILED=0
check() {  # check <description> <command...>
  if "${@:2}" >/dev/null 2>&1; then
    printf '    %s[pass]%s %s\n' "$C_GRN" "$C_RST" "$1"; PASS=$((PASS+1))
  else
    printf '    %s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$1"; FAILED=$((FAILED+1))
  fi
}

step "Cluster"

if oc whoami >/dev/null 2>&1; then
  check "operator CSV Succeeded" bash -c \
    "oc get csv -n '$OPERATOR_NS' -o jsonpath='{.items[*].status.phase}' | grep -q Succeeded"

  check "BGPCloudConfiguration exists" oc get bgpcloudconfiguration cluster

  # Any session not Established means the data path is not there, whatever else looks fine.
  TOTAL=$(oc get bgpsessionstates -A --no-headers 2>/dev/null | wc -l)
  UP=$(oc get bgpsessionstates -A --no-headers 2>/dev/null | grep -ci established)
  if [ "$TOTAL" -gt 0 ] && [ "$UP" -eq "$TOTAL" ]; then
    printf '    %s[pass]%s BGP sessions Established (%s/%s)\n' "$C_GRN" "$C_RST" "$UP" "$TOTAL"; PASS=$((PASS+1))
  else
    printf '    %s[FAIL]%s BGP sessions Established (%s/%s)\n' "$C_RED" "$C_RST" "$UP" "$TOTAL"; FAILED=$((FAILED+1))
  fi

  check "BGPRouting Ready" bash -c \
    "[ \"\$(oc get bgprouting '$BGPROUTING_NAME' -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready ]"

  check "CUDN generated" oc get clusteruserdefinednetwork "cluster-udn-${CUDN_NAME}"

  # Zero Services in the demo namespace is not hygiene — it is the claim being demonstrated.
  SVCS=$(oc get svc -n "$DEMO_NAMESPACE" --no-headers 2>/dev/null | wc -l)
  if [ "$SVCS" -eq 0 ]; then
    printf '    %s[pass]%s no Services in %s (nothing is proxying for the VM)\n' "$C_GRN" "$C_RST" "$DEMO_NAMESPACE"; PASS=$((PASS+1))
  else
    printf '    %s[warn]%s %s Service(s) in %s — the "nothing in front of it" line is weaker\n' "$C_YEL" "$C_RST" "$SVCS" "$DEMO_NAMESPACE"
  fi

  VM_IP_NOW=$(oc get vmi "$VM_NAME" -n "$DEMO_NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
  if [ -n "$VM_IP_NOW" ] && ip_in_cidr "$VM_IP_NOW" "$CUDN_CIDR"; then
    printf '    %s[pass]%s VM address %s is in %s\n' "$C_GRN" "$C_RST" "$VM_IP_NOW" "$CUDN_CIDR"; PASS=$((PASS+1))
  else
    printf '    %s[FAIL]%s VM address "%s" is not in %s\n' "$C_RED" "$C_RST" "${VM_IP_NOW:-none}" "$CUDN_CIDR"; FAILED=$((FAILED+1))
  fi

  # Without a claim the address is not durable, so the "survives migration" story is false.
  check "IPAMClaim present (address is durable)" bash -c \
    "[ \"\$(oc get ipamclaims -n '$DEMO_NAMESPACE' --no-headers 2>/dev/null | wc -l)\" -gt 0 ]"
else
  warn "not logged in to a cluster — cluster checks skipped"
fi

step "AWS"

if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  if [ -n "${RS_ID:-}" ]; then
    EP_OK=$(aws ec2 describe-route-server-endpoints --region "$REGION" \
      --filters "Name=route-server-id,Values=$RS_ID" \
      --query 'length(RouteServerEndpoints[?State==`available`])' --output text 2>/dev/null)
    printf '    %s[info]%s Route Server endpoints available: %s\n' "$C_BLU" "$C_RST" "${EP_OK:-0}"

    # The money shot of the demo. If this is empty with healthy sessions, propagation is
    # missing on that route table rather than BGP being broken.
    FOUND=0
    for RTB in ${ROUTE_TABLES:-}; do
      if aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$RTB" \
           --query "RouteTables[].Routes[?DestinationCidrBlock=='${CUDN_CIDR}']" \
           --output text 2>/dev/null | grep -q .; then
        FOUND=$((FOUND+1))
      fi
    done
    if [ "$FOUND" -gt 0 ]; then
      printf '    %s[pass]%s %s advertised into %s route table(s)\n' "$C_GRN" "$C_RST" "$CUDN_CIDR" "$FOUND"; PASS=$((PASS+1))
    else
      printf '    %s[FAIL]%s %s is not in any VPC route table\n' "$C_RED" "$C_RST" "$CUDN_CIDR"; FAILED=$((FAILED+1))
    fi
  else
    warn "no RS_ID in handback.env — AWS checks skipped"
  fi
else
  warn "no usable AWS credentials — AWS checks skipped."
  warn "You will need a screenshot of the VPC route table for demo beat 3."
fi

step "Summary"
printf '    passed: %s   failed: %s\n\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
