# 11 — Storage

> ⚠️ This file has been merged into [01-kubernetes-core.md → Section 6: Storage](01-kubernetes-core.md)
> All answered Q&A is there. This file is kept only for reference.

---

## Quick redirect

| Topic | Location |
|---|---|
| PV / PVC / StorageClass | [01-kubernetes-core.md § Storage](01-kubernetes-core.md) |
| EBS CSI driver | [01-kubernetes-core.md § Storage](01-kubernetes-core.md) |
| WaitForFirstConsumer | [01-kubernetes-core.md § Storage](01-kubernetes-core.md) |
| StatefulSet PVC lifecycle | [01-kubernetes-core.md § Storage](01-kubernetes-core.md) |
| EBS vs EFS | [01-kubernetes-core.md § Storage](01-kubernetes-core.md) |
| Orphaned EBS on destroy | [03-terraform-iac.md § Destroy patterns](03-terraform-iac.md) |

---

## Cheat Sheet

| Concept | Key Point |
|---|---|
| EBS | AZ-specific, ReadWriteOnce, use for databases |
| EFS | Multi-AZ, ReadWriteMany, use for shared files |
| WaitForFirstConsumer | Delays PV provisioning until pod is scheduled → same AZ |
| volumeClaimTemplates | StatefulSet creates one PVC per replica |
| PVC not deleted on StatefulSet delete | Intentional — must delete manually to release EBS |
