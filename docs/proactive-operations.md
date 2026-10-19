# Proactive Operations and Slack Visibility

## Operational behavior

The monitoring module publishes CloudWatch alarm transitions to SNS. The dispatcher persists ALARM incidents in DynamoDB using a deterministic incident ID, queues an immediate incident-detected Slack event, and invokes the bounded remediation worker. The worker records its action and verification evidence, then queues the final outcome. CloudWatch OK transitions also produce a recovery notification.

Slack delivery is handled separately through SQS and a dedicated notifier Lambda. SQS retries transient failures and moves messages to a dead-letter queue after `notification_max_receive_count` receives. A CloudWatch alarm fires when the DLQ is non-empty; operators should inspect and redrive messages only after addressing the delivery cause. Delivery is at-least-once, so duplicate Slack posts are possible in edge cases; include incident IDs when reconciling messages.

A scheduled health reporter (enabled by default, `rate(1 hour)`) reports Auto Scaling desired/min/max capacity, InService instance count, ALB target health, and active CloudWatch alarms. Set `enable_scheduled_health_reports = false` to disable it or adjust `health_report_schedule_expression`. The report is a point-in-time infrastructure view, not a full synthetic application test or guarantee of service correctness.

## Severity and action boundaries

- `ALARM`: persist and notify immediately, then apply the signal-specific bounded policy.
- `OK`: notify the team that the alarm recovered; this message is not itself proof that all application checks passed.
- CPU/memory: bounded scale-out is subject to the remediation ceiling.
- Unhealthy ALB target: current worker uses explicit target-health lookup and ASG membership checks; replacement completion must be verified independently. Prefer native ASG ELB health checks for ordinary instance replacement.
- Disk and application-error signals: observe-only unless a future policy can identify the affected resource and prove a safe, bounded action.
- Unknown or ambiguous signals: do not run destructive remediation.

## Slack configuration and security

Supply `slack_webhook_url` as a sensitive Terraform input via the approved CI secret/variable mechanism. Do not commit it to `.tfvars`, source control, logs, or incident records. For high-assurance production deployments, use Secrets Manager and a rotation procedure instead of a long-lived Lambda environment variable.

## Operational validation

1. In staging, force a known CloudWatch alarm and verify an incident-detected Slack message arrives before the remediation result.
2. Verify the DynamoDB incident status, action, verification payload, and notification state.
3. Trigger an OK transition and verify an alarm-recovered message.
4. Temporarily configure an invalid webhook in a non-production environment; verify SQS retries and the DLQ alarm. Restore the webhook and test redrive.
5. Wait for the scheduled report and compare its values with the AWS console/CLI.
6. Simulate unhealthy target behavior and confirm the worker does not report success until the policy's recovery checks pass.

## Current limitations

This release adds periodic point-in-time health reporting and durable notification delivery. It does not claim predictive failure prevention. CloudWatch anomaly detection, per-instance CPU/memory alarms, automated root-cause correlation, and live AWS failure-injection evidence remain separate follow-up work. Scheduled reports do not replace alarms or on-call escalation.
