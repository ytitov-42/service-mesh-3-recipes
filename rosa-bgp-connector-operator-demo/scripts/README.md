# BGP Cloud Connector demo — scripts

Automates the runbook ([`rosa-bgp-vm-direct-reachability-runbook.md`](../rosa-bgp-vm-direct-reachability-runbook.md)).
The runbook explains *why*; these scripts are the *how*.

> **Never run against a cluster you care about without a dry run first.**
> Script 03 enables FRR on the cluster network (brief disruption) and can install
> OpenShift Virtualization. Route Server endpoints bill roughly **$0.75/hr each**.

---

## Acronyms

| Term | Meaning |
|---|---|
| **FRR** | [Free Range Routing](https://frrouting.org/) — routing stack (BGP/BFD) that OVN-Kubernetes enables on router nodes when `BGPCloudConfiguration` is applied; causes a short network blip |
| **CUDN** | Cluster User Defined Network — L2/L3 overlay whose prefix is advertised into the VPC |
| **CNV** | OpenShift Virtualization (KubeVirt) — runs the demo VM on metal workers |
| **HCP** | ROSA Hosted Control Plane |
| **ASN** | Autonomous System Number (BGP). Cluster and Amazon ASNs must differ |
| **BFD** | Bidirectional Forwarding Detection — fast session liveness (vs BGP keepalives) |
| **SSM** | AWS Systems Manager — used by script `05` to reach the VPC test client |

---

## What you get

When you finish:

- BGP sessions from labelled workers to Amazon VPC Route Server
- CUDN prefix (default `192.168.100.0/24`) advertised into VPC route tables
- A KubeVirt VM on that prefix (e.g. `192.168.100.3`) with **no** Service / NAT
- `ping` / `curl` from a VPC EC2 test client straight to the VM

---

## Script map

```
  cluster admin            AWS owner             cluster admin
  ┌──────────────┐        ┌──────────────┐      ┌──────────────────┐
  │ 01-cluster-  │ hand-  │ 02-aws-      │ hand-│ 03-cluster-      │
  │   prepare.sh ├───────►│   setup.sh   ├─────►│   deploy.sh      │
  └──────────────┘ off.env└──────────────┘ back └────────┬─────────┘
                              .env                       │
                                                         ▼
                                                  04-verify.sh
                                                         │
                                                         ▼
                                              05-demo-reachability.sh
```

**Main demo path:** **01 → 02 → 03 → 04**. Then **05** for the live ping/curl; **90 → 91** to tear down.

| Script | Who | Needs | Does |
|---|---|---|---|
| **`01-cluster-prepare.sh`** | cluster admin | `oc` | Preflight, label routers, write `state/handoff.env` |
| **`02-aws-setup.sh`** | AWS owner | `aws` (EC2 + IAM) | Route Server, endpoints, SG, IAM role → `state/handback.env` |
| **`03-cluster-deploy.sh`** | cluster admin | `oc` | BGP operator, CNV (if VM), BGP CRs, demo VM |
| **`04-verify.sh`** | either | `oc` and/or `aws` | Read-only readiness check |
| `05-demo-reachability.sh` | either | `aws` (SSM) | Ping/curl VM from the VPC test client |
| `90-cleanup-cluster.sh` | cluster admin | `oc` | Tear down cluster objects (**first**) |
| `91-cleanup-aws.sh` | AWS owner | `aws` | Tear down Route Server / IAM (**second**, stops hourly charge) |

Common flags: `--dry-run`, `--yes`, `--help`.

---

## Prerequisites

| Tool | Notes |
|---|---|
| `oc` | Logged in as cluster-admin |
| `aws` CLI **v2 recent** | Must include Route Server APIs (`aws ec2 help \| grep route-server`). Homebrew: `brew install awscli` and ensure `/opt/homebrew/bin` wins over old `/usr/local/bin/aws` (`hash -r`; check `aws --version`) |
| `python3` | CIDR overlap helpers |
| `rosa` | Only if you need a metal machine pool (often from the **lab bastion**, not your laptop OCM login) |
| OpenShift **4.22+** | Operator catalog ships for 4.22 / 5.0 |
| Bare-metal workers | Required for OpenShift Virtualization on ROSA (`*.metal`) |

Configure AWS credentials for the account that owns the cluster VPC before script 02.

---

## Step-by-step

Work from this directory:

```bash
cd rosa-bgp-connector-operator-demo/scripts
```

### Prerequisite: metal workers (if you need the VM)

**Goal:** bare-metal workers so CNV can run the demo VM. **Done when:** `virt-mp` is `2/2` and metal nodes are Ready with `bgp_router=true`.

CNV on ROSA needs `*.metal`. From a host where `rosa` sees your cluster (often the **bastion**).

**Inspect** (optional — see what you will pick):

```bash
rosa list clusters
# private worker subnets only (do not use .aws.subnet_ids[0] — that is often public)
rosa list machinepools -c <name>
rosa list machinepools -c <name> -o json | jq -r '.[] | "\(.id) \(.subnet // .subnets[0])"'
```

**Set variables** (from `rosa` / `jq`; HCP machine pools must use a **private** subnet):

```bash
export REGION="us-east-2"
export CLUSTER_NAME=$(rosa list clusters -o json \
  | jq -r '[.[] | select(.state=="ready")][0].name')
# reuse subnet from workers* pool (HCP field is .subnet; some builds use .subnets[])
export WORKER_SUBNET=$(rosa list machinepools -c "$CLUSTER_NAME" -o json \
  | jq -r '
      ([.[] | select(.id | startswith("workers"))][0] // .[0])
      | .subnet // .subnets[0] // empty
    ')

echo "CLUSTER_NAME=$CLUSTER_NAME  WORKER_SUBNET=$WORKER_SUBNET"
```

**Create the metal pool:**

```bash
rosa list instance-types --hosted-cp --region "$REGION" | grep -i metal

rosa create machinepool --cluster "$CLUSTER_NAME" --name virt-mp \
  --replicas 2 \
  --instance-type m5zn.metal \
  --subnet "$WORKER_SUBNET" \
  --ec2-metadata-http-tokens required \
  --labels bgp_router=true
```

Wait until the pool shows `2/2` (metal often takes **15–45 minutes** after EC2 is `running`):

```bash
# works on bastion without kubeconfig
rosa describe machinepool --cluster "$CLUSTER_NAME" --machinepool virt-mp \
  | egrep 'Current replicas|Desired replicas|Message'
# or: watch -n 30 'rosa describe machinepool -c "$CLUSTER_NAME" --machinepool virt-mp | egrep "Current replicas|Message"'

# once kubeconfig / oc login is set:
oc get nodes -L node.kubernetes.io/instance-type,bgp_router
```

> Note: `rosa list instance-types` on some CLI builds has **no** `-c` flag; use `--hosted-cp --region`.

### 0. Edit `config.env`

**Goal:** lock demo choices (name, region, CUDN, ASNs). **Done when:** values match the cluster and CUDN does not overlap pod/service/VPC CIDRs.

Set at least:

```bash
CLUSTER_NAME="your-rosa-cluster"   # same name as the ROSA cluster / metal pool
REGION="us-east-2"                 # must match the cluster
CUDN_CIDR="192.168.100.0/24"     # must NOT overlap VPC / pod / service CIDRs
AMAZON_ASN="64512"
CLUSTER_ASN="65001"                # must differ from AMAZON_ASN
```

Everything else (operator names, CNV package, labels) can stay at the defaults.

`CUDN_CIDR` is a **choice**, not a discovery. Check overlap:

```bash
oc get network.config/cluster -o jsonpath='Pod: {.spec.clusterNetwork[*].cidr}{"\n"}Service: {.spec.serviceNetwork[*]}{"\n"}'
# VPC CIDR is checked again in script 02
```

### 1. Cluster prepare (`01`)

**Goal:** discover router nodes / OIDC and write the AWS handoff. **Done when:** `state/handoff.env` exists (instance IDs, OIDC, ASNs, …).

```bash
./01-cluster-prepare.sh --dry-run
./01-cluster-prepare.sh --yes
```

Share `config.env` + `handoff.env` with the AWS owner if roles are split.

If you added metal **after** a previous `01` run, re-run `01` so handoff picks up new instance IDs.

### 2. AWS setup (`02`)

**Goal:** Route Server, endpoints, SG, IAM role (+ optional test client). **Done when:** `state/handback.env` has `RS_ID`, `ROLE_ARN`, route tables.

```bash
# must succeed (source config.env first, or export REGION)
aws sts get-caller-identity --region "$REGION"

./02-aws-setup.sh --dry-run --yes
# recommended for the demo:
./02-aws-setup.sh --yes --with-test-client
```

`--with-test-client` launches a small EC2 in a router subnet. It does **not** attach an
IAM instance profile (privilege decision). Use script 05 with `--ensure-ssm-profile` later.

### 3. Cluster deploy (`03`)

**Goal:** BGP operator + sessions + CUDN (+ CNV/VM unless skipped). **Done when:** BGP Established and (unless `--skip-vm`) demo VM has a CUDN IP.

```bash
./03-cluster-deploy.sh --dry-run --yes
./03-cluster-deploy.sh --yes
# networking only (no CNV / no VM):
# ./03-cluster-deploy.sh --yes --skip-vm
```

This will:

1. Install **BGP Cloud Connector** (OwnNamespace OperatorGroup)
2. Apply `BGPCloudConfiguration` (FRR rollout — expect a short network blip)
3. Wait until all BGP sessions are **Established**
4. Create demo namespace + `BGPRouting` (`spec.network.subnets`)
5. Unless `--skip-vm`: install **OpenShift Virtualization** if missing, wait for
   HyperConverged + kubemacpool webhook, create the demo VM

### 4. Verify (`04`)

**Goal:** read-only readiness check of cluster + AWS advertisement. **Done when:** operator, BGP, BGPRouting, CUDN, VM IP, IPAMClaim (and VPC route) all pass.

```bash
./04-verify.sh
```

### 5. Demo reachability (`05`)

**Goal:** prove VPC → VM L3 reachability (no Service/NAT). **Done when:** ping/curl from the VPC test client to the VM IP succeed.

From a VPC test client (not the lab bastion — it is usually in another VPC):

```bash
# one-shot ping + curl via SSM SendCommand (no session-manager-plugin required)
./05-demo-reachability.sh --yes

# first time / no IAM profile on the client:
./05-demo-reachability.sh --ensure-ssm-profile --yes

# interactive shell (needs: brew install --cask session-manager-plugin)
./05-demo-reachability.sh --shell
```

On the client (or via SendCommand output):

```bash
# e.g. 192.168.100.3
ping -c4 <VM_IP>
curl http://<VM_IP>/
```

Also show in the AWS console: **VPC → Route tables → Routes** → destination
`192.168.100.0/24`, origin **Advertisement**.

Cluster side:

```bash
# should be empty (no Service / NAT)
oc get svc -n bgp-demo
oc get vmi demo-vm -n bgp-demo -o wide
```

### 6. Cleanup (order matters)

**Goal:** remove cluster objects first, then AWS (stops Route Server $/hr). **Done when:** CRs gone and Route Server / IAM deleted; optional: metal pool deleted.

```bash
# wait for BGPCloudConfiguration finalizer
./90-cleanup-cluster.sh --yes
# deletes Route Server endpoints (stops hourly $)
./91-cleanup-aws.sh --yes

# metal pool (from bastion / rosa):
rosa delete machinepool --cluster "$CLUSTER_NAME" --machinepool virt-mp --yes
```

---

## Files

| File | Purpose |
|---|---|
| `config.env` | Choices (cluster name, CIDR, ASNs, names). Safe to share. |
| `state/handoff.env` | Cluster → AWS (generated by 01). Do not commit. |
| `state/handback.env` | AWS → cluster (generated by 02/03). Do not commit. |
| `lib/common.sh` | Logging, CIDR helpers, Route Server describe helpers |

---

## Pitfalls fixed in these scripts

Keep these in mind if you fork or debug older copies:

| Issue | Fix |
|---|---|
| AWS CLI too old / wrong binary on PATH | Need Route Server APIs; prefer Homebrew `aws` 2.41+ over stale `/usr/local/bin/aws` |
| `describe-route-server-endpoints --filters Name=route-server-id` fails | API rejects that filter; scripts filter client-side (`rs_*` helpers in `common.sh`) |
| OperatorGroup `targetNamespaces: []` | Treated as AllNamespaces; BGP Cloud Connector only supports OwnNamespace |
| CSV wait matched unrelated `Succeeded` CSVs | Wait specifically for `bgp-cloud-connector.*` |
| `BGPRouting` `spec.subnets` | CRD requires `spec.network.subnets` |
| CNV wait required `VirtualMachine` CRD before HyperConverged | Apply HCO first; VM CRDs appear after |
| VM create timed out on kubemacpool webhook | Wait for kubemacpool endpoints; retry apply on webhook errors |
| Bastion ≠ test client path | Bastion is often another VPC; use SSM to the VPC test client (`05`) |
| Session Manager plugin missing | `05` default uses SendCommand; `--shell` needs the plugin |
| `disassociate-route-server` → IncorrectState / non-deleted propagation | Disable propagation on each route table first (`91` does this now) |
| Re-running `91` while RS is `deleting`/`deleted` | Treat those states as success; delete only when still live |

---

## What the scripts refuse to do

- CUDN overlapping pod, service, or VPC CIDR
- Continuing when BGP sessions are not all Established
- Accepting a VM address outside the CUDN prefix
- Uninstalling the operator before its finalizer completes (script 90)

## Not automated on purpose

- Transit Gateway static route / Direct Connect allowed prefix for on-prem
- Attaching an SSM instance profile during `02` (use `05 --ensure-ssm-profile`)
- Reverting FRR on the cluster network (another rollout)

---

## Status

Exercised end-to-end against a live ROSA HCP lab (operator install, Route Server,
BGP sessions, CUDN advertisement, CNV + demo VM, VPC reachability via SSM).
Still **dry-run first** on any new cluster.
