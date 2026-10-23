# CartOps — Jenkins CI Server Setup Guide

Full setup walkthrough for the Jenkins EC2 master node that runs the `dev-build.groovy`
pipeline. Update this file whenever you hit a new error or change a step.

---

## Architecture: Single-EC2 Setup (Learning / Dev)

```
EC2 (t3.large, Ubuntu 25.10)
├── Jenkins  :8080   — CI orchestrator
├── SonarQube:9000   — code quality gate (Docker container)
├── Docker daemon    — builds all 4 Spring Boot images
├── Trivy            — image + filesystem scanning
└── AWS CLI          — ECR push (via EC2 IAM role, no stored keys)
```

No separate Jenkins worker node. Pipeline uses `agent any` → runs on the built-in node.
For production: add a second EC2 as an SSH agent and set built-in node executors to 0.

---

## PHASE A — EC2 Instance

| Setting | Value |
|---|---|
| Instance type | t3.large (2 vCPU, 8 GB RAM) |
| AMI | Ubuntu 22.04+ LTS |
| Storage | **29 GB gp3 minimum** — Docker images for 4 Spring Boot services fill disk fast |
| IAM Role | Attach a role with `AmazonEC2ContainerRegistryPowerUser` |
| Elastic IP | Attach one — Jenkins URL must be stable for GitHub webhooks |

### Security Group Inbound Rules

| Type | Port | Source | Purpose |
|---|---|---|---|
| SSH | 22 | Your IP | Terminal access |
| Custom TCP | 8080 | Your IP | Jenkins UI |
| Custom TCP | 9000 | Your IP | SonarQube UI |

> **Why Custom TCP for 9000 and not "HTTP"?**
> AWS's "HTTP" type hardcodes port 80. SonarQube runs on 9000.
> HTTP/HTTPS presets only cover ports 80/443 — use Custom TCP for anything else.

---

## PHASE B — System Packages

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y fontconfig unzip wget curl git apt-transport-https gnupg
```

`fontconfig` is required by Jenkins UI for font rendering — without it, Jenkins fails to start properly.

---

## PHASE C — Java (17 + 21)

Both versions are installed:
- **Java 21** — system default, used by the Jenkins daemon
- **Java 17** — used by Gradle to build Spring Boot services (matches developer local env)

```bash
sudo apt-get install -y openjdk-21-jdk openjdk-17-jdk
```

Set Java 21 as system default (Jenkins daemon uses this):
```bash
sudo update-alternatives --config java
# select java-21 from the list
java -version   # should print 21.x
```

Find the Java 17 path for Jenkins tool config later:
```bash
update-java-alternatives --list
# Output example:
# java-1.17.0-openjdk-amd64   1711   /usr/lib/jvm/java-1.17.0-openjdk-amd64
# java-1.21.0-openjdk-amd64   2111   /usr/lib/jvm/java-1.21.0-openjdk-amd64
```

> **Note:** Ubuntu names the JVM directory `java-1.17.0-openjdk-amd64`, NOT `java-17-openjdk-amd64`.
> The `-1.17.0` vs `-17` mismatch trips people up when entering the path in Jenkins Tools.

---

## PHASE D — Jenkins

### Known Issue: GPG Key Verification Failure on Ubuntu 25.x

The standard Jenkins docs use `wget -O file.asc` which downloads the ASCII-armored key,
but the `debian-stable` repo is signed with a different key (`7198F4B714ABFC68`).
This causes `NO_PUBKEY` errors on apt-get update.

**Fix — fetch the exact key by ID from the Ubuntu keyserver:**

```bash
sudo gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 7198F4B714ABFC68
sudo gpg --export 7198F4B714ABFC68 | sudo tee /usr/share/keyrings/jenkins-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt-get update && sudo apt-get install -y jenkins
```

> Why this works: the `jenkins.io-2023.key` URL serves a different key than the one that
> actually signed the `debian-stable` Release file. Fetching by the exact key ID from the
> keyserver always gets the right one.

### Enable Auto-Start on Reboot

```bash
sudo systemctl enable jenkins
sudo systemctl start jenkins
sudo systemctl status jenkins   # should show "active (running)"
```

---

## PHASE E — Docker

```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker jenkins   # Jenkins OS user must be in the docker group
sudo usermod -aG docker ubuntu    # your shell user too
sudo systemctl enable docker
sudo systemctl restart docker
sudo systemctl restart jenkins    # MUST restart Jenkins after group change
```

Fix docker socket permissions (prevents "permission denied" in pipeline stages):
```bash
sudo chmod 777 /var/run/docker.sock
```

> **Why `usermod -aG docker jenkins` and NOT `docker ubuntu`?**
> Jenkins pipeline stages run as the `jenkins` OS user (not `ubuntu`).
> If only `ubuntu` is added, `docker build` fails with permission denied in the pipeline.
> After usermod, Jenkins must be restarted for the group change to take effect.

---

## PHASE F — AWS CLI v2

No `aws configure` needed — the EC2 IAM role provides credentials automatically.
AWS CLI just needs to be installed so `aws ecr get-login-password` works in the pipeline.

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

---

## PHASE G — Trivy

```bash
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update
sudo apt-get install -y trivy
trivy --version
```

---

## PHASE H — SonarQube (Docker Container)

Running SonarQube as a Docker container on the same EC2 is standard for learning setups.
For production: separate EC2, persistent volume, PostgreSQL backend.

```bash
docker run -d --name sonarqube \
  --restart=always \
  -p 9000:9000 \
  sonarqube:lts-community
```

Wait ~90 seconds for startup, then verify:
```bash
docker logs sonarqube --tail 20
# Look for: "SonarQube is operational"
```

Access: `http://<EC2-IP>:9000`
Default credentials: `admin / admin` (forced password change on first login)

> **"Running a version that is no longer active" warning:** This is cosmetic — the pipeline
> works fully. Pull `docker pull sonarqube:lts-community` and recreate the container to
> clear it when convenient.

---

## PHASE I — Jenkins UI First-Time Setup

Open `http://<EC2-IP>:8080`

```bash
# Get the initial unlock password
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

1. Paste the password → Unlock Jenkins
2. Install suggested plugins (let it run, ~5 minutes)
3. Create admin user — save this password

---

## PHASE J — Jenkins Plugins

**Manage Jenkins → Plugins → Available → install:**

| Plugin | Why needed |
|---|---|
| OWASP Dependency-Check | `owasp_dependency()` shared library step |
| SonarQube Scanner | `sonarqube_analysis()` + quality gate |
| Docker + Docker Pipeline | `docker build` / `docker push` in pipeline stages |
| Pipeline: Stage View | Visual stage breakdown in pipeline UI |
| Pipeline: Shared Groovy Libraries | `@Library('Shared') _` at top of dev-build.groovy |
| GitHub Integration | Webhook trigger on git push |

---

## PHASE K — Jenkins Tools Configuration

### JDK (Manage Jenkins → Tools → JDK installations)

```
Name      : Java17
JAVA_HOME : /usr/lib/jvm/java-1.17.0-openjdk-amd64
```

> Use the path from `update-java-alternatives --list`, NOT `/usr/lib/jvm/java-17-openjdk-amd64`
> (that path doesn't exist — Ubuntu uses the `1.17.0` naming convention).

### OWASP Dependency-Check (Manage Jenkins → Tools → Dependency-Check)

```
Name    : OWASP
Install : automatically (latest)
```

### SonarQube Scanner (Manage Jenkins → Tools → SonarQube Scanner)

```
Name    : Sonar        ← must match SONAR_HOME = tool "Sonar" in dev-build.groovy
Install : automatically
```

---

## PHASE L — Built-In Node Executors

By default Jenkins sets the built-in node to 0 executors (security best practice for
multi-node setups). On a single-EC2 setup this means no builds can run.

**Manage Jenkins → Nodes → Built-In Node → Configure:**

```
Number of executors : 2
Root directory      : /var/lib/jenkins   (already default)
Usage               : Use this node as much as possible
```

---

## PHASE M — Credentials

**Manage Jenkins → Credentials → System → Global → Add Credentials:**

| ID | Type | Value |
|---|---|---|
| `github` | Username + Password | GitHub username + Personal Access Token (PAT) |
| `sonar-token` | Secret Text | Token from SonarQube → Administration → Security → Users → Tokens |

> **No AWS/ECR credential needed.** The EC2 IAM role (`AmazonEC2ContainerRegistryPowerUser`)
> handles all ECR auth. `aws ecr get-login-password` reads the instance role automatically.

---

## PHASE N — SonarQube Server Config

**Manage Jenkins → System → SonarQube servers → Add:**

```
Name       : Sonar
Server URL : http://localhost:9000     ← SonarQube is on the same EC2
Auth Token : sonar-token               ← the credential from Phase M
```

---

## PHASE O — SonarQube Webhook (Critical)

Without this, the `sonarqube_code_quality()` pipeline step hangs forever waiting for a
quality gate result that never arrives. SonarQube must call Jenkins back.

**In SonarQube UI → Administration → Webhooks → Create:**

```
Name : Jenkins
URL  : http://<EC2-IP>:8080/sonarqube-webhook/
```

---

## PHASE P — Shared Library

The pipeline starts with `@Library('Shared') _` — all the helper functions
(`docker_build`, `ecr_push`, `trivy_scan`, `owasp_dependency`, `sonarqube_analysis`, etc.)
live in the shared library repo.

**Manage Jenkins → System → Global Trusted Pipeline Libraries → Add:**

```
Name            : Shared              ← must match @Library('Shared')
Default version : main
Source          : Git
URL             : https://github.com/<your-org>/Jenkins_SharedLib.git
Credentials     : github
```

---

## PHASE Q — Create Pipeline Job

**New Item → Pipeline → name: `ecom-dev-build`**

```
Build Triggers:
  ✅ GitHub hook trigger for GITScm polling

Pipeline Definition:
  Pipeline script from SCM
  SCM         : Git
  URL         : https://github.com/sanketire45/CartOps.git
  Credentials : github
  Branch      : */main
  Script Path : CICD/dev-build.groovy
```

---

## PHASE R — GitHub Webhook

**CartOps repo → Settings → Webhooks → Add webhook:**

```
Payload URL  : http://<EC2-IP>:8080/github-webhook/
Content type : application/json
Events       : Just the push event
```

---

## PHASE S — First Pipeline Run (Smoke Test)

```
Build with Parameters → IMAGE_TAG: test123
```

Expected stage flow:
1. Validate Parameters — IMAGE_TAG not empty ✅
2. Workspace Cleanup ✅
3. Git: Code Checkout ✅
4. Trivy: Filesystem Scan — scans source code, pom.xml deps
5. OWASP: Dependency Check — **takes 10 min on first run** (downloads CVE database)
6. SonarQube: Code Analysis + Quality Gate
7. Docker: Build + Scan + Push (parallel × 4 services)
8. GitOps: Update Image Tag → commits values-prod.yaml → ArgoCD deploys

---

## Common Errors & Fixes

| Error | Cause | Fix |
|---|---|---|
| `NO_PUBKEY 7198F4B714ABFC68` | Jenkins apt key mismatch | See Phase D — fetch key by ID from keyserver |
| `permission denied /var/run/docker.sock` | Jenkins user not in docker group | `usermod -aG docker jenkins` then restart Jenkins, then `chmod 777 /var/run/docker.sock` |
| SonarQube quality gate hangs | Webhook not configured | Add webhook in SonarQube → Administration → Webhooks |
| `JAVA_HOME is not a directory` | Wrong JDK path in Jenkins Tools | Use `/usr/lib/jvm/java-1.17.0-openjdk-amd64` (not `java-17`) |
| `ERR_CONNECTION_TIMED_OUT` on port 9000 | Security group only has HTTP (port 80) | Add Custom TCP rule for port 9000 in AWS Security Group |
| No builds run, queue stays pending | Built-in node has 0 executors | Set executors to 2 in Manage Jenkins → Nodes → Built-In Node |
