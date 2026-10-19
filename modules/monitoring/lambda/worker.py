"""Bounded remediation worker with durable claims and signal-specific verification.

Safety defaults: ambiguous aggregate alarms are not acted on destructively; missing
metrics or verification timeouts never count as recovery; Slack is best-effort only.
"""
import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

elbv2 = boto3.client("elbv2")
autoscaling = boto3.client("autoscaling")
ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
cloudwatch = boto3.client("cloudwatch")
ddb = boto3.client("dynamodb")
sqs = boto3.client("sqs")

TARGET_GROUP_ARN = os.environ["TARGET_GROUP_ARN"]
ASG_NAME = os.environ["ASG_NAME"]
ENV_PREFIX = os.environ.get("ENV_PREFIX", "prod")
MAX_CAPACITY = int(os.environ.get("MAX_CAPACITY", "4"))
CPU_THRESHOLD = float(os.environ.get("CPU_ALARM_THRESHOLD", "80"))
MEMORY_THRESHOLD = float(os.environ.get("MEMORY_ALARM_THRESHOLD", "80"))
DISK_THRESHOLD = float(os.environ.get("DISK_ALARM_THRESHOLD", "70"))
APP_ERROR_THRESHOLD = float(os.environ.get("APP_ERROR_THRESHOLD", "5"))
DISK_FSTYPE = os.environ.get("DISK_FSTYPE", "ext4")
INCIDENT_TABLE_NAME = os.environ["INCIDENT_TABLE_NAME"]
NOTIFICATION_QUEUE_URL = os.environ["NOTIFICATION_QUEUE_URL"]
VERIFICATION_DELAY = max(0, int(os.environ.get("VERIFICATION_DELAY_SECONDS", "15")))
VERIFICATION_ATTEMPTS = max(1, int(os.environ.get("VERIFICATION_ATTEMPTS", "5")))
VERIFICATION_INTERVAL = max(1, int(os.environ.get("VERIFICATION_INTERVAL_SECONDS", "10")))
LOCK_TTL_SECONDS = max(60, int(os.environ.get("REMEDIATION_LOCK_TTL_SECONDS", "180")))

TERMINAL_STATUSES = {"SUCCEEDED", "FAILED", "UNVERIFIED", "RECOVERED_NO_ACTION"}


def _now():
    return datetime.now(timezone.utc).isoformat()


def _ddb_value(value):
    if isinstance(value, bool):
        return {"BOOL": value}
    if isinstance(value, (int, float)):
        return {"N": str(value)}
    return {"S": str(value)}


def update_incident(incident_id, status=None, **fields):
    names, values, updates = {}, {}, []
    if status is not None:
        names["#status"] = "status"
        values[":status"] = {"S": status}
        updates.append("#status = :status")
    fields["updated_at"] = _now()
    for index, (key, value) in enumerate(fields.items()):
        names[f"#f{index}"] = key
        values[f":f{index}"] = _ddb_value(value)
        updates.append(f"#f{index} = :f{index}")
    ddb.update_item(
        TableName=INCIDENT_TABLE_NAME,
        Key={"incident_id": {"S": incident_id}},
        UpdateExpression="SET " + ", ".join(updates),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


def alarm(event):
    return event.get("alarm", {})


def classify_signal(event):
    supplied = event.get("signal")
    if supplied in {"cpu", "cpu_anomaly", "memory", "disk", "alb_unhealthy_targets", "application_errors"}:
        return supplied
    name = str(alarm(event).get("AlarmName", "")).lower()
    if "cpu-anomaly" in name:
        return "cpu_anomaly"
    if "cpu" in name:
        return "cpu"
    if "memory" in name or "mem_used" in name:
        return "memory"
    if "disk" in name:
        return "disk"
    if "unhealthy-target" in name or "unhealthyhostcount" in name:
        return "alb_unhealthy_targets"
    if "app-log-errors" in name or "app-error" in name:
        return "application_errors"
    return "unknown"


def _claim_lock(incident_id):
    now = int(time.time())
    lock_id = f"REMEDIATION-LOCK#{ENV_PREFIX}"
    try:
        ddb.update_item(
            TableName=INCIDENT_TABLE_NAME,
            Key={"incident_id": {"S": lock_id}},
            UpdateExpression="SET lock_owner = :owner, lock_expires_at = :expires, lock_acquired_at = :at",
            ConditionExpression="attribute_not_exists(lock_owner) OR lock_expires_at < :now OR lock_owner = :owner",
            ExpressionAttributeValues={
                ":owner": {"S": incident_id},
                ":expires": {"N": str(now + LOCK_TTL_SECONDS)},
                ":now": {"N": str(now)},
                ":at": {"S": _now()},
            },
        )
        return True
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return False
        raise


def _release_lock(incident_id):
    lock_id = f"REMEDIATION-LOCK#{ENV_PREFIX}"
    try:
        ddb.update_item(
            TableName=INCIDENT_TABLE_NAME,
            Key={"incident_id": {"S": lock_id}},
            UpdateExpression="REMOVE lock_owner, lock_expires_at, lock_acquired_at",
            ConditionExpression="lock_owner = :owner",
            ExpressionAttributeValues={":owner": {"S": incident_id}},
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
            raise


def _claim_incident(incident_id):
    try:
        ddb.update_item(
            TableName=INCIDENT_TABLE_NAME,
            Key={"incident_id": {"S": incident_id}},
            UpdateExpression="SET #status = :claimed, worker_claimed_at = :at, updated_at = :at",
            ConditionExpression="attribute_not_exists(#status) OR (#status = :received) OR (#status = :dispatch_failed)",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":claimed": {"S": "CLAIMED"},
                ":received": {"S": "RECEIVED"},
                ":dispatch_failed": {"S": "DISPATCH_FAILED"},
                ":at": {"S": _now()},
            },
        )
        return True
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return False
        raise


def asg_state():
    groups = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME]).get("AutoScalingGroups", [])
    if not groups:
        raise RuntimeError(f"Auto Scaling Group not found: {ASG_NAME}")
    group = groups[0]
    instances = [i["InstanceId"] for i in group.get("Instances", []) if i.get("LifecycleState") == "InService"]
    return group, instances


def target_health():
    return elbv2.describe_target_health(TargetGroupArn=TARGET_GROUP_ARN).get("TargetHealthDescriptions", [])


def unhealthy_targets():
    return [d for d in target_health() if d.get("TargetHealth", {}).get("State") == "unhealthy"]


def scale_out(reason):
    group, _ = asg_state()
    desired = int(group["DesiredCapacity"])
    maximum = min(int(group["MaxSize"]), MAX_CAPACITY)
    if desired >= maximum:
        return {"changed": False, "summary": f"Scale-out blocked at remediation ceiling {maximum}: {reason}"}
    autoscaling.set_desired_capacity(AutoScalingGroupName=ASG_NAME, DesiredCapacity=desired + 1, HonorCooldown=True)
    return {"changed": True, "summary": f"Requested bounded scale-out from {desired} to {desired + 1}: {reason}"}


def replace_unhealthy_target(incident_id):
    targets = unhealthy_targets()
    if not targets:
        return {"changed": False, "summary": "No unhealthy ALB target was found at diagnosis time."}
    # Never act on IP/Lambda targets or a target that is not an EC2 member of this ASG.
    group, _ = asg_state()
    target = next((d for d in targets if d.get("Target", {}).get("Id") in {i.get("InstanceId") for i in group.get("Instances", [])}), None)
    if target is None:
        return {"changed": False, "summary": "Unhealthy target could not be safely mapped to an EC2 instance in the configured ASG; manual review required."}
    instance_id = target["Target"]["Id"]
    ec2.create_tags(Resources=[instance_id], Tags=[{"Key": "Incident_Status", "Value": "Quarantined"}, {"Key": "Incident_ID", "Value": incident_id}])
    elbv2.deregister_targets(TargetGroupArn=TARGET_GROUP_ARN, Targets=[{"Id": instance_id}])
    autoscaling.detach_instances(AutoScalingGroupName=ASG_NAME, InstanceIds=[instance_id], ShouldDecrementDesiredCapacity=False)
    return {"changed": True, "summary": f"Detached unhealthy ASG instance {instance_id}; desired capacity preserved for replacement."}


def _alarm_is_ok(alarm_name):
    if not alarm_name:
        return False, "MISSING"
    result = cloudwatch.describe_alarms(AlarmNames=[alarm_name]).get("MetricAlarms", [])
    if not result:
        return False, "MISSING"
    state = result[0].get("StateValue", "INSUFFICIENT_DATA")
    return state == "OK", state


def _recent_metric_values(namespace, metric_name, dimensions, period):
    now = datetime.now(timezone.utc)
    result = cloudwatch.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=[{"Name": key, "Value": str(value)} for key, value in dimensions.items()],
        StartTime=now - __import__("datetime").timedelta(seconds=period * 4),
        EndTime=now,
        Period=period,
        Statistics=["Average" if namespace != "CustomAppMetrics" else "Sum"],
    )
    points = sorted(result.get("Datapoints", []), key=lambda item: item["Timestamp"])
    return [float(point.get("Average", point.get("Sum", 0))) for point in points[-2:]]


def verify_signal(signal, event):
    name = str(alarm(event).get("AlarmName", ""))
    alarm_ok, alarm_state = _alarm_is_ok(name)
    result = {"signal": signal, "originating_alarm_ok": alarm_ok, "originating_alarm_state": alarm_state,
              "originating_alarm": f"originating_alarm_state={alarm_state}"}
    try:
        if signal == "alb_unhealthy_targets":
            descriptions = target_health()
            healthy = sum(1 for d in descriptions if d.get("TargetHealth", {}).get("State") == "healthy")
            unhealthy = sum(1 for d in descriptions if d.get("TargetHealth", {}).get("State") == "unhealthy")
            group, instances = asg_state()
            capacity_ok = len(instances) >= int(group["MinSize"]) and int(group["DesiredCapacity"]) >= int(group["MinSize"])
            result.update({"healthy_targets": healthy, "unhealthy_targets": unhealthy, "in_service": len(instances), "capacity_ok": capacity_ok})
            result["success"] = alarm_ok and unhealthy == 0 and healthy > 0 and capacity_ok
            return result

        if signal == "cpu":
            values = _recent_metric_values("AWS/EC2", "CPUUtilization", {"AutoScalingGroupName": ASG_NAME}, 300)
            group, instances = asg_state()
            capacity_ok = len(instances) >= int(group["MinSize"]) and int(group["DesiredCapacity"]) >= int(group["MinSize"])
            metric_ok = len(values) >= 2 and all(value < CPU_THRESHOLD for value in values)
            result.update({"recent_cpu_percent": values, "metric_below_threshold": metric_ok, "capacity_ok": capacity_ok})
            result["success"] = alarm_ok and metric_ok and capacity_ok
        elif signal == "memory":
            values = _recent_metric_values("CWAgent", "mem_used_percent", {"AutoScalingGroupName": ASG_NAME}, 300)
            group, instances = asg_state()
            capacity_ok = len(instances) >= int(group["MinSize"]) and int(group["DesiredCapacity"]) >= int(group["MinSize"])
            metric_ok = len(values) >= 2 and all(value < MEMORY_THRESHOLD for value in values)
            result.update({"recent_memory_percent": values, "metric_below_threshold": metric_ok, "capacity_ok": capacity_ok})
            result["success"] = alarm_ok and metric_ok and capacity_ok
        elif signal == "disk":
            values = _recent_metric_values("CWAgent", "disk_used_percent", {"AutoScalingGroupName": ASG_NAME, "path": "/", "fstype": DISK_FSTYPE}, 120)
            metric_ok = len(values) >= 2 and all(value < DISK_THRESHOLD for value in values)
            result.update({"recent_disk_percent": values, "metric_below_threshold": metric_ok,
                           "note": "Observe-only signal: no cleanup was issued; recovery is reported only if recent disk metrics and the alarm both clear."})
            result["success"] = alarm_ok and metric_ok
        elif signal == "application_errors":
            values = _recent_metric_values("CustomAppMetrics", f"{ENV_PREFIX}-AppErrorCount", {}, 60)
            metric_ok = len(values) >= 2 and all(value < APP_ERROR_THRESHOLD for value in values)
            result.update({"recent_application_error_counts": values, "metric_below_threshold": metric_ok,
                           "note": "Observe-only signal: no restart/scale action was issued; recent error metrics must clear before reporting recovery."})
            result["success"] = alarm_ok and metric_ok
        else:
            result.update({"success": False, "note": "Unknown or anomaly-only signal; no destructive action is allowed."})
    except Exception as exc:
        result.update({"success": False, "verification_error": str(exc)})
    return result


def remediate(event):
    signal = classify_signal(event)
    name = str(alarm(event).get("AlarmName", "UnknownAlarm"))
    if signal == "cpu_anomaly":
        return {"action": "observe_only_anomaly_warning", "changed": False,
                "summary": "CPU anomaly detected; no scaling action taken from anomaly detection alone. Correlate with sustained utilization, latency, and capacity before changing resources."}
    if signal in {"cpu", "memory"}:
        return {"action": "bounded_scale_out", **scale_out(name)}
    if signal == "alb_unhealthy_targets":
        return {"action": "replace_unhealthy_target", **replace_unhealthy_target(event["incident_id"])}
    if signal == "disk":
        return {"action": "observe_only", "changed": False, "summary": "No disk cleanup issued: current alarm is ASG-aggregated and does not identify a safe instance/filesystem target."}
    if signal == "application_errors":
        return {"action": "observe_only", "changed": False, "summary": "Application error spike recorded for investigation; no blind scale-out or instance replacement."}
    return {"action": "observe_only", "changed": False, "summary": "No remediation rule matched this signal."}


def _notify(incident_id, message, success, status=None):
    """Queue the result without allowing notification failure to rewrite remediation outcome."""
    payload = {
        "type": "remediation_result", "incident_id": incident_id,
        "environment": ENV_PREFIX, "success": bool(success),
        "status": status or ("SUCCEEDED" if success else "FAILED"),
        "message": message,
    }
    last_error = None
    for attempt in range(1, 4):
        try:
            sqs.send_message(QueueUrl=NOTIFICATION_QUEUE_URL, MessageBody=json.dumps(payload, sort_keys=True))
            update_incident(incident_id, result_notification_state="QUEUED", result_notification_queued_at=_now())
            return True
        except Exception as exc:
            last_error = exc
            logger.exception("Failed to queue notification for incident %s (attempt %s/3)", incident_id, attempt)
            if attempt < 3:
                time.sleep(attempt)
    # Keep the remediation result intact. A log metric/alarm surfaces delivery-intent failure.
    try:
        update_incident(incident_id, result_notification_state="QUEUE_FAILED",
                        result_notification_detail=str(last_error)[:1000],
                        result_notification_payload=json.dumps(payload, sort_keys=True))
    except Exception:
        logger.exception("Could not persist notification queue failure for %s", incident_id)
    return False


def lambda_handler(event, context):
    incident_id = event["incident_id"]
    signal = classify_signal(event)
    name = str(alarm(event).get("AlarmName", "UnknownAlarm"))

    if not _claim_incident(incident_id):
        logger.info("Incident already claimed or terminal; ignoring duplicate worker invocation: %s", incident_id)
        return {"incident_id": incident_id, "status": "DUPLICATE_IGNORED"}
    if not _claim_lock(incident_id):
        update_incident(incident_id, "UNVERIFIED", reason="Another remediation is active for this environment", signal=signal)
        _notify(incident_id, f"⚠️ SELF-HEALING deferred: incident `{incident_id}` ({name}) could not acquire the environment remediation lock. Manual review/retry required.", False, "UNVERIFIED")
        return {"incident_id": incident_id, "status": "UNVERIFIED", "reason": "lock_busy"}

    try:
        update_incident(incident_id, "REMEDIATING", signal=signal, action_started_at=_now())
        # Avoid acting on a stale notification when the source alarm already recovered.
        initial_ok, initial_state = _alarm_is_ok(name)
        if initial_ok and signal != "unknown":
            remediation = {
                "action": "no_op_already_recovered",
                "changed": False,
                "summary": "Source alarm was already OK when the worker started; no remediation action was issued.",
            }
        else:
            remediation = remediate(event)
        update_incident(incident_id, "VERIFYING", action=remediation["action"], remediation_summary=remediation["summary"], remediation_changed=remediation["changed"], initial_alarm_state=initial_state)
        if VERIFICATION_DELAY:
            time.sleep(min(VERIFICATION_DELAY, 30))
        verification = {"success": False, "signal": signal, "attempts": 0}
        for attempt in range(1, VERIFICATION_ATTEMPTS + 1):
            verification = verify_signal(signal, event)
            verification["attempts"] = attempt
            if verification.get("success"):
                break
            if attempt < VERIFICATION_ATTEMPTS:
                time.sleep(VERIFICATION_INTERVAL)
        if verification.get("success"):
            status = "RECOVERED_NO_ACTION" if remediation["action"].startswith("observe_only") else "SUCCEEDED"
        elif remediation["action"].startswith("observe_only") or signal in {"unknown", "cpu_anomaly"} or verification.get("originating_alarm_state") in {"INSUFFICIENT_DATA", "MISSING"}:
            status = "UNVERIFIED"
        else:
            status = "FAILED"  # remediation attempted but required independent checks did not pass
        update_incident(incident_id, status, verification=json.dumps(verification, sort_keys=True), completed_at=_now())
        icon = "✅" if status == "SUCCEEDED" else "⚠️"
        message = (
            f"{icon} *SELF-HEALING {status}*\n*Incident:* `{incident_id}`\n*Environment:* `{ENV_PREFIX}`\n"
            f"*Signal:* `{signal}`\n*Alarm:* `{name}`\n*Action:* {remediation['summary']}\n"
            f"*Verification:* `{json.dumps(verification, sort_keys=True)}`"
        )
        _notify(incident_id, message, status == "SUCCEEDED", status)
        return {"incident_id": incident_id, "status": status, "signal": signal, "verification": verification}
    except Exception as exc:
        logger.exception("Worker failed for incident %s", incident_id)
        try:
            update_incident(incident_id, "FAILED", error=str(exc)[:2000], completed_at=_now())
        except Exception:
            logger.exception("Failed to persist worker failure for %s", incident_id)
        _notify(incident_id, f"🚨 *SELF-HEALING FAILED*\n*Incident:* `{incident_id}`\n*Environment:* `{ENV_PREFIX}`\n*Alarm:* `{name}`\n*Error:* `{str(exc)[:1000]}`", False, "FAILED")
        raise
    finally:
        _release_lock(incident_id)
