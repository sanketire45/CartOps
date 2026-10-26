# 🔐 Kubernetes Security — Answered Question Bank

> Every answer is defensible from what you actually built in the Ecommerce-Spring project.
> Voice: **problem → solution → trade-off → one concrete detail.**
> Tags: **[G]** general/conceptual · **[S]** scenario · **[TF]** Terraform-round.
>
> Project facts: cluster `ecom`, **us-east-2**, **K8s 1.34**, 2× `t3.medium` (launch template maxPods=110 + prefix delegation), default VPC across 3 AZs, ArgoCD GitOps, ESO + AWS Secrets Manager, Kyverno admission policies, NetworkPolicy default-deny, PSA restricted, scoped IRSA per workload.

---

## The one sentence that ties it all together

> "Security in Kubernetes is layered — secrets management at the data layer, IRSA for identity, securityContext for pod hardening, PSA and Kyverno at admission, NetworkPolicy for traffic control, and Falco for runtime detection. No single tool covers everything — each layer assumes the one below it has already failed."

---

## Layer 1 — Secrets Management

**[G] Why not store secrets in environment variables or ConfigMaps?**
Both are stored in etcd in plaintext and visible via `kubectl describe pod` to anyone with read access on the namespace. Environment variables also appear in process listings (`/proc/<pid>/environ`) — a container escape or noisy neighbour can read them. The correct pattern is AWS Secrets Manager as the single source of truth, with the External Secrets Operator pulling them into K8s Secrets at runtime. The K8s Secret is just a local cache — if deleted, ESO recreates it automatically on the next reconcile cycle.

**[G] What is the External Secrets Operator and how does it work?**
ESO is a controller that watches `ExternalSecret` CRDs. You define: which secret to fetch from Secrets Manager (`remoteRef.key`), which JSON field inside it (`remoteRef.property`), and what K8s Secret key to write it to (`secretKey`). ESO polls Secrets Manager on an interval (we use 1h) and keeps the K8s Secret in sync. The pod never talks to AWS — it reads the K8s Secret like any normal secret. Authentication to AWS happens via IRSA on ESO's own ServiceAccount.

**[S] Your pod was crashing with `CreateContainerConfigError`. How did you debug it?**
`kubectl describe pod mysql-0 -n ecom` showed the error: secret `mysql-secret` key `mysql-root-password` not found. ESO was writing the key as `mysql-root-password` but the pod's `secretKeyRef` was looking for key `password`. Fixed by changing `secretKey: mysql-root-password` → `secretKey: password` in `external-secret.yaml`, then force-syncing ESO immediately: `kubectl annotate externalsecret mysql-external-secret -n ecom force-sync=$(date +%s) --overwrite`. Lesson: the `secretKey` in ExternalSecret is the key name INSIDE the K8s Secret — it must exactly match what the pod reads via `secretKeyRef.key`.

**[TF] How is ESO installed in your Terraform?**
`helm_release.external_secrets` in `argocd.tf` — installs ESO via Helm with `serviceAccount.annotations.eks.amazonaws.com/role-arn` set to the IRSA role ARN from `secrets-manager.tf`. The IRSA role has a policy allowing `secretsmanager:GetSecretValue` only on the `ecom/*` path — not the whole account.

---

## Layer 2 — Identity (IRSA)

**[G] What is IRSA and why does it exist?**
IRSA — IAM Roles for Service Accounts. It lets a pod assume an IAM role without any static credentials. The mechanism: K8s issues a signed JWT to the pod's ServiceAccount, the OIDC provider (registered in IAM) validates that JWT, AWS STS returns short-lived credentials. No access keys in environment variables, no shared node-level role, no credential rotation needed. Credentials expire automatically.

**[G] Why scope one IAM role per workload instead of one shared role?**
Blast radius. If `order-service` is compromised via a dependency vulnerability, it should only reach SQS — not S3, not Secrets Manager, not RDS. Shared roles mean one compromise = full AWS access. In our project: ESO has a role scoped to `secretsmanager:GetSecretValue` on `ecom/*`, order-service has SQS permissions, product-category has S3 permissions. Each role trusts only its own ServiceAccount via the OIDC condition `sub: system:serviceaccount:ecom:order-sa`.

**[G] What is OIDC and why does EKS need it for IRSA?**
OIDC is the trust bridge between Kubernetes and AWS IAM. K8s issues ServiceAccount tokens (JWTs) signed with its own key. Without OIDC, AWS IAM has no way to verify those tokens. The OIDC provider — registered via `aws_iam_openid_connect_provider` in Terraform — tells AWS: "trust tokens signed by this K8s cluster." That's what allows `sts:AssumeRoleWithWebIdentity` to work.

**[S] A pod keeps getting `AccessDenied` from AWS even though IRSA is configured. Where do you look?**
1. `kubectl get sa <name> -n ecom -o yaml` — is the `eks.amazonaws.com/role-arn` annotation present?
2. `kubectl describe pod <name>` — is `AWS_WEB_IDENTITY_TOKEN_FILE` injected as an env var? (IRSA mutating webhook injects it — if missing, the pod can't authenticate)
3. IAM role trust policy — does the OIDC condition match exactly: correct OIDC URL, correct `sub` value (`system:serviceaccount:<namespace>:<sa-name>`)?
4. IAM permissions policy — does the role actually allow the specific action on the specific resource?

**[TF] How is IRSA wired in Terraform?**
Three parts: (1) `aws_iam_openid_connect_provider` in `oidc.tf` — registers the cluster's OIDC issuer URL with IAM. (2) IAM role with a trust policy that uses `sts:AssumeRoleWithWebIdentity` with two conditions: `StringEquals` on `:sub` (the ServiceAccount) and `:aud` (sts.amazonaws.com). (3) The Helm chart or `helm_release` annotates the ServiceAccount with that role ARN. The three pieces must match exactly — wrong namespace, wrong SA name = `AccessDenied`.

---

## Layer 3 — Pod Hardening (securityContext)

**[G] What is a securityContext and what fields matter most?**
Settings that control Linux-level privileges for a pod or container. Key fields: `runAsNonRoot: true` (fail if image tries to run as UID 0), `runAsUser: 999` (specific UID), `allowPrivilegeEscalation: false` (child processes can't gain more privileges than parent), `capabilities: drop: [ALL]` (remove all Linux capabilities), `seccompProfile: RuntimeDefault` (filter dangerous syscalls), `readOnlyRootFilesystem: true` (prevent writing to container filesystem). We apply all of these to every container in the ecom namespace.

**[G] What are Linux capabilities?**
Fine-grained root powers. Root is monolithic — but Linux splits it into ~40 capabilities: `NET_ADMIN` (configure networking), `SYS_PTRACE` (attach to processes), `NET_BIND_SERVICE` (bind to ports below 1024), etc. By default containers get ~14 capabilities. `drop: ALL` removes every one — the container behaves like an unprivileged user. If the app genuinely needs one (e.g. `NET_BIND_SERVICE` to listen on port 80), you add just that back.

**[G] What is seccomp?**
Seccomp (secure computing mode) is a Linux kernel feature that filters which syscalls a process can make. `RuntimeDefault` uses containerd's default seccomp profile which blocks ~300 dangerous syscalls (e.g. `ptrace`, `reboot`, `mount`) while allowing everything a normal app needs. Prevents container escape via obscure kernel exploits. Required by the PSA `restricted` profile.

**[S] MySQL pod was crashing with `Permission denied` on `/var/lib/mysql` even with `runAsUser: 999`. Why?**
The EBS volume was previously owned by root (UID 0). When mysql runs as UID 999, it can't write to root-owned directories. Fix: add `fsGroup: 999` to the pod-level securityContext. `fsGroup` tells Kubernetes to `chown` all mounted volumes to that GID before the container starts — runs as a privileged init step before the app process launches. Also deleted the stale PVC to force a fresh volume initialization with correct ownership from the start.

---

## Layer 4 — Admission Control (Kyverno + PSA)

**[G] What is an admission controller?**
A gate in the K8s API server. Every create/update request passes through admission before being written to etcd. Two types: **validating** (allow/deny the request) and **mutating** (modify the resource before storing it). Examples: PSA is a built-in validating controller. Kyverno registers itself as an external webhook — both validating and mutating depending on the policy. If the webhook is down and `failurePolicy: Fail`, all resource creation in the cluster stops.

**[G] What is Pod Security Admission (PSA)?**
PSA is built directly into the K8s API server (GA since 1.25). It enforces security profiles on pods at the namespace level using labels. Three profiles: `privileged` (no restrictions), `baseline` (blocks hostNetwork/hostPID/privileged containers), `restricted` (strongest — requires non-root, drop ALL caps, seccomp). Three modes: `enforce` (reject), `warn` (allow but warn), `audit` (allow but log). We label the ecom namespace with all three set to `restricted` — any non-compliant pod is rejected before it starts.

**[G] PSA vs Kyverno vs OPA — when do you use each?**
PSA — built-in, zero overhead, only covers pod security profiles. Can't customise beyond the 3 fixed profiles. Kyverno — custom policies on any K8s resource (not just pods), YAML-based rules, can mutate resources. OPA/Gatekeeper — same purpose as Kyverno but uses Rego language — more powerful, steeper learning curve. In production you use both: PSA for the security floor (non-root, no privileged), Kyverno for org-specific rules (image registry, resource limits, required labels).

**[G] What Kyverno policies did you implement?**
Two ClusterPolicies: (1) `require-resource-limits` — every container must declare CPU and memory limits; without limits a noisy pod can starve the whole node. Currently in `Audit` mode — logs violations, doesn't block yet. Will flip to `Enforce` after all deployments have limits added. (2) `deny-latest-tag` — blocks images tagged `:latest` because it's non-deterministic; forces explicit image SHAs or version tags for reproducible deployments.

**[S] A developer's deployment was rejected and they don't know why. How do you debug?**
```bash
kubectl describe replicaset <name> -n ecom   # shows the admission rejection message
kubectl get events -n ecom --sort-by='.lastTimestamp'   # Kyverno/PSA events appear here
```
PSA gives a clear message with the profile violation. Kyverno includes the policy name, rule name, and the exact field that failed. The error message is always in the ReplicaSet events — not on the Deployment itself, because Deployment creates ReplicaSet which creates Pods — the rejection happens at the Pod level.

---

## Layer 5 — NetworkPolicy

**[G] What is a NetworkPolicy and why does default-deny matter?**
NetworkPolicy is a K8s resource that controls pod-to-pod traffic at the IP/port level. Without it, every pod can reach every other pod — a compromised frontend can talk directly to MySQL on port 3306. Default-deny means: create one NetworkPolicy with empty `podSelector: {}` and `policyTypes: [Ingress]` — this drops all ingress to all pods in the namespace. Then add explicit allow rules for each permitted path. Zero-trust inside the cluster.

**[G] How does NetworkPolicy enforcement work on EKS?**
NetworkPolicy objects are accepted by the K8s API server regardless — but they do nothing without a CNI that enforces them. On EKS with VPC CNI you must set `enableNetworkPolicy: "true"` in the VPC CNI addon configuration. Without that flag, every `kubectl apply -f network-policy.yaml` succeeds silently but traffic is never blocked. We set this in `addons.tf` via `configuration_values = jsonencode({ enableNetworkPolicy = "true" })`.

**[G] Walk me through your NetworkPolicy setup.**
Six policies in `helm/ecom/templates/network-policy.yaml`:
1. `default-deny-ingress` — drops all ingress to all pods in ecom namespace
2. `allow-ingress-to-frontend` — allows ingress-nginx namespace → frontend:80
3. `allow-frontend-to-product` — allows frontend → product-category:8080
4. `allow-frontend-to-order` — allows frontend → order-service:7878
5. `allow-services-to-mysql` — allows product-category and order-service → mysql:3306
6. `allow-all-to-eureka` — allows all pods → eureka:8761 (service discovery)

All ports reference Helm values (`{{ .Values.*.port }}`), never hardcoded.

**[S] NetworkPolicy is applied but order-service still can't reach product-category. It times out instead of getting refused. Why?**
Timeout (not refused) means the packets are being dropped silently — which is exactly what NetworkPolicy does. The policy was missing an allow rule for `order-service → product-category`. Kyverno and PSA give error messages. NetworkPolicy gives silence — the connection just hangs until the TCP timeout. Debug: `kubectl exec -n ecom order-pod -- curl -v product-svc:8080` — if it hangs without a response, it's a NetworkPolicy drop. Check `kubectl describe networkpolicy -n ecom` to see exactly which pods are selected by each policy.

**[TF] Why does VPC CNI `enableNetworkPolicy` live in Terraform and not in the Helm chart?**
VPC CNI is an EKS managed addon — not a Helm release. It's configured via `aws_eks_addon` with `configuration_values`. The setting enables the VPC CNI agent to start its network policy controller DaemonSet. This is cluster-level infrastructure, not application config — belongs in Terraform alongside the addon definition.

---

## Layer 6 — Runtime Security (Falco)

**[G] What is Falco and how does it work?**
Falco is a runtime threat detection engine. It runs as a DaemonSet — one pod per node — and uses an eBPF probe to hook into every syscall on that node. Every `open()`, `exec()`, `connect()` from any process (pods, system daemons, everything) passes through the eBPF probe. Falco checks against its rules and alerts on suspicious behaviour: shell spawned inside a container, read of `/etc/shadow`, unexpected outbound connection. eBPF is read-only — Falco observes, never intercepts.

**[G] What's the difference between Falco and admission controllers?**
Admission controllers check the YAML at deploy time — they can't see what happens inside a running container. Falco watches live process behaviour. If an attacker uses `kubectl exec` to get into your mysql pod and runs `cat /etc/passwd`, Falco catches it — Kyverno never knew because it only checked the Deployment manifest at apply time. You need both: admission for preventive control, Falco for detective control.

**[G] Falco vs observability tools (Prometheus/Grafana) — what's the difference?**
Same deployment pattern (DaemonSet), completely different purpose. Observability (node-exporter, Fluent Bit) watches performance and health — CPU, memory, error rates. Falco watches behaviour and threats — what processes are doing. Observability answers "is my app healthy?" Falco answers "is anyone attacking my app?" Analogy: node-exporter is a health monitor (heart rate), Falco is a security camera (behaviour).

---

## RBAC

**[G] How does Kubernetes RBAC work? Is there a DENY verb?**
RBAC is **purely additive** — there is no DENY verb. Default state is everything denied. You create Roles (what actions are allowed on what resources) and RoleBindings (which user/ServiceAccount gets that Role). A user's effective permissions are the union of all their bound roles. You cannot give someone a role and then "take back" a specific permission with another rule. If you need deny-on-top-of-allow, you need Kyverno or OPA to enforce it — RBAC alone can't do it.

**[G] `kubectl auth can-i delete pods` returns `no`. Does that mean there's a DENY rule?**
No. "No" means there is no ALLOW rule for that action — it's not the same as an explicit deny. This distinction matters when debugging access issues: you're not looking for a DENY to remove, you're looking for a missing ALLOW to add. Use `kubectl auth can-i --list --as=<user>` to see what a user CAN do, which is more useful than checking individual permissions.

**[G] ClusterRole vs Role — when to use each?**
`Role` is namespace-scoped — grants permissions within one namespace. `ClusterRole` is cluster-scoped — grants permissions across all namespaces (or on cluster-level resources like nodes, PersistentVolumes, StorageClasses). Use Role for application-level permissions (a service account reading ConfigMaps in its own namespace). Use ClusterRole for infra tooling (ArgoCD needs to watch all namespaces, ESO needs ClusterSecretStore).

---

## The Layered Defence Answer (say this when asked "how do you secure a K8s cluster")

```
Layer 1 — Secrets:    No hardcoded secrets. ESO + AWS Secrets Manager. K8s Secret is a local cache.
Layer 2 — Identity:   Scoped IRSA per workload. Each pod assumes only the role it needs. OIDC trust bridge.
Layer 3 — Hardening:  runAsNonRoot, drop ALL caps, seccompProfile RuntimeDefault, allowPrivilegeEscalation=false.
Layer 4 — Admission:  PSA restricted label on namespace (built-in, zero overhead). Kyverno for custom rules.
Layer 5 — Network:    Default-deny NetworkPolicy. Explicit allow-list. VPC CNI enforcement enabled.
Layer 6 — Runtime:    Falco DaemonSet watching syscalls via eBPF. Detects post-deploy threats.
```

Each layer assumes the one below it has already failed. That's defence in depth.
