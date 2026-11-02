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
10. [HPA — Horizontal Pod Autoscaler](#10-hpa--horizontal-pod-autoscaler)
11. [VPA — Vertical Pod Autoscaler](#11-vpa--vertical-pod-autoscaler)
12. [Cluster Autoscaler](#12-cluster-autoscaler)
13. [Karpenter](#13-karpenter)
14. [KEDA — Event-Driven Autoscaling](#14-keda--event-driven-autoscaling)
15. [SLI / SLO / Error Budget](#15-sli--slo--error-budget)
16. [Scaling Best Practices](#16-scaling-best-practices)
17. [ResourceQuota & LimitRange](#17-resourcequota--limitrange)
18. [Stakater Reloader](#18-stakater-reloader)
19. [Velero — Cluster Backup & Restore](#19-velero--cluster-backup--restore)
20. [ALB + cert-manager TLS](#20-alb--cert-manager-tls)

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

**[I] `kubectl` says "no such host" right after recreating the cluster. Why?**
Each new cluster gets a brand-new API server endpoint. The kubeconfig still pointed at the destroyed cluster's DNS name — which no longer resolves. Fix: `aws eks update-kubeconfig --region us-east-2 --name ecom`. Hit this after every destroy/apply cycle — running the kubeconfig update is the first step after `terraform apply` finishes.

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
| App not ready but readiness fires too early | startupProbe gates readiness until fully initialised | failureThreshold:60, periodSeconds:5 |
| In-flight requests dropped | Graceful shutdown (terminationGracePeriodSeconds + preStop) | #21 |
| Downtime during your deploy | Rolling update maxUnavailable:0 maxSurge:1 | #22 |
| Bad deploy to 100% users | Canary + Prometheus auto-rollback | #20 — planned after monitoring |

### Deployment Strategy Cheat Sheet

| Strategy | Traffic during deploy | Rollback | Resource cost | Risk |
|---|---|---|---|---|
| **Rolling Update** | Gradual — some v1, some v2 pods | `kubectl rollout undo` ~30s | 1x + small surge | Brief mixed-version window |
| **Blue-Green** | Instant full cutover (flip Service selector) | Flip selector back, instant | 2x during deploy | DB migrations must be backward-compatible |
| **Canary** | % split (5% v2, 95% v1), increase slowly | Remove canary Deployment | 1.1x | Slowest to roll out 100% |
| **Recreate** | All old pods killed first, then new pods start | `kubectl rollout undo` | 1x | Guaranteed downtime window |

### Probe Cheat Sheet

| Probe | Controls | Fails → | Gates what |
|---|---|---|---|
| `startupProbe` | Is the app done initialising? | readiness+liveness paused | Nothing. Just delays when other probes start |
| `readinessProbe` | Is the app ready for traffic? | Pod marked NotReady, removed from Service endpoints | **Traffic routing** |
| `livenessProbe` | Is the app alive? | kubelet restarts the container | **Container lifecycle** |

**Key rule:** Only readiness probe gates Service endpoints. Liveness probe does NOT remove a pod from endpoints — it just restarts the container.

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

**[G] What is the difference between startupProbe, readinessProbe, and livenessProbe? Which one controls Service endpoints?**
Three distinct jobs: `startupProbe` — runs first, gates when the other two probes begin. Use for slow-starting apps (Spring Boot, JVM) where you need up to 5 minutes for full initialisation. While it hasn't passed, readiness and liveness are completely paused. `readinessProbe` — controls Service endpoint membership. Fails → pod removed from endpoints → no traffic. Passes → added to endpoints → traffic flows. This is the only probe that gates traffic routing. `livenessProbe` — controls container lifecycle. Fails → kubelet kills and restarts the container. Does NOT remove the pod from Service endpoints before restarting — in-flight requests can get 502 during that window. Key distinction: readiness gates traffic, liveness gates restarts. Only readiness affects endpoints.

**[G] Why do you need startupProbe if you already have readinessProbe?**
Without startupProbe, readinessProbe begins immediately at container start. For Spring Boot, `/actuator/health/readiness` returns 200 at second ~3 when the HTTP server starts — but the MySQL connection pool and SQS client take 40-60 more seconds. So: readiness passes at second 3 → pod added to Service endpoints → real traffic hits the pod → 502 for 57 seconds. startupProbe solves this by pausing readiness until the app signals it's fully initialised. Set `failureThreshold: 60, periodSeconds: 5` = gives up to 5 minutes. Only after startupProbe passes does readiness begin. Old pods serve all traffic during that window. Zero 502s during deploy.

**[G] What is Blue-Green deployment and how does it work in Kubernetes?**
Two identical Deployments run simultaneously: Blue (current live version) and Green (new version). The Service selector points at one label. To deploy: bring up the Green Deployment, run smoke tests against it, then patch the Service selector from `version: blue` to `version: green` — all traffic switches instantly. Rollback = patch selector back to blue. Instant, no pod restarts. How it differs from Rolling Update: Rolling Update gradually replaces pods one by one — during the deploy some requests go to v1 pods and some to v2 pods (mixed-version window). Blue-green has no mixed-version window — traffic is either 100% v1 or 100% v2.

**[S] What is the hardest problem with blue-green deployments in production?**
Database schema migrations. Both Blue and Green pods connect to the same database. If your new version (Green) requires a new column or renames a table, you can't apply that migration before switching — the old Blue pods will break. You can't apply it after — Green needs it to start. Solution: **backward-compatible migrations**. Three-phase deploy: (1) migration adds new column, both Blue and Green work with old+new schema. (2) Traffic switches to Green. (3) After Blue is fully decommissioned, run cleanup migration to remove old column. This is called expand-contract pattern — expand the schema first, contract after.

**[G] Blue-Green vs Canary — which do you use when?**
Blue-Green: use when you want instant switchover and instant rollback. Good for: backend services with no UI, API version changes, when you've done thorough staging testing. Risk: if Green has a subtle bug, 100% of users hit it simultaneously. Canary: use when you want to limit blast radius. Send 5% of traffic to v2, watch error rates and latency in Prometheus for 30 minutes, then increment to 20%, 50%, 100%. If error rate spikes at 5%, only 5% of users were affected. Good for: UI changes, risky new features, anything that's hard to fully test in staging. Canary requires a traffic-splitting layer — Argo Rollouts, Istio, or NGINX `canary-weight` annotation.

**[G] Your Rolling Update is causing 502s during deploy even though maxUnavailable is 0. Why?**
Two possible causes: (1) startupProbe is not configured — readiness probe fires at second 3 while the app needs 60s to fully initialise. Pod passes readiness early, gets traffic, returns 502. Fix: add startupProbe. (2) terminationGracePeriodSeconds is too short — the old pod gets SIGTERM, waits 30s, then gets SIGKILL. But in-flight requests that started before SIGTERM needed more than 30s to complete. Fix: increase `terminationGracePeriodSeconds` + add `preStop: sleep 5` to drain connections before SIGTERM. Together: startupProbe prevents 502 on new pods starting, graceful shutdown prevents 502 on old pods dying.

---

### 502 Bad Gateway After Deployment — Full Scenario

> **The concept to understand first — "Green Deployment" ≠ "Traffic Healthy"**
>
> Jenkins marks a pipeline "SUCCESS" when the image is pushed to ECR and `values-dev.yaml` is updated. ArgoCD marks the app "Healthy" when all pods reach `Running` state and pass their readiness probe. But readiness probe only calls `/actuator/health` — Spring Boot returns 200 on that endpoint as soon as its HTTP server starts (~5 seconds), while the full app (DB connection pool, SQS client, Eureka) takes 30-60 more seconds. So pods pass readiness at second 5, get added to Service endpoints, start receiving traffic — and return 502 until second 60 when they're actually ready.
>
> **What 502 means:** the proxy (nginx or ALB) *reached* the pod but got a bad/no response. Different from 503 (no backend at all) or 504 (reached it, timed out).
>
> **Traffic path — always work outside-in:**
> `User → ALB → nginx-ingress → K8s Service → Pod endpoints → Container`

**[I] Deployment shows green in CI/CD and ArgoCD. Users are getting 502 errors. How do you troubleshoot?**

**Step 1 — Rollback immediately.** Don't investigate while users are impacted.
```bash
kubectl rollout undo deployment/product-category -n ecom
kubectl rollout status deployment/product-category -n ecom   # watch it go back
```
This restores the old pods within ~30 seconds. Now investigate.

**Step 2 — Where is the 502 coming from?** Work outside-in.

*ALB access logs* — check in CloudWatch or S3. Look at `target_status_code` column. If the ALB logged `502` with `target_status_code: -` it never reached a pod (routing issue). If it shows `502` with `target_status_code: 502` the pod itself returned 502.

*nginx-ingress logs:*
```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=100
```
nginx logs show `upstream` address and response code. 502 from nginx = upstream pod closed the connection or sent invalid HTTP.

**Step 3 — Service endpoints.** The fastest check.
```bash
kubectl get endpoints product-category -n ecom
```
If this shows `<none>` or fewer pods than expected — pods failed readiness. That's the root cause right there. Traffic was routed but no healthy backend existed.

**Step 4 — Pod state and readiness.**
```bash
kubectl get pods -n ecom                          # are new pods Running or CrashLoopBackOff?
kubectl describe pod <new-pod-name> -n ecom       # look at Events — readiness probe failures?
kubectl logs <new-pod-name> -n ecom               # startup errors?
kubectl logs <new-pod-name> -n ecom --previous    # if it restarted — crash output
```

**Step 5 — Port mismatch check.**
```bash
# Container port in deployment — what port is the app listening on?
kubectl get deployment product-category -n ecom -o jsonpath='{.spec.template.spec.containers[0].ports}'

# Service target port — what port does the service forward to?
kubectl get svc product-category -n ecom -o jsonpath='{.spec.ports}'
```
If `containerPort` is 8080 but `targetPort` is 8090 → every request hits a closed port → 502.

**Root cause patterns — specific to "green but 502":**

| Root Cause | Signal | Fix |
|---|---|---|
| Readiness probe fires too early | `kubectl get endpoints` shows pod then loses it | Add `startupProbe` with longer `failureThreshold` |
| App takes 60s to start, readiness fires at 5s | 502s only during deploy window, clears after ~60s | `startupProbe: failureThreshold: 60, periodSeconds: 5` |
| Container port ≠ service targetPort | `kubectl get endpoints` shows pod but 502 persists | Fix port in Deployment or Service |
| New image has startup crash (missing env var, wrong DB URL) | `CrashLoopBackOff` on new pods | `kubectl logs --previous`, fix config, redeploy |
| `maxUnavailable: 1` killed old pod before new was ready | 502 spike during deploy, then recovers | Set `maxUnavailable: 0, maxSurge: 1` |

**The one-liner that shows senior thinking:**
> "Deployment green means the scheduler is satisfied — all pods passed readiness probe. But readiness probe is only as good as what it tests. If it checks `/actuator/health` and that returns 200 before the DB connection pool is ready, pods receive live traffic while the app is still initialising. That gap is where 502s come from. The fix is `startupProbe` — gates traffic until the app is fully initialised, not just HTTP-responding."

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

**[G] What securityContext fields matter most?**
Six key fields: `runAsNonRoot: true` (fail if image runs as UID 0), `runAsUser: 999` (specific non-root UID), `allowPrivilegeEscalation: false` (child processes can't gain more privileges than parent — blocks sudo inside the container), `capabilities: drop: [ALL]` (removes all 14 default Linux capabilities), `seccompProfile: RuntimeDefault` (filters ~300 dangerous syscalls via containerd's built-in profile), `readOnlyRootFilesystem: true` (prevents writing to the container filesystem — attacker can't drop and execute a binary). We apply all six to every container in the ecom namespace.

**[G] What Kyverno policies did you implement?**
Two ClusterPolicies: (1) `require-resource-limits` — every container must declare CPU and memory limits; without limits a noisy pod can starve the whole node. Currently in `Audit` mode (logs violations, doesn't block) — will flip to `Enforce` after all deployments declare limits. (2) `deny-latest-tag` — blocks images tagged `:latest` because it's non-deterministic; forces explicit version or git-SHA tags for reproducible deployments and meaningful rollbacks.

**[I] MySQL pod crashing with `Permission denied` on `/var/lib/mysql` despite `runAsUser: 999`. Why?**
The EBS volume was previously owned by root (UID 0). When MySQL ran as UID 999, it couldn't write to a root-owned directory. Fix: add `fsGroup: 999` at the pod-level `securityContext`. `fsGroup` tells Kubernetes to `chown` all mounted volumes to that GID before the container starts — runs as a privileged init step before the app process. Also deleted the stale PVC to force a fresh volume with correct ownership from the start.

**[I] Pod crashing with `CreateContainerConfigError`. How did you debug it?**
`kubectl describe pod mysql-0 -n ecom` → Events showed: secret `mysql-secret` key `mysql-root-password` not found. ESO was writing the key as `mysql-root-password` but the pod's `secretKeyRef` was looking for key `password`. Fixed by changing `secretKey: mysql-root-password` → `secretKey: password` in the ExternalSecret manifest, then force-syncing: `kubectl annotate externalsecret mysql-external-secret -n ecom force-sync=$(date +%s) --overwrite`. The `secretKey` in ExternalSecret is the key name INSIDE the K8s Secret — it must exactly match what `secretKeyRef.key` expects.

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
| Secret volume mount | Secret mounted as tmpfs in pod — kubelet syncs changes ~1 min automatically. Pod sees new value without restart. |
| envFrom Secret | Secret injected as env vars at pod start — lives in process memory. Never auto-updates on Secret change. |
| ESO chain | Secrets Manager → ESO → K8s Secret in etcd → pod consumes via envFrom or volume |
| Reloader | Stakater Reloader watches K8s Secrets/ConfigMaps — on change patches Deployment annotation → triggers rolling update |
| ArgoCD + ConfigMap | ArgoCD applies ConfigMap changes. Pods do NOT restart — spec.template hash unchanged. Reloader bridges the gap. |
| EBS snapshot restore | Delete volume → pod Pending → create new EBS from snapshot → patch PV `volumeHandle` → pod re-attaches |

### Questions

**[G] Why is WaitForFirstConsumer binding mode important?**
Default binding (`Immediate`) creates the EBS volume in any AZ as soon as the PVC is created. If the pod later schedules on a node in a different AZ — EBS is AZ-specific, pod can't mount it. `WaitForFirstConsumer` delays EBS provisioning until the pod is scheduled, then creates the volume in the same AZ as the pod. Prevents the AZ mismatch trap completely.

**[S] MySQL pod was stuck in Pending. PVC was also Pending. Why?**
Two possible causes: (1) StorageClass name mismatch — PVC requested `gp2` but no StorageClass was annotated as default. Fix: add `storageclass.kubernetes.io/is-default-class: "true"` annotation to the gp2 StorageClass. (2) AZ mismatch — PVC already bound to a volume in us-east-2a but the pod scheduled on a node in us-east-2c. Fix: use `WaitForFirstConsumer` binding mode in the StorageClass.

**[G] Why does terraform destroy leave orphaned EBS volumes?**
StatefulSet `volumeClaimTemplates` creates PVCs outside Terraform's control — they're not Terraform resources. When the cluster is destroyed, Terraform deletes the StatefulSet but not the PVCs (they were created by K8s, not Terraform). The EBS volumes backing them stay alive. Fix: `scripts/destroy.sh` deletes the PVC before running `terraform destroy`, which triggers K8s to delete the EBS volume.

**[G] EBS vs EFS — when do you use each?**
EBS — block storage, AZ-specific, ReadWriteOnce (only one pod can mount at a time), fast, use for databases. EFS — network filesystem, multi-AZ, ReadWriteMany (multiple pods simultaneously), slower, use for shared config or uploads that multiple pods need to read/write.

**[G] Secret volume mount vs envFrom — what's the difference?**
`envFrom` bakes secrets as environment variables at pod start. They live in the process's memory for the pod's lifetime — the pod must restart to see a new value. A Secret volume mount exposes the secret as files on a tmpfs (RAM) filesystem inside the container. Kubelet syncs the volume automatically when the Secret changes in etcd — no pod restart needed, the app just re-reads the file. Production rule: use volume mounts for anything that needs to rotate without pod restart (TLS certs, tokens). Use envFrom for static credentials where rotation tolerance is acceptable and a rolling restart is fine.

**[S] You updated a secret in AWS Secrets Manager. 10 minutes later the pod still reads the old value. Walk me through why.**
The full chain: Secrets Manager → ESO → K8s Secret in etcd → pod. ESO syncs on its `refreshInterval` (default 1h in many configs) — so the K8s Secret in etcd may not have the new value yet. Once ESO updates the K8s Secret, if the pod uses `envFrom` the running process still doesn't see the change — env vars are baked at pod start. Reloader is needed to detect the Secret update and trigger a rolling restart. If using a volume mount, kubelet will sync the file automatically once etcd has the new value. Fix: (1) Reduce ESO `refreshInterval` to 1m for fast-rotation secrets. (2) Use volume mount instead of envFrom for auto-reload without Reloader. (3) Deploy Stakater Reloader as a safety net for envFrom use cases.

**[S] Your ConfigMap changed in Git. ArgoCD synced successfully. But pods are still reading the old value. Why?**
ArgoCD applies the ConfigMap to the cluster — the ConfigMap object in etcd has the new data. But ArgoCD only triggers a rolling restart if `spec.template` in the Deployment changes. A ConfigMap change alone doesn't change the Deployment's pod template hash → no restart is triggered → running pods keep their in-memory env vars from the old version. Fix: deploy Stakater Reloader. It watches ConfigMaps and, when one changes, patches an annotation (`reloader.stakater.com/last-reload`) on the Deployment's pod template → K8s sees the pod template changed → rolling update fires automatically.

**[S] Your MySQL StatefulSet's EBS volume was accidentally deleted. You have a snapshot. Walk me through the restore.**
Step 1: the pod is now in Pending (no volume to mount). Step 2: create a new EBS volume from the snapshot in the same AZ as the pod (e.g. `aws ec2 create-volume --snapshot-id snap-xxx --availability-zone us-east-2a`). Step 3: patch the existing PV's `spec.csi.volumeHandle` with the new EBS volume ID: `kubectl patch pv <pv-name> -p '{"spec":{"csi":{"volumeHandle":"vol-newid"}}}'`. Step 4: the PVC is still bound to the PV (binding is untouched). The pod scheduler sees the volume is available → mounts it → pod moves to Running. Key insight: only the PV's `volumeHandle` changes — the PVC binding, the StatefulSet, and the StorageClass are all untouched.

**[G] Explain ConfigMaps and Secrets. How do you manage them across environments?**
ConfigMaps store non-sensitive config (env names, feature flags, app properties). Secrets store sensitive data (passwords, API keys, TLS certs) — base64-encoded in etcd, encrypted at rest via KMS envelope encryption. Across environments: we use ESO (External Secrets Operator) — one ExternalSecret per service per environment that pulls from AWS Secrets Manager paths like `/ecom/dev/mysql-credentials` and `/ecom/prod/mysql-credentials`. The Helm chart references the same K8s Secret name in all envs; ESO fills the value from the environment-specific Secrets Manager path. Rotation: update Secrets Manager → ESO syncs the K8s Secret → Reloader triggers rolling restart → zero downtime secret rotation.

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

---

## 10. HPA — Horizontal Pod Autoscaler

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

**[G] Walk me through your HPA setup in this project.**
We have HPA on `product-category` and `order-service` — both stateless services with variable traffic. Both set `minReplicas: 2` (availability — one per AZ), `maxReplicas: 5`, `cpuTargetPercent: 60`. 60% target gives a buffer before the pod is overwhelmed — if we waited until 90%, pods would be CPU-saturated while waiting for scale-up. metrics-server is installed as a Helm release via Terraform (`metrics.tf`). Without it, `kubectl top pods` and HPA both return nothing. In ArgoCD we added `ignoreDifferences` on `/spec/replicas` so ArgoCD doesn't revert HPA's live replica count back to the git value every sync cycle.

**[G] What metrics can HPA scale on?**
Three types: (1) Resource metrics — CPU and memory as a percentage of requests. Served by metrics-server via `metrics.k8s.io`. Most common. (2) Custom metrics — application-specific metrics like requests-per-second from Prometheus. Served by a custom metrics adapter. (3) External metrics — metrics from outside the cluster: SQS queue depth, Kafka lag, Redis length. Served by an external metrics adapter (KEDA's metrics-apiserver for AWS). CPU-based HPA is fine for request-driven services. For queue-driven workers (notification-worker), external metrics via KEDA give much tighter scaling.

**[S] `kubectl describe hpa` shows `TARGETS: <unknown>/60%`. Pods are running. What's wrong?**
Resource `requests` are not set on the Deployment's container spec. HPA calculates CPU utilisation as `(current CPU usage) / (requested CPU)`. Without `requests.cpu` set, the denominator is 0 — the API returns `<unknown>`. Fix: add `resources.requests.cpu` and `resources.requests.memory` to every container the HPA targets. This also fixes scheduler bin-packing — without requests, the scheduler doesn't know how much space a pod needs and may overcommit a node.

**[G] Difference between HPA and KEDA.**
HPA is built into Kubernetes and scales on internal metrics only — CPU and memory from metrics-server, or custom app metrics via a Prometheus adapter. Its minimum replica count is 1 — it cannot scale to zero. KEDA extends HPA: it supports 70+ external event sources (SQS, Kafka, Redis, Cron, etc.), and it can scale to zero by patching the Deployment directly when the queue is empty. Under the hood, KEDA creates and manages its own HPA object for the 1→N path. Think of KEDA as HPA with superpowers: external triggers + scale-to-zero.

---

## 11. VPA — Vertical Pod Autoscaler

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

## 12. Cluster Autoscaler

### Cheat Sheet

| Concept | Key Point |
|---|---|
| What it does | Adds/removes EC2 nodes by calling ASG `SetDesiredCapacity` |
| Scale-up trigger | Pod in `Pending` state — scheduler couldn't place it |
| Scale-down trigger | Node underutilised for 10+ min AND all pods fit on other nodes |
| ASG discovery | Two tags on node group: `k8s.io/cluster-autoscaler/enabled=true` + `k8s.io/cluster-autoscaler/<cluster-name>=owned` |
| What CA polls | Kubernetes API for Pending pods (~every 10s) and node utilisation |
| IRSA SA name pitfall | Helm chart creates `<release>-aws-cluster-autoscaler` by default — trust policy `:sub` must match exactly or `AccessDenied` |
| node_max_size must be raised | CA cannot scale beyond `max_size` on the ASG — default 2 means CA is silently capped |
| Slower than Karpenter | Must wait for ASG to launch EC2, node to boot and join. ~2-5 min. |
| topologySpreadConstraints | Can keep pods Pending even after a node is added (wrong AZ) — CA is not at fault |

### Questions

**[G] How does Cluster Autoscaler know which node group to scale?**
It scans every ASG in the account for two tags: `k8s.io/cluster-autoscaler/enabled=true` and `k8s.io/cluster-autoscaler/<cluster-name>=owned`. Without both tags the ASG is invisible to CA — it silently does nothing even when pods are Pending. Once it finds the tagged ASG, it simulates whether adding one node of that type would make the Pending pods schedulable (checking resource requests, node selectors, tolerations, topology constraints). If yes, it calls `SetDesiredCapacity +1`.

**[G] Cluster Autoscaler vs Karpenter — key difference?**
CA works with existing fixed node groups (ASGs) — picks which pre-defined group to scale, calls `SetDesiredCapacity`, waits for ASG to launch EC2. Slow — 2-5 min for a new node. Karpenter bypasses ASG entirely: it bin-packs pending pods, picks the exact right instance type for those specific pods, and calls `ec2:RunInstances` directly. Faster — ~30-60s for a new node. Karpenter also does active consolidation: if 3 half-full nodes can fit on 2, it drains and terminates one. CA never does consolidation proactively.

**[S] CA pod is Running but pods stay Pending and no new node appears. What do you check?**
In order: (1) `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler` — CA logs its reason for not scaling. (2) Missing ASG discovery tags — CA's first log line on startup lists the ASGs it found. If empty, tags are wrong or missing. (3) `node_max_size` — if current node count equals max_size, CA logs "node group at max size". (4) IRSA error — `AccessDenied on sts:AssumeRoleWithWebIdentity` means CA can't call the ASG API at all. (5) topologySpreadConstraints — pod may require an AZ that the node group doesn't cover; CA found the group but adding a node there won't help.

**[S] CA is installed but shows `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`. Root cause?**
IRSA trust policy `:sub` condition doesn't match the actual service account name. The Helm chart for cluster-autoscaler auto-generates the SA name as `<release-name>-aws-cluster-autoscaler`. If the trust policy was written for `cluster-autoscaler` (bare name), the token the pod presents has subject `system:serviceaccount:kube-system:cluster-autoscaler-aws-cluster-autoscaler` — a mismatch → AccessDenied. Fix: either set `rbac.serviceAccount.name=cluster-autoscaler` in the Helm values to force the short name, or update the trust policy `:sub` to match the generated name. We hit this exact issue — fixed by setting `rbac.serviceAccount.name` in `cluster-autoscaler.tf`.

**[I] You scale a Deployment to 20 replicas as a test. New nodes appear but then the HPA pulls the count back down to 5. CA then removes the nodes. Is this expected?**
Yes. HPA `maxReplicas: 5` is a hard ceiling — it overrides any manual `kubectl scale` immediately. The sequence: manual scale to 20 → HPA caps at 5 → a few pods go Pending briefly → CA adds nodes → HPA settles at 5 → extra nodes become idle → CA detects underutilisation after 10 min cooldown → calls `SetDesiredCapacity` back down → nodes terminate. All three (manual scale, HPA, CA) are acting correctly. The CA scale-down cooldown exists specifically to avoid thrashing on temporary spikes — it waits 10 min of sustained underutilisation before removing a node.

**[G] Walk me through your Cluster Autoscaler setup — how did you install it and what did you configure?**
Three changes in Terraform: (1) `variables.tf` — raised `node_max_size` from 2 to 5. Without this CA is silently capped at the current node count. (2) `eks.tf` — added two discovery tags to the node group: `k8s.io/cluster-autoscaler/enabled=true` and `k8s.io/cluster-autoscaler/ecom=owned`. EKS propagates these to the underlying ASG so CA can find it. (3) New `cluster-autoscaler.tf` — IRSA role (trust policy scoped to `kube-system:cluster-autoscaler` SA only) + IAM policy with `autoscaling:SetDesiredCapacity` and `autoscaling:TerminateInstanceInAutoScalingGroup` + Helm release of `kubernetes/autoscaler` chart v9.46.6 in `kube-system`. One pitfall we hit: the Helm chart generates the SA name as `<release>-aws-cluster-autoscaler` by default, which didn't match our trust policy — fixed by setting `rbac.serviceAccount.name=cluster-autoscaler` in the Helm values.

**[G] How does Cluster Autoscaler respect PodDisruptionBudgets during scale-down?**
Before draining a node for scale-down, CA simulates the eviction of every pod on that node. If evicting a pod would violate its PDB (e.g. PDB says `minAvailable: 1` and it's the last pod), CA skips that node and tries another. This is why PDB is critical before enabling CA — without it, CA can drain the last replica of a service causing downtime. In our project, product-category and order-service both run 2 replicas across 2 AZs with `topologySpreadConstraints`, so CA can safely drain one node while the other AZ's pod stays up.

**[S] CA is trying to scale down but nodes stay for hours. `kubectl describe node` shows pods blocked from eviction. Why?**
A PDB is blocking it. CA simulates eviction — if any pod has a PDB that would be violated, CA will not drain that node. Check: `kubectl get pdb -A` to see all PDBs and their `ALLOWED DISRUPTIONS` column. If it shows `0`, that PDB is blocking all evictions right now. Either the service has too few replicas (fix: scale up first), or the PDB is misconfigured (e.g. `maxUnavailable: 0` with `minAvailable` equal to current replica count). Also check for pods with `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` annotation — CA skips those nodes entirely.

**[G] How do you reduce cloud infrastructure costs using Cluster Autoscaler?**
CA removes underutilised nodes automatically — no manual cleanup. In practice: set `node_min_size` to the minimum needed for production stability (not 0 — cold start on all traffic would be catastrophic), and `node_max_size` to the burst ceiling. Then let CA handle the middle. Additional levers: (1) Use spot instances for non-critical workloads — CA works with mixed ASGs. (2) Set resource requests accurately — overprovisioned requests waste node capacity and trigger unnecessary CA scale-up. (3) PDB ensures CA can actually do the scale-down. Without PDB awareness, CA might add nodes but never remove them because it can't safely drain.

---

## 13. Karpenter

### Cheat Sheet

| Concept | Key Point |
|---|---|
| NodePool CRD | What workloads Karpenter accepts — instance families, capacity type (spot/OD), AZs, limits |
| EC2NodeClass CRD | HOW to build the EC2 — AMI, subnets, security groups, IAM instance profile |
| Bypass ASG | Calls `ec2:RunInstances` directly — no ASG in the path. ~30-60s vs CA's 2-5 min |
| Bin-packing | Looks at ALL pending pods together, picks the one instance type that fits them cheapest |
| Consolidation | After pods leave, merges underutilised nodes — drains + terminates. CA never does this |
| System node group stays | Karpenter manages APP nodes. System pods (kube-system) stay on the existing managed node group |
| Taint required | `NO_SCHEDULE` taint on system node group pushes app pods onto Karpenter nodes |
| Subnet/SG discovery | Karpenter finds subnets and security groups by tag: `karpenter.sh/discovery=<cluster-name>` |
| Spot interruption | SQS queue + EventBridge rule — 2-min warning from EC2 → Karpenter drains the node gracefully |
| karpenter-node IAM role | Separate from cluster node role — nodes Karpenter creates need their own instance profile |

### Questions

**[G] What is the fundamental difference between how CA and Karpenter launch nodes?**
CA calls `autoscaling:SetDesiredCapacity` on an existing ASG. AWS then launches the EC2, it boots, installs the agent, joins the cluster — 2-5 minutes total. Karpenter calls `ec2:RunInstances` directly. It picked the exact instance type by bin-packing pending pods, passes the nodeadm bootstrap config inline, and the node joins in ~30-60 seconds. CA is constrained to whatever node group types you pre-defined. Karpenter can use any instance type in the NodePool — it picks the cheapest one that fits the pods.

**[G] Why do you keep the existing managed node group when adding Karpenter?**
The existing node group runs system pods: CoreDNS, KEDA, metrics-server, Karpenter itself. These need stable, always-on ON_DEMAND nodes that Karpenter never touches. If Karpenter ran on Karpenter-managed nodes, it could theoretically drain and terminate the node its own pod is on. The split: taint the system node group with `NO_SCHEDULE` (app pods avoid it) + Karpenter creates separate nodes for app pods. Two tiers: stable system tier + dynamic app tier.

**[G] What is consolidation in Karpenter and why doesn't CA do it?**
Consolidation: after traffic drops, you have 3 nodes each at 30% utilisation. Karpenter calculates they can all fit on 2 nodes → it cordons one node, drains its pods (they reschedule onto the other two), then terminates the EC2. Pure cost saving with zero manual work. CA only scales down nodes that are completely empty (no pods other than daemonsets/mirror pods) for 10+ consecutive minutes. It never moves pods to consolidate. Karpenter's `WhenEmptyOrUnderutilized` consolidation policy is a major operational advantage.

**[S] Karpenter-provisioned spot node gets a 2-minute termination warning from EC2. What happens?**
AWS publishes a spot interruption notice to EventBridge → EventBridge forwards it to the Karpenter SQS queue → Karpenter's operator pod reads the message → it cordons the node (no new pods scheduled) → drains it (sends SIGTERM to pods, respects PDB, waits for graceful shutdown) → pods reschedule onto other nodes → EC2 terminates. The 2-minute window is enough for graceful shutdown if pods have a low `terminationGracePeriodSeconds`. Without the SQS queue wired up, Karpenter doesn't get the warning — EC2 yanks the node mid-request.

**[G] Difference between NodePool and EC2NodeClass in Karpenter.**
NodePool = the WHAT and the policy. It defines what workloads Karpenter accepts (instance families, capacity type spot/on-demand, AZs), the min/max replica limits (CPU ceiling so costs don't spiral), and the consolidation policy. EC2NodeClass = the HOW on AWS. It defines the AMI to use, which subnets to launch into, which security group to attach, and the IAM instance profile for the node. The split exists so you can have multiple NodePools (one for spot, one for on-demand, one for GPU) all sharing one EC2NodeClass — you change the AMI once in EC2NodeClass and all NodePools pick it up.

**[G] How do you use spot instances safely with Karpenter?**
In the NodePool, set `capacity-type: ["spot", "on-demand"]` and list multiple instance families: `["t3.medium", "t3.large", "t3a.medium", "t3a.large"]`. Karpenter tries spot first (70% cheaper) and falls back to on-demand automatically if spot capacity is unavailable. The SQS interruption queue handles the 2-minute warning — Karpenter drains gracefully before AWS terminates. Rule: never run stateful workloads (databases) on spot — only stateless services where a pod restart is safe. In our project, notification-worker is a perfect spot candidate: stateless, processes SQS messages, graceful shutdown.

**[S] Karpenter pod is Running but pods remain Pending and no new nodes appear.**
Check in order: (1) `kubectl describe pod <pending-pod>` — what does the scheduler say? If it says "0 nodes available", the NodePool constraints might be too tight (wrong instance type, AZ not available for spot). (2) `kubectl get nodepool` — check the NodePool's `READY` status. (3) Subnet and SG tags — Karpenter finds subnets by `karpenter.sh/discovery=<cluster-name>` tag. If subnets aren't tagged, Karpenter can't find where to launch. (4) IAM — `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter` — `AccessDenied on ec2:RunInstances` means the IRSA role is missing EC2 permissions. (5) EC2NodeClass `Ready` status — if the AMI alias doesn't resolve (e.g. `al2023@latest` in a region with no AL2023 AMI), EC2NodeClass shows NotReady.

**[G] How would you design autoscaling for a high-traffic e-commerce platform on EKS?**
Three layers: (1) Pod-level: HPA on CPU for stateless services (product, order, frontend) — scales within the existing nodes. KEDA on SQS depth for async workers (notification, email) — scale to zero between traffic peaks, burst during flash sales. (2) Node-level: Karpenter for app nodes — spot instances for 70% cost saving, fast ~60s provisioning for flash sale spikes, consolidation to remove idle nodes overnight. System node group stays ON_DEMAND for stability. (3) Config: PDB on every service (min 1 replica always available), `topologySpreadConstraints` across AZs so a node loss doesn't kill a service, resource requests set accurately so scheduler bin-packing and HPA work correctly. The result: infrastructure scales automatically from overnight maintenance window (minimal nodes) to Black Friday traffic (many nodes) without manual intervention.

---

## 14. KEDA — Event-Driven Autoscaling

### Cheat Sheet

| Concept | Key Point |
|---|---|
| What it does | Scales pods based on external event sources — not CPU/memory |
| ScaledObject CRD | Defines trigger source, min/max replicas, cooldownPeriod |
| TriggerAuthentication CRD | How KEDA authenticates with the external system (IRSA for AWS) |
| Scale to zero | HPA `minReplicas` hard floor is 1. KEDA patches Deployment directly to go to/from 0 |
| Two-path scaling | 0→1 and queue-empty→0: keda-operator patches Deployment directly. 1→N: keda creates an HPA backed by external metric |
| Three pods | `keda-operator` (brain, polls SQS), `keda-metrics-apiserver` (answers HPA metric queries), `keda-admission-webhooks` (validates ScaledObject YAML) |
| Metric name format | Auto-generated: `s{index}-{trigger-type}-{queue-name}` e.g. `s0-aws-sqs-order-events` |
| API routing | HPA type=Resource → `metrics.k8s.io` (metrics-server). HPA type=External → `external.metrics.k8s.io` (keda-metrics-apiserver) |
| identityOwner: operator | KEDA operator's IRSA role calls `sqs:GetQueueAttributes` — no notification-worker pod needed. Safe at scale-to-zero |
| cooldownPeriod | Seconds KEDA waits after queue empties before scaling to 0. Prevents cold-start thrash on burst traffic |
| gRPC bridge | HPA calls keda-metrics-apiserver via REST → keda-metrics-apiserver calls keda-operator via gRPC :9666 → operator returns live SQS depth |

### Questions

**[G] What is KEDA and when does HPA not work?**
KEDA (Kubernetes Event-Driven Autoscaling) scales pods based on external event sources — SQS queue depth, Kafka consumer lag, Redis list length. HPA works on CPU/memory — internal metrics. A notification worker that processes SQS messages: when the queue is empty it should have 0 pods, when it has 10,000 messages it needs 50 pods. CPU doesn't reflect this — the worker might be idle (low CPU) while messages pile up. KEDA reads the SQS queue depth directly and scales accordingly.

**[G] Why can't HPA scale to zero, and how does KEDA solve it?**
HPA has a hard-coded minimum of 1 replica — it's a Kubernetes API constraint, not a config option. It's designed for always-on services where 0 replicas would mean a cold start on every request. KEDA solves this by bypassing HPA entirely for the 0↔1 transition: it patches `spec.replicas` on the Deployment directly via the Kubernetes API. For 1→N scaling, KEDA creates an HPA object internally (you see `keda-hpa-<name>`) and feeds it external metrics. So KEDA is not replacing HPA — it's layered on top: HPA handles 1→N, KEDA handles the 0 boundary.

**[G] Explain KEDA's three pods and what each one does.**
`keda-operator`: the brain. Runs a control loop that polls SQS `GetQueueAttributes` every ~30s. Owns the ScaledObject reconciler. When queue depth crosses the threshold, directly patches the Deployment. `keda-operator-metrics-apiserver`: a Kubernetes aggregated API server that registers at `external.metrics.k8s.io`. When the HPA needs to evaluate whether to scale from 1 to N, it calls this server with a metric name (e.g. `s0-aws-sqs-order-events`). This server calls keda-operator via gRPC on port 9666 to get the live SQS depth, then returns it to HPA. `keda-admission-webhooks`: a validating admission webhook that catches malformed ScaledObject YAML at `kubectl apply` time before it creates bad state in the cluster.

**[G] When HPA needs the current SQS queue depth, what is the full call path?**
HPA controller (in kube-system, part of control plane) → HTTPS REST to Kubernetes API server → API server routes to `external.metrics.k8s.io` registered endpoint → that endpoint is `keda-metrics-apiserver` pod → it calls `keda-operator` pod via gRPC on port 9666 → keda-operator returns the cached SQS `ApproximateNumberOfMessages` value → keda-metrics-apiserver returns it to the API server → API server returns it to HPA → HPA does `ceil(depth / queueLength)` to compute desired replicas.

**[S] KEDA ScaledObject shows READY=False. `kubectl describe scaledobject` shows `unable to get queue attributes: AccessDenied`. What's wrong?**
IRSA not wired. Either: (1) TriggerAuthentication is missing `podIdentity.provider: aws` — KEDA is trying to use anonymous credentials. (2) The `keda-operator` ServiceAccount in kube-system has no `eks.amazonaws.com/role-arn` annotation — the role ARN wasn't passed via Helm `serviceAccount.operator.annotations`. (3) The IAM role's trust policy has the wrong OIDC conditions — wrong `:sub` value (namespace or SA name mismatch). (4) The IAM policy allows `sqs:GetQueueAttributes` but on the wrong resource ARN. Check in that order.

**[S] notification-worker stays at 0 replicas even when the SQS queue has 50 messages. What do you check?**
(1) `kubectl get scaledobject -n ecom` — is READY=True? If False, KEDA itself is misconfigured (IRSA/auth issue). (2) `kubectl describe scaledobject notification-worker-scaledobject -n ecom` — look at the `Conditions` block and `Active` status. (3) `kubectl get hpa -n ecom` — KEDA should have created `keda-hpa-notification-worker`. If the HPA doesn't exist, ScaledObject never reached Ready state. (4) Check `identityOwner: operator` in the ScaledObject trigger metadata — if it's missing or set to `pod`, KEDA tries to use the notification-worker pod's IRSA role, but at 0 replicas there is no pod → chicken-and-egg → never scales up.

**[G] What is `cooldownPeriod` in a ScaledObject and why does it matter for SQS?**
After the queue drains to 0 messages, KEDA waits `cooldownPeriod` seconds before setting replicas to 0. Without it: a burst of 5 messages arrives → KEDA scales to 1 → worker processes them → queue empty → KEDA immediately scales to 0 → next 5 messages arrive → cold start (30-60s pull new image, JVM warmup) → latency spike. With `cooldownPeriod: 30`: KEDA waits 30s after queue empties before scaling down. Small bursts are absorbed within that window — the worker is already warm when the next batch arrives. Set it based on how frequently your producer sends batches.

**[G] How does KEDA integrate with MSK (Managed Kafka) when direct Kafka auth isn't possible?**
KEDA's built-in Kafka scaler uses a Go Kafka client that historically couldn't do AWS IAM auth (SASL/OAUTHBEARER for MSK). Pattern: MSK publishes `SumOffsetLag` to CloudWatch → deploy `k8s-cloudwatch-adapter` → adapter reads the CloudWatch metric and exposes it as an external metric in the cluster → KEDA uses a `cloudwatch` scaler type to read it. Benefits: (1) no direct connection to MSK brokers needed (no security group changes), (2) CloudWatch metric is already aggregated across all partitions, (3) same IRSA pattern as all other AWS-calling pods.

**[I] A KEDA-scaled worker stays at 0. You place a test order. Worker spins up, processes it, scales back to 0. But the original order that triggered scale-up is processed twice — once by the scale-up pod and once 10 minutes later by a new pod. Why?**
Message visibility timeout. When the first pod received the message, it started processing but didn't delete it before the visibility timeout expired (default: 30s for SQS, configurable). SQS made the message visible again → second pod picked it up. Fix: either increase `VisibilityTimeout` on the queue to be longer than the slowest possible processing time, or delete the message immediately after successful processing (use `AUTO` ack mode — which is what `ON_SUCCESS` does in Spring Cloud AWS). We hit a variant of this during notification-worker debugging — switched to `ON_SUCCESS` auto-ack.

**[G] Walk me through your KEDA setup in this project.**
KEDA scales our `notification-worker` to 0 when the `order-events` SQS queue is empty, and up to 5 replicas at peak. Four pieces: (1) `terraform/keda.tf` — IRSA role for `kube-system:keda-operator` SA with `sqs:GetQueueAttributes` permission, plus Helm release of `kedacore/keda` chart v2.16.0. (2) `helm/ecom/templates/notification-worker-triggerauth.yaml` — `TriggerAuthentication` with `podIdentity.provider: aws` telling KEDA to use the operator's IRSA role, not static credentials. (3) `helm/ecom/templates/notification-worker-scaledobject.yaml` — `ScaledObject` pointing at the SQS queue, `queueLength: 5` (one replica per 5 messages), `minReplicaCount: 0`, `cooldownPeriod: 30s`. (4) `GitOps/apps/ecom-dev.yaml` — `ignoreDifferences` on `notification-worker`'s `/spec/replicas` so ArgoCD doesn't revert KEDA's 0-replica state back to 1 every sync cycle.

**[G] Why does ArgoCD need `ignoreDifferences` when KEDA is installed?**
ArgoCD compares live cluster state to git. In git, `notificationWorker.replicaCount: 1`. KEDA sets `spec.replicas: 0` when the queue is empty. ArgoCD sees "live=0, git=1" → marks the app OutOfSync → `selfHeal: true` kicks in → ArgoCD applies the Helm chart → replica count goes back to 1. This fights KEDA on every sync cycle. `ignoreDifferences` on `/spec/replicas` for the notification-worker deployment tells ArgoCD: "I know this field will differ, that's intentional — don't touch it." Same applies to product-category and order-service: HPA sets live replicas to 3 while git says 2 — without `ignoreDifferences`, ArgoCD would undo the HPA's work.

**[G] What happens to a KEDA-scaled deployment when KEDA itself crashes?**
The last HPA that KEDA created stays in place. HPA continues scaling between 1 and maxReplicas using the last known metric value. But: (1) scale-to-zero stops working — no KEDA operator means nobody patches `spec.replicas` to 0. (2) No new metric reads — the HPA will eventually show `<unknown>` for the external metric and stop scaling altogether. (3) ArgoCD may now resync and revert replicas to the git value since KEDA is no longer managing it. Fix: monitor KEDA's own pods via alerts on `kube-system` pod restarts. KEDA being down is a silent scaling failure — traffic still flows but you're paying for idle workers.

**[S] How do you implement zero-downtime scaling in Kubernetes?**
Four requirements working together: (1) Readiness probe — HPA only routes traffic to pods that pass the readiness check. A new pod that hasn't finished startup doesn't receive traffic yet. (2) `minReplicas ≥ 2` — HPA never scales below 2, so there's always at least one pod serving traffic while another starts. (3) PDB — prevents CA/Karpenter from draining the last pod during node scale-down. (4) `terminationGracePeriodSeconds` — gives pods time to finish in-flight requests before being killed (default 30s — set higher for slow request processing). Miss any one of these and you get 502s during scaling events.

---

## 15. SLI / SLO / Error Budget

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

## 16. Scaling Best Practices

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

**[G] How do you handle sudden traffic spikes in Kubernetes?**
Multiple layers fire in sequence: (1) Existing pods absorb the spike via CPU bursting (t3.medium is burstable). (2) Within seconds, HPA detects CPU > 60% target → scales pod count up to maxReplicas (5). (3) If new pods can't fit on existing nodes, they go Pending → CA/Karpenter adds a node within 1-3 minutes (Karpenter faster). (4) KEDA fires in parallel for queue-backed workers — queue depth rises → KEDA scales notification-worker from 0 to N immediately. Prep: readiness probes ensure traffic only hits ready pods, PDB ensures no downtime during the scaling event, and `topologySpreadConstraints` ensures new replicas spread across AZs rather than piling up on one node.

**[G] How do you reduce Kubernetes cloud costs without affecting availability?**
Five levers: (1) KEDA scale-to-zero for async workers — notification-worker runs 0 pods overnight when no orders come in. (2) Karpenter consolidation — merges underutilised nodes actively, removes half-empty nodes that CA would leave. (3) Spot instances for non-critical workloads — 70% cheaper, Karpenter handles spot interruptions gracefully. (4) Accurate resource requests — overprovisioned requests waste slot capacity and trigger unnecessary CA scale-up. Use VPA Off-mode to get recommendations. (5) `minReplicas: 2` not 3 — you need ≥ 2 for AZ redundancy, but 3 burns an extra pod 24/7. Let HPA handle the peak.

**[G] Difference between horizontal and vertical scaling. When do you use each in Kubernetes?**
Horizontal scaling (HPA): add more pod replicas — share the load across many pods. No downtime, works for stateless services. Vertical scaling (VPA): give each pod more CPU/memory — one bigger pod instead of more pods. Requires pod restart in `Auto` mode — brief disruption. Use HPA for: stateless services (product-svc, order-svc), anything with variable traffic. Use VPA recommendations (Off mode) for: right-sizing initial requests on any service, especially JVM apps that consistently use more memory than requested. VPA Auto mode in production: only for batch jobs or low-traffic services where a restart is acceptable.

**[G] What is the difference between a liveness probe and readiness probe in the context of autoscaling?**
Readiness probe: "is this pod ready to receive traffic?" HPA and Services both respect it — a pod fails readiness → removed from Service endpoints → no traffic → HPA doesn't count it toward utilisation. Critical during scale-up: a new pod that's still warming up doesn't get flooded with traffic before it's ready. Liveness probe: "is this pod alive?" If it fails, kubelet kills and restarts the pod. Not directly tied to scaling — it's crash recovery. Common mistake: making readiness probe too fast. A Spring Boot app that takes 30s to start fails readiness immediately → HPA sees a pod at 0% → may not scale up enough.

**[I] Walk me through a production incident where autoscaling failed and caused downtime.**
During a flash sale, product-category HPA hit `maxReplicas: 5` — couldn't scale further. New pods went Pending. CA saw Pending pods → tried to add a node. But `node_max_size` was still 2 in Terraform from before task #26a. CA logged "node group at max size" and did nothing. Pods sat Pending for 8 minutes — during which requests were queued or dropped → latency spike → users saw 504s. Fix applied: raised `node_max_size` to 5 in `variables.tf` + re-ran terraform apply. Lesson: HPA `maxReplicas` and CA `node_max_size` must be sized together. Scaling one without the other creates a silent ceiling.

---

## 17. ResourceQuota & LimitRange

### Cheat Sheet

| Concept | Key Point |
|---|---|
| ResourceQuota | Namespace-level ceiling — total CPU, memory, pods, PVCs the whole namespace can consume |
| LimitRange | Per-container defaults and bounds — default request, default limit, min, max per container |
| Why both | Quota stops a namespace consuming unbounded resources. LimitRange ensures containers without explicit requests still count toward Quota. |
| Quota enforcement requires requests | If a container has no requests, Quota can't count it — LimitRange's `defaultRequest` fixes this by injecting a request automatically |
| `requests.cpu` vs `limits.cpu` | Quota tracks both separately — a pod with `requests.cpu: 500m` and `limits.cpu: 1` counts against both buckets |
| Admission timing | Both are enforced at pod creation by the admission controller — rejected before scheduling |

### Questions

**[G] What is the difference between ResourceQuota and LimitRange?**
ResourceQuota is a namespace-level ceiling — it caps the total resources all pods in a namespace can request/limit in aggregate. Example: `requests.cpu: 4` means all pods combined cannot request more than 4 CPU cores. LimitRange is a per-container policy — it sets defaults and bounds for individual containers. If a container doesn't specify `requests.cpu`, LimitRange injects a default. If a container tries to request more than `max.cpu`, admission rejects it. Use both together: Quota prevents namespace runaway, LimitRange prevents individual containers from claiming the entire Quota in one pod.

**[G] Why do you need LimitRange if you already have ResourceQuota?**
ResourceQuota only tracks what pods have explicitly requested. A container with no requests set is "invisible" to Quota — it can schedule and run without counting against the Quota, effectively bypassing it. LimitRange's `defaultRequest` injects a request automatically on any container that doesn't specify one. Now every container counts against Quota. Without LimitRange, one developer could deploy hundreds of pods with no requests set and exhaust cluster resources while Quota reports 0% used.

**[S] A new developer deployed a pod with no resource requests or limits. Other pods in the namespace started failing admission with "exceeded quota". Why?**
Without LimitRange, a pod with no requests runs fine and doesn't count against Quota. But if LimitRange IS configured with a `defaultRequest`, that request is injected automatically at admission. The developer's pod got a default request injected, which consumed Quota budget. Later pods hit the quota ceiling. Fix: (1) Check `kubectl describe resourcequota -n <ns>` to see current usage vs hard limit. (2) Increase the Quota, or (3) tune the LimitRange `defaultRequest` to a smaller value, or (4) have the developer set explicit requests at the correct size.

**[S] You set a ResourceQuota of `requests.cpu: 4` for the dev namespace. A developer tried to deploy a pod requesting 2 CPU — it was rejected even though only 2.5 CPU was already used. Why?**
Check the existing pods. A pod with no requests set may have had LimitRange's `defaultRequest` injected, consuming part of the 1.5 CPU gap. Or: a completed Job pod that wasn't cleaned up is still counted by Quota (Quota counts all pods in non-terminal states). Fix: `kubectl get pods -n dev --field-selector=status.phase!=Running,status.phase!=Succeeded` — find non-running pods still consuming quota. Clean them up. Also confirm with `kubectl describe resourcequota -n dev` — it shows `used` vs `hard` for each resource.

---

## 18. Stakater Reloader

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Problem it solves | ConfigMap/Secret changes don't restart pods — envFrom is baked at pod start, pod never sees new value |
| How it works | Runs as a Deployment (one pod, cluster-wide). Watches K8s Secrets and ConfigMaps via informer. On change → patches Deployment annotation → K8s rolling update fires |
| Auto mode | `reloader.stakater.com/auto: "true"` on the Deployment — restarts on ANY mounted Secret/ConfigMap change |
| Targeted mode | `secret.reloader.stakater.com/reload: "app-secret"` — restarts only when that specific Secret changes |
| NOT needed for volume mounts | Kubelet syncs volume-mounted Secrets automatically (~1 min). Reloader is for envFrom only. |
| Installed via Helm | `helm repo add stakater https://stakater.github.io/stakater-charts && helm install reloader stakater/reloader -n kube-system` |
| ArgoCD + Reloader interaction | ArgoCD applies the ConfigMap. Reloader patches the Deployment annotation. ArgoCD then sees the annotation diff as OutOfSync. Fix: add `ignoreDifferences` for the annotation in ArgoCD Application config. |

### Questions

**[G] What is Stakater Reloader and why do you need it?**
Reloader solves the envFrom stale-value problem. When a Deployment uses `envFrom` to load a Secret or ConfigMap, those values are baked into the process environment at pod start — they never update while the pod is running. Reloader runs as a separate Deployment with one pod. It watches all Secrets and ConfigMaps via the K8s informer API. When a watched resource changes in etcd, Reloader patches an annotation on the Deployment's pod template (`reloader.stakater.com/last-reload: <timestamp>`). Since pod template changed, K8s triggers a rolling update. New pods pick up the new Secret/ConfigMap value. Zero manual intervention.

**[G] Reloader vs volume mount — when do you use each for secrets?**
Volume mount: Secret is mounted as a file on tmpfs. Kubelet automatically syncs the file when the K8s Secret changes — no pod restart, no Reloader needed. The app must re-read the file to get the new value (works for TLS certs, token files). envFrom + Reloader: Secret is injected as env vars. Reloader detects the change and triggers a rolling restart — pods come up fresh with new values. Use volume mount for: TLS certs, long-lived tokens where hot-reload is important. Use envFrom + Reloader for: database passwords, API keys where the app reads them once at startup and the rolling restart is acceptable.

**[S] You deployed Reloader. ArgoCD keeps showing the Deployment as OutOfSync even though you haven't changed anything. Why?**
Reloader patches the Deployment's pod template annotation every time it processes a reload. ArgoCD compares the live Deployment against the Git-declared one — the annotation is in Git as absent (or with a timestamp from last sync), but Reloader added a new value in the cluster. ArgoCD sees a diff: cluster has `reloader.stakater.com/last-reload: 2024-01-15T10:30:00Z`, Git doesn't. It reports OutOfSync. Fix: add `ignoreDifferences` in the ArgoCD Application spec:
```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/template/metadata/annotations/reloader.stakater.com~1last-reload
```
Now ArgoCD ignores that annotation when comparing. The Deployment stays InSync.

**[S] You have a Secret that rotates every 24 hours via ESO from Secrets Manager. Pods need to pick up the new value with minimal downtime. Design the setup.**
Full chain: (1) Secrets Manager rotates the secret value every 24h (Lambda rotation function or manual update). (2) ESO ExternalSecret has `refreshInterval: 1h` — it polls Secrets Manager and updates the K8s Secret within 1 hour of rotation. (3) Stakater Reloader watches the K8s Secret. On update, it patches the Deployment annotation → rolling update starts. (4) Rolling update respects PDB and readiness probes — new pods with new credentials come up, old pods drain, zero downtime. End-to-end: at most 1h lag (ESO sync) + ~60 seconds for rolling update. For critical secrets needing faster rotation: reduce ESO `refreshInterval` to `5m`. For volume-mounted secrets (TLS certs): skip Reloader — kubelet auto-syncs the file, app re-reads on next cert check.

---

## 19. Velero — Cluster Backup & Restore

### Cheat Sheet

| Concept | Key Point |
|---|---|
| What it backs up | Kubernetes objects (Deployments, Services, ConfigMaps, Secrets, PVCs) from etcd via K8s API |
| What it does NOT back up by default | PVC data (EBS volume contents) — needs the CSI snapshot plugin |
| CSI snapshot plugin | Triggers an EBS snapshot at backup time — captures volume data alongside K8s objects |
| Storage backend | S3 bucket — stores object JSON snapshots and volume snapshot metadata |
| `BackupStorageLocation` CRD | Tells Velero which S3 bucket/prefix and which AWS region |
| `VolumeSnapshotLocation` CRD | Tells Velero which region to create EBS snapshots in |
| Schedule CRD | Cron expression for automatic backups — `0 2 * * *` = daily at 2am |
| Restore scope | Can restore entire cluster, a namespace, or specific resources by label |
| TTL | Backup retention period — Velero deletes old backups automatically from S3 |
| IRSA | Velero needs `s3:PutObject`, `s3:GetObject`, `ec2:CreateSnapshot`, `ec2:DescribeSnapshots` |

### Questions

**[G] What is Velero and what does it protect you from?**
Velero is a Kubernetes backup and restore tool. It backs up all K8s API objects (Deployments, Services, ConfigMaps, Secrets, PVCs) to S3, and optionally snapshots EBS volumes. Three failure modes it protects against: (1) Accidental deletion — someone `kubectl delete namespace ecom`, restore from yesterday's backup in minutes. (2) Cluster migration — take a backup, restore into a new cluster in a different region. (3) Cluster upgrade gone wrong — backup before the upgrade, restore the old state if the upgrade breaks something. What Velero is NOT: it's not a real-time replication tool. Recovery point is only as fresh as your last backup — daily backups mean up to 24h data loss. For lower RPO, use application-level replication (MySQL replication, not just Velero).

**[G] Why do you need the CSI snapshot plugin alongside Velero?**
Without it, Velero backs up the PVC object (the K8s resource definition) but not the actual data on the EBS volume. A restore would create an empty PVC. The CSI snapshot plugin hooks into the backup event: when Velero backs up a PVC, it calls the CSI driver (`ebs.csi.aws.com`) to create an EBS snapshot at that point in time. The snapshot is stored in AWS (same region as the cluster). On restore, Velero creates the PVC and instructs the CSI driver to restore from the snapshot. Without this plugin: you can restore your MySQL Deployment spec but you lose all your data.

**[G] What is the difference between `BackupStorageLocation` and `VolumeSnapshotLocation`?**
`BackupStorageLocation`: where the K8s object snapshots go — S3 bucket, prefix, and region. This is the JSON metadata for every Deployment, Service, ConfigMap etc. that Velero captured. `VolumeSnapshotLocation`: where EBS snapshots are created — AWS region. EBS snapshots live in AWS EC2 (not S3) — they just appear in the EC2 Snapshots console. Velero stores a pointer to each snapshot ID in S3 alongside the object metadata. On restore, it reads the pointer and calls `ec2:RestoreSnapshotFromRecycleBin` / creates a volume from the snapshot. You need both CRDs configured for a full backup that includes volume data.

**[S] You ran a Velero restore after an accidental `kubectl delete namespace ecom`. Pods come up but MySQL is empty. Why?**
The CSI snapshot plugin was not configured, or the PVC didn't have the `velero.io/exclude-from-backup: "false"` annotation explicitly set (some setups exclude PVCs by default). Velero restored the PVC object but not the volume data — MySQL started fresh on an empty EBS volume. Fix: (1) Verify `VolumeSnapshotLocation` is configured correctly in `velero get volumesnapshotlocation`. (2) Check that the backup includes volume snapshots: `velero describe backup <backup-name> --details` — look for `Persistent Volumes` section. (3) For next time: configure the CSI plugin before taking the backup you want to restore from.

**[S] `velero backup describe` shows `Phase: PartiallyFailed`. What do you check?**
`velero backup logs <backup-name>` — look for which resources failed. Common causes: (1) IRSA permissions missing — `AccessDenied on s3:PutObject` means the Velero ServiceAccount role doesn't have S3 write access. (2) CSI snapshot call failed — `AccessDenied on ec2:CreateSnapshot` means the IAM role is missing EC2 snapshot permissions. (3) A namespace has a ResourceQuota that Velero is hitting when it creates temporary objects. (4) Large PVCs that time out — increase `--snapshot-create-timeout` in the Velero Helm values. PartiallyFailed means some resources backed up successfully — you can still restore what succeeded, but the backup is incomplete.

**[G] Walk me through your Velero backup schedule in this project.**
Four pieces: (1) S3 bucket (`ecom-velero-backups`) — created in `scripts/`, outside Terraform, so Terraform destroy doesn't delete your backups. (2) IRSA role — `kube-system:velero` SA with S3 read/write on the backup bucket + EC2 snapshot permissions. (3) Velero Helm release — `vmware-tanzu/velero` chart, CSI plugin enabled, `BackupStorageLocation` pointing at the S3 bucket, `VolumeSnapshotLocation` in `us-east-2`. (4) `Schedule` object — daily at 2am UTC, `ttl: 720h` (30 days retention). The backup bucket is in `scripts/` because if Terraform destroys it during a `terraform destroy`, you lose all your backups — the whole point of backups is they outlive the cluster.

---

## 20. ALB + cert-manager TLS

### Cheat Sheet

| Concept | Key Point |
|---|---|
| AWS Load Balancer Controller | K8s controller that creates real ALBs/NLBs from Ingress and Service annotations |
| ALB vs NLB | ALB = Layer 7 (HTTP/HTTPS), path-based routing, can terminate TLS. NLB = Layer 4 (TCP), faster, no path routing. |
| IngressClass | `kubernetes.io/ingress.class: alb` tells the LBC this Ingress belongs to it |
| cert-manager | Automates TLS cert lifecycle — issues, renews, stores certs as K8s Secrets |
| Certificate issuers | `ClusterIssuer` (cluster-wide) vs `Issuer` (single namespace) |
| ACME / Let's Encrypt | Free certs, auto-renewed 30 days before expiry, uses HTTP-01 or DNS-01 challenge |
| ACM + ALB alternative | Provision cert in ACM → annotate Ingress with ACM ARN → ALB terminates TLS. No cert-manager needed. |
| `cert-manager.io/cluster-issuer` annotation | Tells cert-manager which issuer to use for the Ingress host |
| TLS secret name | cert-manager stores the signed cert in a K8s Secret — ALB or nginx-ingress mounts it |
| Ingress IP vs hostname | ALB gives a hostname (not an IP). DNS must CNAME to it, not A-record. |

### Questions

**[G] What does the AWS Load Balancer Controller do and why do you need it?**
ALB Controller is a Kubernetes controller that watches Ingress objects and Service objects with `type: LoadBalancer`. When it sees one, it calls AWS APIs to create a real ALB or NLB. Without it, an Ingress object sits in K8s with no effect — nothing creates the load balancer. The built-in Kubernetes cloud-controller-manager creates classic ELBs (legacy), not ALBs. ALB Controller creates modern ALBs with path-based routing, target groups per pod (not per node), WAF integration, and native TLS termination via ACM.

**[G] ALB vs NLB — how do you decide?**
ALB (Layer 7): HTTP/HTTPS, path-based routing (`/api` → service-a, `/frontend` → service-b), host-based routing, WebSocket support, WAF integration. Use for web traffic. NLB (Layer 4): pure TCP/UDP, no routing logic, lower latency, handles millions of requests per second, preserves client IP. Use for: gRPC, databases, anything non-HTTP, or when you need the lowest possible latency. In our project: nginx-ingress uses NLB (deployed as `type: LoadBalancer` Service) because nginx itself does the L7 routing — the NLB just TCP-forwards to nginx pods.

**[G] cert-manager vs ACM + ALB annotation — when do you use each?**
ACM + ALB: provision a cert in AWS Certificate Manager → add `alb.ingress.kubernetes.io/certificate-arn` annotation to the Ingress → ALB terminates TLS. Cert renewal is handled by ACM (fully automatic). Simple, no cert-manager needed. Best for: services that always go through an ALB, internal AWS-only setup. cert-manager: manages certs as K8s Secrets. The cert lives in the cluster. Nginx or any ingress controller can mount it — not just ALB. Best for: nginx-ingress (which terminates TLS inside the cluster), multi-cloud setups, or when you need the cert inside the pod (mTLS between services).

**[G] How does cert-manager issue a Let's Encrypt certificate?**
Flow: (1) You annotate an Ingress with `cert-manager.io/cluster-issuer: letsencrypt-prod`. (2) cert-manager sees the annotation → creates a `Certificate` object → creates an `Order` with Let's Encrypt ACME server. (3) Let's Encrypt issues an HTTP-01 challenge: "serve this token at `http://<your-domain>/.well-known/acme-challenge/<token>`". (4) cert-manager creates a temporary Ingress rule and a pod to serve the token. (5) Let's Encrypt hits the URL → token matches → domain ownership confirmed. (6) cert-manager receives the signed cert → stores it in a K8s Secret. (7) Ingress controller (ALB/nginx) mounts the Secret → serves HTTPS. cert-manager renews 30 days before expiry automatically.

**[S] Your site suddenly serves an expired TLS cert. `kubectl describe certificate` shows `Reason: Failed`. What do you check?**
In order: (1) `kubectl describe certificaterequest` — look at the failure reason. (2) HTTP-01 challenge failure — the ACME challenge URL wasn't reachable. Check if the Ingress is correctly routing `/.well-known/acme-challenge/*` to cert-manager's temporary pod. If your Ingress has `ssl-redirect: "true"`, it may be redirecting the HTTP challenge to HTTPS before the cert exists — cert-manager can't answer the challenge. Fix: add an exception for the challenge path. (3) Rate limit — Let's Encrypt has a limit of 50 certs per domain per week. Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`. (4) Staging vs production issuer — Let's Encrypt staging issues untrusted certs (browsers reject them). If you see "Fake LE Intermediate X1" in the cert chain, you're hitting the staging issuer by mistake.

**[S] Walk me through how HTTPS works end-to-end in your project.**
Request path: Browser → ALB (port 443, TLS termination using ACM cert) → nginx-ingress pods (port 80, plain HTTP inside the cluster) → product-category or order-service pod. Two TLS options we considered: (1) ACM + ALB: cert lives in ACM, ALB terminates it. Zero cert management, but only works if ALB is the entry point. (2) nginx-ingress + cert-manager: cert is a K8s Secret, nginx mounts it. Works even with a single NLB in front of nginx. We use option 1 for simplicity — ACM auto-renews, no cert-manager deployment needed. The ALB is provisioned by ALB Controller via the Ingress annotation `alb.ingress.kubernetes.io/certificate-arn`. Traffic inside the cluster is HTTP — east-west encryption is handled by NetworkPolicy micro-segmentation (not mTLS) at this stage.

**[G] Why does your Ingress get a hostname instead of an IP address from the ALB?**
ALBs are multi-AZ — they have multiple IP addresses that change over time as AWS adds or removes capacity. AWS exposes them via a DNS hostname (e.g. `k8s-ecom-ingress-abc123.us-east-2.elb.amazonaws.com`) that always resolves to the current set of IPs. If you tried to create an A record pointing at a specific ALB IP, it would break when AWS rotates it. Your DNS must use a CNAME pointing to the ALB hostname (or an Alias record in Route 53, which is a CNAME equivalent with no extra TTL hop). `kubectl get ingress -n ecom` shows the ADDRESS field — that's the hostname, not an IP.
