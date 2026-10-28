# 🎯 DevOps Interview Master — Index

> Built from the Ecommerce-Spring project (EKS + Terraform + ArgoCD + Jenkins).
> Every answer is grounded in something actually built — not theoretical.
> Add to each file as topics are implemented. Never leave answers only in chat.

---

## Files

| # | Topic | File | Sections Covered |
|---|---|---|---|
| 01 | Kubernetes Core | [01-kubernetes-core.md](01-kubernetes-core.md) | ✅ Cluster arch, Pods, Scheduling, **Reliability**, **Security**, **Storage**, RBAC, Node capacity |
| 02 | K8s Security (redirect) | [02-security.md](02-security.md) | → merged into 01 |
| 03 | Terraform & IaC | [03-terraform-iac.md](03-terraform-iac.md) | ✅ data vs resource, state, lifecycle, Helm releases, destroy patterns |
| 04 | Docker & Containers | [04-docker-containers.md](04-docker-containers.md) | 🔨 in progress |
| 05 | CI/CD & Jenkins | [05-cicd-jenkins.md](05-cicd-jenkins.md) | 🔨 in progress |
| 06 | GitOps & ArgoCD | [06-gitops-argocd.md](06-gitops-argocd.md) | 🔨 in progress |
| 07 | AWS (Well-Architected) | [07-aws-services.md](07-aws-services.md) | ✅ Security, Reliability, Performance, Cost, Operational Excellence |
| 08 | Networking | [08-networking.md](08-networking.md) | ✅ VPC CNI, ENI formula, prefix delegation, NetworkPolicy |
| 09 | Scaling & Autoscaling | [09-scaling.md](09-scaling.md) | ⏳ fill when HPA + CA done |
| 10 | Observability | [10-observability.md](10-observability.md) | ⏳ fill when Prometheus + Loki done |
| 11 | Storage (redirect) | [11-storage.md](11-storage.md) | → merged into 01 |

---

## File structure inside each topic file

Every section follows this format:

```
## Section Name

### Cheat Sheet
Key points table — the 5-8 things to remember if this topic comes up.

### Questions
[G] General/conceptual — "what is X, how does X work"
[S] Scenario/troubleshooting — "your pod is stuck, your drain is blocked"
[I] Incident/war-story — "walk me through a zero-downtime upgrade"
```

---

## The master answer framework

Every interview answer follows this structure:

```
Problem → Solution → Trade-off → One concrete detail from the project
```

Example:
> "Why not store secrets in environment variables?"
> Problem: env vars visible in kubectl describe and in /proc — readable after a container escape.
> Solution: ESO + Secrets Manager — pod reads a K8s Secret that ESO syncs at runtime.
> Trade-off: adds ESO + IRSA complexity but eliminates credential rotation entirely.
> Concrete detail: we hit this — mysql pod crashed because secretKeyRef.key didn't match what ESO wrote.

---

## Tags

- **[G]** General / conceptual — "what is X, how does X work"
- **[S]** Scenario — "you had problem Y, how did you fix it / what do you check"
- **[I]** Incident / war story — "walk me through X going wrong in production"
- **[TF]** Terraform-specific — "how is X done in Terraform"
- **[AWS]** AWS-specific — "how does AWS implement X"

---

## Topics by project phase (what's answered vs pending)

### Phase 3 — Security ✅ (all in 01 § Security)
Secrets, IRSA, securityContext, PSA, Kyverno, NetworkPolicy, Falco, RBAC

### Phase 4 — Reliability ✅ (all in 01 § Reliability)
Replicas, anti-affinity, topologySpreadConstraints, PDB, readiness probes, graceful shutdown, rolling update

### Phase 5 — Scaling ⏳
HPA, Cluster Autoscaler, Karpenter, KEDA → fill 09-scaling.md when implemented

### Observability ⏳
Prometheus, Grafana, Loki, Alertmanager, SLI/SLO → fill 10-observability.md when implemented

### CI/CD + GitOps 🔨
Jenkins matrix builds, ArgoCD app-of-apps, Argo Rollouts canary → fill 05 + 06 when expanded
