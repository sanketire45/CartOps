# 04 — Docker & Containers

> Tags: **[G]** conceptual · **[S]** scenario
> Project: multi-stage Dockerfiles, eclipse-temurin:17-jre-alpine runtime, non-root appuser,
> .dockerignore, ECR with git-SHA tags, Kyverno deny-latest-tag policy

---

## Sections
1. [Container Fundamentals](#1-container-fundamentals)
2. [Dockerfile Best Practices](#2-dockerfile-best-practices)
3. [Image Tagging & Versioning](#3-image-tagging--versioning)
4. [Container Security](#4-container-security)
5. [Container Runtime](#5-container-runtime)

---

## 1. Container Fundamentals

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Container vs VM | Container shares host OS kernel. VM has its own kernel + OS. |
| Namespace | Linux isolation primitive — each container gets its own PID, net, mount, UTS namespace |
| cgroup | Controls resource usage — CPU, memory limits per container |
| Image layers | Read-only, stacked via Union filesystem. Each `RUN`/`COPY` = new layer. |
| Container = image + writable layer | Running container adds a thin writable layer on top of read-only image |

### Questions

**[G] Container vs VM — what's the actual difference?**
VMs virtualise hardware — each VM has its own OS kernel, takes minutes to boot, uses GBs of RAM just for the OS. Containers share the host OS kernel — only the app and its dependencies are packaged. Start in milliseconds, use MBs of RAM. The trade-off: VMs provide stronger isolation (different kernels can't interfere). Containers share the kernel — a kernel exploit in one container could affect others. That's why seccompProfile and capability dropping matter.

**[G] What are namespaces and cgroups?**
Two Linux kernel features that make containers possible. Namespaces: isolation — each container sees its own process tree (PID namespace), network interfaces (net namespace), and filesystem mount points (mount namespace). From inside the container, it looks like a separate machine. cgroups (control groups): resource limits — cap how much CPU, memory, and I/O a container can use. Without cgroups, one container could starve the entire node.

---

## 2. Dockerfile Best Practices

### Cheat Sheet

| Practice | Why |
|---|---|
| Multi-stage build | Builder image has JDK + Maven (large). Runtime image has only JRE + jar (small). |
| JRE not JDK in final stage | JDK adds compilers, debuggers — attack surface with no runtime benefit |
| `eclipse-temurin:17-jre-alpine` | Alpine = minimal base image (~5MB OS). Fewer packages = fewer CVEs. |
| Non-root user | If process is exploited, attacker gets a non-root user — not root on the node |
| `.dockerignore` | Prevents `target/`, `.git/`, `*.md` from being copied → smaller image, no secrets leak |
| `COPY dependencies first, source second` | Dependencies change rarely — Docker caches that layer. Source changes every build. |

### Questions

**[G] What is a multi-stage Docker build and why does it matter for Java apps?**
Build stage uses a full JDK + Maven image to compile and package. Final stage copies only the built `.jar` into a minimal JRE image. Result: our runtime image is ~200MB instead of ~500MB+ for a full JDK image. Smaller image = faster pull, less storage cost in ECR, reduced attack surface (no compiler, no Maven, no build tools in production). This is why we use `eclipse-temurin:17-jre-alpine` as the final base.

**[G] Why create a non-root user in the Dockerfile?**
By default Docker runs processes as root inside the container — UID 0. If the app has a vulnerability (RCE in a dependency), the attacker gets root inside the container. From root you can escape certain container boundaries, read sensitive mounted files, or pivot to other pods. Non-root user limits the blast radius. We create `appuser` with UID 1000 and `USER appuser` in the Dockerfile — combined with `runAsNonRoot: true` in the securityContext which enforces this at the K8s level.

**[S] Your Docker build passes locally but fails in Jenkins with a "permission denied" error copying files. Why?**
`.dockerignore` is missing or wrong, and Jenkins is running in a directory where some files are owned by root (from a previous Docker step or volume mount). Or the `COPY` is trying to copy a file the build context doesn't include. Check: `COPY target/*.jar app.jar` assumes `target/` exists — if Maven hasn't run or the build stage didn't `RUN mvn package`, the jar isn't there. Multi-stage builds must copy FROM the named build stage explicitly: `COPY --from=builder /app/target/*.jar app.jar`.

**[G] Layer caching — how do you structure a Dockerfile to maximise cache hits?**
Put the most stable layers first. Dependencies (Maven pom.xml, package.json) rarely change. Source code changes every commit. So: `COPY pom.xml .` → `RUN mvn dependency:resolve` → `COPY src/ .` → `RUN mvn package`. If only source changed, Docker reuses the cached dependency layer — build goes from 3 minutes to 20 seconds. Wrong order (COPY everything first) = cache miss on every build.

---

## 3. Image Tagging & Versioning

### Cheat Sheet

| Tag Strategy | Problem |
|---|---|
| `:latest` | Non-deterministic — same tag, different image after a rebuild. Can't rollback. |
| Git SHA tag | Immutable — `product-svc:a3f2c91` always = that exact commit. Rollback = deploy old SHA. |
| Semantic version | `v1.2.3` — human-readable, but requires manual bump. Common for public releases. |
| Branch tag | `product-svc:main-a3f2c91` — identifies both branch and commit |

### Questions

**[G] Why is `:latest` tag dangerous in production?**
Three problems: (1) Non-deterministic — two deploys with `:latest` can run different code if the image was rebuilt in between. (2) No rollback — you can't roll back to "the last `:latest`" because overwriting the tag destroys history. (3) Requires `imagePullPolicy: Always` — every pod start pulls from ECR, adding latency. We enforce git-SHA tags with a Kyverno `deny-latest-tag` ClusterPolicy — any Deployment using `:latest` is rejected at admission time.

**[G] How does git-SHA tagging work in your Jenkins pipeline?**
Jenkins reads the git commit SHA at pipeline start: `GIT_COMMIT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()`. Then builds and pushes: `docker build -t ${ECR_REPO}:${GIT_COMMIT} .` and `docker push`. ArgoCD's values.yaml is then updated with the new tag, committed to Git, and ArgoCD deploys it. Rollback = commit the old SHA back to values.yaml.

---

## 4. Container Security

### Cheat Sheet

| Layer | What It Does |
|---|---|
| Non-root in Dockerfile (`USER appuser`) | Default process UID inside image |
| `runAsNonRoot: true` (securityContext) | K8s enforces it — rejects pod if image runs as root |
| `drop: [ALL]` capabilities | Removes all Linux capabilities from the container |
| `readOnlyRootFilesystem: true` | Container can't write to its own filesystem — blocks malware persistence |
| Image scanning (ECR Inspector) | Scans for known CVEs in image layers on every push |
| Distroless base image | No shell, no package manager — nothing for an attacker to use |

### Questions

**[G] Dockerfile `USER appuser` vs `runAsNonRoot: true` in securityContext — what's the difference and why do you need both?**
`USER appuser` in the Dockerfile sets the default UID the image runs as — it's baked into the image. `runAsNonRoot: true` in securityContext is enforced by Kubernetes at pod creation — it rejects the pod if the container would run as UID 0. You need both: Dockerfile sets the intent, securityContext enforces it at the platform level regardless of what the image says. A third-party image might not have a non-root user baked in — `runAsNonRoot` catches that.

**[S] ECR image scan shows a CRITICAL CVE in your base image. What do you do?**
1. Check if the CVE is actually exploitable in your context (many CVEs are in packages your app never calls)
2. Update the base image in the Dockerfile: `FROM eclipse-temurin:17-jre-alpine` → pull the latest tag which likely has the fix
3. Rebuild and push — Jenkins pipeline triggers a new image scan
4. If the base image maintainer hasn't patched it yet: either wait, switch to a different base (Distroless), or accept and document the risk. Never ship a known-exploitable CRITICAL without a documented decision.

---

## 5. Container Runtime

### Cheat Sheet

| Concept | Key Point |
|---|---|
| containerd | The container runtime Kubernetes uses (since 1.24 — Docker removed) |
| CRI | Container Runtime Interface — the API between kubelet and the runtime |
| OCI | Open Container Initiative — spec for image format and runtime behaviour |
| Why Docker was removed | Docker → dockershim → containerd = extra hop. K8s now talks to containerd directly. |
| Docker images still work | Docker produces OCI-compliant images — they run on containerd fine |

### Questions

**[G] Kubernetes removed Docker as a runtime. Does that mean Docker images don't work?**
No — Docker images are OCI-compliant. containerd runs OCI images — Docker's images are just OCI images. What was removed was dockershim: the compatibility layer that translated K8s container API calls → Docker API → containerd. The chain is now shorter: kubelet → CRI → containerd directly. Your Dockerfiles and `docker build` commands are unchanged. Only the runtime that runs images in the cluster changed.

**[G] What is the CRI (Container Runtime Interface)?**
CRI is the API that kubelet uses to talk to any container runtime. It defines operations like `RunPodSandbox`, `CreateContainer`, `StartContainer`. Any runtime that implements CRI works with Kubernetes — containerd, CRI-O, Kata Containers. This is why removing Docker (which never natively implemented CRI) didn't break images: containerd was always underneath Docker and already implements CRI natively.
