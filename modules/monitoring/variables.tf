variable "env_prefix" {
  type        = string
  description = "Environment prefix used for naming resources (e.g., dev, staging, prod)"
}

variable "asg_name" {
  type        = string
  description = "The name of the Auto Scaling Group to monitor and remediate"
}

variable "target_group_arn" {
  type        = string
  description = "The ARN of the ALB Target Group to query for unhealthy application instances"
}

variable "alb_arn_suffix" {
  type        = string
  description = "The ALB ARN suffix used for ApplicationELB CloudWatch dimensions"
}

variable "slack_webhook_url" {
  type        = string
  description = "The secure Slack incoming webhook URL used to post incident reports"
  sensitive   = true
}

variable "alert_email" {
  type        = string
  description = "Optional email address to subscribe to SNS alarm notifications"
  default     = ""
}

variable "sns_kms_key_id" {
  type        = string
  description = "KMS Key ID or ARN to encrypt the SNS Topic at rest"
  default     = null
}

# --- CPU Alarm Variables ---
variable "cpu_alarm_threshold" {
  type        = number
  description = "Average CPU threshold percent to trigger alarm"
  default     = 80
}

variable "cpu_evaluation_periods" {
  type        = number
  description = "The number of periods over which data is compared against the threshold"
  default     = 2
}

variable "cpu_datapoints_to_alarm" {
  type        = number
  description = "The number of datapoints within the evaluation period that must be breaching to trigger the alarm"
  default     = 2
}

variable "cpu_alarm_period" {
  type        = number
  description = "The period in seconds over which the specified statistic is applied"
  default     = 300
}

# --- Disk Alarm Variables ---
variable "enable_disk_alarm" {
  type        = bool
  description = "Whether to deploy the high disk usage alarm"
  default     = true
}

variable "disk_alarm_threshold" {
  type        = number
  description = "Root disk usage threshold percentage to trigger alarm"
  default     = 70
}

variable "disk_evaluation_periods" {
  type        = number
  description = "Evaluation periods for disk alarm"
  default     = 1
}

variable "disk_alarm_period" {
  type        = number
  description = "Period in seconds for disk alarm evaluation"
  default     = 120
}

# --- Log Error Alarm Variables ---
variable "enable_log_error_alarm" {
  type        = bool
  description = "Whether to enable application log error monitoring"
  default     = true
}

variable "cloudwatch_agent_parameter_name" {
  type        = string
  description = "SSM Parameter Store name containing the CloudWatch Agent configuration"
  default     = "/asg-webserver/cloudwatch-agent-config"
}

variable "app_log_group_name" {
  type        = string
  description = "CloudWatch log group receiving application logs from the EC2 CloudWatch agent"
  default     = "/ec2/app-logs"
}

variable "log_error_pattern" {
  type        = string
  description = "Metric filter pattern to search for error terms in logs"
  default     = "?ERROR ?Error ?error ?500 ?EXCEPTION ?Exception"
}

variable "log_error_threshold" {
  type        = number
  description = "Number of log error occurrences in period to trigger alarm"
  default     = 5
}

variable "log_error_alarm_period" {
  type        = number
  description = "Evaluation window in seconds for error log frequency"
  default     = 60
}

# --- General Variables ---
variable "log_retention_in_days" {
  type        = number
  description = "CloudWatch Log Group retention period in days for the remediation Lambda"
  default     = 14
}

variable "disk_fstype" {
  type        = string
  description = "Filesystem type of the root volume (e.g., ext4 for Ubuntu/Debian, xfs for Amazon Linux)"
  default     = "ext4"
}

variable "tags" {
  type        = map(string)
  description = "A mapping of tags to assign to all module resources"
  default     = {}
}
variable "memory_alarm_threshold" {
  type        = number
  description = "Memory utilization threshold percentage"
  default     = 80
}

variable "memory_evaluation_periods" {
  type        = number
  description = "Evaluation periods for memory alarm"
  default     = 2
}

variable "memory_datapoints_to_alarm" {
  type        = number
  description = "Datapoints required to trigger memory alarm"
  default     = 2
}

variable "memory_alarm_period" {
  type        = number
  description = "Period in seconds for memory alarm evaluation"
  default     = 300
}

variable "remediation_max_capacity" {
  type        = number
  description = "Maximum desired capacity allowed by automated remediation"
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
    error_message = "remediation_verification_attempts must be between 1 and 6 to fit the worker Lambda timeout."
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
  description = "Lease duration for the environment-wide remediation lock"
  default     = 180
  validation {
    condition     = var.remediation_lock_ttl_seconds >= 120 && var.remediation_lock_ttl_seconds <= 3600
    error_message = "remediation_lock_ttl_seconds must be between 120 and 3600."
  }
}


variable "health_report_schedule_expression" {
  type        = string
  description = "EventBridge schedule for proactive Slack infrastructure health summaries"
  default     = "rate(1 hour)"
}

variable "enable_scheduled_health_reports" {
  type        = bool
  description = "Enable scheduled infrastructure health reports to Slack"
  default     = true
}

variable "notification_max_receive_count" {
  type        = number
  description = "Maximum SQS delivery attempts before a notification is sent to the dead-letter queue"
  default     = 5
  validation {
    condition     = var.notification_max_receive_count >= 2 && var.notification_max_receive_count <= 10
    error_message = "notification_max_receive_count must be between 2 and 10."
  }
}
