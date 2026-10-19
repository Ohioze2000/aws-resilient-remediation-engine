# Architecture Overview

## Purpose

This repository provisions a production-style AWS web platform designed to demonstrate resilient infrastructure, automated remediation, observability, security controls, and CI/CD automation using Terraform.

## Logical flow

```text
Internet
   |
   v
Route 53
   |
   v
ACM Certificate
   |
   v
Application Load Balancer
   |  HTTPS / health checks
   v
Private EC2 instances
managed by Auto Scaling Group
   |
   +--> Docker application
   |
   +--> CloudWatch Agent
   |
   +--> Systems Manager

CloudWatch alarms
   |
   v
SNS
   |
   v
Incident Remediation Lambda
   |
   +--> inspect ALB target health
   +--> deregister unhealthy target
   +--> detach unhealthy instance from ASG
   +--> preserve desired capacity
   +--> tag quarantined instance
   +--> notify Slack
```

## Terraform modules

- `modules/network` — VPC, subnets, routing, NAT, and related network resources.
- `modules/alb` — Application Load Balancer, listeners, target group, and security controls.
- `modules/ssl` — ACM certificate and validation resources.
- `modules/dns` — Route 53 records and aliases.
- `modules/webserver` — EC2 launch configuration, Auto Scaling, bootstrap, and instance security.
- `modules/iam` — IAM roles and policies for EC2 and supporting services.
- `modules/monitoring` — CloudWatch, SNS, alarms, remediation Lambda, and notifications.

## Design principles

1. Keep application instances private and expose the service through the ALB.
2. Prefer short-lived identity through OIDC instead of long-lived AWS access keys.
3. Use ELB health checks and Auto Scaling for replacement of unhealthy capacity.
4. Use CloudWatch and automated remediation to reduce operational toil.
5. Keep sensitive and environment-specific values configurable through Terraform variables or approved secret/variable stores.
6. Keep Terraform state remote through the configured HCP Terraform backend.
