# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A multi-AZ AWS infrastructure for a highly available web application, deployed with Terraform. The stack prioritizes **cost efficiency within the AWS Free Tier** while maintaining HA across 2 availability zones.

**Current Status:** Network, compute, and audit logging layers are implemented. NAT instances and private Ubuntu instances run in per-AZ ASGs with SSM connectivity. NAT route self-healing uses EventBridge + Lambda. CloudTrail audit logging streams to CloudWatch Logs. Full resilience testing complete across all 9 failure combinations (55–158s recovery band). Database (RDS) and CloudWatch alarms are planned for future phases.

## Progress Update (2026-05-01)

- Added private compute capacity: two Ubuntu `t2.micro` instances (1 per AZ) via `aws_autoscaling_group.private` in `modules/compute/`.
- Added private route egress through NAT by creating per-AZ default routes in private route tables to each NAT instance ENI.
- Root module wiring now passes `private_subnet_ids`, `private_route_table_ids`, Debian AMI for NAT, and Ubuntu AMI for private instances into `module.compute`.
- Added `modules/compute/outputs.tf` and exported private/NAT ASG names and private security group in root `outputs.tf`.
- Updated `ssm-connect.sh` to list `Private-*` instances.
- Performed full environment recycle: `terraform destroy -auto-approve` then `terraform apply -auto-approve`.
- Verified private instance management channel via SSM by running commands on both private instances with `AWS-RunShellScript` and confirming successful output.
- Added `modules/nat_route_healer/` to automatically repair private default routes after NAT instance replacement:
  - EventBridge rule listens for `EC2 Instance Launch Successful` from the NAT ASGs.
  - Lambda resolves the launched NAT instance ENI and runs `ec2:ReplaceRoute` for the mapped private route table.
- **Repository state note (2026-05-01):** Baseline network/compute changes are committed and pushed to `main`.

## Progress Update (2026-05-01, session 3)

- Inspected live CloudWatch log groups via AWS CLI:
  - `/aws/cloudtrail/main`: ~922 events and rising
  - `/aws/lambda/main-nat-route-healer`: 102 events (last invocation ~04:04 UTC — NAT replacement in AZ-a, route updated to `eni-0ecb28f1d0a410baa` in `rtb-0b54737a38205fa69`)
- Measured CloudTrail ingestion rate: **~88 events/min** (active background log generation process running)
- Lambda healer log was quiet this session — no NAT replacements triggered
- Dominant CloudTrail event types observed: SSM `UpdateInstanceInformation` heartbeats, IAMUser console read calls (`DescribeRegions`, `ListApplications`, `ListZonalShifts`)

## Progress Update (2026-05-01, session 2)

- Added `modules/monitoring/` with CloudTrail trail → CloudWatch Logs:
  - CloudWatch log group `/aws/cloudtrail/main`, 1-day retention
  - S3 bucket `main-cloudtrail-<account-id>` (mandatory CloudTrail backing store), 1-day lifecycle expiration, public access blocked
  - IAM role allowing CloudTrail to write to the log group
  - Single-region trail, global service events enabled, log file validation enabled
- Wired `module.monitoring` into root `main.tf` and exported `cloudtrail_log_group_name` and `cloudtrail_trail_arn` in root `outputs.tf`
- Ran complete resilience test suite — all 9 failure combinations tested, 55–158s recovery band confirmed
- New scenarios added this session: single NAT only (76s), single private only (55s), NAT + same-AZ private without second NAT (131s), all 4 terminated (152s)

See README.md for detailed architectural decisions and trade-offs.

## File Structure

```
.
├── main.tf                      # Root module - orchestrates child modules
├── variables.tf                 # Root-level input variables (region, profile, AMI versions)
├── outputs.tf                   # VPC and network exports for downstream modules
├── providers.tf                 # AWS provider config (region, profile)
├── data.tf                      # AMI lookups (Debian 13, Ubuntu 24.04)
├── terraform.tfstate            # Current state (committed to git for this demo)
├── .terraform.lock.hcl          # Provider version lock
├── .gitignore                   # Standard Terraform/OS exclusions
├── README.md                    # Architecture decisions and trade-offs
├── CLAUDE.md                    # This file
│
├── modules/network/
│   ├── main.tf                  # VPC module instantiation + route tables
│   ├── variables.tf             # Network module inputs
│   └── outputs.tf               # VPC, subnet, route table exports
│
├── modules/compute/
│   ├── main.tf                  # NAT + private SGs, launch templates, per-AZ ASGs, private default routes via NAT
│   ├── variables.tf             # Compute module inputs
│   └── outputs.tf               # Compute exports (ASG names, private SG)
│
├── modules/nat_route_healer/
│   ├── main.tf                  # EventBridge + Lambda + IAM for automatic private-route repointing on NAT relaunch
│   ├── variables.tf             # Route-healer module inputs (ASG->route-table map)
│   └── outputs.tf               # Route-healer module outputs (lambda/rule names)
│
└── modules/monitoring/
    ├── main.tf                  # CloudTrail trail, CW log group, S3 bucket + policy, IAM role
    ├── variables.tf             # Monitoring module inputs (project_name)
    └── outputs.tf               # Monitoring exports (log group name, trail ARN)
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
| `debian_version` | `13` | Debian major version for NAT instance AMI |
| `ubuntu_version` | `24.04` | Ubuntu LTS version for future app AMIs |

**Override via:**
- CLI flags: `terraform apply -var region=us-east-1`
- File: Create `terraform.tfvars` (excluded from git; not committed)
- Environment: Set `TF_VAR_region=us-east-1`

## Architecture

### Current Implementation: Network + Compute Layers

The network module (`modules/network/`) instantiates the [terraform-aws-modules/vpc module](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/~5.0) with custom configurations:

```
VPC (10.0.0.0/16)
├── Public Subnets (IGW egress)
│   ├── AZ-1: 10.0.1.0/24  (NAT instance, ALB)
│   └── AZ-2: 10.0.2.0/24  (NAT instance, ALB)
│
└── Private Subnets (NAT instance egress)
    ├── AZ-1: 10.0.11.0/24 (app/database)
    └── AZ-2: 10.0.12.0/24 (app/database)
```

**Key settings in `modules/network/main.tf`:**
- `enable_nat_gateway = false` — NAT is managed via EC2 instances, not the managed service
- `enable_vpn_gateway = false` — VPN not in scope
- Route tables for public (→ IGW) and private (→ NAT) subnets
- Tagging with `Project`, `ManagedBy`, `Environment`

The compute module (`modules/compute/`) deploys both NAT and private instances:

- **Security group** (`aws_security_group.nat`): allows all inbound from VPC CIDR, all outbound
- **Security group** (`aws_security_group.private`): egress-only for private instances
- **Launch template** (`aws_launch_template.nat`): Debian 13 AMI, t2.micro, SSM profile (`SSM-EC2`), IMDSv2 enforced, user_data bootstraps NAT behavior
- **Launch template** (`aws_launch_template.private`): Ubuntu 24.04 AMI, t2.micro, SSM profile (`SSM-EC2`), IMDSv2 enforced
  - **Gotcha:** profile name is `SSM-EC2` (hyphen) — `SSM_EC2` (underscore) does not exist in this account
- **ASGs** (`aws_autoscaling_group.nat`): one per AZ (count = 2), min=max=desired=1, deployed in public subnets
- **ASGs** (`aws_autoscaling_group.private`): one per AZ (count = 2), min=max=desired=1, deployed in private subnets
- **Private routes** (`aws_route.private_default_via_nat`): one per AZ default route (`0.0.0.0/0`) to NAT instance ENI for private egress

The NAT route-healer module (`modules/nat_route_healer/`) mitigates route drift when NAT instances are replaced:

- **Event source**: Auto Scaling service event `EC2 Instance Launch Successful` filtered to NAT ASG names
- **Lambda action**: maps ASG name -> private route table ID, resolves launched NAT instance ENI, and calls `ec2:ReplaceRoute` for `0.0.0.0/0`
- **Outcome**: private subnets regain egress without requiring manual `terraform apply` after NAT replacement events

The monitoring module (`modules/monitoring/`) provides CloudTrail audit logging:

- **CloudTrail trail** (`aws_cloudtrail.main`): single-region, global service events included, log file validation enabled
- **CloudWatch log group** (`aws_cloudwatch_log_group.cloudtrail`): `/aws/cloudtrail/main`, 1-day retention
- **S3 bucket** (`aws_s3_bucket.cloudtrail`): mandatory CloudTrail backing store, `force_destroy = true`, 1-day lifecycle expiration, public access blocked
- **IAM role** (`aws_iam_role.cloudtrail_cloudwatch`): trust policy for `cloudtrail.amazonaws.com`, policy grants `logs:CreateLogStream` + `logs:PutLogEvents` on the log group
- **Note:** CloudTrail always requires an S3 bucket even when streaming to CW Logs — S3 is the mandatory backing store, CW Logs is additive

**user_data bootstrap sequence:**
1. Installs `amazon-ssm-agent` via `.deb` download (no apt repo needed)
2. Installs `iptables-persistent`
3. Enables `net.ipv4.ip_forward` via sysctl
4. Calls `aws ec2 modify-instance-attribute --no-source-dest-check` via IMDSv2 (instance self-disables SRC/DST check)
5. Adds iptables MASQUERADE + FORWARD rules and persists them

**Known issue:** `source_dest_check = false` inside `network_interfaces` block of launch template is commented out — the AWS provider does not support this field on launch templates. The workaround is the self-call in user_data, which requires the SSM-EC2 instance profile to have `ec2:ModifyInstanceAttribute` permission.

### Design Decisions

#### NAT Instances vs. Managed NAT Gateway

**Choice:** NAT Instances (t2.micro, Debian), one per AZ, bootstrapped via user_data.

**Why:** NAT Gateway costs ~$32/month per AZ. Two AZs = ~$65/month baseline. NAT Instances on t2.micro are fully free under the 12-month free tier (~$0), then ~$17/month after. This design trades **managed HA** and **operational simplicity** for **cost savings** that dominate in a portfolio/demo environment.

**Implementation:** See `modules/compute/main.tf`. The launch template user_data enables IPv4 forwarding, installs iptables-persistent, adds MASQUERADE rules, and self-disables source/dest check via the AWS API (since the Terraform launch template resource doesn't support `source_dest_check = false` in `network_interfaces`). One ASG per AZ (min=max=desired=1) provides per-AZ HA.

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

### Phase 1: Compute (Implemented)

- NAT instances via ASG (one per AZ) in public subnets — `modules/compute/`
- Private Ubuntu instances via ASG (one per AZ) in private subnets — `modules/compute/`
- Bootstrapped via user_data (IPv4 forwarding, iptables, SSM agent)
- IMDSv2 enforced, SSM instance profile for agent + self-modify SRC/DST check

**Still needed in compute phase:**
- App EC2 ASG in private subnets
- ALB in public subnets targeting the app ASG
- App security groups (ALB → App, App → RDS)
- App-specific outputs and wiring once ALB/target groups are introduced

### Phase 2: Database (Planned)

- RDS Multi-AZ PostgreSQL or MySQL in private subnets
- Parameter group, option group, subnet group
- Module: `modules/database/`

### Phase 3: Monitoring (Partial)

**Implemented:**
- CloudTrail trail → CloudWatch Logs (`modules/monitoring/`) — captures all API activity, SSM events, IAM/STS calls

**Still needed:**
- CloudWatch metric alarms (CPU, status checks, Lambda errors)
- VPC Flow Logs for network-level observability
- DLQ + alarm on route healer Lambda errors

## Known TODOs

1. **Terraform Deployment Role** (security follow-up)
   - Currently: Uses SSO `AdministratorAccess` session for Terraform
   - Should be: Assume a scoped `TerraformDeploy` role with `PowerUserAccess` + name-prefix-bounded IAM policy
   - Benefit: Principle of least privilege; prevents accidental infrastructure changes outside this project

2. **`source_dest_check` in launch template** (compute phase)
   - The Terraform `aws_launch_template` resource does not support `source_dest_check = false` within `network_interfaces`
   - Current workaround: user_data calls `aws ec2 modify-instance-attribute --no-source-dest-check` via IMDSv2
   - Requires: SSM-EC2 instance profile to have `ec2:ModifyInstanceAttribute` on `arn:aws:ec2:*:*:instance/*`
   - `modules/compute/main.tf` has the field commented out with an explanatory note
   - Observed during recreate testing: NAT instances may come up with `SourceDestCheck=True` initially; verify and remediate during post-apply checks if needed

3. **terraform.tfstate** in git (state management follow-up)
   - Current: Committed to git for demo/personal project simplicity
   - Production should use: S3 backend with versioning, DynamoDB lock table

4. **VPC Flow Logs** (monitoring phase)
   - Optional, but valuable for debugging network connectivity issues
   - Logs to CloudWatch Logs (cost: ~$0.50/GB in us-west-2)

5. **NAT route-healer observability** (reliability follow-up)
   - EventBridge delivery is best effort; keep a fallback runbook (`terraform apply`) if route updates lag or fail
   - Consider adding CloudWatch alarms/log metric filters for Lambda errors and DLQ integration

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

# List NAT + private instances and SSM session commands
./ssm-connect.sh

# Verify SSM-managed instances are online
aws ssm describe-instance-information --profile mrpocket2726 --region us-west-2 --output table
```

Or view in the AWS Console: VPC dashboard → Your VPCs → Filter by tag `Project=ha`.

## Cost Management

**Monthly estimate (2 AZs, free tier):**
- VPC, subnets, route tables: ~$0
- NAT Instances (t2.micro ×2): $0–$34/month (free for 12 months, then ~$17/month)
- SSM Agent: $0 (no additional charge for SSM on EC2)
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

## Resilience Testing

All tests terminated instances via `aws ec2 terminate-instances` and polled SSM with stale-ID filtering to confirm genuine replacements (not cached terminated IDs) came online.

**Baseline:** `terraform destroy` → `terraform apply` → all 4 instances online in **105s**.

### Complete Test Matrix

| Scenario | Recovery Time | Notes |
|---|---|---|
| Single private only | 55s | No NAT involvement; replacement just needs SSM agent registration |
| Single NAT only | 76s | Other AZ untouched; healer repoints route, one bootstrap to wait on |
| Both NATs only | 86s | Both healers fired independently; existing SSM sessions survived blackhole |
| Both privates only | 111s | NAT routes untouched throughout |
| NAT + same-AZ private (single NAT) | 131s | Private replacement blocked until its AZ NAT finished bootstrapping |
| NAT AZ-1 + Private AZ-1 (both NATs up) | 125s | Healer restored route before replacement private needed egress |
| NAT AZ-1 + Private AZ-2 (cross AZ) | 147s | AZ-2 private recovered independently through healthy AZ-2 NAT |
| Both NATs + one private | 120–158s | Tested both AZ combinations; range reflects NAT bootstrap variance |
| All 4 terminated | 152s | Full blackout 65s (T+43s–T+108s); no instances online during that window |

### Key Observations

**Recovery is gated on NAT bootstrap time.** The healer fires and updates the route within ~60–90s — well before NAT user_data completes. Routes go `active` pointing at valid ENIs before packets can flow. The healer eliminates manual `terraform apply`; it doesn't shorten the traffic blackout.

**Single-instance failures are fast.** Single private: 55s (no NAT dependency). Single NAT: 76s (one bootstrap, other AZ untouched). These are the most common real-world failure modes.

**SSM sessions are durable under NAT loss.** In every test where a private instance survived but lost its NAT, the SSM TCP session held through the full blackhole window — up to 123s with no egress.

**AZ isolation held across all 9 combinations.** AZ-2 failures never impacted AZ-1 recovery. The two ASGs and two healer invocations operated independently throughout.

**Recovery band: 55–158 seconds.** Floor is single-instance ASG replacement + SSM registration. Ceiling is NAT bootstrap time under worst-case all-4 termination.

## Current Status

As of 2026-05-01, the network, compute, and audit logging layers are complete. The full resilience test matrix (all 9 failure combinations) has been validated. CloudTrail audit logging is live and streaming to CloudWatch Logs.

Future phases (ALB, RDS, CloudWatch alarms) are documented but not actively planned — the primary goal of demonstrating NAT instance HA complexity and trade-offs has been achieved.
