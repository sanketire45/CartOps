# 🎤 EKS + Terraform — Answered Question Bank (from the Wanderlust project)

> Every answer is defensible from what you actually built. Voice: **problem → solution → trade-off → one concrete detail.**
> Tags: **[G]** general/conceptual · **[S]** scenario · **[TF]** Terraform-round.
> Project facts to anchor answers: cluster `wanderlust`, **us-east-2**, **K8s 1.34**, 2× `c7i-flex.large` (2 vCPU/4 GB), default VPC across 3 AZs, NGINX ingress behind an internet-facing **NLB**, ClusterIP services (`/`→frontend:5173, `/api`→backend:8080), Jenkins CI (Trivy/OWASP/Sonar gate → Docker → DockerHub), CD bumps image tag → **ArgoCD** syncs, **IRSA** for the AWS LB Controller.

---

# 🟦 EKS / KUBERNETES

## 1. EKS cluster & architecture

**[G] What is EKS, and what does AWS manage vs you?**
EKS is AWS's managed Kubernetes. AWS runs and hides the **control plane** — API server, etcd, scheduler, controller-manager — across AZs, patches it, and charges a flat hourly fee. **I own the worker nodes and everything on them**: node groups, workloads, networking add-ons, scaling, observability. So I never SSH into a master; I interact through the API endpoint. In my project Terraform created the cluster (`aws_eks_cluster`) and a managed node group (`aws_eks_node_group`) — the brain and the muscle.

**[G] Control plane components — which run where on EKS?**
API server (front door), etcd (state store), scheduler (places pods), controller-manager (reconciliation loops), cloud-controller-manager — **all managed by AWS**, invisible to me. On each worker node I own: kubelet, kube-proxy, and the container runtime (containerd). The split matters because control-plane troubleshooting (etcd, static pods) is a self-managed/CKA skill; on EKS I focus on the node-and-workload layer.

**[G] Managed node group vs self-managed vs Fargate — which and why?**
I used a **managed node group** — AWS handles the EC2 lifecycle, AMI patching, and draining on upgrade, but I still get real nodes (so DaemonSets run, and I can use Spot/Graviton). Self-managed means I own the ASG and AMIs (more control, more toil). Fargate is serverless pods — no nodes to manage, pay-per-pod — great for spiky/isolated workloads but no DaemonSets and pricier at steady scale. For a cluster I create/destroy daily, managed node groups were the simplest right answer.

**[G] Why does EKS need subnets in 2+ AZs?**
The control plane is spread across AZs for HA, and it places cross-AZ ENIs — so EKS requires subnets in at least two AZs. My cluster used the default VPC's three subnets across us-east-2 a/b/c. This is also why single-AZ EBS volumes are a scheduling trap: a pod can reschedule to an AZ where its volume doesn't exist.

**[S] Cluster took ~9 min, nodes another ~2 — why two phases?**
Terraform builds the **control plane first** (`aws_eks_cluster`, ~8–9 min because AWS provisions the managed HA control plane), then the **node group** joins (~1–2 min to launch EC2 and register with the API). They're ordered automatically because the node group references the cluster name. A brain with no nodes can schedule nothing — that's why there are two resources.

**[S] `kubectl` says "no such host" after recreating the cluster — why?**
Each new cluster gets a **brand-new API server endpoint** (and OIDC ID). My kubeconfig still pointed at yesterday's destroyed cluster, which no longer resolves in DNS → "no such host." Fix: `aws eks update-kubeconfig --region us-east-2 --name wanderlust` to repoint. I hit this exact thing after a destroy/apply cycle.

**[G] What is `endpoint_public_access`? Harden it how?**
It makes the cluster's Kubernetes API reachable from the internet, so my laptop's `kubectl` (and `port-forward`) work. It lives in `eks.tf` under the cluster's `vpc_config`. For a short-lived learning cluster, public is fine. In prod I'd set `public_access_cidrs` to the office/VPN range, or go `endpoint_private_access = true` and reach it via a bastion/VPN — don't leave the API open to the whole internet.

---

## 2. IAM, IRSA & OIDC

**[G] How does a *pod* get AWS permissions on EKS?**
Through **IRSA — IAM Roles for Service Accounts**. You bind a scoped IAM role to a Kubernetes ServiceAccount; pods using that SA get temporary AWS credentials via a projected OIDC token. **Not** the node role — that would give the permission to every pod on the node. In my project the AWS Load Balancer Controller pod uses IRSA (`wanderlust-aws-lbc-irsa`) so only it can create load balancers.

**[G] Walk me through IRSA end-to-end.**
Four pieces: (1) the cluster has an **OIDC provider** registered in IAM — the trust anchor. (2) An IAM role whose **trust policy** allows `sts:AssumeRoleWithWebIdentity` from that OIDC provider, *conditioned* on a specific `namespace:serviceaccount` (`:sub`) and audience `sts.amazonaws.com` (`:aud`). (3) The ServiceAccount is annotated `eks.amazonaws.com/role-arn: <role>`. (4) At runtime, EKS projects a signed token into the pod; the AWS SDK exchanges it with STS for temporary creds scoped to that role. So identity flows pod → SA → OIDC token → STS → IAM role.

**[G] IRSA vs the node instance role — why not the node role?**
The node role is attached to the EC2 instance, so **every pod scheduled on that node inherits it** — a frontend pod could suddenly create load balancers. IRSA scopes permissions to **one pod's ServiceAccount** = least privilege, and credentials are short-lived STS tokens, not static node creds. Blast radius is the whole argument.

**[G] What's the OIDC provider's job?**
It's the **trust anchor**. EKS exposes an OIDC issuer URL; registering it in IAM as an OIDC provider lets IAM trust tokens signed by the cluster. Without it, STS has no reason to believe a pod's token — `AssumeRoleWithWebIdentity` would fail. In Terraform I created it from the cluster's issuer + its TLS thumbprint (`tls_certificate` data + `aws_iam_openid_connect_provider`).

**[S] LB controller gets `AccessDenied` even though the role exists — debug it.**
Two-sided check. **AWS side:** does the role's trust policy federate the OIDC provider and pin the exact `system:serviceaccount:kube-system:aws-load-balancer-controller` in the `:sub` condition? **K8s side:** `kubectl get sa aws-load-balancer-controller -n kube-system -o yaml | grep role-arn` — does the SA annotation point at *that* role? The #1 bug is a mismatch: the SA names one role, but the role trusts a different SA. Both "exist" yet it's denied.

**[S] Backend pod needs to read S3/SQS — grant it least-privilege.**
Create a dedicated IAM role with only `s3:GetObject`/`sqs:ReceiveMessage` on the specific ARNs, a trust policy for the OIDC provider scoped to the backend's `namespace:serviceaccount`, annotate the backend SA with that role ARN. Never add it to the node role (leaks to all pods) and never bake static keys into the image. This is exactly the IRSA pattern I used for the LB controller, reused per workload.

**[G] IAM vs RBAC?**
IAM governs **AWS** permissions (can this identity call EC2/S3?). RBAC governs **Kubernetes API** permissions (can this subject list pods?). They're separate planes — a ServiceAccount can carry an IAM role (via IRSA) *and* a K8s Role. "Who can reach the EKS API at all" is IAM (`aws-auth`/Access Entries); "what they can do once in" is RBAC.

---

## 3. Networking — Services, Ingress, Load Balancing

**[G] Service types and when to use each?**
**ClusterIP** — internal virtual IP, the default (my frontend/backend services). **NodePort** — opens a port on every node (crude external access). **LoadBalancer** — provisions one cloud LB per service (expensive at scale). I use ClusterIP internally and let the Ingress expose things, so I don't pay for an LB per service.

**[G] Service vs Ingress?**
A Service is **L4** — port-level routing to pods. An Ingress is **L7** — one shared load balancer routes by host/path to many services, with TLS in one place. Ten `type: LoadBalancer` services = ten LBs = ten bills; one Ingress + controller = one LB for all of them. My NGINX ingress routes `/`→frontend and `/api`→backend behind a single NLB.

**[G] port vs targetPort vs nodePort vs containerPort?**
`containerPort` — the port the app listens on in the pod (backend 8080). `targetPort` — where the Service forwards to (matches containerPort). `port` — the Service's own virtual-IP port other pods call. `nodePort` — (NodePort type only) the port opened on every node. The Service maps `port → targetPort`; I removed nodePorts when I switched to ClusterIP + Ingress.

**[G] How does traffic get from a Service to a pod?**
The Service is a virtual IP. **kube-proxy** on each node programs iptables/IPVS rules that DNAT the ClusterIP to a real **ready** pod IP, load-balancing across them. The **EndpointSlice** controller keeps the pod-IP list fresh based on readiness, so an unready pod is excluded. kube-proxy runs as a DaemonSet — one per node.

**[G] What does the AWS Load Balancer Controller do, and why IRSA?**
It's a controller pod that watches Service/Ingress objects and **calls AWS APIs to create NLBs/ALBs**, target groups, and listeners. Because it calls AWS, it needs AWS permissions — granted keyless via **IRSA**, scoped to just that pod. In my setup it saw NGINX's `type: LoadBalancer` service (with NLB annotations) and provisioned the internet-facing NLB.

**[G] NGINX controller vs AWS LB Controller — how together?**
They're complementary. The **AWS LB Controller** created the **NLB** (the AWS-level front door). The **NGINX ingress controller** is an in-cluster pod that reads my Ingress rules and **path-routes** HTTP to the right ClusterIP service. So: internet → NLB → NGINX pod → service → pod. The LB controller does L4 provisioning; NGINX does L7 routing.

**[S] Walk me through a user request to the app.**
Browser resolves the NLB hostname → hits the **internet-facing NLB** → forwards to an **NGINX ingress pod** → NGINX matches the path (`/api`→backend-service, `/`→frontend-service) → the **ClusterIP** service → **kube-proxy** DNATs to a ready pod. Two load-balancing layers: the NLB spreads across NGINX pods, kube-proxy spreads across app pods. The control plane is never in the data path.

**[S] You switched the frontend to call `/api` instead of a hardcoded backend IP — why better?**
The old way baked a node IP into the frontend build — brittle, broke on redeploy, and forced CORS. With a **relative `/api`**, the browser calls the same origin it's already on, and the Ingress routes `/api` to the backend. No hardcoded host, no CORS, and the same image works in any environment. That was my "Plan B" production enhancement over the tutorial's NodePort+baked-IP approach.

**[S] Why did EXTERNAL-IP show a DNS name, not an IP?**
AWS load balancers are given a **hostname**, not a fixed IP, because they're backed by multiple nodes across AZs whose IPs can change and scale. So the Service's `EXTERNAL-IP` is the NLB's DNS name, and you'd CNAME your real domain to it — never to an IP.

**[G] ALB `target-type: ip` vs `instance`?**
`instance` routes to a NodePort on the node, adding a hop and relying on kube-proxy. `ip` registers **pod IPs directly** in the target group, so the ALB hits pods straight — lower latency and cleaner health checks. It's the standard choice on EKS with the VPC CNI (pods already have real VPC IPs).

---

## 4. GitOps / ArgoCD / CD

**[G] What is GitOps? Push vs pull?**
GitOps makes **Git the single source of truth** for the cluster. In the **push** model, CI runs `kubectl apply` with cluster creds (big attack surface). In the **pull** model, an in-cluster agent (ArgoCD) watches Git and reconciles the cluster to match — so CI only needs Git push rights, never a kubeconfig. My pipeline is pull-based: CD edits the image tag in Git, ArgoCD pulls and deploys.

**[G] How does ArgoCD know what to deploy?**
Via an **Application** object (a CRD) that points at a repo, path, target cluster, and namespace. It's not automatic — until that object exists, ArgoCD watches nothing. Mine points at the `kubernetes/` folder of the repo and syncs into the `wanderlust` namespace.

**[S] You installed ArgoCD via Terraform but it deployed nothing — why?**
Terraform's `helm_release` installs the **ArgoCD controller**, but the **Application** object (which tells it what to watch) couldn't go in Terraform — its CRD doesn't exist at plan time ("chicken can't lay an egg before the chicken exists"). So it's a two-phase bootstrap: Terraform installs the engine, then `kubectl apply -f argocd-app.yaml` seeds the first Application. I proved it was watching nothing with `kubectl get applications -n argocd` → "No resources found."

**[S] "When CI finishes, how does the right ArgoCD get the change?"**
It doesn't get *pushed* anything. CI/CD only pushes a manifest change to **Git**. ArgoCD **pulls** — it continuously watches the repo its Application names, sees the new image tag, and syncs. Git connects them passively, like a noticeboard: the CD pipeline pins a note, ArgoCD reads it. That's why the pipeline has no cluster credentials.

**[G] What do `selfHeal` and `prune` do?**
`selfHeal` reverts manual drift — if someone `kubectl edit`s a managed resource, ArgoCD puts it back to match Git. `prune` deletes resources that were removed from Git. Together they guarantee the cluster equals Git, nothing more, nothing less.

**[S] Someone `kubectl edit`s a Deployment ArgoCD manages — what happens?**
With `selfHeal: true`, ArgoCD detects the drift and reverts it to the Git-defined state within its sync interval. The lesson: in GitOps you change things by committing to Git, not by editing the cluster — manual edits get undone.

**[G] Why the Application manifest vs clicking "New App" in the UI?**
The UI way stores the app definition only inside ArgoCD's database — invisible, not reviewable, lost if the cluster dies. The **declarative** manifest lives in Git: reviewable in a PR, version-controlled, reproducible. Rebuild the cluster → one `kubectl apply` and everything comes back. It's GitOps applied to ArgoCD itself.

---

## 5. CI / Docker / registry / security scanning

**[G] Walk me through your CI pipeline.**
Validate params → workspace cleanup → Git checkout → **Trivy** filesystem scan → **OWASP Dependency-Check** → **SonarQube** analysis → **SonarQube Quality Gate** (aborts on fail) → multi-stage **Docker build** (frontend+backend) → **push to Docker Hub** → on success, trigger the CD job. Security is shift-left: nothing builds an image until it passes the scans and the gate.

**[G] Trivy vs OWASP vs SonarQube — what does each catch?**
**Trivy** — vulnerabilities and secrets in the filesystem/image (OS + language packages). **OWASP Dependency-Check** — known CVEs in your third-party dependencies (software composition analysis). **SonarQube** — code smells, bugs, and security hotspots in *your* source (SAST). Three different layers: your deps, your image, your code.

**[G] What's a Quality Gate and why gate on it?**
A Quality Gate is a pass/fail threshold on SonarQube's findings (coverage, new bugs, vulnerabilities). Gating the pipeline on it means code that regresses quality **can't ship** — the build aborts. It's event-driven: SonarQube processes the report, then POSTs the result to Jenkins via a webhook; `waitForQualityGate` blocks until it arrives.

**[S] Pods are `ImagePullBackOff: repository does not exist` — debug it.**
`describe` the pod → read Events (no app logs yet). "repository does not exist" means the registry has nothing at that name/tag. I checked Docker Hub and the repo genuinely didn't exist — the **CI hadn't built/pushed** those images yet. It proved the GitOps loop worked (ArgoCD scheduled the pods) but the image artifact was missing. Fix: run CI to build+push, then the pods recover on their own (ImagePullBackOff auto-retries).

**[S] CI tags `v0.0.0` but manifests want `v2.1` — what breaks, whose job to fix?**
The pods ask the registry for a tag that doesn't exist → ImagePullBackOff. The fix isn't in Kubernetes — it's **tag sync**, which is the entire job of the **CD stage**: after CI pushes `…:v0.0.0`, CD rewrites the manifest's image tag to match and pushes to Git, and ArgoCD rolls the pods. Mismatched manifest-tag vs pushed-tag is the classic cause.

**[G] Why immutable git-SHA tags over `:latest`?**
`:latest` is mutable — you can't tell what's actually running, and nodes serve a stale cached layer. A **git-SHA tag** ties the running image to an exact commit (traceable, reproducible) and, with registry tag-immutability, can never be overwritten. Essential for rollbacks and audits.

**[G] Multi-stage Docker builds — why?**
Build in a fat image with compilers/dev deps, then copy only the runtime artifact into a small, hardened final image. Smaller images pull faster, have far less attack surface, and (with a non-root user + distroless base) a compromised container has almost nothing to exploit.

---

## 6. Node resources & scheduling

**[G] requests vs limits, and QoS classes?**
**Request** = reserved for scheduling (the scheduler guarantees it). **Limit** = hard cap at runtime. CPU over limit = throttled; **memory over limit = OOMKilled (137)**. If requests==limits for both → **Guaranteed**; some set → **Burstable**; none → **BestEffort** (evicted first under pressure).

**[G] Capacity vs Allocatable — why does a 4 GB node schedule only ~3 GB?**
**Capacity** is the node's total RAM; **Allocatable** is what's left for pods after the kubelet, OS, and eviction threshold take their reserve. On my `c7i-flex.large` (4 GB), Capacity was ~3.72 GiB and Allocatable ~3.07 GiB — ~674 MiB reserved. On a small node that reserve is a big chunk (~17%), which is one argument for fewer, bigger nodes.

**[G] What is OOMKilled and its exit code?**
When a container exceeds its memory limit, the kernel's OOM killer terminates it — exit code **137** (128 + SIGKILL), shown as `Reason: OOMKilled` in `describe`. It's instant SIGKILL, so graceful-shutdown hooks don't run.

**[S] A pod is OOMKilled — confirm and fix.**
`kubectl describe pod` → Last State shows `OOMKilled`, exit 137. Confirm real usage with `kubectl top` (needs metrics-server) or cgroup files to decide: **raise the limit** if it's legitimately needed, or **fix a leak** if memory climbs steadily. For a JVM, remember non-heap (metaspace/threads) needs headroom beyond the heap setting.

**[S] `kubectl top nodes` errors "Metrics API not available" — why?**
EKS doesn't ship **metrics-server** by default. `kubectl top` (and the HPA) read live CPU/RAM from metrics-server, which scrapes cAdvisor in each kubelet. No metrics-server = no `top` and no CPU-based autoscaling — so it's one of the first add-ons teams install. I confirmed node memory instead via `describe nodes` Capacity/Allocatable, which needs nothing.

---

## 7. Troubleshooting — the war stories (lead with these)

**[S] Tell me about a networking issue you debugged.**
My SonarQube scanner (on the same EC2 as Jenkins) timed out reaching SonarQube on `:9000` even though the security group was open — and from the public internet the port answered instantly. Root cause: **AWS NAT hairpinning** — an instance can't reach its own *public* IP; the packet heads to the IGW and never loops back. Key tell: **"connect timed out" = a dropped path (firewall/routing)**, vs "connection refused" = port reachable but nothing listening. Fix: address the co-located service over `localhost`/private IP, not the public IP. I hit the same bug again on the Sonar→Jenkins webhook — both because they used the shared host's public IP.

**[S] Build failed `permission denied /var/run/docker.sock` — cause & fix.**
The Jenkins user wasn't in the `docker` group, so it couldn't talk to the Docker daemon socket (owned `root:docker`). Fix: `sudo usermod -aG docker jenkins` then **restart Jenkins** (group membership is only read at process start). Caveat I'd mention: docker-group membership is effectively root on the host (you can mount the host FS into a container), so hardened setups use rootless Docker or Kaniko instead of the socket.

**[S] `COPY .env.docker` failed in the Docker build but works locally — why?**
The file existed on my laptop but was **gitignored**, so it never reached Jenkins' checkout → not in the build context → `COPY` failed. The backend worked because its `.env.docker` was force-committed. Since I'd already moved the frontend to a relative `/api` path, the env file was obsolete anyway — I removed the dead `COPY` line. Lesson: Docker builds only what's in the build context, and gitignore silently removes files from CI.

**[S] A webhook times out but the service is up — how do you reason about it?**
I separate "can't reach" from "reached, rejected." **Timeout** points at the *path* — firewall/security-group/routing/NAT — because packets are vanishing. **Connection refused** means the host is reachable but nothing's listening on that port. That distinction took me straight to the hairpin-NAT root cause on the Sonar→Jenkins callback instead of chasing the app.

---

# 🟪 TERRAFORM ROUND

> A Terraform round probes the **model** (config/state/reality), **data vs resource**, **dependencies**, **providers**, **state management**, **modules**, **drift**, and **secrets**. Anchor every answer in what you built.

**[G] Explain the Terraform workflow; what is `plan` doing?**
Terraform reconciles three things: your **config** (desired), the **state file** (what it thinks exists), and **reality** (what AWS actually has). `plan` refreshes reality, diffs it against config using state as the map, and shows the add/change/destroy set. `apply` executes it and updates state. It's declarative: I describe the end state, Terraform computes the steps.

**[G] What is the state file and why does it matter?**
State maps your config resources to real cloud resource IDs — it's how Terraform knows that `aws_eks_cluster.this` *is* cluster `wanderlust`. Without it, Terraform couldn't compute diffs or know what it owns. It can also hold sensitive values, which is why it must be protected.

**[S] State got deleted/recovered with a mismatch — what happens, how recover?**
I lived this: I recovered a `tfstate` that contained Jenkins resources my config no longer declared. The rule is **"in state but not in config → destroy"**, so the next `apply` would have **deleted my Jenkins box**. Fix: back up state, then `terraform state rm aws_instance.testinstance …` to **stop managing** those resources without destroying them — Terraform forgets them, the real resources stay. Plan then showed 0 to destroy.

**[G] "In state but not in config" — what does Terraform do?**
It plans to **destroy** it, because state represents what Terraform owns and config is the desired truth — anything owned but no longer desired gets removed. That's exactly why a recovered/stale state is dangerous, and why `state rm` (decouple) vs `destroy` (delete) is a critical distinction.

**[TF] How do you manage state in a team?**
A **remote backend** — S3 for the state object plus a **DynamoDB table for state locking** — so concurrent `apply`s can't corrupt it, and everyone shares one source of truth. Honest current state: mine is **local** (fine for a solo learning cluster), and moving it to S3+DynamoDB is my first hardening task. I'd also enable versioning on the bucket for recovery.

**[G] `terraform state rm` vs `terraform destroy`?**
`state rm` tells Terraform to **forget** a resource — it stays in AWS but is no longer managed. `destroy` **deletes** the real resource. I used `state rm` to cleanly decouple the Jenkins EC2 from this config without tearing it down.

**[G] `resource` vs `data` source?**
`resource` **creates and manages** something (Terraform owns its lifecycle). `data` **looks up** something that already exists, read-only. I used `data "aws_vpc"`/`data "aws_subnets"` to find the default VPC's networking rather than create a new VPC, and `data "aws_eks_cluster_auth"` to get a cluster token.

**[G] Implicit vs explicit dependencies; where did you need `depends_on`?**
Terraform infers **implicit** dependencies from references (the node group references `aws_eks_cluster.this.name`, so the cluster builds first). **`depends_on`** is for ordering Terraform *can't* see from references — I used it to ensure IAM policy attachments existed **before** the cluster, and the node group + IAM were ready **before** the Helm releases that run pods.

**[S] Why does Terraform build the cluster before the node group without you ordering it?**
Because the node group's config **references** `aws_eks_cluster.this.name` — that reference creates an implicit dependency, so Terraform builds the cluster first automatically. You only reach for `depends_on` when there's a real ordering need with no reference to express it.

**[G] What are providers? You used five — name them and why.**
Providers are plugins that talk to an API. I used **aws** (all AWS resources), **tls** (read the OIDC issuer's cert thumbprint), **kubernetes** (talk to the cluster), **helm** (install charts as `helm_release`), and **http** (fetch the LB-controller IAM policy JSON from a URL). Multiple providers let one config span AWS + the cluster + Helm.

**[G] How does the helm provider authenticate to a cluster that doesn't exist until apply?**
The kubernetes/helm providers are configured with the cluster's **endpoint**, **CA cert** (`base64decode` of `certificate_authority[0].data`), and a **token** from `data "aws_eks_cluster_auth"`. These resolve during apply *after* the cluster is created, so the provider can authenticate in the same run. It's the Terraform equivalent of `aws eks update-kubeconfig`.

**[TF] How did you build an IRSA role in Terraform?**
Five moving parts: `aws_iam_openid_connect_provider` (from the cluster issuer + `tls_certificate` thumbprint); a `data "aws_iam_policy_document"` **trust** policy with a `Federated` principal = the OIDC ARN and `StringEquals` conditions on `:sub` (the exact `namespace:serviceaccount`) and `:aud`; the `aws_iam_role` using that trust; the permissions policy (fetched via `data "http"` → `aws_iam_policy`) attached to the role; and the Helm `set` that annotates the ServiceAccount with the role ARN. That chain is IRSA expressed as code.

**[G] How do you express an IAM trust policy in TF?**
With `data "aws_iam_policy_document"` — `statement` blocks with `effect`, `actions` (`sts:AssumeRoleWithWebIdentity` for IRSA), `principals` (type `Federated`, the OIDC ARN), and `condition` blocks for the `:sub`/`:aud` match. It renders to JSON I pass to the role's `assume_role_policy`. It's more readable and composable than inline JSON.

**[S] You fetched the LB-controller IAM policy from a URL — how/why?**
`data "http"` pulls the upstream `iam_policy.json` the controller publishes, and I feed `response_body` straight into `aws_iam_policy`. Why: the policy is large and AWS maintains it — fetching keeps it current instead of me hand-copying hundreds of lines that could drift. Trade-off: it's a network dependency at plan time, so for stricter prod I might vendor a pinned copy.

**[G] What does `helm_release` do?**
It's `helm install`/`upgrade` managed by Terraform — Terraform tracks the release in state and reconciles it. I used it for ArgoCD, the AWS LB Controller, and NGINX, passing chart values via `set` blocks (e.g. the IRSA role-arn annotation, clusterName, vpcId).

**[S] Helm-into-a-fresh-cluster sometimes times out on first apply — why, what do you do?**
Right after the cluster/nodes come up there's eventual-consistency lag — the API or webhooks aren't fully ready, so a `helm_release` can time out. The fix is usually just **re-running `apply`** (it's idempotent and picks up where it left off). I sequence Helm releases with `depends_on` after the node group to minimize it.

**[TF] Would you pin chart versions?**
For prod, yes — pin the chart `version` so applies are reproducible and an upstream chart bump can't silently change behavior. I left versions floating for learning but flagged pinning (argo-cd, aws-load-balancer-controller, ingress-nginx) as a pre-prod step.

**[G] How do you parameterize per-environment?**
Input **variables** with per-env `tfvars` (region, cluster name, instance type, sizes). For the app layer, Helm `values-dev/prod`. So one codebase, different inputs per environment, no copy-paste.

**[G] What are outputs for?**
To surface useful values after apply — I output the cluster endpoint, OIDC provider ARN, and the exact `aws eks update-kubeconfig` command, so the next step (and other modules) can consume them without digging through the console.

**[TF] Your config is flat (no modules) — how would you refactor for scale?**
I'd extract **modules** by concern — a `cluster` module, an `iam/irsa` module, an `addons` module — with clear input/output interfaces, then compose them per environment. That gives reuse across dev/stage/prod and smaller blast radius per change. Combined with **remote state + locking**, that's the jump from a personal project to a team setup. (Honest known gap I'd call out myself.)

**[G] What is drift and how does Terraform detect it?**
Drift is when reality diverges from state — someone changes a resource by hand in the console. `terraform plan` refreshes real state and shows the diff; `apply` pulls it back to config. In a team you'd run `plan` in CI on a schedule/PR to catch drift early.

**[TF] How do you handle secrets in Terraform?**
Don't put real secrets in config or let them sit in state in cleartext. Mark variables `sensitive`, keep state in an encrypted remote backend, and source real secrets at **runtime** from AWS Secrets Manager via the External Secrets Operator (my planned fix) rather than materializing them through Terraform. Best of all is no static secret — e.g. IAM DB auth.

---

## How to drill
- **Lead scenario rounds with the war stories** (NAT hairpin, state-mismatch recovery, ImagePullBackOff, docker.sock) — they're real and senior-sounding.
- **Every answer ends with a trade-off or "what I'd improve"** — that's what separates mid from senior.
- When you hit something you haven't built (KEDA, Karpenter, remote state), say *"here's how it works and how I'd approach it"* — never bluff.
