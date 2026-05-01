# Resilience Testing

The stack was tested with direct failure injection against live EC2 instances. Tests terminated instances with the AWS CLI and measured time until replacement instances were visible and manageable through SSM.

Stale terminated instance IDs were filtered out so the timing reflected real replacements, not cached SSM inventory.

## Baseline

`terraform destroy` followed by `terraform apply` restored all four SSM-managed instances in 105 seconds.

The final four instances appeared in SSM 28 seconds after `terraform apply` completed.

## Failure Matrix

| Scenario | Recovery Time | Notes |
|---|---|---|
| Single private only | 55s | No NAT involvement; replacement only needed SSM agent registration |
| Single NAT only | 76s | Other AZ stayed healthy; healer repointed the private route, then NAT bootstrap finished |
| Both NATs only | 86s | Both healers fired independently; existing SSM sessions survived the blackhole window |
| Both privates only | 111s | NAT untouched; private routes stayed active |
| NAT + same-AZ private, one NAT | 131s | Private replacement was blocked until its AZ NAT finished bootstrapping |
| NAT AZ-1 + private AZ-1, both NATs up | 125s | Healer restored the route before private replacement needed egress |
| NAT AZ-1 + private AZ-2, cross AZ | 147s | AZ-2 private recovered independently through its healthy NAT |
| Both NATs + one private | 120-158s | Tested both AZ combinations; range reflects NAT bootstrap variance |
| All 4 terminated | 152s | Complete blackout from T+43s to T+108s, 65s with zero instances online |

## Observations

Recovery is gated by NAT bootstrap time, not route replacement. The healer can update a route within roughly 60-90 seconds, but the replacement NAT instance still has to install packages, configure iptables, and disable source/destination checks.

Single-instance failures are fast. The most likely failures, one private instance or one NAT instance, recovered in 55-76 seconds.

SSM sessions were durable under NAT loss. Existing private-instance SSM sessions survived blackhole windows of up to 123 seconds.

AZ isolation held across the full matrix. Failures in one AZ did not break recovery in the other AZ.

The tested recovery band was 55-158 seconds. The floor is ASG replacement plus SSM registration. The ceiling is NAT bootstrap under the worst failure combinations.

## Monitoring Evidence

During testing, CloudTrail and Lambda logs showed:

- More than 920 CloudTrail events under active load.
- 102 NAT route healer Lambda log events.
- CloudTrail ingestion around 88 events per minute during observation.
- Dominant CloudTrail events from SSM `UpdateInstanceInformation`, IAM console reads, and STS `AssumeRole`.

These numbers are point-in-time observations from 2026-05-01, not ongoing service-level guarantees.
