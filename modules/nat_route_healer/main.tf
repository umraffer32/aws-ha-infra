locals {
  nat_asg_names_sorted = sort(keys(var.nat_asg_to_private_route_table))

  lambda_source = <<-PY
    import json
    import logging
    import os
    import time

    import boto3

    LOG = logging.getLogger()
    LOG.setLevel(logging.INFO)

    EC2 = boto3.client("ec2")

    ASG_TO_ROUTE_TABLE = json.loads(os.environ["ASG_TO_ROUTE_TABLE"])
    DESTINATION_CIDR = os.environ.get("DESTINATION_CIDR", "0.0.0.0/0")
    DESCRIBE_RETRIES = 8
    DESCRIBE_SLEEP_SECONDS = 3


    def _get_primary_eni(instance_id):
      last_error = None
      for attempt in range(1, DESCRIBE_RETRIES + 1):
        try:
          response = EC2.describe_instances(InstanceIds=[instance_id])
          reservations = response.get("Reservations", [])
          if reservations and reservations[0].get("Instances"):
            network_interfaces = reservations[0]["Instances"][0].get("NetworkInterfaces", [])
            if network_interfaces:
              return network_interfaces[0]["NetworkInterfaceId"]
          last_error = RuntimeError(f"No instance data for {instance_id}")
        except Exception as exc:
          last_error = exc
        time.sleep(DESCRIBE_SLEEP_SECONDS)
      raise RuntimeError(f"Unable to resolve primary ENI for {instance_id}: {last_error}")


    def handler(event, _context):
      detail = event.get("detail", {})
      asg_name = detail.get("AutoScalingGroupName")
      instance_id = detail.get("EC2InstanceId")

      if asg_name not in ASG_TO_ROUTE_TABLE:
        LOG.info("Skipping event for unmanaged ASG: %s", asg_name)
        return {"status": "ignored", "reason": "unmanaged_asg", "asg_name": asg_name}

      if not instance_id:
        raise RuntimeError("Event missing detail.EC2InstanceId")

      route_table_id = ASG_TO_ROUTE_TABLE[asg_name]
      eni_id = _get_primary_eni(instance_id)

      EC2.replace_route(
        RouteTableId=route_table_id,
        DestinationCidrBlock=DESTINATION_CIDR,
        NetworkInterfaceId=eni_id,
      )

      LOG.info(
        "Updated route %s in %s to ENI %s for ASG %s (instance %s)",
        DESTINATION_CIDR,
        route_table_id,
        eni_id,
        asg_name,
        instance_id,
      )

      return {
        "status": "updated",
        "asg_name": asg_name,
        "instance_id": instance_id,
        "route_table_id": route_table_id,
        "network_interface_id": eni_id,
        "destination_cidr": DESTINATION_CIDR,
      }
  PY
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/${var.project_name}-nat-route-healer.zip"

  source {
    content  = local.lambda_source
    filename = "lambda_function.py"
  }
}

resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-nat-route-healer-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.project_name}-nat-route-healer-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRouteHealing"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:ReplaceRoute",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaLogging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "route_healer" {
  function_name = "${var.project_name}-nat-route-healer"
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "lambda_function.handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      ASG_TO_ROUTE_TABLE = jsonencode(var.nat_asg_to_private_route_table)
      DESTINATION_CIDR   = var.destination_cidr_block
    }
  }
}

resource "aws_cloudwatch_event_rule" "nat_launch_success" {
  name        = "${var.project_name}-nat-launch-success"
  description = "Triggers NAT route healing after NAT ASG instance replacement"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance Launch Successful"]
    detail = {
      AutoScalingGroupName = local.nat_asg_names_sorted
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.nat_launch_success.name
  target_id = "nat-route-healer"
  arn       = aws_lambda_function.route_healer.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.route_healer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nat_launch_success.arn
}
