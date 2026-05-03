# Roadmap

The primary goal of demonstrating NAT instance high availability complexity is complete. The remaining work would make the project closer to a full application platform.

## Completed (2026-05-02)

- **AMI baking with Packer** — both NAT (Debian 13) and private (Ubuntu 24.04) instances now launch from pre-baked AMIs with all dependencies installed. Recovery time improved from ~2:34 average to ~2:25 average (-6%) across the 15-combo failure matrix.
- **RDS** — Multi-AZ PostgreSQL 16 on `db.t3.micro`, encrypted at rest, in private subnets with security group scoped to the private instance SG. Credentials managed via sensitive `terraform.tfvars` variable.
- **Monitoring** — CloudTrail trail with CloudWatch Logs delivery, metric filters, alarms (CloudTrail ingestion stall, Lambda errors/throttles, EventBridge failed/retry invocations), and a CloudWatch operations dashboard.

## App Tier

- Add an Application Load Balancer in public subnets.
- Add target groups and ALB health checks.
- Add security groups for ALB-to-app and app-to-RDS traffic.
- Export app and ALB outputs for validation.

## Monitoring (remaining)

- Add VPC Flow Logs for network-level troubleshooting.
- Add app-tier metrics and alarms after the app tier exists.

## Reliability

- Add a DLQ or equivalent failed-invocation capture path for the NAT route healer.
- Add a replay or runbook path for missed EventBridge/Lambda failures.
- Consider rolling replacement settings if zero-instance gaps become unacceptable.

## Security And State

- Replace broad SSO administrator deployment with a scoped Terraform deployment role.
- Move Terraform state from local-only usage to an S3 backend with versioning and DynamoDB locking.
- Review IAM permissions for name-prefix or tag-bounded access.
