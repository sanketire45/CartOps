# =============================================================================
#  vpc.tf  —  production-style VPC for EKS  (REFERENCE — currently commented out)
# =============================================================================
#  WHY COMMENTED OUT:
#    eks.tf currently uses the default VPC (public subnets only) — zero extra cost,
#    fine for a learning cluster you create/destroy frequently.
#    NAT Gateways cost ~$32/month always-on regardless of traffic.
#
#  WHEN TO UNCOMMENT:
#    When doing a production-grade or company cluster. Steps:
#      1. Uncomment everything below
#      2. In eks.tf, comment out:
#           data "aws_vpc" "default" { default = true }
#           data "aws_subnets" "default" { ... }
#      3. In eks.tf, replace subnet_ids in both aws_eks_cluster + aws_eks_node_group:
#           subnet_ids = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
#         (control plane needs both; nodes go in private only — handled by Karpenter tags)
#      4. terraform init && terraform apply
#
#  PRODUCTION LAYOUT:
#
#    INTERNET
#        │
#        ▼
#    Internet Gateway
#        │
#        ▼
#    ┌───────────────────────────────────────────────────────┐
#    │  VPC  10.0.0.0/16                                     │
#    │                                                       │
#    │  PUBLIC SUBNETS  (us-east-2a: 10.0.1.0/24)           │
#    │                  (us-east-2b: 10.0.2.0/24)           │
#    │  ├── ALB / NLB (internet-facing load balancers)       │
#    │  ├── NAT Gateway (one per AZ for HA)                  │
#    │  └── Route: 0.0.0.0/0 → IGW                          │
#    │                                                       │
#    │  PRIVATE SUBNETS (us-east-2a: 10.0.10.0/24)          │
#    │                  (us-east-2b: 10.0.11.0/24)          │
#    │  ├── EKS worker nodes (NO public IPs)                 │
#    │  ├── Pods (get VPC IPs from same CIDR via vpc-cni)    │
#    │  ├── MySQL StatefulSet                                │
#    │  └── Route: 0.0.0.0/0 → NAT Gateway                  │
#    │       (outbound only: ECR pulls, STS, SQS, etc.)      │
#    └───────────────────────────────────────────────────────┘
#
#  INTERVIEW: "worker node can't pull ECR images in a private subnet?"
#    1. Missing NAT Gateway — no outbound route from private subnet
#    2. Missing VPC endpoints — ecr.api + ecr.dkr + s3 gateway endpoint
#    3. Security group — node SG must allow outbound 443
#    Diagnose: kubectl describe pod (ImagePullBackOff), kubectl logs aws-node-xxx
# =============================================================================

# locals {
#   azs = ["us-east-2a", "us-east-2b"]
# }
#
#
# # ---------------------------------------------------------------------------
# #  THE VPC
# # ---------------------------------------------------------------------------
# resource "aws_vpc" "ecom" {
#   cidr_block           = "10.0.0.0/16"
#   enable_dns_support   = true
#   enable_dns_hostnames = true  # required for EKS node registration
#   tags = {
#     Name    = "${var.cluster_name}-vpc"
#     Project = "ecom"
#   }
# }
#
# resource "aws_internet_gateway" "ecom" {
#   vpc_id = aws_vpc.ecom.id
#   tags = { Name = "${var.cluster_name}-igw" }
# }
#
#
# # ---------------------------------------------------------------------------
# #  PUBLIC SUBNETS — ALB + NAT Gateway live here
# # ---------------------------------------------------------------------------
# resource "aws_subnet" "public" {
#   count             = 2
#   vpc_id            = aws_vpc.ecom.id
#   cidr_block        = "10.0.${count.index + 1}.0/24"
#   availability_zone = local.azs[count.index]
#   map_public_ip_on_launch = true
#   tags = {
#     Name                     = "${var.cluster_name}-public-${local.azs[count.index]}"
#     "kubernetes.io/role/elb" = "1"  # AWS LB Controller: put internet-facing ALBs here
#   }
# }
#
#
# # ---------------------------------------------------------------------------
# #  PRIVATE SUBNETS — EKS nodes + pods live here
# # ---------------------------------------------------------------------------
# resource "aws_subnet" "private" {
#   count             = 2
#   vpc_id            = aws_vpc.ecom.id
#   cidr_block        = "10.0.${count.index + 10}.0/24"
#   availability_zone = local.azs[count.index]
#   tags = {
#     Name                              = "${var.cluster_name}-private-${local.azs[count.index]}"
#     "kubernetes.io/role/internal-elb" = "1"  # AWS LB Controller: internal ALBs here
#     "karpenter.sh/discovery"          = var.cluster_name  # Karpenter finds these subnets
#   }
# }
#
#
# # ---------------------------------------------------------------------------
# #  NAT GATEWAYS — one per AZ so a single AZ failure doesn't block all egress
# # ---------------------------------------------------------------------------
# resource "aws_eip" "nat" {
#   count  = 2
#   domain = "vpc"
#   tags = { Name = "${var.cluster_name}-nat-eip-${count.index}" }
# }
#
# resource "aws_nat_gateway" "ecom" {
#   count         = 2
#   allocation_id = aws_eip.nat[count.index].id
#   subnet_id     = aws_subnet.public[count.index].id  # NAT sits in PUBLIC subnet
#   tags = { Name = "${var.cluster_name}-nat-${count.index}" }
#   depends_on = [aws_internet_gateway.ecom]
# }
#
#
# # ---------------------------------------------------------------------------
# #  ROUTE TABLES
# #  Public:  0.0.0.0/0 → IGW (direct internet)
# #  Private: 0.0.0.0/0 → NAT Gateway (outbound only, no inbound from internet)
# # ---------------------------------------------------------------------------
# resource "aws_route_table" "public" {
#   vpc_id = aws_vpc.ecom.id
#   route {
#     cidr_block = "0.0.0.0/0"
#     gateway_id = aws_internet_gateway.ecom.id
#   }
#   tags = { Name = "${var.cluster_name}-public-rt" }
# }
#
# resource "aws_route_table" "private" {
#   count  = 2
#   vpc_id = aws_vpc.ecom.id
#   route {
#     cidr_block     = "0.0.0.0/0"
#     nat_gateway_id = aws_nat_gateway.ecom[count.index].id
#   }
#   tags = { Name = "${var.cluster_name}-private-rt-${count.index}" }
# }
#
# resource "aws_route_table_association" "public" {
#   count          = 2
#   subnet_id      = aws_subnet.public[count.index].id
#   route_table_id = aws_route_table.public.id
# }
#
# resource "aws_route_table_association" "private" {
#   count          = 2
#   subnet_id      = aws_subnet.private[count.index].id
#   route_table_id = aws_route_table.private[count.index].id
# }
#
#
# # ---------------------------------------------------------------------------
# #  VPC ENDPOINTS (optional but recommended for private clusters)
# #  Keeps ECR / S3 / STS traffic inside the VPC — no NAT needed for these.
# #  Without these, private-subnet nodes burn NAT bandwidth on every image pull.
# # ---------------------------------------------------------------------------
# data "aws_security_group" "default" {
#   vpc_id = aws_vpc.ecom.id
#   name   = "default"
# }
#
# # S3 Gateway endpoint — free, routes S3 traffic inside VPC (ECR layers live in S3)
# resource "aws_vpc_endpoint" "s3" {
#   vpc_id            = aws_vpc.ecom.id
#   service_name      = "com.amazonaws.${var.aws_region}.s3"
#   vpc_endpoint_type = "Gateway"
#   route_table_ids   = aws_route_table.private[*].id
#   tags = { Name = "${var.cluster_name}-s3-endpoint" }
# }
#
# # ECR API endpoint (Interface) — for docker login / manifest calls
# resource "aws_vpc_endpoint" "ecr_api" {
#   vpc_id              = aws_vpc.ecom.id
#   service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
#   vpc_endpoint_type   = "Interface"
#   subnet_ids          = aws_subnet.private[*].id
#   security_group_ids  = [data.aws_security_group.default.id]
#   private_dns_enabled = true
#   tags = { Name = "${var.cluster_name}-ecr-api-endpoint" }
# }
#
# # ECR DKR endpoint (Interface) — for actual image layer pulls
# resource "aws_vpc_endpoint" "ecr_dkr" {
#   vpc_id              = aws_vpc.ecom.id
#   service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
#   vpc_endpoint_type   = "Interface"
#   subnet_ids          = aws_subnet.private[*].id
#   security_group_ids  = [data.aws_security_group.default.id]
#   private_dns_enabled = true
#   tags = { Name = "${var.cluster_name}-ecr-dkr-endpoint" }
# }
#
# # STS endpoint — required for IRSA token exchange in private clusters
# resource "aws_vpc_endpoint" "sts" {
#   vpc_id              = aws_vpc.ecom.id
#   service_name        = "com.amazonaws.${var.aws_region}.sts"
#   vpc_endpoint_type   = "Interface"
#   subnet_ids          = aws_subnet.private[*].id
#   security_group_ids  = [data.aws_security_group.default.id]
#   private_dns_enabled = true
#   tags = { Name = "${var.cluster_name}-sts-endpoint" }
# }
