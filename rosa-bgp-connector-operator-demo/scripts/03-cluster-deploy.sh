#!/usr/bin/env bash
#
# ROLE: cluster admin (oc)          RUN ORDER: 3 of 3
#
# Consumes state/handback.env from the AWS owner and deploys everything cluster-side:
# operator, BGPCloudConfiguration, CUDN via BGPRouting, and the demo VM. Stops at each
# checkpoint rather than racing ahead, because a failure three steps later is much harder
# to attribute than a failure here.
#
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: 03-cluster-deploy.sh [options]

  --skip-vm      Deploy networking only (no CNV install, no VirtualMachine)
  --dry-run      Print what would change, change nothing
  --yes          Do not prompt
  -h, --help     This text

  Without --skip-vm, OpenShift Virtualization is installed automatically if missing.
USAGE
}

SKIP_VM=false
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-vm) SKIP_VM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
DRY_RUN="${DRY_RUN:-false}"; ASSUME_YES="${ASSUME_YES:-false}"

load_config
load_state "$HANDBACK_FILE" "handback file from the AWS owner"
require_oc_login

[ -n "${RS_ID:-}" ]    || fail "handback.env has no RS_ID"
[ -n "${ROLE_ARN:-}" ] || fail "handback.env has no ROLE_ARN"
info "Route Server: $RS_ID"
info "IAM role    : $ROLE_ARN"

# ---------------------------------------------------------------------------- operator
step "Installing the operator"

# Resolve the channel from the catalog rather than hardcoding: a Subscription naming a
# channel that does not exist sits in ResolutionFailed instead of erroring loudly.
if ! oc get packagemanifest "$OPERATOR_PKG" -n openshift-marketplace >/dev/null 2>&1; then
  fail_ref "package '$OPERATOR_PKG' is not in this cluster's catalog (4.22+ ships it)" "Section 3"
fi
CHANNEL="${OPERATOR_CHANNEL:-}"
if [ -z "$CHANNEL" ]; then
  CHANNEL=$(oc get packagemanifest "$OPERATOR_PKG" -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}')
fi
CATALOG=$(oc get packagemanifest "$OPERATOR_PKG" -n openshift-marketplace \
  -o jsonpath='{.status.catalogSource}')
CATALOG_NS=$(oc get packagemanifest "$OPERATOR_PKG" -n openshift-marketplace \
  -o jsonpath='{.status.catalogSourceNamespace}')
info "channel=$CHANNEL catalog=$CATALOG/$CATALOG_NS"

if [ "$DRY_RUN" = "true" ]; then
  info "[dry] would subscribe to $OPERATOR_PKG"
else
  # The namespace name is half of the IAM trust policy's `sub` — installing anywhere else
  # silently invalidates the role the AWS owner created.
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${OPERATOR_NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OPERATOR_NS}
  namespace: ${OPERATOR_NS}
spec:
  # OwnNamespace only — the CSV does not support AllNamespaces (empty targetNamespaces
  # makes OLM try AllNamespaces and the install fails with UnsupportedOperatorGroup).
  # Cluster-scoped CRs are still fine; watch scope is not the same as CR scope.
  targetNamespaces:
    - ${OPERATOR_NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_PKG}
  namespace: ${OPERATOR_NS}
spec:
  channel: ${CHANNEL}
  name: ${OPERATOR_PKG}
  source: ${CATALOG}
  sourceNamespace: ${CATALOG_NS}
  installPlanApproval: Automatic
  config:
    env:
      # Without this the controller starts cleanly and only fails later, on its first EC2 call.
      - name: ROLEARN
        value: "${ROLE_ARN}"
EOF

  info "waiting for the CSV to reach Succeeded"
  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    # Match this package only — other CSVs can appear in the namespace and are not success.
    PHASE=$(oc get csv -n "$OPERATOR_NS" -o json 2>/dev/null \
      | python3 -c 'import json,sys
items=json.load(sys.stdin).get("items",[])
for i in items:
  if i.get("metadata",{}).get("name","").startswith("bgp-cloud-connector."):
    print(i.get("status",{}).get("phase",""))
    break' 2>/dev/null || true)
    [ "$PHASE" = "Succeeded" ] && break
    info "bgp-cloud-connector CSV phase: ${PHASE:-<none>}"
    sleep "$WAIT_INTERVAL"
  done
  oc get csv -n "$OPERATOR_NS" || true
  [ "${PHASE:-}" = "Succeeded" ] || fail "bgp-cloud-connector CSV is not Succeeded (phase=${PHASE:-none}) — fix the OperatorGroup/Subscription before applying CRs"

  # Cross-check the ServiceAccount against what the trust policy was built with. A mismatch
  # here is the top cause of CloudCredentialsInvalid, and it is invisible until the operator
  # makes its first AWS call.
  ACTUAL_SA=$(oc get sa -n "$OPERATOR_NS" -o name | sed 's|serviceaccount/||' | grep -i controller-manager || true)
  if [ -n "$ACTUAL_SA" ] && [ "$ACTUAL_SA" != "openshift-bgp-cloud-connector-controller-manager" ]; then
    warn "ServiceAccount is '$ACTUAL_SA' but the IAM trust policy expects"
    warn "'openshift-bgp-cloud-connector-controller-manager' — have the AWS owner fix the sub"
  fi
fi

# ---------------------------------------------------------------------------- BGP config
step "BGPCloudConfiguration"
warn "this patches the cluster network to enable FRR and will briefly disrupt networking"
confirm "Apply BGPCloudConfiguration now?" || fail "aborted by user"

if [ "$DRY_RUN" = "true" ]; then
  info "[dry] would apply BGPCloudConfiguration/cluster"
else
  cat <<EOF | oc apply -f -
apiVersion: networking.openshift.io/v1beta1
kind: BGPCloudConfiguration
metadata:
  # Cluster-scoped singleton. Any other name is ignored rather than rejected.
  name: cluster
spec:
  platform: AWS
  routerNodeSelector:
    ${ROUTER_NODE_LABEL_KEY}: "${ROUTER_NODE_LABEL_VALUE}"
  bgp:
    localASN: ${CLUSTER_ASN}
    livenessDetection: ${LIVENESS_DETECTION}
  aws:
    region: ${REGION}
    # Capital ID. Endpoints, AZ mapping and the remote ASN are discovered from this alone.
    routeServerIDs:
      - ${RS_ID}
EOF
fi

step "Checkpoint 1 — BGP sessions"
if [ "$DRY_RUN" != "true" ]; then
  # Poll rather than sleep: FRR has to roll out before any session can come up, and how long
  # that takes depends on the cluster.
  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    # Prefer counting lines over `wc -l || echo 0`: with pipefail, a failed oc still lets
    # wc print "0" and then echo adds another "0", which breaks integer tests.
    TOTAL=$(oc get bgpsessionstates -A --no-headers 2>/dev/null | grep -c . || true)
    UP=$(oc get bgpsessionstates -A --no-headers 2>/dev/null | grep -ci established || true)
    TOTAL=${TOTAL:-0}; UP=${UP:-0}
    [ "$TOTAL" -gt 0 ] && [ "$UP" -eq "$TOTAL" ] && break
    info "sessions established: ${UP}/${TOTAL}"
    sleep "$WAIT_INTERVAL"
  done
  oc get bgpsessionstates -A -o wide || true
  if [ "${TOTAL:-0}" -eq 0 ] || [ "${UP:-0}" -ne "${TOTAL:-0}" ]; then
    oc get bgpcloudconfiguration cluster -o jsonpath='{.status.conditions}' 2>/dev/null || true
    fail_ref "BGP sessions are not all Established — do not continue" "Section 8, Troubleshooting"
  fi
  ok "all BGP sessions Established"
fi

# ---------------------------------------------------------------------------- network
step "Namespace and BGPRouting"

if [ "$DRY_RUN" = "true" ]; then
  info "[dry] would create namespace $DEMO_NAMESPACE and BGPRouting $BGPROUTING_NAME"
else
  # Both labels must exist at creation — admission refuses to add the primary-UDN label to an
  # existing namespace, and the only remedy is deleting it.
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
    cluster-udn: ${CUDN_NAME}
---
apiVersion: networking.openshift.io/v1beta1
kind: BGPRouting
metadata:
  name: ${BGPROUTING_NAME}
spec:
  network:
    # Must equal the cluster-udn label above, or the VM lands on the pod network instead.
    name: ${CUDN_NAME}
    # Nested under network (not spec.subnets) — required by the v1beta1 CRD.
    subnets:
      - ${CUDN_CIDR}
EOF

  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    PH=$(oc get bgprouting "$BGPROUTING_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$PH" = "Ready" ] && break
    info "BGPRouting phase: ${PH:-<none>}"
    sleep "$WAIT_INTERVAL"
  done
  [ "${PH:-}" = "Ready" ] || fail_ref "BGPRouting did not reach Ready (phase=${PH:-none})" "Section 8"
  ok "BGPRouting Ready"
  oc get clusteruserdefinednetwork,routeadvertisements
fi

# ---------------------------------------------------------------------------- OpenShift Virtualization (CNV)
# Only needed for the demo VM. BGP / CUDN work without it (--skip-vm).
ensure_cnv() {
  local ns="${CNV_NS:-openshift-cnv}"
  local pkg="${CNV_PKG:-kubevirt-hyperconverged}"
  local channel catalog catalog_ns phase hco

  hco=$(oc get hyperconverged kubevirt-hyperconverged -n "$ns" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  if [ "$hco" = "True" ] && oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1; then
    ok "OpenShift Virtualization already Available"
    return 0
  fi

  step "Installing OpenShift Virtualization"
  if ! oc get packagemanifest "$pkg" -n openshift-marketplace >/dev/null 2>&1; then
    fail_ref "package '$pkg' is not in this cluster's catalog" "Section 1"
  fi
  channel="${CNV_CHANNEL:-}"
  if [ -z "$channel" ]; then
    channel=$(oc get packagemanifest "$pkg" -n openshift-marketplace \
      -o jsonpath='{.status.defaultChannel}')
  fi
  catalog=$(oc get packagemanifest "$pkg" -n openshift-marketplace \
    -o jsonpath='{.status.catalogSource}')
  catalog_ns=$(oc get packagemanifest "$pkg" -n openshift-marketplace \
    -o jsonpath='{.status.catalogSourceNamespace}')
  info "channel=$channel catalog=$catalog/$catalog_ns"

  if [ "$DRY_RUN" = "true" ]; then
    info "[dry] would install OpenShift Virtualization in $ns"
    return 0
  fi

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: ${ns}
spec:
  targetNamespaces:
    - ${ns}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: ${ns}
spec:
  channel: ${channel}
  name: ${pkg}
  source: ${catalog}
  sourceNamespace: ${catalog_ns}
  installPlanApproval: Automatic
EOF

  # VirtualMachine CRDs appear only AFTER HyperConverged is created. Wait for the
  # operator CSV + HyperConverged CRD first, then apply HCO, then wait for VMs.
  info "waiting for kubevirt-hyperconverged CSV Succeeded (and HyperConverged CRD)"
  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    phase=$(oc get csv -n "$ns" -o json 2>/dev/null \
      | python3 -c 'import json,sys
items=json.load(sys.stdin).get("items",[])
for i in items:
  name=i.get("metadata",{}).get("name","").lower()
  if "kubevirt-hyperconverged" in name or "hco-operator" in name:
    print(i.get("status",{}).get("phase",""))
    break' 2>/dev/null || true)
    if [ "$phase" = "Succeeded" ] && oc get crd hyperconvergeds.hco.kubevirt.io >/dev/null 2>&1; then
      break
    fi
    info "CNV CSV phase: ${phase:-<none>}"
    sleep "$WAIT_INTERVAL"
  done
  oc get csv -n "$ns" || true
  [ "${phase:-}" = "Succeeded" ] || fail "kubevirt-hyperconverged CSV is not Succeeded (phase=${phase:-none})"
  oc get crd hyperconvergeds.hco.kubevirt.io >/dev/null 2>&1 \
    || fail "HyperConverged CRD missing after CSV Succeeded"

  cat <<EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: ${ns}
spec: {}
EOF

  info "waiting for HyperConverged Available (deploys KubeVirt / VirtualMachine CRDs)"
  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    hco=$(oc get hyperconverged kubevirt-hyperconverged -n "$ns" \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    if [ "$hco" = "True" ] && oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1; then
      break
    fi
    info "HyperConverged Available: ${hco:-<none>}  VirtualMachine CRD: $(oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1 && echo yes || echo no)"
    sleep "$WAIT_INTERVAL"
  done
  [ "${hco:-}" = "True" ] || fail "HyperConverged is not Available — check 'oc get hyperconverged -n $ns -o yaml'"
  oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1 \
    || fail "VirtualMachine CRD still missing after HyperConverged Available"
  ok "OpenShift Virtualization Available"

  if ! oc get nodes -l kubevirt.io/schedulable=true --no-headers 2>/dev/null | grep -q .; then
    warn "no node is kubevirt.io/schedulable=true yet — metal nodes must finish becoming schedulable"
    warn "the VM may stay Pending until that label appears (CNV on ROSA needs *.metal)"
  fi
}

# ---------------------------------------------------------------------------- VM
if [ "$SKIP_VM" = "true" ]; then
  step "Skipping VM (--skip-vm)"
else
  ensure_cnv
  step "Demo VM"
  if [ "$DRY_RUN" = "true" ]; then
    info "[dry] would create VirtualMachine $VM_NAME"
  else
    cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${DEMO_NAMESPACE}
spec:
  # Always: KubeVirt restarts the VM after relocation, which together with the IPAMClaim is
  # what returns the same address on a new node.
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 2Gi
        devices:
          disks:
            - name: rootdisk
              disk: { bus: virtio }
            - name: cloudinit
              disk: { bus: virtio }
          interfaces:
            - name: default
              binding:
                # Only supported binding on a primary UDN. masquerade would NAT the VM
                # behind the pod IP and defeat the entire demo.
                name: l2bridge
      networks:
        - name: default
          # Membership comes from the namespace labels, not from naming the CUDN here.
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: demo
              chpasswd: { expire: False }
              ssh_pwauth: True
              write_files:
                - path: /var/www/index.html
                  content: "<h1>Reached this VM directly. No NAT.</h1>"
                - path: /etc/systemd/system/demo-web.service
                  content: |
                    [Unit]
                    Description=demo web
                    [Service]
                    # python3 is in the base image, so the demo does not depend on the VM
                    # having outbound internet at exactly the wrong moment.
                    ExecStart=/usr/bin/python3 -m http.server 80 --directory /var/www
                    Restart=always
                    [Install]
                    WantedBy=multi-user.target
              runcmd:
                - [ systemctl, daemon-reload ]
                - [ systemctl, enable, --now, demo-web.service ]
EOF

    step "Checkpoint 2 — the VM's address"
    for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
      VM_IP=$(oc get vmi "$VM_NAME" -n "$DEMO_NAMESPACE" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true)
      [ -n "$VM_IP" ] && break
      sleep "$WAIT_INTERVAL"
    done
    [ -n "${VM_IP:-}" ] || fail "VM never reported an address — check 'oc describe vmi $VM_NAME -n $DEMO_NAMESPACE'"

    # The decisive check. A pod-network address means the namespace labelling was wrong and
    # the VM silently attached to the default network.
    if ip_in_cidr "$VM_IP" "$CUDN_CIDR"; then
      ok "VM address $VM_IP is inside $CUDN_CIDR"
    else
      fail_ref "VM address $VM_IP is NOT in $CUDN_CIDR — it attached to the pod network" "Section 5, Checkpoint 2"
    fi

    # A claim must exist, otherwise the address is not durable and the stability claim you
    # make to the customer would be false.
    oc get ipamclaims -n "$DEMO_NAMESPACE" || warn "no IPAMClaim found — the address may not survive a restart"
    save_var "$HANDBACK_FILE" VM_IP "$VM_IP"
  fi
fi

step "Done"
cat <<EOF

  VM address: ${VM_IP:-<skipped>}

  Next:
    ./04-verify.sh                       demo-readiness check
    From the test client (${TEST_CLIENT_IP:-<none>}):
        ping -c4 ${VM_IP:-<vm-ip>}
        curl http://${VM_IP:-<vm-ip>}/

  Still to confirm from the AWS side (script 04 does this if you have credentials):
    the route ${CUDN_CIDR} appears in the VPC route tables.

EOF
