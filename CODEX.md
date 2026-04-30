# CODEX.md

This file is the Codex init/context guide for this repository.

## Project Snapshot

- Terraform project for a highly available AWS web app foundation.
- Current implementation is network-only (VPC + subnets across 2 AZs).
- Cost-aware design for portfolio/demo usage, favoring free-tier-friendly choices.

## What Exists Today

Root module:
- `providers.tf`: Terraform `>= 1.6`, AWS provider `~> 5.0`
- `main.tf`: discovers available AZs and slices to first 2
- `variables.tf`: region/profile/project name + Debian/Ubuntu AMI version vars
- `data.tf`: AMI lookups for Debian and Ubuntu
- `outputs.tf`: exports VPC and subnet IDs from network module

Network module (`modules/network`):
- Uses `terraform-aws-modules/vpc/aws` `~> 5.0`
- VPC CIDR `10.0.0.0/16`
- Public subnets: `10.0.1.0/24`, `10.0.2.0/24`
- Private subnets: `10.0.11.0/24`, `10.0.12.0/24`
- `enable_nat_gateway = false`
- `enable_vpn_gateway = false`
- Tags: `Project`, `ManagedBy`, `Environment=dev`

## Important Reality Check

- README and CLAUDE docs describe NAT-instance strategy, ALB, and RDS as intended architecture.
- Those compute/database layers are not implemented yet in Terraform resources.
- `images/architecture.svg` currently labels NAT gateways; treat as conceptual diagram, not deployed state.

## Working Conventions

- Keep module layout consistent: `main.tf`, `variables.tf`, `outputs.tf`.
- Prefer passing inputs through root module variables/locals rather than hardcoding.
- Preserve tag conventions and `project_name`-based naming.
- Keep changes scoped and additive; avoid unrelated refactors.

## Local Workflow

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

For cost control:

```bash
terraform destroy
```

## Agent Guardrails

- Do not hand-edit `.terraform.lock.hcl` unless explicitly required.
- Do not introduce remote state/backend changes unless requested.
- If adding new layers (compute/database/monitoring), wire through outputs cleanly and document tradeoffs in README.
