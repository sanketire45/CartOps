# 🎯 DevOps Interview Master — Index

> Built from the Ecommerce-Spring project (EKS + Terraform + ArgoCD + Jenkins).
> Every answer is grounded in something actually built — not theoretical.
> Add to each file as topics are implemented in the project.

---

## Files

| # | Topic | File | Status |
|---|---|---|---|
| 01 | Kubernetes Core | [01-kubernetes-core.md](01-kubernetes-core.md) | 🔨 in progress |
| 02 | Kubernetes Security | [02-security.md](02-security.md) | ✅ done |
| 03 | Terraform & IaC | [03-terraform-iac.md](03-terraform-iac.md) | 🔨 in progress |
| 04 | Docker & Containers | [04-docker-containers.md](04-docker-containers.md) | ✅ done |
| 05 | CI/CD & Jenkins | [05-cicd-jenkins.md](05-cicd-jenkins.md) | 🔨 in progress |
| 06 | GitOps & ArgoCD | [06-gitops-argocd.md](06-gitops-argocd.md) | 🔨 in progress |
| 07 | AWS Core Services | [07-aws-services.md](07-aws-services.md) | 🔨 in progress |
| 08 | Networking | [08-networking.md](08-networking.md) | 🔨 in progress |
| 09 | Scaling & Autoscaling | [09-scaling.md](09-scaling.md) | ⏳ pending |
| 10 | Observability | [10-observability.md](10-observability.md) | ⏳ pending |
| 11 | Storage | [11-storage.md](11-storage.md) | ⏳ pending |

---

## How to use

- **Green = ready to study.** File has answered questions from the project.
- **Orange = in progress.** Sections exist, content being added as tasks complete.
- **Grey = pending.** File created with sections, no content yet — added when we reach that phase.
- Add questions to the relevant section as you implement each task.
- Every answer must reference something you actually built — no generic textbook answers.

---

## The master answer framework

Every interview answer follows this structure:

```
Problem → Solution → Trade-off → One concrete detail from the project
```

Example:
> "Why not store secrets in environment variables?"
> Problem: env vars are visible in kubectl describe and etcd.
> Solution: ESO + Secrets Manager — pod reads a K8s Secret, never touches AWS.
> Trade-off: adds ESO + IRSA complexity but eliminates credential rotation entirely.
> Concrete detail: we hit this exact issue — mysql pod was crashing because the Secret key name didn't match what ESO wrote.

---

## Tags used across all files

- **[G]** General / conceptual — "what is X, how does X work"
- **[S]** Scenario — "you had problem Y, how did you fix it"
- **[TF]** Terraform-specific — "how is X done in Terraform"
- **[AWS]** AWS-specific — "how does AWS implement X"
