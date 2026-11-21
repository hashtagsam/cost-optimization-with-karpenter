# 3-AZ VPC: nodes in private subnets, control-plane ENIs in intra subnets
# (no internet route), public subnets only for the NAT gateway.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name            = local.name
  cidr            = "10.20.0.0/16"
  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet("10.20.0.0/16", 4, i)]      # /20 - pods use VPC IPs
  public_subnets  = [for i, _ in local.azs : cidrsubnet("10.20.0.0/16", 8, i + 48)] # /24
  intra_subnets   = [for i, _ in local.azs : cidrsubnet("10.20.0.0/16", 8, i + 52)] # /24

  enable_nat_gateway = true
  single_nat_gateway = true # dev: cheap. prod: one per AZ

  map_public_ip_on_launch        = false
  manage_default_security_group  = true # strip all rules from the default SG
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Network forensics for incident response
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 30

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1, "karpenter.sh/discovery" = local.name }
}

# Free S3 gateway endpoint: ECR image layers come from S3, so image pulls
# (frequent when Karpenter churns nodes) skip NAT data-processing charges.
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.7.3"

  vpc_id = module.vpc.vpc_id
  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
  }
}