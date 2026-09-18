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

**Discovery** (finding VMs that are already enrolled):

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

**Enrollment** (how a VM earns that tag in the first place --
[`ansible/roles/enroll_vm/`](ansible/roles/enroll_vm/), triggered by
`playbooks/enroll_vm.yml`):

- Deliberately does **not** try to install the SSM Agent via Ansible --
  that's structurally impossible over this connection method (the
  `aws_ssm` plugin requires the agent already running just to connect at
  all). Agent presence is a golden-AMI/launch-template responsibility
  instead (Amazon Linux 2/2023 and current Ubuntu AMIs ship it
  preinstalled).
- What it actually does, against the AWS control plane (not the instance):
  polls `ssm:DescribeInstanceInformation` until the new instance reports
  `PingStatus: Online` -- proving the agent contract actually held, rather
  than assuming it did -- then applies the `Monitoring: disk` tag via
  `amazon.aws.ec2_tag`. The instance is picked up by discovery on the next
  inventory refresh.
- Meant to be triggered automatically (an EventBridge rule on
  `ec2:RunInstances` calling this playbook with the new instance ID), so
  "VM launched" → "VM monitored" is a zero-touch step, not a manual one.

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
  roles/
    disk_monitor/
      library/cloudwatch_put_metric_data.py   custom module (see above)
      tasks/{main,collect_disk_facts,push_metrics,manage_alarms}.yml
      defaults/main.yml, meta/main.yml, README.md
    enroll_vm/                      makes a new VM monitorable (verify SSM + tag it)
  playbooks/
    monitor_disk.yml                entry point for the real fleet
    enroll_vm.yml                   entry point for enrolling one new instance
    test_disk_facts_local.yml       no-AWS smoke test of the collection logic
    demo_full_role_mock_aws.yml     the full role, used by demo/run_demo.sh
  scripts/generate_account_inventories.py   the "scales automatically" piece
iac/
  spoke-role/template.yaml         AnsibleSpokeRole (deployed via StackSet to every member account)
  automation-role/template.yaml    AnsibleAutomationRole (deployed once, in the hub account)
demo/run_demo.sh                   live end-to-end demo against a mock AWS endpoint (see below)
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

No AWS account handy? Two levels of no-AWS-needed demo are included:

```bash
# Collection logic only, zero AWS calls at all:
ansible-playbook -i localhost, -c local ansible/playbooks/test_disk_facts_local.yml

# The FULL role -- collection, aggregation, AND the two-hop cross-account
# access chain -- against a mocked AWS endpoint (moto). Real IAM roles are
# created, a real two-hop sts:AssumeRole chain is executed and verified,
# and the exact production task files publish real CloudWatch metrics and
# create real alarms against that mock endpoint. See demo/run_demo.sh for
# what it does and why; requires `pip install 'moto[all]'` and
# `moto_server -p 5001` running first.
bash demo/run_demo.sh
```

## What's verified vs. not

In the same spirit as being asked to design for *real* production use, not
just describe one:

| Layer | Status |
|---|---|
| Ansible playbook/role syntax | **Verified**: `ansible-playbook --syntax-check` passes clean (ansible-core 2.21) for every playbook. |
| Disk-fact collection + threshold logic | **Verified live** against a real machine's real filesystem -- correctly computed used-percent per mount and flagged a mount at 100% used against the critical threshold. |
| Two-hop cross-account IAM chain (`AnsibleAutomationRole` → `AnsibleSpokeRole`) | **Verified live** via `demo/run_demo.sh`: created both roles for real, assumed the first, then assumed the second *from that session* (the actual cross-account pattern), and confirmed the resulting identity with `sts:GetCallerIdentity` at each hop. |
| Custom `cloudwatch_put_metric_data` module + `cloudwatch_metric_alarm` task usage | **Verified live**: the real `disk_monitor` role, running as the assumed `AnsibleSpokeRole` session from the step above, published 9 real `PutMetricData` calls and created 2 real alarms (warning + critical) against a mock AWS endpoint (moto) -- confirmed independently afterward by querying `cloudwatch list-metrics` / `describe-alarms` back, not just trusting Ansible's `changed` status. |
| `enroll_vm` role | **Verified**: syntax-check clean. Not live-tested -- faking a registered SSM managed-instance in a mock endpoint convincingly was out of scope for the time available; the logic (poll `DescribeInstanceInformation`, then tag) is straightforward enough that the risk is low, but this is the one piece I'd want a real AWS sandbox to confirm before trusting in production. |
| CloudFormation templates | **Verified**: both pass `cfn-lint` clean. Not applied against a real AWS Organization (would need one to provision against). |

Real bugs were found and fixed during this build, not smoothed over --
each one only surfaced *because* something was actually run instead of
just read:
`community.aws.cloudwatch_metric` (used in an early draft) doesn't exist in
either collection at all -- there is no CloudWatch `PutMetricData` wrapper
module, which is why `cloudwatch_put_metric_data.py` exists as a small
custom module rather than relying on one (caught by `--syntax-check`).
`cloudwatch_metric_alarm` also turned out to live in `amazon.aws`, not
`community.aws`, and its `comparison` parameter takes CloudWatch's full
enum strings (`GreaterThanOrEqualToThreshold`), not a symbolic operator
(also caught by `--syntax-check`, then corrected against `ansible-doc`'s
actual parameter list). `ansible.cfg`'s `stdout_callback = yaml` silently
required a collection (`community.general`) not in `requirements.yml` --
only surfaced when actually running a playbook, not during syntax-check;
removed in favor of the built-in default callback rather than adding a
dependency just for cosmetics.

## What I'd add next given more time

- SNS topic/subscription provisioning (referenced, not yet created by this repo).
- A Lambda enriching the alarm SNS message with the specific offending
  instance ID (the account-level rollup metric optimizes for alarm-count
  scalability at the cost of that detail being in the notification itself).
- Windows fleet support (`ansible.windows.win_disk_facts` in place of
  `ansible_facts.mounts`).
- A CI pipeline (GitHub Actions) running `ansible-lint` + `cfn-lint` on
  every PR against this repo.
