# 08 — Networking (Kubernetes + AWS)

> Tags: **[G]** conceptual · **[S]** scenario · **[AWS]** AWS-specific
> Project: VPC CNI, default VPC 3 AZs, NLB, NGINX ingress, NetworkPolicy,
> prefix delegation, ENI pod limits, ClusterIP services

---

## 1. Kubernetes networking model

> Every pod gets a unique IP, pods can talk to any other pod without NAT,
> Services provide stable VIPs, kube-proxy manages iptables rules,
> CNI plugin is responsible for pod networking.

<!-- ADD QUESTIONS HERE -->

---

## 2. VPC CNI & ENI

> How VPC CNI works — assigns real VPC IPs to pods (not overlay network),
> ENI per node, IPs per ENI, max-pods formula: (ENIs × (IPs_per_ENI - 1)) + 2,
> t3.medium: 3 ENIs × 6 IPs = 17 pods max.

**[G] Why is the max pod count on t3.medium 17?**
VPC CNI assigns a real VPC IP to each pod from the node's ENIs. t3.medium supports 3 ENIs with 6 IPs each. One IP per ENI is reserved for the ENI itself (the primary IP). Formula: `(3 × (6-1)) + 2 = 17`. The +2 is for the node itself and one reserved. This is a hard limit set by the ENI quota on that instance type.

**[G] What is prefix delegation and why does it need a launch template?**
Prefix delegation changes how VPC CNI assigns IPs: instead of 1 IP per slot, it assigns a /28 block (16 IPs) per slot. t3.medium goes from 17 available IPs to 288. BUT kubelet's `--max-pods` is baked at node boot time by the EKS bootstrap script — it still says 17 regardless of IPs available. Prefix delegation is useless without also overriding `--max-pods` via a launch template. You need both: prefix delegation (enough IPs) + launch template maxPods=110 (kubelet allowed to use them).

<!-- ADD MORE -->

---

## 3. Services

> ClusterIP — stable virtual IP inside cluster, backed by iptables/IPVS rules.
> NodePort — exposes on each node's IP on a static port.
> LoadBalancer — provisions a cloud load balancer (NLB/ALB).
> Headless — no VIP, DNS returns pod IPs directly (used by StatefulSets).

<!-- ADD QUESTIONS HERE -->

---

## 4. Ingress & Load Balancers

> Ingress resource vs Ingress controller, NGINX ingress vs AWS LBC,
> NLB vs ALB, path-based routing, TLS termination,
> internet → NLB → NGINX pod → ClusterIP service → pod.

<!-- ADD QUESTIONS HERE -->

---

## 5. NetworkPolicy

> Full content in [02-security.md](02-security.md) / [k8s-security-answered.md](k8s-security-answered.md) Layer 5.
> Key point: policies are enforced by the CNI, not the API server.
> VPC CNI requires `enableNetworkPolicy=true` — without it, policies are silently ignored.

---

## 6. DNS inside Kubernetes

> CoreDNS resolves service names, `<service>.<namespace>.svc.cluster.local`,
> pods use cluster DNS by default (resolv.conf injected),
> why Eureka service discovery works by service name not IP.

<!-- ADD QUESTIONS HERE -->

---

## 7. AWS VPC fundamentals

> VPC, subnets (public vs private), CIDR ranges, Internet Gateway,
> NAT Gateway, Security Groups vs NACLs, route tables,
> why EKS needs subnets in 2+ AZs.

<!-- ADD QUESTIONS HERE -->
