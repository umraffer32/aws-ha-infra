# Highly Available AWS Infrastructure Without a NAT Gateway

A multi-AZ AWS infrastructure deployed with Terraform, built to explore what it actually takes to maintain high availability when you don't use managed services for the hard parts. The central question: how much engineering does a NAT Gateway abstract away, and is the cheaper alternative viable?

![Architecture diagram](images/architecture.svg)

## What This Is

The stack runs two Availability Zones with public and private subnets, NAT instances (instead of NAT Gateway), and private Ubuntu instances managed by Auto Scaling Groups. All access is through AWS SSM — no open ports, no keypairs.

The interesting part is not the infrastructure itself. It's the `modules/nat_route_healer/` — a Lambda-backed self-healing system built to solve the core problem with NAT instances: when one dies and its ASG launches a replacement, the private route table still points at a dead ENI. Without intervention, egress from that AZ is broken until someone runs `terraform apply`. The healer eliminates that manual step.

```
VPC (10.0.0.0/16)
├── Public Subnets
│   ├── AZ-1: 10.0.1.0/24   — NAT instance (Debian t2.micro, ASG-managed)
│   └── AZ-2: 10.0.2.0/24   — NAT instance (Debian t2.micro, ASG-managed)
│
└── Private Subnets
    ├── AZ-1: 10.0.11.0/24  — Ubuntu t2.micro instance (ASG-managed)
    └── AZ-2: 10.0.12.0/24  — Ubuntu t2.micro instance (ASG-managed)
```

## Stack

| Layer | Technology |
|---|---|
| Infrastructure as Code | Terraform (modular) |
| NAT | Debian 13 t2.micro instances, one per AZ, ASG-managed |
| Private Compute | Ubuntu 24.04 t2.micro instances, one per AZ, ASG-managed |
| Route Self-Healing | EventBridge + Lambda (`modules/nat_route_healer/`) |
| Instance Access | AWS SSM Session Manager (no SSH, no keypairs) |
| Audit Logging | CloudTrail → CloudWatch Logs (`/aws/cloudtrail/main`) |
| Load Balancing | ALB (planned) |
| Database | RDS Multi-AZ (planned) |

## The NAT Instance Problem

NAT Gateway is a fully managed, internally redundant AWS service. It costs $0.045/hour per AZ — roughly $32/month per AZ, or $65/month for two. It handles its own failover transparently and requires no operational care.

NAT instances on t2.micro are free under the AWS 12-month free tier, then roughly $8.50/month each. For a portfolio project with frequent teardowns, the cost difference dominates.

The problem is that NAT instances aren't transparently HA. The instance is the NAT. When it dies:

1. The ASG detects the failure and launches a replacement — this is automatic.
2. The replacement gets a new primary ENI with a new ENI ID.
3. The private route table still has a `0.0.0.0/0` entry pointing at the old, now-gone ENI.
4. That route goes `blackhole`. All outbound traffic from the private subnet stops.
5. Nothing fixes this automatically — the route just stays broken.

The standard remedy is `terraform apply`, which re-reads the live NAT instance ENI and updates the route. In production that means an on-call page, a human, and however long it takes them to respond.

## The Route Healer

`modules/nat_route_healer/` closes this gap without human intervention.

**How it works:**

1. EventBridge listens for `EC2 Instance Launch Successful` events from the NAT ASGs.
2. When a NAT ASG launches a replacement instance, EventBridge invokes a Lambda.
3. The Lambda maps the ASG name to the corresponding private route table (passed in as a variable at deploy time).
4. It resolves the new instance's primary ENI ID via `describe-instances`, with a retry loop (8 attempts, 3s sleep) to handle the brief window between EC2 launch and metadata availability.
5. It calls `ec2:ReplaceRoute` to update the `0.0.0.0/0` entry in the private route table.
6. Private subnet egress resumes without any human action.

**What it doesn't do:** The route is updated when the ASG fires the launch event — not when the NAT instance is actually ready to forward traffic. NAT user_data takes several minutes to complete (apt installs, iptables setup, source/dest check disable). So there's a window where the route is `active` pointing at a valid ENI, but the NAT instance itself isn't yet forwarding packets. This is a known limitation of the NAT instance approach, not a healer bug.

## Audit Logging

`modules/monitoring/` ships a CloudTrail trail that streams all AWS API activity into CloudWatch Logs.

**What it captures:** Every API call made against the account in us-west-2 — EC2 instance launches and terminations, SSM session starts and command invocations, IAM/STS credential activity, S3 access, and CloudTrail self-queries. Global service events (IAM, STS) are included.

**Where it lands:** CloudWatch Logs log group `/aws/cloudtrail/main`, 1-day retention. A backing S3 bucket (`main-cloudtrail-<account-id>`) stores raw trail data with a matching 1-day lifecycle expiration.

**Volume observed:** 920+ CloudTrail events and 102 Lambda healer events as of 2026-05-01, with CloudTrail ingesting at ~88 events/min under active load. Dominant event types: SSM `UpdateInstanceInformation` heartbeats, IAMUser console reads (`DescribeRegions`, `ListApplications`), and STS `AssumeRole` calls — with spikes during failure simulations as instances terminate, re-register, and the route healer Lambda fires.

## NAT Instance Bootstrap

Each NAT instance runs this sequence on first boot via user_data:

1. `apt update && apt install awscli iptables-persistent` — installs dependencies
2. Download and install `amazon-ssm-agent` from the S3 distribution endpoint
3. `sysctl net.ipv4.ip_forward=1` — enables IP forwarding
4. Self-call to `aws ec2 modify-instance-attribute --no-source-dest-check` via IMDSv2 — disables source/dest check on its own ENI. This is required because the Terraform `aws_launch_template` resource doesn't support `source_dest_check = false` in the `network_interfaces` block.
5. `iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE` + FORWARD rules, saved via `netfilter-persistent`

This bootstrap is why recovery takes 2–5 minutes rather than seconds. The route can be fixed in ~90s; the NAT instance itself takes longer to be ready.

## Design Decisions

### NAT Instances over NAT Gateway

**For this project:** NAT Gateway costs $65/month baseline for two AZs, before data transfer. NAT instances on t2.micro are free for 12 months, then ~$17/month for the pair. For a portfolio environment that gets torn down frequently, the cost difference dominates.

**The real trade-off is operational complexity, not money.** The healer, the IMDSv2 self-modify workaround, the ENI retry loop, the iptables bootstrap — all of that exists to approximate what NAT Gateway provides natively. See the "What NAT Gateway Would Delete" section for the full accounting.

**In production:** NAT Gateway is correct once real traffic and SLAs are involved. An on-call engineer debugging a blackhole route at 2am costs more than $65/month in engineering time alone. The crossover happens well before production scale.

### 2 AZs over 3

ALB requires a minimum of 2 AZs. RDS Multi-AZ is inherently 2-zone. The AWS Well-Architected Framework treats 2 AZs as the HA baseline for stateless web applications.

A third AZ only buys something for quorum-based systems — etcd, Kafka, Consul — where losing one AZ with 2 nodes loses quorum, but with 3 nodes a majority survives. This stack has no quorum requirements. Adding a third AZ here would mean a third NAT instance, third route tables, third set of subnets — roughly 50% more cost for zero additional resilience the workload can use.

### SSM over SSH

No port 22, no keypairs, no bastion host. IAM policies control who can start sessions and which instances they can reach. Sessions are logged via CloudWatch. Private instances have no inbound security group rules at all — their security group only allows outbound traffic.

### ALB over NLB (planned)

HTTP workload — ALB is the correct choice. Layer 7 routing, TLS termination, path and hostname-based routing, HTTP-aware health checks, native ASG integration. NLB is for non-HTTP protocols or when downstream systems need a static IP. Neither applies here.

## Resilience Testing

A full battery of failure injection tests was run against the live stack to validate recovery behavior. All tests terminated instances via the AWS CLI and measured time to full SSM connectivity restoration, with stale-ID filtering to ensure replacement instances (not cached terminated ones) were counted.

**Baseline:** `terraform destroy` → `terraform apply` → all 4 instances online in **105 seconds** (28s after apply completed).

### Test Results

| Scenario | Recovery Time | Notes |
|---|---|---|
| Single private only | 55s | Fastest result — no NAT involvement, replacement just needs SSM agent to register |
| Single NAT only | 76s | Other AZ fully healthy; healer repoints route, one bootstrap to wait on |
| Both NATs only | 86s | Both healers fired independently; existing SSM sessions survived full blackhole |
| Both privates only | 111s | NAT untouched; routes stayed active throughout |
| NAT + same-AZ private (one NAT) | 131s | Private-a replacement blocked until its AZ-a NAT finished bootstrapping |
| NAT AZ-1 + Private AZ-1 (same AZ, both NATs) | 125s | Healer restored route before replacement private needed egress |
| NAT AZ-1 + Private AZ-2 (cross AZ) | 147s | AZ-2 private recovered independently through its healthy NAT |
| Both NATs + one private | 120–158s | Tested both AZ combinations; range reflects NAT bootstrap variance |
| All 4 terminated | 152s | Complete blackout T+43s–T+108s (65s with zero instances online) |

### What the Tests Showed

**Recovery ceiling is NAT bootstrap time, not the healer.** The Lambda fires within ~60–90s of termination and updates the route. But the NAT instance itself takes longer to complete user_data (apt install, iptables, source/dest check). Routes go `active` pointing at new ENIs before packets can actually flow. The effective outage window for existing connections is the route blackhole period. New connections wait for full NAT bootstrap.

**Single-instance failures are fast.** A single private instance recovers in ~55s — just ASG detection plus SSM agent registration, no NAT dependency. A single NAT recovers in ~76s — one bootstrap, other AZ untouched. These are the most common real-world failure modes and the most recoverable.

**Existing SSM sessions are remarkably durable.** In every test where a private instance survived but lost its NAT, the SSM TCP session held through the entire blackhole window — up to 123 seconds with no egress. The healer restored routes fast enough that sessions didn't need to reconnect.

**AZ isolation held in every scenario.** AZ-2 failures never impacted AZ-1 recovery and vice versa across all nine test combinations. The two ASGs and two healer invocations operated independently throughout.

**Recovery band is consistent.** Across all failure combinations — 1 instance through all 4 — recovery stayed in the **55–158 second range**, with the floor set by single-instance ASG replacement and the ceiling by NAT bootstrap time in the worst-case all-4 scenario.

## What NAT Gateway Would Delete

If this project used NAT Gateway instead of NAT instances, the following would be removed entirely:

- `modules/nat_route_healer/` — all 3 files. The entire module exists solely because NAT instances leave stale routes on replacement.
- NAT launch template (`aws_launch_template.nat`) including its ~30-line user_data bash script
- NAT security group (`aws_security_group.nat`)
- NAT ASGs (×2) and the runtime data sources used to resolve their ENI IDs at apply time
- Per-AZ private default routes (`aws_route.private_default_via_nat`) — NAT Gateway wires these through the VPC module natively
- `hashicorp/archive` provider — only needed to zip the Lambda
- `data.aws_ami.debian` — NAT instances run Debian; private instances are Ubuntu; with NAT Gateway only one AMI lookup remains
- NAT-specific variables: `nat_ami_id`, `nat_instance_type`
- Outputs: `nat_asg_names`, `nat_route_healer_lambda_name`, `nat_route_healer_event_rule_name`
- CLAUDE.md known issues: `source_dest_check` workaround, healer observability concerns

Roughly **150–200 lines of Terraform and bash eliminated**, an entire module deleted, and the operational question "did the healer fire?" permanently removed from the runbook.

This is the accurate accounting of what $65/month buys.

## Deployment

```bash
# Authenticate
aws sso login --profile mrpocket2726

# Deploy
terraform init
terraform plan
terraform apply

# Verify
aws ssm describe-instance-information \
  --profile mrpocket2726 --region us-west-2 \
  --query "InstanceInformationList[].{ID:InstanceId,Name:ComputerName,Ping:PingStatus}" \
  --output table

# Teardown
terraform destroy
```

## Project Status

The network and compute layers are complete and validated. The NAT route healer has been tested under all meaningful failure combinations and performs as designed.

| Component | Status |
|---|---|
| VPC, subnets, route tables (2 AZs) | Done |
| NAT instances (Debian, ASG-managed, per AZ) | Done |
| Private compute (Ubuntu, ASG-managed, per AZ) | Done |
| NAT route self-healer (EventBridge + Lambda) | Done |
| Resilience testing (all failure combinations) | Done |
| Audit logging (CloudTrail → CloudWatch Logs) | Done |
| App tier (private ASG + ALB) | Planned |
| Database layer (RDS Multi-AZ) | Planned |
| CloudWatch alarms + VPC Flow Logs | Planned |

## Known Limitations

**`source_dest_check` in launch templates** — The Terraform `aws_launch_template` resource does not support `source_dest_check = false` in the `network_interfaces` block. Workaround: NAT instances call `aws ec2 modify-instance-attribute --no-source-dest-check` on themselves during boot using IMDSv2. This requires the SSM-EC2 instance profile to have `ec2:ModifyInstanceAttribute`.

**min=max=desired=1 per AZ** — There is always a zero-instance gap during ASG replacement. In-flight work on a terminated instance is lost. Rolling replacement requires desired >= 2.

**No application health checks** — ASG health checks are EC2-level only. A zombie instance (running but hung at the app layer) won't be detected or replaced without ELB health check integration.

**Terraform state in git** — `terraform.tfstate` is committed for demo simplicity. Production should use an S3 backend with DynamoDB locking.

**EventBridge delivery is best-effort** — If the healer Lambda fails or the event is not delivered, the route stays broken. Fallback is `terraform apply`. A DLQ and CloudWatch alarm on Lambda errors would close this gap.

## References

- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/~5.0)
- [AWS: NAT Instances vs. NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-comparison.html)
- [AWS Well-Architected Framework — Reliability Pillar](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
