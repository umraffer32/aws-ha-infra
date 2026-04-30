# AGENTS.md

Canonical agent guide for this repository.

## 1) Project Intent

This repo provisions a cost-conscious, highly available AWS foundation with Terraform.
Design goal: 2-AZ HA baseline while staying practical for free-tier/portfolio usage.

## 2) Current Implementation State

- Implemented: network layer (`modules/network`)
  - VPC + public/private subnets across 2 AZs
  - IGW + route tables
  - NAT Gateway disabled (`enable_nat_gateway = false`)

- Implemented: compute/NAT layer (`modules/compute`)
  - Security group: all-from-VPC inbound, all outbound
  - Launch template: Debian 13, t2.micro, SSM profile (`SSM-EC2`), IMDSv2 required
  - Per-AZ ASG (count=2), min=max=desired=1, deployed to public subnets
  - user_data bootstraps: SSM agent install, IPv4 forwarding, iptables MASQUERADE, self-disables SRC/DST check via `aws ec2 modify-instance-attribute`
  - `source_dest_check = false` in `network_interfaces` is commented out — Terraform launch template resource doesn't support it; workaround is the user_data self-call

- `data.tf`: AMI lookups for Debian 13 (owner `136693071363`) and Ubuntu 24.04 (owner `099720109477`)

- Not yet implemented: app ASG, ALB, database (RDS), monitoring
- `images/architecture.svg` is conceptual and may not match live resources exactly

## 3) Repo Layout

- `providers.tf`: Terraform + AWS provider constraints
- `main.tf`: root orchestration (`module.network`, `module.compute`, AZ discovery)
- `variables.tf`: root inputs (region, profile, project_name, debian_version, ubuntu_version)
- `outputs.tf`: root outputs (vpc_id, subnet IDs, AZs)
- `data.tf`: AMI lookups (Debian 13 and Ubuntu 24.04)
- `modules/network/{main,variables,outputs}.tf`: VPC module wrapper
- `modules/compute/{main,variables}.tf`: NAT ASG + launch template (no outputs.tf yet)
- `README.md`: architecture decisions and tradeoffs
- `CLAUDE.md` / `CODEX.md`: agent context

## 4) Defaults and Environment

- Terraform: `>= 1.6`
- AWS provider: `~> 5.0`
- Default region: `us-west-2`
- Default AWS profile: `mrpocket2726`
- Typical auth:
  - `aws sso login --profile mrpocket2726`

## 5) Working Rules

- Prefer small, scoped changes that match existing patterns.
- Keep module structure consistent: `main.tf`, `variables.tf`, `outputs.tf`.
- Do not hand-edit `.terraform.lock.hcl` unless required.
- Do not introduce remote backend/state changes unless explicitly requested.
- Update `README.md` when architectural behavior materially changes.

## 6) Terraform Runbook

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Cost cleanup:

```bash
terraform destroy
```

## 7) Compute/NAT Guardrails

- SSM instance profile name is `SSM-EC2` (hyphen). `SSM_EC2` (underscore) does not exist in this account.
- `source_dest_check = false` is NOT settable in a Terraform `aws_launch_template` `network_interfaces` block — the provider ignores/errors on it. Use user_data to self-call `aws ec2 modify-instance-attribute --no-source-dest-check`.
- The `SSM-EC2` profile must have `ec2:ModifyInstanceAttribute` to enable the above workaround.
- user_data installs the SSM agent from the S3 `.deb` URL (no apt repo required on Debian).
- SG for NAT instances is defined inside `modules/compute/main.tf`.

## 8) Planned Next Layers

- App EC2 ASG + ALB (complete the compute phase)
- Database (RDS Multi-AZ PostgreSQL or MySQL in private subnets)
- Monitoring (CloudWatch alarms, optional VPC Flow Logs)
