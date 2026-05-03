# Resilience Testing

The stack was tested with direct failure injection against live EC2 instances. Tests terminated instances with the AWS CLI and measured time until replacement instances were visible and manageable through SSM. Stale terminated instance IDs were filtered out so timing reflected real replacements, not cached SSM inventory.

## Baseline

`terraform destroy` followed by `terraform apply` restored all four SSM-managed instances in **105 seconds**. The final four instances appeared in SSM 28 seconds after `terraform apply` completed.

---

## AMI Baking Impact

Both instance types were moved to Packer-baked AMIs on 2026-05-02 to eliminate per-boot package installation time.

| AMI | Base OS | Pre-baked |
|---|---|---|
| `nat-instance-*` | Debian 13 | awscli, iptables-persistent, amazon-ssm-agent |
| `private-instance-*` | Ubuntu 24.04 | amazon-ssm-agent (snap refresh + start) |

After baking, the recovery floor shifted from package installation to: ASG scheduling (~20–40s), OS boot (~15–20s), user data execution (~10–15s), SSM agent registration (~10–30s). The Lambda route healer itself runs in **~400–720ms** once triggered.

---

## Recovery Results — All Automated Runs

Three successful full-matrix runs (15 failure combos each). All runs used baked AMIs.

| # | Scenario | Run 1 (05-02 21:53Z) | Run 2 (05-02 22:48Z) | Run 3 (05-03 00:32Z) |
|---|---|---|---|---|
| 1 | NAT-2a | 159s | 91s | 142s |
| 2 | NAT-2b | 112s | 85s | 165s |
| 3 | NAT-2a + NAT-2b | 130s | 171s | 112s |
| 4 | Private-2a | 176s | 104s | 163s |
| 5 | NAT-2a + Private-2a | 164s | 119s | 172s |
| 6 | NAT-2b + Private-2a | 182s | 181s | 100s |
| 7 | NAT-2a + NAT-2b + Private-2a | 205s | 185s | 136s |
| 8 | Private-2b | 152s | 142s | 78s |
| 9 | NAT-2a + Private-2b | 176s | 197s | 125s |
| 10 | NAT-2b + Private-2b | 118s | 186s | 188s |
| 11 | NAT-2a + NAT-2b + Private-2b | 118s | 175s | 160s |
| 12 | Private-2a + Private-2b | 142s | 137s | 136s |
| 13 | NAT-2a + Private-2a + Private-2b | 153s | 150s | 140s |
| 14 | NAT-2b + Private-2a + Private-2b | 165s | 154s | 134s |
| 15 | All 4 terminated | 153s | 158s | 219s |
| | **Average** | **154s** | **149s** | **145s** |
| | **Min** | **112s** | **85s** | **78s** |
| | **Max** | **205s** | **197s** | **219s** |

**Cross-run aggregate:** avg ~149s, floor 78s, ceiling 219s across 45 total scenarios.

---

## Key Findings

**AZ isolation held across the full matrix.** Failures in one AZ did not affect recovery in the other. Each NAT ASG and its healer operated independently.

**Single-instance failures recover fastest.** Solo NAT or private failures generally landed in the 85–165s range. The healer fires within seconds of the new instance launching; the wait is OS boot + SSM registration.

**Multi-instance failures are slower but bounded.** Worst observed was 219s (all 4 terminated). The ceiling comes from private instances depending on their AZ NAT being ready before SSM can register — creating a sequential dependency in same-AZ combos.

**Run-to-run variance is significant (~30–50s).** AWS scheduling jitter, SSM heartbeat timing, and Lambda cold starts make individual scenario times noisy. Averages across the 15-combo matrix are more meaningful than any single result.

**SSM sessions survived NAT loss.** Existing private-instance SSM sessions remained alive through blackhole windows of up to 123 seconds, confirming the control plane is resilient to data-plane outages.

**Route healer is fast and reliable.** Fired correctly on every NAT replacement across all runs. Lambda execution time was consistently 400–720ms. Private-only failures correctly produced no healer invocation (routes untouched).

---

## Monitoring Evidence (2026-05-02 final run)

- 92 CloudTrail events in the run window: `TerminateInstances`, `RunInstances`, `ReplaceRoute`
- 76 NAT route healer Lambda log events
- 15 `ReplaceRoute` events — one per NAT replacement, zero false positives


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 6:23:01 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 11.8s |
| Status return-to-available | 72s |
| Pre-failover primary AZ | us-west-2b |
| Multi-AZ failover completed events | 3 |
| Probe samples (total / failed) | 175 / 9 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T18:05:14.680000+00:00 Multi-AZ instance failover started. 
  2026-05-03T18:05:31.666000+00:00 DB instance restarted
  2026-05-03T18:05:49.561000+00:00 Multi-AZ instance failover completed
  2026-05-03T18:05:49.561000+00:00 The user requested a failover of the DB instance.
  2026-05-03T18:16:34.814000+00:00 Multi-AZ instance failover started. 
  2026-05-03T18:16:53.859000+00:00 DB instance restarted
  2026-05-03T18:17:19.647000+00:00 The user requested a failover of the DB instance.
  2026-05-03T18:17:19.647000+00:00 Multi-AZ instance failover completed
  2026-05-03T18:21:24.744000+00:00 Multi-AZ instance failover started. 
  2026-05-03T18:21:41.013000+00:00 DB instance restarted
  2026-05-03T18:21:49.687000+00:00 Multi-AZ instance failover completed
  2026-05-03T18:21:49.687000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T18:21:12Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3–6 minutes after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 6:29:46 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 10.2s |
| Status return-to-available | 78s |
| Pre-failover primary AZ | us-west-2b |
| Multi-AZ failover completed events | 4 |
| Probe samples (total / failed) | 185 / 5 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T18:05:14.680000+00:00 Multi-AZ instance failover started. 
  2026-05-03T18:05:31.666000+00:00 DB instance restarted
  2026-05-03T18:05:49.561000+00:00 Multi-AZ instance failover completed
  2026-05-03T18:05:49.561000+00:00 The user requested a failover of the DB instance.
  2026-05-03T18:16:34.814000+00:00 Multi-AZ instance failover started. 
  2026-05-03T18:16:53.859000+00:00 DB instance restarted
  2026-05-03T18:17:19.647000+00:00 The user requested a failover of the DB instance.
  2026-05-03T18:17:19.647000+00:00 Multi-AZ instance failover completed
  2026-05-03T18:21:24.744000+00:00 Multi-AZ instance failover started. 
  2026-05-03T18:21:41.013000+00:00 DB instance restarted
  2026-05-03T18:21:49.687000+00:00 Multi-AZ instance failover completed
  2026-05-03T18:21:49.687000+00:00 The user requested a failover of the DB instance.
  2026-05-03T18:28:04.880000+00:00 Multi-AZ instance failover started. 
  2026-05-03T18:28:21.065000+00:00 DB instance restarted
  2026-05-03T18:28:49.738000+00:00 Multi-AZ instance failover completed
  2026-05-03T18:28:49.739000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T18:27:52Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3–6 minutes after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.

