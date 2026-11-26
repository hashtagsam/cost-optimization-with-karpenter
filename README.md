# EKS cost optimisation with Karpenter

An AWS EKS cluster where **Karpenter**, not fixed node groups, buys the compute: Spot-first, right-sized, ARM or x86, and removed again when idle. Built with **Terraform**, with Kyverno guardrails, Prometheus/Grafana/OpenCost for proof, and keyless GitHub Actions CI/CD.

`make report` compares the live price of your running nodes against a static 6 × m6i.xlarge on-demand node group. On the burst demo the saving is typically 60–75% (Spot prices vary by hour and AZ).

For the story behind the project (goals, problems hit, alternatives and next steps) see [docs/PROJECT-WRITEUP.md](docs/PROJECT-WRITEUP.md).

## Architecture

```
GitHub Actions ──OIDC──► plan role (read-only) / apply role (approval-gated)
        │
        ▼
Terraform ─► VPC (3 AZ, private nodes, 1 NAT, flow logs, S3 endpoint)
          └► EKS 1.35 (KMS-encrypted secrets, audit logs, access entries)
                ├─ system node group: 2 × Bottlerocket ARM (m7g.large), tainted, on-demand
                │     runs Karpenter, CoreDNS, Kyverno, metrics-server
                └─ Karpenter NodePools
                      general : Spot-first, ARM+x86, c/m/r gen 6+, consolidates
                      critical: on-demand, tainted, no cost moves in business hours
Kyverno  ─► admission guardrails (requests/limits, no :latest, critical-pool access)
Prometheus + Grafana + OpenCost ─► node churn, pool limits, pending pods, cost per namespace
```

## Repo map

| Path | What it does |
|---|---|
| `terraform/bootstrap` | Run once, local state: S3 state bucket (KMS, versioned, TLS-only), GitHub OIDC provider, plan and apply roles with deny guardrails |
| `terraform/envs/dev` | VPC, EKS, system node group, Karpenter IAM/SQS/Pod Identity, EBS encryption default, budget alert |
| `platform/karpenter` | Controller Helm values, EC2NodeClass and the two NodePools |
| `platform/kyverno` | Kyverno Helm values and three CEL `ValidatingPolicy` guardrails |
| `platform/monitoring` | kube-prometheus-stack and OpenCost values, Karpenter ServiceMonitor and alerts |
| `k8s/` | Demo app (podinfo with HPA/PDB/NetworkPolicy) and the `inflate` load generator |
| `scripts/` | `cost-report.sh` (live Spot/on-demand pricing) and `teardown.sh` (safe destroy order) |
| `.github/` | CI lint/scan, Terraform plan/apply/drift, Dependabot |

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| AWS account | admin access | You need to create IAM roles, VPCs and EKS |
| AWS CLI | v2 | `aws sts get-caller-identity` must work |
| Terraform | ≥ 1.10 | 1.10 added S3 native state locking |
| kubectl | 1.34–1.36 | Must be within one minor version of the cluster (1.35) |
| Helm | 3.x | |
| jq, envsubst, watch, openssl | any | `envsubst` comes with `gettext` |
| GitHub CLI (`gh`) | any | Optional, but makes the CI setup one command per value |
| tflint, checkov, kyverno CLI, shellcheck | latest | Optional locally (`make lint`); CI runs them anyway |

Bash is required. On Windows, run everything from WSL.

**Cost:** about £3–4 a day while the cluster is up (control plane, NAT gateway, two system nodes, plus Spot nodes during the demo). Always run `make down` when you finish. The bootstrap stack left behind costs about $1 a month.

Defaults: region `eu-west-2`, project name `karpenter-costopt`, cluster `karpenter-costopt-dev`. To use another region: set `region` in tfvars, run bootstrap with `terraform -chdir=terraform/bootstrap apply -var github_org=<you> -var region=<region>`, and run `make init STATE_REGION=<region>`.

## Quick start

All commands run from the repo root. `make help` lists every target.

### 1. Bootstrap (once per AWS account)

```bash
make bootstrap GITHUB_ORG=<your-github-username>
```

Creates the state bucket, KMS key, GitHub OIDC provider and the two CI roles. The repo name defaults to `cost-optimization-with-karpenter`; if yours differs, add `-var github_repo=<name>` (see `terraform/bootstrap/variables.tf`).

> **Keep `terraform/bootstrap/terraform.tfstate`.** It is Git-ignored and is the only record of what bootstrap created. Back it up outside the repo. If it is lost, see [Troubleshooting](#troubleshooting).

### 2. Configure

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
```

| Variable | Set it to | How to find it |
|---|---|---|
| `endpoint_public_access_cidrs` | `["<your-ip>/32"]` | `curl -s https://checkip.amazonaws.com`. `0.0.0.0/0` is rejected |
| `admin_principal_arns` | `["arn:aws:iam::<acct>:role/<RoleName>"]` | `aws sts get-caller-identity`. If it shows `assumed-role/<RoleName>/...`, use `aws iam get-role --role-name <RoleName> --query Role.Arn --output text` |
| `create_spot_service_linked_role` | `true`, or `false` if it exists | `aws iam get-role --role-name AWSServiceRoleForEC2Spot` succeeds → `false` |
| `budget_email` | your email, or `""` to skip | Gets an alert at 80% of $75/month |

### 3. Build the cluster (~15 min)

```bash
make init       # writes backend.hcl from bootstrap outputs
make plan
make apply      # applies the saved plan, then writes your kubeconfig
kubectl get nodes    # two Bottlerocket ARM system nodes, Ready
```

### 4. Install the platform (~10 min)

```bash
make platform   # karpenter, nodepools, metrics-server, kyverno, monitoring
make app        # podinfo + inflate
```

Each step is idempotent. If one fails, fix the cause and rerun only that target (`make kyverno`, `make monitoring`, …).

### 5. Run the demo

```bash
make watch      # terminal 1: nodes with pool, Spot/on-demand, type, zone, arch
make inflate    # terminal 2: 30 × 1 vCPU pods → Karpenter adds Spot nodes in ~1 min
make report     # live-priced cost vs the 6 × m6i.xlarge baseline
make grafana    # prints the admin password, then http://localhost:3000 (user: admin)
make deflate    # pods to 0 → consolidation removes nodes after ~2 min
kubectl run test --image=nginx -n default   # Kyverno denies it: no requests, :latest
```

In Grafana: **Dashboards → Karpenter** for capacity, **Alerting → Alert rules** for the three Karpenter alerts. `make grafana` holds the terminal; to run it in the background instead: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/tmp/grafana-pf.log 2>&1 &`.

`scripts/cost-report.sh <cluster> <region> [baseline_type] [baseline_count]` lets you compare against a different baseline.

### 6. Tear down

```bash
make down
```

Type the cluster name to confirm. The script deletes the NodePools first (so Karpenter terminates its own instances, which Terraform does not know about), then runs `terraform destroy`, then checks for orphaned instances. It should end with **"Clean - nothing left billing."** The bootstrap stack is kept on purpose.

### Resuming later

```bash
curl -s https://checkip.amazonaws.com     # update terraform.tfvars if your IP changed
make init plan apply
make platform app
```

## CI/CD setup (optional)

Two workflows run in GitHub Actions:

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | every push and PR | `terraform fmt`/`validate`, tflint, Kyverno CLI on the manifests, shellcheck, gitleaks, checkov. No AWS access |
| `terraform.yml` | PRs touching `terraform/`, pushes to `main` touching `terraform/envs/`, nightly 05:17 UTC | PR/nightly: plan with the read-only role (nightly fails on drift). Push to `main`: apply after approval |

`terraform.yml` skips itself until `AWS_PLAN_ROLE_ARN` is set, so the repo stays green before you wire it up.

**1. Create a GitHub Environment** `dev`: Settings → Environments → New environment → tick **Required reviewers** and add yourself.

**2. Set the variables and secret** straight from Terraform outputs (avoids stray quotes or spaces, which break the AWS login step):

```bash
B="terraform -chdir=terraform/bootstrap output -raw"
gh variable set AWS_REGION           --body "eu-west-2"
gh variable set AWS_PLAN_ROLE_ARN    --body "$($B plan_role_arn)"
gh variable set TF_STATE_BUCKET      --body "$($B state_bucket)"
gh variable set TF_STATE_KMS_KEY_ARN --body "$($B state_kms_key_arn)"
gh variable set AWS_APPLY_ROLE_ARN   --env dev --body "$($B apply_role_arn)"
gh secret   set TF_VARS              < terraform/envs/dev/terraform.tfvars
```

`TF_VARS` is a **secret** because it holds your IP and email; those two variables are also marked `sensitive` in Terraform, so plan output shows `(sensitive value)`. Re-run the `gh secret set` line whenever you change `terraform.tfvars`.

**3. Test it** with a PR that only adds a comment to `terraform/bootstrap/variables.tf`: you get a plan in the job summary, and merging it does not trigger an apply. Changes under `terraform/envs/` trigger an apply after merge, which waits for your approval in the `dev` environment.

**While the cluster is torn down** the nightly drift check will report every resource as missing. Disable it with `gh workflow disable terraform` and re-enable with `gh workflow enable terraform`.

Dependabot opens weekly PRs for GitHub Action SHAs and Terraform providers/modules. Helm chart versions are pinned in the `Makefile` and updated by hand.

## Configuration reference

| To change | Edit |
|---|---|
| Kubernetes version | `kubernetes_version` in tfvars (default `1.35`) |
| Karpenter version | `KARPENTER_VERSION` in `Makefile`, and the dashboard URL tag in `platform/monitoring/prometheus-values.yaml` |
| Instance types, Spot/on-demand, pool size limits | `platform/karpenter/nodepools.yaml`, then `make nodepools` |
| How quickly idle nodes are removed | `consolidateAfter` in `nodepools.yaml` (2m for the demo; 5–15m in real use) |
| Guardrail policies | `platform/kyverno/policies.yaml`, then `kubectl apply -f` it |
| Alerts | `platform/monitoring/alerts.yaml` |
| Budget amount | `aws_budgets_budget.lab` in `terraform/envs/dev/main.tf` |
| Cost baseline | arguments to `scripts/cost-report.sh` |

To let a namespace use the on-demand `critical` pool, label it `platform.example.io/tier=critical` and give its pods a toleration for `workload-tier=critical:NoSchedule` and `nodeSelector: { workload-tier: critical }`.

## Security controls

| Layer | Control |
|---|---|
| CI identity | GitHub OIDC, no stored keys. PR plan role is read-only with explicit denies (no secrets, SSM params, S3 objects outside state, no state writes). Apply role only after Environment approval; denied IAM users/keys, CloudTrail/GuardDuty tampering and state-bucket changes. Fork PRs get no credentials |
| State | S3 + customer KMS key, versioning, TLS-only policy, native S3 locking |
| Cluster access | EKS access entries, no implicit creator admin; API endpoint limited to your CIDR (validated, never `0.0.0.0/0`) |
| Control plane | KMS envelope encryption of Secrets; all 5 log types including audit |
| Nodes | Bottlerocket, IMDSv2 with hop limit 1, SSM instead of SSH, encrypted gp3, private subnets |
| Workload identity | EKS Pod Identity for Karpenter |
| Admission | Kyverno: requests + memory limit required, no `:latest`, critical pool only for approved namespaces. Pod Security Admission `restricted` on the app namespace |
| Network | VPC CNI network policy: default-deny + explicit allow; VPC flow logs |
| Supply chain | Actions pinned to SHAs, modules pinned exactly, Dependabot, gitleaks, checkov, tflint, shellcheck. Every checkov skip is documented in `.checkov.yaml` |

## Known limitations (lab trade-offs)

- One NAT gateway (not AZ-resilient); public API endpoint restricted by IP rather than private-only.
- `bottlerocket@latest` AMI alias: nodes roll automatically when AWS publishes a new image.
- Prometheus and Grafana use pod-local storage: metrics and Grafana settings are lost when their pods move.
- Alertmanager is off: alerts are visible in Grafana but not sent anywhere.
- OpenCost prices Spot nodes at on-demand rates (no Spot data feed configured); `make report` uses live Spot prices.
- `make report` covers EC2 compute only, at list prices, at one moment. It is a measurement, not a bill.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl`: `i/o timeout` | Your public IP changed | Update `endpoint_public_access_cidrs`, `make plan apply`, `gh secret set TF_VARS < …` |
| `kubectl`: `no such host` | Kubeconfig points at a destroyed cluster | `aws eks update-kubeconfig --region eu-west-2 --name karpenter-costopt-dev` |
| `kubectl`: `Unauthorized` | Your AWS identity is not in `admin_principal_arns` | Use the **role** ARN of the identity in `aws sts get-caller-identity` |
| `make bootstrap`: `EntityAlreadyExists … OIDC provider` (or the `gha-plan`/`gha-apply` roles) | Bootstrap state was lost but the resources still exist | Import them, e.g. `terraform -chdir=terraform/bootstrap import -var github_org=<you> aws_iam_openid_connect_provider.github <arn>` (get the ARN with `aws iam list-open-id-connect-providers`); roles: `'aws_iam_role.ci["plan"]' karpenter-costopt-gha-plan`. Then `make bootstrap` |
| `make init`: `KMSInvalidStateException … pending deletion` | Stale `backend.hcl` from a previous bootstrap | `make init` regenerates it from the current bootstrap outputs |
| `make apply`: `LimitExceeded … PolicySize 6144` | Karpenter controller policy too big for a managed policy | Keep `enable_inline_policy = true` in `eks.tf` |
| Pods `Pending`, no new nodes | NodePool limit hit, NodeClass not Ready, or IAM | `kubectl get nodeclaims`, `kubectl describe ec2nodeclass default`, `kubectl -n kube-system logs deploy/karpenter` |
| `make monitoring`: `context deadline exceeded` | A pod never became Ready within 10 min | `kubectl -n monitoring get pods`, then `describe`/`logs --previous` on the failing pod. Grafana killed by its liveness probe before it finished starting is fixed by the probe delay and CPU request in `prometheus-values.yaml` |
| `make monitoring`: `another operation … is in progress` | Interrupted Helm install | `helm -n monitoring uninstall kube-prometheus-stack`, then `make monitoring` |
| Grafana rejects the password | Secret changed after Grafana first started | `kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana` |
| CI: `Source Account ID is needed if the Role Name is provided and not the Role ARN` | `AWS_PLAN_ROLE_ARN`/`AWS_APPLY_ROLE_ARN` has quotes, spaces or only a role name | Re-set the variables with the `gh variable set … $(… output -raw …)` commands above |
| CI: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Repo name or owner differs from what bootstrap trusts | Re-run bootstrap with the right `github_org` / `github_repo` |
| `make down`: `the server doesn't have a resource type "nodepools"` | Karpenter is not installed | Harmless; the script continues to `terraform destroy` |
| `make`: `missing separator` | Makefile recipes indented with spaces | Convert indentation to tabs |
