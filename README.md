# EKS cost optimisation with Karpenter

Cut Kubernetes compute cost on AWS EKS by replacing fixed node groups with **Karpenter**: Spot-first, right-sized, multi-arch nodes that are consolidated away when idle. Built with **Terraform**, with policy, monitoring and CI security built in rather than bolted on.

**Result to quote:** a static 6 × m6i.xlarge on-demand node group versus Karpenter-managed Spot/Graviton capacity. `make report` prints the live-priced saving for your own run (typically 60–75% on the burst workload; prices vary).

## Architecture

```
GitHub Actions ──OIDC──► plan role (read-only) / apply role (approval-gated)
        │
        ▼
Terraform ─► VPC (3 AZ, private nodes, 1 NAT, flow logs, S3 endpoint)
          └► EKS (private-ish API, KMS secrets, audit logs, access entries)
                ├─ system node group: 2 × Bottlerocket ARM, tainted, on-demand
                │     runs Karpenter, CoreDNS, Kyverno, Prometheus
                └─ Karpenter NodePools
                      general : Spot-first, ARM+x86, many types, consolidates
                      critical: on-demand, tainted, no disruption in business hours
Kyverno  ─► admission guardrails (requests/limits, no :latest, critical-pool access)
Prometheus + Grafana + OpenCost ─► node churn, pool limits, pending pods, £ per namespace
```

## Repo map

| Path | What it does |
|---|---|
| `terraform/bootstrap` | One-off, local state: S3 state bucket (KMS, versioned, TLS-only), GitHub OIDC provider, plan and apply roles with deny guardrails |
| `terraform/envs/dev` | VPC, EKS, Karpenter IAM/SQS/Pod Identity, EBS encryption default, budget alert |
| `platform/karpenter` | Controller values, EC2NodeClass and the two NodePools |
| `platform/kyverno` | Kyverno values and three CEL `ValidatingPolicy` guardrails |
| `platform/monitoring` | kube-prometheus-stack, OpenCost, Karpenter ServiceMonitor and alerts |
| `k8s/` | Hardened demo app (podinfo + HPA/PDB/NetworkPolicy) and the `inflate` load generator |
| `scripts/` | `cost-report.sh` (live Spot/on-demand pricing) and `teardown.sh` (safe order) |
| `.github/` | CI lint/scan, Terraform plan/apply/drift, Dependabot |

## Quick start

Needs: AWS CLI (admin-ish profile), Terraform ≥ 1.10, kubectl, Helm, jq, envsubst. Region defaults to eu-west-2. Expect ~£3–4/day while running; **always `make down`**.

```bash
make bootstrap GITHUB_ORG=<your-github-user>          # once
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars   # set your IP + role ARN
make init plan apply      # ~15 min
make platform app         # add-ons + demo app
make inflate && make watch   # Karpenter launches Spot nodes in ~60 s
make report               # cost vs the static baseline
make deflate              # consolidation removes the nodes
make grafana              # dashboards at localhost:3000
make down                 # Karpenter nodes first, then destroy, then orphan check
```

**CI setup:** in GitHub, create Environment `dev` with yourself as required reviewer and add variable `AWS_APPLY_ROLE_ARN` to it. Add repo variables `AWS_REGION`, `AWS_PLAN_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_STATE_KMS_KEY_ARN` (all from `terraform -chdir=terraform/bootstrap output`) and `TF_VARS` (contents of your tfvars). Until those exist the Terraform workflow skips; lint/scan CI runs regardless.

## How the cost saving works

1. **Spot first.** `general` allows Spot and on-demand; Karpenter picks the cheapest Spot pool with the lowest interruption risk (price-capacity-optimised). Interruption notices arrive via EventBridge → SQS, so pods are drained before the 2-minute reclaim.
2. **Wide instance menu.** Families c/m/r, generations > 5, ARM and x86. More options means more Spot pools, cheaper prices and fewer interruptions.
3. **Graviton.** ARM is ~20% cheaper per vCPU. Multi-arch images let the scheduler use it freely.
4. **Right-sizing.** Karpenter bin-packs pending pods into a fitted instance rather than adding another fixed-size node. Kyverno enforcing requests makes this accurate.
5. **Consolidation.** `WhenEmptyOrUnderutilized` deletes empty nodes and replaces under-used ones with cheaper ones. Disruption budgets cap the blast radius.
6. **Hard ceiling.** NodePool CPU/memory `limits` stop a bad HPA or runaway job turning into a big bill. AWS Budget alerts at 80% of $75.

## Security controls

| Layer | Control |
|---|---|
| CI identity | GitHub OIDC, no stored keys. PR plan role is read-only with explicit denies (no secrets, SSM params, S3 objects outside state). Apply role only after Environment approval; still denied IAM users/keys, CloudTrail/GuardDuty tampering, state-bucket policy changes |
| State | S3 + customer KMS key, versioning, TLS-only policy, native S3 locking (no DynamoDB) |
| Cluster access | Access entries (API mode), no implicit creator admin; API endpoint restricted to your CIDR (validated, never 0.0.0.0/0) |
| Control plane | KMS envelope encryption of Secrets; all 5 log types incl. audit |
| Nodes | Bottlerocket (minimal, immutable, read-only root), IMDSv2 hop limit 1 (pods can't steal node creds), SSM not SSH, encrypted gp3, private subnets |
| Workload identity | EKS Pod Identity for Karpenter (no IRSA trust-policy sprawl) |
| Admission | Kyverno: requests + memory limit required, no `:latest`, only namespaces labelled `platform.example.io/tier=critical` may tolerate the `critical` pool. Pod Security Admission `restricted` on the app namespace |
| Network | VPC CNI network policy: default-deny plus explicit allow from monitoring; flow logs on |
| Supply chain | Actions pinned to SHAs, modules pinned exactly, Dependabot, gitleaks, checkov, tflint, shellcheck |
| Ops safety | Drift detection nightly; teardown deletes NodePools before `destroy` so no orphan EC2 |

## Interview talking points

- **Why Karpenter over Cluster Autoscaler?** CA scales node groups of one fixed shape and needs an ASG per shape. Karpenter talks to EC2 Fleet directly, chooses the instance per pending batch, launches in under a minute and actively consolidates. Fewer moving parts, better bin-packing.
- **How do you make Spot safe?** Diversify (many types × 3 AZs), interruption queue for graceful drains, PDBs, ≥ 3 replicas spread across zones, preStop sleep so the load balancer drains first, and a separate on-demand `critical` pool for things that must not be interrupted.
- **Why a system node group at all?** Karpenter can't schedule itself. A small tainted, on-demand Bottlerocket group hosts the controllers so a Spot event never takes out the autoscaler or the policy engine.
- **What stops consolidation hurting production?** Disruption budgets (max % of nodes at once, zero on `critical` during business hours), PDBs, `do-not-disrupt` on stateful pods like Prometheus, `consolidateAfter` to avoid flapping.
- **Why enforce requests with Kyverno?** Karpenter sizes nodes from requests. No requests = wrong instance sizes and noisy-neighbour OOMs. It's a cost control as much as a reliability one.
- **How do you prove the saving?** OpenCost for cost per namespace, `cost-report.sh` with live Spot and on-demand prices against a stated baseline, Grafana for node count and churn over time. Be honest: dev workload, point-in-time prices.
- **Least privilege in CI?** Two roles split by trust condition (`pull_request` vs `environment:dev`), so a malicious PR can never get write. Explicit denies survive even if a broad managed policy is attached.
- **Terraform design?** Bootstrap with local state solves the chicken-and-egg for the remote backend. Exact module pins, partial backend config so no account IDs in git, `plan -out` then `apply` the same file.
- **Why a 6,144-char inline policy?** Karpenter's controller policy exceeds the managed-policy size limit, so the module attaches it inline. (Real error I hit and fixed.)

## Trade-offs and accepted risks (dev)

Single NAT gateway (cheaper, not AZ-resilient). Public API endpoint, CIDR-restricted, rather than private-only + VPN. `bottlerocket@latest` AMI alias (pin and promote in prod). Grafana admin via a Kubernetes Secret, not an external secret store. Alertmanager disabled. Checkov skips are listed with reasons in `.checkov.yaml`.

**For production:** private endpoint, NAT per AZ, pinned AMIs promoted through environments, External Secrets + AWS Secrets Manager, Alertmanager to Slack/PagerDuty, GitOps (Argo CD) for `platform/`, separate accounts per environment, Savings Plans for the on-demand baseline.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `kubectl` i/o timeout or `no such host` | Your IP changed → update `endpoint_public_access_cidrs`, `make plan apply`. Or stale kubeconfig after a rebuild → `make apply` reruns `update-kubeconfig` |
| `KMSInvalidStateException … pending deletion` on init | Old `backend.hcl` points at a deleted key. `make init` regenerates it from bootstrap outputs |
| `PolicySize 6144` from IAM | Keep `enable_inline_policy = true` on the Karpenter module |
| `server doesn't have a resource type "nodepools"` on teardown | Karpenter already gone; `teardown.sh` checks for the CRD and goes straight to `destroy` |
| Pods `Pending`, no new nodes | `kubectl logs -n kube-system deploy/karpenter`; usually NodePool limits reached or missing requests |