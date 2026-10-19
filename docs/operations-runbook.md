# Operations Runbook

## Before enabling automated remediation

1. Confirm the ASG, target group, alarm names, CloudWatch Agent metrics, and app log group match this environment.
2. Confirm the CloudWatch Agent is installed and publishing `mem_used_percent` and `disk_used_percent` with the dimensions used by the alarms.
3. Run `python -m unittest discover -s tests -v`, `terraform fmt -check -recursive`, and `terraform validate` in an initialized Terraform working directory.
4. Review the plan, especially IAM, Lambda environment variables, and DynamoDB table changes. Deploy and exercise the workflow in non-production first.

## Incident triage

1. Read the incident item in `${env_prefix}-remediation-incidents`; inspect `signal`, `status`, `action`, `remediation_summary`, `verification`, `error`, and `notification_state`.
2. Check the originating CloudWatch alarm state and recent metric data.
3. For ALB incidents, inspect target health reason codes, ASG activity history, and application readiness.
4. For CPU/memory incidents, verify the ASG's configured min/max, the remediation ceiling, launch capacity, and service health.
5. Disk alarms are observe-only until the alarm identifies a specific instance safely. Do not run fleet-wide cleanup as an automated response.
6. Application-error alarms are observe-only; inspect application logs and deployment changes before deciding on scaling or replacement.

## Status meanings

- `SUCCEEDED`: all required signal-specific recovery checks passed.
- `FAILED`: execution failed with an exception; inspect `error` and worker logs.
- `UNVERIFIED`: recovery evidence was absent, insufficient, still breaching, or the environment lock was unavailable. Treat this as requiring investigation, not success.
- `notification_state=RETRYING`: remediation status is unchanged; notification delivery failed separately.

## Concurrency and duplicate delivery

A DynamoDB conditional incident claim prevents the same event from running twice. A separate environment lock serializes actions across different incidents. If the lock is busy, the incident is marked `UNVERIFIED` for operator review; do not manually delete lock fields without first checking worker execution and lease expiry.

## Slack failure

Slack delivery is best-effort. Review `notification_state` and CloudWatch worker logs. Do not rerun remediation solely because a notification failed.

## Rollback

Review the Terraform plan and run history before reverting. If automated remediation is causing unsafe behavior, disable alarm actions or roll back the monitoring module via a reviewed Terraform change. Do not manually change resources merely to align Terraform state. Do not test destructive paths against production resources.
