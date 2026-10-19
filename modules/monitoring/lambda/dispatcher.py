"""Normalize CloudWatch alarm events, persist incidents, and enqueue durable Slack updates."""
import hashlib
import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)
ddb = boto3.client("dynamodb")
sqs = boto3.client("sqs")
lambda_client = boto3.client("lambda")
TABLE_NAME = os.environ["INCIDENT_TABLE_NAME"]
WORKER_FUNCTION_NAME = os.environ["WORKER_FUNCTION_NAME"]
ENV_PREFIX = os.environ.get("ENV_PREFIX", "prod")
QUEUE_URL = os.environ["NOTIFICATION_QUEUE_URL"]
TTL_SECONDS = int(os.environ.get("INCIDENT_TTL_SECONDS", "604800"))


def _now():
    return datetime.now(timezone.utc).isoformat()


def _incident_id(alarm_name, state_change_time):
    raw = f"{alarm_name}|{state_change_time}"
    return "INC-" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16].upper()


def _ttl():
    return int(datetime.now(timezone.utc).timestamp()) + TTL_SECONDS


def _signal_for_alarm(name):
    name = name.lower()
    if "cpu-anomaly" in name or "cpu-anomaly" in name.replace("_", "-"):
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


def _queue_notification(payload):
    # SQS provides durable delivery, bounded retries and a DLQ; message delivery is
    # intentionally independent from remediation outcome.
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(payload, sort_keys=True))


def _dispatch_worker(incident_id, message):
    payload = {
        "incident_id": incident_id,
        "environment": ENV_PREFIX,
        "signal": _signal_for_alarm(message.get("AlarmName", "")),
        "alarm": message,
    }
    result = lambda_client.invoke(
        FunctionName=WORKER_FUNCTION_NAME,
        InvocationType="Event",
        Payload=json.dumps(payload).encode("utf-8"),
    )
    if result.get("StatusCode") not in (200, 202):
        raise RuntimeError(f"Worker asynchronous invoke returned {result.get('StatusCode')}")
    ddb.update_item(
        TableName=TABLE_NAME,
        Key={"incident_id": {"S": incident_id}},
        UpdateExpression="SET dispatch_state = :d, dispatched_at = :t",
        ExpressionAttributeValues={":d": {"S": "DISPATCHED"}, ":t": {"S": _now()}},
    )
    return payload


def lambda_handler(event, context):
    accepted = []
    for record in event.get("Records", []):
        try:
            message = json.loads(record["Sns"]["Message"])
        except (KeyError, TypeError, json.JSONDecodeError):
            logger.exception("Skipping malformed SNS alarm message")
            continue

        alarm_name = str(message.get("AlarmName", "UnknownAlarm"))
        state = str(message.get("NewStateValue", "UNKNOWN"))
        state_change_time = str(message.get("StateChangeTime", ""))
        if state != "ALARM":
            # CloudWatch OK transitions are useful team visibility, but never start remediation.
            if state == "OK":
                _queue_notification({
                    "type": "alarm_recovered", "environment": ENV_PREFIX,
                    "alarm_name": alarm_name, "signal": _signal_for_alarm(alarm_name),
                    "state_change_time": state_change_time or _now(),
                    "reason": str(message.get("NewStateReason", "Alarm returned to OK"))[:1000],
                })
            logger.info("Processed non-ALARM state %s for %s", state, alarm_name)
            continue
        if not state_change_time:
            logger.error("Alarm %s has no StateChangeTime; refusing non-idempotent dispatch", alarm_name)
            continue

        incident_id = _incident_id(alarm_name, state_change_time)
        now = _now()
        item = {
            "incident_id": {"S": incident_id}, "alarm_name": {"S": alarm_name},
            "signal": {"S": _signal_for_alarm(alarm_name)}, "state_change_time": {"S": state_change_time},
            "environment": {"S": ENV_PREFIX}, "status": {"S": "RECEIVED"},
            "dispatch_state": {"S": "PENDING"}, "notification_state": {"S": "PENDING"},
            "created_at": {"S": now}, "updated_at": {"S": now}, "expires_at": {"N": str(_ttl())},
            "alarm": {"S": json.dumps(message)},
        }
        try:
            ddb.put_item(TableName=TABLE_NAME, Item=item, ConditionExpression="attribute_not_exists(incident_id)")
            created = True
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            created = False
            existing = ddb.get_item(TableName=TABLE_NAME, Key={"incident_id": {"S": incident_id}}, ConsistentRead=True).get("Item", {})
            if existing.get("dispatch_state", {}).get("S") == "DISPATCHED":
                logger.info("Duplicate incident already dispatched: %s", incident_id)
                continue
            notification_state = existing.get("incident_notification_state", {}).get("S", "PENDING")
        else:
            notification_state = "PENDING"

        # Queue immediate incident awareness if it has not already been recorded as queued.
        # A narrow send/DB-update race can produce duplicate Slack messages, but not duplicate
        # remediation; at-least-once notification is preferred to silently losing the alert.
        if notification_state in {"PENDING", "QUEUE_FAILED"}:
            _queue_notification({
                "type": "incident_detected", "incident_id": incident_id,
                "environment": ENV_PREFIX, "alarm_name": alarm_name,
                "signal": _signal_for_alarm(alarm_name), "state_change_time": state_change_time,
                "reason": str(message.get("NewStateReason", "CloudWatch alarm entered ALARM"))[:1000],
            })
            ddb.update_item(TableName=TABLE_NAME, Key={"incident_id": {"S": incident_id}},
                            UpdateExpression="SET incident_notification_state = :s, incident_notification_queued_at = :t",
                            ExpressionAttributeValues={":s": {"S": "QUEUED"}, ":t": {"S": _now()}})
        _dispatch_worker(incident_id, message)
        accepted.append(incident_id)
    return {"accepted_incidents": accepted}
