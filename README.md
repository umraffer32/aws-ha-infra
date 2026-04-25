# Highly Available Web Application on AWS

A multi-AZ AWS infrastructure deployed with Terraform.

![Architecture diagram](images/architecture.svg)

### NAT Gateway vs NAT Instance

**Choice:** NAT Instances (t2.micro, Debian), one per AZ, bootstrapped via user_data.

NAT Gateway is AWS's recommended default — managed, automatically HA within an AZ, throughput scales transparently. It's also ~$32/month per AZ before any per-GB processing charges. Two AZs comes out to ~$65/month sitting idle, which dominates the cost of an otherwise dormant portfolio stack.

NAT Instances flip the math. With t2.micro under the AWS Free Tier (750 instance-hours/month for the first 12 months), two of them running 24/7 are fully covered — NAT cost is effectively $0 for the duration of the free tier, then ~$17/month afterward. That's the difference between a stack I can leave running indefinitely and one I have to remember to `terraform destroy` between demos.

**Bootstrapping:** the instances run Debian and configure themselves at boot via `user_data`:
- Enable IPv4 forwarding (`net.ipv4.ip_forward=1`, persisted in `/etc/sysctl.d/`)
- Add an `iptables` MASQUERADE rule on the public-facing interface
- Persist iptables rules across reboot

The `source_dest_check = false` flag on the ENI is set in Terraform — it's an AWS-level setting that tells the VPC router to permit packets whose source or destination IP isn't the instance itself. Without it, NAT silently doesn't work.

**What I'm trading away:**

- **Managed HA.** A NAT Gateway recovers transparently if the underlying hardware fails. A NAT Instance is just an EC2 — if it dies, egress from that subnet stops. I mitigate by running one per AZ inside an Auto Scaling Group with `min`/`max`/`desired = 1`, so an instance failure auto-replaces and an AZ failure only takes out one path.
- **Operational ownership.** I own the AMI, OS patches, sizing, and the source/destination-check setting. AWS handles all of that for NAT Gateway.
- **Throughput ceiling.** t2.micro is bandwidth-limited and burst-credit-limited on CPU. Fine for this project; not fine for production-scale traffic.

**When this decision flips:** in a production environment with real traffic and SLAs, NAT Gateways become correct. The ~$65/month premium buys managed HA and removes a class of operational toil that easily costs more than that in engineering time the first time something breaks at 2am. The choice here isn't "NAT Instance is better" — it's "NAT Instance is better *for this context*: a free-tier portfolio environment where the cost ratio is extreme and downtime is harmless."

**Side benefit:** because private instances retain outbound internet via NAT, SSM Session Manager works without VPC interface endpoints (~$42/month for the `ssm` / `ssmmessages` / `ec2messages` trio across two AZs). Endpoints would only be required if I'd chosen fully isolated private subnets — appropriate for compliance-bound environments (HIPAA, PCI, FedRAMP), overkill here.