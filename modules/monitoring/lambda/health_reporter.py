"""Scheduled proactive infrastructure health report; sends observations, never remediates."""
import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)
asg = boto3.client("autoscaling")
elbv2 = boto3.client("elbv2")
cloudwatch = boto3.client("cloudwatch")
sqs = boto3.client("sqs")
ENV_PREFIX = os.environ.get("ENV_PREFIX", "prod")
ASG_NAME = os.environ["ASG_NAME"]
TARGET_GROUP_ARN = os.environ["TARGET_GROUP_ARN"]
QUEUE_URL = os.environ["NOTIFICATION_QUEUE_URL"]


def lambda_handler(event, context):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME]).get("AutoScalingGroups", [])
    if not groups:
        raise RuntimeError(f"Configured Auto Scaling Group not found: {ASG_NAME}")
    group = groups[0]
    instances = group.get("Instances", [])
    in_service = [i for i in instances if i.get("LifecycleState") == "InService"]
    target_descriptions = elbv2.describe_target_health(TargetGroupArn=TARGET_GROUP_ARN).get("TargetHealthDescriptions", [])
    target_states = [d.get("TargetHealth", {}).get("State", "unknown") for d in target_descriptions]
    healthy_targets = sum(state == "healthy" for state in target_states)
    unhealthy_targets = sum(state == "unhealthy" for state in target_states)
    alarm_result = cloudwatch.describe_alarms(StateValue="ALARM", MaxRecords=100)
    active_alarms = [a.get("AlarmName", "UnknownAlarm") for a in alarm_result.get("MetricAlarms", [])
                     if a.get("AlarmName", "").startswith(f"{ENV_PREFIX}-")]
    at_capacity_limit = int(group.get("DesiredCapacity", 0)) >= int(group.get("MaxSize", 0))
    if unhealthy_targets or healthy_targets == 0 or not in_service or active_alarms:
        overall = "ATTENTION REQUIRED"
        icon = "⚠️"
    elif at_capacity_limit:
        overall = "HEALTHY — CAPACITY AT MAXIMUM"
        icon = "🟡"
    else:
        overall = "HEALTHY"
        icon = "🟢"
    alarm_lines = "\n".join(f"• {name}" for name in active_alarms[:10]) if active_alarms else "• No active CloudWatch alarms"
    message = (
        f"{icon} *SCHEDULED AWS INFRASTRUCTURE HEALTH*\n*Environment:* `{ENV_PREFIX}`\n*Observed at:* {timestamp}\n"
        f"*Overall:* {overall}\n*Auto Scaling Group:* `{ASG_NAME}`\n"
        f"*Capacity:* desired {group.get('DesiredCapacity')} / min {group.get('MinSize')} / max {group.get('MaxSize')}\n"
        f"*Instances:* {len(in_service)} InService of {len(instances)} total\n"
        f"*ALB targets:* {healthy_targets} healthy, {unhealthy_targets} unhealthy, {len(target_descriptions)} total\n"
        f"*Active alarms:*\n{alarm_lines}\n"
        "_This is a point-in-time health summary, not a guarantee of application correctness._"
    )
    payload = {"type": "health_report", "environment": ENV_PREFIX, "message": message, "created_at": timestamp}
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(payload, sort_keys=True))
    logger.info("Queued scheduled health report overall=%s active_alarms=%d unhealthy_targets=%d", overall, len(active_alarms), unhealthy_targets)
    return {"status": "QUEUED", "overall": overall, "active_alarms": len(active_alarms), "unhealthy_targets": unhealthy_targets}
