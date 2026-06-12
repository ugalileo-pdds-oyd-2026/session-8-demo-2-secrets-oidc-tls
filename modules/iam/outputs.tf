output "compute_role_arn" {
  description = "ARN of the EC2 compute role"
  value       = aws_iam_role.compute.arn
}

output "compute_instance_profile_name" {
  description = "Name of the EC2 instance profile"
  value       = aws_iam_instance_profile.compute.name
}

output "ci_runner_role_arn" {
  description = "ARN of the CI runner role — used as role-to-assume in GitHub Actions"
  value       = aws_iam_role.ci_runner.arn
}
