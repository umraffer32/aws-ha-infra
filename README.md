# Highly Available Web Application on AWS

A multi-AZ AWS infrastructure deployed with Terraform. Prioritizes cost efficiency within the AWS Free Tier while maintaining HA across 2 availability zones.

![Architecture diagram](images/architecture.svg)

## Architecture

```
VPC (10.0.0.0/16)
├── Public Subnets  — AZ-1: 10.0.1.0/24   AZ-2: 10.0.2.0/24   (NAT instances, ALB)
└── Private Subnets — AZ-1: 10.0.11.0/24  AZ-2: 10.0.12.0/24  (app, database)
```

## Stack

| Layer | Technology |
|---|---|
| Infrastructure | Terraform (modular) |
| NAT | Debian t2.micro instances, one per AZ, ASG-managed |
| Private Compute | Ubuntu t2.micro instances, one per AZ, ASG-managed |
| Load Balancing | ALB (planned) |
| Database | RDS Multi-AZ (planned) |
| Access | AWS SSM Session Manager |

## Design Decisions

### NAT Instances over NAT Gateway

NAT Gateway costs ~$32/month per AZ — two AZs is ~$65/month before any data transfer. A pair of t2.micro NAT instances are free under the 12-month free tier, then ~$17/month. For a portfolio environment with frequent teardowns, the cost difference dominates.

The trade-off: NAT Instances aren't transparently HA — if an instance dies, egress from that AZ stops until the ASG replaces it. Each NAT instance runs in an ASG (min=max=desired=1) to automate recovery. In production with real traffic and SLAs, NAT Gateway is the right call.

### 2 AZs over 3

ALB requires a minimum of 2 AZs. RDS Multi-AZ is inherently 2-zone. The Well-Architected Framework treats 2 AZs as the HA baseline — a third AZ only buys something for quorum-based systems (etcd, Kafka, Consul), which this stack doesn't have.

### ALB over NLB

HTTP workload. ALB operates at Layer 7: path/host routing, TLS termination, HTTP-aware health checks, native ASG integration. NLB is correct for non-HTTP protocols or when downstream systems need a static IP — neither applies here.

### SSM over SSH

No open port 22, no keypair management. IAM controls who can access which instances and sessions are auditable via CloudWatch. SSM also means no VPC interface endpoints are needed for private subnet connectivity.

## Deployment

```bash
aws sso login --profile mrpocket2726

terraform init
terraform plan
terraform apply

# Teardown
terraform destroy
```

## Current Progress (as of 2026-04-30)

- [x] Network layer: VPC, public/private subnets, and route tables across 2 AZs
- [x] NAT layer: Debian NAT instances in per-AZ ASGs
- [x] Private compute baseline: Ubuntu private instances in per-AZ ASGs
- [x] Private subnet internet egress routed through NAT instance ENIs per AZ
- [x] Access and validation: NAT working as intended, private instances reach online SSM connectivity within ~2 minutes
- [ ] App layer: private app ASG plus ALB listeners/target groups
- [ ] Database layer: RDS Multi-AZ module and wiring
- [ ] Monitoring: CloudWatch alarms/log groups and optional VPC Flow Logs

## Work In Progress

- Build app tier in private subnets and front it with an ALB in public subnets
- Add security group boundaries for ALB -> App and App -> RDS traffic
- Add `modules/database` for Multi-AZ RDS and subnet/security integration
- Add `modules/monitoring` for alarms, logs, and network observability

## Known TODOs

- **Terraform deploy role** — currently uses SSO `AdministratorAccess`. Should assume a scoped `TerraformDeploy` role with `PowerUserAccess` + name-prefix-bounded IAM policy.
- **Remote state** — `terraform.tfstate` is committed to git. Production should use an S3 backend with DynamoDB locking.
