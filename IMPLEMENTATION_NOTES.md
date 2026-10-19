# Implementation Notes — Proactive Bounded Self-Healing

## Implemented in this repository refactor

- Retained deterministic incident IDs, conditional DynamoDB incident creation, retryable dispatcher state, worker claims, and environment-level remediation lock.
- Retained bounded CPU/memory scale-out, guarded ALB target mapping, and observe-only handling for ambiguous aggregate disk/application signals.
- Added Slack notification processing through SQS, a dedicated notifier Lambda, retry handling, a dead-letter queue, and CloudWatch alarms for a non-empty DLQ and worker notification-intent failures. Notification failures do not overwrite remediation outcomes.
- Added separate Slack events for incident detection, CloudWatch alarm recovery, and remediation outcome; notification delivery state is tracked independently by event type.
- Added scheduled proactive health reports covering ASG capacity, InService instances, ALB target health, and active CloudWatch alarms.
- Added a CPU anomaly-detection warning that is explicitly observe-only; anomaly detection alone does not trigger scale-out or destructive recovery.
- Added tests for notification rendering, successful delivery, retry signaling, signal classification, and anomaly observe-only behavior.

## Local validation performed

- `python3 -m py_compile modules/monitoring/lambda/*.py tests/*.py` — passed.
- `python3 -m unittest discover -s tests -v` — 12 tests passed.
- `bash -n scripts/validate-local.sh entry-script.sh` — pending final packaging validation.

## Not performed / required before production

- Terraform `fmt`, `init`, `validate`, and `plan`: Terraform CLI is not installed in this environment.
- AWS deployment, IAM Access Analyzer review, Slack delivery integration, SQS DLQ/redrive validation, EventBridge schedule validation, and live recovery/failure-injection tests have not been run.
- CPU/memory alarms remain ASG-aggregated; per-instance alarm lifecycle and precise identity correlation are not implemented in this release. Disk and application-error actions remain observe-only by design.
- Scheduled health reports are point-in-time infrastructure summaries, not predictive guarantees or full application synthetic checks.

Do not describe this artifact as live-AWS-validated or production-certified. Run `./scripts/validate-local.sh` with Terraform installed, inspect the plan/IAM, and complete the staging acceptance plan in `docs/proactive-operations.md` before production rollout.
