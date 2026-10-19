variable "aws_region" {
  type        = string
  description = "AWS region for infrastructure deployment"
  default     = "us-east-1"
}

variable "env_prefix" {
  type        = string
  description = "Environment prefix used for resource naming (e.g., dev, staging, prod)"
}

variable "vpc_cidr_block" {
  type        = string
  description = "Base IPv4 CIDR block for the primary VPC"
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to deploy subnets into"
  default     = 2
}


variable "domain_name" {
  type        = string
  description = "The registered domain name for DNS routing and ACM SSL certification"
}

variable "create_www_record" {
  type        = bool
  description = "Whether to create a www alias record for the application."
  default     = true
}


variable "alb_deletion_protection" {
  type        = bool
  description = "Protect the production ALB from accidental deletion. Disable explicitly for intentional teardown."
  default     = false
}

variable "enable_ipv6" {
  type        = bool
  description = "Whether to create AAAA alias records for the application. Requires a dual-stack ALB and IPv6-enabled VPC/subnets."
  default     = false
}

variable "image_name" {
  type        = string
  description = "AMI search pattern for EC2 instance launch template"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for Auto Scaling Group nodes"
}

variable "app_archive_url" {
  type        = string
  description = "HTTPS URL of the application source archive consumed by EC2 bootstrap"
}

variable "cloudwatch_agent_parameter_name" {
  type        = string
  description = "SSM Parameter Store name containing the CloudWatch Agent configuration"
  default     = "/asg-webserver/cloudwatch-agent-config"
}

variable "public_key_content" {
  type        = string
  description = "Raw public SSH key content for direct host access. Leave empty if using SSM"
}

variable "desired_capacity" {
  type        = number
  description = "Target number of instances in the Auto Scaling Group"
  default     = 2
}

variable "min_size" {
  type        = number
  description = "Minimum number of instances in the Auto Scaling Group"
  default     = 2
}

variable "max_size" {
  type        = number
  description = "Maximum number of instances in the Auto Scaling Group"
  default     = 4
}

variable "slack_webhook_url" {
  type        = string
  description = "Slack Webhook URL for CloudWatch incident alerting and remediation events"
  sensitive   = true
}

variable "alert_email" {
  type        = string
  description = "Email address for SNS CloudWatch alarm notifications"
  default     = ""
  sensitive   = true
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied across all deployed modules"
  default     = {}
}

variable "remediation_max_capacity" {
  type        = number
  description = "Maximum desired capacity permitted by automated remediation"
  default     = 4
}

variable "remediation_verification_delay_seconds" {
  type        = number
  description = "Initial wait before recovery verification (worker caps this at 30 seconds)"
  default     = 15
}

variable "remediation_verification_attempts" {
  type        = number
  description = "Maximum signal-specific recovery verification attempts"
  default     = 5
  validation {
    condition     = var.remediation_verification_attempts >= 1 && var.remediation_verification_attempts <= 6
    error_message = "remediation_verification_attempts must be between 1 and 6."
  }
}

variable "remediation_verification_interval_seconds" {
  type        = number
  description = "Seconds between recovery verification attempts"
  default     = 10
  validation {
    condition     = var.remediation_verification_interval_seconds >= 1 && var.remediation_verification_interval_seconds <= 10
    error_message = "remediation_verification_interval_seconds must be between 1 and 10."
  }
}

variable "remediation_lock_ttl_seconds" {
  type        = number
  description = "Environment-wide remediation lock lease in seconds"
  default     = 180
  validation {
    condition     = var.remediation_lock_ttl_seconds >= 120 && var.remediation_lock_ttl_seconds <= 3600
    error_message = "remediation_lock_ttl_seconds must be between 120 and 3600."
  }
}

variable "enable_scheduled_health_reports" {
  type        = bool
  description = "Enable scheduled infrastructure health reports to Slack"
  default     = true
}

variable "health_report_schedule_expression" {
  type        = string
  description = "EventBridge schedule for proactive health summaries (for example rate(1 hour))"
  default     = "rate(1 hour)"
}

variable "notification_max_receive_count" {
  type        = number
  description = "SQS attempts before a Slack notification is moved to the dead-letter queue"
  default     = 5
}
