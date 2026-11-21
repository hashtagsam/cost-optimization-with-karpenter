# Bootstrap: encrypted remote state + keyless GitHub Actions roles.
# Run once, locally, with admin credentials. Uses local state on purpose:
# it creates the bucket that every other stack stores its state in.

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform", Stack = "bootstrap" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  repo       = "${var.github_org}/${var.github_repo}"
}

#################
# KMS Key Policy
#################

data "aws_iam_policy_document" "state_kms" {
  #checkov:skip=CKV_AWS_109:Key policy - "*" means this key only
  #checkov:skip=CKV_AWS_111:Key policy - "*" means this key only
  #checkov:skip=CKV_AWS_356:Key policy - "*" means this key only
  #this key policy mean that the aws account has delegated control over this kms key (aws_kms_key.state)
  #The alternative is to use SSE-S3 encryption (it is free, simpler, but anyone with s3:GetObject can read the state)
  statement {
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform state for ${var.project}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.state_kms.json
}

#################
# S3 Bucket
#################
resource "aws_s3_bucket" "state" {
  bucket = "${var.project}-tfstate-${local.account_id}-${var.region}"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "tls_only" {
  statement {
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}


####################
# GitHub OIDC Trust
####################
# CI never holds AWS keys: GitHub mints a short-lived signed token, AWS
# trades it for 1-hour credentials only if the repo/branch/env matches.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan  = ["repo:${local.repo}:pull_request", "repo:${local.repo}:ref:refs/heads/main"]
    apply = ["repo:${local.repo}:environment:${var.github_environment}"]
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

####################
# Plan & Apply Roles
####################
# Plan role: runs untrusted PR code, so it may READ everything (incl. state)
# but explicit denies stop it reading data or secrets, or writing state.
data "aws_iam_policy_document" "plan_guardrails" {
  statement {
    sid       = "DecryptState" # ReadOnlyAccess has no kms:Decrypt
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.state.arn]
  }
  statement {
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue", "dynamodb:GetItem", "dynamodb:Query",
      "dynamodb:Scan", "sqs:ReceiveMessage", "lambda:GetFunction",
    ]
    resources = ["*"]
  }
  statement {
    effect        = "Deny"
    actions       = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    not_resources = ["arn:aws:ssm:*::parameter/aws/service/*"] # public AMI params stay readable
  }
  statement {
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    effect        = "Deny"
    actions       = ["kms:Decrypt"]
    not_resources = [aws_kms_key.state.arn]
  }
}

# Apply role: needs broad rights (it creates IAM roles), so explicit denies
# remove backdoors (users/keys), audit tampering and state-bucket changes.
data "aws_iam_policy_document" "apply_guardrails" {
  statement {
    effect = "Deny"
    actions = [
      "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile",
      "organizations:*", "account:*", "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail", "guardduty:DeleteDetector",
    ]
    resources = ["*"]
  }
  statement {
    effect    = "Deny"
    actions   = ["s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration"]
    resources = [aws_s3_bucket.state.arn]
  }
}

locals {
  roles = {
    plan  = { managed = "ReadOnlyAccess", guardrails = data.aws_iam_policy_document.plan_guardrails.json }
    apply = { managed = "AdministratorAccess", guardrails = data.aws_iam_policy_document.apply_guardrails.json }
  }
}

resource "aws_iam_role" "ci" {
  for_each             = local.roles
  name                 = "${var.project}-gha-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "ci" {
  #checkov:skip=CKV_AWS_274:Apply role creates IAM roles; limited by OIDC trust, approval gate and explicit denies
  for_each   = local.roles
  role       = aws_iam_role.ci[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value.managed}"
}

resource "aws_iam_role_policy" "guardrails" {
  for_each = local.roles
  name     = "guardrails"
  role     = aws_iam_role.ci[each.key].id
  policy   = each.value.guardrails
}