# 02 — Kubernetes Security

> Full content in: [k8s-security-answered.md](k8s-security-answered.md)
> This file is the section index — click through to the full answered Q&A.

---

## Sections covered

| Layer | Topic | Status |
|---|---|---|
| 1 | Secrets — ESO + AWS Secrets Manager | ✅ |
| 2 | Identity — IRSA per workload | ✅ |
| 3 | Pod hardening — securityContext | ✅ |
| 4 | Admission — PSA + Kyverno | ✅ |
| 5 | Network — NetworkPolicy default-deny | ✅ |
| 6 | Runtime — Falco + eBPF | ✅ |
| — | RBAC — additive-only, no DENY verb | ✅ |

---

## The layered defence answer (memorise this)

```
Layer 1 — Secrets:    ESO + Secrets Manager. K8s Secret is a local cache only.
Layer 2 — Identity:   Scoped IRSA per workload. Each pod assumes only what it needs.
Layer 3 — Hardening:  runAsNonRoot, drop ALL caps, seccompProfile RuntimeDefault.
Layer 4 — Admission:  PSA restricted label. Kyverno for custom org rules.
Layer 5 — Network:    Default-deny NetworkPolicy. Explicit allow-list per path.
Layer 6 — Runtime:    Falco DaemonSet watching syscalls via eBPF.
```

Each layer assumes the one below it has already failed. That is defence in depth.
