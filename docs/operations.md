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
| `debian_version` | `13` | Debian major version used as Packer source AMI base for NAT images |
| `ubuntu_version` | `24.04` | Ubuntu LTS version used as Packer source AMI base for private images |
| `db_name` | `appdb` | Name of the initial PostgreSQL database |
| `db_username` | `appuser` | Master username for the PostgreSQL database |
| `db_password` | _(none)_ | Master password — must be set in `terraform.tfvars` (sensitive, never committed) |

Note: the compute module looks up live AMIs from self-owned baked images (`nat-instance-*` and `private-instance-*`), not directly from Debian/Ubuntu. These variables only control which base OS Packer builds on top of.

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
  nat-ami.pkr.hcl       # Packer build for NAT instances (Debian 13)
  private-ami.pkr.hcl   # Packer build for private instances (Ubuntu 24.04)
  failure-sim.sh         # 15-combo failure simulation script
  ssm-connect.sh
  README.md
  docs/
  modules/
    network/
    compute/
    nat_route_healer/
    rds/
    monitoring/
```

Module responsibilities:

- `modules/network/`: VPC, subnets, route tables, and network tags.
- `modules/compute/`: NAT instances, private instances, security groups, launch templates, ASGs, and private default routes.
- `modules/nat_route_healer/`: EventBridge, Lambda, IAM, and route replacement logic.
- `modules/rds/`: Multi-AZ PostgreSQL RDS instance, DB subnet group, and security group.
- `modules/monitoring/`: CloudTrail, CloudWatch Logs, metric filters, alarms, dashboard, and CloudTrail S3 backing bucket.

## AMI Management

NAT and private instances use pre-baked Packer AMIs. Rebuild when the base OS needs patching or dependencies change:

```bash
packer build nat-ami.pkr.hcl        # builds nat-instance-<timestamp>
packer build private-ami.pkr.hcl    # builds private-instance-<timestamp>
```

After a build completes, `terraform apply` picks up the new AMI automatically (data sources use `most_recent = true`). Existing instances are not replaced until you trigger an instance refresh:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name main-nat-asg-us-west-2a \
  --preferences '{"MinHealthyPercentage":0}' \
  --profile mrpocket2726 --region us-west-2

aws autoscaling start-instance-refresh \
  --auto-scaling-group-name main-nat-asg-us-west-2b \
  --preferences '{"MinHealthyPercentage":0}' \
  --profile mrpocket2726 --region us-west-2
```

Repeat for `main-private-asg-us-west-2a` and `main-private-asg-us-west-2b` for private instances.

## Cost Management

Approximate monthly baseline for the current two-AZ demo shape:

| Resource | Estimate |
|---|---|
| VPC, subnets, route tables | $0 |
| NAT instances, `t2.micro` x2 | $0 during eligible Free Tier, ~$17/month after |
| Private instances, `t2.micro` x2 | $0 during eligible Free Tier, ~$17/month after |
| RDS Multi-AZ `db.t3.micro`, 20 GiB gp2 | ~$26/month (not Free Tier eligible for Multi-AZ) |
| SSM agent | $0 |
| CloudWatch Logs and CloudTrail S3 | Low for this demo with 1-day retention, usage-dependent |

Run `terraform destroy` when the environment is not needed.

## Operational Gotchas

- The private route points to a NAT instance ENI, so route repair is needed whenever a NAT ASG replaces an instance.
- The route healer updates the route after launch, but NAT user data can still be running. A route can be active before packet forwarding is ready. With baked AMIs, user data runs in ~10-15s (runtime config only — no package installs), so this window is shorter than it used to be.
- EventBridge delivery is best effort. Alarms cover Lambda and EventBridge health, but there is no DLQ yet. Fallback is `terraform apply`.
- `terraform.tfstate` is committed for demo simplicity. Production should use an S3 backend with versioning and DynamoDB locking.
- The ASGs use min/max/desired of 1 per AZ, so there is a zero-instance gap during replacement.
- ASG health checks are EC2-level only. App-layer health checks will need ALB integration when the app tier is added.
- RDS Multi-AZ takes ~15–25 minutes to provision and ~30–45 minutes for a full destroy+apply cycle. Comment out `module "rds"` in `main.tf` to skip it when iterating on other parts of the stack.
- `db_password` must be set in `terraform.tfvars` and is gitignored. If it is missing, `terraform plan` will prompt interactively.
