# 04 — Docker & Containers

> Tags: **[G]** conceptual · **[S]** scenario
> Project: multi-stage Dockerfiles, non-root appuser, eclipse-temurin:17-jre-alpine runtime

---

## 1. Container fundamentals

> Container vs VM, namespaces + cgroups, image layers, Union filesystem,
> why containers are not VMs.

<!-- ADD QUESTIONS HERE -->

---

## 2. Dockerfile best practices

> Multi-stage builds, builder vs runtime image, why JRE not JDK in final stage,
> non-root user, .dockerignore, layer caching order (dependencies before source code),
> COPY vs ADD, CMD vs ENTRYPOINT.

<!-- ADD QUESTIONS HERE -->

---

## 3. Image tagging & versioning

> Why `:latest` is dangerous (non-deterministic, no rollback),
> git-SHA tags for immutability, semantic versioning,
> ECR lifecycle policy to clean old images.

<!-- ADD QUESTIONS HERE -->

---

## 4. Container security

> Non-root user in Dockerfile vs runAsNonRoot in securityContext — difference,
> why both are needed, distroless images, image scanning (Trivy).

<!-- ADD QUESTIONS HERE -->

---

## 5. Container runtime

> containerd vs Docker, why Kubernetes dropped Docker (dockershim),
> CRI (Container Runtime Interface), OCI spec.

<!-- ADD QUESTIONS HERE -->
