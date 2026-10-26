# 11 — Storage (Kubernetes + AWS)

> Tags: **[G]** conceptual · **[S]** scenario
> Project: EBS CSI (gp3, WaitForFirstConsumer), mysql StatefulSet PVC,
> EFS CSI planned (#33), Velero backup planned (#32)

---

## 1. Kubernetes storage concepts

> PersistentVolume (PV) — the actual storage resource.
> PersistentVolumeClaim (PVC) — a request for storage by a pod.
> StorageClass — defines how to dynamically provision PVs.
> Dynamic provisioning — PVC created → StorageClass provisions PV automatically.

<!-- ADD QUESTIONS HERE -->

---

## 2. EBS CSI driver

> EBS CSI translates PVC → EBS volume API call.
> Replaces old in-tree volume plugin.
> Requires IRSA for the EBS CSI controller ServiceAccount.
> gp3 > gp2: same performance, ~20% cheaper, independently configurable IOPS/throughput.

**[S] MySQL pod was in Pending state because PVC was Pending. Why?**
Two possible causes: (1) StorageClass name didn't exist — we had `storageClassName: gp2` but gp2 wasn't annotated as default. Fix: add `storageclass.kubernetes.io/is-default-class: "true"` annotation to gp2 StorageClass (done via `kubernetes_annotations` resource in Terraform). (2) AZ mismatch — PVC bound to a volume in us-east-2a but pod scheduled on a node in us-east-2c. EBS volumes are AZ-specific. Fix: WaitForFirstConsumer binding mode — PVC waits for pod scheduling before provisioning the EBS in the correct AZ.

<!-- ADD MORE -->

---

## 3. EBS vs EFS

> EBS — block storage, AZ-specific, ReadWriteOnce (one pod at a time), fast.
> EFS — network filesystem, multi-AZ, ReadWriteMany (multiple pods simultaneously), slower.
> Use EBS for: databases (MySQL), single-pod stateful apps.
> Use EFS for: shared config files, multiple pods needing the same data.

<!-- ADD QUESTIONS HERE -->

---

## 4. StatefulSet storage

> `volumeClaimTemplates` — auto-creates one PVC per pod replica (data-mysql-0, data-mysql-1).
> PVCs are NOT deleted when StatefulSet is deleted — intentional (protect data).
> PVCs are NOT tracked by Terraform — orphaned EBS volumes after cluster destroy.
> Fix: delete PVCs explicitly before `terraform destroy` (handled in scripts/destroy.sh).

<!-- ADD QUESTIONS HERE -->

---

## 5. Velero backup & restore

> Cluster-level backup tool — backs up K8s objects + PVC snapshots to S3.
> Use for DR drills, cluster migration, accidental deletion recovery.
> Restore workflow: Velero restores K8s objects first, then PVC snapshots.

<!-- ADD QUESTIONS HERE — fill when task #32 is done -->

---

## 6. WaitForFirstConsumer

> Default PVC binding: `Immediate` — PVC binds to a PV in any AZ immediately.
> Problem: pod might be scheduled in a different AZ than where the volume was provisioned.
> `WaitForFirstConsumer`: delays binding until a pod is scheduled — provisions the EBS
> in the AZ where the pod actually lands. Prevents AZ mismatch entirely.

<!-- ADD QUESTIONS HERE -->
