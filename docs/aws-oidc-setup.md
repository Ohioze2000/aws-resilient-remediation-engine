# AWS OIDC Authentication

This repository uses two separate trust relationships because Terraform is configured with an HCP Terraform remote backend:

1. **GitHub Actions → AWS OIDC** for AWS API calls made by the GitHub-hosted runner, such as the post-deployment `validate_infra.py` quality gate.
2. **HCP Terraform → AWS dynamic credentials** for Terraform plan/apply/destroy operations that execute remotely in HCP Terraform.

Do not add long-lived `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` credentials to GitHub Actions.

## 1. GitHub Actions OIDC role

Create an AWS IAM OIDC identity provider for:

- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`

Create a dedicated IAM role for this repository. The trust policy must restrict the `sub` claim to this repository and the intended branch/workflow context. For a branch-based trust relationship, the subject is:

```text
repo:Ohioze2000/aws-self-healing-infrastructure:ref:refs/heads/main
```

The role should contain only the permissions required by `validate_infra.py` and the runner-side identity check. For the current implementation, the minimum application permissions are:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSecurityGroups",
        "elasticloadbalancing:DescribeTargetHealth"
      ],
      "Resource": "*"
    }
  ]
}
```

Start with this least-privilege policy and expand only when a failed quality gate demonstrates a missing permission.

Store the role ARN as this GitHub Actions repository secret:

```text
AWS_GITHUB_ACTIONS_ROLE_ARN
```

The workflow grants `id-token: write` and uses `aws-actions/configure-aws-credentials` to exchange the GitHub OIDC token for short-lived AWS credentials. The AWS session is only requested on pushes to `main`, which matches the trust policy and avoids granting runner AWS access to pull-request executions.

## 2. HCP Terraform dynamic AWS credentials

Terraform plan/apply/destroy run remotely because this repository uses the HCP Terraform `cloud` backend. GitHub runner credentials are **not** automatically available inside the remote Terraform run.

Configure HCP Terraform dynamic AWS provider credentials for workspace `asg-incid` instead of storing static AWS credentials in the workspace.

At a minimum, configure the workspace with:

```text
TFC_AWS_PROVIDER_AUTH=true
TFC_AWS_RUN_ROLE_ARN=<HCP Terraform AWS role ARN>
```

The corresponding AWS IAM role must trust the HCP Terraform OIDC provider and restrict the `sub` claim to the expected organization, project, workspace, and run phase. This is separate from the GitHub Actions OIDC role. The `destroy.yml` workflow does not request AWS credentials because its Terraform operations execute remotely in HCP Terraform.

Example subject pattern:

```text
organization:DigitalTech:project:<PROJECT_NAME>:workspace:asg-incid:run_phase:*
```

Use the exact project name and run phases configured in HCP Terraform.

## 3. Why two roles?

The separation is intentional:

```text
GitHub Actions
     │
     │ GitHub OIDC
     ▼
AWS GitHub Actions Role
     │
     └── runner-side validation / AWS API calls

GitHub Actions
     │
     │ HCP Terraform API
     ▼
HCP Terraform
     │
     │ HCP Terraform OIDC
     ▼
AWS Terraform Run Role
     │
     └── Terraform plan / apply / destroy
```

This keeps the GitHub runner identity separate from the Terraform execution identity and avoids passing long-lived AWS credentials through GitHub or HCP Terraform.
