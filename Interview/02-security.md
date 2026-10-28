# 02 — Kubernetes Security

> ⚠️ This file has been merged into [01-kubernetes-core.md → Section 5: Security](01-kubernetes-core.md)
> All answered Q&A is there. This file is kept only for reference.

---

## Quick redirect

| Topic | Location |
|---|---|
| Secrets / ESO | [01-kubernetes-core.md § Security → Layer 1](01-kubernetes-core.md) |
| IRSA | [01-kubernetes-core.md § Security → Layer 2](01-kubernetes-core.md) |
| securityContext | [01-kubernetes-core.md § Security → Layer 3](01-kubernetes-core.md) |
| PSA + Kyverno | [01-kubernetes-core.md § Security → Layer 4](01-kubernetes-core.md) |
| NetworkPolicy | [01-kubernetes-core.md § Security → Layer 5](01-kubernetes-core.md) |
| Falco | [01-kubernetes-core.md § Security → Layer 6](01-kubernetes-core.md) |
| RBAC | [01-kubernetes-core.md § RBAC](01-kubernetes-core.md) |

---

## The layered defence (memorise this)

```
Layer 1 — Secrets:    ESO + AWS Secrets Manager. K8s Secret is a local cache.
Layer 2 — Identity:   Scoped IRSA per workload. OIDC trust bridge.
Layer 3 — Hardening:  runAsNonRoot, drop ALL caps, seccompProfile RuntimeDefault.
Layer 4 — Admission:  PSA restricted label. Kyverno for custom rules.
Layer 5 — Network:    Default-deny NetworkPolicy. Explicit allow-list.
Layer 6 — Runtime:    Falco DaemonSet watching syscalls via eBPF.
```
