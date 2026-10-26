# 01 — Kubernetes Core

> Tags: **[G]** conceptual · **[S]** scenario · **[TF]** Terraform
> Project: cluster `ecom`, K8s 1.34, 2× t3.medium, us-east-2, default VPC

---

## 1. Cluster Architecture

> What is EKS, what does AWS manage vs you, control plane components,
> managed node group vs self-managed vs Fargate, why 2+ AZs required.
> → See also: eks-terraform-answered.md Section 1

<!-- ADD QUESTIONS HERE AS TOPICS ARE COVERED -->

---

## 2. Pods & Workloads

> Pod lifecycle, restartPolicy, Deployment vs StatefulSet vs DaemonSet vs Job,
> init containers, sidecar pattern, resource requests vs limits.

<!-- ADD QUESTIONS HERE -->

---

## 3. Services & Networking

> ClusterIP vs NodePort vs LoadBalancer, headless service, DNS resolution inside cluster,
> kube-proxy, iptables vs IPVS, Endpoints vs EndpointSlices.

<!-- ADD QUESTIONS HERE -->

---

## 4. Scheduling

> How the scheduler picks a node, nodeSelector vs nodeAffinity vs podAffinity,
> taints and tolerations, resource requests in scheduling decisions,
> pod priority and preemption.

<!-- ADD QUESTIONS HERE -->

---

## 5. ConfigMaps & Secrets

> ConfigMap vs Secret, how pods consume them (env vs volume mount),
> Secret encryption at rest in etcd, why not to use Secrets for real credentials.

<!-- ADD QUESTIONS HERE -->

---

## 6. StatefulSets

> StatefulSet vs Deployment, stable network identity, volumeClaimTemplates,
> ordered pod creation/deletion, headless service requirement,
> EBS AZ affinity trap (WaitForFirstConsumer).

<!-- ADD QUESTIONS HERE -->

---

## 7. RBAC

> Role vs ClusterRole, RoleBinding vs ClusterRoleBinding,
> additive-only (no DENY verb), `kubectl auth can-i`, ServiceAccount,
> how IRSA builds on top of ServiceAccount.

<!-- ADD QUESTIONS HERE -->

---

## 8. Node capacity & pod limits

> ENI formula for max-pods, kubelet --max-pods baked at boot,
> why prefix delegation alone doesn't increase pod count,
> launch template + nodeadm config to override.

<!-- ADD QUESTIONS HERE -->
