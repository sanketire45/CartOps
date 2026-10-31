# 07 — AWS Services (Well-Architected)

> Tags: **[G]** conceptual · **[S]** scenario · **[AWS]** AWS-specific
> Structured by the 5 AWS Well-Architected Framework pillars.
> Project: EKS, ECR, IAM+IRSA, Secrets Manager, S3, SQS, KMS, EBS, EFS, NLB, CloudWatch

---

## The 5 Pillars (one-liner each)

| Pillar | What it asks |
|---|---|
| **Security** | Who can access what, and is data protected? |
| **Reliability** | Can the system recover from failures automatically? |
| **Performance Efficiency** | Are we using the right resources at the right size? |
| **Cost Optimization** | Are we paying for what we actually use? |
| **Operational Excellence** | Can we ship, monitor, and improve safely? |

> In interviews, when asked "how would you design X on AWS?" — anchor each decision to a pillar. It shows senior-level systems thinking.

---

## Pillar 1 — Security

### Cheat Sheet

| AWS Service | Role in Security |
|---|---|
| IAM + IRSA | Pod-level identity. No static keys. OIDC trust bridge. |
| Secrets Manager | Credentials at rest. Rotation. ESO pulls into K8s. |
| KMS | Envelope encryption. EKS secrets encryption in etcd. |
| ECR + Inspector | Image scanning on push. Block on critical CVEs. |
| VPC security groups | Node-level firewall (not pod-level — that's NetworkPolicy). |

### Questions

**[G] IAM role vs IAM user — which do you use for EC2/EKS workloads?**
Always roles for workloads — never users with static access keys. Roles provide short-lived credentials via STS `AssumeRole`. Static keys don't expire, get committed to repos, and are the #1 cause of AWS account breaches. For EKS pods specifically: IRSA lets each pod assume a role via OIDC without any key at all.

**[G] What is the difference between a trust policy and a permissions policy on an IAM role?**
Trust policy = who can assume this role (controls the door). Permissions policy = what this role can do once assumed (controls the room). For IRSA: trust policy allows `sts:AssumeRoleWithWebIdentity` from the specific K8s ServiceAccount (via OIDC conditions). Permissions policy allows specific AWS actions — `secretsmanager:GetSecretValue` on `arn:aws:secretsmanager:*:*:secret:ecom/*` only.

**[G] Secrets Manager vs SSM Parameter Store — when do you use each?**
Secrets Manager: built for credentials — rotation, versioning, ~$0.40/secret/month. Use for DB passwords, API keys, anything that needs rotation. SSM Parameter Store: free standard tier, no rotation — use for config values and the AWS public directory (`/aws/service/eks/...` for AMI IDs). In our project: Secrets Manager for mysql password (via ESO), SSM for AMI ID lookup in the launch template.

**[G] What is KMS envelope encryption?**
You never encrypt data directly with the CMK — that's expensive and the CMK can't leave KMS. Instead: KMS generates a data encryption key (DEK), encrypts the actual data with the DEK locally, then encrypts the DEK with the CMK and stores the encrypted DEK alongside the data. To decrypt: KMS decrypts the DEK, you use the DEK to decrypt the data. The CMK never leaves KMS. We use KMS to encrypt K8s Secrets at rest in etcd — `secretsEncryption` in EKS config.

---

## Pillar 2 — Reliability

### Cheat Sheet

| AWS Feature | What it Protects |
|---|---|
| Multi-AZ node groups | Node group spans multiple AZs — single AZ outage doesn't kill all nodes |
| Managed node group rolling update | EKS drains+replaces nodes one at a time, respects PDB |
| EBS `WaitForFirstConsumer` | Pod + volume land in the same AZ — no mount failure |
| NLB vs ALB | NLB is zonal-resilient: static IPs per AZ, traffic fails over |
| S3 | 11 nines durability, multi-AZ by design |
| SQS | At-least-once delivery, DLQ for failed messages |

### Questions

**[G] How does EKS handle an AZ outage?**
If one AZ goes down, EC2 instances in that AZ terminate. The ASG for the managed node group detects the loss and launches replacement nodes in the remaining AZs. Pods on lost nodes are rescheduled by K8s onto surviving nodes. This only works if: (1) the node group spans multiple AZs (subnets in each AZ), (2) your pods have enough replicas so the service is still running on surviving nodes during the recovery period.

**[S] After a node group upgrade, some pods are Pending even though nodes are Ready. Why?**
topologySpreadConstraints or podAntiAffinity with `required` mode. If the upgrade resulted in fewer nodes in a zone temporarily, the hard constraint can't be satisfied — pods sit Pending until the zone has enough nodes. Fix: use `preferred` (soft) anti-affinity and `whenUnsatisfiable: ScheduleAnyway` on topologySpread — pods schedule degraded rather than Pending.

**[G] What is an SQS dead letter queue?**
A secondary queue where messages go after failing delivery N times (configured as `maxReceiveCount`). When order-svc fails to process a message (app crash, timeout), SQS retries up to N times, then moves the message to the DLQ. The DLQ lets you inspect failed messages, debug the root cause, and replay them once fixed — without losing the message.

---

## Pillar 3 — Performance Efficiency

### Cheat Sheet

| Decision | Reason |
|---|---|
| t3.medium for dev cluster | 2 vCPU, 4GB RAM — enough for 5 Spring Boot services. Cheap at ~$0.033/hr |
| gp3 over gp2 for EBS | Same performance baseline, ~20% cheaper, independently configurable IOPS + throughput |
| Prefix delegation | /28 per ENI slot → t3.medium: 288 IPs instead of 17. More pods per node. |
| Launch template maxPods=110 | kubelet override — allows prefix delegation IPs to actually be used |
| NLB for NGINX ingress | Layer 4 — lower latency than ALB. Static IPs. Better for high-throughput TCP. |

### Questions

**[G] Why gp3 over gp2 for EBS?**
gp3 is newer, cheaper (~20% lower cost for same baseline), and lets you independently configure IOPS and throughput without paying for a higher-tier volume. gp2 ties IOPS to volume size (3 IOPS/GB). A 10GB gp2 volume gets 30 IOPS — you'd need to over-provision size to get more IOPS. gp3 gives 3000 IOPS and 125 MB/s baseline regardless of size.

**[G] NLB vs ALB — when do you use each?**
NLB — Layer 4 (TCP/UDP). Ultra-low latency, static IPs per AZ, passes through to the backend unchanged. Use for: NGINX ingress, non-HTTP protocols, when you need static IPs for whitelisting. ALB — Layer 7 (HTTP/HTTPS). Path and host-based routing, WAF integration, native AWS LBC support, better for microservices with different URL paths. Our project: NLB fronts NGINX (which does the L7 routing internally). Future: ALB directly via AWS Load Balancer Controller for native ingress.

---

## Pillar 4 — Cost Optimization

### Cheat Sheet

| Practice | Saving |
|---|---|
| Daily `terraform destroy` (dev cluster) | EKS control plane ~$0.10/hr + EC2 — ~$70/month if always on |
| gp3 over gp2 | ~20% cheaper per GB |
| ECR lifecycle policy | Delete untagged images older than 7 days — S3 storage cost |
| Resource requests set correctly | Scheduler bin-packs pods — fewer nodes needed |
| Spot instances for non-critical workloads | Up to 90% cheaper than On-Demand |
| Budget alert | AWS Budget with SNS alert before hitting spend threshold |

### Questions

**[G] What is the cost impact of not setting resource requests?**
The scheduler places pods without knowing how much CPU/memory they need — it can't bin-pack efficiently. Result: nodes appear "full" (all CPU allocated) but actually have free physical CPU because apps use less than requested (or requested nothing). You end up with more nodes than needed. Also: HPA can't work without requests — it calculates "current usage / requested" to determine scale percentage.

**[G] Spot vs On-Demand for EKS node groups?**
Spot instances are spare EC2 capacity at up to 90% discount but can be interrupted with 2 minutes notice. Safe for: stateless workloads with multiple replicas (interruption just shifts traffic to surviving pods), batch jobs, non-critical services. Not safe for: StatefulSets with single replica (MySQL), anything that can't handle sudden termination. Production pattern: On-Demand for system nodes (Kyverno, ArgoCD), Spot for application workloads.

---

## Pillar 5 — Operational Excellence

### Cheat Sheet

| Practice | Tool |
|---|---|
| Immutable image tags | ECR with git-SHA tags — `:latest` blocked by Kyverno |
| Image vulnerability scanning | ECR Enhanced Scanning (Inspector) on push |
| GitOps — desired state in Git | ArgoCD syncs Git → cluster. No manual kubectl in prod. |
| Deployment automation | Jenkins matrix builds per service, ArgoCD sync |
| Tagging all resources | `Environment=dev`, `Project=ecom` — cost allocation + operations |
| Observability | Prometheus + Grafana + Loki (planned) |
| Runbook for destroy | `scripts/destroy.sh` — documented, repeatable, safe teardown |

### Questions

**[G] Why immutable image tags instead of `:latest`?**
`:latest` is non-deterministic — two deploys with the same tag can run different code if the image was rebuilt between them. Git-SHA tags are immutable — `product-svc:a3f2c91` always refers to exactly that commit. Also: `:latest` forces `imagePullPolicy: Always` which adds latency to every pod start. We enforce this with a Kyverno `deny-latest-tag` ClusterPolicy — any Deployment using `:latest` is rejected at admission.

**[G] What is the ECR image lifecycle policy for?**
ECR stores images in S3 — old untagged images accumulate and cost money. Lifecycle policy automatically deletes untagged images older than 7 days and keeps only the last N tagged images per repo. In our project: `expireUntaggedImages` after 7 days, keep last 10 tagged. The Jenkins pipeline pushes a new git-SHA tagged image on every build — old ones are cleaned up automatically.

**[S] A Jenkins build succeeded but ArgoCD is still running the old version. Why?**
ArgoCD syncs from Git — if the Helm values file wasn't updated with the new image tag, ArgoCD sees no diff and does nothing. The Jenkins pipeline must update `values.yaml` (or the environment-specific overlay) with the new ECR image tag and commit it to Git. ArgoCD detects the Git change and syncs. Without the Git commit step, the image pushed to ECR is never deployed.

---

## Pillar 6 — Disaster Recovery & Backup

### Cheat Sheet

| Tool / Feature | What It Does | When to Use |
|---|---|---|
| EBS Snapshots | Point-in-time incremental backup of EBS volumes stored in S3 | Database volumes, stateful workloads |
| AWS DLM | Data Lifecycle Manager — automated EBS snapshot schedule, free | EBS-only, simple retention rules |
| AWS Backup | Centralised backup service — EBS, RDS, EFS, DynamoDB, cross-account | Multi-service, compliance, Vault Lock WORM |
| RDS automated backups | Built-in to RDS — daily snapshot + transaction logs for PITR. On by default (7d retention). | All RDS instances |
| Aurora backups | Always on, cannot be disabled. PITR to any second within 35 days. | Aurora only |
| `delete_automated_backups = false` | Terraform flag — keeps RDS backups when the instance is destroyed. | Production RDS Terraform config |
| DR tiers | Backup/Restore (hours) → Pilot Light (minutes) → Warm Standby (seconds) → Active-Active (zero) | Match RTO/RPO to business need |

### Questions

**[G] What is the difference between AWS DLM and AWS Backup for EBS?**
DLM (Data Lifecycle Manager) is EBS-only and free. You create a lifecycle policy that takes snapshots on a schedule (e.g. daily at 02:00) and retains the last N. Simple, zero overhead for single-service EBS backup. AWS Backup is a centralised backup service that covers EBS, RDS, EFS, DynamoDB, Aurora, S3, and more. It adds: cross-account backup copy, cross-region copy, compliance reports, Vault Lock (WORM — snapshots can't be deleted even by admins), and unified backup policies across services. Use DLM for: EBS-only, simple retention. Use AWS Backup for: compliance-driven environments, multi-service backup governance, cross-account DR.

**[G] Are RDS and Aurora automated backups enabled by default?**
RDS automated backups: on by default with 7-day retention, but can be disabled by setting `backup_retention_period = 0`. AWS Backup is NOT required — RDS has its own native mechanism that stores daily snapshots + transaction logs to S3 (managed by AWS). Aurora automated backups: always enabled, cannot be disabled. Both support PITR (Point-in-Time Recovery) — you can restore to any second within the retention window. Critical Terraform flag: `delete_automated_backups = false` on the RDS resource — without this, when you run `terraform destroy` in dev, automated backups are deleted immediately.

**[G] Walk me through restoring an EBS volume from a snapshot in Kubernetes.**
Scenario: MySQL StatefulSet's EBS volume was deleted. Step 1: pod goes Pending (no volume to attach). Step 2: create a new EBS volume from the snapshot in the same AZ — `aws ec2 create-volume --snapshot-id snap-xxx --availability-zone us-east-2a --volume-type gp3`. Step 3: the PVC is still bound to the old PV (which now has a dead volume reference). Patch the PV's `spec.csi.volumeHandle` with the new EBS volume ID: `kubectl patch pv <pv-name> -p '{"spec":{"csi":{"volumeHandle":"vol-newid"}}}'`. Step 4: pod scheduler re-evaluates, volume is available, pod mounts it and starts. Key point: only the PV's `volumeHandle` changes — PVC binding and all other resources are untouched.

**[G] What are the four DR tiers and what RTO/RPO does each give?**
1. **Backup & Restore** — snapshots to S3, restore when needed. RTO: hours. RPO: hours (last snapshot). Cheapest. Use for non-critical data or long RPO tolerance.
2. **Pilot Light** — minimal core infrastructure (RDS, ECR) always running. EKS is off. On disaster: run Terraform to provision EKS, deploy from Git. RTO: 20-30 min. RPO: near-zero (RDS PITR). Use for dev/staging DR.
3. **Warm Standby** — scaled-down duplicate environment in DR region. DB replica, minimal EKS nodes. On disaster: scale up, promote replica to primary, switch DNS. RTO: minutes. RPO: seconds (replica lag).
4. **Active-Active** — full traffic in multiple regions simultaneously. Route53 latency routing or weighted records split traffic. Zero RTO, near-zero RPO. Most expensive. Use for global customer-facing production.

**[G] Explain the difference between Availability and Reliability.**
Availability: is the system *up*? Measured as uptime percentage — "five nines" means 99.999% uptime, ~5 minutes downtime per year. A system is available if it responds at all, even with degraded correctness. Reliability: does the system *work correctly* when it's up? A system that is up but returns wrong data, drops messages, or silently fails is available but not reliable. K8s features for availability: replicas, PDB, rolling updates, readiness probes, HPA. K8s features for reliability: graceful shutdown (SIGTERM handler + `terminationGracePeriodSeconds`), SQS `ON_SUCCESS` ack (message only removed after successful processing), idempotent API design (duplicate order request doesn't create duplicate charges), circuit breakers. Most "reliability" sections in job postings are actually asking about both — know the distinction when answering.

**[S] How would you design a disaster recovery strategy for this EKS platform?**
Answer by layer: (1) **K8s objects** — all in Git (ArgoCD GitOps). In any disaster, `argocd app sync ecom-dev` recreates everything. No backup needed. (2) **EBS volumes (MySQL data)** — DLM daily snapshots with 7-day retention. In DR, create new EBS from latest snapshot and patch PV volumeHandle. (3) **RDS** — automated backups + PITR enabled. Cross-region read replica for warm standby. Promote replica and update connection string in Secrets Manager for prod failover. (4) **EKS cluster** — Terraform IaC. In disaster: `terraform apply` in DR region recreates cluster in ~20 min. (5) **DNS + traffic** — Route53 health checks on primary ALB. On health check failure → Route53 failover record points to DR region ALB. This maps to Pilot Light (EKS) + Warm Standby (RDS) tier — RTO ~20-30 min, RPO near-zero for DB.

**[G] How do you reduce cloud costs without affecting availability?**
Five production levers: (1) **KEDA scale-to-zero** — async workers (notification-worker) run 0 pods when queue is empty. Zero cost overnight. (2) **Karpenter consolidation** — merges underutilised nodes, removes half-empty ones CA would leave. Actively right-sizes the cluster. (3) **Spot instances** — 60-70% cheaper for stateless services with multiple replicas. Karpenter handles interruptions with graceful shutdown + rescheduling. (4) **Accurate resource requests** — right-size with VPA recommendations. Overprovisioned requests waste slot capacity and trigger unnecessary CA scale-up. (5) **Daily cluster destroy for dev** — we run `terraform destroy` every night in dev (`scripts/destroy.sh`), saving ~$70/month on a 3-node EKS cluster. Data in EBS and RDS survives the destroy — only compute is deallocated. Prod stays always-on; dev burns money only during working hours.
