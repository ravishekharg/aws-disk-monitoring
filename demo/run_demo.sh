#!/usr/bin/env bash
# Minimal-working demonstration of the whole solution against a mocked AWS
# endpoint (moto, https://github.com/getmoto/moto) -- no real AWS account
# needed to see it actually run, not just read the code.
#
# What this proves, for real, not just on paper:
#   1. Access management: a genuine two-hop STS AssumeRole chain
#      (AnsibleAutomationRole -> AnsibleSpokeRole), the same chain
#      iac/*/template.yaml define for real AWS.
#   2. Data collection: the disk_monitor role's collect_disk_facts.yml runs
#      against THIS machine's real filesystem (not fabricated numbers).
#   3. Aggregation: the collected numbers are published via real
#      cloudwatch:PutMetricData / PutMetricAlarm API calls (against the
#      mock endpoint) using the exact same task files and custom module
#      that run in production -- only AWS_ENDPOINT_URL differs.
#
# Prerequisites: moto_server running (`pip install 'moto[all]'; moto_server
# -p 5001`), ansible-core + this repo's collections installed. Run from
# WSL/Linux/macOS (ansible-core does not run natively on Windows).
#
# Usage: bash demo/run_demo.sh
set -euo pipefail

ENDPOINT="http://localhost:5001"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export AWS_ACCESS_KEY_ID=testing
export AWS_SECRET_ACCESS_KEY=testing
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL="$ENDPOINT"

json_field() {
  # $1 = json string, $2 = python expression relative to the parsed object
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))" "$1" "$2"
}

echo "=================================================================="
echo "1. Reset mock AWS state"
echo "=================================================================="
curl -s -X POST "$ENDPOINT/moto-api/reset" >/dev/null
echo "done"

echo
echo "=================================================================="
echo "2. Create AnsibleAutomationRole (hub account) -- real IAM CreateRole call"
echo "=================================================================="
aws iam create-role --role-name AnsibleAutomationRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::123456789012:root"},"Action":"sts:AssumeRole"}]}' \
  --query 'Role.Arn' --output text

echo
echo "=================================================================="
echo "3. Create AnsibleSpokeRole (member account), trust policy allows ONLY AnsibleAutomationRole"
echo "=================================================================="
aws iam create-role --role-name AnsibleSpokeRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::123456789012:role/AnsibleAutomationRole"},"Action":"sts:AssumeRole"}]}' \
  --query 'Role.Arn' --output text

aws iam put-role-policy --role-name AnsibleSpokeRole --policy-name DiskMonitoringPermissions \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["cloudwatch:PutMetricData","cloudwatch:PutMetricAlarm","cloudwatch:DescribeAlarms"],"Resource":"*"}]}'
echo "(attached the same permission set as iac/spoke-role/template.yaml, trimmed to what this demo exercises)"

echo
echo "=================================================================="
echo "4. Hop 1: assume AnsibleAutomationRole (as the control node would)"
echo "=================================================================="
HOP1=$(aws sts assume-role --role-arn arn:aws:iam::123456789012:role/AnsibleAutomationRole --role-session-name hop1-automation)
export AWS_ACCESS_KEY_ID=$(json_field "$HOP1" "d['Credentials']['AccessKeyId']")
export AWS_SECRET_ACCESS_KEY=$(json_field "$HOP1" "d['Credentials']['SecretAccessKey']")
export AWS_SESSION_TOKEN=$(json_field "$HOP1" "d['Credentials']['SessionToken']")
echo "Now operating as: $(aws sts get-caller-identity --query Arn --output text)"

echo
echo "=================================================================="
echo "5. Hop 2: from that session, assume AnsibleSpokeRole -- the real cross-account chain"
echo "=================================================================="
HOP2=$(aws sts assume-role --role-arn arn:aws:iam::123456789012:role/AnsibleSpokeRole --role-session-name hop2-spoke)
export AWS_ACCESS_KEY_ID=$(json_field "$HOP2" "d['Credentials']['AccessKeyId']")
export AWS_SECRET_ACCESS_KEY=$(json_field "$HOP2" "d['Credentials']['SecretAccessKey']")
export AWS_SESSION_TOKEN=$(json_field "$HOP2" "d['Credentials']['SessionToken']")
echo "Now operating as: $(aws sts get-caller-identity --query Arn --output text)"
echo "(this session, and only this session, is what the Ansible role below uses)"

echo
echo "=================================================================="
echo "6. Run the REAL disk_monitor role (collect + push metrics + manage alarms)"
echo "   -- same task files as production, only the AWS endpoint differs"
echo "=================================================================="
cd "$REPO_ROOT/ansible"
ansible-playbook -i localhost, -c local playbooks/demo_full_role_mock_aws.yml \
  -e "sns_topic_arn=arn:aws:sns:us-east-1:123456789012:disk-monitoring-alerts"

echo
echo "=================================================================="
echo "7. Verify: did the metrics actually land in (mock) CloudWatch?"
echo "=================================================================="
aws cloudwatch list-metrics --namespace CustomDiskMonitoring

echo
echo "=================================================================="
echo "8. Verify: were the account-level alarms actually created?"
echo "=================================================================="
aws cloudwatch describe-alarms --alarm-name-prefix disk-usage \
  --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,Threshold:Threshold,Comparison:ComparisonOperator}' \
  --output table

echo
echo "Demo complete -- collection, aggregation, and the two-hop access-management"
echo "chain all executed for real against a mock AWS endpoint."
