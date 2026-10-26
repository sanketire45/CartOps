# 06 — GitOps & ArgoCD

> Tags: **[G]** conceptual · **[S]** scenario
> Project: ArgoCD watching helm/ecom/, app-of-apps pattern, sync waves,
> ArgoCD detects any file change in the Helm chart directory

---

## 1. GitOps fundamentals

> What GitOps is, Git as single source of truth, declarative vs imperative,
> pull-based vs push-based CD, why GitOps over `kubectl apply` in CI.

<!-- ADD QUESTIONS HERE -->

---

## 2. ArgoCD architecture

> Application CRD, App controller, repo server, API server,
> how ArgoCD watches Git (polling interval or webhook),
> what triggers a sync (git diff detected).

**[G] How does ArgoCD detect changes — do you have to update values.yaml?**
ArgoCD watches the entire `path: helm/ecom` directory. Any file change in that path — templates, values, Chart.yaml, even a comment — triggers ArgoCD to re-render the Helm chart and diff the output against the live cluster state. So adding a new template (like `network-policy.yaml`) automatically gets picked up on the next sync cycle without touching values.yaml. The watch is directory-level, not file-level.

<!-- ADD MORE -->

---

## 3. Sync strategies

> Manual vs automatic sync, self-heal, prune,
> sync waves and hooks for ordered deployment,
> app-of-apps pattern for managing multiple applications.

<!-- ADD QUESTIONS HERE -->

---

## 4. ArgoCD vs Flux

> Both are GitOps tools. ArgoCD: UI-first, Application CRD, Helm-native.
> Flux: CLI-first, Kustomization CRD, more K8s-native.
> When to use which. Our project uses ArgoCD.

<!-- ADD QUESTIONS HERE -->

---

## 5. Handling drift

> What is drift (live cluster differs from Git), how ArgoCD detects it,
> OutOfSync status, auto-sync with self-heal to correct drift automatically,
> when NOT to auto-sync (breaking changes need human review).

<!-- ADD QUESTIONS HERE -->

---

## 6. ArgoCD + Helm

> How ArgoCD renders Helm charts, `valueFiles` in Application spec,
> ArgoCD does not run `helm install` — it renders templates and applies via kubectl,
> implication: Helm hooks don't run in ArgoCD by default.

<!-- ADD QUESTIONS HERE -->
