# 05 — CI/CD & Jenkins

> Tags: **[G]** conceptual · **[S]** scenario · **[I]** incident
> Project: Jenkins on EC2, matrix pipeline per service, Trivy + OWASP + SonarQube gates,
> Docker build → ECR push, git-SHA tags, ArgoCD for CD

---

## Sections
1. [CI/CD Fundamentals](#1-cicd-fundamentals)
2. [Jenkins Pipeline](#2-jenkins-pipeline)
3. [Quality Gates](#3-quality-gates)
4. [Docker Build in CI](#4-docker-build-in-ci)
5. [Secrets in CI](#5-secrets-in-ci)
6. [CI vs CD Split](#6-ci-vs-cd-split)

---

## 1. CI/CD Fundamentals

### Cheat Sheet

| Term | Meaning |
|---|---|
| CI (Continuous Integration) | Every code push → automated build + test + scan |
| CD (Continuous Delivery) | Every passing CI → artifact ready to deploy, one-click release |
| CD (Continuous Deployment) | Every passing CI → auto-deploy to production, no human click |
| Shift left | Move testing and security scanning earlier — catch bugs in CI not production |
| Pipeline as code | Jenkinsfile in Git — pipeline is versioned, reviewed, auditable |

### Questions

**[G] What is the difference between Continuous Delivery and Continuous Deployment?**
Delivery: every successful build produces a deployable artifact. Deployment to production still requires a human click or approval. Deployment: every successful build automatically deploys to production with no manual step. Most companies use Delivery for production (need a human gate) and Deployment for staging/dev. In our project: Jenkins (CI) → image pushed to ECR → ArgoCD (CD) deploys to cluster. ArgoCD can be configured as Delivery (manual sync) or Deployment (auto-sync).

**[G] What does "shift left" mean?**
Move security and quality checks as early as possible in the pipeline — to the left of the timeline. Instead of catching a vulnerable dependency in a production incident (far right), catch it in the PR build (far left) via Trivy and OWASP dependency check. Cheaper to fix at commit time than at incident time. Also applies to testing: unit tests in CI vs integration tests in staging.

---

## 2. Jenkins Pipeline

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Declarative pipeline | `pipeline { stages { stage('Build') { steps {...} } } }` — structured, recommended |
| Scripted pipeline | Groovy code in `node {}` block — more flexible but harder to read |
| Jenkinsfile | Pipeline definition in Git — versioned alongside the code |
| `parallel` block | Run multiple stages simultaneously — matrix build per service |
| `post { always {} failure {} }` | Cleanup, notifications regardless of success/failure |
| Shared library | Reusable Groovy functions across multiple Jenkinsfiles |

### Questions

**[G] What is a Jenkinsfile and why is it better than a UI-configured pipeline?**
A Jenkinsfile is the pipeline definition as code, committed to the same repository as the application. Benefits: (1) Versioned — every pipeline change is a Git commit with reviewer approval. (2) Reproduced — clone the repo, get the pipeline. (3) Auditable — who changed the pipeline, when, why. UI-configured pipelines are invisible to Git, lost when Jenkins is rebuilt, and can't be reviewed in a PR. We use declarative Jenkinsfile checked into each service's repo root.

**[G] How do you build 4 microservices in Jenkins without it taking 4× longer?**
Parallel stages. Each service builds in its own `parallel` block — product-svc, order-svc, frontend, eureka all build simultaneously. Total pipeline time = slowest service, not sum of all. In our project the matrix build uses a `parallel` block with one entry per service, each doing: `docker build → trivy scan → docker push to ECR`.

**[S] A Jenkins build passed but the Docker image wasn't pushed to ECR. What do you check?**
1. ECR login step — does Jenkins EC2 have the IAM role to call `ecr:GetAuthorizationToken`? Check AWS CLI: `aws ecr get-login-password --region us-east-2`
2. Was the `docker push` step in the same agent/node that did the `docker login`? Docker login is session-scoped — if the push runs on a different agent, the credential isn't there.
3. Check the pipeline logs for the exact step — Jenkins marks the overall build as success even if a non-critical step failed (if it's not in a `script {}` block that throws).

---

## 3. Quality Gates

### Cheat Sheet

| Tool | What It Checks | Blocks Pipeline? |
|---|---|---|
| Trivy | CVEs in Docker image layers and OS packages | Yes — on CRITICAL/HIGH |
| OWASP Dependency Check | Known vulnerabilities in Java/npm dependencies | Yes — on CRITICAL |
| SonarQube | Code quality, test coverage, code smells, duplications | Yes — if Quality Gate fails |
| Why gates must block | A warning that doesn't block gets ignored. Gates create accountability. |

### Questions

**[G] Why should quality gates block the pipeline rather than just warn?**
A warning that doesn't block gets ignored — developers see it, move on, it accumulates. When a gate blocks, the developer must fix it before merging. It creates a forcing function. In our pipeline: Trivy with CRITICAL CVEs blocks the build. SonarQube with coverage below threshold blocks. The pain of being blocked once trains the team to address issues early. Warnings-only pipelines are security theatre.

**[G] Trivy vs OWASP Dependency Check — what's the difference?**
Trivy scans the Docker image as a whole — OS packages (Alpine apk), Java jar files inside the image, filesystem. It finds CVEs in anything that ended up in the image. OWASP Dependency Check scans the Maven `pom.xml` and the built classpath — Java library CVEs from the NVD database. Overlap exists, but Trivy is broader (catches OS-level CVEs that OWASP misses). We run both: OWASP in the build stage (before Docker build), Trivy on the final image.

**[S] Trivy is blocking every build with a CVE in the base image that has no fix yet. What do you do?**
Three options: (1) `.trivyignore` file — add the CVE ID to suppress it with a documented reason and an expiry date. (2) Update the base image to a newer minor version that has the patch. (3) If no patch exists: accept the risk with a ticket, add it to the ignore file with a comment and a Jira link, review monthly. Never permanently suppress without documentation — that's how CVEs become incidents.

---

## 4. Docker Build in CI

### Cheat Sheet

| Approach | Security Risk | Use |
|---|---|---|
| Docker socket bind mount (`/var/run/docker.sock`) | HIGH — container gets full Docker daemon access = root on host | Dev only, never production |
| Docker-in-Docker (DinD) | Medium — privileged container | Acceptable but complex |
| Kaniko | No Docker daemon needed — builds OCI images inside K8s | Best for K8s-native CI |
| Jenkins EC2 with Docker installed | Docker runs directly on the host — simple, our approach | Jenkins on dedicated EC2 |

### Questions

**[G] Why is mounting `/var/run/docker.sock` a security risk?**
The Docker socket is the root interface to the Docker daemon running on the host. Any container with access to it can run `docker run --privileged` or `docker run -v /:/host` — full access to the host filesystem as root. It's essentially giving the container root on the node. In CI: if a malicious dependency in your build can exec code, it can escape the container entirely via the socket. Our Jenkins runs on a dedicated EC2 (not in K8s) with Docker installed directly — no socket mounting needed.

---

## 5. Secrets in CI

### Cheat Sheet

| Bad Practice | Good Practice |
|---|---|
| Hardcode ECR URL in Jenkinsfile | Store as Jenkins credential or env var from IAM role |
| AWS access keys in Jenkinsfile | IAM role on Jenkins EC2 — no keys at all |
| `echo $PASSWORD` in pipeline logs | Use Jenkins credentials binding — value is masked in logs |
| App runtime secrets in CI | CI handles build-time secrets. App gets runtime secrets from ESO + Secrets Manager. |

### Questions

**[G] How does Jenkins push to ECR without AWS access keys?**
Jenkins runs on an EC2 instance. The EC2 has an IAM instance profile (role) with `ecr:GetAuthorizationToken` and `ecr:BatchCheckLayerAvailability` / `ecr:PutImage` permissions. When Jenkins runs `aws ecr get-login-password`, the AWS CLI uses the EC2 instance metadata service to get temporary credentials from the role — no static keys anywhere. This is the correct pattern: IAM role on the machine, never keys in code or environment variables.

**[S] A developer accidentally committed AWS credentials to the Jenkinsfile. What's the immediate response?**
1. Revoke the keys immediately in IAM — before anything else
2. Check CloudTrail for API calls using those keys in the last 24h — assess blast radius
3. Remove the credentials from Git history: `git filter-branch` or `git filter-repo` — the commit itself must be scrubbed, not just reverted (reverts leave the old commit in history)
4. Rotate any resources the keys could have accessed
5. Add `git-secrets` pre-commit hook to prevent recurrence

---

## 6. CI vs CD Split

### Cheat Sheet

```
CI (Jenkins owns):                    CD (ArgoCD owns):
  ↓ code push                           ↓ Git change detected
  ↓ build (mvn package)                 ↓ Helm chart rendered
  ↓ unit tests                          ↓ diff vs live cluster
  ↓ Trivy + OWASP + SonarQube           ↓ apply diff to cluster
  ↓ docker build                        ↓ watch rollout
  ↓ docker push to ECR (git-SHA tag)
  ↓ update values.yaml with new tag
  ↓ commit + push to Git
```

### Questions

**[G] Why separate CI and CD instead of having Jenkins deploy directly?**
CI is imperative: run commands, produce an artifact. CD is declarative: desired state lives in Git, the CD tool reconciles live state to match. Separating them gives: (1) Git as audit trail for every deploy — who changed what, when, why. (2) Rollback = revert a Git commit. (3) Drift detection — ArgoCD shows when live cluster differs from Git. (4) Self-healing — ArgoCD auto-corrects manual `kubectl` changes. Jenkins doing `kubectl apply` directly has none of these properties.

**[S] Jenkins build succeeded, new image in ECR, but ArgoCD is still running the old version. Why?**
Jenkins pushed the image but didn't update `values.yaml`. ArgoCD syncs from Git — if the Helm values file still has the old image tag, ArgoCD sees no diff and does nothing. The Jenkins pipeline must: build → push to ECR → `sed -i "s|image:.*|image: ${ECR_REPO}:${GIT_SHA}|" helm/ecom/values.yaml` → `git commit` → `git push`. ArgoCD detects the commit and syncs. Missing the Git commit step = image in ECR but never deployed.
