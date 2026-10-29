# 🛒 Ecommerce-Spring → Industry-Grade EKS Platform — Task Roadmap

> **Why this project:** genuine **Spring Boot microservices** (Product&Category · Order · Eureka) with real REST APIs, inter-service Feign calls, MySQL+Flyway, and a live external API — the real microservices target our EKS/monitoring work assumes. **App layer is strong; platform layer is what we build.**
>
> **The big win:** the entire **Terraform foundation + platform patterns from Wanderlust port here almost unchanged.** Task IDs `(#N)` stay in sync with `DevOps-End-To-End-Project/Todos/eksTodos.md`.
>
> **Services:** `frontend` (nginx :80) · `product-category` (Spring Boot :8080) · `order-service` (Spring Boot :7878) · `eureka-server` (Spring Boot :8761) · `mysql` (StatefulSet :3306)
>
> Status: ✅ done · ⚠️ partial · ❌ missing · 🔨 to build · 🗣️ explain-only

---

## 📦 What the project already has (strong base)

| Capability | Status | Maps to |
|---|---|---|
| 3 microservices + Eureka discovery + inter-service Feign REST | ✅ | microservices gap (#38) — **already real** |
| Real REST APIs + external FakeStore API | ✅ | actual API traffic |
| Multi-stage Dockerfiles — JRE-alpine runtime, non-root user | ✅ | #17 ✅ hardened |
| Helm chart `helm/ecom` (per-service templates, single chart) | ✅ | #18 ✅ done |
| `values-dev.yaml` / `values-prod.yaml` | ✅ | #5 ✅ multi-env |
| HPA on product-category | ✅ | #24 (extend to order-svc) |
| MySQL StatefulSet + headless Service + PVC | ✅ | #31 (confirm gp3 + WaitForFirstConsumer on EKS) |
| MySQL backup Job + CronJob | ✅ | Jobs/CronJobs |
| ConfigMap + basic Secret template | ✅ | baseline |
| docker-compose (local dev + healthchecks) | ✅ | local dev |
| Liveness/readiness/startup probes in all Helm templates | ✅ | #27 ✅ done |
| React/Vite frontend + nginx Dockerfile + Helm templates | ✅ | Phase 0 ✅ done |
| Ingress path-routing template in Helm | ✅ | Phase 0 ✅ done |

---

## 🧭 BUILD ORDER (follow this — dependency-correct sequence)

> ⚠️ Task numbers are **stable IDs** (like tickets) grouped by theme — they are NOT the build order. Follow the phases below.

### PHASE 0 — App ready ✅ (5/5 complete)
- [x] **Consolidate Helm** → deleted `helm/ecom-chart` scaffold; single chart at `helm/ecom`.
- [x] **Harden Dockerfiles (#17)** → runtime `eclipse-temurin:17-jre-alpine`, non-root `appuser`, `.dockerignore`. All 3 services + frontend.
- [x] **ADD FRONTEND** ⭐ → React/Vite SPA: Products catalogue, ProductDetail, Orders pages; calls relative `/api/...`; nginx Dockerfile + Helm templates.
- [x] **Ingress path-routing** → `helm/ecom/templates/ingress.yaml`: `/` → frontend, `/api/products` + `/api/categories` → product-svc, `/api/orders` → order-svc.
- [x] **Probes (#27)** → startup + liveness + readiness via `/actuator/health/liveness|readiness` on all 3 Helm deployment templates.

---

### PHASE 1 — Foundation · Terraform · config-only · no credits

> **🏗️ Architecture decision (decide before writing any Terraform):**
> EKS offers two modes: **Standard EKS** (you manage compute — node groups, Karpenter, CA) and **EKS Auto Mode** (AWS manages Karpenter-based provisioning for you). We deliberately choose **Standard EKS** — the goal is hands-on learning of Karpenter, Cluster Autoscaler, node groups, and node-level diagnostics. EKS Auto Mode abstracts away exactly what we need to see. When an interviewer asks "have you set up Karpenter?" the Standard EKS answer is concrete; Auto Mode is "AWS did it."

```
#1 remote state → #2 managed add-ons → #3 node strategy → #4 cluster access → variables adapt
```

- [x] **#1 Terraform remote state → S3 + native S3 locking** ✅
  Port `backend-bootstrap.sh` from Wanderlust. Bucket: `ecom-tfstate` (versioning + encryption on). Use **`use_lockfile = true`** in the S3 backend — HashiCorp deprecated DynamoDB-based locking; S3 native locking is the current approach and removes the extra DynamoDB dependency. The backend bucket must be bootstrapped separately (manually or via a bootstrap script) before the main Terraform config can reference it.
  *Interview: "how do you manage Terraform state in a team?" → S3 remote state + native locking, versioning for rollback, separate bootstrap for the bucket itself.*

- [x] **#2 EKS managed add-ons via `aws_eks_addon`** ✅
  Port `addons.tf` from Wanderlust. Add-ons: `vpc-cni`, `coredns`, `kube-proxy`, **`aws-ebs-csi-driver`** (IRSA), **`aws-efs-csi-driver`** (IRSA), `eks-pod-identity-agent`. Change cluster name to `ecom`.
  *Interview: "managed add-ons vs installing yourself?" → AWS patches them, version-pinned, upgrade-safe.*

- [x] **#3 Node strategy** — system managed node group (On-Demand, labeled `role: system`) + Karpenter NodePool for workloads ✅
  Port `node-groups.tf`. Build Cluster Autoscaler first (#26a) to feel its limits, then migrate to Karpenter (#26b).

- [x] **#4 Cluster access: IAM Access Entries** (modern) ✅
  Port `cluster-access.tf`. Document legacy `aws-auth` ConfigMap alongside — the classic lockout trap. API mode enabled.
  *Interview: "how do you manage EKS access?" → Access Entries vs aws-auth — know both.*

- [x] **Adapt `variables.tf`** → `cluster_name = "ecom"`, `region`, ECR repo names for 4 services. Point Helm images at ECR URIs. ✅

- [ ] **#6 🗣️ EXPLAIN-ONLY** 📖 *(cover on-demand when hitting IP issues)* — VPC CNI internals: pod gets a real VPC IP from an ENI; `max-pods` cap per instance type. **Prefix delegation:** instead of assigning one IP per ENI slot, assign a /28 prefix (16 IPs) per slot. This increases pod density, but the actual gain depends on the instance's ENI count, prefix slots, available subnet IPs, and the kubelet `max-pods` limit — it is not a guaranteed "16×" increase. Diagnose IP exhaustion by inspecting `aws-node` pod logs, `kubectl get nodes -o wide` for IP usage, and free IPs in the subnet via AWS console.

- [ ] **#7 🗣️ EXPLAIN-ONLY** 📖 *(cover on-demand)* — Fargate vs managed node groups: no DaemonSets on Fargate, pay-per-pod, fixed sizes. When to use each.

- [x] **AWS networking fundamentals — document before touching infra** ✅
  Draw the VPC layout: public subnets (ALB, NAT GW), private subnets (EKS nodes, pods). Know: route tables (public → IGW, private → NAT), security groups (ALB SG → node SG → pod ports), EKS control-plane endpoint (public or private). For a **private cluster** (nodes in private subnets), pods need connectivity to ECR, S3, STS, and Secrets Manager — either via NAT Gateway or **VPC endpoints** for each. Without this, image pulls and AWS API calls silently fail. This is a higher-priority gap than any additional Kubernetes controller.
  *Interview: "worker node can't pull ECR images in a private subnet?" → missing ECR VPC endpoint (`com.amazonaws.region.ecr.api` + `com.amazonaws.region.ecr.dkr`) and S3 gateway endpoint.*

- [x] **Cost controls — Budget alert + tagging + teardown procedure** ✅
  Add an AWS Budget alert (email/Slack when spend exceeds $20). Apply cost tags to all Terraform resources: `Project = ecom`, `Env = dev`. Document a teardown order: destroy EKS cluster → EBS volumes → ECR repos → VPC/SGs → S3 bucket last. EKS, EC2 (nodes), NAT Gateway, ALB, EBS, EFS, and CloudWatch Logs all generate costs even with zero traffic. A running cluster costs ~$5–10/day — always destroy after a session.
  *Interview: "how do you control cloud costs?" → tagging strategy, Budget alerts, scheduled cluster teardown for dev.*

---

### PHASE 2 — Delivery & GitOps · config-only · mostly cluster-down

```
#16 ECR+SHA → #14 image scanning → CI pipeline (Jenkins) → #19 ArgoCD app-of-apps → #5 multi-env wired
```

- [x] **#16 Amazon ECR + immutable git-SHA tags + lifecycle policy** ✅ ⭐
  Create 4 ECR repos: `ecom/frontend`, `ecom/product-category`, `ecom/order-service`, `ecom/eureka`. Enable **tag immutability** (no overwriting a SHA). Lifecycle: expire untagged images after 7 days, keep last 10 tagged. Tag format: `:<GIT_SHA>` — never `:latest`.
  *Interview: "why not :latest?" → can't trace what's running, stale-cache bugs, rollback impossible.*

- [x] **#14 ECR image scanning (enhanced / Inspector) on push** ✅
  Enable scan-on-push for all 4 repos. Surface CRITICAL/HIGH findings — block promotion in CI if any found. (We already have Trivy in CI; this adds registry-side scanning as a second gate.)

- [x] **CI pipeline (Jenkins) — matrix build per service** ✅
  Jenkinsfile: parallel matrix stage builds all 4 images simultaneously. Each stage: `docker build → Trivy scan → docker push :<GIT_SHA>` to ECR. On success: update the image tag in `helm/ecom/values-prod.yaml` and commit (GitOps trigger for ArgoCD).

- [ ] **Terraform CI/CD pipeline** ⏳ *(do after Phase 3 cluster is stable — needs working cluster first)*
  Extend the Jenkins pipeline to cover infrastructure changes, not just application builds. Stages: `terraform fmt --check` (fail on unformatted code) → `terraform validate` → **Checkov** or `tfsec` (IaC security scanning — fail on HIGH findings) → `terraform plan` (saved as artifact, requires human review/approval before apply) → `terraform apply` (gated by approval). Use **short-lived AWS credentials** via Jenkins IRSA or assumed role — never store long-lived access keys in Jenkins credentials. Add drift detection: a scheduled daily `terraform plan` that alerts if the live infrastructure diverges from state.
  *Interview: "how do you manage infrastructure changes safely?" → same CI discipline as app code: scan → plan → review → apply. IaC security scanning catches misconfigurations before they reach production.*

- [x] **#19 ArgoCD app-of-apps + sync waves** ✅
  One root `Application` that bootstraps all others from Git (eliminates manual `kubectl apply`). Sync-wave annotations so CRDs/operators (ESO, Kyverno, Karpenter) install **before** resources that depend on them. Auto-sync + self-heal on.
  *Interview: "GitOps bootstrap" → app-of-apps pattern, sync waves for ordering.*

- [x] **#5 Multi-env wired into ArgoCD** ✅
  Already have `values-dev.yaml` / `values-prod.yaml`. Wire as two ArgoCD Applications pointing at the same chart, different values files. Dev auto-syncs on every push; prod requires manual promotion.

- [ ] **#20 Argo Rollouts — canary + Prometheus auto-rollback** ⏳ *(do AFTER monitoring phase — needs Prometheus for AnalysisTemplate)* ⭐
  Convert `product-category` Deployment → `Rollout`. For canary steps (10% → 50%) to represent real **weighted traffic** (not just pod ratio), configure: (1) a `stable` Service + a `canary` Service, (2) Argo Rollouts ALB traffic-routing integration (alb `ingress` or `targetGroupBinding`), so the ALB target group weights are programmatically shifted. Add ALB **pod readiness gates** so a new pod isn't marked ready until its ALB target is healthy. `AnalysisTemplate` queries Prometheus error-rate on `/api/products`. Bad deploy → auto-abort. ⚠️ Needs Prometheus → do after monitoring phase.
  *Interview: "canary vs blue-green" → real canary splits traffic at the load-balancer, not at the pod level. Without ALB integration, 1 canary pod out of 10 pods is 10% by coincidence, not by policy.*

- [x] **#21 Graceful shutdown** — `terminationGracePeriodSeconds: 30` + `preStop: sleep 5` + Spring handles SIGTERM ✅
  The `preStop` sleep gives the load balancer time to drain the endpoint before SIGTERM fires. Without it: traffic hits a pod that's already shutting down → 502s during deploys.
  *Interview: "zero-downtime deploy" → endpoint removal races SIGTERM; preStop bridges the gap.*

- [x] **#22 Rolling-update knobs** — `maxUnavailable: 0` + `maxSurge: 1` on all deployments ✅
  `maxUnavailable: 0` means no pod is killed until a new one is healthy (readiness-gated). `maxSurge: 1` = one extra pod during rollout. Applied to all 4 services.

---

### PHASE 3 — Cluster-UP batch · needs running cluster · burns credits · one session

> Run this in a single session to minimise time the cluster is up. Sub-groups can overlap.

#### Security (#8 → #9 → #10 → #11 → #12 → #13)

- [x] **#8 External Secrets Operator + AWS Secrets Manager via IRSA** ✅
  Install ESO. Create `SecretStore` (IRSA-auth to Secrets Manager). Create `ExternalSecret` that pulls `ecom/mysql-password` + `ecom/jwt-secret` → K8s Secret. Delete the plaintext `mysql-secret` from Git. Add KMS envelope encryption on etcd.
  *Interview: "how do you keep secrets out of Git?" → ESO + Secrets Manager + IRSA. No static password in the pod.*

- [x] **#9 Scoped IRSA per workload** ✅
  IRSA is for **application AWS API calls** — it is NOT how kubelet pulls ECR images. Kubelet uses the **node IAM role** for image pulls; that role needs `ecr:GetDownloadUrlForLayer` etc. IRSA scopes application-level AWS access. Scope each service: `order-service` IRSA = SQS `SendMessage` only. `notification-worker` IRSA = SQS `ReceiveMessage` + `DeleteMessage` only. `product-category` IRSA = Secrets Manager `GetSecretValue` on `ecom/*` only.
  *Interview: "IAM blast radius" → broad node role leaks to every pod on the node; IRSA binds an IAM role to a single ServiceAccount via OIDC — compromise of one pod can't access another service's AWS resources.*

- [x] **#10 Pod `securityContext` → Pod Security "restricted"** ✅
  On all 5 services: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`, `seccompProfile: RuntimeDefault`. Add to Helm deployment templates.
  *Interview: "if a pod is compromised, what limits the damage?" → securityContext + NetworkPolicy + IRSA scope.*

- [x] **#11 Kyverno admission policies** ✅
  Install Kyverno. Enforce cluster-wide: block running as root · require resource limits · disallow `:latest` tag · require liveness + readiness probes. Watch a bad manifest get **rejected at admission** — not just flagged.
  *Interview: "how do you enforce standards across 100 services?" → policy engine, not per-chart conventions.*

- [x] **#12 Default-deny NetworkPolicy + explicit allow-list** ✅
  Enable VPC CNI network-policy add-on. Apply default-deny in `ecom` namespace. **Important path reality:** the React frontend makes `/api/...` requests from the **browser** through the ALB — the frontend **pod** itself does not call backend service pods. Real ingress/egress rules:

  **Ingress (who may receive traffic):**
  - `product-category` ← ALB worker nodes (allow from ALB subnet CIDR on :8080)
  - `order-service` ← ALB worker nodes (allow from ALB subnet CIDR on :7878)
  - `eureka-server` ← product-category, order-service, notification-worker (on :8761)
  - `mysql` ← product-category, order-service, notification-worker (on :3306)

  **Egress (who may initiate traffic):**
  - `order-service` → product-category :8080 (Feign call)
  - `order-service` → SQS endpoint (external, port 443)
  - `product-category` → FakeStore API (external, port 443)
  - `notification-worker` → SQS endpoint (external, port 443)
  - All pods → kube-dns :53 UDP+TCP

  Watch traffic break, then add rules one at a time. Validate with `netshoot` `curl` + `nc`.
  *Interview: "east-west security" — 5 real service paths, real external egress, real ALB ingress. Most toy examples skip the ALB CIDR and external egress entirely.*

- [x] **#13 Pod Security Standards namespace labels** ✅

- [x] **#15 🗣️ EXPLAIN-ONLY** ✅ — Falco + RBAC covered on-demand.

---

#### Reliability (#29 → #28 → #21 → #22)

- [x] **#29 Multiple replicas + anti-affinity** ✅ — product/order/frontend: replicaCount=2 + podAntiAffinity preferredDuringScheduling topologyKey:hostname
  product-category: 2 replicas. order-service: 2 replicas. frontend: 2 replicas. Add `podAntiAffinity` (preferredDuringScheduling) to spread across nodes/AZs. Update `values-prod.yaml`.

- [x] **#28 PodDisruptionBudget + topologySpreadConstraints** ✅
  Add PDB (`minAvailable: 1`) for product-category + order-service. Add `topologySpreadConstraints` (spread across AZs, `maxSkew: 1`). Drain a node → watch PDB hold the line.
  *Interview: "PDB ≠ hardware failure protection" — it only governs voluntary disruptions (drain, upgrade, eviction).*

- [x] **#30 🗣️ EXPLAIN-ONLY** ✅ — VPA (resizes one pod; fights HPA on same metric); SLI/SLO/error budgets (SRE); EKS zero-downtime upgrade war story.

---

#### Scaling (#23 → #24 → #38 → #25 → #26a → #26b)

- [x] **#23 metrics-server** ✅ — `terraform/metrics-server.tf` helm_release, `--kubelet-preferred-address-types=InternalIP`, depends_on coredns.

- [x] **#24 HPA on CPU + memory** ✅ *(Phase 3 — after #23 metrics-server)*
  HPA on both product-category + order-service (autoscaling/v2, CPU target 60%, min 2 max 5). Added resources.requests.cpu to both deployments (HPA denominator). Load-tested with busybox load-gen pods — watched live scale 2→5 replicas then scale-down with 300s stabilization window. Kyverno + PSA blocked a plain `kubectl run` — fixed with securityContext + pinned tag. PolicyReport FAIL=1 fixed for eureka + frontend by adding resource limits.
  *Interview: "HPA formula" → `ceil(current × cur/target)`; HPA can't scale to zero (KEDA can).*

- [x] **#38 Add `notification-worker` microservice** ✅ *(Phase 3 — major feature, unlocks KEDA + NetworkPolicy + tracing stories)*
  **This is the most important architectural addition.** When an order is placed, `order-service` publishes an event to **AWS SQS** (`order-events` queue). New `notification-worker` Spring Boot service consumes SQS and writes a "notification sent" record to MySQL.

  **Build it with production SQS reliability from the start:**
  - **Dead-letter queue (DLQ):** after N failed processing attempts, the message moves to `order-events-dlq`. Alert on DLQ depth.
  - **Idempotent processing:** SQS Standard queues may deliver a message more than once. The worker must be idempotent — check if orderId was already processed before writing.
  - **Visibility timeout:** set longer than max processing time so a slow consumer doesn't cause re-delivery mid-processing.
  - **Transactional outbox:** `order-service` writing to MySQL + publishing to SQS is two operations — if MySQL commits but SQS publish fails, the event is lost. Pattern: write an "outbox" row in the same MySQL transaction, then a separate process reads and publishes it. This guarantees at-least-once delivery.
  - **Alert:** add a CloudWatch alarm on `ApproximateAgeOfOldestMessage` — the canary metric for a stuck consumer.

  Unlocks all at once:
  - KEDA scale-on-SQS (#25) — the event-driven autoscaling star story
  - Real east-west NetworkPolicy (#12) — now 5 services talk, not 4
  - Distributed tracing across an async hop (monitoring)
  - Genuine "event-driven microservices" line on CV
  *Interview: "what happens if SQS publish fails after MySQL commits?" → transactional outbox pattern. "How do you handle duplicate SQS delivery?" → idempotent consumer. These are the follow-up questions that separate candidates who built it from those who read about it.*

- [ ] **#25 KEDA — event-driven autoscaling on SQS** 🔨 ⭐⭐ *(Phase 3 — after #38 notification-worker)*
  Install KEDA. `ScaledObject` with `aws-sqs-queue` trigger on the `order-events` queue. `notification-worker` IRSA = SQS receive only. Prove **scale-to-zero** when queue is empty. Push 100 messages → watch pods appear.
  *Interview: "CPU HPA vs KEDA" → CPU lags the actual workload; KEDA reacts to the queue depth directly, scales to zero saving cost.*

- [ ] **#26a Cluster Autoscaler FIRST** 🔨 *(Phase 3 — install to feel its limits, then migrate to Karpenter #26b)*
  Install CA on the managed node group. Make pods unschedulable (request more CPU than available). Watch CA scale the ASG. **Notice the pain on purpose:** one instance type per group, slow (~minutes), no bin-packing. This friction is WHY Karpenter exists.
  **Also do here:** Add `aws_launch_template` to `eks.tf` with `--max-pods=110` kubelet extra arg + re-enable `ENABLE_PREFIX_DELEGATION=true` in `addons.tf`. Rolling-replace nodes so kubelet picks up the new limit. This unlocks prefix delegation properly (pod density 17→110 per node) and removes the need for a 3rd node long-term.

- [ ] **#26b Migrate to Karpenter** 🔨 ⭐ *(Phase 3 — after #26a Cluster Autoscaler, HIGH priority)*
  Remove CA. Install Karpenter (2 replicas). `NodePool` + `EC2NodeClass` mixing Spot + On-Demand (consolidation enabled). Same unschedulable test → Karpenter picks a right-sized instance in ~60s and consolidates on scale-down.
  *Interview: "I ran CA, hit the one-shape/slow/no-binpack limits, then moved to Karpenter — here's what changed."*

---

#### Storage (#31 → #32 → #33 → #34)

- [ ] **#31 MySQL StatefulSet + EBS CSI gp3 + WaitForFirstConsumer** 🔨 *(Phase 3 — verify after cluster-up)*
  StatefulSet already exists. On EKS: confirm StorageClass is `gp3`, `WaitForFirstConsumer` binding mode (binds the EBS volume in the AZ the pod lands in — avoids the one-AZ trap). Confirm `aws-ebs-csi-driver` IRSA is wired (#2).
  *Interview: "WaitForFirstConsumer" → without it, EBS binds in a random AZ; pod may land in a different AZ → mount fails.*

- [ ] **DB recovery + application resilience** 🔨 *(Phase 3 — after #31, medium priority)*
  The MySQL backup CronJob already exists. Extend it into a **tested restore procedure**: restore the backup to a separate pod, verify data integrity, document the RTO (how long does restore take?) and RPO (how much data is lost at most?). Store backups outside the pod/node lifecycle — an S3 bucket via IRSA. Also exercise two Spring Boot failure scenarios:
  - **Flyway migration failure:** deploy a migration with a SQL error → Spring Boot refuses to start (`FlywayException`). Fix: repair with `flyway repair` or roll back the migration file.
  - **Connection-pool exhaustion:** configure HikariCP with `maximumPoolSize: 2` and run concurrent load. Observe `Connection is not available, request timed out`. Tune pool size + `connectionTimeout`.
  *Interview: "StatefulSet vs RDS Multi-AZ?" → StatefulSet + EBS: you own backup, restore, failover, and data integrity. RDS: AWS handles multi-AZ failover, automated backups, encryption. For a real production MySQL workload, RDS is almost always the right answer.*

- [ ] **#32 Velero cluster backup + restore DR drill** 🔨 *(Phase 3 — after #31 EBS, medium priority)*
  Install Velero with AWS plugin (S3 + EBS snapshots via IRSA). Schedule daily cluster backup. **DR drill:** delete the `ecom` namespace entirely, restore from Velero backup, verify all pods + PVCs come back. Document RTO (restore time) and RPO (max data loss window). Pairs with MySQL CronJob backup — Velero covers K8s objects + volumes, CronJob covers application-level SQL dump.
  *Interview: "how do you recover from accidental namespace deletion?" → Velero restore. "RTO vs RPO?" → RTO = how long to restore, RPO = how much data you lose. "Velero vs etcd backup?" → etcd backup restores the whole cluster; Velero is namespace/resource-scoped and portable across clusters.*

- [ ] **#33 EFS CSI (RWX) shared PVC demo** 🔨 *(Phase 3 — after #31 EBS confirmed working)*
  Mount one EFS volume ReadWriteMany by `product-category` and `order-service` on different nodes (e.g. shared upload directory or config). Proves you understand EBS (RWO, one AZ) vs EFS (RWX, multi-AZ, shared).

- [ ] **#34 Namespace + ResourceQuota + LimitRange** 🔨 *(Phase 3 — quick win, do early in cluster-up session)*
  Put all services in a dedicated `ecom` namespace with a `ResourceQuota` (total CPU/memory cap) and `LimitRange` (per-container defaults). Prevents one service from starving others.

- [ ] **#35 Stakater Reloader — rolling restart on ConfigMap/Secret change** 🔨 *(Phase 3 — install early, pairs with #8 ESO)*
  Annotate deployments with `reloader.stakater.com/auto: "true"`. Change a key in `ecom-config` ConfigMap → Reloader triggers a **rolling restart** of affected deployments. Note: Reloader triggers a pod rollout — it does not hot-reload config in-place. The new pods pick up the new env vars on start. Contrast with `checksum/config` annotation (also triggers rollout but requires a Helm upgrade).
  *Interview: "why doesn't a ConfigMap change reach the pod?" → env vars are baked at pod start; volume-mounted CMs update eventually but apps must re-read them; Reloader forces a restart so pods re-read on start.*

---

#### Ingress & TLS (#35 → #36 → #37)

- [ ] **#36 AWS LB Controller — ALB Ingress + `target-type: ip` + cert-manager/ACM TLS** 🔨 ⭐ *(Phase 3 — after app is running on cluster)*
  Install `aws-load-balancer-controller`. Add ALB Ingress annotations: `kubernetes.io/ingress.class: alb`, `alb.ingress.kubernetes.io/target-type: ip`, `alb.ingress.kubernetes.io/group.name: ecom`. Wire **cert-manager** (or ACM) for HTTPS.
  *Interview: "target-type: ip" → ALB routes directly to pod IP, skipping NodePort+kube-proxy hop. IngressGroup = one ALB shared across multiple Ingress objects.*

- [ ] **#37 🗣️ EXPLAIN-ONLY** 📖 *(cover on-demand)* — Gateway API (`HTTPRoute`): the emerging successor to Ingress. Matches Karpenter/modern EKS direction.

- [ ] **#38 🗣️ EXPLAIN-ONLY** 📖 *(cover on-demand)* — service mesh (Istio/Linkerd): mTLS east-west, L7 traffic split, distributed tracing; when it's worth the operational cost vs not.

---

### MONITORING (separate file: `eks-monitoring.md`)

> Spring Boot Actuator + Micrometer makes the metrics pillar easier here than on a Node app — `/actuator/prometheus` is one dependency away.

- [ ] **Prometheus (kube-prometheus-stack)** *(after Phase 3 cluster is stable)* + `ServiceMonitor` per service + Spring Boot Actuator `/actuator/prometheus` endpoint enabled on product-category + order-service.
- [ ] **Grafana dashboards** *(after Prometheus)* — golden signals per service: latency (p50/p95/p99), error rate, RPS, saturation. Spring Micrometer gives JVM memory + GC metrics free.
- [ ] **Alertmanager** *(after Grafana)* — at least one real alert (e.g. error rate > 5% for 2 min) → Slack webhook. This backs the "MTTR −40%" resume line.
- [ ] **Loki + Fluent Bit** *(after Alertmanager)* (log aggregation) · **Tempo + OpenTelemetry** traces across service hops — including the async `order-service → SQS → notification-worker` hop (#38).
- [ ] **Cross-deps:** Argo Rollouts canary analysis (#20) consumes Prometheus — finish Prometheus **before** completing #20.

---

## 🧨 PART 2 — TROUBLESHOOTING & FAILURE LABS
### Break it on purpose · watch the real error · answer from memory, not theory

> **7-step method (every time):** 1 OBSERVE symptom → 2 LOCATE layer → 3 UNDERSTAND (`describe` Events first; `logs --previous`; exit code) → 4 HYPOTHESIZE → 5 VERIFY (one change) → 6 FIX → 7 PREVENT.
>
> **Conditions tell you the stuck stage:** `PodScheduled:False` → scheduler · `Initialized:False` → init container · `ContainersReady:False` → probe.
>
> **Toolkit:** `kubectl describe` (Events) · `logs --previous` · `get events --sort-by=.lastTimestamp` · `get endpoints` · `auth can-i [--as=…]` · `-o jsonpath` · `kubectl debug` ephemeral container · `netshoot` pod · `port-forward` · `rollout status/undo` · `cordon`/`drain` (respects PDBs).

### 2.1 Pod-level failures

- [ ] **F1. CrashLoopBackOff** — wrong start cmd / missing env var on `order-service` → `logs --previous`, decode exit code. *(Q25)*
- [ ] **F2. ImagePullBackOff / ErrImagePull** — know all 4 Event messages: `401/403` (**node IAM role** missing ECR permissions — kubelet pulls images, not the app pod; check the node role, not IRSA) · `manifest unknown / 404` (bad tag / wrong repo URI) · `timeout/refused` (private subnet without ECR VPC endpoint, or NetworkPolicy egress block) · **Docker Hub rate-limit** (100 pulls/6h unauthenticated → use ECR or authenticated pull). Diagnose: `describe pod` Events → check node role policy, image URI, registry reachability. *(Q26)*
- [ ] **F3. OOMKilled (exit 137)** — set `limits.memory: 64Mi` on `product-category`. Exit 137 = SIGKILL, which can result from OOM killing but does not prove OOM by itself (it also fires on `docker stop` or node pressure eviction). Confirm OOM: check the container's `reason: OOMKilled` in `describe pod` and node Events, not just the exit code. Tune with JVM flags: `-XX:MaxRAMPercentage=75.0` makes the JVM respect the container memory limit. *(Q27)*
- [ ] **F4. CreateContainerConfigError** — reference a missing ConfigMap key in `order-service` env (image pulls fine, container never starts). Fix ref or add `optional: true`.
- [ ] **F5. Init container stuck `Init:0/1`** — `wait-for-mysql` init container stalls if MySQL StatefulSet is down → `logs -c wait-for-mysql`.
- [ ] **F6. Pod stuck `Terminating`** — add a finalizer to a pod / long preStop → pod hangs. Remove finalizer; tune grace period.
- [ ] **F7. Exit-code decode drill** — `0` clean · `1` app error · `137` OOM/SIGKILL · `143` SIGTERM · `127` bad cmd · `139` segfault. Know cold.

### 2.2 Scheduling / node failures

- [ ] **F8. Pending — insufficient CPU/memory** — request more CPU than any node has → `describe pod` Events; Karpenter should provision a new node. *(Q24)*
- [ ] **F9. Pending — taint, no toleration** — taint the system node → untolerated taint Event → add toleration to the workload.
- [ ] **F9b. Pending — node affinity/selector mismatch** — set `nodeSelector` matching no node label → "didn't match node affinity" → `get nodes --show-labels` (usually a label-key typo). *(Q24)*
- [ ] **F10. Node NotReady / DiskPressure** — fill node disk → pods evicted. Read node Conditions: MemoryPressure / DiskPressure / PIDPressure. `df -h`, `du -sh /var/log/pods/*`. Cordon + drain where safe, clear disk. **Do not assume Karpenter automatically replaces unhealthy nodes** — Karpenter replaces nodes when pods are Pending; for NotReady nodes, check whether the node is managed by Karpenter or the managed node group and follow the appropriate remediation (terminate via ASG for MNG, Karpenter will replace when pods become unschedulable). *(Q31)*

### 2.3 Networking / Service failures

- [ ] **F11. Readiness fail → backend error** — break `/actuator/health/readiness` path in `product-category` → endpoints empty, removed from Service. The exact HTTP error depends on the ingress/ALB state: could be 502 (ALB has no healthy targets), 503 (nginx returns no upstream), or 504 (timeout waiting for a target). `get endpoints product-category` will show empty — that's the definitive diagnostic. *(Q4)*
- [ ] **F12. Selector mismatch → no endpoints** — change `product-category` Service selector label → `get endpoints` empty (the most common real bug). *(Q28)*
- [ ] **F13. DNS failure** — call `order-service` by wrong name → NXDOMAIN. Use `netshoot` to `nslookup order-service.ecom.svc.cluster.local`. Check CoreDNS logs. *(Q28)*
- [ ] **F14. NetworkPolicy silently blocks** — default-deny applied but Feign call from `order-service → product-category` fails with **timeout** (not refused — the silent failure). Add the allow rule. *(Q-SEC2 — the classic "policy applied but CNI isn't enforcing" trap)*
- [ ] **F15. Liveness death-spiral** — set `timeoutSeconds: 1` on slow `/actuator/health` → healthy pods restarted in a loop. Fix: startup probe + headroom. *(Q29 — a war story)*

### 2.4 Storage / config failures

- [ ] **F16. PVC unbound / Pending** — claim a StorageClass that doesn't exist → PVC Pending → MySQL pod Pending. Fix StorageClass name.
- [ ] **F17. EBS AZ conflict** — create a **disposable test PVC** (not the real MySQL PVC) using a StorageClass with `Immediate` binding. Schedule its pod in a different AZ → "volume node affinity conflict". Fix: StorageClass with `WaitForFirstConsumer` → volume binds in the AZ where the pod lands. Important: changing the StorageClass does not move an already-provisioned volume — use this disposable PVC for the experiment, not the production MySQL volume. *(Q24; ties to #31)*
- [ ] **F18. ConfigMap not updating in pod** — change `ecom-config` CM value → env var in pod unchanged until restart. Prove with `kubectl exec env | grep KEY`. Fix with Reloader (#34). *(Q6)*

### 2.5 Delivery / access failures

- [ ] **F19. Rollout stuck** — deploy a bad image tag (`:nonexistent`) → rollout stalls, old pods stay up (readiness gates it). Fix: `rollout undo` / `helm rollback` / git revert in ArgoCD. *(Q32)*
- [ ] **F20. "Works locally, fails on EKS"** — build `product-category` on Apple Silicon (arm64) → push to ECR → EKS node is amd64 → `exec format error`. Fix: `docker buildx --platform linux/amd64`. *(Q30)*
- [ ] **F21. RBAC "Forbidden"** — application pods don't need Kubernetes API access just to read env vars injected from Secrets. Use a **legitimate example**: create a `metrics-collector` ServiceAccount for a tool that reads pod/node info via the K8s API. Without a Role it gets 403 Forbidden. Verify: `kubectl auth can-i list pods --as=system:serviceaccount:ecom:metrics-collector`. Add a Role + RoleBinding with only `get,list` on `pods`. Also explain: RBAC is Kubernetes API access only — it has nothing to do with AWS IAM. Those are completely separate. *(Q21)*
- [ ] **F22. ECR pull denied** — pod SA missing ECR perms → ImagePullBackOff "not authorized to perform ecr:GetDownloadUrlForLayer". **Root cause: node IAM role** is missing ECR permissions — kubelet pulls images using the node role, not the pod's IRSA role. Fix: add `AmazonEC2ContainerRegistryReadOnly` to the **node IAM role** (or add the specific ECR actions). Also check: correct ECR repo region, private subnet needs ECR VPC endpoint or NAT. *(Q26; ties to #16)*

### 2.6 At-scale / production failures

- [ ] **F23. VPC CNI IP exhaustion / max-pods hit** 🗣️+note — too many pods per node → pods Pending "failed to allocate IP address". Diagnose: inspect `aws-node` pod logs on the node (`kubectl logs -n kube-system -l k8s-app=aws-node`), check free IPs in the subnet (AWS console → Subnets → Available IPs), check the instance ENI limit, check the kubelet `max-pods` setting. Fix options: enable prefix delegation (increases IPs per ENI slot, but actual gain depends on instance type/ENI limits/subnet space), add a secondary CIDR to the VPC, use larger subnets, or spread across more node types. *(Q-EKS1)*
- [ ] **F24. PDB blocks node drain** 🔨 — with 2 healthy replicas and `minAvailable: 1`, draining a node that holds one of them will generally succeed (1 replica remains). To make the PDB actually block: first make one replica unavailable (e.g. deploy a bad image to one pod so it's not ready), then drain the node holding the last healthy pod. PDB now blocks the eviction because availability would fall below `minAvailable: 1`. Fix: bring the other pod back to healthy first, then drain. *(ties to #28)*
- [ ] **F25. Karpenter consolidation disruption** 🔨 — Karpenter consolidates a node mid-request. PDB prevents eviction below `minAvailable`, but PDB alone does not guarantee every in-flight HTTP request survives. You also need: graceful shutdown (`terminationGracePeriodSeconds` + `preStop` sleep to drain connections, #21) + readiness-gated rollout (#22). Demonstrate: enable consolidation, watch a pod get evicted, observe brief 5xx spike if graceful shutdown is absent, then add `preStop` and retry. *(ties to #21/#26b/#28)*
- [ ] **F26. CoreDNS throttling / `ndots:5` latency** 🗣️ — `ndots:5` means: if a name has fewer than 5 dots, the resolver tries it with each search-domain suffix before attempting it as an absolute name. It does NOT mean 5 DNS lookups per every call — the number depends on the name and search list. At scale this adds latency. **Diagnose first:** measure DNS query volume with CoreDNS Prometheus metrics and actual latency before tuning. Fix options: use FQDNs in service calls (e.g. `product-category.ecom.svc.cluster.local`), lower `ndots` to 2 in pod spec, or add NodeLocal DNSCache as a DaemonSet to bypass CoreDNS for cached queries.
- [ ] **F27. Secret rotation breaks pods** 🔨 — ESO rotates `ecom/mysql-password` in Secrets Manager but running pods cached the old value → MySQL auth fails. Fix: Reloader + ESO `refreshInterval`. *(ties to #8/#34)*
- [ ] **F28. AZ capacity-loss simulation** 🗣️+partial🔨 — cordon all nodes in one AZ (controlled simulation — not a real AZ outage; a real AZ failure involves infrastructure beyond your control). Watch: topologySpread shifts stateless workloads to remaining AZs; `mysql-0` StatefulSet with a single-AZ EBS volume does NOT recover automatically — the PVC is bound to the failed AZ. Document this limitation. This is why production databases use RDS Multi-AZ (automatic failover) rather than a single StatefulSet + EBS. *(ties to #28/#31)*
- [ ] **F29. Argo Rollouts auto-rollback** 🔨 — push a bad `product-category` build → Prometheus analysis detects error-rate spike → canary automatically aborted, traffic returns to stable. *(ties to #20)*
- [ ] **F30. 🗣️ EXPLAIN-ONLY:** etcd/API throttling at scale; zero-downtime EKS cluster upgrade (kubent/Pluto → new node group → drain respecting PDBs); Velero backup/DR (RTO/RPO).

### 2.7 Cluster / control-plane / node-join failures

- [ ] **F31. EKS worker node won't join** 🔨 — new node stuck NotReady / never appears → wrong node IAM role, missing Access Entry, bad bootstrap/user-data, or no subnet route to API. *(Q-EKS2)*
- [ ] **F32. 🗣️ EXPLAIN-ONLY ⭐ — OS/CNI-level failure "pod healthy, node networking dead"** — Datadog March 2023: systemd-networkd restart flushed routing rules → 60%+ of nodes lost pod networking across 5 regions while pod readiness probes **passed**. Lesson: pod health ≠ node health → need `node_exporter` node-level metrics + canary OS updates + staggered regional windows. *(Datadog Dublin near-certain question)*
- [ ] **F33. 🗣️ EXPLAIN-ONLY (CKA / self-managed):** etcd disk full → `etcdctl compact + defrag`; etcd snapshot restore (update BOTH `--data-dir` AND the hostPath volume in the static-pod manifest — the classic restore trap); control-plane static-pod won't start; kubelet won't start (`journalctl -u kubelet`). *On EKS, AWS owns all of this.*

---

## 🎯 Mainstream stack decisions (what we pick, and why)

| Layer | ✅ We implement | 🗣️ Also know | Why this one |
|---|---|---|---|
| **IaC** | Terraform + S3 remote state (native `use_lockfile`) | OpenTofu, CloudFormation | Remote state = team table-stakes; DynamoDB locking deprecated |
| **Node autoscaling** | Karpenter (CA first to feel limits, then migrate) | Cluster Autoscaler | Modern AWS standard; faster, bin-packs, spot-aware |
| **Pod autoscaling** | HPA (CPU/mem) + KEDA (SQS trigger, scale-to-zero) | VPA | KEDA = star event-driven story; HPA = baseline |
| **Secrets** | ESO + AWS Secrets Manager + IRSA + KMS etcd | Secrets Store CSI, Sealed Secrets, Vault | Most-recommended 2026 pattern; secrets never in Git |
| **Policy** | Kyverno | OPA/Gatekeeper | YAML-native, easier, most-recommended for new teams |
| **NetworkPolicy** | VPC CNI network-policy add-on | Cilium, Calico | No CNI swap on EKS; Cilium = "I'd use at scale" answer |
| **Registry** | Amazon ECR (immutable SHA + lifecycle + scan) | GHCR, Harbor | ECR = default in AWS shops |
| **Packaging** | Helm (`helm/ecom` + values-dev/prod) | Kustomize | 75% default packager; gives rollback + release lifecycle |
| **GitOps** | ArgoCD (app-of-apps + sync waves) | Flux | ~60% of clusters, 97% prod users |
| **Progressive delivery** | Argo Rollouts (canary + Prometheus analysis) | Flagger, blue-green | Canary + auto-rollback = the senior deploy answer |
| **Storage** | EBS CSI (gp3, WaitForFirstConsumer) + EFS CSI (RWX) | — | Covers one-AZ (EBS) and shared (EFS) stories |
| **Ingress** | NGINX (local/dev) + AWS LB Controller ALB (EKS) + cert-manager TLS | Gateway API (HTTPRoute) | Covers exact AWS-LB-Controller interview follow-ups |
| **Observability** | Prometheus/Grafana/Loki/Fluent Bit/Tempo/OTel | Datadog, CloudWatch | → eks-monitoring.md |

---

## ✅ Progress tracker

- **Phase 0 (app-ready):** **5/5 ✅**
- **Phase 1 (Foundation):** **7/8** *(#6, #7 are explain-only → cover on-demand)*
- **Phase 2 (Delivery):** **7/9** ✅ #16 ECR · #14 scanning · CI pipeline · #19 ArgoCD · #5 multi-env · #21 graceful shutdown · #22 rolling-update — remaining: Terraform CI/CD ⏳ · #20 Argo Rollouts ⏳ (after monitoring)
- **Phase 3 (Cluster-UP):** 🔨 in progress — Security ✅ · Reliability ✅ · Scaling ⏳ (#25 KEDA next)
- **Monitoring:** ⏳ after Phase 3
- **Part 2 Failure Labs:** ⏳ after full platform is built
- **Phase 3 (Cluster-UP):** 13/19 — #8 #9 #10 #11 #12 #13 #15 #29 #28 #30 #23 #24 #38 done · remaining: #25 KEDA · #26a CA · #26b Karpenter · #31 MySQL gp3 · #32 Velero · #33 EFS · #34 ResourceQuota · #35 Reloader · #36 ALB+TLS
- **Monitoring:** 0/4
- **Part 2 Failure Labs:** 0/34

**⭐ High-ROI set (start here after Phase 1):** #8 ESO · #9 IRSA · #12 NetworkPolicy · #16 ECR+SHA · #19 ArgoCD · #20 Argo Rollouts · #25 KEDA · #26b Karpenter · #31 MySQL+EBS · #38 notification-worker
