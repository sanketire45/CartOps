# 06 — GitOps & ArgoCD

> Tags: **[G]** conceptual · **[S]** scenario · **[I]** incident
> Project: ArgoCD watching `helm/ecom/`, app-of-apps pattern, sync waves,
> manual bootstrap: `kubectl apply -f GitOps/apps/ecom-dev.yaml` after every terraform apply

---

## Sections
1. [GitOps Fundamentals](#1-gitops-fundamentals)
2. [ArgoCD Architecture](#2-argocd-architecture)
3. [Sync Strategies](#3-sync-strategies)
4. [Handling Drift](#4-handling-drift)
5. [ArgoCD + Helm](#5-argocd--helm)
6. [ArgoCD vs Flux](#6-argocd-vs-flux)

---

## 1. GitOps Fundamentals

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Git as source of truth | Desired cluster state lives in Git — not in Jenkins, not in someone's head |
| Declarative | Describe WHAT you want (Helm chart), not HOW to get there (kubectl commands) |
| Pull-based CD | ArgoCD pulls from Git and applies to cluster. Push-based = CI pushes to cluster. |
| Reconciliation loop | ArgoCD continuously compares Git state vs live state and corrects drift |
| Auditability | Every deploy = a Git commit. Author, timestamp, diff — complete audit trail. |

### Questions

**[G] What is GitOps and why is it better than `kubectl apply` from CI?**
GitOps: Git is the single source of truth for cluster state. A GitOps controller (ArgoCD) continuously reconciles the live cluster to match Git. Benefits over Jenkins `kubectl apply`: (1) Audit trail — every change is a Git commit with author and reason. (2) Rollback — `git revert` = rollback. (3) Drift correction — ArgoCD auto-fixes manual changes. (4) Multi-team — different teams own different apps in Git without direct cluster access. CI with `kubectl apply` is fire-and-forget — it deploys once, forgets, and never detects drift.

**[G] Pull-based vs push-based CD — what's the difference?**
Push-based (Jenkins → kubectl apply): CI has cluster credentials and pushes changes. Problem: you have to give CI broad cluster access, and CI doesn't monitor state after deploy. Pull-based (ArgoCD): the controller runs inside the cluster, pulls from Git, never needs CI to have cluster credentials. CI only needs to push to Git. The cluster itself decides when and how to update — more secure, self-healing, continuously monitored.

---

## 2. ArgoCD Architecture

### Cheat Sheet

| Component | Role |
|---|---|
| Application CRD | Defines: which Git repo, which path, which cluster, which namespace |
| App Controller | Watches Git + cluster, computes diff, triggers sync |
| Repo Server | Clones Git repo, renders Helm/Kustomize templates |
| API Server | gRPC/REST API — serves the UI and CLI |
| ApplicationSet | Generates multiple Applications from a template (one per environment, one per service) |

### Questions

**[G] How does ArgoCD detect changes — do you have to update values.yaml?**
ArgoCD watches the entire `path: helm/ecom` directory. Any file change in that directory — templates, values, Chart.yaml, even a comment — triggers ArgoCD to re-render the Helm chart and diff the output against the live cluster. Adding a new template (`network-policy.yaml`) gets picked up automatically on the next sync without touching values.yaml. The watch is directory-level, not file-level.

**[G] How does ArgoCD authenticate to Git?**
ArgoCD uses a repository credential — SSH key or HTTPS token stored in an ArgoCD Secret. When the repo server needs to render templates, it clones using that credential. In our project: GitHub repo with an ArgoCD deploy key (read-only SSH key). ArgoCD can only read from the repo — never write — which is the correct security posture.

**[S] ArgoCD shows "Unknown" status for an application. What does that mean?**
ArgoCD can't reach the Git repo or can't render the Helm chart. Check: (1) `argocd app get ecom-dev` — shows the error message. (2) Common causes: Git credentials expired or rotated, Helm chart rendering error (bad template syntax, missing value), network connectivity from ArgoCD namespace to GitHub. Fix the underlying cause and ArgoCD will re-evaluate automatically.

---

## 3. Sync Strategies

### Cheat Sheet

| Strategy | Behaviour |
|---|---|
| Manual sync | ArgoCD detects diff but waits for human to click Sync |
| Auto sync | ArgoCD syncs automatically on every Git change |
| Self-heal | Auto-corrects drift even without a Git change (someone ran `kubectl edit`) |
| Prune | Deletes resources in cluster that were removed from Git |
| Sync waves | `argocd.argoproj.io/sync-wave: "0"` — control apply order within one sync |
| App-of-apps | One ArgoCD Application that manages other Applications (bootstrap pattern) |

### Questions

**[G] What is an app-of-apps pattern?**
One "root" ArgoCD Application whose Git path contains other Application CRDs. When ArgoCD syncs the root app, it creates all the child Applications, which then each sync their own workloads. In our project: `GitOps/apps/ecom-dev.yaml` is the root app. It points to a directory of Application manifests — one for the ecom Helm chart, potentially one for monitoring, one for ingress. We bootstrap once with `kubectl apply -f GitOps/apps/ecom-dev.yaml` after every terraform apply — ArgoCD manages everything after that.

**[G] What are sync waves and when do you use them?**
Sync waves control the order resources are applied within one ArgoCD sync. Lower wave number = applied first. ArgoCD waits for wave N to be healthy before starting wave N+1. Use case: Namespace must exist before Deployments, CRDs must exist before CRs, database must be running before the app. We use sync wave 0 for infrastructure (namespace, RBAC), wave 1 for databases (MySQL), wave 2 for backend services, wave 3 for frontend.

**[S] Auto-sync is enabled but ArgoCD keeps re-syncing the same app every 3 minutes. Why?**
A resource in the cluster has a field that ArgoCD renders differently from what's live. Common causes: (1) A controller adds an annotation or label that's not in Git — ArgoCD sees it as drift and reverts it. Fix: add `ignoreDifferences` for that field. (2) A Helm template generates a timestamp or random value — different on every render. Fix: use a stable value or ignore that field. Endless re-sync is a sign of a normalization issue between the template and the live resource.

---

## 4. Handling Drift

### Cheat Sheet

| Scenario | ArgoCD Behaviour |
|---|---|
| Someone runs `kubectl edit deployment` | OutOfSync — ArgoCD detects diff on next poll (default 3 min) |
| Auto-sync + self-heal enabled | ArgoCD reverts the manual change automatically |
| Auto-sync without self-heal | ArgoCD only syncs on Git changes — manual edits stay |
| Resource deleted from Git | OutOfSync — only reverted if `prune: true` is set |

### Questions

**[G] What is "drift" in GitOps and how does ArgoCD handle it?**
Drift: the live cluster state differs from what Git declares. Causes: manual `kubectl edit`, a controller modifying a resource, a previous failed deploy. ArgoCD computes a diff between rendered Git manifests and live K8s objects every 3 minutes (configurable). When drift is detected: status → OutOfSync. With auto-sync + self-heal: ArgoCD applies the Git version and overwrites the drift. Without self-heal: it shows OutOfSync and waits for a manual sync trigger.

**[S] A developer manually scaled a Deployment from 2 to 5 replicas via kubectl. ArgoCD synced 5 minutes later and it went back to 2. Why did they lose their change?**
GitOps by design. `values.yaml` has `replicaCount: 2`. ArgoCD synced with self-heal enabled, saw the live count (5) differed from Git (2), and reverted. The correct approach: change `replicaCount` in Git → commit → ArgoCD deploys it. Manual kubectl changes are intentionally overwritten — that's what makes GitOps a reliable single source of truth. For dynamic scaling (HPA), the field must be excluded from ArgoCD's diff via `ignoreDifferences`.

---

## 5. ArgoCD + Helm

### Cheat Sheet

| Concept | Key Point |
|---|---|
| ArgoCD renders Helm, doesn't run it | Renders `helm template`, applies via kubectl — not `helm install` |
| No Helm hooks | Helm hooks don't fire in ArgoCD (pre-install, post-upgrade) — use sync hooks or init containers instead |
| valueFiles | Multiple values files — `values.yaml` (base) + `values-dev.yaml` (override) |
| `helm diff` plugin | ArgoCD UI shows rendered YAML diff — very useful for reviewing changes before sync |
| Chart version pinning | `targetRevision: 1.2.3` in Application spec — pin exact chart version |

### Questions

**[G] ArgoCD renders Helm but doesn't run `helm install`. What's the implication?**
Helm hooks (`pre-install`, `post-upgrade`, `pre-delete`) don't fire in ArgoCD — they're Helm-specific lifecycle events that only work when Helm manages the release. If you need ordered operations, use ArgoCD sync waves + sync hooks instead. Also: ArgoCD doesn't store a Helm release secret in the cluster — `helm list` won't show your ArgoCD-managed apps. You manage lifecycle through ArgoCD, not the `helm` CLI.

**[G] How do you manage dev vs prod configs in ArgoCD with Helm?**
Multiple Application CRDs pointing to the same Helm chart path but different `valueFiles`. Dev application uses `values.yaml` + `values-dev.yaml`. Prod application uses `values.yaml` + `values-prod.yaml`. The prod overlay has `replicaCount: 3`, different resource limits, prod ECR image tags. Same chart, environment-specific overrides. ArgoCD renders each independently. In our project: single `values.yaml` for now, `values-dev.yaml` for future multi-env separation.

---

## 6. ArgoCD vs Flux

### Cheat Sheet

| | ArgoCD | Flux |
|---|---|---|
| UI | Yes — rich web UI | No built-in UI |
| API | Application CRD | Kustomization / HelmRelease CRD |
| Helm support | Native | Via HelmRelease CRD |
| Multi-cluster | Yes — manage multiple clusters from one ArgoCD | Yes |
| Learning curve | Lower — UI helps | Higher — CLI-first |
| Community | Larger | Growing |

### Questions

**[G] ArgoCD vs Flux — when would you choose each?**
ArgoCD if: your team prefers a visual UI, you use Helm heavily, you want app-of-apps bootstrapping, or you need a strong RBAC model for multi-team access. Flux if: you prefer a more Kubernetes-native pure CRD approach, you use Kustomize heavily, or you want simpler operator model without the ArgoCD API server. Both are CNCF graduated projects. We chose ArgoCD for the UI visibility — especially useful while learning the GitOps model and debugging sync issues.
