output "lambda_name" {
  description = "Name of the Lambda that updates private routes when NAT instances relaunch"
  value       = aws_lambda_function.route_healer.function_name
}

output "lambda_arn" {
  description = "ARN of the Lambda that updates private routes when NAT instances relaunch"
  value       = aws_lambda_function.route_healer.arn
}

output "event_rule_name" {
  description = "EventBridge rule name that listens for NAT ASG launch events"
  value       = aws_cloudwatch_event_rule.nat_launch_success.name
}
