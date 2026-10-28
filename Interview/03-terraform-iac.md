# 03 — Terraform & IaC

> Tags: **[G]** conceptual · **[S]** scenario · **[TF]** Terraform-specific
> Project: full EKS cluster + addons + Helm releases managed via Terraform
> Voice: problem → solution → trade-off → one concrete detail from the project

---

## Sections
1. [Core Concepts](#1-core-concepts)
2. [State Management](#2-state-management)
3. [Dependencies & Build Order](#3-dependencies--build-order)
4. [Lifecycle Rules](#4-lifecycle-rules)
5. [Helm Releases in Terraform](#5-helm-releases-in-terraform)
6. [Destroy Patterns](#6-destroy-patterns)
7. [IaC Best Practices](#7-iac-best-practices)

---

## 1. Core Concepts

### Cheat Sheet

| Concept | Key Point |
|---|---|
| `resource` | Creates something new in AWS |
| `data` | Reads something that already exists — read-only lookup |
| `terraform plan` | Shows what WILL change — never modifies anything |
| `terraform apply` | Makes the changes shown in plan |
| Idempotency | Run apply 10 times on same config = same result. No duplicates. |
| Provider | Plugin that translates HCL → AWS API calls |

### Questions

**[G] What is `data` vs `resource` in Terraform?**
`resource` creates something new. `data` reads something that already exists — read-only lookup. Example: `data "aws_ssm_parameter" "eks_ami"` reads the current EKS-optimised AMI ID from AWS's public SSM directory. We don't create the AMI, we look up its ID to use in our launch template. Using `data` means we never hardcode an AMI ID that goes stale when AWS patches it — Terraform reads it fresh on every plan.

**[G] What is idempotency in Terraform?**
Run `terraform apply` on the same config 10 times — the result is always the same. If the resource already exists and matches the config, Terraform does nothing. This is fundamentally different from a bash script that would create a second EC2 on every run. Idempotency is what makes IaC safe to apply repeatedly — for fixes, for CI/CD, for disaster recovery.

**[S] A junior ran `terraform apply` twice. Now there are two EKS clusters. Why and how do you prevent it?**
They ran apply from different directories or different state file locations — each had its own state, neither knew about the other's cluster. Prevention: remote state in S3 with DynamoDB locking. One team = one state file. DynamoDB lock prevents two people running apply simultaneously. State isolation is the #1 operational practice for Terraform in teams.

---

## 2. State Management

### Cheat Sheet

| Concept | Key Point |
|---|---|
| `terraform.tfstate` | Maps your HCL config to real AWS resource IDs |
| Remote state | S3 bucket + DynamoDB locking — never local in production |
| State drift | Real AWS resource changed outside Terraform — plan shows unexpected diff |
| `terraform import` | Bring an existing resource into Terraform state |
| `terraform state mv` | Move a resource between state paths without destroying |
| Lost state | Terraform thinks nothing exists — tries to recreate everything |

### Questions

**[G] What is the Terraform state file and why does it matter?**
`terraform.tfstate` is Terraform's record of what it created — maps config to real AWS resource IDs (e.g. `aws_eks_cluster.main` → `arn:aws:eks:us-east-2:123:cluster/ecom`). Without it, Terraform can't know what to update or destroy. In production it lives in S3 with DynamoDB locking. If the state file is lost, Terraform thinks nothing exists and tries to recreate everything — potential duplicates, conflicts, and outages.

**[G] What is state drift?**
When real AWS resources change outside Terraform — someone clicked in the console, a script ran, AWS auto-modified a setting. The next `terraform plan` shows a diff even though you changed nothing in HCL. Fix: either import the change into state (`terraform import`) or let Terraform reconcile by running apply to revert to the declared config. Prevention: everything goes through Terraform, no ClickOps on managed resources.

**[S] You need to rename a Terraform resource block from `aws_eks_cluster.main` to `aws_eks_cluster.ecom`. What happens if you just rename it in HCL?**
Terraform sees the old resource deleted and a new one created — it will destroy the EKS cluster and recreate it. Correct approach: `terraform state mv aws_eks_cluster.main aws_eks_cluster.ecom` — renames the state entry without touching AWS. Then rename in HCL. Plan shows no changes. This is the difference between a safe refactor and an outage.

---

## 3. Dependencies & Build Order

### Cheat Sheet

| Pattern | When to Use |
|---|---|
| Implicit dependency | Resource A uses `resource_B.id` → Terraform infers the order |
| `depends_on` | Resource A must wait for B but doesn't reference B's attributes |
| EKS build order | Cluster → VPC CNI addon → Node group → CoreDNS/kube-proxy addons |
| Why CNI before nodes | Nodes boot into a broken network without CNI — stay NotReady |

### Questions

**[G] Implicit vs explicit `depends_on` — when do you need each?**
Implicit: Terraform automatically infers order when resource A uses an attribute of resource B (`eks_cluster.arn`). Explicit `depends_on`: when A must wait for B but doesn't reference any of B's attributes — the dependency is behavioural not attributive. Example: `helm_release.argocd` must wait for the node group to have nodes ready, but it doesn't use any node group attribute in its config.

**[G] Why does the node group have `depends_on = [aws_eks_addon.vpc_cni]`?**
Without VPC CNI, nodes boot but can't get pod IPs — they join the cluster but stay `NotReady`. Terraform would then try to install kube-proxy and CoreDNS add-ons, which need running nodes to schedule on. Forcing CNI first means nodes boot into a working network. This ordering is not automatic because EKS nodes don't reference the CNI addon in their config — explicit `depends_on` is the only way to enforce it.

---

## 4. Lifecycle Rules

### Cheat Sheet

| Rule | What It Does | When to Use |
|---|---|---|
| `create_before_destroy` | Creates replacement before deleting old | Resources with live references (launch template) |
| `prevent_destroy` | Terraform errors if you try to destroy | Production databases, KMS keys |
| `ignore_changes` | Terraform ignores drift on these attributes | AWS auto-modifies tags, ASG desired count |

### Questions

**[G] Why does the launch template use `lifecycle { create_before_destroy = true }`?**
Without it, Terraform tries to delete the old launch template before creating the new one. The node group still references the old version — delete fails with a dependency error. `create_before_destroy` reverses the order: create new version first → node group reference updates → delete old version. Order matters in IaC: the reference must move before the old resource is removed.

**[G] When would you use `prevent_destroy`?**
On resources where accidental destruction would be catastrophic: production RDS instances, KMS keys (deleting a KMS key means all data encrypted with it is permanently unreadable), Terraform S3 state buckets. `prevent_destroy = true` makes `terraform destroy` and any plan that would remove the resource fail with an error. You must explicitly remove the lifecycle block to delete.

---

## 5. Helm Releases in Terraform

### Cheat Sheet

| Problem | Fix |
|---|---|
| Kyverno/ArgoCD/ESO destroy hangs forever | `wait = false` — fire uninstall, don't wait for CRD finalizer |
| ingress-nginx destroy times out | `timeout = 900` — NLB deletion takes 8-10 min |
| Why finalizer deadlock happens | Webhook pod being deleted + finalizer waiting for webhook = deadlock |
| `wait = false` is safe on cluster destroy | EKS node deletion breaks all finalizers automatically |

### Questions

**[G] Why did you set `wait = false` on Kyverno, ArgoCD, and ESO helm releases?**
These operators install CRDs with finalizers. On `helm uninstall`, Kubernetes tries to delete those CRDs but the finalizer waits for the webhook to acknowledge — and the webhook pod is already being terminated. Classic deadlock. `wait = false` tells Terraform: fire `helm uninstall` without waiting. Since we destroy the entire cluster anyway, EKS node termination forces all pods to die, breaking every finalizer automatically. The CRDs are gone when the cluster is gone.

**[G] Why did you increase ingress-nginx Helm timeout to 900s?**
ingress-nginx creates an AWS NLB. On `helm uninstall`, Kubernetes deletes the LoadBalancer Service, which tells AWS to delete the NLB. NLB deletion takes 8-10 minutes (draining active connections). Default Helm timeout is 300s. Terraform was marking the release as failed mid-deletion, leaving orphaned AWS resources. 900s gives the NLB enough time to fully drain and delete.

**[S] `terraform destroy` has been running for 45 minutes and is stuck on a Helm release. What do you do?**
First check which release: `terraform plan -destroy` output shows the stuck resource. If it's an operator (Kyverno, ArgoCD, ESO) — `wait = false` is the fix (add it to the release config). If it's ingress-nginx — increase `timeout`. If you're stuck right now: manually run `kubectl delete namespace argocd --force --grace-period=0` to break the finalizer, then re-run `terraform destroy`. But add `wait = false` to prevent it next time.

---

## 6. Destroy Patterns

### Cheat Sheet

| Resource | Why Terraform Misses It | Fix |
|---|---|---|
| StatefulSet PVCs | Created by K8s `volumeClaimTemplates`, not Terraform | `scripts/destroy.sh` deletes PVC before destroy |
| KMS key | 7-30 day deletion window, can't be force-deleted | Created in `scripts/`, not Terraform state |
| ECR images | ECR repo with images can't be deleted if not empty | Lifecycle policy cleans images, or `force_delete=true` on the repo |

### Questions

**[G] What resources does Terraform NOT clean up automatically on destroy?**
Resources Terraform didn't create: StatefulSet PVCs (created by K8s), ECR images (pushed by Jenkins), EBS volumes from orphaned PVCs. Also: resources with deletion protection windows — KMS keys (7-30 days). Our rule: long-lived resources or those with deletion windows go in `scripts/` and are managed manually, not in Terraform state.

**[G] Why is the KMS key in `scripts/create-kms-key.sh` and not in Terraform?**
KMS keys have a mandatory 7-30 day deletion window — you can't delete one immediately. If KMS were in Terraform state and you ran `terraform destroy`, it would schedule deletion but the key wouldn't actually be gone for 7 days. Next `terraform apply` would fail trying to create a new key with the same alias (alias still exists pointing to the pending-deletion key). Managing KMS outside Terraform, referenced via `data "aws_kms_key"`, avoids this entirely.

---

## 7. IaC Best Practices

### Cheat Sheet

| Practice | Why |
|---|---|
| Never hardcode AMI IDs | AWS patches them — use SSM data source for latest |
| Remote state always | No local state in teams — drift, conflicts, lost files |
| `terraform plan` in CI | Catch drift and mistakes before apply |
| Separate state per environment | Dev and prod never share state — destroy dev won't touch prod |
| Tag everything | Cost allocation, cost per environment, cost per team |
| `scripts/` for manual resources | Things outside Terraform's lifecycle — don't fight the tool |

### Questions

**[G] Why use SSM parameter lookup for AMI IDs instead of hardcoding?**
AWS releases new EKS-optimised AMIs every few weeks with security patches. A hardcoded AMI ID goes stale — nodes boot on an unpatched image. The SSM path `/aws/service/eks/optimized-ami/<version>/amazon-linux-2023/.../image_id` is maintained by AWS and always points to the latest recommended AMI for that K8s version. Terraform reads it fresh on every plan — zero maintenance.

**[G] IaC vs ClickOps — what's the real business argument for IaC?**
Three things ClickOps can't do: (1) Reproducibility — spin up an identical environment in minutes for staging, DR, new region. (2) Auditability — every change is a Git commit with author, timestamp, and reason. (3) Drift detection — `terraform plan` shows if someone changed something in the console. ClickOps is invisible, unrepeatable, and unauditable. In a Dublin DevOps interview: "I can recreate our entire EKS cluster from scratch in 20 minutes with one command."
