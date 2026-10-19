# Bounded Remediation Architecture — DynamoDB Incident State

## Event flow

CloudWatch Alarm → SNS → Dispatcher Lambda → DynamoDB conditional incident record → SQS notification + Worker Lambda → bounded action → signal-specific recovery verification → outcome notification → SQS notifier Lambda → Slack. EventBridge also triggers scheduled point-in-time health reports; CloudWatch CPU anomaly detection sends an observe-only warning.

## Incident record and idempotency

The dispatcher derives a stable incident ID from the CloudWatch alarm name and `StateChangeTime`, writes with `attribute_not_exists(incident_id)`, and records dispatch state. If asynchronous invocation cannot be confirmed, SNS redelivery can retry the pending dispatch. The worker conditionally claims only newly received incidents; duplicate worker deliveries do not repeat terminal or already-claimed work. An environment-level DynamoDB lease serializes remediation across alarms. Lease TTL is deliberately longer than the worker Lambda timeout.

Incident statuses are `RECEIVED`, `CLAIMED`, `REMEDIATING`, `VERIFYING`, `SUCCEEDED`, `FAILED`, `UNVERIFIED`, and `RECOVERED_NO_ACTION`. Notification state is tracked separately by event type (incident detected, recovery, remediation result). SQS provides durable delivery retries and a dead-letter queue; a CloudWatch alarm fires when the DLQ is non-empty. Slack delivery remains independent of remediation status and cannot cause remediation to run again.

## Supported signals and safety boundaries

| Signal | Automated action | Required recovery evidence |
|---|---|---|
| CPU | Increase ASG desired capacity by one, capped by the lower of ASG max size and `remediation_max_capacity` | The originating CPU alarm is `OK`, two recent ASG CPU datapoints are below threshold, and ASG capacity is healthy; this release also adds an observe-only ASG CPU anomaly warning |
| Memory | Same bounded scale-out action | The originating memory alarm is `OK`, two recent CWAgent memory datapoints are below threshold, and ASG capacity is healthy |
| Disk | Observe only while the alarm is ASG-aggregated | Two recent root-filesystem CWAgent disk datapoints are below threshold and the originating alarm is `OK`; missing/insufficient data is not recovery. Since no action is issued, the outcome is `RECOVERED_NO_ACTION`, not self-healing success |
| ALB unhealthy targets | Find an unhealthy target that maps to an EC2 instance in the configured ASG, tag it, deregister it, and detach it without decrementing desired capacity | Originating alarm is `OK`, no unhealthy targets remain, at least one healthy target exists, and ASG in-service capacity is at least its minimum |
| Application errors | Observe only; do not blindly scale or replace an instance based only on an error count | Two recent application-error metric datapoints are below threshold and the originating alarm is `OK`. Since no action is issued, the outcome is `RECOVERED_NO_ACTION`, not self-healing success |
| Unknown signal | Observe only | Never marked successful without a recognized signal and positive evidence |

Disk remediation is intentionally disabled for the current aggregate alarm because its dimensions do not reliably identify the affected instance. Do not fan out cleanup across all instances. If instance-targeted cleanup is desired later, add per-instance alarm dimensions and a reviewed, allow-listed cleanup policy first. Application errors are also observe-only because a log count does not prove that scaling or replacement addresses the cause.

## Recovery verification

The worker polls the originating CloudWatch alarm rather than treating a fixed delay or a successful API call as recovery. ALB incidents additionally require target-health and ASG-capacity checks. An alarm in `ALARM`, `INSUFFICIENT_DATA`, missing, or unavailable state does not pass verification. Exhausted verification attempts yield `UNVERIFIED`, not success. Verification attempts and interval are configurable but bounded to fit the Lambda timeout.

## AWS security and operations

- IAM permissions are limited to the APIs used by the worker and incident table; CloudWatch alarm description is read-only.
- DynamoDB uses on-demand billing, server-side encryption, point-in-time recovery, and TTL for incident records.
- The worker has an explicit remediation capacity ceiling and an environment-wide concurrency lease.
- The webhook is never logged. Notification failure is recorded independently.
- Run unit tests and Terraform formatting/validation, review the plan and IAM changes, then deploy to a non-production environment before production rollout.

This design follows AWS Well-Architected principles for operational excellence, security, reliability, and cost awareness; it is not a certification or substitute for environment-specific testing and review.


## Team visibility and proactive warnings

- The dispatcher queues an incident-detected Slack event after persisting an incident and before invoking the worker.
- CloudWatch `OK` transitions create alarm-recovered notifications.
- The worker queues a distinct remediation outcome after recording verification evidence.
- The SQS notifier uses partial batch responses; failed messages are retried and eventually sent to the DLQ. A non-empty DLQ raises a CloudWatch alarm.
- EventBridge schedules an hourly health report by default. It reports ASG desired/min/max capacity, InService instance count, ALB target health, and active alarms.
- An ASG CPU anomaly-detection alarm improves early awareness but is observe-only. It does not independently trigger scaling or replacement.

Scheduled reports are point-in-time summaries, not predictions or synthetic application checks. Per-instance CPU/memory alarm lifecycle, fully correlated root-cause analysis, and live AWS failure-injection evidence are not included in this release.
