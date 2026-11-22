variable "project" {
  type    = string
  default = "karpenter-costopt2"
  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project))
    error_message = "Lowercase letters, digits and hyphens, 3-24 chars (it becomes part of an S3 bucket name)."
  }
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "github_org" {
  description = "GitHub user or org that owns the repo."
  type        = string
}

variable "github_repo" {
  type    = string
  default = "cost-optimization-with-karpenter"
}

variable "github_environment" {
  description = "GitHub Environment (with required reviewers) allowed to use the apply role."
  type        = string
  default     = "dev"
}

# CI test: plan-on-PR check
