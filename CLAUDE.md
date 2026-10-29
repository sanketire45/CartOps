# Ecommerce-Spring — Claude Code context

## What this is
Spring Boot microservices e-commerce backend (Product&Category + Order + Eureka discovery) being built into an industry-grade EKS platform. See `TASKS.md` for the full roadmap.

Goal: 
 Goal of this project is to build the end to end production style devops project.
 where we will build cicd, Eks, observability , monitoring, Terraform (IAC)
 Why: why we are donig this , is becuase when in interview when he asks for any senario based question or any in general question he will ask it from the best practices used in all of this services, hence we are deploying and creating this whole devops stack production style,
so if any question comes I have already implemented the things that most need for big scale production workloads.
so for eg. in cicd we will deploy and create all those best practices for big scale production grade environments which most hiring companies are.
same in eks ,iac, obsesrvability etc..
so we are takling and solving all the major problems in each service hence i will understand all the core basics, hence even if stack or any service changes i already knew what problem it solves and i can migrate to that service or learn it very quickly before interview.
## Current state (updated 2026-10-29)

### Cluster
- EKS cluster is UP, all pods in `ecom` namespace running on image tag **v0.0.7**
- All 5 services healthy: `eureka-server`, `frontend`, `mysql`, `order-service` (2 replicas), `product-category` (2 replicas), `notification-worker` (1 replica)
- ArgoCD GitOps watching `helm/ecom/values-dev.yaml` — deploys on every git push
- Jenkins pipeline at `CICD/dev-build.groovy` — run with param `IMAGE_TAG=v0.0.X`

### What's fully working
- Jenkins CI pipeline: validate → trivy → OWASP → SonarQube → parallel build → parallel ECR push → GitOps update
- ECR: 5 repos (`ecom-product-category`, `ecom-order-service`, `ecom-eureka-server`, `ecom-frontend`, `ecom-notification-worker`)
- ArgoCD: `ecom-dev` app + `root-app` app-of-apps pattern
- NetworkPolicy: micro-segmentation (default-deny + allow-list)
- HPA: `product-category` and `order-service` scale on CPU
- notification-worker: SQS listener active, polling `order-events` queue, writing to `notification_db`

### notification-worker (task #38) — just completed
**All 5 bugs fixed in this session:**
1. NetworkPolicy blocked MySQL → added `notification-worker` to `allow-services-to-mysql` (`5de323b`)
2. Wrong DB name `ecommercespring` → fixed to `notification_db` in `application.properties` + mysql-initdb ConfigMap (`ba8fc31`)
3. Spring Boot 3.5.14 / Spring Cloud AWS 3.3.0 BOM conflict → `SPRING_CLOUD_COMPATIBILITY_VERIFIER_ENABLED=false` env var + fixed BOM order in `build.gradle` (`7d937ed`)
4. IRSA: `sts module not on classpath` → added `software.amazon.awssdk:sts` to `build.gradle` (`1049eee`)
5. Jenkins emailext plugin not configured → replaced with `echo` (`cb9e0c8`)

**Verify SQS end-to-end (not done yet):** place a test order via order-service API → watch `kubectl logs -n ecom -l app=notification-worker -f` for `Received order event` log line → confirm row written to `notification_db.notifications` table.

### IAM / Jenkins setup (scripts, NOT Terraform)
- `scripts/bootstrap-jenkins-iam.sh` — source of truth for Jenkins IAM roles. Live policy is v3.
- Roles: `CartOps-Jenkins-Instance-Role` (on EC2) → assumes → `CartOps-Jenkins-CI-Role` (holds ECR push)
- Shared lib: `Jenkins_SharedLib/vars/ecr_push.groovy` — uses env vars (not named profiles) to avoid race condition
- `Jenkins_SharedLib/vars/` also has: `code_checkout`, `docker_build`, `trivy_scan`, `owasp_dependency`, `sonarqube_analysis`, `sonarqube_code_quality`

### Pending tasks (not started)
| Task | What |
|------|------|
| #25  | KEDA — ScaledObject for notification-worker SQS, needs `terraform/keda.tf` + `notification-worker-scaledobject.yaml` + `notification-worker-triggerauth.yaml` + `sqs:GetQueueAttributes` in IRSA policy |
| #26a | Cluster Autoscaler |
| #26b | Karpenter |
| #31  | MySQL gp3 + WaitForFirstConsumer |
| #32  | Velero backup |
| #33  | EFS CSI (pods already installed, may need more) |
| #34  | ResourceQuota + LimitRange |
| #35  | Stakater Reloader |
| #36  | ALB + cert-manager TLS |
| Obs  | Prometheus + Grafana + Loki |

### After cluster-up (#26), do the kubectl verification walkthrough
See memory `project-hpa-keda-verify.md` — walk through these commands together:
```bash
kubectl get pods -n kube-system | grep -E "metrics-server|keda"
kubectl get hpa -A
kubectl describe hpa keda-hpa-notification-worker -n ecom
kubectl describe hpa product-category-hpa -n ecom
kubectl get scaledobject -A
```

## How to resume
1. Read this file top-to-bottom — current state is always here.
2. Check memory files in `~/.claude/projects/.../memory/` for user preferences.
3. Pick up at the first unchecked task in the Pending tasks table above.
4. Always follow the convention: explain task → why → code detail → interview angle → wait for approval → THEN write code.

## Key conventions

### Teaching order — follow this EVERY time before writing code
1. **Explain the task** — what it is, what problem it solves
2. **Explain why it's needed** — the motivation, the risk it addresses
3. **Explain the code in detail** — both logic (what each block does) AND syntax (why it's written that way, what each field/keyword means)
4. **Interview angle** — general/conceptual [G] + scenario/troubleshooting [S] + incident/war-story [I] questions, where applicable
5. **Wait for approval**
6. **Then write the code**

What NOT to do: explain concept → silently write code → explain inline via comments. That is the wrong order.

### Interview questions format
When surfacing interview questions after each task, always include:
- **[G] General/conceptual** — "what is X", "how does Y work"
- **[S] Scenario/troubleshooting** — "your drain got stuck", "pods Pending after autoscaler added node", "PDB is blocking rollout"
- **[I] Incident/war-story** — "zero-downtime upgrade went wrong", "SQS backed up under spike"
At least one [S] or [I] per topic — not just definitions. That is what Dublin DevOps interviews actually test.

### For Terraform work
- Frame how each `.tf` block would be asked in a Terraform-focused interview round (state, providers, data vs resource, modules, drift, etc.)
- Drop inline callouts while writing `.tf` — short notes on: `data` vs `resource`, why SSM lookup beats hardcoding, `depends_on` ordering, `lifecycle` rules, IRSA pattern. One line, tight. Builds IaC interview vocabulary naturally.

### Interview folder — `Interview/` in this repo
- One file per major DevOps topic (K8s, Terraform, CI/CD, GitOps, AWS, Networking, Scaling, Observability)
- `01-kubernetes-core.md` is the master K8s file — security, storage, reliability, RBAC are all subsections inside it
- `07-aws-services.md` structured by AWS Well-Architected pillars
- Each section: **Cheat Sheet** (key points / failure modes table) then **Questions** (G/S/I tagged)
- Fill sections as tasks complete — never leave answers only in chat

### Terraform safety rule — NEVER run without explicit approval
Never run `terraform apply`, `terraform destroy`, or `terraform apply -target=...` without the user explicitly saying "do it" / "run it" / "go ahead". Even on session resume — read state first, report what you see, then wait.

**Why:** In a prior session, apply ran immediately on resume while the cluster was down, creating orphaned IAM roles in AWS.

### Scripts vs Terraform — long-lived resources go in `scripts/`
Resources with mandatory deletion windows or that should outlive apply/destroy cycles go in `scripts/` — created once manually, NOT managed by Terraform.

- **In scripts/:** KMS keys (7-day minimum deletion window), Route53 hosted zones, S3 state bucket, ACM certs, Jenkins IAM roles
- **In Terraform:** IAM roles, EKS cluster, ECR repos, Helm releases (fine to delete/recreate)
- Terraform references scripts/ resources via `data` source (lookup by name/ARN) not `resource` block

**Why:** Sanket does terraform apply/destroy daily for learning. KMS keys in Terraform accumulate (30+ pending-deletion keys after a month → hits 100-key quota). Scripts/ means create once, sit cheaply, never accumulate.

### Do NOT make changes when user is only asking questions
If the user asks "what is X" or "how does Y work" — explain only. Do not touch any file. Wait for explicit "write it" / "do it" / "yes".

### When user says "see real" / verify live cluster
Run the kubectl/aws commands AND explain each one as you run it — what it does, what each flag means, why it's useful for production debugging. Don't just paste output silently.

### Model usage
- **Sonnet** (default) — code writing, file ops, task tracking, routine explanations
- **Opus** — deep conceptual teaching, interview prep, complex multi-layer reasoning only
- Start fresh chats per topic/phase. Resume via this CLAUDE.md. Use `/compact` if chat gets long.

### Confidential workplace files — READ ONLY, never share
User has granted read-only access to WCloud IoT production pipeline files at `/Users/sanketwalunj/Desktop/WCloud-Deployments-IOT-Shared-Services-DevOps/`. Read them only for CartOps pattern insights. Never quote, copy, or describe their specific implementation details.

### After cluster-up — run these immediately
```bash
# Verify node address type (for metrics-server InternalIP arg)
kubectl get node <node-name> -o jsonpath='{.status.addresses}'

# metrics-server
kubectl top nodes
kubectl top pods -n ecom
kubectl get apiservice v1beta1.metrics.k8s.io   # must show Available=True

# HPA watch
kubectl get hpa -n ecom -w
```

Then do the KEDA/HPA verification walkthrough (see `project-hpa-keda-verify` memory):
```bash
kubectl get pods -n kube-system | grep -E "metrics-server|keda"
kubectl get hpa -A
kubectl describe hpa keda-hpa-notification-worker -n ecom
kubectl describe hpa product-category-hpa -n ecom
kubectl get scaledobject -A
```
