# 01 — Kubernetes Core

> Tags: **[G]** conceptual · **[S]** scenario · **[I]** incident/war-story
> Project: cluster `ecom`, K8s 1.34, 2× t3.medium, us-east-2, 3 AZs
> Voice for every answer: **problem → solution → trade-off → one concrete detail from the project**

---

## Sections
1. [Cluster Architecture](#1-cluster-architecture)
2. [Pods & Workloads](#2-pods--workloads)
3. [Scheduling & Affinity](#3-scheduling--affinity)
4. [Reliability](#4-reliability)
5. [Security](#5-security)
6. [Storage](#6-storage)
7. [RBAC](#7-rbac)
8. [Services & Networking](#8-services--networking)
9. [Node Capacity & Pod Limits](#9-node-capacity--pod-limits)

---

## 1. Cluster Architecture

### Cheat Sheet

| Concept | Key Point |
|---|---|
| EKS control plane | AWS managed — etcd, API server, scheduler, controller-manager. You own the nodes. |
| Managed node group | AWS handles EC2 lifecycle, AMI upgrades, ASG. You define instance type + size. |
| Fargate | No nodes — AWS runs each pod on its own micro-VM. No DaemonSets, no SSH. |
| Why 2+ AZs | Single AZ = single point of failure for the whole cluster. EKS requires 2+ for node groups. |
| Control plane cost | ~$0.10/hr regardless of node count. Cluster running = control plane billing. |

### Questions

**[G] What does EKS manage vs what do you manage?**
AWS manages the control plane — API server, etcd, scheduler, controller-manager, all HA across 3 AZs. You never see or SSH into control plane nodes. You manage: worker nodes (EC2), networking (VPC, subnets, security groups), add-ons (VPC CNI, CoreDNS), and everything running in the cluster. The boundary matters because EKS upgrades are split: AWS upgrades the control plane, you upgrade the node group separately.

**[G] What is a managed node group vs Fargate?**
Managed node group: EC2 instances in an ASG. You pick instance type. You can SSH in. DaemonSets work (Falco, Fluent Bit need this). AWS handles node AMI upgrades via rolling update. Fargate: no nodes — AWS runs each pod in an isolated micro-VM. No DaemonSets, no privileged containers, no SSH, no node-level visibility. Use Fargate for batch workloads. Use managed node groups for anything that needs DaemonSets, persistent storage, or GPU.

**[S] Your EKS cluster nodes show NotReady right after creation. What do you check first?**
VPC CNI addon. Nodes boot and join the cluster but can't get pod IPs until CNI is running. If CNI wasn't installed before the node group, nodes come up NotReady. In our Terraform: `depends_on = [aws_eks_addon.vpc_cni]` on the node group — forces CNI to be ready before any node boots.

---

## 2. Pods & Workloads

### Cheat Sheet

| Workload Type | Use For |
|---|---|
| Deployment | Stateless services — product-svc, order-svc, frontend |
| StatefulSet | Stateful apps needing stable identity + persistent storage — MySQL |
| DaemonSet | One pod per node — Falco, Fluent Bit, node-exporter |
| Job / CronJob | One-off or scheduled tasks — DB migrations, report generation |
| Init container | Wait for a dependency before main container starts |

### Questions

**[G] Deployment vs StatefulSet — when do you use each?**
Deployment is for stateless services: pods are interchangeable, any pod can handle any request, scale up/down freely. StatefulSet is for apps that need stable identity: each pod gets a stable DNS name (`mysql-0`, `mysql-1`), ordered startup/shutdown, and its own PVC (separate volume per replica). MySQL in our project is a StatefulSet — it needs a persistent volume and a stable name for service discovery.

**[G] What does an init container do?**
Init containers run to completion before the main container starts. They share the pod's network and volumes. We use one on every service that talks to MySQL:
```yaml
initContainers:
  - name: wait-for-mysql
    image: busybox:1.36
    command: ['sh','-c','until nc -z mysql 3306; do sleep 2; done']
```
Without this, product-svc starts and immediately fails because MySQL isn't ready — CrashLoopBackOff. The init container holds the main container back until MySQL port is open.

**[S] A pod is stuck in CrashLoopBackOff. What is your debugging sequence?**
1. `kubectl describe pod <name> -n ecom` — look at Events, Last State exit code
2. `kubectl logs <name> -n ecom --previous` — logs from the crashed container
3. Exit code 1 = app error (check logs). Exit code 137 = OOMKilled (check memory limits). Exit code 0 = app exited cleanly (wrong restartPolicy or missing entrypoint).

---

## 3. Scheduling & Affinity

### Cheat Sheet

| Rule | Type | Effect |
|---|---|---|
| `nodeSelector` | Hard | Pod only goes to nodes with this label |
| `nodeAffinity` | Soft or Hard | Prefer/require nodes with a label |
| `podAntiAffinity` (preferred) | Soft | Try not to co-locate with matching pods — same node |
| `podAntiAffinity` (required) | Hard | Never co-locate — pod stays Pending if no other node |
| `topologySpreadConstraints` | Configurable | Count-based even spread across AZ or node |
| Taints + tolerations | Exclusion | Node repels pods unless pod has the matching toleration |

### Questions

**[G] What is the difference between `podAntiAffinity` and `topologySpreadConstraints`?**
Anti-affinity is binary: "is there already a pod like me on this node? Yes/No — avoid or allow." topologySpreadConstraints is counting: "how many of my pods are in each AZ, and is the difference ≤ maxSkew?" Anti-affinity breaks down with many replicas — with 6 replicas and 2 nodes it can't enforce even distribution. topologySpreadConstraints with `maxSkew:1` across zones guarantees 3+3 regardless of replica count.

**[G] `required` vs `preferred` in podAntiAffinity — which do you use and why?**
`preferred` for HA workloads. `required` means if no valid node exists (e.g. after a node failure), the pod stays Pending forever rather than running somewhere. Degraded-but-alive (two pods on the same node) is better than Pending. We use `preferred` — the scheduler tries to spread, falls back gracefully when it can't.

**[G] `topologyKey: kubernetes.io/hostname` vs `topology.kubernetes.io/zone` — what's the difference?**
Both are node labels. `hostname` = each node is its own domain (spread per node). `zone` = all nodes in the same AZ are one domain (spread per AZ). We use hostname in podAntiAffinity (don't put two pods on the same node) and zone in topologySpreadConstraints (keep AZ pod counts balanced). They answer different questions — node co-location vs AZ balance.

**[S] After HPA scaled product-svc to 6 replicas, all 6 ended up in us-east-1a. Why?**
Only podAntiAffinity was set (topologyKey: hostname). Anti-affinity prevents two pods on the same node, not two pods in the same AZ. With 6 replicas and 3 nodes all in us-east-1a, the anti-affinity was satisfied (1 per node) but all are in one AZ. Fix: add `topologySpreadConstraints` with `topologyKey: topology.kubernetes.io/zone` and `maxSkew: 1`.

---

## 4. Reliability

### Cheat Sheet — what each tool protects against

| Failure Mode | Protection | Our Implementation |
|---|---|---|
| Node crashes (involuntary) | Multiple replicas | product, order, frontend: replicaCount=2 |
| Both replicas on same node | podAntiAffinity preferred hostname | #29 — all 3 deployments |
| AZ imbalance at scale | topologySpreadConstraints maxSkew:1 zone | #28 — all 3 deployments |
| Node drain kills last pod | PodDisruptionBudget minAvailable:1 | #28 — pdb.yaml |
| Traffic to unready pod | Readiness probe | #27 — /actuator/health/readiness |
| In-flight requests dropped | Graceful shutdown (terminationGracePeriodSeconds + preStop) | #21 |
| Downtime during your deploy | Rolling update maxUnavailable:0 maxSurge:1 | #22 |
| Bad deploy to 100% users | Canary + Prometheus auto-rollback | #20 — planned after monitoring |

**The one-liner for interviews:**
> "Reliability is layered — replicas for node failures, anti-affinity for co-location, PDB for planned maintenance, readiness probes for traffic safety, graceful shutdown for request integrity, and rolling update knobs for deploy safety."

### Questions

**[G] Why run 2+ replicas? Isn't 1 enough if health checks restart it automatically?**
Restart only happens after the pod is already dead — there's a gap (detection + restart time, typically 30-60s) where the service is unavailable. 2 replicas means when one pod dies, the other is already serving. The health check restart brings it back from 1 → 2, not from 0 → 1.

**[G] What is a PodDisruptionBudget and what does it NOT protect against?**
PDB limits voluntary disruptions — node drains, cluster upgrades, Cluster Autoscaler scale-downs. It tells the Eviction API: "don't evict this pod if doing so would breach minAvailable." It does NOT protect against involuntary disruptions (node crash, OOM kill) — that's what replicas handle. Rolling update's `maxUnavailable` also does not interact with PDB — they cover different triggers entirely.

**[S] Your node group upgrade is stuck. kubectl drain has been running 30 minutes on one node. What do you do?**
`kubectl get pdb -n ecom` — check `ALLOWED DISRUPTIONS`. If it shows 0, the PDB is blocking. The replacement pod for the pod being evicted hasn't become Ready. Find the Pending/unhealthy pod: `kubectl get pods -n ecom` — then debug it (`kubectl describe pod`, `kubectl logs`). Common causes: ImagePullBackOff (ECR creds), resource pressure on remaining nodes (no room), failing readiness probe. Once the replacement is Ready, drain resumes automatically.

**[S] A pod is in Running state but getting no traffic. Users see errors. What's happening?**
Readiness probe is failing. `kubectl describe pod` shows readiness probe failures in Events. The pod is alive (liveness OK) but not Ready — the Service endpoint is removed so no traffic routes to it. Check the actuator endpoint: `kubectl exec <pod> -- curl localhost:8080/actuator/health/readiness`. Could be a downstream dependency (MySQL down) making the app report not-ready.

**[I] Walk me through a zero-downtime EKS node group upgrade.**
Before touching nodes, the groundwork must be in place: 2 replicas, PDB, readiness probes, graceful shutdown. With that: EKS cordons a node (no new pods), calls the Eviction API. PDB checks: "removing this pod still leaves minAvailable=1 — OK." Pod evicted. Scheduler places replacement on another node. Replacement passes readiness probe → Ready. EKS terminates the old EC2, launches new one with updated AMI. Repeats for next node. Service never drops below 1 running pod. Without any one of these pieces, the upgrade either hangs (PDB blocks forever) or causes downtime (last pod evicted while replacement isn't ready).

**[G] `minAvailable` vs `maxUnavailable` in PDB — which is clearer?**
Same outcome with 2 replicas. `minAvailable: 1` reads as a guarantee ("I need at least 1 healthy"). `maxUnavailable: 1` reads as a tolerance ("I can lose at most 1"). We use `minAvailable` — the Helm if-guard `{{- if gt (int .Values.*.replicaCount) 1 }}` also prevents creating a PDB on a single-replica service (would permanently block drains).

---

## 5. Security

### Cheat Sheet — the 6 layers

```
Layer 1 — Secrets:    ESO + AWS Secrets Manager. K8s Secret is a local cache.
Layer 2 — Identity:   Scoped IRSA per workload. Pod assumes only the role it needs.
Layer 3 — Hardening:  runAsNonRoot, drop ALL caps, seccompProfile RuntimeDefault.
Layer 4 — Admission:  PSA restricted label (built-in). Kyverno for custom rules.
Layer 5 — Network:    Default-deny NetworkPolicy. Explicit allow-list per path.
Layer 6 — Runtime:    Falco DaemonSet — syscall-level threat detection via eBPF.
```

Each layer assumes the one below has already failed — that is defence in depth.

### Questions

**[G] Why not store secrets in environment variables?**
Env vars are visible in `kubectl describe pod` and in `/proc/<pid>/environ` — readable by anyone with pod exec access or a container escape. Also stored in etcd in plaintext. Correct pattern: AWS Secrets Manager as source of truth, ESO pulls them into a K8s Secret at runtime. The pod reads the K8s Secret — never touches AWS directly. We hit this exact issue in the project: mysql pod was crashing because `secretKeyRef.key` didn't match the key name ESO wrote.

**[G] What is IRSA and why does it matter?**
IAM Roles for Service Accounts — lets a pod assume an AWS IAM role without static credentials. Mechanism: K8s issues a signed JWT for the pod's ServiceAccount, the OIDC provider (registered in IAM) validates it, AWS STS returns short-lived credentials. No access keys in env vars, no shared node role, no rotation needed. We scope one IAM role per workload — if order-svc is compromised, it can only reach SQS, not S3 or Secrets Manager.

**[S] A pod keeps getting AccessDenied from AWS even though IRSA is configured. Where do you look?**
1. `kubectl get sa <name> -n ecom -o yaml` — is `eks.amazonaws.com/role-arn` annotation present?
2. `kubectl describe pod` — is `AWS_WEB_IDENTITY_TOKEN_FILE` injected? (IRSA webhook injects it — missing = can't auth)
3. IAM trust policy — OIDC URL correct? `sub` condition exactly matches `system:serviceaccount:<namespace>:<sa-name>`?
4. IAM permissions — does the role actually allow the specific action on the specific resource ARN?

**[G] PSA vs Kyverno — when do you use each?**
PSA is built into the API server — zero overhead, fixed profiles (privileged/baseline/restricted), pods only. Kyverno is an external webhook — custom rules on any resource, can mutate. In production you use both: PSA for the security floor (non-root, no privileged) and Kyverno for org-specific rules (image registry allowlist, required resource limits, label enforcement). PSA catches the basics for free; Kyverno handles what PSA can't.

**[G] What is a NetworkPolicy and why is default-deny the correct starting point?**
NetworkPolicy controls pod-to-pod traffic at IP/port level. Without it, every pod reaches every other pod — a compromised frontend can talk directly to MySQL on port 3306. Default-deny: one NetworkPolicy with empty `podSelector: {}` drops all ingress to all pods in the namespace. Then add explicit allow rules for each legitimate path. Our 6 policies: default-deny + allow nginx→frontend, frontend→product, frontend→order, services→mysql, all→eureka.

**[S] NetworkPolicy is applied but order-service still can't reach product-category. Connection times out. Why?**
Timeout (not refused) means packets are silently dropped — that's exactly what NetworkPolicy does. There's a missing allow rule for `order-service → product-category`. Debug: `kubectl exec order-pod -- curl -v product-svc:8080` — if it hangs, it's a NetworkPolicy drop. `kubectl describe networkpolicy -n ecom` shows exactly which pods each policy selects.

**[G] What is Falco and how is it different from admission controllers?**
Falco is runtime threat detection — DaemonSet, one pod per node, eBPF probe watches every syscall. Admission controllers check the YAML at deploy time. If an attacker `kubectl exec`s into a running pod and runs `cat /etc/shadow`, Kyverno never knew — it only checked the Deployment manifest at apply time. Falco catches it live. You need both: admission for prevention, Falco for detection.

**[S] A developer's deployment was rejected and they don't know why. How do you debug?**
```bash
kubectl describe replicaset <name> -n ecom   # admission rejection message is here
kubectl get events -n ecom --sort-by=.lastTimestamp
```
Rejection happens at the Pod level (Deployment → ReplicaSet → Pod). PSA gives the specific profile violation. Kyverno includes policy name, rule name, and the exact field that failed.

---

## 6. Storage

### Cheat Sheet

| Concept | Key Point |
|---|---|
| PVC | Request for storage. App creates this. |
| PV | Actual storage resource. CSI driver creates this. |
| StorageClass | Defines HOW to provision PVs (which driver, volume type) |
| EBS | Block storage, AZ-specific, ReadWriteOnce (one pod) |
| EFS | Network filesystem, multi-AZ, ReadWriteMany (many pods) |
| WaitForFirstConsumer | Delay PV provisioning until pod is scheduled → correct AZ |
| `volumeClaimTemplates` | StatefulSet auto-creates one PVC per replica (data-mysql-0, data-mysql-1) |
| StatefulSet PVC lifecycle | PVCs NOT deleted when StatefulSet is deleted — intentional (protect data) |

### Questions

**[G] Why is WaitForFirstConsumer binding mode important?**
Default binding (`Immediate`) creates the EBS volume in any AZ as soon as the PVC is created. If the pod later schedules on a node in a different AZ — EBS is AZ-specific, pod can't mount it. `WaitForFirstConsumer` delays EBS provisioning until the pod is scheduled, then creates the volume in the same AZ as the pod. Prevents the AZ mismatch trap completely.

**[S] MySQL pod was stuck in Pending. PVC was also Pending. Why?**
Two possible causes: (1) StorageClass name mismatch — PVC requested `gp2` but no StorageClass was annotated as default. Fix: add `storageclass.kubernetes.io/is-default-class: "true"` annotation to the gp2 StorageClass. (2) AZ mismatch — PVC already bound to a volume in us-east-2a but the pod scheduled on a node in us-east-2c. Fix: use `WaitForFirstConsumer` binding mode in the StorageClass.

**[G] Why does terraform destroy leave orphaned EBS volumes?**
StatefulSet `volumeClaimTemplates` creates PVCs outside Terraform's control — they're not Terraform resources. When the cluster is destroyed, Terraform deletes the StatefulSet but not the PVCs (they were created by K8s, not Terraform). The EBS volumes backing them stay alive. Fix: `scripts/destroy.sh` deletes the PVC before running `terraform destroy`, which triggers K8s to delete the EBS volume.

**[G] EBS vs EFS — when do you use each?**
EBS — block storage, AZ-specific, ReadWriteOnce (only one pod can mount at a time), fast, use for databases. EFS — network filesystem, multi-AZ, ReadWriteMany (multiple pods simultaneously), slower, use for shared config or uploads that multiple pods need to read/write.

---

## 7. RBAC

### Cheat Sheet

| Concept | Key Point |
|---|---|
| No DENY verb | RBAC is additive only — default is deny everything, you add ALLOWs |
| `can-i` returns "no" | Missing ALLOW — not an explicit DENY. Add the missing ALLOW. |
| Role | Namespace-scoped permissions |
| ClusterRole | Cluster-scoped permissions (nodes, PVs, watching all namespaces) |
| ServiceAccount | Pod identity — this is what IRSA annotates |

### Questions

**[G] How does Kubernetes RBAC work? Is there a DENY verb?**
RBAC is purely additive — no DENY verb exists. Everything is denied by default. You create Roles (allowed actions on resources) and RoleBindings (which subject gets the Role). A subject's permissions are the union of all bound Roles. You cannot explicitly deny a specific action on top of an allow. For deny-on-top-of-allow, you need Kyverno or OPA.

**[G] `kubectl auth can-i delete pods` returns "no". Does that mean there's a DENY rule?**
No. "No" means there is no ALLOW rule for that action — not an explicit deny. Don't look for a DENY to remove. Look for the missing ALLOW to add. `kubectl auth can-i --list --as=<user>` shows everything a user CAN do — more useful for debugging than checking individual permissions.

**[G] Role vs ClusterRole — when do you use each?**
Role: namespace-scoped, grants permissions within one namespace. Use for application ServiceAccounts. ClusterRole: cluster-scoped, works across all namespaces or on cluster-level resources (nodes, PVs, StorageClasses). Use for infra tooling — ArgoCD needs to watch all namespaces, ESO needs ClusterSecretStore which is cluster-scoped.

---

## 8. Services & Networking

> Full coverage: [08-networking.md](08-networking.md)

**Quick reference:**

| Service Type | Use |
|---|---|
| ClusterIP | Internal pod-to-pod. Stable VIP. Default. |
| LoadBalancer | External traffic. Provisions NLB/ALB. |
| Headless | No VIP — DNS returns pod IPs. Used by StatefulSets. |

---

## 9. Node Capacity & Pod Limits

### Cheat Sheet

| Concept | Key Point |
|---|---|
| ENI formula | (ENIs × (IPs_per_ENI - 1)) + 2 |
| t3.medium default | 3 ENIs × 6 IPs = 17 pods max |
| Prefix delegation | /28 block (16 IPs) per slot → t3.medium gets up to 288 IPs |
| Why launch template needed | kubelet `--max-pods` is baked at boot — prefix delegation useless without overriding it |
| Our maxPods setting | 110 — set via AL2023 nodeadm `NodeConfig` in launch template user_data |

### Questions

**[G] Why is t3.medium limited to 17 pods by default?**
VPC CNI assigns a real VPC IP to each pod from the node's ENIs. t3.medium supports 3 ENIs × 6 IPs = 18 IPs total. One IP per ENI is reserved for the ENI itself. Formula: (3 × (6-1)) + 2 = 17. This is a hard limit set by the EC2 instance's ENI quota — no amount of node tuning changes the ENI count.

**[G] Prefix delegation gives 16× more IPs. Why do you still need a launch template?**
kubelet's `--max-pods` is baked at node boot time by the EKS bootstrap script — it reads the ENI formula and hardcodes 17. Even if prefix delegation gives 288 IPs available, kubelet refuses to schedule beyond 17 pods because its internal counter says max=17. The launch template overrides `--max-pods` via the AL2023 nodeadm `NodeConfig` spec. You need both changes together: prefix delegation (enough IPs) + launch template (kubelet allowed to use them).
