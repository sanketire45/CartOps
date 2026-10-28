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
