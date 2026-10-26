# =============================================================================
#  variables.tf  —  the tuneable knobs (set a value ONCE, use it everywhere)
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:   (nothing — these are just the SETTINGS the
#        other files read; like the flags you'd type on an eksctl command)
#
#  📖  WHAT IT DOES, SIMPLY:
#        Instead of hardcoding "wanderlust" or "c7i-flex.large" in many files,
#        define each once here and reference it as var.<name>. Change it in one
#        place → it changes everywhere. `default` = the value used if you don't
#        override it. Each EKS knob below maps to one eksctl flag.
# =============================================================================

variable "aws_region" {
  description = "AWS region where resources will be provisioned"
  default     = "us-east-2"
}

variable "ami_id" {
  description = "AMI ID for the Jenkins EC2 instance (see ec2.tf.bak — not managed here anymore)"
  default     = "ami-0b6d9d3d33ba97d99"
}

variable "instance_type" {
  description = "Instance type for the Jenkins EC2 instance"
  default     = "m7i-flex.large"

}

# ---------------------------------------------------------------------------
# EKS knobs  (each maps to one eksctl flag)
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "EKS cluster name (eksctl --name)"
  default     = "ecom"
}

variable "cluster_version" {
  description = "Kubernetes version for the control plane. NOTE (verified Sep 2026): latest EKS version is 1.36; standard support is ~1.34-1.36. Versions <= 1.33 are on EXTENDED support (extra $ surcharge) or retired. The tutorial used 1.30 — do NOT use it now. Pick a version your console lists under standard support; match this to what you actually create."
  default     = "1.34"
}

variable "node_instance_type" {
  description = "Worker node machine size. t3.medium = 2 vCPU / 4 GiB, general-purpose, burstable — good for dev/learning. Bump to t3.large (8 GiB) when adding monitoring stack (Prometheus+Grafana)."
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "How many worker nodes to start with (eksctl --nodes)"
  default     = 2
}

variable "node_min_size" {
  description = "Fewest worker nodes the group may scale to (eksctl --nodes-min)"
  default     = 2
}

variable "node_max_size" {
  description = "Most worker nodes the group may scale to (eksctl --nodes-max)"
  default     = 2
}

variable "node_volume_size" {
  description = "Root EBS disk size in GB per worker node (eksctl --node-volume-size)"
  default     = 20
}

# ---------------------------------------------------------------------------
# Cluster access (todo #4)
# ---------------------------------------------------------------------------
variable "extra_admin_role_arn" {
  description = "IAM role ARN to grant cluster-admin access (e.g. Jenkins CI role). Leave empty to skip."
  default     = ""
}

# ---------------------------------------------------------------------------
# ECR (todo #5) — one private repo per service
# ---------------------------------------------------------------------------
variable "ecr_repos" {
  description = "ECR repository names for each service (account/region come from the provider)"
  type        = map(string)
  default = {
    product  = "ecom-product-category"
    order    = "ecom-order-service"
    eureka   = "ecom-eureka-server"
    frontend = "ecom-frontend"
  }
}
