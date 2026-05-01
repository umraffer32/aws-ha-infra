output "cloudtrail_log_group_name" {
  description = "CloudWatch log group receiving CloudTrail events"
  value       = aws_cloudwatch_log_group.cloudtrail.name
}

output "cloudtrail_trail_arn" {
  description = "ARN of the CloudTrail trail"
  value       = aws_cloudtrail.main.arn
}
