# Deployment Guide

## Prerequisites

- AWS account and target region.
- HCP Terraform workspace configured for the repository.
- Terraform CLI for local validation.
- A Route 53 hosted zone for the application domain.
- An ACM-compatible domain configuration.
- Application archive hosted at an HTTPS URL.
- CloudWatch Agent configuration stored in SSM Parameter Store.
- Required Terraform variables/secrets configured through an approved variable source.

## Local validation

Run:

```bash
./scripts/validate-local.sh
```

This performs the repository's local formatting/initialization/validation checks and Python compilation that are available through the script.

## Terraform validation

Before an apply, run in an environment with Terraform and access to the configured HCP Terraform workspace:

```bash
terraform fmt -check -recursive
terraform init
terraform validate
terraform plan
```

Review the plan before applying any infrastructure change.

## GitHub Actions

The repository uses GitHub Actions for CI/CD and runner-side AWS verification. GitHub Actions uses OIDC for short-lived AWS credentials rather than static AWS access keys. Terraform execution remains associated with the configured HCP Terraform backend/workspace.

See [`aws-oidc-setup.md`](aws-oidc-setup.md) for the required trust relationships.

## Production changes

For production changes:

1. Review the Terraform plan.
2. Confirm networking, security-group, IAM, ALB, ASG, and monitoring changes.
3. Verify the HCP Terraform run is targeting the intended workspace.
4. Apply only after review/approval according to the team's change process.
5. Confirm ALB target health and CloudWatch alarms after deployment.
