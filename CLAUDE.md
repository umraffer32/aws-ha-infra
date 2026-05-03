# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

```bash
# Auth
aws sso login --profile mrpocket2726

# Terraform
terraform init
terraform plan
terraform apply
terraform destroy

# Packer (rebuild baked AMIs — run before terraform apply to pick up new image)
packer build nat-ami.pkr.hcl
packer build private-ami.pkr.hcl

# Verify SSM connectivity
aws ssm describe-instance-information \
  --profile mrpocket2726 --region us-west-2 \
  --query "InstanceInformationList[].{ID:InstanceId,Ping:PingStatus}" \
  --output table

# Failure simulation (15-combo full matrix, ~30 min)
bash failure-sim.sh

# Instance refresh after AMI rebuild
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name main-nat-asg-us-west-2a \
  --preferences '{"MinHealthyPercentage":0}' \
  --profile mrpocket2726 --region us-west-2
```

## Architecture

Two-AZ AWS stack demonstrating self-managed NAT instances as a NAT Gateway replacement. The core engineering challenge: ASG-managed NAT instances get new ENIs on replacement, so private route tables point at stale targets. The route healer solves this automatically.

### Module Responsibilities

- **`modules/network/`** — VPC, subnets, route tables. Private route tables are created here but their default routes are managed by `modules/compute/` (because the target is the live NAT ENI, known only after instances start).
- **`modules/compute/`** — NAT and private launch templates, ASGs, security groups, and `aws_route` resources for private default routes. NAT instances self-modify `source_dest_check = false` via IMDSv2 + `aws ec2 modify-instance-attribute` in user data — Terraform's `network_interfaces` block does not support this attribute.
- **`modules/nat_route_healer/`** — EventBridge rule watching `EC2 Instance Launch Successful` on NAT ASGs → Lambda → `ec2:ReplaceRoute`. The Lambda source is inlined as a Terraform `local` and zipped via the `archive` provider. No external Lambda files exist.
- **`modules/monitoring/`** — CloudTrail, CloudWatch log group, metric filters, alarms, and operations dashboard.

### AMI Strategy

Both instance types use Packer-baked self-owned AMIs (not vanilla OS images) to minimize boot time:
- `nat-ami.pkr.hcl` → `nat-instance-*` (Debian 13, awscli + iptables-persistent + SSM agent pre-installed)
- `private-ami.pkr.hcl` → `private-instance-*` (Ubuntu 24.04, SSM agent snap pre-initialized)
- `data.tf` looks up the latest self-owned image matching each name pattern

### Key Wiring in `main.tf`

The `nat_route_healer` module receives a map of `asg_name → route_table_id` built inline from compute and network outputs. This is how the Lambda knows which route table to repair for each NAT ASG.

### Account-Specific Notes

- AWS profile: `mrpocket2726`
- Region: `us-west-2`
- IAM instance profile: `SSM-EC2` (hyphen, not underscore) — required for both NAT and private instances
- `terraform.tfvars` sets `project_name = "main"` (overrides the `"ha"` default)
- `terraform.tfstate` is local and gitignored — no remote backend
