module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # API: private for nodes, public only from allow-listed IPs
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Access entries only (no aws-auth ConfigMap), no implicit admin for the creator
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  access_entries = {
    for i, arn in var.admin_principal_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # KMS envelope encryption of Secrets + full control-plane audit logs
  encryption_config = { resources = ["secrets"] }
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni = {
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" }) # enforce NetworkPolicies
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  ########################
  # EKS managed node group
  ########################

  # Small static Graviton group that runs Karpenter itself (it must never run
  # on nodes it manages). The taint keeps app pods off it.
  eks_managed_node_groups = {
    system = {
      ami_type       = "BOTTLEROCKET_ARM_64"
      instance_types = ["m7g.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { "karpenter.sh/controller" = "true", "node-role" = "system" }
      taints = {
        critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
      }
      # IMDSv2 only, hop limit 1: pods can't steal the node's IAM credentials
      metadata_options = { http_endpoint = "enabled", http_tokens = "required", http_put_response_hop_limit = 1 }
      # Session Manager instead of SSH
      iam_role_additional_policies = { ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" }
    }
  }

  node_security_group_tags = { "karpenter.sh/discovery" = local.name }
}


##################
# Karpenter module
##################
# Karpenter's AWS side: controller role (Pod Identity, tag-scoped EC2 rights),
# node role + access entry, SQS interruption queue + EventBridge rules.
# The Helm release is installed by `make karpenter`, so this stack never
# needs Kubernetes API access (CI can plan/apply it).
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0"

  cluster_name                    = module.eks.cluster_name
  create_pod_identity_association = true
  # Controller policy exceeds the 6,144-char managed-policy limit; inline allows 10,240
  enable_inline_policy = true

  node_iam_role_use_name_prefix     = false
  node_iam_role_name                = "${local.name}-karpenter-node"
  node_iam_role_additional_policies = { ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" }
}