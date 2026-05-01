output "cloudtrail_log_group_name" {
  description = "CloudWatch log group receiving CloudTrail events"
  value       = aws_cloudwatch_log_group.cloudtrail.name
}

output "cloudtrail_trail_arn" {
  description = "ARN of the CloudTrail trail"
  value       = aws_cloudtrail.main.arn
}

output "operations_dashboard_name" {
  description = "Name of the CloudWatch operations dashboard"
  value       = aws_cloudwatch_dashboard.operations.dashboard_name
}

output "alarm_arns" {
  description = "Map of CloudWatch alarm ARNs"
  value = {
    cloudtrail_ingestion_stalled       = aws_cloudwatch_metric_alarm.cloudtrail_ingestion_stalled.arn
    nat_route_healer_lambda_errors     = aws_cloudwatch_metric_alarm.nat_route_healer_lambda_errors.arn
    nat_route_healer_lambda_throttles  = aws_cloudwatch_metric_alarm.nat_route_healer_lambda_throttles.arn
    nat_launch_rule_failed_invocations = aws_cloudwatch_metric_alarm.nat_launch_rule_failed_invocations.arn
    nat_launch_rule_retry_pressure     = aws_cloudwatch_metric_alarm.nat_launch_rule_retry_pressure.arn
  }
}

output "alarm_names" {
  description = "Map of CloudWatch alarm names"
  value = {
    cloudtrail_ingestion_stalled       = aws_cloudwatch_metric_alarm.cloudtrail_ingestion_stalled.alarm_name
    nat_route_healer_lambda_errors     = aws_cloudwatch_metric_alarm.nat_route_healer_lambda_errors.alarm_name
    nat_route_healer_lambda_throttles  = aws_cloudwatch_metric_alarm.nat_route_healer_lambda_throttles.alarm_name
    nat_launch_rule_failed_invocations = aws_cloudwatch_metric_alarm.nat_launch_rule_failed_invocations.alarm_name
    nat_launch_rule_retry_pressure     = aws_cloudwatch_metric_alarm.nat_launch_rule_retry_pressure.alarm_name
  }
}
