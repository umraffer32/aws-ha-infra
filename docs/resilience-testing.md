# Resilience Testing

The stack was tested with direct failure injection against live EC2 instances. Tests terminated instances with the AWS CLI and measured time until replacement instances were visible and manageable through SSM. Stale terminated instance IDs were filtered out so timing reflected real replacements, not cached SSM inventory.

## Baseline

`terraform destroy` followed by `terraform apply` restored all four SSM-managed instances in **1:45**. The final four instances appeared in SSM 0:28 after `terraform apply` completed.

---

## AMI Baking Impact

Both instance types were moved to Packer-baked AMIs on 2026-05-02 to eliminate per-boot package installation time.

| AMI | Base OS | Pre-baked |
|---|---|---|
| `nat-instance-*` | Debian 13 | awscli, iptables-persistent, amazon-ssm-agent |
| `private-instance-*` | Ubuntu 24.04 | amazon-ssm-agent (snap refresh + start) |

After baking, the recovery floor shifted from package installation to: ASG scheduling (~0:20–0:40), OS boot (~0:15–0:20), user data execution (~0:10–0:15), SSM agent registration (~0:10–0:30). The Lambda route healer itself runs in **~0:00.4–0:00.7** once triggered.

---

## Recovery Results — All Automated Runs

Three successful full-matrix runs (15 failure combos each). All runs used baked AMIs.

| # | Scenario | Run 1 (05-02 21:53Z) | Run 2 (05-02 22:48Z) | Run 3 (05-03 00:32Z) |
|---|---|---|---|---|
| 1 | NAT-2a | 2:39 | 1:31 | 2:22 |
| 2 | NAT-2b | 1:52 | 1:25 | 2:45 |
| 3 | NAT-2a + NAT-2b | 2:10 | 2:51 | 1:52 |
| 4 | Private-2a | 2:56 | 1:44 | 2:43 |
| 5 | NAT-2a + Private-2a | 2:44 | 1:59 | 2:52 |
| 6 | NAT-2b + Private-2a | 3:02 | 3:01 | 1:40 |
| 7 | NAT-2a + NAT-2b + Private-2a | 3:25 | 3:05 | 2:16 |
| 8 | Private-2b | 2:32 | 2:22 | 1:18 |
| 9 | NAT-2a + Private-2b | 2:56 | 3:17 | 2:05 |
| 10 | NAT-2b + Private-2b | 1:58 | 3:06 | 3:08 |
| 11 | NAT-2a + NAT-2b + Private-2b | 1:58 | 2:55 | 2:40 |
| 12 | Private-2a + Private-2b | 2:22 | 2:17 | 2:16 |
| 13 | NAT-2a + Private-2a + Private-2b | 2:33 | 2:30 | 2:20 |
| 14 | NAT-2b + Private-2a + Private-2b | 2:45 | 2:34 | 2:14 |
| 15 | All 4 terminated | 2:33 | 2:38 | 3:39 |
| | **Average** | **2:34** | **2:29** | **2:25** |
| | **Min** | **1:52** | **1:25** | **1:18** |
| | **Max** | **3:25** | **3:17** | **3:39** |

**Cross-run aggregate:** avg ~2:29, floor 1:18, ceiling 3:39 across 45 total scenarios.

---

## Key Findings

**AZ isolation held across the full matrix.** Failures in one AZ did not affect recovery in the other. Each NAT ASG and its healer operated independently.

**Single-instance failures recover fastest.** Solo NAT or private failures generally landed in the 1:25–2:45 range. The healer fires within seconds of the new instance launching; the wait is OS boot + SSM registration.

**Multi-instance failures are slower but bounded.** Worst observed was 3:39 (all 4 terminated). The ceiling comes from private instances depending on their AZ NAT being ready before SSM can register — creating a sequential dependency in same-AZ combos.

**Run-to-run variance is significant (~0:30–0:50).** AWS scheduling jitter, SSM heartbeat timing, and Lambda cold starts make individual scenario times noisy. Averages across the 15-combo matrix are more meaningful than any single result.

**SSM sessions survived NAT loss.** Existing private-instance SSM sessions remained alive through blackhole windows of up to 2:03, confirming the control plane is resilient to data-plane outages.

**Route healer is fast and reliable.** Fired correctly on every NAT replacement across all runs. Lambda execution time was consistently 0:00.4–0:00.7. Private-only failures correctly produced no healer invocation (routes untouched).

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
| psql writer-unavailability window | 0:11.8 |
| Status return-to-available | 1:12 |
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

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 6:29:46 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:10.2 |
| Status return-to-available | 1:18 |
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

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 7:41:10 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:13.2 |
| Status return-to-available | 1:12 |
| Pre-failover primary AZ | us-west-2a |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 171 / 6 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T19:39:30.415000+00:00 Multi-AZ instance failover started. 
  2026-05-03T19:39:46.838000+00:00 DB instance restarted
  2026-05-03T19:40:20.305000+00:00 The user requested a failover of the DB instance.
  2026-05-03T19:40:20.305000+00:00 Multi-AZ instance failover completed
```

**CloudTrail timeline:**
```
  2026-05-03T19:39:21Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 7:45:07 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:13.2 |
| Status return-to-available | 3:09 |
| Pre-failover primary AZ | us-west-2a |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 375 / 6 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T19:43:30.385000+00:00 Multi-AZ instance failover started. 
  2026-05-03T19:43:44.785000+00:00 DB instance restarted
  2026-05-03T19:44:20.325000+00:00 Multi-AZ instance failover completed
  2026-05-03T19:44:20.325000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T19:41:22Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 7:49:04 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:13.2 |
| Status return-to-available | 3:09 |
| Pre-failover primary AZ | us-west-2a |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 375 / 6 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T19:47:25.420000+00:00 Multi-AZ instance failover started. 
  2026-05-03T19:47:40.831000+00:00 DB instance restarted
  2026-05-03T19:48:20.367000+00:00 Multi-AZ instance failover completed
  2026-05-03T19:48:20.367000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T19:45:19Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 7:53:13 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:13.2 |
| Status return-to-available | 3:21 |
| Pre-failover primary AZ | us-west-2a |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 395 / 6 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T19:51:30.452000+00:00 Multi-AZ instance failover started. 
  2026-05-03T19:51:46.797000+00:00 DB instance restarted
  2026-05-03T19:52:20.392000+00:00 Multi-AZ instance failover completed
  2026-05-03T19:52:20.393000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T19:49:16Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 7:57:09 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:10.7 |
| Status return-to-available | 3:08 |
| Pre-failover primary AZ | us-west-2a |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 377 / 5 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T19:55:30.490000+00:00 Multi-AZ instance failover started. 
  2026-05-03T19:55:47.006000+00:00 DB instance restarted
  2026-05-03T19:56:20.426000+00:00 Multi-AZ instance failover completed
  2026-05-03T19:56:20.426000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T19:53:25Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 8:01:06 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:13.2 |
| Status return-to-available | 3:09 |
| Pre-failover primary AZ | us-west-2a |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 375 / 6 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T19:59:25.518000+00:00 Multi-AZ instance failover started. 
  2026-05-03T19:59:40.654000+00:00 DB instance restarted
  2026-05-03T19:59:50.446000+00:00 Multi-AZ instance failover completed
  2026-05-03T19:59:50.447000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T19:57:21Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 8:05:03 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:13.2 |
| Status return-to-available | 3:09 |
| Pre-failover primary AZ | us-west-2a |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 376 / 6 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T20:03:25.722000+00:00 Multi-AZ instance failover started. 
  2026-05-03T20:03:41.158000+00:00 DB instance restarted
  2026-05-03T20:04:20.491000+00:00 Multi-AZ instance failover completed
  2026-05-03T20:04:20.491000+00:00 The user requested a failover of the DB instance.
```

**CloudTrail timeline:**
```
  2026-05-03T20:01:18Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 8:09:02 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:10.7 |
| Status return-to-available | 3:09 |
| Pre-failover primary AZ | us-west-2b |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 379 / 5 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T20:07:20.572000+00:00 Multi-AZ instance failover started. 
  2026-05-03T20:07:36.033000+00:00 DB instance restarted
  2026-05-03T20:08:20.533000+00:00 The user requested a failover of the DB instance.
  2026-05-03T20:08:20.533000+00:00 Multi-AZ instance failover completed
```

**CloudTrail timeline:**
```
  2026-05-03T20:05:15Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 8:13:10 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:13 |
| Status return-to-available | 3:19 |
| Pre-failover primary AZ | us-west-2b |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 402 / 13 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T20:11:30.612000+00:00 Multi-AZ instance failover started. 
  2026-05-03T20:11:46.705000+00:00 DB instance restarted
  2026-05-03T20:12:20.547000+00:00 The user requested a failover of the DB instance.
  2026-05-03T20:12:20.547000+00:00 Multi-AZ instance failover completed
```

**CloudTrail timeline:**
```
  2026-05-03T20:09:15Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.


## RDS Failover Test: 2026-05-03

Run timestamp: 2026-05-03 8:17:09 PM UTC  
Script: `rds-sim.sh`  
DB instance: `main-postgres`  
Probe host: `i-0f18ee25cc6ab6b41`  

| Metric | Value |
|---|---|
| psql writer-unavailability window | 0:40.9 |
| Status return-to-available | 3:10 |
| Pre-failover primary AZ | us-west-2b |
| Multi-AZ failover completed events | 1 |
| Probe samples (total / failed) | 379 / 53 |
| CloudTrail RebootDBInstance events | 1 |

**RDS event timeline:**
```
  2026-05-03T20:15:30.645000+00:00 Multi-AZ instance failover started. 
  2026-05-03T20:16:15.001000+00:00 DB instance restarted
  2026-05-03T20:16:50.594000+00:00 The user requested a failover of the DB instance.
  2026-05-03T20:16:50.594000+00:00 Multi-AZ instance failover completed
```

**CloudTrail timeline:**
```
  2026-05-03T20:13:23Z RebootDBInstance (forceFailover=true)
```

> Note: `DBInstances[0].AvailabilityZone` lags by 3:00–6:00 after a
> Multi-AZ failover, so "before/after" AZ readings from describe-db-instances
> are unreliable in real time. The RDS event log above is authoritative.

