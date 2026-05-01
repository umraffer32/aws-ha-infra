variable "project_name" {
  description = "Short name used as a prefix for tagging and resource naming"
  type        = string
}

variable "nat_route_healer_lambda_name" {
  description = "Lambda function name for the NAT route healer"
  type        = string
}

variable "nat_route_healer_event_rule_name" {
  description = "EventBridge rule name that triggers NAT route healing"
  type        = string
}

variable "alarm_actions" {
  description = "List of ARNs to invoke when alarms enter ALARM"
  type        = list(string)
  default     = []
}

variable "ok_actions" {
  description = "List of ARNs to invoke when alarms return to OK"
  type        = list(string)
  default     = []
}

variable "insufficient_data_actions" {
  description = "List of ARNs to invoke when alarms enter INSUFFICIENT_DATA"
  type        = list(string)
  default     = []
}

variable "cloudtrail_stalled_period_seconds" {
  description = "Period for cloudtrail ingestion stalled alarm"
  type        = number
  default     = 300
}

variable "cloudtrail_stalled_evaluation_periods" {
  description = "Evaluation periods for cloudtrail ingestion stalled alarm"
  type        = number
  default     = 3
}

variable "cloudtrail_stalled_datapoints_to_alarm" {
  description = "Datapoints to alarm for cloudtrail ingestion stalled alarm"
  type        = number
  default     = 3
}

variable "cloudtrail_stalled_threshold" {
  description = "Threshold for cloudtrail ingestion stalled alarm"
  type        = number
  default     = 1
}

variable "lambda_errors_period_seconds" {
  description = "Period for nat route healer lambda errors alarm"
  type        = number
  default     = 60
}

variable "lambda_errors_evaluation_periods" {
  description = "Evaluation periods for nat route healer lambda errors alarm"
  type        = number
  default     = 1
}

variable "lambda_errors_datapoints_to_alarm" {
  description = "Datapoints to alarm for nat route healer lambda errors alarm"
  type        = number
  default     = 1
}

variable "lambda_errors_threshold" {
  description = "Threshold for nat route healer lambda errors alarm"
  type        = number
  default     = 1
}

variable "lambda_throttles_period_seconds" {
  description = "Period for nat route healer lambda throttles alarm"
  type        = number
  default     = 60
}

variable "lambda_throttles_evaluation_periods" {
  description = "Evaluation periods for nat route healer lambda throttles alarm"
  type        = number
  default     = 1
}

variable "lambda_throttles_datapoints_to_alarm" {
  description = "Datapoints to alarm for nat route healer lambda throttles alarm"
  type        = number
  default     = 1
}

variable "lambda_throttles_threshold" {
  description = "Threshold for nat route healer lambda throttles alarm"
  type        = number
  default     = 1
}

variable "eventbridge_failed_invocations_period_seconds" {
  description = "Period for eventbridge failed invocations alarm"
  type        = number
  default     = 60
}

variable "eventbridge_failed_invocations_evaluation_periods" {
  description = "Evaluation periods for eventbridge failed invocations alarm"
  type        = number
  default     = 1
}

variable "eventbridge_failed_invocations_datapoints_to_alarm" {
  description = "Datapoints to alarm for eventbridge failed invocations alarm"
  type        = number
  default     = 1
}

variable "eventbridge_failed_invocations_threshold" {
  description = "Threshold for eventbridge failed invocations alarm"
  type        = number
  default     = 1
}

variable "eventbridge_retry_period_seconds" {
  description = "Period for eventbridge retry pressure alarm"
  type        = number
  default     = 300
}

variable "eventbridge_retry_evaluation_periods" {
  description = "Evaluation periods for eventbridge retry pressure alarm"
  type        = number
  default     = 1
}

variable "eventbridge_retry_datapoints_to_alarm" {
  description = "Datapoints to alarm for eventbridge retry pressure alarm"
  type        = number
  default     = 1
}

variable "eventbridge_retry_threshold" {
  description = "Threshold for eventbridge retry pressure alarm"
  type        = number
  default     = 3
}
