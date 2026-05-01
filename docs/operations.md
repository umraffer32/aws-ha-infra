# Operations

This document covers the practical commands and repo details needed to deploy, validate, and operate the project.

## Prerequisites

- AWS account with access to EC2, VPC, IAM, CloudWatch, CloudTrail, S3, Lambda, and EventBridge.
- Terraform `>= 1.6`.
- AWS CLI configured with SSO profile `mrpocket2726`, or override `var.aws_profile`.
- Existing IAM instance profile named `SSM-EC2` with SSM permissions and `ec2:ModifyInstanceAttribute` for NAT source/destination check handling.

Authenticate:

```bash
aws sso login --profile mrpocket2726
```

## Configuration

Root variables live in `variables.tf`.

| Variable | Default | Purpose |
|---|---|---|
| `region` | `us-west-2` | AWS region |
| `aws_profile` | `mrpocket2726` | Local AWS CLI/SSO profile |
| `project_name` | `ha` | Resource name prefix and tag value |
| `debian_version` | `13` | Debian major version for NAT AMI lookup |
| `ubuntu_version` | `24.04` | Ubuntu LTS version for private instance AMI lookup |

Override with CLI flags, a local `terraform.tfvars`, or `TF_VAR_` environment variables.

## Deployment

```bash
terraform init
terraform validate
terraform fmt -recursive
terraform plan
terraform apply
```

Teardown:

```bash
terraform destroy
```

## Validation

List NAT and private instances with the helper script:

```bash
./ssm-connect.sh
```

Verify SSM-managed instances:

```bash
aws ssm describe-instance-information \
  --profile mrpocket2726 \
  --region us-west-2 \
  --output table
```

Inspect VPC resources:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=ha" \
  --profile mrpocket2726

aws ec2 describe-route-tables \
  --filters "Name=tag:Project,Values=ha" \
  --profile mrpocket2726
```

Useful Terraform outputs include VPC ID, subnet IDs, NAT ASG names, private ASG names, CloudTrail log group, operations dashboard name, monitoring alarm names, and NAT route healer Lambda/EventBridge rule names.

## Repository Layout

```text
.
  main.tf
  variables.tf
  outputs.tf
  providers.tf
  data.tf
  ssm-connect.sh
  README.md
  docs/
  modules/
    network/
    compute/
    nat_route_healer/
    monitoring/
```

Module responsibilities:

- `modules/network/`: VPC, subnets, route tables, and network tags.
- `modules/compute/`: NAT instances, private instances, security groups, launch templates, ASGs, and private default routes.
- `modules/nat_route_healer/`: EventBridge, Lambda, IAM, and route replacement logic.
- `modules/monitoring/`: CloudTrail, CloudWatch Logs, metric filters, alarms, dashboard, and CloudTrail S3 backing bucket.

## Cost Management

Approximate monthly baseline for the current two-AZ demo shape:

| Resource | Estimate |
|---|---|
| VPC, subnets, route tables | $0 |
| NAT instances, `t2.micro` x2 | $0 during eligible Free Tier, about $17/month after |
| SSM agent | $0 |
| CloudWatch Logs and CloudTrail S3 | Low for this demo with 1-day retention, usage-dependent |

Run `terraform destroy` when the environment is not needed.

## Operational Gotchas

- The private route points to a NAT instance ENI, so route repair is needed whenever a NAT ASG replaces an instance.
- The route healer updates the route after launch, but NAT user data can still be running. A route can be active before packet forwarding is ready.
- EventBridge delivery is best effort. Alarms cover Lambda and EventBridge health, but there is no DLQ yet. Fallback is `terraform apply`.
- `terraform.tfstate` is committed for demo simplicity. Production should use an S3 backend with versioning and DynamoDB locking.
- The ASGs use min/max/desired of 1 per AZ, so there is a zero-instance gap during replacement.
- ASG health checks are EC2-level only. App-layer health checks will need ALB integration when the app tier is added.
