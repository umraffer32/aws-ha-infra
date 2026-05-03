# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current State (2026-05-03)

- **Infra:** Up. 4 instances Online in SSM, RDS Multi-AZ available. Private instances updated (apt update/upgrade).
- **Last completed:** (1) `rds-sim.sh` run 4× — RDS Multi-AZ writer-unavailability **0:10.2**, return-to-available **1:18**. (2) Private instances patched: Private-2a all current, Private-2b kernel upgraded (6.17.0-1012→1013, reboot pending).
- **Earlier:** 3 full failure-sim matrix runs (avg 2:29 EC2 recovery); `ssm-check.sh` patched for zero-instance state; CLAUDE.md "Current State" section added as the canonical status surface.
- **Gotchas surfaced:** `psql --connect-timeout` is NOT a valid flag in psql 16 — use `PGCONNECT_TIMEOUT` env var. `DBInstances[0].AvailabilityZone` lags 3:00–6:00 after Multi-AZ failover; use `describe-events` (authoritative) or the probe (real-time) instead. SSM RunShellScript: use `apt` not `apt-get` for proper package handling.
- **Next:** ALB + app tier, VPC Flow Logs, Lambda DLQ, S3+DDB Terraform backend.

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

# Failure simulation (15-combo full matrix, ~30:00)
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
- **`modules/compute/`** — NAT and private launch templates, ASGs (one per AZ for both NAT and private), security groups, and `aws_route` resources for private default routes. At apply time, `data.aws_instance.nat_runtime` looks up the running NAT instance by Name tag and routes point to its primary ENI. NAT instances self-modify `source_dest_check = false` via IMDSv2 + `aws ec2 modify-instance-attribute` in user data — Terraform's `network_interfaces` block does not support this attribute.
- **`modules/nat_route_healer/`** — EventBridge rule watching `EC2 Instance Launch Successful` on NAT ASGs → Lambda → `ec2:ReplaceRoute`. Fixes the stale-route problem when ASG replaces a NAT instance (new ENI, old route). Lambda source is inlined as a Terraform `local` and zipped via the `archive` provider. No external Lambda files exist.
- **`modules/rds/`** — Multi-AZ PostgreSQL RDS instance in private subnets. Encrypted, no public access, 7-day backup retention. Security group allows port 5432 inbound only from the private instance security group. Credentials passed in via `terraform.tfvars` (`db_name`, `db_username`, `db_password`). Takes ~15:00–25:00 to provision; comment out `module "rds"` in `main.tf` to skip it during fast iteration.
- **`modules/monitoring/`** — CloudTrail (single-region, CW Logs delivery), CloudWatch metric filters, alarms for CloudTrail ingestion stall / Lambda errors+throttles / EventBridge failed+retry invocations, and an operations dashboard.

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
