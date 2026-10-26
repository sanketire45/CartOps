# 05 — CI/CD & Jenkins

> Tags: **[G]** conceptual · **[S]** scenario
> Project: Jenkins on EC2, multi-stage pipeline, Trivy + OWASP + SonarQube gates,
> Docker build → ECR push, git-SHA tags, ArgoCD for CD

---

## 1. CI/CD fundamentals

> CI vs CD vs CD (delivery vs deployment), why automate, pipeline stages,
> what "shift left" means in the context of testing and security.

<!-- ADD QUESTIONS HERE -->

---

## 2. Jenkins pipeline

> Declarative vs scripted pipeline, Jenkinsfile, stages and steps,
> agents and nodes, parallel stages, when/post blocks,
> stash/unstash for artifacts between stages.

<!-- ADD QUESTIONS HERE -->

---

## 3. Quality gates

> Trivy (image vulnerability scanning), OWASP dependency check,
> SonarQube (code quality + coverage), fail-fast on HIGH severity,
> why quality gates must block the pipeline not just warn.

<!-- ADD QUESTIONS HERE -->

---

## 4. Docker build in CI

> Docker-in-Docker vs bind mount /var/run/docker.sock (security risk),
> multi-stage build in CI, tagging strategy (git SHA + branch),
> ECR login via IRSA or IAM role on Jenkins EC2.

<!-- ADD QUESTIONS HERE -->

---

## 5. Secrets in CI

> Never hardcode credentials in Jenkinsfile, Jenkins credentials store,
> IAM role on Jenkins EC2 for ECR push (no static keys),
> difference between CI credentials and app runtime secrets.

<!-- ADD QUESTIONS HERE -->

---

## 6. CI/CD split — why separate CI from CD

> CI owns: build, test, scan, push image to ECR.
> CD owns: deploy to Kubernetes (ArgoCD GitOps pattern).
> Why separation: CD is declarative (desired state in Git), CI is imperative (run commands).
> Jenkins bumps image tag in Helm values → ArgoCD detects drift → syncs cluster.

<!-- ADD QUESTIONS HERE -->
