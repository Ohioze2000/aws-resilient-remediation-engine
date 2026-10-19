output "cloudwatch_alarms_topic_arn" {
  description = "ARN of the SNS topic for CloudWatch alarms"
  value       = aws_sns_topic.cloudwatch_alarms_topic.arn
}


output "high_cpu_alarm_arn" {
  description = "ARN of the High CPU alarm"
  value       = aws_cloudwatch_metric_alarm.high_cpu_alarm.arn
}

output "high_disk_alarm_arn" {
  description = "ARN of the High Disk Usage alarm"
  value       = length(aws_cloudwatch_metric_alarm.high_disk_alarm) > 0 ? aws_cloudwatch_metric_alarm.high_disk_alarm[0].arn : null
}

output "log_error_alarm_arn" {
  description = "ARN of the Log Error alarm"
  value       = length(aws_cloudwatch_metric_alarm.app_error_alarm) > 0 ? aws_cloudwatch_metric_alarm.app_error_alarm[0].arn : null
}
output "app_log_group_name" {
  description = "CloudWatch log group used by the application error metric filter"
  value       = aws_cloudwatch_log_group.app_log_group.name
}

output "cw_agent_config_parameter_arn" {
  description = "ARN of the SSM Parameter Store entry containing the CloudWatch agent configuration"
  value       = aws_ssm_parameter.cw_agent_config.arn
}

output "remediation_incident_table_name" {
  description = "DynamoDB table storing bounded remediation incident state"
  value       = aws_dynamodb_table.remediation_incidents.name
}

output "remediation_dispatcher_function_name" {
  description = "Name of the SNS-triggered remediation dispatcher Lambda"
  value       = aws_lambda_function.remediation_dispatcher.function_name
}

output "slack_notification_queue_url" {
  description = "SQS queue URL for durable Slack operational notifications"
  value       = aws_sqs_queue.slack_notifications.url
}

output "slack_notification_dlq_url" {
  description = "Dead-letter queue URL for notifications requiring operator review"
  value       = aws_sqs_queue.slack_notifications_dlq.url
}

output "health_reporter_function_name" {
  description = "Scheduled proactive health report Lambda name, when enabled"
  value       = var.enable_scheduled_health_reports ? aws_lambda_function.health_reporter[0].function_name : null
}
