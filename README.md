# AWS Self-Healing Infrastructure

Terraform-managed AWS infrastructure for a highly available web application running in an Auto Scaling Group behind an Application Load Balancer, with CloudWatch monitoring, SNS notifications, and automated unhealthy-instance remediation.

## Architecture

- **VPC:** public and private subnets across the configured Availability Zones.
- **ALB:** public HTTPS entry point with ACM certificate validation and Route 53 aliases.
- **Compute:** Ubuntu EC2 instances in private subnets managed by an Auto Scaling Group.
- **Bootstrap:** EC2 user data installs Docker and the CloudWatch Agent, downloads the application archive, and starts the container.
- **Observability:** CloudWatch metrics/logs, metric filters, alarms, and SNS notifications.
- **Remediation:** CloudWatch → SNS → Python dispatcher Lambda → DynamoDB incident state → bounded remediation worker → recovery verification → Slack. The workflow can scale capacity within a configured ceiling, replace unhealthy ALB targets, perform bounded disk cleanup through SSM, and verify the resulting service state.
- **CI/CD:** GitHub Actions validates Terraform and executes the deployment workflow; AWS runner-side authentication uses GitHub OIDC.
- **Remote state:** HCP Terraform/Terraform Cloud backend configuration is defined in `backend.tf`.

## Important configuration

The following inputs should be supplied through Terraform variables or an approved variable source rather than embedded in scripts:

- `app_archive_url` — HTTPS URL for the application source archive.
- `cloudwatch_agent_parameter_name` — SSM Parameter Store name containing the CloudWatch Agent configuration.
- `slack_webhook_url` — sensitive Slack webhook used for incident notifications.
- `alert_email` — optional SNS email subscription.
- `domain_name` — application domain managed through Route 53.

## Security controls

- EC2 instances require IMDSv2.
- EC2 application ingress is restricted to the ALB security group.
- EC2 uses SSM rather than requiring SSH when `public_key_content` is left empty.
- GitHub Actions uses short-lived AWS credentials through OIDC for runner-side AWS verification.
- The EC2 role receives only the SSM parameter permission required for the CloudWatch Agent configuration in addition to the managed SSM/CloudWatch Agent policies.
- Lambda remediation permissions are limited to target-health inspection, target deregistration, ASG instance detachment, and EC2 tagging.

## Validation

Run the local validation script before committing:

```bash
./scripts/validate-local.sh
```

The CI workflow also runs Terraform formatting and validation. A live `terraform plan`/`apply` requires access to the configured HCP Terraform workspace and AWS credentials.

## Bounded event-driven remediation flow

1. CloudWatch alarm enters `ALARM`.
2. SNS invokes the dispatcher Lambda.
3. The dispatcher derives a deterministic incident ID and conditionally creates the incident in DynamoDB. Duplicate SNS delivery for the same alarm event is ignored by the conditional write.
4. The remediation worker diagnoses the alarm and selects a bounded action.
5. CPU/memory conditions may increase desired capacity by one, never above the configured remediation ceiling.
6. Unhealthy ALB targets are deregistered before the instance is detached with desired capacity preserved.
7. Disk conditions can invoke bounded SSM cleanup with one-instance-at-a-time concurrency and CloudWatch output.
8. The worker records remediation state in DynamoDB, waits for the configured verification delay, verifies ASG capacity and ALB target health, and posts the result to Slack.
9. If verification fails or a safety boundary blocks remediation, DynamoDB records the failed state and Slack reports the failure and manual review requirement.

## Notes

This repository intentionally keeps the application bootstrap archive configurable. The infrastructure repository does not need to contain the application source code itself.

## Final production-safety review

The release candidate includes the following infrastructure and operational controls:

- ALB terminates HTTPS with ACM and redirects HTTP to HTTPS.
- EC2 instances run in private subnets behind an internet-facing ALB; outbound access uses per-AZ NAT gateways.
- EC2 ingress is restricted to the ALB security group; public SSH is not required when SSM is used.
- ASG uses ELB health checks, a 300-second health-check grace period, instance warm-up, capacity convergence timeout, and rolling instance refresh with rollback enabled.
- CloudWatch monitors CPU, disk, application log errors, and unhealthy ALB targets. The unhealthy-target alarm feeds the SNS/Lambda remediation path.
- Remediation deregisters an unhealthy target before detaching the instance so the ASG can replace it without leaving the unhealthy node in service.
- DNS/ACM dependencies remain explicit so certificate validation completes before the HTTPS ALB is created.
- GitHub Actions uses scoped AWS OIDC permissions for runner-side validation; Terraform execution remains associated with the HCP Terraform workspace.
- The destroy workflow requires the explicit `DESTROY` confirmation input and runs in the protected `production` environment.

## Remediation safeguards

- Automated scale-out is capped by `remediation_max_capacity`.
- The dispatcher and worker use conditional DynamoDB claims, stable incident IDs, and an environment-level remediation lease.
- Recovery is signal-specific: the originating alarm must return to `OK`; ALB incidents additionally require healthy targets and minimum ASG capacity.
- Disk and application-error incidents are observe-only by default because the existing aggregate signals do not safely identify a target for destructive remediation.
- Slack delivery is tracked independently and cannot change the incident outcome.

## Proactive team visibility

This release queues immediate incident-detected, alarm-recovered, and remediation-result messages through SQS before delivery to Slack. A dedicated notifier Lambda retries failed deliveries and routes exhausted notifications to a dead-letter queue with a CloudWatch alarm. A scheduled health reporter posts hourly ASG capacity, instance state, ALB target health, and active alarm summaries by default. Configure `health_report_schedule_expression` and `enable_scheduled_health_reports` in the monitoring module. See [`docs/proactive-operations.md`](docs/proactive-operations.md) for behavior, safe operating boundaries, and staging validation steps.

**Validation boundary:** local unit/static checks are not equivalent to a live AWS deployment. Verify SQS redrive, EventBridge scheduling, IAM access, Slack delivery, and end-to-end recovery in an isolated AWS staging account before enabling production remediation.
