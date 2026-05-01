data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  monitoring_metric_namespace = "${var.project_name}/monitoring"
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.project_name}"
  retention_in_days = 1
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-after-1-day"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name = "${var.project_name}-cloudtrail-cw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "${var.project_name}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project_name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

resource "aws_cloudwatch_log_metric_filter" "cloudtrail_event_count" {
  name           = "${var.project_name}-cloudtrail-event-count"
  pattern        = "{ $.eventVersion = \"*\" }"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  metric_transformation {
    name          = "CloudTrailEventCount"
    namespace     = local.monitoring_metric_namespace
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "cloudtrail_ingestion_stalled" {
  alarm_name          = "${var.project_name}-cloudtrail-ingestion-stalled"
  alarm_description   = "CloudTrail events stopped flowing into ${aws_cloudwatch_log_group.cloudtrail.name}."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.cloudtrail_stalled_evaluation_periods
  datapoints_to_alarm = var.cloudtrail_stalled_datapoints_to_alarm
  threshold           = var.cloudtrail_stalled_threshold
  metric_name         = aws_cloudwatch_log_metric_filter.cloudtrail_event_count.metric_transformation[0].name
  namespace           = local.monitoring_metric_namespace
  statistic           = "Sum"
  period              = var.cloudtrail_stalled_period_seconds
  treat_missing_data  = "breaching"

  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions
}

resource "aws_cloudwatch_metric_alarm" "nat_route_healer_lambda_errors" {
  alarm_name          = "${var.project_name}-nat-route-healer-lambda-errors"
  alarm_description   = "NAT route healer Lambda reported errors."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.lambda_errors_evaluation_periods
  datapoints_to_alarm = var.lambda_errors_datapoints_to_alarm
  threshold           = var.lambda_errors_threshold
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  statistic           = "Sum"
  period              = var.lambda_errors_period_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.nat_route_healer_lambda_name
  }

  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions
}

resource "aws_cloudwatch_metric_alarm" "nat_route_healer_lambda_throttles" {
  alarm_name          = "${var.project_name}-nat-route-healer-lambda-throttles"
  alarm_description   = "NAT route healer Lambda was throttled."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.lambda_throttles_evaluation_periods
  datapoints_to_alarm = var.lambda_throttles_datapoints_to_alarm
  threshold           = var.lambda_throttles_threshold
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  statistic           = "Sum"
  period              = var.lambda_throttles_period_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.nat_route_healer_lambda_name
  }

  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions
}

resource "aws_cloudwatch_metric_alarm" "nat_launch_rule_failed_invocations" {
  alarm_name          = "${var.project_name}-nat-launch-rule-failed-invocations"
  alarm_description   = "EventBridge failed to invoke NAT route healer target."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.eventbridge_failed_invocations_evaluation_periods
  datapoints_to_alarm = var.eventbridge_failed_invocations_datapoints_to_alarm
  threshold           = var.eventbridge_failed_invocations_threshold
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  statistic           = "Sum"
  period              = var.eventbridge_failed_invocations_period_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = var.nat_route_healer_event_rule_name
  }

  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions
}

resource "aws_cloudwatch_metric_alarm" "nat_launch_rule_retry_pressure" {
  alarm_name          = "${var.project_name}-nat-launch-rule-retry-pressure"
  alarm_description   = "EventBridge retry attempts indicate delivery pressure for NAT healer invocations."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.eventbridge_retry_evaluation_periods
  datapoints_to_alarm = var.eventbridge_retry_datapoints_to_alarm
  threshold           = var.eventbridge_retry_threshold
  metric_name         = "RetryInvocationAttempts"
  namespace           = "AWS/Events"
  statistic           = "Sum"
  period              = var.eventbridge_retry_period_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = var.nat_route_healer_event_rule_name
  }

  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions
}

resource "aws_cloudwatch_dashboard" "operations" {
  dashboard_name = "${var.project_name}-operations"

  dashboard_body = jsonencode({
    start          = "-PT6H"
    periodOverride = "inherit"
    widgets = [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title  = "${var.project_name} Alarm Status"
          sortBy = "stateUpdatedTimestamp"
          alarms = [
            aws_cloudwatch_metric_alarm.cloudtrail_ingestion_stalled.arn,
            aws_cloudwatch_metric_alarm.nat_route_healer_lambda_errors.arn,
            aws_cloudwatch_metric_alarm.nat_route_healer_lambda_throttles.arn,
            aws_cloudwatch_metric_alarm.nat_launch_rule_failed_invocations.arn,
            aws_cloudwatch_metric_alarm.nat_launch_rule_retry_pressure.arn,
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "CloudTrail Event Flow"
          region = data.aws_region.current.name
          stat   = "Sum"
          period = 300
          metrics = [
            [
              local.monitoring_metric_namespace,
              aws_cloudwatch_log_metric_filter.cloudtrail_event_count.metric_transformation[0].name,
              {
                label = "CloudTrailEventCount"
              }
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "NAT Healer Lambda"
          region = data.aws_region.current.name
          stat   = "Sum"
          period = 60
          metrics = [
            [
              "AWS/Lambda",
              "Invocations",
              "FunctionName",
              var.nat_route_healer_lambda_name,
              {
                id    = "m_lambda_invocations"
                label = "Invocations"
              }
            ],
            [
              ".",
              "Errors",
              ".",
              ".",
              {
                id    = "m_lambda_errors"
                label = "Errors"
              }
            ],
            [
              ".",
              "Throttles",
              ".",
              ".",
              {
                id    = "m_lambda_throttles"
                label = "Throttles"
              }
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "EventBridge Delivery Health (NAT Launch Rule)"
          region = data.aws_region.current.name
          stat   = "Sum"
          period = 300
          metrics = [
            [
              "AWS/Events",
              "InvocationAttempts",
              "RuleName",
              var.nat_route_healer_event_rule_name,
              {
                id    = "m_attempts"
                label = "InvocationAttempts"
              }
            ],
            [
              ".",
              "SuccessfulInvocationAttempts",
              ".",
              ".",
              {
                id    = "m_success"
                label = "SuccessfulInvocationAttempts"
              }
            ],
            [
              ".",
              "FailedInvocations",
              ".",
              ".",
              {
                id    = "m_failed"
                label = "FailedInvocations"
              }
            ],
            [
              ".",
              "RetryInvocationAttempts",
              ".",
              ".",
              {
                id    = "m_retry"
                label = "RetryInvocationAttempts"
              }
            ],
            [
              {
                expression = "IF(m_attempts>0,100*m_success/m_attempts,100)"
                id         = "e_success_rate"
                label      = "SuccessfulInvocationRate %"
                yAxis      = "right"
              }
            ]
          ]
          yAxis = {
            right = {
              min = 0
              max = 100
            }
          }
        }
      }
    ]
  })
}
