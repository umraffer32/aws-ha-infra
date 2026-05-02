# Resilience Testing

The stack was tested with direct failure injection against live EC2 instances. Tests terminated instances with the AWS CLI and measured time until replacement instances were visible and manageable through SSM.

Stale terminated instance IDs were filtered out so the timing reflected real replacements, not cached SSM inventory.

This document contains both historical narrative snapshots and raw automated run artifacts appended by `failure-sim.sh`. For the current state, use the latest `## Automated Run` section near the end of this file.

## Baseline

`terraform destroy` followed by `terraform apply` restored all four SSM-managed instances in 105 seconds.

The final four instances appeared in SSM 28 seconds after `terraform apply` completed.

## Latest Snapshot (2026-05-02)

Most recent full-matrix automated run (`Run timestamp: 2026-05-02T22:48:32Z`) produced:

- Recovery band: `85s` to `197s`
- Median recovery: `154s`
- Average recovery: `149s`
- CloudTrail events in run window (`TerminateInstances` / `RunInstances` / `ReplaceRoute`): `92`
- NAT route healer Lambda log events in run window: `76`

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

Recovery is gated by NAT bootstrap time, not route replacement. The healer can update a route within roughly 60-90 seconds, but the replacement NAT instance still has to install packages, configure iptables, and disable source/destination checks.

Single-instance failures are generally faster than multi-instance failures, but can vary between runs. In the 2026-05-01 historical snapshot they recovered in 55-76 seconds; in the latest 2026-05-02 run they recovered in 85-142 seconds.

SSM sessions were durable under NAT loss. Existing private-instance SSM sessions survived blackhole windows of up to 123 seconds.

AZ isolation held across the full matrix. Failures in one AZ did not break recovery in the other AZ.

Across runs, recovery remains dominated by ASG replacement, bootstrap, and SSM registration time. The 2026-05-01 band was 55-158 seconds, while the latest 2026-05-02 automated run was 85-197 seconds.

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
