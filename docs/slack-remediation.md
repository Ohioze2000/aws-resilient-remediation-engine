# Slack Operational Visibility

Slack receives separate messages for:

- **Incident detected:** queued after the incident is persisted in DynamoDB, before the dispatcher invokes remediation.
- **Alarm recovered:** emitted for a CloudWatch `OK` transition. This reports alarm state only; it is not a substitute for application-level verification.
- **Remediation result:** queued after the worker records `SUCCEEDED`, `FAILED`, or `UNVERIFIED` with verification evidence.
- **Scheduled infrastructure health:** periodic ASG capacity, InService instance count, ALB target health, and active CloudWatch alarm summary.

Messages are delivered through an SQS queue and notifier Lambda. SQS retries failed deliveries and routes exhausted messages to a dead-letter queue; a CloudWatch alarm alerts when the DLQ is non-empty. Notification delivery state is tracked separately for incident detection, recovery, and remediation result so asynchronous message ordering does not overwrite the wrong event status. Delivery is at-least-once; duplicate messages remain possible during retry races.

The runtime webhook is passed as the sensitive Terraform variable `slack_webhook_url`. Do not commit it to source control or print it in logs. For stronger secret lifecycle controls, move it to AWS Secrets Manager and implement rotation before a high-assurance production rollout.

See [`proactive-operations.md`](proactive-operations.md) for staging validation and limitations.
