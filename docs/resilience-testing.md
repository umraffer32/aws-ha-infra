# Resilience Testing

The stack was tested with direct failure injection against live EC2 instances. Tests terminated instances with the AWS CLI and measured time until replacement instances were visible and manageable through SSM.

Stale terminated instance IDs were filtered out so the timing reflected real replacements, not cached SSM inventory.

This document contains both historical narrative snapshots and raw automated run artifacts appended by `failure-sim.sh`. For the current state, use the latest `## Automated Run` section near the end of this file.

## Baseline

`terraform destroy` followed by `terraform apply` restored all four SSM-managed instances in 105 seconds.

The final four instances appeared in SSM 28 seconds after `terraform apply` completed.

## Latest Snapshot (2026-05-02 — baked AMIs)

Most recent full-matrix run with fully baked AMIs for both NAT and private instances:

- Recovery band: `65s` to `184s`
- Median recovery: `136s`
- Average recovery: `120s`
- Improvement vs unbaked baseline: ~27s average (-18%)

## AMI Baking Summary (2026-05-02)

Both instance types were moved to Packer-baked AMIs to reduce per-boot install time:

| AMI | Base OS | Pre-baked packages |
|---|---|---|
| `nat-instance-*` | Debian 13 | awscli, iptables-persistent, amazon-ssm-agent (.deb) |
| `private-instance-*` | Ubuntu 24.04 | amazon-ssm-agent (snap refresh + start) |

Recovery time comparison across runs:

| Run | AMI state | Avg recovery | Min | Max |
|---|---|---|---|---|
| Baseline (2026-05-01) | Unbaked | 147s | 112s | 205s |
| Run 2 (2026-05-02) | NAT baked only | 145s | 78s | 219s |
| Run 3 (2026-05-02, baked both) | NAT + private baked | **120s** | **65s** | **184s** |

The biggest gains were in single-instance private failures (176s → 65s) and single NAT failures (159s → 72s). Multi-instance and full-wipeout scenarios improved more modestly due to parallel recovery paths and higher natural variance.

After baking, the recovery floor is gated by ASG scheduling, OS boot, SSM agent registration, and Lambda cold starts — not package installation.

## Failure Matrix (Historical Snapshot — 2026-05-01)

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

With baked AMIs, recovery is no longer gated by package installation. The bottleneck shifted to ASG scheduling (~20-40s), OS boot (~15-20s), user data execution (~10-15s), and SSM agent registration (~10-30s). Route replacement itself is fast — the Lambda healer runs in ~500-650ms once triggered.

Single-instance failures recovered as fast as 65s in the baked-AMI run. Multi-instance failures still take 1.5–3 minutes due to parallel replacement paths and their dependencies (e.g. private instances need their AZ NAT ready before SSM can register).

SSM sessions were durable under NAT loss. Existing private-instance SSM sessions survived blackhole windows of up to 123 seconds.

AZ isolation held across the full matrix. Failures in one AZ did not break recovery in the other AZ.

Run-to-run variance remains significant (~30-50s) due to AWS scheduling jitter, SSM heartbeat timing windows, and Lambda cold starts. Averages across the 15-combo matrix are more meaningful than individual scenario times.

## Monitoring Evidence

Latest automated run (2026-05-02) showed:

- 92 CloudTrail events in the run window for `TerminateInstances`, `RunInstances`, and `ReplaceRoute`.
- 76 NAT route healer Lambda log events in the run window.
- 15 `ReplaceRoute` events (matching NAT replacement activity).

Historical high-volume observation sample (2026-05-01):

- More than 920 CloudTrail events under active load.
- 102 NAT route healer Lambda log events.
- CloudTrail ingestion around 88 events per minute during observation.
- Dominant CloudTrail events from SSM `UpdateInstanceInformation`, IAM console reads, and STS `AssumeRole`.

These numbers are point-in-time observations from 2026-05-01, not ongoing service-level guarantees.

## Automated Run: 2026-05-02

Run timestamp: 2026-05-02T21:53:02Z  
Script: `failure-sim.sh`  

| Combo | Scenario | Recovery Time |
|---|---|---|
| 1 | NAT-2a | 159s |
| 2 | NAT-2b | 112s |
| 3 | NAT-2a NAT-2b | 130s |
| 4 | Private-2a | 176s |
| 5 | NAT-2a Private-2a | 164s |
| 6 | NAT-2b Private-2a | 182s |
| 7 | NAT-2a NAT-2b Private-2a | 205s |
| 8 | Private-2b | 152s |
| 9 | NAT-2a Private-2b | 176s |
| 10 | NAT-2b Private-2b | 118s |
| 11 | NAT-2a NAT-2b Private-2b | 118s |
| 12 | Private-2a Private-2b | 142s |
| 13 | NAT-2a Private-2a Private-2b | 153s |
| 14 | NAT-2b Private-2a Private-2b | 165s |
| 15 | NAT-2a NAT-2b Private-2a Private-2b | 153s |


### Log Excerpts — NAT-2a

**Lambda (route healer):**
```
INIT_START Runtime Version: python:3.12.mainlinev2.v7	Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244
	[INFO]	2026-05-02T21:55:11.504Z		Found credentials in environment variables.
	START RequestId: 46b674b8-92e0-4a70-a4ea-97b7c7c4b6b3 Version: $LATEST
	[INFO]	2026-05-02T21:55:12.424Z	46b674b8-92e0-4a70-a4ea-97b7c7c4b6b3	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0efdc30f9dc326571 for ASG main-nat-asg-us-west-2a (instance i-09fb080dca668d353)
	END RequestId: 46b674b8-92e0-4a70-a4ea-97b7c7c4b6b3
	REPORT RequestId: 46b674b8-92e0-4a70-a4ea-97b7c7c4b6b3	Duration: 688.36 ms	Billed Duration: 1229 ms	Memory Size: 128 MB	Max Memory Used: 99 MB	Init Duration: 539.70 ms	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T21:53:05Z TerminateInstances
```

### Log Excerpts — NAT-2b

**Lambda (route healer):**
```
START RequestId: 77850120-a609-4712-b82f-698988711728 Version: $LATEST
	[INFO]	2026-05-02T21:56:58.310Z	77850120-a609-4712-b82f-698988711728	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-053625f5b67e71624 for ASG main-nat-asg-us-west-2b (instance i-0bdd1ca813aea3d80)
	END RequestId: 77850120-a609-4712-b82f-698988711728
	REPORT RequestId: 77850120-a609-4712-b82f-698988711728	Duration: 527.57 ms	Billed Duration: 528 ms	Memory Size: 128 MB	Max Memory Used: 99 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T21:54:39Z RunInstances
  2026-05-02T21:54:38Z TerminateInstances
  2026-05-02T21:55:12Z ReplaceRoute
  2026-05-02T21:55:48Z TerminateInstances
```

### Log Excerpts — NAT-2a NAT-2b

**Lambda (route healer):**
```
START RequestId: 6e03443c-ed5b-4cce-a151-b19330025f79 Version: $LATEST
	[INFO]	2026-05-02T21:58:58.980Z	6e03443c-ed5b-4cce-a151-b19330025f79	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0c419055b1f06dc66 for ASG main-nat-asg-us-west-2b (instance i-0d95f4d1f6391e41f)
	END RequestId: 6e03443c-ed5b-4cce-a151-b19330025f79
	REPORT RequestId: 6e03443c-ed5b-4cce-a151-b19330025f79	Duration: 636.72 ms	Billed Duration: 637 ms	Memory Size: 128 MB	Max Memory Used: 99 MB	
	START RequestId: 4c83bfcb-e4e4-40c1-9e34-3c7bacba8f4b Version: $LATEST
	[INFO]	2026-05-02T21:59:20.007Z	4c83bfcb-e4e4-40c1-9e34-3c7bacba8f4b	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0ca0d3b6644e462af for ASG main-nat-asg-us-west-2a (instance i-041fd2606a6b3bf58)
	END RequestId: 4c83bfcb-e4e4-40c1-9e34-3c7bacba8f4b
	REPORT RequestId: 4c83bfcb-e4e4-40c1-9e34-3c7bacba8f4b	Duration: 404.11 ms	Billed Duration: 405 ms	Memory Size: 128 MB	Max Memory Used: 99 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T21:56:25Z TerminateInstances
  2026-05-02T21:56:26Z RunInstances
  2026-05-02T21:56:58Z ReplaceRoute
  2026-05-02T21:57:44Z TerminateInstances
```

### Log Excerpts — Private-2a

**Lambda (route healer):**
```
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T21:58:25Z TerminateInstances
  2026-05-02T21:58:26Z RunInstances
  2026-05-02T21:58:48Z RunInstances
  2026-05-02T21:58:47Z TerminateInstances
  2026-05-02T21:58:58Z ReplaceRoute
  2026-05-02T21:59:20Z ReplaceRoute
  2026-05-02T21:59:58Z TerminateInstances
  2026-05-02T22:01:55Z TerminateInstances
  2026-05-02T22:01:55Z RunInstances
```

### Log Excerpts — NAT-2a Private-2a

**Lambda (route healer):**
```
INIT_START Runtime Version: python:3.12.mainlinev2.v7	Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244
	[INFO]	2026-05-02T22:04:52.182Z		Found credentials in environment variables.
	START RequestId: 4be66b61-6c1b-4a60-9b4c-1569bbfe812b Version: $LATEST
	[INFO]	2026-05-02T22:04:53.120Z	4be66b61-6c1b-4a60-9b4c-1569bbfe812b	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-030d2ee805f891c6c for ASG main-nat-asg-us-west-2a (instance i-06ec2ca7f7d616b77)
	END RequestId: 4be66b61-6c1b-4a60-9b4c-1569bbfe812b
	REPORT RequestId: 4be66b61-6c1b-4a60-9b4c-1569bbfe812b	Duration: 690.99 ms	Billed Duration: 1305 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	Init Duration: 613.41 ms	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:02:58Z TerminateInstances
  2026-05-02T22:03:50Z RunInstances
  2026-05-02T22:03:49Z TerminateInstances
  2026-05-02T22:04:46Z TerminateInstances
  2026-05-02T22:04:46Z RunInstances
  2026-05-02T22:04:53Z ReplaceRoute
```

### Log Excerpts — NAT-2b Private-2a

**Lambda (route healer):**
```
START RequestId: 62ede2e8-4572-4fce-bf05-4438de452ce4 Version: $LATEST
	[INFO]	2026-05-02T22:06:27.371Z	62ede2e8-4572-4fce-bf05-4438de452ce4	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0e946e94bc61cced7 for ASG main-nat-asg-us-west-2b (instance i-02aed7cfeecdc646b)
	END RequestId: 62ede2e8-4572-4fce-bf05-4438de452ce4
	REPORT RequestId: 62ede2e8-4572-4fce-bf05-4438de452ce4	Duration: 710.57 ms	Billed Duration: 711 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:05:46Z TerminateInstances
  2026-05-02T22:06:20Z TerminateInstances
  2026-05-02T22:06:21Z RunInstances
  2026-05-02T22:06:27Z ReplaceRoute
```

### Log Excerpts — NAT-2a NAT-2b Private-2a

**Lambda (route healer):**
```
START RequestId: 59de09db-39d5-41c6-89d9-9103c3447e65 Version: $LATEST
	[INFO]	2026-05-02T22:10:27.283Z	59de09db-39d5-41c6-89d9-9103c3447e65	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-099e15dc136304268 for ASG main-nat-asg-us-west-2b (instance i-0a1fedc30272adb10)
	END RequestId: 59de09db-39d5-41c6-89d9-9103c3447e65
	REPORT RequestId: 59de09db-39d5-41c6-89d9-9103c3447e65	Duration: 714.92 ms	Billed Duration: 715 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	
	START RequestId: e5c29b2a-ddcd-4006-af51-45cc53a5fd07 Version: $LATEST
	[INFO]	2026-05-02T22:11:17.432Z	e5c29b2a-ddcd-4006-af51-45cc53a5fd07	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0e41357220665e2fd for ASG main-nat-asg-us-west-2a (instance i-09a64f982eee4edc4)
	END RequestId: e5c29b2a-ddcd-4006-af51-45cc53a5fd07
	REPORT RequestId: e5c29b2a-ddcd-4006-af51-45cc53a5fd07	Duration: 395.40 ms	Billed Duration: 396 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:07:48Z RunInstances
  2026-05-02T22:07:47Z TerminateInstances
  2026-05-02T22:08:52Z TerminateInstances
  2026-05-02T22:09:52Z TerminateInstances
  2026-05-02T22:09:53Z RunInstances
  2026-05-02T22:10:18Z TerminateInstances
  2026-05-02T22:10:19Z RunInstances
  2026-05-02T22:10:27Z ReplaceRoute
  2026-05-02T22:10:44Z TerminateInstances
  2026-05-02T22:10:45Z RunInstances
  2026-05-02T22:11:17Z ReplaceRoute
```

### Log Excerpts — Private-2b

**Lambda (route healer):**
```
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:12:21Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2b

**Lambda (route healer):**
```
INIT_START Runtime Version: python:3.12.mainlinev2.v7	Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244
	[INFO]	2026-05-02T22:17:16.517Z		Found credentials in environment variables.
	START RequestId: cd646012-d1a7-4f70-ae73-59a5533ca16f Version: $LATEST
	[INFO]	2026-05-02T22:17:17.456Z	cd646012-d1a7-4f70-ae73-59a5533ca16f	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-099cc7fcbaf8653b1 for ASG main-nat-asg-us-west-2a (instance i-0acf9bb189a01d836)
	END RequestId: cd646012-d1a7-4f70-ae73-59a5533ca16f
	REPORT RequestId: cd646012-d1a7-4f70-ae73-59a5533ca16f	Duration: 712.40 ms	Billed Duration: 1277 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	Init Duration: 564.31 ms	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:14:18Z TerminateInstances
  2026-05-02T22:14:19Z RunInstances
  2026-05-02T22:14:58Z TerminateInstances
```

### Log Excerpts — NAT-2b Private-2b

**Lambda (route healer):**
```
START RequestId: 10caae8a-9bfb-43f1-9746-fbfdad79b7fc Version: $LATEST
	[INFO]	2026-05-02T22:18:56.228Z	10caae8a-9bfb-43f1-9746-fbfdad79b7fc	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0264d015544997bfe for ASG main-nat-asg-us-west-2b (instance i-080a974a020ba55df)
	END RequestId: 10caae8a-9bfb-43f1-9746-fbfdad79b7fc
	REPORT RequestId: 10caae8a-9bfb-43f1-9746-fbfdad79b7fc	Duration: 614.45 ms	Billed Duration: 615 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:16:18Z TerminateInstances
  2026-05-02T22:16:18Z RunInstances
  2026-05-02T22:16:44Z RunInstances
  2026-05-02T22:16:43Z TerminateInstances
  2026-05-02T22:17:17Z ReplaceRoute
```

### Log Excerpts — NAT-2a NAT-2b Private-2b

**Lambda (route healer):**
```
START RequestId: 4edfc169-6075-4e52-b88b-51045491b6f6 Version: $LATEST
	[INFO]	2026-05-02T22:20:30.264Z	4edfc169-6075-4e52-b88b-51045491b6f6	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0ea41b9239a9bc9cb for ASG main-nat-asg-us-west-2b (instance i-036c7a1340d282a8a)
	END RequestId: 4edfc169-6075-4e52-b88b-51045491b6f6
	REPORT RequestId: 4edfc169-6075-4e52-b88b-51045491b6f6	Duration: 710.01 ms	Billed Duration: 711 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	
	START RequestId: 7d6352e5-ce6d-44f3-9fa6-a0d17e660ea8 Version: $LATEST
	[INFO]	2026-05-02T22:21:25.533Z	7d6352e5-ce6d-44f3-9fa6-a0d17e660ea8	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-05403c7dc94cf2570 for ASG main-nat-asg-us-west-2a (instance i-02e0eddcc731f59a1)
	END RequestId: 7d6352e5-ce6d-44f3-9fa6-a0d17e660ea8
	REPORT RequestId: 7d6352e5-ce6d-44f3-9fa6-a0d17e660ea8	Duration: 375.51 ms	Billed Duration: 376 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:17:57Z TerminateInstances
  2026-05-02T22:18:18Z RunInstances
  2026-05-02T22:18:18Z TerminateInstances
  2026-05-02T22:18:23Z TerminateInstances
  2026-05-02T22:18:24Z RunInstances
  2026-05-02T22:18:56Z ReplaceRoute
  2026-05-02T22:19:59Z TerminateInstances
```

### Log Excerpts — Private-2a Private-2b

**Lambda (route healer):**
```
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:20:18Z RunInstances
  2026-05-02T22:20:17Z TerminateInstances
  2026-05-02T22:20:24Z TerminateInstances
  2026-05-02T22:20:24Z RunInstances
  2026-05-02T22:20:30Z ReplaceRoute
  2026-05-02T22:20:52Z TerminateInstances
  2026-05-02T22:20:53Z RunInstances
  2026-05-02T22:21:25Z ReplaceRoute
  2026-05-02T22:22:01Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2a Private-2b

**Lambda (route healer):**
```
START RequestId: e3ee9f99-488b-4764-b601-c44f4ffd0c93 Version: $LATEST
	[INFO]	2026-05-02T22:25:26.095Z	e3ee9f99-488b-4764-b601-c44f4ffd0c93	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-014bd73f620f4b832 for ASG main-nat-asg-us-west-2a (instance i-0ef7d9c0608dc4554)
	END RequestId: e3ee9f99-488b-4764-b601-c44f4ffd0c93
	REPORT RequestId: e3ee9f99-488b-4764-b601-c44f4ffd0c93	Duration: 635.84 ms	Billed Duration: 636 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:22:17Z TerminateInstances
  2026-05-02T22:22:17Z RunInstances
  2026-05-02T22:23:39Z RunInstances
  2026-05-02T22:23:39Z TerminateInstances
  2026-05-02T22:24:27Z TerminateInstances
  2026-05-02T22:24:53Z TerminateInstances
  2026-05-02T22:24:53Z RunInstances
  2026-05-02T22:25:26Z ReplaceRoute
  2026-05-02T22:25:44Z TerminateInstances
  2026-05-02T22:25:44Z RunInstances
  2026-05-02T22:26:15Z RunInstances
  2026-05-02T22:26:14Z TerminateInstances
```

### Log Excerpts — NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
START RequestId: 329ffb50-556f-4eec-8a50-fe19a2c158e7 Version: $LATEST
	[INFO]	2026-05-02T22:28:51.091Z	329ffb50-556f-4eec-8a50-fe19a2c158e7	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-020c34c5a18ec0ac3 for ASG main-nat-asg-us-west-2b (instance i-0607d05c3f5cb1a9f)
	END RequestId: 329ffb50-556f-4eec-8a50-fe19a2c158e7
	REPORT RequestId: 329ffb50-556f-4eec-8a50-fe19a2c158e7	Duration: 601.41 ms	Billed Duration: 602 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:27:04Z TerminateInstances
  2026-05-02T22:27:38Z TerminateInstances
  2026-05-02T22:27:39Z RunInstances
  2026-05-02T22:28:15Z RunInstances
  2026-05-02T22:28:14Z TerminateInstances
  2026-05-02T22:28:18Z TerminateInstances
  2026-05-02T22:28:19Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
START RequestId: 45fe9716-6ef9-48b9-a41f-9be7adebb48c Version: $LATEST
	[INFO]	2026-05-02T22:31:01.965Z	45fe9716-6ef9-48b9-a41f-9be7adebb48c	Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0a64b9bf596c1c481 for ASG main-nat-asg-us-west-2b (instance i-0f85e4de964e564e5)
	END RequestId: 45fe9716-6ef9-48b9-a41f-9be7adebb48c
	REPORT RequestId: 45fe9716-6ef9-48b9-a41f-9be7adebb48c	Duration: 628.95 ms	Billed Duration: 629 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	
	START RequestId: 065adbb0-0614-48e5-9fff-2a223c0bcdf5 Version: $LATEST
	[INFO]	2026-05-02T22:31:09.994Z	065adbb0-0614-48e5-9fff-2a223c0bcdf5	Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0b9e80b854ce8bde0 for ASG main-nat-asg-us-west-2a (instance i-052754a402bf7babc)
	END RequestId: 065adbb0-0614-48e5-9fff-2a223c0bcdf5
	REPORT RequestId: 065adbb0-0614-48e5-9fff-2a223c0bcdf5	Duration: 413.42 ms	Billed Duration: 414 ms	Memory Size: 128 MB	Max Memory Used: 98 MB	

```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
  2026-05-02T22:28:51Z ReplaceRoute
  2026-05-02T22:29:53Z TerminateInstances
  2026-05-02T22:30:14Z TerminateInstances
  2026-05-02T22:30:14Z RunInstances
  2026-05-02T22:30:29Z RunInstances
  2026-05-02T22:30:29Z TerminateInstances
  2026-05-02T22:30:53Z RunInstances
  2026-05-02T22:30:52Z TerminateInstances
```

## Automated Run: 2026-05-02

Run timestamp: 2026-05-02T22:47:28Z  
Script: `failure-sim.sh`  
Topology source: `terraform-asg`  
Log mode: `summary`  
Failure policy: `continue-on-error`  

| Combo | Scenario | Recovery Time |
|---|---|---|
| 1 | — | ERROR (discovery) |
| 2 | — | ERROR (discovery) |
| 3 | — | ERROR (discovery) |
| 4 | — | ERROR (discovery) |
| 5 | — | ERROR (discovery) |
| 6 | — | ERROR (discovery) |
| 7 | — | ERROR (discovery) |
| 8 | — | ERROR (discovery) |
| 9 | — | ERROR (discovery) |
| 10 | — | ERROR (discovery) |
| 11 | — | ERROR (discovery) |
| 12 | — | ERROR (discovery) |
| 13 | — | ERROR (discovery) |
| 14 | — | ERROR (discovery) |
| 15 | — | ERROR (discovery) |


## Automated Run: 2026-05-02

Run timestamp: 2026-05-02T22:48:32Z  
Script: `failure-sim.sh`  
Topology source: `terraform-asg`  
Log mode: `summary`  
Failure policy: `continue-on-error`  

| Combo | Scenario | Recovery Time |
|---|---|---|
| 1 | NAT-2a | 91s |
| 2 | NAT-2b | 85s |
| 3 | NAT-2a NAT-2b | 171s |
| 4 | Private-2a | 104s |
| 5 | NAT-2a Private-2a | 119s |
| 6 | NAT-2b Private-2a | 181s |
| 7 | NAT-2a NAT-2b Private-2a | 185s |
| 8 | Private-2b | 142s |
| 9 | NAT-2a Private-2b | 197s |
| 10 | NAT-2b Private-2b | 186s |
| 11 | NAT-2a NAT-2b Private-2b | 175s |
| 12 | Private-2a Private-2b | 137s |
| 13 | NAT-2a Private-2a Private-2b | 150s |
| 14 | NAT-2b Private-2a Private-2b | 154s |
| 15 | NAT-2a NAT-2b Private-2a Private-2b | 158s |


### Log Excerpts — NAT-2a

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-02T22:49:21.532Z Found credentials in environment variables. 
  START RequestId: a34a81b0-2835-4349-8293-2b0651cb9fda Version: $LATEST 
  [INFO] 2026-05-02T22:49:22.468Z a34a81b0-2835-4349-8293-2b0651cb9fda Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0058dc9b4cf046994 for ASG main-nat-asg-us-west-2a (instance i-0383730d219e4a6b7) 
  END RequestId: a34a81b0-2835-4349-8293-2b0651cb9fda 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 1
by event:
  TerminateInstances: 1
timeline sample:
  2026-05-02T22:48:35Z TerminateInstances
```

### Log Excerpts — NAT-2b

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-02T22:50:56.168Z Found credentials in environment variables. 
  START RequestId: c7f9dfd3-c8b1-4e8a-b15a-57c3b42ec77d Version: $LATEST 
  [INFO] 2026-05-02T22:50:57.403Z c7f9dfd3-c8b1-4e8a-b15a-57c3b42ec77d Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0306c028bdcf0104b for ASG main-nat-asg-us-west-2b (instance i-0297bca16b92cfc89) 
  END RequestId: c7f9dfd3-c8b1-4e8a-b15a-57c3b42ec77d 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-02T22:49:03Z TerminateInstances
  2026-05-02T22:49:04Z RunInstances
  2026-05-02T22:49:22Z ReplaceRoute
  2026-05-02T22:50:09Z TerminateInstances
  2026-05-02T22:50:23Z TerminateInstances
  2026-05-02T22:50:24Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: 492c7b2d-4b46-48cb-a52d-a3c7fb818b56 Version: $LATEST 
  [INFO] 2026-05-02T22:52:56.534Z 492c7b2d-4b46-48cb-a52d-a3c7fb818b56 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0b2ddd2de5dcdb077 for ASG main-nat-asg-us-west-2b (instance i-01c1b8ac56baca41e) 
  END RequestId: 492c7b2d-4b46-48cb-a52d-a3c7fb818b56 
  REPORT RequestId: 492c7b2d-4b46-48cb-a52d-a3c7fb818b56 Duration: 608.41 ms Billed Duration: 609 ms Memory Size: 128 MB Max Memory Used: 98 MB 
  START RequestId: b06313cc-43cd-45a7-b159-4a471f95c1df Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 4
by event:
  ReplaceRoute: 1
  RunInstances: 1
  TerminateInstances: 2
timeline sample:
  2026-05-02T22:50:57Z ReplaceRoute
  2026-05-02T22:51:38Z TerminateInstances
  2026-05-02T22:52:23Z TerminateInstances
  2026-05-02T22:52:24Z RunInstances
```

### Log Excerpts — Private-2a

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 5
by event:
  ReplaceRoute: 2
  RunInstances: 1
  TerminateInstances: 2
timeline sample:
  2026-05-02T22:52:56Z ReplaceRoute
  2026-05-02T22:53:03Z TerminateInstances
  2026-05-02T22:53:04Z RunInstances
  2026-05-02T22:53:36Z ReplaceRoute
  2026-05-02T22:54:33Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2a

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 9757b9d0-bcae-410c-a2c3-df0e06c5fac9 Version: $LATEST 
  [INFO] 2026-05-02T22:57:36.033Z 9757b9d0-bcae-410c-a2c3-df0e06c5fac9 Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-09f725aa6c0709de3 for ASG main-nat-asg-us-west-2a (instance i-03d7b15c0c2a60226) 
  END RequestId: 9757b9d0-bcae-410c-a2c3-df0e06c5fac9 
  REPORT RequestId: 9757b9d0-bcae-410c-a2c3-df0e06c5fac9 Duration: 588.45 ms Billed Duration: 589 ms Memory Size: 128 MB Max Memory Used: 98 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 3
by event:
  RunInstances: 1
  TerminateInstances: 2
timeline sample:
  2026-05-02T22:55:30Z TerminateInstances
  2026-05-02T22:55:31Z RunInstances
  2026-05-02T22:56:19Z TerminateInstances
```

### Log Excerpts — NAT-2b Private-2a

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: c0a0a9c8-3d91-47f1-8704-ac842fba20f8 Version: $LATEST 
  [INFO] 2026-05-02T23:00:34.491Z c0a0a9c8-3d91-47f1-8704-ac842fba20f8 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-09d3a8397d0d31265 for ASG main-nat-asg-us-west-2b (instance i-0d7ca4005ef8cacb7) 
  END RequestId: c0a0a9c8-3d91-47f1-8704-ac842fba20f8 
  REPORT RequestId: c0a0a9c8-3d91-47f1-8704-ac842fba20f8 Duration: 639.62 ms Billed Duration: 640 ms Memory Size: 128 MB Max Memory Used: 98 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 11
by event:
  ReplaceRoute: 2
  RunInstances: 4
  TerminateInstances: 5
timeline sample:
  2026-05-02T22:57:03Z TerminateInstances
  2026-05-02T22:57:04Z RunInstances
  2026-05-02T22:57:25Z TerminateInstances
  2026-05-02T22:57:26Z RunInstances
  2026-05-02T22:57:36Z ReplaceRoute
  2026-05-02T22:58:22Z TerminateInstances
  2026-05-02T22:59:22Z TerminateInstances
  2026-05-02T22:59:23Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2a

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: 11919c76-9a4c-4096-8587-f44e4b77c8d6 Version: $LATEST 
  [INFO] 2026-05-02T23:03:00.520Z 11919c76-9a4c-4096-8587-f44e4b77c8d6 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0e1bb722166dbbcfd for ASG main-nat-asg-us-west-2b (instance i-0830cd47884f53e2b) 
  END RequestId: 11919c76-9a4c-4096-8587-f44e4b77c8d6 
  REPORT RequestId: 11919c76-9a4c-4096-8587-f44e4b77c8d6 Duration: 639.45 ms Billed Duration: 640 ms Memory Size: 128 MB Max Memory Used: 98 MB 
  START RequestId: c2f263ff-b67b-4756-a6b2-233531e7ba93 Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 8
by event:
  ReplaceRoute: 1
  RunInstances: 3
  TerminateInstances: 4
timeline sample:
  2026-05-02T23:01:27Z TerminateInstances
  2026-05-02T23:02:27Z TerminateInstances
  2026-05-02T23:02:28Z RunInstances
  2026-05-02T23:03:00Z ReplaceRoute
  2026-05-02T23:03:02Z RunInstances
  2026-05-02T23:03:02Z TerminateInstances
  2026-05-02T23:03:20Z TerminateInstances
  2026-05-02T23:03:21Z RunInstances
```

### Log Excerpts — Private-2b

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 2
by event:
  ReplaceRoute: 1
  TerminateInstances: 1
timeline sample:
  2026-05-02T23:03:35Z ReplaceRoute
  2026-05-02T23:04:35Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2b

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-02T23:09:42.776Z Found credentials in environment variables. 
  START RequestId: bbd7f8d9-31d7-4ce9-9106-995806915845 Version: $LATEST 
  [INFO] 2026-05-02T23:09:43.673Z bbd7f8d9-31d7-4ce9-9106-995806915845 Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0fa529deedc33b35f for ASG main-nat-asg-us-west-2a (instance i-008e2a50aeec0ae2f) 
  END RequestId: bbd7f8d9-31d7-4ce9-9106-995806915845 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 7
by event:
  RunInstances: 3
  TerminateInstances: 4
timeline sample:
  2026-05-02T23:06:11Z TerminateInstances
  2026-05-02T23:06:12Z RunInstances
  2026-05-02T23:07:00Z TerminateInstances
  2026-05-02T23:08:11Z TerminateInstances
  2026-05-02T23:08:12Z RunInstances
  2026-05-02T23:09:09Z TerminateInstances
  2026-05-02T23:09:10Z RunInstances
```

### Log Excerpts — NAT-2b Private-2b

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-02T23:12:26.826Z Found credentials in environment variables. 
  START RequestId: 4b5ecbe3-4477-4340-b784-f14470416cd9 Version: $LATEST 
  [INFO] 2026-05-02T23:12:27.704Z 4b5ecbe3-4477-4340-b784-f14470416cd9 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-082e4fdbe755c9ee2 for ASG main-nat-asg-us-west-2b (instance i-0dc9da24170d51502) 
  END RequestId: 4b5ecbe3-4477-4340-b784-f14470416cd9 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 3
by event:
  ReplaceRoute: 1
  RunInstances: 1
  TerminateInstances: 1
timeline sample:
  2026-05-02T23:09:43Z ReplaceRoute
  2026-05-02T23:10:21Z TerminateInstances
  2026-05-02T23:12:20Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2b

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: 5b5a54fa-63e5-4432-ba21-5b679f66f0d1 Version: $LATEST 
  [INFO] 2026-05-02T23:15:03.678Z 5b5a54fa-63e5-4432-ba21-5b679f66f0d1 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0a4fd915006f8ca0b for ASG main-nat-asg-us-west-2b (instance i-00a68bef0ffd3b420) 
  END RequestId: 5b5a54fa-63e5-4432-ba21-5b679f66f0d1 
  REPORT RequestId: 5b5a54fa-63e5-4432-ba21-5b679f66f0d1 Duration: 647.43 ms Billed Duration: 648 ms Memory Size: 128 MB Max Memory Used: 99 MB 
  START RequestId: 1a3d6fb6-48b8-4b08-bae7-e7a418b387f1 Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-02T23:12:19Z TerminateInstances
  2026-05-02T23:12:20Z TerminateInstances
  2026-05-02T23:12:21Z RunInstances
  2026-05-02T23:12:27Z ReplaceRoute
  2026-05-02T23:13:29Z TerminateInstances
  2026-05-02T23:14:19Z RunInstances
```

### Log Excerpts — Private-2a Private-2b

**Lambda (route healer):**
```
count: 2
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-02T23:17:14.519Z Found credentials in environment variables. 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 10
by event:
  ReplaceRoute: 2
  RunInstances: 3
  TerminateInstances: 5
timeline sample:
  2026-05-02T23:14:19Z TerminateInstances
  2026-05-02T23:14:30Z TerminateInstances
  2026-05-02T23:14:31Z RunInstances
  2026-05-02T23:15:03Z ReplaceRoute
  2026-05-02T23:15:08Z TerminateInstances
  2026-05-02T23:15:09Z RunInstances
  2026-05-02T23:15:40Z ReplaceRoute
  2026-05-02T23:16:27Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2a Private-2b

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-02T23:19:14.094Z Found credentials in environment variables. 
  START RequestId: 9ca1249c-1a88-4354-b518-34ceb679d1ca Version: $LATEST 
  [INFO] 2026-05-02T23:19:15.020Z 9ca1249c-1a88-4354-b518-34ceb679d1ca Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-032673a3cbcdebea3 for ASG main-nat-asg-us-west-2a (instance i-0f8df38ad4ccfd00d) 
  END RequestId: 9ca1249c-1a88-4354-b518-34ceb679d1ca 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 10
by event:
  ReplaceRoute: 1
  RunInstances: 4
  TerminateInstances: 5
timeline sample:
  2026-05-02T23:18:08Z RunInstances
  2026-05-02T23:18:08Z TerminateInstances
  2026-05-02T23:18:47Z TerminateInstances
  2026-05-02T23:19:07Z TerminateInstances
  2026-05-02T23:19:08Z RunInstances
  2026-05-02T23:19:12Z RunInstances
  2026-05-02T23:19:12Z TerminateInstances
  2026-05-02T23:19:15Z ReplaceRoute
```

### Log Excerpts — NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: cc8aa5a9-06b2-445c-90f1-ee0c7059c0e2 Version: $LATEST 
  [INFO] 2026-05-02T23:22:57.873Z cc8aa5a9-06b2-445c-90f1-ee0c7059c0e2 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0d0fa8b0f619b41c6 for ASG main-nat-asg-us-west-2b (instance i-0e04ae13c993abef1) 
  END RequestId: cc8aa5a9-06b2-445c-90f1-ee0c7059c0e2 
  REPORT RequestId: cc8aa5a9-06b2-445c-90f1-ee0c7059c0e2 Duration: 720.12 ms Billed Duration: 721 ms Memory Size: 128 MB Max Memory Used: 99 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-02T23:21:20Z TerminateInstances
  2026-05-02T23:22:06Z TerminateInstances
  2026-05-02T23:22:07Z RunInstances
  2026-05-02T23:22:24Z TerminateInstances
  2026-05-02T23:22:25Z RunInstances
  2026-05-02T23:22:57Z ReplaceRoute
```

### Log Excerpts — NAT-2a NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: db38e17c-f1d0-4123-8e0a-2daffdc13b50 Version: $LATEST 
  [INFO] 2026-05-02T23:24:57.570Z db38e17c-f1d0-4123-8e0a-2daffdc13b50 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0ed459cd2bfd62345 for ASG main-nat-asg-us-west-2b (instance i-0af1514af0fe0058c) 
  END RequestId: db38e17c-f1d0-4123-8e0a-2daffdc13b50 
  REPORT RequestId: db38e17c-f1d0-4123-8e0a-2daffdc13b50 Duration: 646.50 ms Billed Duration: 647 ms Memory Size: 128 MB Max Memory Used: 99 MB 
  START RequestId: e3eb1bd0-4dde-48ab-a2ef-2ee872ab101b Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 10
by event:
  ReplaceRoute: 1
  RunInstances: 5
  TerminateInstances: 4
timeline sample:
  2026-05-02T23:23:11Z RunInstances
  2026-05-02T23:23:11Z TerminateInstances
  2026-05-02T23:23:58Z TerminateInstances
  2026-05-02T23:24:07Z TerminateInstances
  2026-05-02T23:24:08Z RunInstances
  2026-05-02T23:24:24Z TerminateInstances
  2026-05-02T23:24:25Z RunInstances
  2026-05-02T23:24:57Z ReplaceRoute
```

## Automated Run: 2026-05-03

Run timestamp: 2026-05-03T00:32:09Z  
Script: `failure-sim.sh`  
Topology source: `terraform-asg`  
Log mode: `summary`  
Failure policy: `continue-on-error`  

| Combo | Scenario | Recovery Time |
|---|---|---|
| 1 | NAT-2a | 142s |
| 2 | NAT-2b | 165s |
| 3 | NAT-2a NAT-2b | 112s |
| 4 | Private-2a | 163s |
| 5 | NAT-2a Private-2a | 172s |
| 6 | NAT-2b Private-2a | 100s |
| 7 | NAT-2a NAT-2b Private-2a | 136s |
| 8 | Private-2b | 78s |
| 9 | NAT-2a Private-2b | 125s |
| 10 | NAT-2b Private-2b | 188s |
| 11 | NAT-2a NAT-2b Private-2b | 160s |
| 12 | Private-2a Private-2b | 136s |
| 13 | NAT-2a Private-2a Private-2b | 140s |
| 14 | NAT-2b Private-2a Private-2b | 134s |
| 15 | NAT-2a NAT-2b Private-2a Private-2b | 219s |


### Log Excerpts — NAT-2a

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-03T00:34:19.443Z Found credentials in environment variables. 
  START RequestId: f07019e9-2912-4a7a-9901-82e8aa67392f Version: $LATEST 
  [INFO] 2026-05-03T00:34:20.383Z f07019e9-2912-4a7a-9901-82e8aa67392f Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0a2bf13ef5fcc45ef for ASG main-nat-asg-us-west-2a (instance i-06cb7c02f21169409) 
  END RequestId: f07019e9-2912-4a7a-9901-82e8aa67392f 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 1
by event:
  TerminateInstances: 1
timeline sample:
  2026-05-03T00:32:12Z TerminateInstances
```

### Log Excerpts — NAT-2b

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-03T00:37:05.345Z Found credentials in environment variables. 
  START RequestId: d3f752e1-2e35-40c0-8c9a-3c92168f7b57 Version: $LATEST 
  [INFO] 2026-05-03T00:37:06.267Z d3f752e1-2e35-40c0-8c9a-3c92168f7b57 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-03ce207c28e227539 for ASG main-nat-asg-us-west-2b (instance i-00bbb980aea592293) 
  END RequestId: d3f752e1-2e35-40c0-8c9a-3c92168f7b57 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T00:33:46Z TerminateInstances
  2026-05-03T00:33:47Z RunInstances
  2026-05-03T00:34:20Z ReplaceRoute
  2026-05-03T00:34:37Z TerminateInstances
  2026-05-03T00:36:32Z TerminateInstances
  2026-05-03T00:36:33Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: dbb5554c-4af6-42c3-8dba-d531e7792533 Version: $LATEST 
  [INFO] 2026-05-03T00:38:18.730Z dbb5554c-4af6-42c3-8dba-d531e7792533 Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-012c7d5cfd1af0b6a for ASG main-nat-asg-us-west-2a (instance i-0beb53d6bcc9733d9) 
  END RequestId: dbb5554c-4af6-42c3-8dba-d531e7792533 
  REPORT RequestId: dbb5554c-4af6-42c3-8dba-d531e7792533 Duration: 677.64 ms Billed Duration: 678 ms Memory Size: 128 MB Max Memory Used: 99 MB 
  START RequestId: 410ba0e2-8e7f-4b04-9f28-c6eff201b936 Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 1
by event:
  ReplaceRoute: 1
timeline sample:
  2026-05-03T00:37:06Z ReplaceRoute
```

### Log Excerpts — Private-2a

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 10
by event:
  ReplaceRoute: 2
  RunInstances: 3
  TerminateInstances: 5
timeline sample:
  2026-05-03T00:37:26Z TerminateInstances
  2026-05-03T00:37:46Z RunInstances
  2026-05-03T00:37:46Z TerminateInstances
  2026-05-03T00:38:18Z ReplaceRoute
  2026-05-03T00:38:32Z TerminateInstances
  2026-05-03T00:38:32Z RunInstances
  2026-05-03T00:39:04Z ReplaceRoute
  2026-05-03T00:39:20Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2a

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-03T00:44:18.441Z Found credentials in environment variables. 
  START RequestId: 1b9e6719-934a-4f60-841d-aef080560f3b Version: $LATEST 
  [INFO] 2026-05-03T00:44:19.414Z 1b9e6719-934a-4f60-841d-aef080560f3b Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0ae9d542593605460 for ASG main-nat-asg-us-west-2a (instance i-05ccc6ce7d4c678f8) 
  END RequestId: 1b9e6719-934a-4f60-841d-aef080560f3b 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 1
by event:
  TerminateInstances: 1
timeline sample:
  2026-05-03T00:42:29Z TerminateInstances
```

### Log Excerpts — NAT-2b Private-2a

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: b50c4b39-c0c4-44d4-8e27-53b5d5aaede4 Version: $LATEST 
  [INFO] 2026-05-03T00:46:44.037Z b50c4b39-c0c4-44d4-8e27-53b5d5aaede4 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-00e22fbdb7cbde5d1 for ASG main-nat-asg-us-west-2b (instance i-04086f8792b967f46) 
  END RequestId: b50c4b39-c0c4-44d4-8e27-53b5d5aaede4 
  REPORT RequestId: b50c4b39-c0c4-44d4-8e27-53b5d5aaede4 Duration: 635.99 ms Billed Duration: 636 ms Memory Size: 128 MB Max Memory Used: 99 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 3
  TerminateInstances: 2
timeline sample:
  2026-05-03T00:43:45Z TerminateInstances
  2026-05-03T00:43:46Z RunInstances
  2026-05-03T00:44:19Z ReplaceRoute
  2026-05-03T00:44:28Z RunInstances
  2026-05-03T00:44:28Z TerminateInstances
  2026-05-03T00:46:33Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2a

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: 324d8111-6ec4-4c7a-b79b-b68f1bb77e44 Version: $LATEST 
  [INFO] 2026-05-03T00:48:27.822Z 324d8111-6ec4-4c7a-b79b-b68f1bb77e44 Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-037470de7c469ec13 for ASG main-nat-asg-us-west-2a (instance i-0b1c867e9b960f47e) 
  END RequestId: 324d8111-6ec4-4c7a-b79b-b68f1bb77e44 
  REPORT RequestId: 324d8111-6ec4-4c7a-b79b-b68f1bb77e44 Duration: 537.04 ms Billed Duration: 538 ms Memory Size: 128 MB Max Memory Used: 99 MB 
  START RequestId: 290ca4d0-6b22-4c88-a65b-1529e16ae9ab Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 9
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 6
timeline sample:
  2026-05-03T00:45:25Z TerminateInstances
  2026-05-03T00:46:32Z TerminateInstances
  2026-05-03T00:46:37Z TerminateInstances
  2026-05-03T00:46:38Z RunInstances
  2026-05-03T00:46:44Z ReplaceRoute
  2026-05-03T00:47:08Z TerminateInstances
  2026-05-03T00:47:55Z TerminateInstances
  2026-05-03T00:47:55Z RunInstances
```

### Log Excerpts — Private-2b

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 5
by event:
  ReplaceRoute: 2
  RunInstances: 2
  TerminateInstances: 1
timeline sample:
  2026-05-03T00:48:27Z ReplaceRoute
  2026-05-03T00:48:28Z RunInstances
  2026-05-03T00:48:37Z RunInstances
  2026-05-03T00:48:37Z TerminateInstances
  2026-05-03T00:49:09Z ReplaceRoute
```

### Log Excerpts — NAT-2a Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 291880ac-1eaf-4c10-998f-a77e1cf9f733 Version: $LATEST 
  [INFO] 2026-05-03T00:52:18.574Z 291880ac-1eaf-4c10-998f-a77e1cf9f733 Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-092e69b3b1a3bb2d8 for ASG main-nat-asg-us-west-2a (instance i-0e4c897406c061fec) 
  END RequestId: 291880ac-1eaf-4c10-998f-a77e1cf9f733 
  REPORT RequestId: 291880ac-1eaf-4c10-998f-a77e1cf9f733 Duration: 635.08 ms Billed Duration: 636 ms Memory Size: 128 MB Max Memory Used: 99 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 5
by event:
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T00:49:26Z TerminateInstances
  2026-05-03T00:50:07Z TerminateInstances
  2026-05-03T00:50:08Z RunInstances
  2026-05-03T00:50:47Z TerminateInstances
  2026-05-03T00:51:46Z RunInstances
```

### Log Excerpts — NAT-2b Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 98c883c3-f547-44a3-ba3a-1e7e1275e7e8 Version: $LATEST 
  [INFO] 2026-05-03T00:55:05.669Z 98c883c3-f547-44a3-ba3a-1e7e1275e7e8 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-04e2e09ca823944b7 for ASG main-nat-asg-us-west-2b (instance i-071cc1863a8ff26f9) 
  END RequestId: 98c883c3-f547-44a3-ba3a-1e7e1275e7e8 
  REPORT RequestId: 98c883c3-f547-44a3-ba3a-1e7e1275e7e8 Duration: 634.38 ms Billed Duration: 635 ms Memory Size: 128 MB Max Memory Used: 99 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 7
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 4
timeline sample:
  2026-05-03T00:51:45Z TerminateInstances
  2026-05-03T00:52:07Z TerminateInstances
  2026-05-03T00:52:07Z RunInstances
  2026-05-03T00:52:18Z ReplaceRoute
  2026-05-03T00:52:55Z TerminateInstances
  2026-05-03T00:54:06Z RunInstances
  2026-05-03T00:54:32Z TerminateInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2b

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: e32aae21-2bd5-43ae-ac47-1e4ac08054f1 Version: $LATEST 
  [INFO] 2026-05-03T00:56:39.182Z e32aae21-2bd5-43ae-ac47-1e4ac08054f1 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-07153b2210d53c2e9 for ASG main-nat-asg-us-west-2b (instance i-0c3c7293924871a51) 
  END RequestId: e32aae21-2bd5-43ae-ac47-1e4ac08054f1 
  REPORT RequestId: e32aae21-2bd5-43ae-ac47-1e4ac08054f1 Duration: 589.39 ms Billed Duration: 590 ms Memory Size: 128 MB Max Memory Used: 99 MB 
  START RequestId: 6e26daa4-0724-41fb-aa57-e2534f6ccc77 Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 9
by event:
  ReplaceRoute: 2
  RunInstances: 3
  TerminateInstances: 4
timeline sample:
  2026-05-03T00:54:06Z TerminateInstances
  2026-05-03T00:54:33Z RunInstances
  2026-05-03T00:55:05Z ReplaceRoute
  2026-05-03T00:56:06Z TerminateInstances
  2026-05-03T00:56:33Z RunInstances
  2026-05-03T00:56:33Z TerminateInstances
  2026-05-03T00:56:39Z ReplaceRoute
  2026-05-03T00:58:03Z TerminateInstances
```

### Log Excerpts — Private-2a Private-2b

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 7
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 4
timeline sample:
  2026-05-03T00:57:53Z TerminateInstances
  2026-05-03T00:57:54Z RunInstances
  2026-05-03T00:58:26Z ReplaceRoute
  2026-05-03T00:58:49Z TerminateInstances
  2026-05-03T01:00:03Z TerminateInstances
  2026-05-03T01:00:04Z RunInstances
  2026-05-03T01:00:20Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2a Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 6a2a8a9d-5da3-4bf5-989d-185b620afd63 Version: $LATEST 
  [INFO] 2026-05-03T01:02:26.109Z 6a2a8a9d-5da3-4bf5-989d-185b620afd63 Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-05f29fd9f9ff4e5d6 for ASG main-nat-asg-us-west-2a (instance i-09c018e8800f0b57d) 
  END RequestId: 6a2a8a9d-5da3-4bf5-989d-185b620afd63 
  REPORT RequestId: 6a2a8a9d-5da3-4bf5-989d-185b620afd63 Duration: 698.44 ms Billed Duration: 699 ms Memory Size: 128 MB Max Memory Used: 99 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 5
by event:
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T01:01:09Z TerminateInstances
  2026-05-03T01:01:53Z TerminateInstances
  2026-05-03T01:01:53Z RunInstances
  2026-05-03T01:02:04Z RunInstances
  2026-05-03T01:02:25Z TerminateInstances
```

### Log Excerpts — NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 7e0ae445-5f51-45f8-b601-5379c9e03303 Version: $LATEST 
  [INFO] 2026-05-03T01:04:59.928Z 7e0ae445-5f51-45f8-b601-5379c9e03303 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-00d5f3e4e73884224 for ASG main-nat-asg-us-west-2b (instance i-0f80a190ed4f43a41) 
  END RequestId: 7e0ae445-5f51-45f8-b601-5379c9e03303 
  REPORT RequestId: 7e0ae445-5f51-45f8-b601-5379c9e03303 Duration: 606.41 ms Billed Duration: 607 ms Memory Size: 128 MB Max Memory Used: 99 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T01:02:03Z TerminateInstances
  2026-05-03T01:02:26Z RunInstances
  2026-05-03T01:02:26Z ReplaceRoute
  2026-05-03T01:03:32Z TerminateInstances
  2026-05-03T01:04:12Z TerminateInstances
  2026-05-03T01:04:13Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: 73252dfb-dafc-4cdc-9b00-2920fb2280ef Version: $LATEST 
  [INFO] 2026-05-03T01:07:10.783Z 73252dfb-dafc-4cdc-9b00-2920fb2280ef Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-045ff8d5ac6b28fb5 for ASG main-nat-asg-us-west-2b (instance i-01fe0342a2bace3f9) 
  END RequestId: 73252dfb-dafc-4cdc-9b00-2920fb2280ef 
  REPORT RequestId: 73252dfb-dafc-4cdc-9b00-2920fb2280ef Duration: 645.16 ms Billed Duration: 646 ms Memory Size: 128 MB Max Memory Used: 99 MB 
  START RequestId: 7532feff-5965-4d53-8d38-18be35b1c0c2 Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 15
by event:
  ReplaceRoute: 3
  RunInstances: 6
  TerminateInstances: 6
timeline sample:
  2026-05-03T01:04:20Z RunInstances
  2026-05-03T01:04:20Z TerminateInstances
  2026-05-03T01:04:27Z TerminateInstances
  2026-05-03T01:04:27Z RunInstances
  2026-05-03T01:04:59Z ReplaceRoute
  2026-05-03T01:05:50Z TerminateInstances
  2026-05-03T01:06:11Z TerminateInstances
  2026-05-03T01:06:12Z RunInstances
```

## Automated Run: 2026-05-03

Run timestamp: 2026-05-03T02:26:05Z  
Script: `failure-sim.sh`  
Topology source: `terraform-asg`  
Log mode: `summary`  
Failure policy: `continue-on-error`  

| Combo | Scenario | Recovery Time |
|---|---|---|
| 1 | NAT-2a | 72s |
| 2 | NAT-2b | 131s |
| 3 | NAT-2a NAT-2b | 95s |
| 4 | Private-2a | 65s |
| 5 | NAT-2a Private-2a | 172s |
| 6 | NAT-2b Private-2a | 154s |
| 7 | NAT-2a NAT-2b Private-2a | 130s |
| 8 | Private-2b | 148s |
| 9 | NAT-2a Private-2b | 154s |
| 10 | NAT-2b Private-2b | 132s |
| 11 | NAT-2a NAT-2b Private-2b | 130s |
| 12 | Private-2a Private-2b | 136s |
| 13 | NAT-2a Private-2a Private-2b | 166s |
| 14 | NAT-2b Private-2a Private-2b | 137s |
| 15 | NAT-2a NAT-2b Private-2a Private-2b | 184s |


### Log Excerpts — NAT-2a

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-03T02:27:03.495Z Found credentials in environment variables. 
  START RequestId: cedeaeda-cb26-409d-87fc-ccac3bab6828 Version: $LATEST 
  [INFO] 2026-05-03T02:27:04.482Z cedeaeda-cb26-409d-87fc-ccac3bab6828 Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-01b92b3eb6232baa2 for ASG main-nat-asg-us-west-2a (instance i-00d470494df08ddde) 
  END RequestId: cedeaeda-cb26-409d-87fc-ccac3bab6828 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
(no TerminateInstances/RunInstances/ReplaceRoute events in window)
```

### Log Excerpts — NAT-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 33f68dce-b8cb-471e-a907-1a4fa10d9a52 Version: $LATEST 
  [INFO] 2026-05-03T02:29:13.120Z 33f68dce-b8cb-471e-a907-1a4fa10d9a52 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-035f3dccd758e4273 for ASG main-nat-asg-us-west-2b (instance i-0c1b50c906f622e81) 
  END RequestId: 33f68dce-b8cb-471e-a907-1a4fa10d9a52 
  REPORT RequestId: 33f68dce-b8cb-471e-a907-1a4fa10d9a52 Duration: 668.05 ms Billed Duration: 669 ms Memory Size: 128 MB Max Memory Used: 98 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 5
by event:
  ReplaceRoute: 1
  RunInstances: 1
  TerminateInstances: 3
timeline sample:
  2026-05-03T02:26:09Z TerminateInstances
  2026-05-03T02:26:30Z TerminateInstances
  2026-05-03T02:26:31Z RunInstances
  2026-05-03T02:27:04Z ReplaceRoute
  2026-05-03T02:27:24Z TerminateInstances
```

### Log Excerpts — NAT-2a NAT-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: b9cccaad-d6b1-4b3e-b426-b3e9f3d25d6b Version: $LATEST 
  [INFO] 2026-05-03T02:30:46.343Z b9cccaad-d6b1-4b3e-b426-b3e9f3d25d6b Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0ed938ee2365f27a1 for ASG main-nat-asg-us-west-2b (instance i-07b55dd0790efce62) 
  END RequestId: b9cccaad-d6b1-4b3e-b426-b3e9f3d25d6b 
  REPORT RequestId: b9cccaad-d6b1-4b3e-b426-b3e9f3d25d6b Duration: 648.41 ms Billed Duration: 649 ms Memory Size: 128 MB Max Memory Used: 98 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 4
by event:
  ReplaceRoute: 1
  RunInstances: 1
  TerminateInstances: 2
timeline sample:
  2026-05-03T02:28:39Z TerminateInstances
  2026-05-03T02:28:40Z RunInstances
  2026-05-03T02:29:13Z ReplaceRoute
  2026-05-03T02:29:38Z TerminateInstances
```

### Log Excerpts — Private-2a

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
(no TerminateInstances/RunInstances/ReplaceRoute events in window)
```

### Log Excerpts — NAT-2a Private-2a

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 910fefcb-7108-4841-b257-04f40a0d909a Version: $LATEST 
  [INFO] 2026-05-03T02:35:03.453Z 910fefcb-7108-4841-b257-04f40a0d909a Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0720fa54aab85e17a for ASG main-nat-asg-us-west-2a (instance i-0ac959ba949553a30) 
  END RequestId: 910fefcb-7108-4841-b257-04f40a0d909a 
  REPORT RequestId: 910fefcb-7108-4841-b257-04f40a0d909a Duration: 668.05 ms Billed Duration: 669 ms Memory Size: 128 MB Max Memory Used: 98 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 12
by event:
  ReplaceRoute: 2
  RunInstances: 4
  TerminateInstances: 6
timeline sample:
  2026-05-03T02:30:31Z TerminateInstances
  2026-05-03T02:30:31Z RunInstances
  2026-05-03T02:30:39Z TerminateInstances
  2026-05-03T02:30:40Z RunInstances
  2026-05-03T02:30:46Z ReplaceRoute
  2026-05-03T02:31:04Z ReplaceRoute
  2026-05-03T02:31:16Z TerminateInstances
  2026-05-03T02:31:40Z TerminateInstances
```

### Log Excerpts — NAT-2b Private-2a

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 1ce5743d-f627-408b-861a-dbc1e84a3104 Version: $LATEST 
  [INFO] 2026-05-03T02:37:08.921Z 1ce5743d-f627-408b-861a-dbc1e84a3104 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0b8d9f93c1abf1470 for ASG main-nat-asg-us-west-2b (instance i-082ce6d0eceab5047) 
  END RequestId: 1ce5743d-f627-408b-861a-dbc1e84a3104 
  REPORT RequestId: 1ce5743d-f627-408b-861a-dbc1e84a3104 Duration: 664.86 ms Billed Duration: 665 ms Memory Size: 128 MB Max Memory Used: 98 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T02:34:30Z TerminateInstances
  2026-05-03T02:34:31Z RunInstances
  2026-05-03T02:35:03Z ReplaceRoute
  2026-05-03T02:35:19Z TerminateInstances
  2026-05-03T02:36:35Z TerminateInstances
  2026-05-03T02:36:36Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2a

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: 4e9b732b-5e11-4ecf-a578-d45f07e85fad Version: $LATEST 
  [INFO] 2026-05-03T02:39:08.813Z 4e9b732b-5e11-4ecf-a578-d45f07e85fad Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-0caddd60bc6546f62 for ASG main-nat-asg-us-west-2b (instance i-063176c9317a98542) 
  END RequestId: 4e9b732b-5e11-4ecf-a578-d45f07e85fad 
  REPORT RequestId: 4e9b732b-5e11-4ecf-a578-d45f07e85fad Duration: 617.26 ms Billed Duration: 618 ms Memory Size: 128 MB Max Memory Used: 98 MB 
  START RequestId: 58b797d3-b80b-4356-abee-a0a1437b4aec Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 8
by event:
  ReplaceRoute: 1
  RunInstances: 3
  TerminateInstances: 4
timeline sample:
  2026-05-03T02:36:58Z TerminateInstances
  2026-05-03T02:36:59Z RunInstances
  2026-05-03T02:37:08Z ReplaceRoute
  2026-05-03T02:37:56Z TerminateInstances
  2026-05-03T02:38:35Z TerminateInstances
  2026-05-03T02:38:36Z RunInstances
  2026-05-03T02:38:39Z TerminateInstances
  2026-05-03T02:38:39Z RunInstances
```

### Log Excerpts — Private-2b

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 5
by event:
  ReplaceRoute: 2
  RunInstances: 1
  TerminateInstances: 2
timeline sample:
  2026-05-03T02:39:08Z ReplaceRoute
  2026-05-03T02:39:27Z ReplaceRoute
  2026-05-03T02:39:34Z TerminateInstances
  2026-05-03T02:39:35Z RunInstances
  2026-05-03T02:40:10Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2b

**Lambda (route healer):**
```
count: 6
sample:
  INIT_START Runtime Version: python:3.12.mainlinev2.v7 Runtime Version ARN: arn:aws:lambda:us-west-2::runtime:e4ab553846c4e081013ff7d1d608a5358d5b956bb5b81c83c66d2a31da8f6244 
  [INFO] 2026-05-03T02:44:55.679Z Found credentials in environment variables. 
  START RequestId: cf2209b0-49f6-4639-ad99-fbea02904fab Version: $LATEST 
  [INFO] 2026-05-03T02:44:56.591Z cf2209b0-49f6-4639-ad99-fbea02904fab Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-0637b87176d559b91 for ASG main-nat-asg-us-west-2a (instance i-06204634069bfa52c) 
  END RequestId: cf2209b0-49f6-4639-ad99-fbea02904fab 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 3
by event:
  RunInstances: 1
  TerminateInstances: 2
timeline sample:
  2026-05-03T02:42:05Z TerminateInstances
  2026-05-03T02:42:06Z RunInstances
  2026-05-03T02:42:41Z TerminateInstances
```

### Log Excerpts — NAT-2b Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 040e9b10-4f36-43df-9dcb-4355aeeadf30 Version: $LATEST 
  [INFO] 2026-05-03T02:46:47.871Z 040e9b10-4f36-43df-9dcb-4355aeeadf30 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-071206eb3f449ad06 for ASG main-nat-asg-us-west-2b (instance i-085a56fa64766c892) 
  END RequestId: 040e9b10-4f36-43df-9dcb-4355aeeadf30 
  REPORT RequestId: 040e9b10-4f36-43df-9dcb-4355aeeadf30 Duration: 564.08 ms Billed Duration: 565 ms Memory Size: 128 MB Max Memory Used: 99 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T02:44:02Z TerminateInstances
  2026-05-03T02:44:02Z RunInstances
  2026-05-03T02:44:38Z RunInstances
  2026-05-03T02:44:38Z TerminateInstances
  2026-05-03T02:44:56Z ReplaceRoute
  2026-05-03T02:45:18Z TerminateInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2b

**Lambda (route healer):**
```
count: 10
sample:
  START RequestId: 17ea94cb-3282-4cb3-b103-2443893b359a Version: $LATEST 
  [INFO] 2026-05-03T02:49:14.240Z 17ea94cb-3282-4cb3-b103-2443893b359a Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-02b32d19b8c891a3c for ASG main-nat-asg-us-west-2b (instance i-0b82e64ed4678bcf7) 
  END RequestId: 17ea94cb-3282-4cb3-b103-2443893b359a 
  REPORT RequestId: 17ea94cb-3282-4cb3-b103-2443893b359a Duration: 674.84 ms Billed Duration: 675 ms Memory Size: 128 MB Max Memory Used: 99 MB 
  START RequestId: 825f5345-bbd1-4ba4-b989-6ee9af7bc6c2 Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 14
by event:
  ReplaceRoute: 3
  RunInstances: 5
  TerminateInstances: 6
timeline sample:
  2026-05-03T02:46:08Z RunInstances
  2026-05-03T02:46:08Z TerminateInstances
  2026-05-03T02:46:41Z TerminateInstances
  2026-05-03T02:46:42Z RunInstances
  2026-05-03T02:46:47Z ReplaceRoute
  2026-05-03T02:47:33Z TerminateInstances
  2026-05-03T02:48:04Z TerminateInstances
  2026-05-03T02:48:05Z RunInstances
```

### Log Excerpts — Private-2a Private-2b

**Lambda (route healer):**
```
(no Lambda log events in window)
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 5
by event:
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T02:49:48Z TerminateInstances
  2026-05-03T02:50:00Z TerminateInstances
  2026-05-03T02:50:01Z RunInstances
  2026-05-03T02:51:26Z RunInstances
  2026-05-03T02:51:26Z TerminateInstances
```

### Log Excerpts — NAT-2a Private-2a Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 97515cd8-1741-46ca-8ff2-49ea3d98d1eb Version: $LATEST 
  [INFO] 2026-05-03T02:52:43.941Z 97515cd8-1741-46ca-8ff2-49ea3d98d1eb Updated route 0.0.0.0/0 in rtb-05c01eaa20ece9e70 to ENI eni-020f9456d262cc84a for ASG main-nat-asg-us-west-2a (instance i-092b6db1d98f9a254) 
  END RequestId: 97515cd8-1741-46ca-8ff2-49ea3d98d1eb 
  REPORT RequestId: 97515cd8-1741-46ca-8ff2-49ea3d98d1eb Duration: 823.95 ms Billed Duration: 1393 ms Memory Size: 128 MB Max Memory Used: 98 MB Init Duration: 568.38 ms 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T02:52:08Z TerminateInstances
  2026-05-03T02:52:37Z TerminateInstances
  2026-05-03T02:52:38Z RunInstances
  2026-05-03T02:52:43Z ReplaceRoute
  2026-05-03T02:53:27Z TerminateInstances
  2026-05-03T02:53:27Z RunInstances
```

### Log Excerpts — NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
count: 4
sample:
  START RequestId: 42cab66d-dfbe-498b-8973-ee6cd89bc1f5 Version: $LATEST 
  [INFO] 2026-05-03T02:56:42.392Z 42cab66d-dfbe-498b-8973-ee6cd89bc1f5 Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-060ff0fa2b371e5c5 for ASG main-nat-asg-us-west-2b (instance i-0a570393b06de13d6) 
  END RequestId: 42cab66d-dfbe-498b-8973-ee6cd89bc1f5 
  REPORT RequestId: 42cab66d-dfbe-498b-8973-ee6cd89bc1f5 Duration: 675.52 ms Billed Duration: 676 ms Memory Size: 128 MB Max Memory Used: 98 MB 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 7
by event:
  RunInstances: 3
  TerminateInstances: 4
timeline sample:
  2026-05-03T02:54:01Z TerminateInstances
  2026-05-03T02:54:02Z RunInstances
  2026-05-03T02:54:57Z TerminateInstances
  2026-05-03T02:55:29Z TerminateInstances
  2026-05-03T02:55:29Z RunInstances
  2026-05-03T02:56:07Z TerminateInstances
  2026-05-03T02:56:08Z RunInstances
```

### Log Excerpts — NAT-2a NAT-2b Private-2a Private-2b

**Lambda (route healer):**
```
count: 8
sample:
  START RequestId: b1ff973b-4c68-4536-bbc4-1202f0800baa Version: $LATEST 
  [INFO] 2026-05-03T02:58:41.771Z b1ff973b-4c68-4536-bbc4-1202f0800baa Updated route 0.0.0.0/0 in rtb-02ac0656d64e951c7 to ENI eni-04b60029555e36193 for ASG main-nat-asg-us-west-2b (instance i-0ea4e641d395a7f52) 
  END RequestId: b1ff973b-4c68-4536-bbc4-1202f0800baa 
  REPORT RequestId: b1ff973b-4c68-4536-bbc4-1202f0800baa Duration: 607.39 ms Billed Duration: 608 ms Memory Size: 128 MB Max Memory Used: 98 MB 
  START RequestId: 6a4e641d-8df7-4234-8ab9-20136175a5be Version: $LATEST 
```

**CloudTrail (TerminateInstances / RunInstances / ReplaceRoute):**
```
count: 6
by event:
  ReplaceRoute: 1
  RunInstances: 2
  TerminateInstances: 3
timeline sample:
  2026-05-03T02:56:35Z TerminateInstances
  2026-05-03T02:56:36Z RunInstances
  2026-05-03T02:56:42Z ReplaceRoute
  2026-05-03T02:57:17Z TerminateInstances
  2026-05-03T02:58:04Z TerminateInstances
  2026-05-03T02:58:05Z RunInstances
```
