# Security Controls

## Identity and access

- GitHub Actions uses GitHub OIDC for short-lived AWS credentials for runner-side AWS operations.
- Terraform plan/apply/destroy uses the configured HCP Terraform AWS identity rather than GitHub runner credentials.
- EC2 uses IAM roles rather than embedded AWS access keys.
- IAM policies are scoped to the documented operational requirements.

## Network security

- EC2 application instances are deployed in private subnets.
- Internet-facing access is provided through the ALB.
- EC2 application ingress is restricted to the ALB security group.
- Public SSH is not required when Systems Manager is used.
- IMDSv2 is required for EC2 metadata access.

## Transport security

- ACM provides the ALB certificate.
- HTTP is redirected to HTTPS.
- The configured ALB TLS policy is `ELBSecurityPolicy-TLS13-1-2-2021-06`.

## Secrets

Do not commit AWS credentials, Slack webhook values, private keys, or other sensitive values. Supply sensitive values through GitHub secrets, HCP Terraform variables, AWS Systems Manager, or another approved secret-management mechanism as appropriate.

## Destructive operations

ALB deletion protection is enabled by default. The controlled destroy workflow requires explicit confirmation before intentionally disabling that protection and destroying the environment.
