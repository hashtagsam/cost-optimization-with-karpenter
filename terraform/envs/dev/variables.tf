variable "project" {
  type    = string
  default = "karpenter-costopt"
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "endpoint_public_access_cidrs" {
  description = "IPs allowed to reach the EKS API, e.g. [\"81.2.69.142/32\"]."
  type        = list(string)
  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0 && !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "Give at least one CIDR, and never 0.0.0.0/0."
  }
}

variable "admin_principal_arns" {
  description = "IAM role/user ARNs that get cluster-admin (use the role ARN, not an assumed-role session ARN)."
  type        = list(string)
}

variable "create_spot_service_linked_role" {
  description = "Set false if AWSServiceRoleForEC2Spot already exists in the account."
  type        = bool
  default     = true
}

variable "budget_email" {
  description = "Email for the monthly budget alert. Empty = no budget."
  type        = string
  default     = ""
}