# 08 — Networking (Kubernetes + AWS)

> Tags: **[G]** conceptual · **[S]** scenario · **[AWS]** AWS-specific
> Project: VPC CNI, default VPC 3 AZs, NLB → NGINX ingress, NetworkPolicy default-deny,
> prefix delegation, ENI pod limits, ClusterIP services, Eureka service discovery

---

## Sections
1. [Kubernetes Networking Model](#1-kubernetes-networking-model)
2. [VPC CNI & ENI](#2-vpc-cni--eni)
3. [Services](#3-services)
4. [Ingress & Load Balancers](#4-ingress--load-balancers)
5. [NetworkPolicy](#5-networkpolicy)
6. [DNS Inside Kubernetes](#6-dns-inside-kubernetes)
7. [AWS VPC Fundamentals](#7-aws-vpc-fundamentals)

---

## 1. Kubernetes Networking Model

### Cheat Sheet

| Rule | Meaning |
|---|---|
| Every pod gets a unique IP | No port conflicts between pods — each pod is its own host |
| Pods talk without NAT | Pod A can reach Pod B directly by IP — no masquerading |
| Services provide stable VIPs | Pod IPs change on restart — Service IP stays fixed |
| CNI implements it | The network rules are managed by the CNI plugin, not K8s itself |

### Questions

**[G] What are the fundamental networking rules in Kubernetes?**
Three rules: (1) Every pod gets a unique cluster-wide IP. (2) Any pod can reach any other pod directly by IP without NAT. (3) Nodes can reach any pod without NAT. This flat network model simplifies service-to-service communication — no port mapping, no NAT tables. The CNI plugin is responsible for making this work. On EKS with VPC CNI, every pod gets a real VPC IP — reachable from other pods and from AWS services directly.

**[G] What is a CNI plugin and what does it do?**
Container Network Interface — the plugin responsible for: assigning an IP to each pod, setting up the network namespace for the pod, programming the routing rules so pods can reach each other. K8s defines the interface, the plugin implements it. On EKS: VPC CNI assigns real VPC subnet IPs to pods (no overlay network). On bare metal: Calico, Flannel, or Cilium create overlay networks. The CNI is also what enforces NetworkPolicy — K8s API accepts policies, CNI enforces them.

---

## 2. VPC CNI & ENI

### Cheat Sheet

| Concept | Key Point |
|---|---|
| VPC CNI | EKS default CNI — assigns real VPC IPs to pods (not overlay) |
| ENI | Elastic Network Interface — virtual NIC attached to EC2 |
| Pod IP source | Pod gets an IP from a secondary IP assigned to an ENI on its node |
| t3.medium limits | 3 ENIs × 6 IPs = 17 pods max (formula: (3×(6-1))+2=17) |
| Prefix delegation | /28 block per slot → 16 IPs instead of 1 → t3.medium: 288 IPs |
| Still needs launch template | kubelet `--max-pods` is baked at boot — must override via launch template |

### Questions

**[G] Why is t3.medium limited to 17 pods?**
VPC CNI assigns a real VPC IP to each pod from secondary IPs on the node's ENIs. t3.medium supports 3 ENIs × 6 IPs = 18 IPs total. One IP per ENI is reserved for the ENI's own primary IP. Formula: (ENIs × (IPs_per_ENI - 1)) + 2 = (3 × 5) + 2 = 17. The +2 accounts for the node itself and one system reserved. This is a hard EC2 instance limit — no tuning changes the ENI count.

**[G] What is prefix delegation and why do you need a launch template to make it work?**
Prefix delegation changes VPC CNI from assigning 1 IP per slot to assigning a /28 block (16 IPs) per slot. t3.medium: 3 ENIs × 5 slots × 16 IPs = 240+ IPs. But kubelet's `--max-pods` is set at node boot time by the EKS bootstrap script using the ENI formula — it hardcodes 17. Even with 240 IPs available, kubelet refuses to schedule pod 18 because its counter says max=17. Fix: override `--max-pods` via a launch template's user_data using AL2023 `NodeConfig`. Both changes together: prefix delegation (enough IPs) + launch template (kubelet allowed to use them).

**[S] Nodes show NotReady after cluster creation. VPC CNI is installed. What's wrong?**
VPC CNI was installed after the nodes booted — nodes bootstrapped without an IP provider. Or: the VPC CNI addon was deployed but the `aws-node` DaemonSet pod is crashing. Check: `kubectl get pods -n kube-system -l k8s-app=aws-node`. If CrashLoopBackOff: check logs for IMDS connectivity or IRSA permission issues — VPC CNI needs `ec2:DescribeInstances` and `ec2:AssignPrivateIpAddresses` via the node IAM role.

---

## 3. Services

### Cheat Sheet

| Type | Accessible From | Backed By |
|---|---|---|
| ClusterIP | Inside cluster only | kube-proxy iptables rules |
| NodePort | Node IP + port (30000-32767) | ClusterIP + node port mapping |
| LoadBalancer | Internet / VPC | ClusterIP + AWS NLB/ALB |
| Headless (`clusterIP: None`) | DNS returns pod IPs directly | CoreDNS |

### Questions

**[G] What is a ClusterIP Service and how does it work?**
ClusterIP is a virtual IP (VIP) assigned to the Service. It never changes even as pods come and go. kube-proxy programs iptables rules on every node: "traffic to ClusterIP:port → round-robin to one of the healthy pod IPs." The ClusterIP itself doesn't have a network interface — it's an iptables DNAT rule. When you `curl product-svc:8080` from inside a pod, CoreDNS resolves `product-svc` to the ClusterIP, iptables intercepts the packet and forwards it to a real pod IP.

**[G] Why does MySQL use a headless Service?**
StatefulSet pods need stable DNS names: `mysql-0.mysql.ecom.svc.cluster.local`. A regular ClusterIP service load-balances across all pods — a JDBC connection to `mysql` might hit mysql-0 or mysql-1 randomly. Headless (`clusterIP: None`) makes CoreDNS return the individual pod IPs directly. The client connects to a specific pod. This is how StatefulSets provide stable network identity — headless service + stable pod hostname (`mysql-0`, `mysql-1`).

---

## 4. Ingress & Load Balancers

### Cheat Sheet

| Component | Role |
|---|---|
| Ingress resource | K8s object — defines routing rules (path, host → Service) |
| Ingress controller | Pod that watches Ingress objects and configures the actual proxy |
| NGINX ingress | Runs an NGINX pod as the proxy. We use this. |
| AWS LBC (Load Balancer Controller) | Creates ALB/NLB directly from Ingress/Service annotations |
| NLB | Layer 4 — fronts NGINX. Static IPs per AZ. Our external entry point. |
| Traffic path | Internet → NLB → NGINX pod → ClusterIP → pod |

### Questions

**[G] What is the difference between an Ingress resource and an Ingress controller?**
Ingress resource is just a K8s config object — it says "requests to /api/products go to product-svc:8080." By itself it does nothing. The Ingress controller is the software that reads those objects and configures the actual proxy (NGINX, Envoy, etc.). You need both. In our project: the Ingress resource defines path routing, NGINX ingress controller reads it and programs NGINX's server blocks, the NLB fronts NGINX and routes TCP traffic to it.

**[G] Why NLB in front of NGINX instead of ALB directly?**
NLB is Layer 4 (TCP) — it passes traffic through to NGINX which does the Layer 7 routing. Advantages: static IP per AZ (useful for DNS whitelisting), ultra-low latency, handles any TCP protocol. ALB directly (via AWS LBC) does Layer 7 natively — path routing, WAF, auth. We use NLB+NGINX because NGINX gives us more routing flexibility and the NLB static IPs are valuable for enterprise environments. Future: ALB directly via AWS LBC for native AWS integrations.

---

## 5. NetworkPolicy

### Cheat Sheet

> Full Q&A in [01-kubernetes-core.md § Security Layer 5](01-kubernetes-core.md)

| Key Point | Detail |
|---|---|
| Enforced by CNI, not API server | API accepts the policy. VPC CNI with `enableNetworkPolicy=true` enforces it. |
| Silently dropped | NetworkPolicy drops packets without RST — connections hang, not refused |
| Default-deny | Empty `podSelector: {}` + `policyTypes: [Ingress]` = deny all ingress to all pods |
| Our 6 policies | default-deny + nginx→frontend + frontend→product + frontend→order + services→mysql + all→eureka |

---

## 6. DNS Inside Kubernetes

### Cheat Sheet

| DNS Name | Resolves To |
|---|---|
| `mysql` | ClusterIP of mysql Service (within same namespace) |
| `mysql.ecom` | Same — namespace qualified |
| `mysql.ecom.svc.cluster.local` | Full FQDN — works from any namespace |
| `mysql-0.mysql.ecom.svc.cluster.local` | Individual StatefulSet pod (headless service) |

### Questions

**[G] How does DNS work inside Kubernetes?**
CoreDNS runs as a Deployment in `kube-system`. Every pod's `/etc/resolv.conf` is injected by kubelet pointing to the CoreDNS ClusterIP. When product-svc does `new URL("http://mysql:3306")`, the JVM queries CoreDNS. CoreDNS looks up `mysql.ecom.svc.cluster.local` (namespace is appended from the pod's search domain) and returns the Service's ClusterIP. kube-proxy then routes it to a pod IP. This is why services work by name without any service registry configuration.

**[G] Why does Eureka work in your project — isn't it redundant with K8s Services?**
Eureka is a Spring Cloud service registry — microservices register themselves by name and discover each other through Eureka. K8s Services provide the same thing via DNS. In our project we keep Eureka for now because the Spring Boot apps are built with Spring Cloud and use `@LoadBalanced RestTemplate` or Feign clients that rely on Eureka for service discovery. Long-term these could be replaced with K8s Services + Spring Cloud Kubernetes library. Both work — Eureka is redundant but not harmful while keeping the app portable.

---

## 7. AWS VPC Fundamentals

### Cheat Sheet

| Concept | Key Point |
|---|---|
| VPC | Isolated private network in AWS. Your cluster lives here. |
| Subnet | Subdivision of VPC — scoped to one AZ. Public or private. |
| Public subnet | Has a route to Internet Gateway. Nodes here get public IPs if needed. |
| Private subnet | Routes outbound via NAT Gateway. Pods here — not directly reachable from internet. |
| Security Group | Stateful firewall — rules on instances/ENIs. Node-level, not pod-level. |
| NACL | Stateless firewall — rules on subnets. Rarely needed with Security Groups. |
| Internet Gateway | Entry/exit for public subnets to reach the internet |
| NAT Gateway | Lets private subnets reach internet (outbound only — to pull images, call APIs) |

### Questions

**[G] Public vs private subnets — where do EKS nodes go?**
Best practice: nodes in private subnets. They don't need a public IP — inbound traffic comes via the NLB (which is in public subnets). Nodes reach ECR, Secrets Manager, and the internet through a NAT Gateway in the public subnet. This limits the attack surface: nodes are not directly reachable from the internet even if a Security Group is misconfigured. Our project uses the default VPC — in a production account you'd create a dedicated VPC with proper public/private subnet separation.

**[G] Security Groups vs NetworkPolicy — do you need both?**
Yes — they protect different layers. Security Groups are AWS-level: they control which IP ranges and ports can reach the EC2 node (or ENI). They're coarse-grained — a Security Group rule for port 8080 allows all pods on that node. NetworkPolicy is Kubernetes-level: controls which specific pods (by label selector) can talk to which other pods within the cluster. You need Security Groups for node-level access control (allow port 443 from the load balancer) and NetworkPolicy for pod-level zero-trust inside the cluster.
