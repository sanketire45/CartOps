# 07 — AWS Core Services

> Tags: **[G]** conceptual · **[S]** scenario · **[AWS]** AWS-specific
> Project: EKS, ECR, IAM + IRSA, Secrets Manager, S3, SQS, KMS, EBS, EFS

---

## 1. IAM & IRSA

> IAM roles vs users vs groups, assume role, trust policy vs permissions policy,
> IRSA — pod-level identity without static credentials,
> OIDC as trust bridge between K8s and AWS.

<!-- ADD QUESTIONS HERE — content already in 02-security.md Layer 2 -->

---

## 2. EKS

> Managed vs self-managed control plane, managed node groups, Fargate,
> addon lifecycle (VPC CNI, CoreDNS, kube-proxy, EBS CSI),
> authentication modes (API vs aws-auth ConfigMap), Access Entries.

<!-- ADD QUESTIONS HERE — content already in eks-terraform-answered.md -->

---

## 3. ECR

> Private registry, image lifecycle policy (keep last N images by git-SHA),
> immutable tags, ECR image scanning (Inspector/enhanced),
> ECR login from Jenkins EC2 vs pod (different IAM mechanisms).

<!-- ADD QUESTIONS HERE -->

---

## 4. Secrets Manager vs SSM Parameter Store

> Both are key-value stores. Secrets Manager: rotation, versioning, ~$0.40/secret/month — for credentials.
> SSM: free standard tier, no rotation — for config + AWS public directory (AMI IDs, etc).
> Our project: Secrets Manager for mysql password (via ESO), SSM for AMI ID lookup in launch template.

<!-- ADD QUESTIONS HERE -->

---

## 5. EBS & Storage

> EBS volume types (gp2 vs gp3), AZ-specific — pod must be in same AZ as volume,
> WaitForFirstConsumer binding mode — waits for pod scheduling before provisioning,
> CSI driver (EBS CSI addon), StorageClass, PVC.

<!-- ADD QUESTIONS HERE -->

---

## 6. SQS & S3

> SQS — message queue, standard vs FIFO, visibility timeout, dead letter queue.
> S3 — object storage, bucket policies, versioning, lifecycle rules.
> How order-service accesses SQS via IRSA (no static credentials).

<!-- ADD QUESTIONS HERE -->

---

## 7. KMS

> Customer managed key (CMK) vs AWS managed key,
> envelope encryption, key policy vs IAM policy,
> KMS used for EKS secrets encryption at rest in etcd.

<!-- ADD QUESTIONS HERE -->

---

## 8. VPC & Networking

> See [08-networking.md](08-networking.md) for full coverage.

---

## 9. NLB vs ALB

> NLB — Layer 4 (TCP/UDP), ultra-low latency, static IPs, used for NGINX ingress.
> ALB — Layer 7 (HTTP/HTTPS), path/host routing, WAF integration, used for AWS LBC Ingress.
> Our project: NLB for NGINX ingress controller, AWS LBC installed for future ALB/Ingress use.

<!-- ADD QUESTIONS HERE -->
