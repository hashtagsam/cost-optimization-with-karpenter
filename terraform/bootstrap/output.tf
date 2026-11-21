output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "plan_role_arn" {
  value = aws_iam_role.ci["plan"].arn
}

output "apply_role_arn" {
  value = aws_iam_role.ci["apply"].arn
}