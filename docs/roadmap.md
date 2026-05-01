# Roadmap

The primary goal of demonstrating NAT instance high availability complexity is complete. The remaining work would make the project closer to a full application platform.

## App Tier

- Add an application Auto Scaling Group in private subnets.
- Add an Application Load Balancer in public subnets.
- Add target groups and ALB health checks.
- Add security groups for ALB to app and app to database traffic.
- Export app and ALB outputs for validation.

## Database

- Add an RDS Multi-AZ PostgreSQL or MySQL module.
- Add DB subnet group, parameter group, option group if needed, and security groups.
- Keep database subnets private.

## Monitoring

- Add VPC Flow Logs for network-level troubleshooting.
- Decide whether logs should land in CloudWatch Logs or S3.
- Add app-tier metrics and alarms after the app tier exists.

## Reliability

- Add a DLQ or equivalent failed-invocation capture path for the NAT route healer.
- Add a replay or runbook path for missed EventBridge/Lambda failures.
- Consider rolling replacement settings if zero-instance gaps become unacceptable.

## Security And State

- Replace broad SSO administrator deployment with a scoped Terraform deployment role.
- Move Terraform state from git to an S3 backend with versioning and DynamoDB locking.
- Review IAM permissions for name-prefix or tag-bounded access.
