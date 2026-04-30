# AGENTS.md

Canonical agent guide for this repository.

## 1) Project Intent

This repo provisions a cost-conscious, highly available AWS foundation with Terraform.
Design goal: 2-AZ HA baseline while staying practical for free-tier/portfolio usage.

## 2) Current Implementation State

- Implemented: network layer only (`modules/network`)
  - VPC + public/private subnets across 2 AZs
  - IGW + route tables
  - NAT Gateway disabled (`enable_nat_gateway = false`)
- Not currently present in repo: compute/database/monitoring modules
- `images/architecture.svg` is conceptual and may not match live resources exactly

## 3) Repo Layout

- `providers.tf`: Terraform + AWS provider constraints
- `main.tf`: root orchestration (`module.network`, AZ discovery)
- `variables.tf`: root inputs
- `outputs.tf`: root outputs
- `data.tf`: AMI lookups
- `modules/network/{main,variables,outputs}.tf`: VPC module wrapper
- `README.md`: architecture decisions and tradeoffs
- `CLAUDE.md` / `CODEX.md`: legacy/additional agent context

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

## 7) Compute/NAT Guardrails (When Added)

- If using SSM instance profile by name, account currently has: `SSM-EC2` (hyphen).
  - `SSM_EC2` (underscore) is invalid in this account.
- For NAT-style EC2 behavior:
  - set `source_dest_check = false`
  - bootstrap forwarding + iptables in `user_data`
- Keep SG resources outside compute files if that project convention is active.

## 8) Planned Next Layers

- Compute (EC2/ASG/ALB)
- Database (RDS Multi-AZ)
- Monitoring (CloudWatch, optional VPC Flow Logs)
