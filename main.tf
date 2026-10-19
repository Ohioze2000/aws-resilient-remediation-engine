terraform {
  required_version = ">= 1.15, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.62"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# ==============================================================================
# LOCAL VARIABLES
# ==============================================================================

locals {
  common_tags = merge(
    var.tags,
    {
      Environment = var.env_prefix
      ManagedBy   = "Terraform"
    }
  )

  # Map ACM Domain Validation Options for Route 53 validation records
  cert_validation_map = {
    for dvo in module.ssl.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
}

# ==============================================================================
# 1. CORE VPC & NETWORKING MODULES
# ==============================================================================

module "network" {
  source         = "./modules/network"
  env_prefix     = var.env_prefix
  az_count       = var.az_count
  vpc_cidr_block = var.vpc_cidr_block
  tags           = local.common_tags
}

# ==============================================================================
# 2. SSL & DNS INFRASTRUCTURE
# ==============================================================================

module "ssl" {
  source                    = "./modules/ssl"
  domain_name               = var.domain_name
  subject_alternative_names = var.create_www_record ? ["www.${var.domain_name}"] : []
  tags                      = local.common_tags
}

module "dns" {
  source      = "./modules/dns"
  domain_name = var.domain_name
  tags        = local.common_tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.cert_validation_map

  allow_overwrite = true
  zone_id         = module.dns.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = module.ssl.certificate_arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Application DNS aliases depend on the ALB, so they are managed at the root
# after the certificate validation dependency has been established.
resource "aws_route53_record" "root_a" {
  zone_id = module.dns.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "root_aaaa" {
  count   = var.enable_ipv6 ? 1 : 0
  zone_id = module.dns.zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www_a" {
  count   = var.create_www_record ? 1 : 0
  zone_id = module.dns.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www_aaaa" {
  count   = (var.create_www_record && var.enable_ipv6) ? 1 : 0
  zone_id = module.dns.zone_id
  name    = "www.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

# ==============================================================================
# 3. APPLICATION LOAD BALANCER
# ==============================================================================

module "alb" {
  source              = "./modules/alb"
  env_prefix          = var.env_prefix
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.public_subnet_ids
  certificate_arn     = module.ssl.certificate_arn
  deletion_protection = var.alb_deletion_protection
  tags                = local.common_tags

  depends_on = [
    aws_acm_certificate_validation.cert_validation
  ]
}

# ==============================================================================
# 4. IAM SECURITY ROLES
# ==============================================================================

module "iam" {
  source     = "./modules/iam"
  env_prefix = var.env_prefix
  tags       = local.common_tags
}

# ==============================================================================
# 5. COMPUTE & AUTO SCALING TIER
# ==============================================================================

module "webserver" {
  source                          = "./modules/webserver"
  env_prefix                      = var.env_prefix
  vpc_id                          = module.network.vpc_id
  private_subnet_ids              = module.network.private_subnet_ids
  alb_security_group_id           = module.alb.alb_security_group_id
  target_group_arn                = module.alb.target_group_arn
  iam_instance_profile_name       = module.iam.iam_instance_profile_name
  instance_type                   = var.instance_type
  image_name                      = var.image_name
  public_key_content              = var.public_key_content
  app_archive_url                 = var.app_archive_url
  cloudwatch_agent_parameter_name = var.cloudwatch_agent_parameter_name
  desired_capacity                = var.desired_capacity
  min_size                        = var.min_size
  max_size                        = var.max_size
  tags                            = local.common_tags
}

# ==============================================================================
# 6. MONITORING & AUTOMATED REMEDIATION
# ==============================================================================

module "monitoring" {
  source                                    = "./modules/monitoring"
  env_prefix                                = var.env_prefix
  asg_name                                  = module.webserver.asg_name
  target_group_arn                          = module.alb.target_group_arn
  alb_arn_suffix                            = module.alb.alb_arn_suffix
  slack_webhook_url                         = var.slack_webhook_url
  alert_email                               = var.alert_email
  app_log_group_name                        = "/ec2/app-logs"
  cloudwatch_agent_parameter_name           = var.cloudwatch_agent_parameter_name
  remediation_max_capacity                  = var.remediation_max_capacity
  remediation_verification_delay_seconds    = var.remediation_verification_delay_seconds
  remediation_verification_attempts         = var.remediation_verification_attempts
  remediation_verification_interval_seconds = var.remediation_verification_interval_seconds
  remediation_lock_ttl_seconds              = var.remediation_lock_ttl_seconds
  enable_scheduled_health_reports           = var.enable_scheduled_health_reports
  health_report_schedule_expression         = var.health_report_schedule_expression
  notification_max_receive_count            = var.notification_max_receive_count

  tags = local.common_tags
}

# Grant the EC2 instance role least-privilege access to the CloudWatch agent
# configuration stored in SSM Parameter Store.
resource "aws_iam_role_policy" "ec2_cloudwatch_agent_config" {
  name = "${var.env_prefix}-ec2-cloudwatch-agent-config"
  role = module.iam.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = module.monitoring.cw_agent_config_parameter_arn
      }
    ]
  })
}
