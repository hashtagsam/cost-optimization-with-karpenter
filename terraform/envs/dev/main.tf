terraform {
  required_version = ">= 1.10.0" # S3 native state locking

  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.59, < 7.0" } # EKS module v21 needs >= 6.59
  }

  # Partial config: bucket/region/kms_key_id come from backend.hcl
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  # Every resource gets cost-allocation tags (activate them in AWS Billing)
  default_tags {
    tags = { Project = var.project, Environment = "dev", ManagedBy = "terraform" }
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # no Local/Wavelength zones
  }
}

locals {
  name = "${var.project}-dev"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
}

####################
# Account guardrails
####################

# Every new EBS volume in this region is encrypted, Karpenter's included
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# EC2 needs this role before it will run Spot; it exists once per account
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_linked_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

# Cost guardrail for the lab itself
resource "aws_budgets_budget" "lab" {
  count        = var.budget_email == "" ? 0 : 1
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = "75"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}