# disk_monitor

Collects per-mount disk usage from a managed instance using Ansible's own
fact-gathering (`ansible_facts.mounts` -- no agent, no `df` parsing), and
publishes it as CloudWatch custom metrics with per-account alarm
reconciliation.

## What it does

1. Gathers mount facts (device, filesystem, size, free space).
2. Filters out pseudo/virtual filesystems (`tmpfs`, `overlay`, etc.) and
   noisy mount points (`/snap`, `/run`, ...).
3. Computes used-percent per real mount.
4. Publishes two per-instance metrics (`DiskUsedPercent`, `DiskFreeGB`) and
   one per-account rollup (`DiskUsedPercentFleetMax`) to CloudWatch.
5. Ensures a warning + critical CloudWatch alarm exists per account,
   watching the rollup metric (see "Why a summary metric" below).

## Why a summary metric

CloudWatch alarms watch one fully-specified metric + dimension set each.
Alarming per instance-and-mount would mean one alarm per (instance, mount)
pair -- thousands of alarms at real fleet scale, most of them idle. Instead,
every host in an account publishes into the same `DiskUsedPercentFleetMax`
metric (dimensioned only by `Account`), and CloudWatch's own `Maximum`
statistic does the fan-in: the account-level alarm fires the moment *any*
contributing instance reports a value over threshold, with no per-instance
alarm bookkeeping to maintain as the fleet grows. The detailed
per-instance/per-mount metrics are still published and available on the
dashboard for drill-down once an alarm has fired.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `cloudwatch_namespace` | `CustomDiskMonitoring` | CloudWatch namespace for all metrics |
| `disk_warning_threshold` | `80` | Percent-used warning alarm threshold |
| `disk_critical_threshold` | `90` | Percent-used critical alarm threshold |
| `excluded_fstypes` | see `defaults/main.yml` | Filesystem types never monitored |
| `excluded_mount_prefixes` | see `defaults/main.yml` | Mount-point prefixes never monitored |
| `manage_alarms` | `true` | Set `false` to only push metrics, skip alarm reconciliation |
| `aws_account_id` | (from inventory `compose`) | Used to dimension/name per-account metrics and alarms |
| `sns_topic_arn` | (group_vars) | Where alarm state changes are sent |

## Requires

- Collections: `amazon.aws`, `community.aws` (see `ansible/requirements.yml`)
- The control node's active AWS session (the assumed `AnsibleSpokeRole` for
  the target account) needs `cloudwatch:PutMetricData`,
  `cloudwatch:PutMetricAlarm`, `cloudwatch:DescribeAlarms`. See
  `iac/spoke-role/template.yaml`.
