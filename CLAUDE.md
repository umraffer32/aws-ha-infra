# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A multi-AZ AWS infrastructure for a highly available web application, deployed with Terraform. The stack prioritizes **cost efficiency within the AWS Free Tier** while maintaining HA across 2 availability zones.

**Current Status:** Network layer is implemented (VPC, subnets, NAT instances, route tables). Compute (EC2/ALB), database (RDS), and monitoring layers are planned for future phases.

See README.md for detailed architectural decisions and trade-offs.

## File Structure

```
.
├── main.tf                      # Root module - orchestrates child modules
├── variables.tf                 # Root-level input variables
├── outputs.tf                   # VPC and network exports for downstream modules
├── providers.tf                 # AWS provider config (region, profile)
├── terraform.tfstate            # Current state (committed to git for this demo)
├── .terraform.lock.hcl          # Provider version lock
├── .gitignore                   # Standard Terraform/OS exclusions
├── README.md                    # Architecture decisions and trade-offs
├── CLAUDE.md                    # This file
│
└── modules/network/
    ├── main.tf                  # VPC module instantiation + future networking
    ├── variables.tf             # Network module inputs
    └── outputs.tf               # VPC, subnet, route table exports
```

## Prerequisites

1. **AWS Account** with Free Tier eligible for t2.micro and basic VPC resources
2. **Terraform >= 1.6** (see `providers.tf` for version constraints)
3. **AWS CLI** configured with SSO profile `mrpocket2726`
   ```bash
   aws sso login --profile mrpocket2726
   ```
   (Or override `aws_profile` variable in `variables.tf` or via CLI)

## Terraform Quick Start

All commands assume working directory is the repository root.

```bash
# Validate configuration and download providers/modules
terraform init
terraform validate
terraform fmt -recursive

# Preview changes (always before apply)
terraform plan

# Deploy infrastructure
terraform apply

# Teardown everything (useful for free tier management)
terraform destroy
```

## Configuration

**Variables** are defined in `variables.tf`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `region` | `us-west-2` | AWS region |
| `aws_profile` | `mrpocket2726` | AWS CLI/SSO profile |
| `project_name` | `ha` | Resource name prefix and tag value |

**Override via:**
- CLI flags: `terraform apply -var region=us-east-1`
- File: Create `terraform.tfvars` (excluded from git; not committed)
- Environment: Set `TF_VAR_region=us-east-1`

## Architecture

### Current Implementation: Network Layer

The network module (`modules/network/`) instantiates the [terraform-aws-modules/vpc module](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/~5.0) with custom configurations:

```
VPC (10.0.0.0/16)
├── Public Subnets (IGW egress)
│   ├── AZ-1: 10.0.1.0/24  (for NAT instance, ALB)
│   └── AZ-2: 10.0.2.0/24  (for NAT instance, ALB)
│
└── Private Subnets (NAT instance egress)
    ├── AZ-1: 10.0.11.0/24 (for app/database)
    └── AZ-2: 10.0.12.0/24 (for app/database)
```

**Key settings in `modules/network/main.tf`:**
- `enable_nat_gateway = false` — we manage NAT via EC2 instances, not managed NAT Gateway
- `enable_vpn_gateway = false` — VPN not in scope
- Route tables created for public (→ IGW) and private (→ NAT) subnets
- Tagging with `Project`, `ManagedBy`, `Environment`

### Design Decisions

#### NAT Instances vs. Managed NAT Gateway

**Choice:** NAT Instances (t2.micro, Debian), one per AZ, bootstrapped via user_data.

**Why:** NAT Gateway costs ~$32/month per AZ. Two AZs = ~$65/month baseline. NAT Instances on t2.micro are fully free under the 12-month free tier (~$0), then ~$17/month after. This design trades **managed HA** and **operational simplicity** for **cost savings** that dominate in a portfolio/demo environment.

**Implementation details** (to be added to user_data when compute module is built):
- Enable IPv4 forwarding: `net.ipv4.ip_forward=1` in `/etc/sysctl.d/`
- Install and persist iptables MASQUERADE rule
- Set `source_dest_check = false` on the instance's ENI (AWS-level API setting required for NAT to function)
- Deploy in an Auto Scaling Group (min=max=desired=1 per AZ) for per-AZ HA

**Trade-offs accepted:**
- Instance failure requires EC2 recovery (vs. transparent failover with NAT Gateway)
- Operational ownership of AMI, patches, sizing
- Throughput limited by t2.micro burst budget

**When this flips:** In production with SLA-bound traffic, NAT Gateway becomes correct. Engineering time to operate an instance at 2am costs far more than $65/month.

#### 2 AZs vs. 3 AZs

**Choice:** 2 Availability Zones.

**Why:** ALB requires minimum 2 subnets in different AZs by design. RDS Multi-AZ (when added) is inherently 2-zone (primary + sync standby). The AWS Well-Architected Framework treats 2 AZs as the baseline that defines "HA" — adding a third AZ doesn't change the resilience bar.

**When 3 AZs would matter:**
- **Quorum systems** (etcd, Kafka, Consul) — with 3 nodes across 3 AZs, losing 1 AZ leaves a majority. With 2 nodes, you lose quorum.
- **Read-heavy replicas** — spreading across 3 AZs reduces client-to-replica latency variance.
- **Regulatory requirements** — some compliance frameworks mandate >2 AZ redundancy.

**Why not 3 AZs here:** This stack is a stateless web app (ALB) + managed database (RDS). Neither has a quorum requirement. A third AZ would mean a third NAT instance, third route tables, third set of subnets — roughly 50% more cost for zero additional resilience the workload can use.

**When this flips:** If we add a self-managed consensus system (e.g., a Kafka cluster for event streaming), 3 AZs becomes correct immediately.

#### ALB vs. NLB

**Planned choice:** Application Load Balancer (ALB).

**Why:** HTTP application workload. ALB operates at Layer 7 (HTTP/HTTPS), enabling path-based routing, hostname routing, TLS termination, and HTTP-aware health checks. It integrates natively with EC2 Auto Scaling Groups.

**Why not NLB:** NLB operates at Layer 4 (TCP/UDP). It's correct for non-HTTP protocols, ultra-high throughput (millions of rps, sub-millisecond latency), or when downstream systems need a static IP. This workload doesn't need any of those.

**When this flips:** If we fronted a game server, MQTT broker, or database proxy, NLB would become correct.

## Future Phases

### Phase 1: Compute (Planned)

- EC2 Auto Scaling Group in private subnets (one per AZ)
- Application Load Balancer in public subnets, targets the ASG
- Security groups (ALB → App, App → RDS)
- Module: `modules/compute/`

### Phase 2: Database (Planned)

- RDS Multi-AZ PostgreSQL or MySQL in private subnets
- Parameter group, option group, subnet group
- Module: `modules/database/`

### Phase 3: Monitoring (Planned)

- CloudWatch Log Groups and Alarms
- Optional: VPC Flow Logs for network observability
- Module: `modules/monitoring/`

## Known TODOs

1. **Terraform Deployment Role** (security follow-up)
   - Currently: Uses SSO `AdministratorAccess` session for Terraform
   - Should be: Assume a scoped `TerraformDeploy` role with `PowerUserAccess` + name-prefix-bounded IAM policy
   - Benefit: Principle of least privilege; prevents accidental infrastructure changes outside this project

2. **NAT Instance Bootstrapping** (compute phase)
   - User_data script to enable IPv4 forwarding, install iptables, persist rules
   - Set `source_dest_check = false` on ENI in Terraform
   - Auto Scaling Group (min=max=desired=1 per AZ)

3. **terraform.tfstate** in git (state management follow-up)
   - Current: Committed to git for demo/personal project simplicity
   - Production should use: S3 backend with versioning, DynamoDB lock table

4. **VPC Flow Logs** (monitoring phase)
   - Optional, but valuable for debugging network connectivity issues
   - Logs to CloudWatch Logs (cost: ~$0.50/GB in us-west-2)

## Adding New Infrastructure

When adding compute, database, or monitoring layers:

1. Create `modules/[component]/` with:
   - `main.tf` — resource definitions
   - `variables.tf` — inputs from root module
   - `outputs.tf` — exports to root outputs or other modules

2. Add module call in root `main.tf`:
   ```hcl
   module "compute" {
     source = "./modules/compute"
     
     vpc_id            = module.network.vpc_id
     private_subnet_ids = module.network.private_subnet_ids
     azs               = local.azs
     project_name      = var.project_name
   }
   ```

3. Export outputs in root `outputs.tf` for upstream consumers or debugging

4. Document architectural trade-offs in README.md alongside the implementation

5. Update this CLAUDE.md with implementation details

## Testing & Validation

After `terraform apply`:

```bash
# Verify VPC created
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=ha" --profile mrpocket2726

# List subnets
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<VPC_ID>" --profile mrpocket2726

# Check route tables
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=<VPC_ID>" --profile mrpocket2726
```

Or view in the AWS Console: VPC dashboard → Your VPCs → Filter by tag `Project=ha`.

## Cost Management

**Monthly estimate (2 AZs, free tier):**
- VPC, subnets, route tables: ~$0
- NAT Instances (t2.micro ×2): $0–$34/month (free for 12 months, then ~$17/month)
- **Total:** $0–$34/month

**To teardown and save costs:**
```bash
terraform destroy
```

This is safe because state is tracked in git. You can reapply anytime.

## References

- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/~5.0)
- [AWS Well-Architected Framework — Reliability Pillar](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
- [NAT Instance vs. NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-comparison.html)
