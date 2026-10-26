# 03 — Terraform & IaC

> Tags: **[G]** conceptual · **[S]** scenario · **[TF]** Terraform-specific
> Project: full EKS cluster + addons + Helm releases managed via Terraform

---

## 1. Core Terraform concepts

> `resource` vs `data`, providers, state file purpose,
> `terraform plan` vs `apply` vs `destroy`, idempotency.

**[G] What is `data` vs `resource` in Terraform?**
`resource` creates something new in AWS. `data` reads something that already exists — read-only lookup. Example from our project: `data "aws_ssm_parameter" "eks_ami"` reads the current EKS-optimised AMI ID from AWS's public SSM directory — we don't create the AMI, we just look up its ID to use in our launch template. Using `data` for the AMI means we never hardcode an AMI ID that goes stale when AWS patches it.

**[G] What is the Terraform state file and why does it matter?**
`terraform.tfstate` is Terraform's record of what it created. It maps your config to real AWS resource IDs. Without it Terraform can't know what to update or destroy. In production it lives in S3 with DynamoDB locking — never on a local disk. If the state file is lost, Terraform thinks nothing exists and tries to recreate everything, potentially causing duplicates or conflicts.

<!-- ADD MORE AS TOPICS ARE COVERED -->

---

## 2. State management

> Remote state (S3 + DynamoDB lock), state drift, `terraform import`,
> `terraform state mv`, when state gets out of sync with real AWS resources.

<!-- ADD QUESTIONS HERE -->

---

## 3. `depends_on` and build order

> Implicit vs explicit dependencies, why order matters in EKS
> (VPC CNI before node group, node group before CoreDNS/kube-proxy),
> `depends_on` on helm_release.

**[G] Why does the node group have `depends_on = [aws_eks_addon.vpc_cni]`?**
Without VPC CNI, nodes boot but can't get pod IPs — they stay `NotReady`. If Terraform started the node group before CNI was active, the nodes would come up broken and need to be recycled. The `depends_on` forces Terraform to: create cluster → install VPC CNI → then create node group. Nodes boot into a working network from the start.

<!-- ADD MORE -->

---

## 4. `lifecycle` rules

> `create_before_destroy`, `prevent_destroy`, `ignore_changes`,
> when each is needed and why.

**[G] Why does the launch template use `lifecycle { create_before_destroy = true }`?**
Without it, Terraform tries to delete the old launch template version before creating the new one. But the node group still references the old version — the delete fails. `create_before_destroy` reverses the order: create new version → update the reference → delete old version. Order matters in IaC: the reference must move before the old thing is removed.

<!-- ADD MORE -->

---

## 5. Helm releases in Terraform

> `helm_release` resource, `wait` and `timeout` parameters,
> why Helm destroy hangs (NLB timeout, Kyverno finalizer deadlock),
> `wait = false` pattern for operators with CRD finalizers.

**[G] Why did you set `wait = false` on Kyverno and ArgoCD helm releases?**
Admission webhook operators (Kyverno, ArgoCD, ESO) install CRDs with finalizers. On `helm uninstall`, Kubernetes tries to delete those CRDs but the finalizer waits for the webhook to acknowledge — and the webhook pod is already being deleted. Deadlock. `wait = false` tells Terraform: fire `helm uninstall` and mark it done immediately without waiting. Since we destroy the entire cluster anyway, the EKS node group deletion forces all pods to terminate, breaking the finalizer deadlock automatically.

**[G] Why did you increase ingress-nginx timeout to 900 seconds?**
ingress-nginx creates an AWS NLB. During `helm uninstall`, Helm deletes the LoadBalancer Service, which tells AWS to delete the NLB. NLB deletion takes 8-10 minutes (draining connections). Default Helm timeout is 300s (5 min). We increased to 900s to give AWS enough time to complete the NLB deletion before Terraform marks the release as failed.

<!-- ADD MORE -->

---

## 6. Modules & reusability

> What is a Terraform module, when to use one,
> root module vs child module, input/output variables.

<!-- ADD QUESTIONS HERE -->

---

## 7. IaC best practices

> Why IaC over ClickOps, drift detection, immutable infrastructure,
> SSM parameter lookups instead of hardcoded AMIs, `data` sources for dynamic values.

**[G] Why use SSM parameter lookup for AMI IDs instead of hardcoding?**
AWS releases new EKS-optimised AMIs every few weeks with security patches and K8s updates. A hardcoded AMI ID goes stale and your nodes boot on an unpatched image. The SSM path `/aws/service/eks/optimized-ami/1.34/amazon-linux-2023/.../image_id` is maintained by AWS and always points to the latest recommended AMI for that K8s version. Terraform reads it fresh on every plan — automatic, always current, zero maintenance.

<!-- ADD MORE -->

---

## 8. Terraform destroy patterns

> Why daily destroy is needed in learning projects (cost),
> common destroy failures (NLB timeout, finalizer deadlock, orphaned EBS volumes),
> `scripts/destroy.sh` pattern — pre-cleanup before terraform destroy.

**[G] What resources does Terraform NOT clean up automatically?**
StatefulSet `volumeClaimTemplates` — PVCs created by StatefulSets are not tracked by Terraform. When the cluster is destroyed the EBS volume backing the PVC stays alive and keeps costing money. Fix: delete the PVC before running `terraform destroy` so Kubernetes triggers EBS deletion. We handle this in `scripts/destroy.sh`.

<!-- ADD MORE -->
