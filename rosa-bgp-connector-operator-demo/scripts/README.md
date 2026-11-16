# BGP Cloud Connector demo — scripts

Automates the runbook (`rosa-bgp-vm-direct-reachability-runbook.md`), split by who holds
which credentials. The runbook remains the explanation; these are the hands.

> **Never run against a cluster you care about without a dry run first.**
> Script 03 patches the cluster network to enable FRR, which causes a brief disruption.
> Every script supports `--dry-run`.

## Why three scripts and not one

The dependency runs **cluster → AWS → cluster**. The AWS side discovers which subnets need
Route Server endpoints by reading node labels, so the cluster work cannot wait until after.
That is also why a single "do everything" script is impossible when two people hold
different credentials.

```
  cluster admin            AWS owner             cluster admin
  ┌──────────────┐        ┌──────────────┐      ┌──────────────────┐
  │ 01-cluster-  │ hand-  │ 02-aws-      │ hand-│ 03-cluster-      │
  │   prepare.sh ├───────►│   setup.sh   ├─────►│   deploy.sh      │
  └──────────────┘ off.env└──────────────┘ back └──────────────────┘
                              .env                      │
                                                        ▼
                                                 04-verify.sh (either)
```

| Script | Who runs it | Needs | Creates |
|---|---|---|---|
| `01-cluster-prepare.sh` | cluster admin | `oc` | nothing — validates and labels nodes |
| `02-aws-setup.sh` | AWS owner | `aws` (EC2 + IAM write) | Route Server, endpoints, SG rules, IAM role |
| `03-cluster-deploy.sh` | cluster admin | `oc` | operator, BGP config, CUDN, VM |
| `04-verify.sh` | either | `oc` and/or `aws` | nothing — read-only readiness check |
| `90-cleanup-cluster.sh` | cluster admin | `oc` | — |
| `91-cleanup-aws.sh` | AWS owner | `aws` | — |

The AWS owner needs **no cluster access** and **no `rosa` CLI**: everything they need is
collected in script 01 and passed in `state/handoff.env`.

## Usage

```bash
# once, by whoever owns the design decisions
vi config.env            # cluster name, region, CUDN CIDR, ASNs

# cluster admin
./01-cluster-prepare.sh --dry-run
./01-cluster-prepare.sh
#   -> send config.env and state/handoff.env to the AWS owner

# AWS owner
./02-aws-setup.sh --dry-run
./02-aws-setup.sh --with-test-client
#   -> send state/handback.env back

# cluster admin
./03-cluster-deploy.sh
./04-verify.sh

# afterwards
./90-cleanup-cluster.sh      # cluster admin, first
./91-cleanup-aws.sh          # AWS owner, second — this stops the hourly charges
```

Common flags: `--dry-run`, `--yes`, `--help`.

## Files

- `config.env` — the choices you make. Safe to share; contains no secrets.
- `state/handoff.env` — cluster → AWS. Instance IDs, OIDC issuer, CIDR, ASNs.
- `state/handback.env` — AWS → cluster. Route Server ID, IAM role ARN, VPC facts.
- `lib/common.sh` — logging, idempotency and CIDR-overlap helpers.

Neither state file contains credentials, but `handback.env` does name your AWS account in
the role ARN — treat it as internal.

## What the scripts refuse to do

These are deliberate hard stops, because each one fails silently or expensively later:

- **CUDN overlapping the pod, service or VPC CIDR.** The VPC's `local` route always beats a
  propagated BGP route, so an overlap blackholes rather than erroring.
- **Continuing past BGP sessions that are not all Established.** Everything downstream
  would appear to succeed while being unreachable.
- **A VM whose address is outside the CUDN prefix.** That means the namespace labels were
  wrong and the VM silently joined the pod network.
- **Uninstalling the operator before its finalizer completes** (script 90). That strands
  Route Server peers and leaves `SourceDestCheck` disabled on worker nodes.

## Not automated on purpose

- **Transit Gateway static route** and **Direct Connect allowed prefix** for the CUDN
  prefix. Needed for real on-prem reachability, but they touch shared network
  infrastructure that a demo script has no business modifying. Script 02 prints a reminder.
- **Instance profile for the test client.** Attaching an IAM role to an instance is a
  privilege decision for the account owner.
- **Reverting FRR on the cluster network.** It triggers another network rollout.

## Status

Written against the runbook and **not executed against a live cluster** — the author had no
network path to one. The control flow has been exercised against mocked `oc` and `aws`
binaries, which verifies the logic and the handoff, not the AWS and OpenShift behaviour.
Dry-run first.
