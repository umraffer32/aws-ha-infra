# Highly Available AWS Infrastructure Without a NAT Gateway

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.6-7B42BC?logo=terraform&logoColor=white&style=flat-square)
![AWS Provider](https://img.shields.io/badge/AWS_Provider-~5.0-FF9900?style=flat-square)
![Region](https://img.shields.io/badge/Region-us--west--2-232F3E?style=flat-square)
![Recovery](https://img.shields.io/badge/Recovery-78%E2%80%93219s_%C2%B7_avg_~149s-2E7D32?style=flat-square)

A two-AZ AWS infrastructure project built with Terraform to explore the operational trade-offs of replacing managed NAT Gateway with self-managed NAT instances.

The key question: what does NAT Gateway abstract away, and how much engineering is required to make the cheaper alternative resilient?

![Architecture diagram](images/architecture.svg)

## What This Builds

The stack runs a VPC across two Availability Zones with public and private subnets, one Debian NAT instance per AZ, private Ubuntu instances managed by Auto Scaling Groups, a Multi-AZ PostgreSQL RDS instance, SSM-only access, CloudTrail audit logging, CloudWatch alarms, and an operations dashboard.

The core reliability feature is `modules/nat_route_healer/`: an EventBridge + Lambda route repair path that updates private default routes when a NAT instance is replaced and receives a new ENI.

```
NAT instance replaced → new ENI → EventBridge fires → Lambda calls ec2:ReplaceRoute → private traffic restored
```

```text
VPC 10.0.0.0/16
  Public subnets
    AZ-1 10.0.1.0/24  NAT instance, ASG-managed
    AZ-2 10.0.2.0/24  NAT instance, ASG-managed

  Private subnets
    AZ-1 10.0.11.0/24 Ubuntu instance, ASG-managed
    AZ-2 10.0.12.0/24 Ubuntu instance, ASG-managed

  RDS Multi-AZ PostgreSQL 16
    Primary + standby spread across both private subnets
```

## Stack

| Layer | Technology |
|---|---|
| Infrastructure | Terraform, AWS provider |
| Network | VPC, public/private subnets, per-AZ route tables |
| NAT | Debian 13 `t2.micro` instances, one ASG per AZ, Packer-baked AMI |
| Private compute | Ubuntu 24.04 `t2.micro` instances, one ASG per AZ, Packer-baked AMI |
| Database | RDS Multi-AZ PostgreSQL 16 `db.t3.micro`, encrypted, private subnets |
| Route self-healing | EventBridge + Lambda |
| Access | AWS SSM Session Manager, no SSH or keypairs |
| Monitoring | CloudTrail, CloudWatch Logs, alarms, operations dashboard |

## Why It Exists

NAT Gateway is simple and production-correct, but costs roughly $65/month for two AZs before data transfer. NAT instances can be close to free in the AWS Free Tier, but they shift failover, bootstrap, routing, AMI, and observability work back to the operator.

This repo demonstrates that trade-off directly. It builds the cheaper path, measures the recovery behavior, and documents what had to be added to make it self-healing.

## Current Status

| Component | Status |
|---|---|
| VPC, subnets, route tables | Done |
| NAT instances, per-AZ ASGs | Done |
| Private Ubuntu instances, per-AZ ASGs | Done |
| NAT route self-healer | Done |
| CloudTrail audit logging | Done |
| CloudWatch alarms and dashboard | Done |
| AMI baking (Packer) | Done (NAT: Debian 13 + awscli/iptables/SSM pre-installed; Private: Ubuntu 24.04 + SSM pre-initialized) |
| Resilience testing | Done (automated 15-combo failure simulation with CloudWatch + CloudTrail evidence capture) |
| RDS Multi-AZ PostgreSQL | Done (PostgreSQL 16, `db.t3.micro`, encrypted, private subnets) |
| App tier and ALB | Planned |
| VPC Flow Logs | Planned |

> [!NOTE]
> **Resilience testing (3 full-matrix runs, 45 scenarios total):** 78–219s range · avg ~149s across all runs. Recovery floor is ASG scheduling + OS boot + SSM registration (~55–90s combined). Route healer fires in 400–720ms per replacement. AZ isolation held across every multi-AZ failure combo.

## Quick Start

```bash
aws sso login --profile mrpocket2726
terraform init
terraform plan
terraform apply
```

Verify managed instances:

```bash
./ssm-check.sh
aws ssm describe-instance-information \
  --profile mrpocket2726 --region us-west-2 \
  --query "InstanceInformationList[].{ID:InstanceId,Name:ComputerName,Ping:PingStatus}" \
  --output table
```

Tear down:

```bash
terraform destroy
```

> **State:** `terraform.tfstate` is gitignored and stays local. A remote backend (S3 + DynamoDB) is on the roadmap for team use.

## Detailed Docs

- [Architecture](docs/architecture.md): NAT instance design, route healer internals, monitoring, and what NAT Gateway would delete.
- [Operations](docs/operations.md): prerequisites, configuration, deployment, validation, costs, and operational gotchas.
- [Resilience Testing](docs/resilience-testing.md): failure matrix, timing results, and observations.
- [Roadmap](docs/roadmap.md): remaining app, database, monitoring, reliability, security, and state-management work.

## References

- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/~5.0)
- [AWS: NAT Instances vs. NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-comparison.html)
- [AWS Well-Architected Framework, Reliability Pillar](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
