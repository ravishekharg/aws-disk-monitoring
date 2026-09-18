# Scalable Disk Monitoring for Multi-Account AWS (Ansible-first)

An Ansible-centric solution for detecting low disk space early across many
AWS accounts and VMs, built on the existing configuration-management stack
rather than a third-party monitoring platform -- CloudWatch is brought in
only where it provides something Ansible genuinely cannot (real-time
alerting, historical retention, a cross-account dashboard), and every other
piece of the pipeline is Ansible itself.

**Provider chosen: AWS.** See [docs/architecture.md](docs/architecture.md)
for the full diagram and request/data flow; this README covers the
"how/why" and how to actually run it.

## The problem, restated

- Many AWS accounts (one per acquired company / business unit), many VMs
  each, growing over time.
- Need early warning on disk space, not a post-mortem after downtime.
- Leverage Ansible (already the config-management tool) before buying
  anything new.
- Must be secure and scale as accounts/VMs are added, without per-account
  manual setup.

## Key components

### 1. Access management

- **No SSH keys anywhere.** Every VM runs the SSM Agent + an instance
  profile with `AmazonSSMManagedInstanceCore` (baked into the golden
  AMI/launch template, so it's true by construction, not by manual setup).
  Ansible connects via `community.aws.aws_ssm` -- no open port 22, no
  bastion host, every session/command audited in CloudTrail.
- **Cross-account access is a two-hop IAM role chain**, not per-account
  credentials: a central `AnsibleAutomationRole` (hub account) assumes a
  purpose-built `AnsibleSpokeRole` in each member account. The spoke role's
  permissions are scoped tightly (SSM connectivity + `PutMetricData`/alarm
  management in one namespace only -- see
  [iac/spoke-role/template.yaml](iac/spoke-role/template.yaml)); the hub
  role's `AssumeRole` permission is scoped to the AWS Organization via the
  `aws:ResourceOrgID` condition key, so it automatically covers every
  current *and future* member account with zero policy edits (see
  [iac/automation-role/template.yaml](iac/automation-role/template.yaml)).
- **Onboarding a new AWS account is "add it to the OU."** A CloudFormation
  **StackSet** targeting that OU deploys `AnsibleSpokeRole` into every
  account automatically, existing and new.

### 2. VM discovery and enrollment

- [`ansible/scripts/generate_account_inventories.py`](ansible/scripts/generate_account_inventories.py)
  calls `organizations:ListAccounts` once, then writes one AWS CLI profile
  and one Ansible dynamic-inventory file
  (`amazon.aws.aws_ec2` plugin) per discovered account into
  `ansible/inventory/accounts/`. Re-running it (on a schedule, or before
  every playbook run) is how newly created accounts get picked up -- no
  hand-edited inventory, ever.
- Within an account, instances are discovered by tag
  (`Monitoring: disk`) and filtered to `running` -- opt-in, not "every
  instance that happens to exist."
- Ansible natively merges every file in an inventory *directory*, so the
  entire multi-account fleet is just `-i inventory/accounts/`.

### 3. Data collection & aggregation

- **Collection**: the `disk_monitor` role uses Ansible's own fact-gathering
  (`ansible_facts.mounts`) -- no monitoring agent installed on any VM, no
  `df` output to parse. Used-percent is computed with plain Jinja
  arithmetic in [`tasks/collect_disk_facts.yml`](ansible/roles/disk_monitor/tasks/collect_disk_facts.yml),
  after filtering out pseudo-filesystems (`tmpfs`, `overlay`, ...) and
  noisy mount points (`/snap`, `/run`, ...).
- **Aggregation**: results are published as CloudWatch custom metrics from
  the *control node* (not the VM) via a small custom module --
  [`cloudwatch_put_metric_data`](ansible/roles/disk_monitor/library/cloudwatch_put_metric_data.py)
  -- because neither `amazon.aws` nor `community.aws` ships a
  `PutMetricData` wrapper (only alarm management). Two granularities are
  published: per-instance/per-mount (`DiskUsedPercent`, `DiskFreeGB`, for
  drill-down) and a per-account rollup (`DiskUsedPercentFleetMax`, for
  scalable alarming -- see the role's
  [README](ansible/roles/disk_monitor/README.md) for why the rollup exists).
- **Presentation**: one warning + one critical CloudWatch alarm per account
  watches the rollup metric and notifies an SNS topic; CloudWatch's
  cross-account observability (Observability Access Manager) rolls every
  account's metrics into a single dashboard without copying data around.

### 4. Scalability

| Growth dimension | What happens |
|---|---|
| New AWS account | Add to the monitored OU → StackSet auto-deploys `AnsibleSpokeRole` → next inventory-generation run discovers it. Zero manual steps. |
| New VM in an existing account | Launch with the standard tag + instance profile → discovered on the next inventory refresh. Zero manual steps. |
| More total VMs (control-plane load) | `strategy: free` lets independent hosts progress without lock-step batching; splitting execution by account/region (one EventBridge-triggered Fargate task per account) parallelizes horizontally instead of one long serial run. |
| More alarms needed | Alarms are per-account (not per-instance/mount), so alarm count scales with *accounts*, not *VMs* -- see "Why a summary metric" in the role README. |

## Repository layout

```
ansible/
  ansible.cfg                    inventory dir, roles_path, fact caching
  requirements.yml                amazon.aws / community.aws / ansible.posix
  inventory/
    aws_ec2.yml.example            single-account reference (documents the base plugin config)
    accounts/                      generated per-account inventory files (gitignored; .gitkeep only)
  group_vars/all.yml               thresholds, CloudWatch namespace, SNS topic
  roles/disk_monitor/
    library/cloudwatch_put_metric_data.py   custom module (see above)
    tasks/{main,collect_disk_facts,push_metrics,manage_alarms}.yml
    defaults/main.yml, meta/main.yml, README.md
  playbooks/
    monitor_disk.yml               entry point for the real fleet
    test_disk_facts_local.yml      no-AWS smoke test of the collection logic
  scripts/generate_account_inventories.py   the "scales automatically" piece
iac/
  spoke-role/template.yaml         AnsibleSpokeRole (deployed via StackSet to every member account)
  automation-role/template.yaml    AnsibleAutomationRole (deployed once, in the hub account)
docs/architecture.md               diagram + full request/data flow + limitations
```

## Running it

```bash
# 1. Install collections
ansible-galaxy collection install -r ansible/requirements.yml

# 2. One-time: deploy iac/automation-role/template.yaml in the hub account,
#    and iac/spoke-role/template.yaml via a StackSet targeting the monitored OU
#    (see docs/architecture.md for the exact aws cloudformation CLI invocations)

# 3. Discover every account and generate its inventory file
cd ansible
python3 scripts/generate_account_inventories.py --hub-profile automation-hub

# 4. Run the fleet-wide playbook
ansible-playbook -i inventory/accounts/ playbooks/monitor_disk.yml
```

No AWS account handy to try the core logic? Run the collection logic alone,
against your own machine, with zero AWS calls:

```bash
ansible-playbook -i localhost, -c local ansible/playbooks/test_disk_facts_local.yml
```

## What's verified vs. not

In the same spirit as being asked to design for *real* production use, not
just describe one:

| Layer | Status |
|---|---|
| Ansible playbook/role syntax | **Verified**: `ansible-playbook --syntax-check` passes clean (ansible-core 2.21). |
| Disk-fact collection + threshold logic | **Verified live**: ran `test_disk_facts_local.yml` against a real machine (see below) -- correctly computed used-percent per mount and flagged a mount at 100% used against the critical threshold. |
| Custom `cloudwatch_put_metric_data` module | Written against `AnsibleAWSModule` (the same base class every other module in these collections uses) for correct auth/region handling; not exercised against a real AWS API in this pass -- no multi-account AWS Organization was available to test against. |
| `cloudwatch_metric_alarm` task usage | Corrected against the module's actual documented parameters (`ansible-doc amazon.aws.cloudwatch_metric_alarm`) after an initial draft used the wrong collection name and a symbolic comparison operator instead of CloudWatch's enum string -- see git history for the fix. |
| CloudFormation templates | **Verified**: both pass `cfn-lint` clean. Not applied against a real AWS Organization. |

Real bugs were found and fixed during this build, not smoothed over:
`community.aws.cloudwatch_metric` (used in an early draft) doesn't exist in
either collection at all -- there is no CloudWatch `PutMetricData` wrapper
module, which is why `cloudwatch_put_metric_data.py` exists as a small
custom module rather than relying on one. `cloudwatch_metric_alarm` also
turned out to live in `amazon.aws`, not `community.aws`, and its
`comparison` parameter takes CloudWatch's full enum strings
(`GreaterThanOrEqualToThreshold`), not a symbolic operator.

## What I'd add next given more time

- SNS topic/subscription provisioning (referenced, not yet created by this repo).
- A Lambda enriching the alarm SNS message with the specific offending
  instance ID (the account-level rollup metric optimizes for alarm-count
  scalability at the cost of that detail being in the notification itself).
- Windows fleet support (`ansible.windows.win_disk_facts` in place of
  `ansible_facts.mounts`).
- A CI pipeline (GitHub Actions) running `ansible-lint` + `cfn-lint` on
  every PR against this repo.
