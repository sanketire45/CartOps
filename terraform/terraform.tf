# =============================================================================
#  terraform.tf  —  which "plugins" (providers) Terraform downloads
# =============================================================================
#  🖥️  SAME AS RUNNING BY HAND:   (nothing — this is setup, not an action)
#        it's like telling your laptop "install the AWS CLI, the kubectl/helm
#        tools, etc." BEFORE you can run any command.
#
#  📖  WHAT IT DOES, SIMPLY:
#        Terraform can't talk to AWS/Kubernetes/Helm on its own — it needs a
#        "provider" plugin for each. This file lists the 5 we use:
#          • aws        → create AWS things (EKS, IAM, VPC lookups)
#          • tls        → read the OIDC issuer's certificate (for oidc.tf)
#          • kubernetes → talk to the cluster's API
#          • helm       → install Helm charts into the cluster
#          • http       → download the LB-controller's IAM policy JSON
#        `terraform init` reads this file and downloads them.
# =============================================================================

terraform {
  # ---------------------------------------------------------------------------
  #  REMOTE STATE (todo #1) — store state in S3, lock with DynamoDB.
  #  🖥️ SAME AS: keeping terraform.tfstate on a shared, versioned, encrypted
  #     drive instead of your laptop, with a "do not disturb" lock so two
  #     applies can't run at once.
  #  ⚠️ Backend values MUST be literals (no var.*): Terraform reads the backend
  #     BEFORE it parses variables. When you switch AWS accounts, update the
  #     bucket name here AND re-run backend-bootstrap.sh.
  #  Create the bucket first:         bash backend-bootstrap.sh
  #  Then migrate local → S3:        terraform init -migrate-state
  # ---------------------------------------------------------------------------
  backend "s3" {
    bucket       = "ecom-tfstate-656022989575"   # created by backend-bootstrap.sh
    key          = "ecom/eks/terraform.tfstate"  # "folder" for THIS project's state
    region       = "us-east-2"
    use_lockfile = true   # S3 native locking (TF >=1.10 — replaces DynamoDB)
    encrypt      = true   # encrypt the state object at rest
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.65.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# Which AWS region everything is built in (comes from variables.tf).
# default_tags apply to EVERY AWS resource Terraform creates — no need to
# add tags = {} on each resource. Shows up in Cost Explorer grouped by Project.
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "ecom"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
