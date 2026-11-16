# Direct VM Reachability on ROSA HCP with BGP Cloud Connector

A build-and-demo runbook: an OpenShift Virtualization VM on ROSA HCP, reachable from the AWS VPC — and over Direct Connect from on-prem — at its own IP, with no NAT.

> **Not yet executed against a live cluster.** Every command and manifest here is sourced and cross-checked against the operator repository, Red Hat documentation and the AWS API reference, but it has not been run end to end. Dry-run it before a customer sees it.

---

## Contents

**[Part I. Understand the architecture](#part-i-understand-the-architecture)** — read before you build, and before you talk to the customer.

- [What you will get](#what-you-will-get) · [Reading the addresses in this document](#reading-the-addresses-in-this-document)
- [Goal, in brief](#goal-in-brief) · [Support status](#support-status)
- [How the VM gets its IP, and what survives a failure](#how-the-vm-gets-its-ip-and-what-survives-a-failure)
  - [Who assigns the address](#who-assigns-the-address)
  - [What survives what](#what-survives-what)
  - [The caveat you must not gloss over](#the-caveat-you-must-not-gloss-over)
  - [Why not an address from the VPC CIDR?](#why-not-an-address-from-the-vpc-cidr)
  - [Choosing a specific address for a specific VM](#choosing-a-specific-address-for-a-specific-vm)
- [VPC and address design](#vpc-and-address-design) — address plan, subnets, route tables, the path to on-prem

**[Part II. Build it](#part-ii-build-it)** — about two hours, started a day ahead.

- [0. Variables used throughout](#0-variables-used-throughout) — includes the two-role handoff tables
- [1. Preflight (cluster)](#1-preflight-cluster) — *cluster admin*
- [2. AWS setup](#2-aws-setup) — *AWS owner*
- [3. Install the operator](#3-install-the-operator) — *cluster admin*
- [4. Configure BGP](#4-configure-bgp) — *cluster admin* · ends at **Checkpoint 1: sessions established**
- [5. Network and VM](#5-network-and-vm) — *cluster admin* · **Checkpoints 2–4: VM address, route in AWS, MTU**

**[Part III. Demonstrate it](#part-iii-demonstrate-it)**

- [6. Demo flow](#6-demo-flow) — eight beats, plus [likely questions](#likely-questions)

**[Part IV. Operate and tear down](#part-iv-operate-and-tear-down)**

- [7. Beyond the demo: production gaps](#7-beyond-the-demo-production-gaps)
- [8. Troubleshooting](#8-troubleshooting)
- [9. Cleanup](#9-cleanup) — **order matters**, see the warning there

**[Appendices](#appendices)**

- [Appendix A. Confirm the schema first](#appendix-a-confirm-the-schema-first)
- [Appendix B. Running without AWS access](#appendix-b-running-without-aws-access)
- [Sources](#sources)

---

# Part I. Understand the architecture

---

## What you will get

When you finish, you can put these on screen:

- A VM holding an address from the CUDN range you chose — `192.168.100.0/24` throughout this runbook — with **zero Kubernetes Service objects** in its namespace. Nothing is proxying for it. You do not pick the host portion; OVN-Kubernetes assigns it and you read it back with `oc get vmi demo-vm -n bgp-demo -o wide`.
- An **AWS VPC route table** containing `192.168.100.0/24`, learned dynamically over BGP and pointing at a worker node's ENI. No human wrote that route.
- `ping` and `curl` succeeding **from any EC2 instance in the VPC** straight to the VM's address.
- The VM's own web server log showing the **EC2 instance's real private IP** as the client — proof there is no NAT and that per-VM firewall rules would work.
- A **failover**: kill BGP on the advertising node and the route repoints to a healthy worker in roughly 1–2 seconds, with a few dropped pings rather than an outage.
- A VM whose **IP survives** live migration, restart, and relocation to another node.

What you will **not** have demonstrated: reachability from an actual on-prem site. That requires the customer's Direct Connect or Transit Gateway. Be precise about this distinction — see [Demo flow, beat 8](#6-demo-flow).

**AWS footprint:** one Route Server, one endpoint per AZ (~$0.75/hr each), one IAM role, one small test EC2 instance.

### Reading the addresses in this document

Three different kinds of address appear below. Mixing them up wastes time, so:

| Example | Kind | Where it comes from |
|---|---|---|
| `192.168.100.0/24` | **You choose it.** | `CUDN_CIDR` in Section 0, applied via `BGPRouting.spec.subnets` |
| `192.168.100.x` | **Assigned at runtime.** | OVN-Kubernetes picks the host portion; read it with `oc get vmi` and capture it in `$VM_IP` |
| `10.0.3.44`, `10.0.1.47`, `10.0.2.91`, `rs-…`, `vpc-…` | **Illustrative placeholders.** | Stand-ins for values from your own environment — substitute throughout |

Anything shown as `<angle-brackets>` is a placeholder you must replace. Everything else is either a shell variable set in Section 0 or a literal that should be typed as written (API group names, label keys, the CR name `cluster`).

---

## Goal, in brief

**What.** Make a VM running inside ROSA HCP reachable from outside the cluster at its own address, as though it were an ordinary host on the customer's network.

**Why it matters.** Today, reaching a VM in a managed cluster from outside means publishing a Service and hiding the VM behind a node or load-balancer address. The customer's firewalls, ACLs and audit logs then see infrastructure IPs rather than workloads, and per-VM policy is impossible. With BGP Cloud Connector the VM becomes a routable host: real source IPs, per-VM firewall rules, and failover driven by BGP instead of health checks.

**How it works.** The cluster becomes a BGP speaker. Selected worker nodes peer with an **Amazon VPC Route Server** and advertise a **ClusterUserDefinedNetwork (CUDN)** prefix into the VPC route tables. The VM lives on that CUDN. Traffic from the VPC routes natively to it via whichever worker node is currently elected; if that node fails, BGP withdraws the route and AWS repoints at a healthy one.

> ⚠️ **The VM does not get an IP from the VPC CIDR.** The CUDN is a *separate, non-overlapping* prefix that becomes routable inside the VPC. The reachability and firewalling outcomes are what the customer wants, but the IPAM story is different. The prefix can still come from their own enterprise address space and be governed by their IPAM — it just cannot be one of the VPC's associated CIDR blocks. "Why not an address from the VPC CIDR?" below explains the mechanism and how to handle the objection.

**Build order.** (1) cluster preflight and label router nodes → (2) AWS: Route Server, endpoints, propagation, security groups, IAM → (3) install the operator → (4) `BGPCloudConfiguration`, verify BGP → (5) `BGPRouting` + VM → (6) demo.

**Time.** Around 2 hours of work, but **start a day ahead**: bare-metal nodes take 30–45 minutes to join, and applying the BGP configuration triggers a cluster network rollout you must not do live.

```
EC2 client ──► VPC route table ──► worker node ENI ──► CUDN 192.168.100.0/24 ──► VM
   10.0.3.44        (learned via BGP)    (router, src/dst check off)        192.168.100.x
                            ▲
                   Amazon VPC Route Server ◄── BGP/BFD ── frr-k8s on labelled workers
```

### Support status

**GA.** The operator reached general availability at **v1.0.0** on the **`stable`** channel; `alpha` was deprecated at GA. The CRs remain `v1beta1`, which is normal for OpenShift networking operators at initial GA and does not mean Tech Preview.

One consequence that is easy to miss: the file-based catalogs ship for **OCP 4.22 and 5.0**. The code supports 4.21+, but on a 4.21 cluster the package will **not appear in OperatorHub**. Target 4.22+. Pin the exact version with `oc get packagemanifest` on the day rather than quoting one from memory.

---

## How the VM gets its IP, and what survives a failure

This is the question customers ask immediately after they see the demo, so it is worth being able to answer precisely.

### Who assigns the address

Nothing in AWS is involved. The chain is entirely inside the cluster:

1. **You** choose the CUDN subnet in `BGPRouting.spec.subnets` (here `192.168.100.0/24`).
2. The operator creates a **ClusterUserDefinedNetwork** with `topology: Layer2`, `role: Primary` and `ipam.lifecycle: Persistent`.
3. **OVN-Kubernetes IPAM** allocates an address from that subnet to the VM's logical switch port when the `virt-launcher` pod is created.
4. **KubeVirt** creates an **`IPAMClaim`** (`ipamclaims.k8s.cni.cncf.io`) for the VM, and OVN-Kubernetes writes the allocated IP and MAC into that claim.
5. **OVN's built-in DHCP server** answers the guest on the Layer 2 logical switch, so the VM configures its interface normally via DHCP. There is no DHCP server for you to run.

The `IPAMClaim` is the important object: the allocation belongs to the **VM**, not to the pod. Whenever a new `virt-launcher` pod is created for that VM, OVN-Kubernetes reads the existing claim and reuses the same address.

```bash
# The claim is what makes the address durable. If no claim exists, the VM is not really on
# the CUDN and its address will change on the next restart — worth checking before you
# promise a customer that the IP is stable.
oc get ipamclaims -n bgp-demo -o wide

# status.ips is written by OVN-Kubernetes, never by you. This is the authoritative record of
# what the VM gets back after a migration, restart or relocation.
oc get ipamclaims -n bgp-demo -o jsonpath='{.items[0].status.ips}{"\n"}'
```

### What survives what

| Event | VM's IP | Why |
|---|---|---|
| **Live migration** (planned, e.g. node drain) | **Unchanged**, no interruption | Layer2 + Persistent IPAM is exactly the supported live-migration path; OVN keeps gateway IP/MAC consistent across nodes with ARP proxy and point-to-point routing |
| **VM restart / stop-start** | **Unchanged** | `IPAMClaim` outlives the pod |
| **BGP router node fails** (not hosting the VM) | **Unchanged** — the VM is not involved at all | Only the *path* changes: BGP withdraws, Route Server repoints the VPC route table at a healthy node |
| **Node hosting the VM fails hard** | **Unchanged once the VM is running again** — but see the caveat below | `IPAMClaim` is reused on the new node |
| *(For contrast)* VM on the **default pod network** | **Changes** | No persistent IPAM; a new pod means a new address |

That last contrast row is the strongest single argument for this design, and worth saying out loud.

### The caveat you must not gloss over

**KubeVirt does not automatically relocate a VM off a hard-failed node by default.** When a node goes `NotReady`, the VMI stays `Running` and the `virt-launcher` pod stays `Terminating` — deliberately. KubeVirt cannot tell whether the VM on the unreachable node is still alive and writing to shared storage, so starting a second copy risks split-brain and data corruption. Nothing moves until the node returns or is **fenced**.

To get automatic recovery you need node health checking and fencing — machine health checks on the machine pool, or the Node Health Check and Self Node Remediation operators. Once that is in place and the VM is rescheduled, `runStrategy: Always` restarts it and the `IPAMClaim` gives it the same address on the new node.

So the accurate customer answer is two sentences, not one: *"The address belongs to the VM, not to the node, so it is preserved across migration, restart and relocation. Automatic relocation after an unplanned node loss is a separate capability — node health checking and fencing — which you configure once at the cluster level."*

Claiming seamless automatic VM failover without that second sentence will not survive the customer's first real node failure.

### Why not an address from the VPC CIDR?

Customers ask this immediately. There are three reasons, and the third one usually turns the objection into a non-issue.

**1. VPC routing would shadow it.** Every route table carries a `local` route for the VPC CIDR that cannot be deleted, and AWS prefers it over propagated routes that overlap it — **even when the propagated route is more specific**. A Route Server advertisement is a propagated route, so a CUDN prefix inside the VPC CIDR would lose to `local`; traffic would be handed to the VPC fabric, which would ARP for an address no ENI owns, and blackhole. (The one documented way to beat `local` is a *static* route whose destination exactly matches a full subnet CIDR and targets a NAT gateway, ENI, or Gateway Load Balancer endpoint — the middlebox-inspection feature, which is not what BGP propagation does.)

**2. No ENI owns the address.** Inside the VPC CIDR, addresses belong to EC2's IPAM and are reachable because they are bound to an ENI. The VM's address lives on an OVN logical switch; no ENI holds it. There is also no way to reserve part of a subnet against EC2 allocation, so you would have two allocators — EC2 and OVN-Kubernetes — independently handing out the same range.

**3. It is the consequence of choosing an overlay.** VPC-native workload addressing is what the AWS VPC CNI does on EKS: every pod IP is a secondary IP on a node ENI, consuming VPC address space and bounded by per-instance ENI/IP quotas. OVN-Kubernetes with Geneve plus BGP takes the opposite approach — keep workloads in an overlay, then make that overlay routable by advertising the prefix.

**The reframe.** The CUDN prefix does not have to be arbitrary. It can come from the customer's enterprise address space, be governed by their IPAM, appear in their CMDB, and route from on-prem over Direct Connect. The only hard rule is that it must not be one of the VPC's **associated CIDR blocks** — and they must not later add it as a secondary CIDR on that VPC, which would create a `local` route and break the whole design.

So when a customer says *"we want VM addresses from our VPC range"*, find out what sits underneath it. If they mean addresses their network team governs, that their firewalls recognise, that route from the data centre — yes, fully satisfiable. If they mean literally inside the VPC CIDR association, that is out of scope for this architecture and no configuration gets there.

### Choosing a specific address for a specific VM

Two different asks get confused here. Separate them before answering a customer.

**"The VM must always have the same address."** Already solved, with no extra configuration. The `IPAMClaim` makes the first allocation permanent for the life of the VM. Let OVN assign it, read it once with `oc get vmi ... -o wide`, then record it in DNS, the CMDB and firewall rules. For the overwhelming majority of requirements — stable addressing so policy and monitoring work — this is the answer, and it is the boring, supported one.

**"We need to choose *which* address."** Harder, and worth checking before you promise it.

- The `IPAMClaim`'s `status.ips` is written by the controller, not by you. There is no documented, supported procedure for hand-creating a claim with a chosen address to pin a VM on a **primary** UDN. *(An earlier draft of this runbook suggested otherwise — that was wrong.)*
- The mechanism that does exist upstream is **preconfigured UDN addresses**: KubeVirt declares the desired addresses on the VM via a `network.kubevirt.io/addresses` annotation, which OVN-Kubernetes ties to the VM's IPAM claim, and the address then survives restart and migration. It sits behind a **feature gate** (`PreconfiguredUDNAddresses`).
- On **managed ROSA HCP you most likely cannot enable that feature gate** — cluster feature sets are generally not customer-modifiable on managed clusters. Confirm with Red Hat before committing to a chosen-address design.
- `excludeSubnets` on a UDN/CUDN is the clean way to carve out a block for manual assignment, but it is unlikely to help here: the CUDN is **generated and owned by the operator** from `BGPRouting`, which exposes only `network.name` and `subnets`, and UDN/CUDN objects **cannot be modified after creation**. Hand-editing the generated CUDN will be reconciled away. Check whether your operator version passes the field through:
  ```bash
  oc explain bgprouting.spec --recursive | grep -i exclude
  ```

**Practical guidance.** If the customer's real requirement is migrating VMs that on-prem systems reference by a fixed IP, raise it as a design question early rather than assuming it is a configuration detail. The achievable shape today is: choose the CUDN prefix to match the range those VMs already live in, accept operator-assigned addresses within it, and reconcile DNS — not: reproduce each VM's exact original address.

---

## VPC and address design

Plan this before building anything. Most of the painful failures in this architecture are address-plan or route-propagation mistakes, and several of them cannot be corrected without recreating objects.

### The decision you are actually making

"VMs with IPs at VPC level" resolves into one of two architectures. Pick deliberately:

| | **Overlay + BGP** (this runbook) | **VPC-native workload IPs** |
|---|---|---|
| Where the VM's IP comes from | A CUDN prefix you own, outside the VPC CIDR | The VPC CIDR itself |
| Mechanism | OVN overlay, prefix advertised to a Route Server | Each address is a secondary IP on a node ENI (AWS VPC CNI style) |
| VPC address consumption | Nodes, load balancers and endpoints only | Every workload consumes a VPC address |
| Scale limit | Route Server advertised-route quotas | ENI / IPs-per-instance quotas |
| Available on ROSA with OVN-Kubernetes | **Yes** | No |

ROSA gives you the left column. A useful side effect: because pods and VMs do **not** consume VPC addresses, your VPC subnets stay small — sized for nodes, LBs and VPC endpoints rather than for workload count. That is the opposite of EKS sizing instincts, and it frees you to spend address space on the CUDN side instead.

### Which ranges must be globally unique

A ROSA cluster running this architecture consumes four distinct ranges:

| Range | Visible outside the cluster? | Uniqueness requirement |
|---|---|---|
| **VPC CIDR** | Yes — advertised to TGW/DX | Unique across the customer's entire routing domain |
| **CUDN prefix(es)** | Yes — advertised via Route Server | Unique across the entire routing domain, **and** never associated to the VPC |
| Pod network | No (unless you choose to advertise it) | Unique within the cluster's reachability scope |
| Service network | No | Same |

Treat the pod and service networks as "unique anyway". The cost of picking globally unique values on day one is zero; the cost of discovering a collision after the customer has three clusters and a Transit Gateway is a renumbering project.

**Allocate from one summarizable block per cluster.** Give each cluster a contiguous parent range and carve the VPC and CUDN prefixes out of it, so on-prem sees one or two summary routes per cluster rather than a growing list. Route table and allowed-prefix entries are finite resources.

### Rules that cannot be broken

- The CUDN prefix **must not overlap** the VPC CIDR, pod CIDR, service CIDR, any other cluster sharing the routing domain, or anything on-prem.
- The CUDN prefix **must never be associated to the VPC** as a CIDR block, now or later. Doing so creates a `local` route that silently wins over the BGP-propagated route and breaks reachability. Record the prefix as reserved in the customer's IPAM with that reason attached.
- Conversely, once the CUDN prefix is in the VPC route tables, AWS will refuse a future VPC CIDR association that is the same as or larger than it. Your advertisement constrains later VPC growth — plan the VPC's eventual size now.
- UDN/CUDN objects **cannot be modified after creation**, and the CUDN here is generated and owned by the operator. Changing the prefix means deleting and recreating the `BGPRouting` and everything attached to it.

### Subnet layout

- **Three AZs** if the customer cares about the resilience story; two is the practical minimum for the BGP failover demo. One AZ means no failover to show.
- **Dedicated Route Server endpoint subnets**, one small subnet per AZ. Endpoints can live in the worker subnets, but separating them keeps security group scoping and IPAM auditing clean, and makes the BGP infrastructure visible in the topology rather than hidden among worker ENIs.
- **A metal worker subnet per AZ** for the OpenShift Virtualization pool. Metal instances are large and few; these subnets stay small.
- Keep the worker subnets sized for nodes plus LB and VPC endpoint ENIs, not for workloads.

### Route tables are your reachability control

Route Server propagation is enabled **per route table**. That makes it the cleanest place to express "which parts of the VPC may reach the VMs":

- Enable propagation only on route tables whose subnets genuinely need to reach the CUDN.
- Leaving it off is a legitimate segmentation decision, not an oversight — document which tables have it and why.
- Route Server does **not** support route tables associated with a virtual private gateway.

### Getting the prefix to on-prem — the part that is not automatic

The runbook demonstrates VPC ↔ VM. Extending to the data centre has two steps that catch people out, because neither happens by itself:

1. **Transit Gateway does not learn the CUDN prefix.** A VPC attachment propagates only the **VPC's own CIDR blocks** into the TGW route table. The CUDN prefix lives behind the VPC, so it is never learned. You must add a **static route** in the TGW route table: destination = CUDN prefix, target = the VPC attachment.
2. **Direct Connect does not advertise it either.** For a DX gateway associated with a Transit Gateway, **only the prefixes in the allowed-prefixes list are advertised on-premises**. Add the CUDN prefix (or a summary covering it) to that list.

Two consequences worth raising with the customer's network team:

- **A VGW-based Direct Connect design is a dead end here.** Route Server cannot propagate into VGW-associated route tables, and a DX gateway already associated with a VGW or a private VIF cannot be attached to a Transit Gateway. The supported shape is DX → DX gateway → **Transit Gateway** → VPC, with a transit VIF.
- **Allowed prefixes are advertised whether or not anything can deliver them.** A prefix in that list appears on the on-premises router even if the TGW route table has no path to it — a blackhole that looks like a cluster problem. Add the TGW static route *before* the allowed prefix, not after.

Return traffic needs the same attention: for on-prem to be reachable *from* the VM, the cluster must learn those prefixes. See Section 7.

### Multiple clusters and multiple tenants

- Several clusters can share one VPC Route Server. The operator tags its peers `managed-by: bgp-cloud-connector/<infrastructureName>` and adopts pre-existing peers rather than duplicating them, so they do not fight.
- Each cluster still needs its **own non-overlapping CUDN prefix**.
- Each tenant network means another `BGPRouting`, another prefix, and another advertised route. Multi-tenant designs grow the route count quickly — check Route Server quotas for endpoints, peering sessions and advertised routes against the planned tenant count, and summarize where you can.

### Where security policy lives

- **Per-VM policy belongs in the cluster** — UDN-aware NetworkPolicy and AdminNetworkPolicy. Security groups cannot express it usefully, because VM traffic is forwarded by worker nodes rather than originating from a VM-specific ENI.
- **On-prem and VPC firewalls can filter per VM**, because there is no NAT and the VM's real address is on the wire. This is the whole point of the architecture — make sure the customer's security team knows they get this back.
- **Network ACLs are stateless.** If the customer uses NACLs on the relevant subnets, both directions must permit the CUDN prefix. This is a classic one-way-traffic cause.
- The router nodes have **source/destination check disabled** and forward traffic for a prefix they do not own. Document this; it will come up in a security review, and the honest framing is that these nodes are deliberately acting as routers.

### A worked example

Enterprise supernet `10.64.0.0/12`, one `/18` per cluster:

| Purpose | Example | Notes |
|---|---|---|
| Cluster parent block | `10.64.0.0/18` | Summarized to on-prem as a single route |
| VPC CIDR | `10.64.0.0/20` | Nodes, LBs, endpoints — small by design |
| Route Server endpoint subnets | `10.64.0.0/24` split /27 per AZ | Carved from the VPC CIDR |
| CUDN — production VMs | `10.64.16.0/22` | Advertised; never associated to the VPC |
| CUDN — second tenant | `10.64.20.0/22` | Another `BGPRouting` |
| Reserved for growth | `10.64.24.0/21` | Keeps the summary intact |
| Pod network | `10.128.0.0/14` (default) | Cluster-internal |
| Service network | `172.30.0.0/16` (default) | Cluster-internal |

On-prem then needs one allowed prefix (`10.64.0.0/18`) and the TGW one static route per advertised CUDN prefix. Adding a tenant later means a new CUDN prefix inside the reserved space, one TGW static route, and no change on-premises.

---

# Part II. Build it

Sections 1, 3, 4 and 5 are run by the **cluster admin**; Section 2 by the **AWS owner**. The ordering is cluster → AWS → cluster, because the AWS discovery reads node labels that only exist after Section 1.

---

## 0. Variables used throughout

Set these once in each shell.

```bash
export CLUSTER="<rosa-cluster-name>"
export REGION="<aws-region>"

# Chosen by you, never discovered. Must sit outside the VPC CIDR, or the VPC's undeletable
# local route shadows the BGP advertisement and traffic blackholes. Changing it later means
# recreating the BGPRouting and everything attached to it, so decide now.
export CUDN_CIDR="192.168.100.0/24"

# The two ASNs must differ — identical values make this iBGP, which is not what the Route
# Server expects. Both are from the private ASN range so they carry no meaning off-site.
export AMAZON_ASN=64512      # AWS side
export CLUSTER_ASN=65001     # OpenShift side
```

**Splitting the work.** Section 2 needs EC2 + IAM write access. But step 2.1 also calls `oc` and `rosa`, so it is not cleanly delegable — if a colleague owns AWS, **you** run the cluster commands in 2.1 and hand over the results:

| You produce (cluster side) | They need it for |
|---|---|
| Router node **instance IDs** (`oc get nodes ... providerID`) | Subnet / VPC / SG discovery |
| **OIDC issuer** (`rosa describe cluster`, or `oc get authentication.config/cluster`) | IAM trust policy |
| Chosen **CUDN CIDR** and **cluster ASN** | Overlap check, Route Server ASN |

| They hand back | You need it for |
|---|---|
| `RS_ID`, `REGION` | `BGPCloudConfiguration` (Section 4) |
| `ROLE_ARN` | Operator Subscription (Section 3) |
| Test EC2 **private IP + access method** | The demo itself (Section 6) |

**Minimum access you personally need on demo day:** a shell on the test EC2 instance, and either AWS read access or a pre-captured screenshot of the VPC route table. Demo beat 3 shows the learned route from the AWS side — with no AWS visibility you lose the single most persuasive moment.

---

## 1. Preflight (cluster)

```bash
oc login https://api.<cluster-domain>:6443 -u <admin>

# Expect 4.22+. The operator's catalog ships only for 4.22 and 5.0, so on 4.21 you would get
# all the way to Section 3 before finding the package simply does not exist in OperatorHub.
oc get clusterversion

# Must report AWS. The platform type is what makes `spec.platform: AWS` legal later; without
# it the operator has no cloud API to discover Route Server endpoints from.
oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}{"\n"}'

# No OpenShift Virtualization means no VM to demonstrate. Check before spending 40 minutes
# waiting for metal nodes you might not be able to use.
oc get csv -n openshift-cnv | grep -i kubevirt

# Compare both against CUDN_CIDR. An overlap does not fail at apply time — it fails later as
# unexplained traffic loss, which is far more expensive to diagnose than this one command.
oc get network.config/cluster -o jsonpath='Pod: {.spec.clusterNetwork[*].cidr}{"\n"}Service: {.spec.serviceNetwork[*]}{"\n"}'

# CNV on ROSA requires bare metal. Two AZs is the minimum that gives you a failover story;
# with a single AZ, demo beat 6 has nowhere to fail over to.
oc get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
```

No metal pool yet:

```bash
# Why each flag:
#   --replicas 2            minimum Red Hat supports for CNV workloads, and gives the
#                           failover demo a second node to move the route to
#   --instance-type *.metal CNV on ROSA requires bare metal; the virtualised default pool
#                           cannot run VMs
#   --ec2-metadata-http-tokens required  IMDSv2. Set at creation because instance metadata
#                           options cannot be changed once the pool exists
#   --labels bgp_router=true  applied at pool level so it survives node replacement; an
#                           `oc label` would be lost and silently drop the node from BGP
rosa create machinepool --cluster "$CLUSTER" --name virt-mp \
  --replicas 2 --instance-type m5zn.metal --ec2-metadata-http-tokens required --labels bgp_router=true
```

> Metal nodes take **30–45 minutes** to join. A **machine pool** label survives node replacement; `oc label node` does not.

**Label the router nodes now** — step 2.1 discovers your AWS subnets from these labels, so this must precede all AWS work. At least one metal node per AZ:

```bash
# This label does double duty: routerNodeSelector matches it in Section 4, and step 2.1 reads
# it to work out which AWS subnets need Route Server endpoints. That second use is why
# labelling cannot wait until after the AWS work.
oc label node <metal-node-az-a> bgp_router=true
oc label node <metal-node-az-b> bgp_router=true

# Expect one node per AZ: each router node peers with the Route Server endpoint in its own
# zone, so a second node in the same AZ adds cost without adding resilience.
oc get nodes -l bgp_router=true -L topology.kubernetes.io/zone
```

Existing pool instead of ad-hoc labels:

```bash
# Prefer this over `oc label` for anything beyond a throwaway demo: when ROSA replaces a node
# the new Node object is created fresh, so ad-hoc labels vanish and the node quietly stops
# being a BGP router — with no error anywhere to tell you.
rosa edit machinepool --cluster "$CLUSTER" <pool-name> --labels bgp_router=true
```

---

## 2. AWS setup

### 2.1 Discover VPC, subnets, security group

Create Route Server endpoints only where BGP router nodes actually run — each endpoint bills hourly.

```bash
# Needed to build the role ARN by hand later, because create-role does not print it in a
# form that is convenient to reuse.
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# The OIDC issuer identifies the cluster to AWS IAM. It is the one value in the trust policy
# that ties the role to *this* cluster rather than any cluster in the account.
export OIDC=$(rosa describe cluster -c "$CLUSTER" -o json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|^https://||')

# Fallback when the rosa CLI is unavailable — the cluster knows its own issuer. Useful
# because the person with AWS access often does not have the rosa CLI configured.
# export OIDC=$(oc get authentication.config/cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')

# Fail here rather than silently writing a malformed trust policy that only breaks in
# Section 4 as CloudCredentialsInvalid.
echo "OIDC=$OIDC"

# providerID is the only place the Node object records its EC2 instance ID, which is the key
# that joins the cluster view to the AWS view. awk takes the last path segment.
export INSTANCE_IDS=$(oc get nodes -l bgp_router=true \
  -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | awk -F/ '{print $NF}')
echo "router instances: $INSTANCE_IDS"

# Human-readable overview before anything is created — confirms the nodes really are spread
# across AZs, which the whole failover story depends on.
aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].[InstanceId,SubnetId,VpcId,SecurityGroups[0].GroupId,Placement.AvailabilityZone]' \
  --output table

# Only these subnets get a Route Server endpoint. Deriving them from the nodes, rather than
# using every cluster subnet, avoids paying ~$0.75/hr for endpoints nothing peers with.
export ROUTER_SUBNETS=$(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].SubnetId' --output text | tr '\t' '\n' | sort -u)

# All router nodes are in one VPC by definition, so reading it from the first is safe.
export VPC_ID=$(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[0].Instances[0].VpcId' --output text)

# Unlike the VPC, this is an assumption: it takes the first node's group. The check at the
# end of this block tells you whether that assumption holds.
export WORKER_SG=$(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)

# Needed both as the source range for the security group rules and for the overlap check
# against CUDN_CIDR.
export VPC_CIDR=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text)

echo "VPC=$VPC_ID CIDR=$VPC_CIDR SG=$WORKER_SG"
echo "subnets: $ROUTER_SUBNETS"

# More than one line of output here means $WORKER_SG covers only some of your router nodes,
# and the BGP sessions on the others will never come up.
aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort -u
```

> **Confirm `$CUDN_CIDR` does not overlap `$VPC_CIDR`.** The most common silent failure.

> **If that last command returns more than one security group**, your router nodes are not all in the same group — apply the Section 2.3 rules to each of them, not just `$WORKER_SG`. This happens when router nodes come from different machine pools.

### 2.2 Route Server, association, propagation, endpoints

```bash
# --persist-routes disable: routes are withdrawn the moment a session drops, which is what
#   makes the failover in demo beat 6 visible rather than delayed by up to five minutes.
#   Enable it in production if you would rather ride out brief control-plane blips.
# --tag-specifications: the Name tag is how you find this Route Server again at cleanup,
#   and how colleagues know it is not stray infrastructure.
export RS_ID=$(aws ec2 create-route-server --region "$REGION" \
  --amazon-side-asn "$AMAZON_ASN" --persist-routes disable \
  --tag-specifications 'ResourceType=route-server,Tags=[{Key=Name,Value=rosa-bgp-demo}]' \
  --query 'RouteServer.RouteServerId' --output text)

# The waiter may not exist in older CLI versions, hence the fallback sleep — associating a
# Route Server that is still `pending` fails.
aws ec2 wait route-server-available --region "$REGION" --route-server-ids "$RS_ID" 2>/dev/null || sleep 60

# Association is what scopes the Route Server to this VPC. Without it the endpoints below
# have nothing to attach to.
aws ec2 associate-route-server --region "$REGION" --route-server-id "$RS_ID" --vpc-id "$VPC_ID"

# propagate into every route table that serves subnets — including the VPC main route table,
# which serves any subnet with no explicit association (easy to miss, and a likely home for a
# hand-created test client subnet)
export ROUTE_TABLES=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[?Associations[?SubnetId!=null || Main==`true`]].RouteTableId' \
  --output text)
echo "route tables: $ROUTE_TABLES"

# Propagation is per route table, and it is effectively the switch for "may these subnets
# reach the VMs". A route table without it will never see the CUDN prefix no matter how
# healthy BGP is — the most common cause of "sessions are up but nothing is reachable".
for RTB in $ROUTE_TABLES; do
  aws ec2 enable-route-server-propagation --region "$REGION" --route-table-id "$RTB" --route-server-id "$RS_ID"
done

# One endpoint per router subnet, because a worker peers only with the endpoint in its own
# AZ. A missing endpoint means that AZ's node never establishes a session and contributes
# nothing to resilience.
for SUBNET in $ROUTER_SUBNETS; do
  aws ec2 create-route-server-endpoint --region "$REGION" --route-server-id "$RS_ID" --subnet-id "$SUBNET"
done
```

Endpoints take **2–3 minutes** to go from `pending` to `available`. Block until they are ready rather than reading a one-shot `describe` and moving on:

```bash
# One endpoint was requested per router subnet, so that count is what "finished" means.
EXPECTED=$(echo "$ROUTER_SUBNETS" | wc -w)

# 40 × 15s = 10 minutes, generously more than the usual 2–3. Counting endpoints that ARE
# available (rather than ones that are not) matters: if creation failed outright there are
# zero endpoints, zero non-available, and the naive test would pass instantly.
for i in $(seq 1 40); do
  READY=$(aws ec2 describe-route-server-endpoints --region "$REGION" \
    --filters "Name=route-server-id,Values=$RS_ID" \
    --query 'length(RouteServerEndpoints[?State==`available`])' --output text)
  [ "$READY" -ge "$EXPECTED" ] && break
  echo "waiting for endpoints: $READY/$EXPECTED available"
  sleep 15
done

# Always read the table afterwards — the loop exits quietly on timeout, and EniAddress is
# the peer address the cluster will talk to, so it is worth seeing with your own eyes.
aws ec2 describe-route-server-endpoints --region "$REGION" \
  --filters "Name=route-server-id,Values=$RS_ID" \
  --query 'RouteServerEndpoints[].[RouteServerEndpointId,SubnetId,EniAddress,State]' --output table
```

> The loop counts endpoints that *are* `available` against the number expected, rather than counting ones that are *not* — otherwise a failed creation yields zero endpoints, zero non-available, and an instant false pass.

> `persist-routes disable` keeps the failover demo visually immediate. Route Server does **not** support route tables associated with a virtual private gateway. Note that Route Server propagates into **VPC route tables only** — getting the prefix onward to a Transit Gateway needs a static route, and onward to on-prem needs a DX allowed prefix. See [VPC and address design](#vpc-and-address-design).

### 2.3 Security group rules

```bash
# tcp/179  BGP itself. Without it sessions sit in Active/Connect forever.
# udp/3784 BFD. Required because Section 4 sets livenessDetection: bfd — omit this and the
#          peers never establish at all, which looks like an operator fault.
# icmp     ping for the demo, and — more importantly — the "fragmentation needed" messages
#          that path MTU discovery depends on (see Checkpoint 4).
# tcp/80   the demo web server.
# Source is the whole VPC CIDR because the Route Server endpoint ENIs take addresses from it
# and you do not know which ones in advance.
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$WORKER_SG" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=179,ToPort=179,IpRanges=[{CidrIp=$VPC_CIDR,Description='BGP'}]" \
    "IpProtocol=udp,FromPort=3784,ToPort=3784,IpRanges=[{CidrIp=$VPC_CIDR,Description='BFD'}]" \
    "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=$VPC_CIDR,Description='demo ICMP'}]" \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$VPC_CIDR,Description='demo HTTP'}]"
```

**Asymmetric return traffic.** Add this only if something VM-*initiated* fails while inbound works:

```bash
# The ephemeral port range, because the reply to a VM-initiated flow arrives as an unsolicited
# inbound packet on a node that never saw the outbound half, so no stateful entry matches it.
# Deliberately not applied by default: this is a wide opening on a worker security group and
# the inbound-only demo does not need it.
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$WORKER_SG" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=32768,ToPort=60999,IpRanges=[{CidrIp=$VPC_CIDR,Description='async return TCP'}]" \
    "IpProtocol=udp,FromPort=32768,ToPort=60999,IpRanges=[{CidrIp=$VPC_CIDR,Description='async return UDP'}]"
```

Why: a VM-initiated flow leaves via the node hosting the VM, but the reply returns to whichever node the route table currently elects. If those differ, the reply lands on an ENI with no stateful entry and is dropped. This is a real widening of the worker SG — have the justification ready rather than adding it silently.

### 2.4 IAM role (CCO/STS)

```bash
export ROLE_NAME="bgp-cloud-connector-demo"

# Unquoted heredoc (<<EOF) so ${ACCOUNT} and ${OIDC} expand — the trust policy has to name
# this specific cluster's OIDC provider.
cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC}:aud": ["openshift", "sts.amazonaws.com"],
        "${OIDC}:sub": "system:serviceaccount:openshift-bgp-cloud-connector:openshift-bgp-cloud-connector-controller-manager"
      }
    }
  }]
}
EOF
# aud: "openshift" is what the Cloud Credential Operator mints tokens with; "sts.amazonaws.com"
#   covers the pod-identity-webhook path. Listing both means either mechanism works.
# sub: pins the role to one ServiceAccount, so a different workload in the cluster cannot
#   assume it. This exact string must match `oc get sa -n openshift-bgp-cloud-connector`,
#   and a mismatch is the single most common cause of CloudCredentialsInvalid.

# Quoted heredoc (<<'EOF') so nothing expands — this document contains no variables and
# $-signs in policy JSON should never be touched by the shell.
cat > /tmp/policy.json <<'EOF'
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
# Why each group:
#   GetCallerIdentity          the operator's own credential self-test; failure here is what
#                              surfaces as CloudCredentialsInvalid
#   Describe*                  discovery. The operator is given only Route Server IDs and
#                              derives endpoints, neighbour addresses, remote ASN and the
#                              subnet-to-AZ mapping from these calls
#   Create/DeleteRouteServerPeer  the actual peering lifecycle, including cleanup on delete
#   Authorize/RevokeSecurityGroupIngress  AWS requires these for peer create/delete even
#                              though the operator's published policy omits them
#   CreateTags                 peers are tagged managed-by:bgp-cloud-connector/<cluster>, which
#                              is how several clusters share one Route Server without clashing
#   ModifyNetworkInterfaceAttribute  disables source/destination check so a worker may forward
#                              traffic for an address it does not own. Note: the *network
#                              interface* call, not ModifyInstanceAttribute
# Resource "*" is demo-grade. For production, scope the write actions to
# route-server-endpoint/*, route-server-peer/* and network-interface/*.

aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file:///tmp/trust.json
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name bgp-cloud-connector --policy-document file:///tmp/policy.json

# Composed by hand rather than parsed from the create-role output, so this still works when
# the role already existed and create-role was a no-op.
export ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# These two values are the entire hand-back to the cluster admin — send them both.
echo "RS_ID=$RS_ID"; echo "ROLE_ARN=$ROLE_ARN"
```

Notes. The audience is `openshift` because credentials flow through the Cloud Credential Operator STS path (`ROLEARN`), not the EKS-style pod-identity webhook; listing both covers either. `ec2:ModifyNetworkInterfaceAttribute` — **not** `ModifyInstanceAttribute` — is what disables source/destination check. The security-group actions are required by AWS for Route Server peer create/delete. `Resource: "*"` is demo-grade; scope it for production.

**Verify the ServiceAccount name matches the trust policy** after installing the operator — a mismatch is the top cause of `CloudCredentialsInvalid`:

```bash
# The name printed here must equal the `sub` string in the trust policy above. The operator
# does not validate this for you; a mismatch only shows up in Section 4 as a credentials
# failure with no hint about which half is wrong.
oc get sa -n openshift-bgp-cloud-connector
```

### 2.5 Test client

A small Amazon Linux 2023 instance in a VPC subnet whose route table got propagation in 2.2.

**Access.** If it sits in a private subnet with no public IP and you have no bastion, use **SSM Session Manager** rather than SSH — no keys, no inbound port 22:

```bash
# Preferred over SSH for a demo box: no key material to manage, no inbound port 22, and it
# works on an instance with no public IP — which is where a realistic test client belongs.
aws ssm start-session --region "$REGION" --target <instance-id>
```

> SSM needs the agent running (preinstalled on AL2023) and an instance profile with `AmazonSSMManagedInstanceCore`. In a private subnet with no NAT gateway it additionally needs VPC interface endpoints for `ssm`, `ssmmessages` and `ec2messages` — otherwise the session simply will not connect. Verify access days before the demo.

**Tools.** `ping` and `curl` are present; `traceroute` usually is not:

```bash
# Worth having: traceroute is what shows the customer the packet entering via a worker node
# rather than some load balancer, which is hard to argue with.
sudo dnf install -y traceroute
```

---

## 3. Install the operator

```bash
# Check availability before writing a Subscription. A Subscription naming a package that is
# not in the catalog sits in ResolutionFailed rather than erroring, so you would otherwise
# spend time debugging OLM instead of noticing the cluster is simply too old.
oc get packagemanifests -n openshift-marketplace | grep -i bgp
```

If nothing appears, check the cluster version — the catalogs ship for 4.22 and 5.0 only.

```bash
# Unquoted heredoc so ${ROLE_ARN} expands — the Subscription must carry the real ARN.
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  # This exact name matters: it is half of the `sub` in the IAM trust policy. Installing the
  # operator anywhere else silently invalidates the role you just created.
  name: openshift-bgp-cloud-connector
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-bgp-cloud-connector
  namespace: openshift-bgp-cloud-connector
spec:
  # Empty list = all-namespaces scope. The operator manages cluster-scoped objects
  # (BGPCloudConfiguration, CUDNs), so limiting it to one namespace would break it.
  targetNamespaces: []
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: bgp-cloud-connector
  namespace: openshift-bgp-cloud-connector
spec:
  # `stable` carries v1.0.0 onward. `alpha` was deprecated at GA and is frozen — subscribing
  # to it would strand you on an old build.
  channel: stable
  name: bgp-cloud-connector
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  # Automatic is fine for a demo. For production, Manual lets you review the InstallPlan
  # before a network-affecting operator upgrades itself.
  installPlanApproval: Automatic
  config:
    env:
      # How the operator learns which IAM role to assume. Without it the controller starts
      # cleanly and only fails later, when it first calls the EC2 API.
      - name: ROLEARN
        value: "${ROLE_ARN}"
EOF
```

```bash
# CSV must reach Succeeded and the controller pod must be Running before the CR in Section 4
# will be reconciled at all — an unreconciled CR looks identical to a broken one.
oc get csv,pods -n openshift-bgp-cloud-connector
```

> `stable` is the right channel post-GA; `alpha` is deprecated and frozen.
> Console installs prompt for the role ARN automatically (the CSV declares `features.operators.openshift.io/token-auth-aws`).
> If you change the role ARN or trust policy **after** install, restart the controller — the token is injected only at pod creation:
> ```bash
> # The web identity token is injected into the pod at creation time only, so an existing pod
> # keeps using the old credentials indefinitely. Restarting is the whole fix.
> oc rollout restart deployment/openshift-bgp-cloud-connector-controller-manager -n openshift-bgp-cloud-connector
> ```

---

## 4. Configure BGP

```bash
# Re-check rather than assume: if a node was replaced between Section 1 and now, an ad-hoc
# label is gone and that AZ will quietly have no BGP speaker.
oc get nodes -l bgp_router=true -L topology.kubernetes.io/zone
```

```bash
# Unquoted heredoc so the ASN, region and Route Server ID expand.
cat <<EOF | oc apply -f -
apiVersion: networking.openshift.io/v1beta1
kind: BGPCloudConfiguration
metadata:
  # Must be exactly "cluster" — this is a cluster-scoped singleton and any other name is
  # ignored by the controller rather than rejected, which is a confusing way to lose an hour.
  name: cluster
spec:
  # Selects which cloud block is required and rejects the others (CEL-enforced). AWS makes
  # spec.aws mandatory and spec.bgp.peerGroups forbidden.
  platform: AWS
  # Decides which nodes become BGP routers. Must match the label from Section 1; an empty
  # match means no peers and no advertisement, with no obvious error.
  routerNodeSelector:
    bgp_router: "true"
  bgp:
    # Must differ from the Amazon-side ASN, otherwise the session is iBGP.
    localASN: ${CLUSTER_ASN}
    # bfd detects a dead peer in ~1s instead of tens of seconds on BGP keepalives — the
    # difference between a crisp failover demo and dead air. Needs UDP/3784 open (2.3).
    livenessDetection: bfd
  aws:
    region: ${REGION}
    # Note the capital ID. This is the only AWS input the operator needs: endpoint addresses,
    # the subnet-to-AZ mapping and the remote ASN are all discovered and written to
    # status.peerGroups, which is why the IAM policy needs those Describe calls.
    routeServerIDs:
      - ${RS_ID}
EOF
```

Cluster-scoped singleton, **must** be named `cluster`. `routeServerIDs` carries a capital `ID`. Only `region` and `routeServerIDs` are supplied — endpoint addresses, AZ mapping and remote ASN are discovered into `status.peerGroups`.

> ⚠️ **This triggers a cluster network operator rollout** (it patches `Network.operator.openshift.io/cluster` to enable FRR). Expect brief disruption. Never do this live in front of a customer.

> `livenessDetection: bfd` (vs the `bgp-keepalive` default) is what makes failover crisp. Expect roughly 1–2 seconds on a hard failure — "sub-second" needs tuned timers. Fall back to `bgp-keepalive` if peers will not establish.

### Checkpoint 1 — sessions established

```bash
# Conditions are where credential and discovery problems surface; CloudCredentialsInvalid
# here means the IAM trust policy, not the networking.
oc get bgpcloudconfiguration cluster -o jsonpath='{.status.conditions}' | jq

# The quickest health view, and it needs no vtysh. BGP column should read Established for
# every router node; Active or Connect means TCP/179 never completed.
oc get bgpsessionstates -A -o wide

# One FRRConfiguration per peer group proves the operator translated its discovery into
# actual FRR config — if this is empty, nothing was ever asked to peer.
oc get frrconfigurations -n openshift-frr-k8s
```

```bash
# The ground truth from the router itself. Worth doing once even when bgpsessionstates looks
# healthy, because the prefix counter tells you routes are actually moving, not just that a
# session exists.
FRR_POD=$(oc get pods -n openshift-frr-k8s -o name | head -1)
oc exec -n openshift-frr-k8s "$FRR_POD" -c frr -- vtysh -c 'show bgp ipv4 unicast summary'

# The same session seen from AWS. Checking both sides separates "the cluster thinks it is
# peered" from "AWS agrees", which fail for completely different reasons.
aws ec2 describe-route-server-peers --region "$REGION" --filters "Name=route-server-id,Values=$RS_ID" \
  --query 'RouteServerPeers[].[RouteServerPeerId,PeerAddress,State,BgpStatus]' --output table
```

Do not continue until sessions are up. `Active`/`Connect` means TCP/179 is blocked (2.3). `CloudCredentialsInvalid` means the trust policy is wrong (2.4).

---

## 5. Network and VM

Namespace labels **must** exist at creation — admission blocks adding `k8s.ovn.org/primary-user-defined-network` later. `cluster-udn` must equal `spec.network.name`.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: bgp-demo
  labels:
    # Must be present at creation — OpenShift admission refuses to add this label to an
    # existing namespace. Get it wrong and the only fix is deleting the namespace.
    k8s.ovn.org/primary-user-defined-network: ""
    # The join to the CUDN: the generated network selects namespaces carrying this label.
    # Its value must equal spec.network.name below, or the VM lands on the pod network.
    cluster-udn: prod
---
apiVersion: networking.openshift.io/v1beta1
kind: BGPRouting
metadata:
  name: cudn1
spec:
  network:
    # Produces a CUDN called cluster-udn-prod selecting namespaces labelled cluster-udn: prod.
    name: prod
  subnets:
    # One entry for single-stack. The operator hardcodes Layer2 + Primary + Persistent IPAM
    # on the generated CUDN, so this prefix is the only addressing decision left to you —
    # and it is immutable once created.
    - ${CUDN_CIDR}
EOF
```

```bash
# Pending → Configuring → Ready. Stuck at Pending with NamespaceNotReady almost always means
# the namespace labels above are wrong or were added after creation.
oc get bgprouting cudn1 -o jsonpath='{.status.phase}{"\n"}'

# Both objects are generated and operator-owned — do not hand-edit them, the controller will
# reconcile your change away. Seeing them here confirms phase Ready is genuine.
oc get clusteruserdefinednetwork,routeadvertisements
```

The operator generates CUDN `cluster-udn-prod` (Layer2, role Primary, `ipam.lifecycle: Persistent`, labelled `advertise: "true"`) and a shared `RouteAdvertisements` named `bgp-cc-route-advertisements`.

### The VM

```bash
cat <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: demo-vm
  namespace: bgp-demo
spec:
  # Always: KubeVirt restarts the VM after a relocation, which together with the IPAMClaim is
  # what gives it the same address back on a new node.
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: demo-vm
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
                # l2bridge is currently the only supported binding for a VM on a primary UDN.
                # masquerade — the usual default — would NAT the VM behind the pod IP and
                # destroy the entire point of this demo.
                name: l2bridge
      networks:
        - name: default
          # Still "pod", even though the VM lands on the CUDN. Membership comes from the
          # namespace labels, not from naming the network here. The interface name above must
          # match this network name.
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            # containerDisk is ephemeral — fine for a demo, and it avoids depending on a
            # storage class. Use a DataVolume/PVC if you want the VM to survive deletion.
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
                    # python3 ships in the base image, so the demo does not depend on the VM
                    # having working outbound internet access at exactly the wrong moment.
                    # Running under systemd also gives you journald, which is how beat 5
                    # proves the real client IP.
                    ExecStart=/usr/bin/python3 -m http.server 80 --directory /var/www
                    Restart=always
                    [Install]
                    WantedBy=multi-user.target
              runcmd:
                # daemon-reload first because the unit file was written after systemd started.
                - [ systemctl, daemon-reload ]
                - [ systemctl, enable, --now, demo-web.service ]
EOF
```

> The web server is `python3 -m http.server` from the base image rather than an installed `httpd`, so the demo does not depend on VM outbound internet access during boot.

The VM joins the CUDN because its **namespace** is labelled, not because it names the network. `binding: {name: l2bridge}` is currently the only supported binding for a VM on a primary UDN.

> The VM need **not** run on a BGP router node — traffic enters at the elected node and crosses the overlay. It does need a virtualization-capable node; KubeVirt marks others `kubevirt.io/schedulable=false`. If the VM stays `Pending`, add a metal `nodeSelector` and check `oc describe vmi demo-vm -n bgp-demo`.

### Checkpoint 2 — the VM has a CUDN address

```bash
# The decisive check of the whole build. An address outside 192.168.100.0/24 means the VM
# silently attached to the default pod network and everything downstream is meaningless.
oc get vmi demo-vm -n bgp-demo -o wide

# Captured once and reused by every verification and demo command that follows.
export VM_IP=$(oc get vmi demo-vm -n bgp-demo -o jsonpath='{.status.interfaces[0].ipAddress}')
echo "VM_IP=$VM_IP"

# A claim must exist. If it does not, the address is not durable and will change on restart —
# which would quietly falsify the stability claim you make to the customer.
oc get ipamclaims -n bgp-demo
```

A pod-network address instead of `192.168.100.x` means the namespace labelling was wrong and the VM silently attached to the default network. Delete the namespace, recreate with both labels, redeploy.

### Checkpoint 3 — the prefix reached AWS

```bash
# Proof that BGP did its job end to end. Double quotes here so ${CUDN_CIDR} expands inside
# the JMESPath filter. Empty output with healthy sessions points at missing propagation on
# this particular route table rather than at BGP.
aws ec2 describe-route-tables --region "$REGION" --route-table-ids $ROUTE_TABLES \
  --query "RouteTables[].Routes[?DestinationCidrBlock=='${CUDN_CIDR}']" --output table
```

Note the target ENI — it identifies the **currently elected router node**, needed for the failover demo:

```bash
export ELECTED_ENI=<eni-id-from-above>

# The route names an ENI, but you need a node name to kill the right FRR pod in beat 6.
# ENI -> instance ID -> Node is the only path between those two worlds.
ELECTED_INSTANCE=$(aws ec2 describe-network-interfaces --region "$REGION" \
  --network-interface-ids "$ELECTED_ENI" \
  --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text)

# providerID carries the instance ID, so grepping it maps the AWS answer back to a node.
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}' \
  | grep "$ELECTED_INSTANCE"
```

### Checkpoint 4 — MTU sanity

Easy to skip, painful to debug live. The CUDN rides the Geneve overlay, so the VM's MTU is typically **1400** (node MTU minus 100), while EC2 instances commonly default to **9001**. Small pings succeed while real transfers stall if path MTU discovery is blocked.

From the EC2 client:

```bash
# -M do sets DF, so the packet is never silently fragmented and you learn the real path MTU.
# 1372 + 28 bytes of headers = 1400, the usual overlay MTU. This should succeed.
ping -c 2 -M do -s 1372 $VM_IP

# Deliberately oversized. The *useful* outcome is a clean "frag needed" error: that proves
# PMTUD works. A timeout means ICMP is being dropped somewhere, and large transfers will
# hang mid-demo even though ping and small curls looked perfect.
ping -c 2 -M do -s 8973 $VM_IP

# A real transfer, not just a reachability probe — confirms bulk data actually completes.
curl -o /dev/null -s -w '%{size_download}\n' http://$VM_IP/
```

A clean "frag needed" means PMTUD works. A **timeout** means ICMP is being dropped — fix it before the demo, or large HTTP responses and SSH sessions will hang in front of the customer.

```bash
# The cluster's overlay MTU, so you can state the real number instead of assuming 1400.
# Empty output means it was never set explicitly and the CNO default applies.
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.mtu}{"\n"}'
```

---

# Part III. Demonstrate it

---

## 6. Demo flow

Roughly 20 minutes. Everything is already built; you are narrating, not installing.

**1 — Nothing in front of the VM.**

```bash
# Showing both together is the point: a VM with a routable address, and no Service, no
# LoadBalancer, no NodePort anywhere near it.
oc get vmi,svc -n bgp-demo
```

A VM at `192.168.100.x`, and an empty service list.

**2 — The cluster is a BGP speaker.**

```bash
# One row per router node. This is the slide that reframes OpenShift as a participant in
# their network rather than a black box behind a load balancer.
oc get bgpsessionstates -A -o wide
```

**3 — AWS learned the route dynamically.** Checkpoint 3 output. "No human wrote that route. The cluster advertised it; AWS installed it."

**4 — Reach it.** From the EC2 client:

```bash
# Deliberately the most ordinary commands possible — the persuasive part is that nothing
# special is needed from the client side.
ping -c 4 $VM_IP
curl http://$VM_IP/
```

**5 — Prove there is no NAT.** On the VM:

```bash
# The payoff. python's http.server logs the client address to journald, so this shows the
# EC2 instance's real private IP. Under NAT it would show a worker node address instead —
# which is exactly the capability the customer loses today.
sudo journalctl -u demo-web -n 10
```

The logged client address is the **EC2 instance's private IP**, not a worker node. "Your IP-based firewall rules and audit logs still mean something."

> Console access: the **web console** (Virtualization → VirtualMachines → `demo-vm` → Console) gives a clean browser serial console with nothing to install, and is the better visual for a customer. `virtctl console demo-vm -n bgp-demo` works too, but `virtctl` is not bundled with `oc` — download it from the console's Command Line Tools page beforehand. Login is `fedora` / `demo`.

**6 — Failover.** Keep `ping $VM_IP` running from EC2, then kill BGP on the elected node:

```bash
# Find the FRR pod on the node the VPC route table currently points at (Checkpoint 3).
oc get pods -n openshift-frr-k8s -o wide | grep <elected-node-name>

# Deleting the pod kills the BGP speaker on that node — a genuine session failure, unlike
# `oc adm drain`, which leaves the DaemonSet running and fails over nothing. The pod is
# recreated automatically, so the demo heals itself while the customer watches.
oc delete pod -n openshift-frr-k8s <frr-pod-on-that-node>
```

The session drops, BFD detects it, Route Server withdraws the route and repoints at the surviving node. The pod restarts and re-establishes on its own. Point out that the **VM never moved and its IP never changed** — only the path did.

> ⚠️ **Do not use `oc adm drain`.** frr-k8s is a DaemonSet, so `--ignore-daemonsets` leaves it running, BGP stays up and nothing fails over. Deleting the FRR pod is a genuine failure simulation. A gentler, reversible alternative is `oc label node <node> bgp_router-`, which makes the operator withdraw the peer.

**7 — Optional: the address follows the VM.** If you have time and a second virt-capable node, live-migrate the VM and keep the ping running:

```bash
virtctl migrate demo-vm -n bgp-demo

# -w so the customer watches it happen live. The NODE column changes; the IP column does
# not — that is the Persistent IPAM claim doing its job, and the ping keeps running.
oc get vmi demo-vm -n bgp-demo -o wide -w
```

**8 — The on-prem story.** Be explicit: you demonstrated the cluster-to-VPC half. Extending to on-prem is their existing Direct Connect or Transit Gateway — a solved problem, but **not** something you showed here. Claiming otherwise surfaces badly in the follow-up deep-dive.

### Likely questions

- *Can the VM get an address from our VPC CIDR?* No, and it does not need to. The `local` route for your VPC CIDR always beats a propagated BGP route, and no ENI would own the address anyway. The CUDN prefix can still come from your own address space and IPAM — it just must not be a CIDR associated with the VPC. Full reasoning in "Why not an address from the VPC CIDR?".
- *Who assigns the VM's IP?* OVN-Kubernetes, from the CUDN subnet, delivered to the guest by OVN's built-in DHCP. See "How the VM gets its IP".
- *Can we choose a specific address for a given VM?* The address is stable for the life of the VM automatically, which covers most requirements. Choosing *which* address needs a feature gate you probably cannot enable on managed ROSA — see "Choosing a specific address for a specific VM" before answering yes.
- *Does the IP survive a node failure?* Yes, the address belongs to the VM via its `IPAMClaim`. But automatic relocation after an unplanned node loss needs node health checking and fencing — a separate cluster capability.
- *Support status?* GA at v1.0.0 on the `stable` channel, ROSA HCP 4.22+. CRs are `v1beta1`, which is normal at initial GA.
- *Transit Gateway and Direct Connect?* Works, but not automatically: TGW needs a **static route** for the CUDN prefix pointing at the VPC attachment (attachments propagate only the VPC's own CIDRs), and the DX gateway needs that prefix in its **allowed-prefixes list**. A VGW-based DX design will not work — Route Server cannot propagate into VGW-associated route tables. See "VPC and address design".
- *Cost?* Route Server endpoints bill hourly per endpoint (≈$0.75/hr); you want one per AZ.

---

# Part IV. Operate and tear down

---

## 7. Beyond the demo: production gaps

**Return path from on-prem.** The demo proves VPC ↔ VM only. For genuine on-prem reachability the cluster must also *learn* those prefixes: an FRRConfiguration with `toReceive.allowed.mode: all` imports neighbour routes into the default VRF, and routes in the default VRF are then imported into the CUDN automatically. Verify explicitly rather than assuming symmetry.

**Node health checking and fencing.** Required if the customer expects VMs to come back automatically after an unplanned node loss. See "How the VM gets its IP".

**Address planning and the path to on-prem.** See "VPC and address design" above — in particular that Transit Gateway needs a **static route** for the CUDN prefix (VPC attachments propagate only the VPC's own CIDRs) and the Direct Connect gateway needs it in the **allowed-prefixes list**. Neither happens automatically, and a VGW-based DX design cannot work here at all.

**Route Server quotas.** Default limits on endpoints, peering sessions and advertised routes. Fine for a demo; a sizing question for production.

**MTU.** See Checkpoint 4. In production, inconsistent MTU across the DX path is a likely source of "works but slowly / large files hang" tickets.

**Scope of the CUDN.** One `BGPRouting` serves the namespaces matching its `cluster-udn` label. Multi-tenant designs need a prefix and CR per tenant network, multiplying advertised routes.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Operator not in OperatorHub | Cluster is 4.21 — catalogs ship for 4.22/5.0 | Upgrade, or use a pre-release catalog source |
| `CloudCredentialsInvalid` | Trust policy `sub`/`aud` mismatch, or pod predates the role | Fix policy, `oc rollout restart deployment/...controller-manager -n openshift-bgp-cloud-connector` |
| BGP stuck `Active`/`Connect` | TCP/179 blocked | SG rule (2.3) |
| Peers never establish with BFD | UDP/3784 blocked | Open it, else `livenessDetection: bgp-keepalive` |
| Session up, no route in VPC table | Propagation not enabled on that table | `enable-route-server-propagation` (2.2) |
| Peer creation authorization error | Missing SG actions in IAM | Add `ec2:AuthorizeSecurityGroupIngress` / `RevokeSecurityGroupIngress` |
| BGPRouting `NamespaceNotReady` | Namespace labels missing or added late | Recreate the namespace |
| VM has pod-network IP | Same as above | Recreate namespace, then VM |
| VM IP changed after restart | No `IPAMClaim` — not on the CUDN, or IPAM not Persistent | `oc get ipamclaims -n bgp-demo`; confirm the CUDN's `ipam.lifecycle` |
| VM did not come back after node loss | Expected — no fencing configured | Node Health Check + Self Node Remediation, or machine health checks |
| Inbound works, VM-initiated fails | Asymmetric return path | Ephemeral port rules (2.3) |
| Ping fine, large transfers hang | PMTUD broken (1400 vs 9001) | Checkpoint 4; ensure ICMP is not filtered |
| VM stuck `Pending` | Non-virt-capable node | `oc describe vmi`, add metal `nodeSelector` |
| Routes advertised but rejected | `targetVRF` set to `default` | Leave `targetVRF` unset |
| Traffic hits node, not VM | Source/dest check still on | Confirm `ec2:ModifyNetworkInterfaceAttribute` and that the operator reconciled |

```bash
# Full object, not just conditions: status.peerGroups shows what the operator actually
# discovered from AWS, which is where discovery problems become visible.
oc get bgpcloudconfiguration cluster -o yaml

# -A because a forgotten BGPRouting in another namespace can keep the shared
# RouteAdvertisements alive and confuse an otherwise clean picture.
oc get bgprouting -A -o yaml

# The controller log is the only place AWS API errors appear in full; CR conditions give you
# the summary, not the underlying permission that was denied.
oc logs -n openshift-bgp-cloud-connector deploy/openshift-bgp-cloud-connector-controller-manager --tail=200
```

---

## 9. Cleanup

**Order matters.** Deleting `BGPCloudConfiguration` makes the operator delete its AWS Route Server peers and re-enable `SourceDestCheck` on the worker ENIs. Remove the Subscription and CSV too early and OLM kills the controller mid-finalizer, orphaning peers and — worse — leaving **source/destination check disabled on your worker nodes**, a security-relevant leftover nobody will notice.

```bash
# 1. Workload first, so the CUDN is unused before the network config goes away.
oc delete vm demo-vm -n bgp-demo
oc delete bgprouting cudn1
oc delete namespace bgp-demo

# 2. The BGP config. Deleting it is what triggers the operator's AWS cleanup, so the
#    operator must still be alive at this point.
oc delete bgpcloudconfiguration cluster

# Blocks until the finalizer has actually finished. `|| true` because oc wait errors when
# the object is already gone, which is a success for our purposes, not a failure.
oc wait --for=delete bgpcloudconfiguration/cluster --timeout=180s || true

# 3. Verify the finalizer did its work BEFORE taking the operator away. Empty peer list is
#    what you want.
aws ec2 describe-route-server-peers --region "$REGION" \
  --filters "Name=route-server-id,Values=$RS_ID" \
  --query 'RouteServerPeers[].[RouteServerPeerId,State]' --output table

# Expect True. This is the security-relevant half: source/destination check was disabled to
# let these nodes forward traffic for the CUDN, and leaving it off is a finding nobody will
# spot later.
aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].[InstanceId,SourceDestCheck]' --output table

# 4. Only now remove the operator. Doing this earlier lets OLM kill the controller
#    mid-finalizer and strands both of the things you just checked.
oc delete subscription bgp-cloud-connector -n openshift-bgp-cloud-connector
oc delete csv -n openshift-bgp-cloud-connector --all
```

If `SourceDestCheck` is still `False`, restore it manually:

```bash
# Every interface, not just the primary: the operator disables the check per ENI, so a
# secondary interface can be left forwarding even after the primary is restored.
for ENI in $(aws ec2 describe-instances --region "$REGION" --instance-ids $INSTANCE_IDS \
  --query 'Reservations[].Instances[].NetworkInterfaces[].NetworkInterfaceId' --output text); do
  aws ec2 modify-network-interface-attribute --region "$REGION" \
    --network-interface-id "$ENI" --source-dest-check "Value=true"
done
```

Then the remaining AWS objects, in dependency order:

```bash
# Peers first — an endpoint with a live peer cannot be deleted. Normally the operator has
# already removed these in step 2; this catches anything it missed. `xargs -r` does nothing
# when the list is empty, which is the expected case.
aws ec2 describe-route-server-peers --region "$REGION" --filters "Name=route-server-id,Values=$RS_ID" \
  --query 'RouteServerPeers[].RouteServerPeerId' --output text | tr '\t' '\n' | \
  xargs -r -n1 -I{} aws ec2 delete-route-server-peer --region "$REGION" --route-server-peer-id {}

# Then endpoints. These are the hourly charge, so this is the step that actually stops the
# meter — worth confirming it succeeded rather than assuming.
aws ec2 describe-route-server-endpoints --region "$REGION" --filters "Name=route-server-id,Values=$RS_ID" \
  --query 'RouteServerEndpoints[].RouteServerEndpointId' --output text | tr '\t' '\n' | \
  xargs -r -n1 -I{} aws ec2 delete-route-server-endpoint --region "$REGION" --route-server-endpoint-id {}

# Disassociate before delete: a Route Server still attached to a VPC will not delete.
aws ec2 disassociate-route-server --region "$REGION" --route-server-id "$RS_ID" --vpc-id "$VPC_ID"
aws ec2 delete-route-server --region "$REGION" --route-server-id "$RS_ID"

# Inline policies must go before the role itself — IAM refuses to delete a role that still
# has policies attached.
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name bgp-cloud-connector
aws iam delete-role --role-name "$ROLE_NAME"
```

> Deleting the BGPCloudConfiguration leaves FRR enabled on the cluster network. Reverting that triggers another network rollout — do not do it casually on a shared cluster.

---

# Appendices

---

## Appendix A. Confirm the schema first

API names changed once already (`CUDNBgpConfig`/`CUDNBgpRouting` at `v1alpha1` → `BGPCloudConfiguration`/`BGPRouting` at `v1beta1`). If `oc explain` disagrees with this document, **`oc explain` wins**.

```bash
# Which CRDs this cluster actually has. If you see CUDNBgpConfig instead of
# BGPCloudConfiguration you are on a pre-GA bundle and the YAML in this runbook will not apply.
oc get crd | grep -iE 'bgp|userdefinednetwork|routeadvertisement|ipamclaim'

# The authoritative field list for *your* build. Worth two minutes before a customer-facing
# run, because a Tech Preview-era field rename is invisible until apply time.
oc explain bgpcloudconfiguration.spec --recursive
oc explain bgprouting.spec --recursive
```

---

## Appendix B. Running without AWS access

`platform: Manual` peers against a router you provide instead of a Route Server. Everything from Section 5 onward is unchanged.

```yaml
apiVersion: networking.openshift.io/v1beta1
kind: BGPCloudConfiguration
metadata:
  name: cluster
spec:
  # Manual reconciles no cloud resources at all — it takes peering verbatim from peerGroups
  # below. CEL rejects spec.aws alongside it, so this is genuinely either/or.
  platform: Manual
  routerNodeSelector:
    bgp_router: "true"
  bgp:
    localASN: 65001
    # bgp-keepalive rather than bfd: a stand-in router may not speak BFD, and a failed BFD
    # negotiation prevents the session establishing at all.
    livenessDetection: bgp-keepalive
    peerGroups:
      # One group per zone, because each node should peer with a router local to it. The
      # nodeSelector decides which nodes use which neighbours.
      - nodeSelector:
          topology.kubernetes.io/zone: us-east-1a
        neighbors:
          # Placeholder — point this at your own router's address.
          - address: 10.0.1.47
            remoteASN: 64512
      - nodeSelector:
          topology.kubernetes.io/zone: us-east-1b
        neighbors:
          - address: 10.0.2.91
            remoteASN: 64512
```

The neighbour addresses and zone names above are placeholders — point them at your own router. Manual reconciles no cloud resources; the platform choice is CEL-enforced, so supplying `spec.aws` alongside `Manual` is rejected. This proves BGP advertisement and no-NAT reachability from the peer. It does **not** prove Route Server integration, route-table propagation, or cloud-side failover. Tell the customer which half they are watching.

---

## Sources

- [openshift/bgp-cloud-connector](https://github.com/openshift/bgp-cloud-connector) · [PR #157 — v1.0.0 to `stable`, `alpha` deprecated at GA](https://github.com/openshift/bgp-cloud-connector/pull/157)
- [Red Hat — Direct VM networking in AWS: BGP cloud connector on ROSA](https://www.redhat.com/es/blog/direct-vm-networking-aws-introducing-bgp-cloud-connector-red-hat-openshift-service-aws)
- [rh-mobb ROSA virt + BGP Cloud Connector guide (PR #1015)](https://github.com/rh-mobb/documentation/pull/1015)
- [AWS — How VPC Route Server works](https://docs.aws.amazon.com/vpc/latest/userguide/route-server-how-it-works.html) · [RouteServerBgpOptions (BFD)](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_RouteServerBgpOptions.html) · [Route Server IAM](https://docs.aws.amazon.com/vpc/latest/userguide/route-server-iam.html)
- [AWS — How route priority works](https://docs.aws.amazon.com/vpc/latest/userguide/route-tables-priority.html) (local route precedence over overlapping propagated routes) · [VPC CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html)
- [AWS — VPC attachments in Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-vpc-attachments.html) (attachments propagate only the VPC CIDR) · [How Transit Gateway works](https://docs.aws.amazon.com/vpc/latest/tgw/how-transit-gateways-work.html)
- [AWS — Allowed prefixes for Direct Connect gateways](https://docs.aws.amazon.com/directconnect/latest/UserGuide/allowed-to-prefixes.html) · [DX gateway and Transit Gateway associations](https://docs.aws.amazon.com/directconnect/latest/UserGuide/direct-connect-transit-gateways.html)
- [OVN-Kubernetes — KubeVirt live migration & persistent IPs](https://ovn-kubernetes.io/features/live-migration/) · [Multi-homing / IPAMClaims](https://ovn-kubernetes.io/master/features/multiple-networks/multi-homing/) · [UserDefinedNetwork API spec (`excludeSubnets`, `ipam`)](https://ovn-kubernetes.io/master/api-reference/userdefinednetwork-api-spec/) · [IPAMClaim API reference](https://docs.okd.io/4.21/rest_api/network_apis/ipamclaim-k8s-cni-cncf-io-v1alpha1.html)
- [ClusterUserDefinedNetwork API reference](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/network_apis/clusteruserdefinednetwork-k8s-ovn-org-v1) · [OCP 4.22 Virtualization networking](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/virtualization/networking) · [Virtualization — Nodes / VM failover](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/virtualization/nodes)
- [KubeVirt — Run strategies and high availability](https://kubevirt.io/user-guide/compute/run_strategies/)
- [Red Hat — IRSA / CCO STS audience](https://www.redhat.com/en/blog/running-pods-in-openshift-with-aws-iam-roles-for-service-accounts-aka-irsa)
- [OCP — Route advertisements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/advanced_networking/route-advertisements)
