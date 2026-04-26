# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A multi-AZ AWS infrastructure for a highly available web application, deployed with Terraform. The stack prioritizes **cost efficiency within the free tier** while maintaining HA across 2 availability zones. See README.md for detailed architectural decisions (NAT Instance vs NAT Gateway, ALB vs NLB, 2 vs 3 AZs) and their trade-offs.

## Terraform Commands

**Prerequisites:** AWS CLI configured with SSO profile `mrpocket2726` (or override `aws_profile` in variables).

```bash
# Initialize and download providers/modules
terraform init

# Format all Terraform files
terraform fmt -recursive

# Validate configuration
terraform validate

# Preview changes
terraform plan

# Apply infrastructure changes
terraform apply

# Destroy entire stack (useful for cleaning up free tier demo)
terraform destroy
```

**Configuration:** See `variables.tf` for defaults (`region=us-west-2`, `project_name=ha`). Override via CLI flags (`-var region=...`) or `terraform.tfvars` (excluded from git).

## Architecture

```
Root Terraform (main.tf)
└── modules/network/
    ├── VPC (public/private subnets across 2 AZs)
    ├── NAT Instances (t2.micro, one per AZ in ASG)
    ├── Route tables (public routes to IGW, private routes to NAT)
    └── (Future: ALB, RDS, compute tier)
```

### Key Implementation Details

**NAT Instance Bootstrapping:** The `modules/network/` implements NAT via EC2 user_data scripts, not managed NAT Gateway:
- Enables IPv4 forwarding on Debian instances
- Installs and persists iptables MASQUERADE rules
- Sets `source_dest_check = false` on the ENI (required for NAT to work at AWS API level)
- Auto Scaling Group with `min=max=desired=1` per AZ provides per-AZ HA

This design trades operational ownership (you manage AMI, patches, sizing) for ~$65/month savings vs managed NAT Gateway when running cost-free under the AWS Free Tier.

**2 AZs, Not 3:** The ALB and RDS Multi-AZ each define their resilience against 2-AZ failures. Adding a 3rd AZ would increase cost and complexity without matching the workload's actual fault domain. See README.md section "2 AZs vs 3 AZs" for when this flips.

## Known TODOs

- **Terraform deployment role:** Currently authenticates via SSO `AdministratorAccess` session. Should assume a scoped `TerraformDeploy` role with `PowerUserAccess` + name-prefix-bounded IAM policy. Track this as a follow-up.

## State Management

- **terraform.tfstate:** Committed to git for simplicity in a demo/personal project. In production, move to S3 with versioning and locking.
- **.gitignore:** Excludes `*.tfvars`, `*.tfstate.*`, `.terraform/`, and editor configs. Sensitive values should never appear in code.

## Adding New Infrastructure

New tiers (compute, database, monitoring) should follow this pattern:
1. Create `modules/[component]/` with `main.tf`, `variables.tf`, `outputs.tf`
2. Add the module call in root `main.tf` (or organize into layers if scope grows)
3. Export outputs through `outputs.tf` for downstream use
4. Document architectural trade-offs in README.md alongside implementation
