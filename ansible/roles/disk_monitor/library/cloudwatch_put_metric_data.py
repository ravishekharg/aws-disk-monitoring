#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Custom module: neither amazon.aws nor community.aws ships a module that
wraps CloudWatch's PutMetricData for an arbitrary custom metric (only
cloudwatch_metric_alarm, which manages alarms against metrics that already
exist) -- this fills that gap, built on the same AnsibleAWSModule base every
other module in these collections uses, so it picks up the same
profile/region/assumed-role auth args for free.
"""
from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
---
module: cloudwatch_put_metric_data
short_description: Publish a single custom CloudWatch metric data point
description:
  - Wraps C(cloudwatch:PutMetricData) for one metric/value/dimension set.
  - Always reports C(changed=true) since CloudWatch metric data points are
    write-only/non-idempotent by nature (there is nothing to check first).
options:
  namespace:
    description: CloudWatch namespace to publish under.
    required: true
    type: str
  metric_name:
    description: Name of the metric.
    required: true
    type: str
  value:
    description: The metric value to publish.
    required: true
    type: float
  unit:
    description: Unit of the value.
    required: false
    default: None
    type: str
  dimensions:
    description: Dimension name/value pairs for this data point.
    required: false
    default: {}
    type: dict
author:
  - Solutions Architecture
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
"""

EXAMPLES = r"""
- name: Publish a disk-used-percent data point
  cloudwatch_put_metric_data:
    namespace: CustomDiskMonitoring
    metric_name: DiskUsedPercent
    value: 87.5
    unit: Percent
    dimensions:
      InstanceId: i-0123456789abcdef0
      MountPoint: /data
"""

RETURN = r"""
changed:
  description: Always true -- publishing a data point is not idempotent.
  returned: always
  type: bool
"""

try:
    import botocore
except ImportError:
    pass  # handled by AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            namespace=dict(required=True, type="str"),
            metric_name=dict(required=True, type="str"),
            value=dict(required=True, type="float"),
            unit=dict(required=False, default="None", type="str"),
            dimensions=dict(required=False, default={}, type="dict"),
        ),
        supports_check_mode=True,
    )

    if module.check_mode:
        module.exit_json(changed=True, msg="Would have published metric data (check mode)")

    client = module.client("cloudwatch")
    dimensions = [{"Name": str(k), "Value": str(v)} for k, v in module.params["dimensions"].items()]

    metric_data = {
        "MetricName": module.params["metric_name"],
        "Dimensions": dimensions,
        "Value": module.params["value"],
    }
    if module.params["unit"] and module.params["unit"] != "None":
        metric_data["Unit"] = module.params["unit"]

    try:
        client.put_metric_data(Namespace=module.params["namespace"], MetricData=[metric_data])
    except (botocore.exceptions.BotoCoreError, botocore.exceptions.ClientError) as e:
        module.fail_json_aws(e, msg="Failed to publish CloudWatch metric data")

    module.exit_json(changed=True)


if __name__ == "__main__":
    main()
