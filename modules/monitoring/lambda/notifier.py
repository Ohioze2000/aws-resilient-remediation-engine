"""Deliver queued operational messages to Slack; SQS provides retries and a DLQ."""
import json
import logging
import os
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)
ddb = boto3.client("dynamodb")
WEBHOOK = os.environ.get("SLACK_WEBHOOK_URL", "")
TABLE_NAME = os.environ.get("INCIDENT_TABLE_NAME", "")
ENV_PREFIX = os.environ.get("ENV_PREFIX", "prod")


def _post(text):
    if not WEBHOOK:
        raise RuntimeError("SLACK_WEBHOOK_URL is not configured; notification must not be marked delivered")
    request = urllib.request.Request(WEBHOOK, data=json.dumps({"text": text}).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=8) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError(f"Slack webhook returned HTTP {response.status}")


def _mark(incident_id, state, detail=None, notification_type=None):
    if not incident_id or not TABLE_NAME:
        return
    field = {
        "incident_detected": "incident_notification_state",
        "remediation_result": "result_notification_state",
        "alarm_recovered": "recovery_notification_state",
    }.get(notification_type, "notification_state")
    expression = f"SET #{field} = :s, notification_updated_at = :t"
    names = {f"#{field}": field}
    values = {":s": {"S": state}, ":t": {"S": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()}}
    if detail:
        expression += ", notification_detail = :d"
        values[":d"] = {"S": detail[:1000]}
    ddb.update_item(TableName=TABLE_NAME, Key={"incident_id": {"S": incident_id}},
                    UpdateExpression=expression, ExpressionAttributeNames=names, ExpressionAttributeValues=values)


def render(event):
    kind = event.get("type", "operational_update")
    env = event.get("environment", ENV_PREFIX)
    if kind == "incident_detected":
        return (f"🚨 *INCIDENT DETECTED*\n*Environment:* `{env}`\n*Incident:* `{event.get('incident_id', 'N/A')}`\n"
                f"*Signal:* `{event.get('signal', 'unknown')}`\n*Alarm:* `{event.get('alarm_name', 'UnknownAlarm')}`\n"
                f"*Time:* `{event.get('state_change_time', 'unknown')}`\n*Reason:* {event.get('reason', 'No reason supplied')}\n"
                "*Status:* Incident recorded; remediation is being evaluated.")
    if kind == "alarm_recovered":
        return (f"🟢 *ALARM RECOVERED*\n*Environment:* `{env}`\n*Signal:* `{event.get('signal', 'unknown')}`\n"
                f"*Alarm:* `{event.get('alarm_name', 'UnknownAlarm')}`\n*Time:* `{event.get('state_change_time', 'unknown')}`\n"
                f"*Details:* {event.get('reason', 'Alarm returned to OK')}")
    if kind == "health_report":
        return event["message"]
    return event.get("message", json.dumps(event, sort_keys=True))


def lambda_handler(event, context):
    failures = []
    for record in event.get("Records", []):
        message_id = record.get("messageId")
        incident_id = None
        try:
            payload = json.loads(record["body"])
            incident_id = payload.get("incident_id")
            _post(render(payload))
            if incident_id:
                _mark(incident_id, "SENT", notification_type=payload.get("type"))
            logger.info("Slack notification delivered type=%s incident=%s", payload.get("type"), incident_id)
        except Exception as exc:
            logger.exception("Notification delivery failed; SQS will retry")
            if incident_id:
                try:
                    _mark(incident_id, "RETRYING", str(exc), notification_type=payload.get("type"))
                except Exception:
                    logger.exception("Unable to persist notification failure")
            failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
