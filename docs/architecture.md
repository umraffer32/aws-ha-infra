# Architecture

This project builds a two-AZ AWS network and compute baseline with self-managed NAT instances instead of NAT Gateway. The design is intentionally small enough to fit a portfolio/free-tier environment while still exposing the operational complexity that managed networking services hide.

## Network Layout

```text
VPC 10.0.0.0/16
  Public subnets
    AZ-1 10.0.1.0/24   NAT instance (ASG)
    AZ-2 10.0.2.0/24   NAT instance (ASG)

  Private subnets
    AZ-1 10.0.11.0/24  private Ubuntu instance (ASG)
    AZ-2 10.0.12.0/24  private Ubuntu instance (ASG)

  RDS (Multi-AZ PostgreSQL)
    Primary             placed in one private subnet by AWS
    Standby             placed in the other private subnet by AWS
```

The network module creates the VPC, subnets, public route table, private route tables, and tags. NAT Gateway is disabled. Private default routes are created by the compute module because the target is the live ENI of each NAT instance.

## Compute Layer

`modules/compute/` deploys both NAT and private instances.

- NAT instances run Debian 13 on `t2.micro`, one Auto Scaling Group per AZ.
- Private instances run Ubuntu 24.04 on `t2.micro`, one Auto Scaling Group per AZ.
- Both launch templates enforce IMDSv2 and use the `SSM-EC2` instance profile.
- NAT security group allows inbound traffic from the VPC CIDR and outbound to the internet.
- Private security group has outbound access only.
- Private route tables point `0.0.0.0/0` at each AZ's NAT instance ENI.

The instance profile name matters: this account has `SSM-EC2` with a hyphen, not `SSM_EC2` with an underscore.

## AMI Baking

Both NAT and private instances use pre-baked AMIs built with Packer (`nat-ami.pkr.hcl`, `private-ami.pkr.hcl`). Baking moves slow package installation out of per-boot user data and into a one-time image build step.

**NAT AMI** (`nat-instance-*`, Debian 13 base):
- `awscli`, `iptables-persistent` pre-installed
- SSM agent pre-installed and enabled via `.deb` package

**Private AMI** (`private-instance-*`, Ubuntu 24.04 base):
- SSM agent pre-refreshed via snap (Ubuntu ships it pre-installed but not fully initialized)

Baked AMIs reduced average recovery time by ~0:27 (~18%) across the 15-combo failure matrix compared to the unbaked baseline. The biggest gains are in single-instance recovery scenarios where the bottleneck was boot-time package installation.

## NAT Instance Bootstrap

User data runs runtime-specific steps only (no package installs):

1. Enable IPv4 forwarding with `net.ipv4.ip_forward=1`.
2. Call `aws ec2 modify-instance-attribute --no-source-dest-check` against itself using IMDSv2 metadata.
3. Add iptables `MASQUERADE` and `FORWARD` rules.
4. Persist iptables rules through reboot.

Terraform's `aws_launch_template` resource does not support `source_dest_check = false` inside the `network_interfaces` block. The self-modify call is the workaround, and it requires `ec2:ModifyInstanceAttribute` on the instance role.

The remaining recovery time (~1:30–3:00 in typical scenarios) is split between ASG replacement scheduling, instance OS boot, user data execution, SSM agent registration, and CloudWatch log propagation.

## Route Healer

`modules/nat_route_healer/` handles the failure mode where an ASG replaces a NAT instance and the private route table still points at the old ENI.

Flow:

1. EventBridge listens for Auto Scaling `EC2 Instance Launch Successful` events from the NAT ASGs.
2. EventBridge invokes a Lambda function.
3. Lambda maps the ASG name to the matching private route table ID.
4. Lambda resolves the launched instance's primary ENI with a retry loop.
5. Lambda calls `ec2:ReplaceRoute` for `0.0.0.0/0`.

This removes the need for manual `terraform apply` after normal NAT replacement events. It does not guarantee the replacement NAT is ready to forward traffic when the route is updated.

## Monitoring

`modules/monitoring/` provides audit and operational visibility:

- CloudTrail trail for regional API activity with global service events included.
- CloudWatch log group `/aws/cloudtrail/main` with 1-day retention.
- S3 backing bucket `main-cloudtrail-<account-id>` with 1-day lifecycle expiration and public access blocked.
- CloudWatch log metric filter for CloudTrail event flow.
- CloudWatch alarms for CloudTrail ingestion stalled, NAT healer Lambda errors, NAT healer Lambda throttles, EventBridge failed invocations, and EventBridge retry pressure.
- CloudWatch dashboard `${project_name}-operations` showing alarm status, CloudTrail flow, Lambda health, and EventBridge delivery health.

Alarm actions default to empty lists, so alarms exist for visibility but do not notify until action ARNs are provided.

## RDS

`modules/rds/` provisions a Multi-AZ PostgreSQL instance in the private subnets.

- Engine: PostgreSQL 16, `db.t3.micro`, 20 GiB gp2, encrypted at rest.
- Multi-AZ standby in the second private subnet — AWS manages failover automatically.
- No public access. Security group allows inbound port 5432 only from the private instance security group.
- 7-day automated backup retention. `skip_final_snapshot = true` and `deletion_protection = false` for demo teardown.
- Credentials (`db_name`, `db_username`, `db_password`) passed in via `terraform.tfvars`. `db_password` is marked `sensitive`.
- Provision time is ~15:00–25:00. For fast iteration that doesn't involve RDS, comment out `module "rds"` in `main.tf`.

## Design Decisions

### NAT Instances over NAT Gateway

NAT Gateway costs roughly $32/month per AZ, or about $65/month for two AZs before data transfer. NAT instances on `t2.micro` are free under the AWS 12-month Free Tier, then roughly $17/month for the pair.

The cost savings come with real operational ownership: bootstrap scripts, source/destination check handling, route repair, AMI selection, health validation, and observability. In production with SLA-bound traffic, NAT Gateway is the correct default.

### Two AZs over Three

Two AZs are enough for this stack's current shape: stateless compute, future ALB, and RDS Multi-AZ. A third AZ would add a third NAT instance, route table set, subnet set, and more operational surface without improving a non-quorum workload.

Three AZs would become appropriate if the project added a self-managed quorum system such as Kafka, etcd, or Consul.

### SSM over SSH

The project avoids port 22, keypairs, and bastion hosts. SSM Session Manager handles access through IAM. Private instances have no inbound security group rules.

### ALB over NLB

The planned app workload is HTTP, so ALB is the right default for Layer 7 routing, TLS termination, path or host routing, and HTTP-aware health checks. NLB would make sense for non-HTTP protocols, static IP needs, or very high-throughput Layer 4 workloads.

## What NAT Gateway Would Delete

Moving to NAT Gateway would remove most of the custom NAT machinery:

- `modules/nat_route_healer/`
- NAT launch template and user data
- NAT security group
- NAT Auto Scaling Groups
- Runtime ENI lookup for private route targets
- `archive` provider dependency for Lambda packaging
- Debian AMI lookup for NAT instances
- NAT-specific variables and outputs
- NAT healer alarms and dashboard widgets
- `source_dest_check` workaround and fallback route-repair runbook

That is the concrete engineering surface bought back by the managed service.
