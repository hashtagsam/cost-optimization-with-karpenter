# Read by the Makefile and passed to Helm/kubectl - never copied by hand
output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "karpenter_queue" {
  value = module.karpenter.queue_name
}

output "karpenter_node_role" {
  value = module.karpenter.node_iam_role_name
}