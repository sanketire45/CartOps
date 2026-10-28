# 09 — Scaling & Autoscaling

> Tags: **[G]** conceptual · **[S]** scenario
> Project: HPA (#24 — planned), Cluster Autoscaler (#26a — planned), KEDA (#25 — planned)
> Fill sections as tasks are implemented. Cheat sheets reflect what we know now.

---

## Sections
1. [HPA — Horizontal Pod Autoscaler](#1-hpa--horizontal-pod-autoscaler)
2. [VPA — Vertical Pod Autoscaler](#2-vpa--vertical-pod-autoscaler)
3. [Cluster Autoscaler](#3-cluster-autoscaler)
4. [Karpenter](#4-karpenter)
5. [KEDA — Event-Driven Autoscaling](#5-keda--event-driven-autoscaling)
6. [SLI / SLO / Error Budget](#6-sli--slo--error-budget)
7. [Scaling Best Practices](#7-scaling-best-practices)

---

## 1. HPA — Horizontal Pod Autoscaler

### Cheat Sheet

| Concept | Key Point |
|---|---|
| What it does | Scales pod replica count based on metrics |
| Requires | metrics-server (for CPU/mem) or custom metrics adapter |
| Scale-up trigger | Current usage / requested > target threshold |
| Scale-down delay | Default 5 min stabilisation window — prevents thrashing |
| Resource requests MUST be set | HPA calculates % usage — without requests, it can't calculate |
| `minReplicas` / `maxReplicas` | Bounds — HPA never goes below min or above max |

### Questions

**[G] How does HPA decide when to scale up?**
HPA compares current metric value against the target. For CPU: `desiredReplicas = ceil(currentReplicas × (currentCPU / targetCPU))`. Example: 2 replicas, each using 80% CPU, target is 50% → `ceil(2 × (80/50)) = ceil(3.2) = 4`. Scale to 4 replicas. This is why resource requests must be set — "current CPU" is measured as a percentage of the requested CPU, not the node's total CPU.

**[G] Why does HPA scale down slowly compared to scale up?**
Scale-down has a stabilisation window (default 5 minutes). HPA waits to see if the load drop is sustained before removing pods. Prevents thrashing: load spikes for 30 seconds, HPA scales up → load drops → HPA immediately scales down → load spikes again. The window absorbs short-lived dips. Scale-up has no delay — responding to load fast is more important than avoiding a few extra pods.

**[S] HPA is configured but pods never scale. `kubectl describe hpa` shows "unable to fetch metrics". Why?**
metrics-server is not installed. HPA requires metrics-server to get CPU/memory readings from kubelet. Install via `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml`. Also check: are resource `requests` set on the Deployment? Without requests, metrics-server returns values but HPA can't calculate a percentage → shows 0% utilisation → never scales.

<!-- Fill with project-specific answers when task #24 is done -->

---

## 2. VPA — Vertical Pod Autoscaler

### Cheat Sheet

| Mode | Behaviour |
|---|---|
| `Off` | Recommends only — shows what requests should be. Doesn't change anything. |
| `Initial` | Sets requests when pod first starts. Never updates running pods. |
| `Auto` | Evicts and restarts pods to apply new requests — disruptive. |
| HPA + VPA conflict | Both on CPU: VPA changes requests → HPA's % calculation changes → feedback loop |
| Safe combo | HPA on custom metrics (request rate) + VPA on memory only |

### Questions

**[G] VPA vs HPA — when do you use each?**
HPA: stateless services with variable traffic — add more pods when load increases. VPA: right-sizing pods whose resource usage is predictable but poorly configured — a Java app that always uses 1.5GB RAM but you set 512MB. VPA `Off` mode is genuinely useful just for recommendations — run it for a week on a new service to see what requests should actually be, then set them manually. Never use VPA `Auto` on a service that already has HPA on the same metric.

**[G] Why do VPA and HPA conflict when both use CPU?**
VPA sees pod uses 100% of its CPU request → VPA increases the request from 200m to 400m. Now pod uses 50% of its request. HPA sees 50% → scales down from 4 pods to 2. Now 2 pods handle the same load → CPU spikes to 100% again → VPA increases request again → HPA scales down again. Loop. Safe pattern: HPA on request rate (from Prometheus), VPA on memory only. They don't touch the same metric.

---

## 3. Cluster Autoscaler

### Cheat Sheet

| Concept | Key Point |
|---|---|
| What it does | Adds or removes EC2 nodes based on pending pods / underutilised nodes |
| Scale-up trigger | Pod is Pending because no node has enough capacity |
| Scale-down trigger | Node is underutilised for 10+ min and all pods can move elsewhere |
| Works with ASG | Modifies ASG `desired count` — AWS launches the EC2 |
| topologySpreadConstraints interaction | Constraints can keep pods Pending even after a node is added (wrong AZ) |
| Slower than Karpenter | Must wait for ASG to launch EC2, node to join, then schedule. ~2-5 min. |

### Questions

**[G] How does Cluster Autoscaler know which node group to scale?**
It checks which node groups have capacity to satisfy the Pending pod's resource requests, node selectors, and tolerations. If multiple node groups qualify, it picks the one that results in the least waste (cheapest). It also checks whether adding a node would actually make the pod schedulable — if the pod has a topologySpreadConstraints requiring a specific AZ and that node group doesn't cover that AZ, it won't scale that group.

**[G] Cluster Autoscaler vs Karpenter — key difference?**
Cluster Autoscaler: works with existing fixed node groups (ASGs). Picks which pre-defined group to scale. Slow — 2-5 min for a new node. Karpenter: bin-packs pending pods, selects the exact right instance type for those specific pods, launches EC2 directly (bypasses ASG). Faster — ~60s for a new node. Karpenter also consolidates: if 3 half-full nodes can fit on 2, it drains + terminates one. We'll implement Cluster Autoscaler first (#26a — launch template already done), Karpenter as an upgrade (#26b).

<!-- Fill with project-specific answers when task #26a is done -->

---

## 4. Karpenter

### Cheat Sheet

| Concept | Key Point |
|---|---|
| NodePool CRD | Defines what instance families/sizes Karpenter can provision |
| EC2NodeClass CRD | AWS-specific config — AMI, subnets, security groups, instance profile |
| Bin-packing | Picks the smallest instance type that fits all pending pods |
| Consolidation | Actively removes underutilised nodes by draining and rescheduling pods |
| No fixed node groups | Karpenter manages EC2 directly — more flexible than ASG-based CA |

<!-- Fill with project-specific answers when task #26b is done -->

---

## 5. KEDA — Event-Driven Autoscaling

### Cheat Sheet

| Concept | Key Point |
|---|---|
| What it does | Scales pods based on external event sources — not CPU/memory |
| ScaledObject CRD | Defines the trigger source and scaling parameters |
| Scale to zero | When queue is empty, KEDA can scale to 0 pods (HPA minimum is 1) |
| SQS trigger | Scale notification-worker based on SQS queue depth |
| Kafka trigger | Scale consumer based on consumer group lag |

### Questions

**[G] What is KEDA and when does HPA not work?**
KEDA (Kubernetes Event-Driven Autoscaling) scales pods based on external event sources — SQS queue depth, Kafka consumer lag, Redis list length. HPA works on CPU/memory — internal metrics. A notification worker that processes SQS messages: when the queue is empty it should have 0 pods, when it has 10,000 messages it needs 50 pods. CPU doesn't reflect this — the worker might be idle (low CPU) while messages pile up. KEDA reads the SQS queue depth directly and scales accordingly.

<!-- Fill with project-specific answers when task #25 is done -->

---

## 6. SLI / SLO / Error Budget

### Cheat Sheet

| Term | Definition | Example |
|---|---|---|
| SLI | Metric measuring service behaviour | 99.2% of requests returned 2xx this month |
| SLO | Internal target for an SLI | 99.9% availability |
| SLA | Contractual floor signed with customers | 99.5% — always lower than SLO |
| Error budget | Allowed downtime = (1 - SLO) × period | 99.9% SLO = 43.2 min/month |
| Budget burn | Incidents consuming the error budget | 1 bad deploy = 8 min = 18% of monthly budget |

### Questions

**[G] What is an error budget and how does it change the dev vs ops dynamic?**
Error budget = (1 - SLO) × time period. At 99.9% monthly SLO: 43.2 minutes of downtime allowed. While budget is healthy: ship features fast, take risks. When budget burns fast (>50% gone in 2 weeks): pause features, do a reliability sprint. It removes the ops-vs-dev argument — the budget is the referee. Dev team's features burn the budget when they cause incidents, so they have direct incentive to write reliable code. Reliability becomes a shared engineering problem, not just ops' problem.

**[S] A team burned 80% of their monthly error budget in the first week. What happens next?**
Feature work pauses — reliability sprint kicks in. Root cause every incident that burned budget: bad deploy (missing canary? no PDB? failing readiness probe?). Fix the gaps. Run chaos engineering to validate. Only resume feature work once budget is restored. The error budget makes this a data-driven decision — not a heated ops-vs-dev meeting.

---

## 7. Scaling Best Practices

### Cheat Sheet

| Practice | Why |
|---|---|
| Set resource requests on all pods | Required for HPA, required for scheduler bin-packing |
| PDB before enabling autoscaling | CA scale-down respects PDB — won't evict the last pod |
| Readiness probe before enabling HPA | Pod must be actually ready before receiving scaled traffic |
| topologySpreadConstraints with HPA | Ensures scaled replicas spread across AZs, not pile up in one |
| Scale-down stabilisation window | Prevents rapid scale-up → scale-down thrash on variable load |

### Questions

**[G] What happens if you enable HPA without resource requests?**
HPA uses the formula: `desiredReplicas = ceil(currentReplicas × (currentUsage / targetUsage))`. "currentUsage" is expressed as a percentage of the requested resources. With no requests set: the API returns `<unknown>` for utilisation — HPA shows 0% CPU and never scales, or throws errors. The Deployment also doesn't benefit from scheduler bin-packing, and Cluster Autoscaler can't calculate whether adding a node would help. Resource requests are the foundation — everything else (HPA, CA, scheduler) depends on them.
