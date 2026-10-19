# ==============================================================================
# 1. CORE NOTIFICATION INFRASTRUCTURE
# ==============================================================================

resource "aws_sns_topic" "cloudwatch_alarms_topic" {
  name              = "${var.env_prefix}-cloudwatch-alarms"
  display_name      = "${var.env_prefix} CloudWatch Alarms"
  kms_master_key_id = var.sns_kms_key_id

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-cloudwatch-alarms"
    }
  )
}

# SNS Topic Policy allowing CloudWatch to publish alarms securely
resource "aws_sns_topic_policy" "default" {
  arn = aws_sns_topic.cloudwatch_alarms_topic.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchToPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.cloudwatch_alarms_topic.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:*:*:alarm:${var.env_prefix}-*"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email_subscription" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.cloudwatch_alarms_topic.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ==============================================================================
# 2. SSM PARAMETER STORE (CLOUDWATCH AGENT CONFIGURATION)
# ==============================================================================

resource "aws_ssm_parameter" "cw_agent_config" {
  name        = var.cloudwatch_agent_parameter_name
  description = "CloudWatch Agent configuration JSON for EC2 instances in Auto Scaling Group"
  type        = "String"

  value = jsonencode({
    agent = {
      metrics_collection_interval = 60,
      run_as_user                 = "root"
    }
    metrics = {
      namespace = "CWAgent"
      append_dimensions = {
        InstanceId           = "$${aws:InstanceId}"
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
      }
      aggregation_dimensions = [
        ["InstanceId"],
        ["AutoScalingGroupName", "path", "fstype"]
      ]
      metrics_collected = {
        cpu = {
          metrics_collection_interval = 60
          measurement = [
            "cpu_usage_idle",
            "cpu_usage_iowait",
            "cpu_usage_user",
            "cpu_usage_system"
          ]
          totalcpu = true
        }
        disk = {
          metrics_collection_interval = 60
          resources                   = ["/"]
          measurement                 = ["disk_used_percent", "inodes_free"]
          ignore_file_system_types    = ["sysfs", "devtmpfs", "tmpfs"]
          drop_device                 = true
        }
        mem = {
          metrics_collection_interval = 60
          measurement                 = ["mem_used_percent"]
        }
        swap = {
          metrics_collection_interval = 60
          measurement                 = ["swap_used_percent"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path         = "/var/log/cloud-init-output.log"
              log_group_name    = "/ec2/cloud-init-output"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/user-data.log"
              log_group_name    = "/ec2/user-data"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/nginx/access.log"
              log_group_name    = "/ec2/nginx/access"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/nginx/error.log"
              log_group_name    = "/ec2/nginx/error"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            },
            {
              file_path         = "/var/log/app/*.log"
              log_group_name    = "/ec2/app-logs"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.log_retention_in_days
            }
          ]
        }
      }
    }
  })
}

resource "aws_cloudwatch_log_group" "app_log_group" {
  name              = var.app_log_group_name
  retention_in_days = var.log_retention_in_days

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-app-logs"
    }
  )
}

# ==============================================================================
# 3. METRIC ALARMS
# ==============================================================================

# --- HIGH CPU ALARM ---
resource "aws_cloudwatch_metric_alarm" "high_cpu_alarm" {
  alarm_name          = "${var.env_prefix}-ASG-High-CPU-Utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.cpu_evaluation_periods
  datapoints_to_alarm = var.cpu_datapoints_to_alarm
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = var.cpu_alarm_period
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_description   = "Alarm when average CPU utilization across Auto Scaling Group '${var.asg_name}' exceeds ${var.cpu_alarm_threshold}%"
  actions_enabled     = true
  treat_missing_data  = "missing"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-ASG-High-CPU-Alarm"
    }
  )
}

# --- PROACTIVE CPU ANOMALY WARNING ---
# This alarm is informational: anomaly detection is useful for early awareness but is not
# sufficient evidence by itself to trigger destructive remediation.
resource "aws_cloudwatch_metric_alarm" "cpu_anomaly_warning" {
  alarm_name          = "${var.env_prefix}-ASG-CPU-Anomaly-Warning"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "e1"
  alarm_description   = "Unusual Auto Scaling Group CPU behavior detected; investigate trend and correlated signals. This alarm is observe-only."
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions          = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  metric_query {
    id          = "m1"
    return_data = false
    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/EC2"
      period      = 300
      stat        = "Average"
      dimensions  = { AutoScalingGroupName = var.asg_name }
    }
  }
  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "CPU anomaly detection band"
    return_data = true
  }
  tags = merge(var.tags, { Name = "${var.env_prefix}-ASG-CPU-Anomaly-Warning" })
}

# --- HIGH MEMORY ALARM ---
resource "aws_cloudwatch_metric_alarm" "high_memory_alarm" {
  alarm_name          = "${var.env_prefix}-ASG-High-Memory-Utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.memory_evaluation_periods
  datapoints_to_alarm = var.memory_datapoints_to_alarm
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = var.memory_alarm_period
  statistic           = "Average"
  threshold           = var.memory_alarm_threshold
  alarm_description   = "Alarm when average memory utilization across the Auto Scaling Group reaches ${var.memory_alarm_threshold}%"
  actions_enabled     = true
  treat_missing_data  = "notBreaching"
  dimensions = {
    AutoScalingGroupName = var.asg_name
  }
  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags = merge(var.tags, { Name = "${var.env_prefix}-ASG-High-Memory-Alarm" })
}

# --- UNHEALTHY TARGET ALARM ---
resource "aws_cloudwatch_metric_alarm" "unhealthy_target_alarm" {
  alarm_name          = "${var.env_prefix}-ALB-Unhealthy-Targets"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "Alarm when one or more targets in the application target group remain unhealthy."
  actions_enabled     = true
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = element(split(":", var.target_group_arn), 5)
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(var.tags, { Name = "${var.env_prefix}-ALB-Unhealthy-Targets-Alarm" })
}

# --- HIGH DISK UTILIZATION ALARM ---
resource "aws_cloudwatch_metric_alarm" "high_disk_alarm" {
  count               = var.enable_disk_alarm ? 1 : 0
  alarm_name          = "${var.env_prefix}-ASG-High-Disk-Utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.disk_evaluation_periods
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = var.disk_alarm_period
  statistic           = "Average"
  threshold           = var.disk_alarm_threshold
  alarm_description   = "Alarm when root disk utilization exceeds ${var.disk_alarm_threshold}%"
  actions_enabled     = true
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.asg_name
    path                 = "/"
    fstype               = var.disk_fstype # Default variable e.g. "ext4" or "xfs"
  }

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-ASG-High-Disk-Alarm"
    }
  )
}

# ==============================================================================
# 4. LOG ERROR MONITORING (FILTER + ALARM)
# ==============================================================================

resource "aws_cloudwatch_log_metric_filter" "app_error_filter" {
  count          = var.enable_log_error_alarm ? 1 : 0
  name           = "${var.env_prefix}-app-error-filter"
  pattern        = var.log_error_pattern
  log_group_name = aws_cloudwatch_log_group.app_log_group.name

  metric_transformation {
    name          = "${var.env_prefix}-AppErrorCount"
    namespace     = "CustomAppMetrics"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_error_alarm" {
  count               = var.enable_log_error_alarm ? 1 : 0
  alarm_name          = "${var.env_prefix}-App-Log-Errors-Spike"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.app_error_filter[0].metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.app_error_filter[0].metric_transformation[0].namespace
  period              = var.log_error_alarm_period
  statistic           = "Sum"
  threshold           = var.log_error_threshold
  alarm_description   = "Alarm when application error occurrences in log group '${var.app_log_group_name}' exceed ${var.log_error_threshold}"
  actions_enabled     = true
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  ok_actions    = [aws_sns_topic.cloudwatch_alarms_topic.arn]

  tags = merge(
    var.tags,
    {
      Name = "${var.env_prefix}-App-Log-Errors-Alarm"
    }
  )
}

# ==============================================================================
# ==============================================================================
# 5. EVENT-DRIVEN BOUNDED REMEDIATION WITH DYNAMODB INCIDENT STATE
# ============================================================================

data "archive_file" "remediation_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/remediation_lambda.zip"
}

resource "aws_dynamodb_table" "remediation_incidents" {
  name         = "${var.env_prefix}-remediation-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"

  attribute {
    name = "incident_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(var.tags, { Name = "${var.env_prefix}-remediation-incidents" })
}

resource "aws_iam_role" "remediation_worker_role" {
  name = "${var.env_prefix}-remediation-worker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "remediation_worker_logs" {
  role       = aws_iam_role.remediation_worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "remediation_worker_policy" {
  name = "${var.env_prefix}-remediation-worker-policy"
  role = aws_iam_role.remediation_worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DeregisterTargets",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:DetachInstances",
          "ec2:CreateTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.remediation_incidents.arn
      },
      {
        Effect  = "Allow"
        Action  = ["cloudwatch:DescribeAlarms", "cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        Effect  = "Allow"
        Action  = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.slack_notifications.arn
      }
    ]
  })
}

resource "aws_iam_role" "remediation_dispatcher_role" {
  name = "${var.env_prefix}-remediation-dispatcher-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "remediation_dispatcher_logs" {
  role       = aws_iam_role.remediation_dispatcher_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "remediation_dispatcher_policy" {
  name = "${var.env_prefix}-remediation-dispatcher-policy"
  role = aws_iam_role.remediation_dispatcher_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.remediation_incidents.arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.remediation_worker.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.slack_notifications.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ssm_remediation_logs" {
  name              = "/aws/ssm/${var.env_prefix}/remediation"
  retention_in_days = var.log_retention_in_days
  tags              = var.tags
}

resource "aws_lambda_function" "remediation_worker" {
  filename         = data.archive_file.remediation_lambda_zip.output_path
  function_name    = "${var.env_prefix}-remediation-worker"
  role             = aws_iam_role.remediation_worker_role.arn
  handler          = "worker.lambda_handler"
  source_code_hash = data.archive_file.remediation_lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 120
  environment {
    variables = {
      NOTIFICATION_QUEUE_URL  = aws_sqs_queue.slack_notifications.url
      TARGET_GROUP_ARN        = var.target_group_arn
      ASG_NAME                = var.asg_name
      ENV_PREFIX              = var.env_prefix
      MAX_CAPACITY            = tostring(var.remediation_max_capacity)
      CPU_ALARM_THRESHOLD      = tostring(var.cpu_alarm_threshold)
      MEMORY_ALARM_THRESHOLD   = tostring(var.memory_alarm_threshold)
      DISK_ALARM_THRESHOLD     = tostring(var.disk_alarm_threshold)
      APP_ERROR_THRESHOLD      = tostring(var.log_error_threshold)
      DISK_FSTYPE              = var.disk_fstype
      INCIDENT_TABLE_NAME     = aws_dynamodb_table.remediation_incidents.name
      VERIFICATION_DELAY_SECONDS = tostring(var.remediation_verification_delay_seconds)
      VERIFICATION_ATTEMPTS = tostring(var.remediation_verification_attempts)
      VERIFICATION_INTERVAL_SECONDS = tostring(var.remediation_verification_interval_seconds)
      REMEDIATION_LOCK_TTL_SECONDS = tostring(var.remediation_lock_ttl_seconds)
    }
  }
  tags = var.tags
}

resource "aws_lambda_function" "remediation_dispatcher" {
  filename         = data.archive_file.remediation_lambda_zip.output_path
  function_name    = "${var.env_prefix}-remediation-dispatcher"
  role             = aws_iam_role.remediation_dispatcher_role.arn
  handler          = "dispatcher.lambda_handler"
  source_code_hash = data.archive_file.remediation_lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  environment {
    variables = {
      INCIDENT_TABLE_NAME = aws_dynamodb_table.remediation_incidents.name
      WORKER_FUNCTION_NAME = aws_lambda_function.remediation_worker.function_name
      ENV_PREFIX           = var.env_prefix
      NOTIFICATION_QUEUE_URL = aws_sqs_queue.slack_notifications.url
    }
  }
  tags = var.tags
}

resource "aws_sns_topic_subscription" "dispatcher_subscription" {
  topic_arn = aws_sns_topic.cloudwatch_alarms_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.remediation_dispatcher.arn
}

resource "aws_lambda_permission" "allow_sns_dispatcher" {
  statement_id  = "AllowExecutionFromSNSDispatcher"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation_dispatcher.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cloudwatch_alarms_topic.arn
}


# Worker notification-intent failures are independent of remediation status but must alert operators.
resource "aws_cloudwatch_log_group" "remediation_worker_logs" {
  name              = "/aws/lambda/${var.env_prefix}-remediation-worker"
  retention_in_days = var.log_retention_in_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_metric_filter" "notification_queue_failures" {
  name           = "${var.env_prefix}-notification-queue-failures"
  log_group_name = aws_cloudwatch_log_group.remediation_worker_logs.name
  pattern        = "\"Failed to queue notification\""
  metric_transformation {
    name      = "NotificationQueueFailures"
    namespace = "${var.env_prefix}/SelfHealing"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "notification_queue_failure" {
  alarm_name          = "${var.env_prefix}-Notification-Queue-Failure"
  namespace           = "${var.env_prefix}/SelfHealing"
  metric_name         = "NotificationQueueFailures"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Worker could not enqueue a remediation outcome notification after bounded retries; inspect logs and incident notification state."
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags
}

# =============================================================================
# 6. DURABLE SLACK NOTIFICATIONS (SQS + DLQ)
# =============================================================================
resource "aws_sqs_queue" "slack_notifications_dlq" {
  name                      = "${var.env_prefix}-slack-notifications-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "slack_notifications" {
  name                       = "${var.env_prefix}-slack-notifications"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 10
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.slack_notifications_dlq.arn
    maxReceiveCount     = var.notification_max_receive_count
  })
  tags = var.tags
}

resource "aws_iam_role" "slack_notifier_role" {
  name = "${var.env_prefix}-slack-notifier-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "slack_notifier_logs" {
  role       = aws_iam_role.slack_notifier_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "slack_notifier_policy" {
  name = "${var.env_prefix}-slack-notifier-policy"
  role = aws_iam_role.slack_notifier_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"], Resource = aws_sqs_queue.slack_notifications.arn },
      { Effect = "Allow", Action = ["dynamodb:UpdateItem"], Resource = aws_dynamodb_table.remediation_incidents.arn }
    ]
  })
}

resource "aws_lambda_function" "slack_notifier" {
  filename         = data.archive_file.remediation_lambda_zip.output_path
  function_name    = "${var.env_prefix}-slack-notifier"
  role             = aws_iam_role.slack_notifier_role.arn
  handler          = "notifier.lambda_handler"
  source_code_hash = data.archive_file.remediation_lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  reserved_concurrent_executions = 2
  environment {
    variables = {
      SLACK_WEBHOOK_URL   = var.slack_webhook_url
      INCIDENT_TABLE_NAME = aws_dynamodb_table.remediation_incidents.name
      ENV_PREFIX          = var.env_prefix
    }
  }
  tags = var.tags
}

resource "aws_lambda_event_source_mapping" "slack_notification_queue" {
  event_source_arn                   = aws_sqs_queue.slack_notifications.arn
  function_name                      = aws_lambda_function.slack_notifier.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
  scaling_config { maximum_concurrency = 2 }
}

resource "aws_iam_role" "health_reporter_role" {
  name = "${var.env_prefix}-health-reporter-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "health_reporter_logs" {
  role       = aws_iam_role.health_reporter_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "health_reporter_policy" {
  name = "${var.env_prefix}-health-reporter-policy"
  role = aws_iam_role.health_reporter_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["autoscaling:DescribeAutoScalingGroups"], Resource = "*" },
      { Effect = "Allow", Action = ["elasticloadbalancing:DescribeTargetHealth"], Resource = var.target_group_arn },
      { Effect = "Allow", Action = ["cloudwatch:DescribeAlarms"], Resource = "*" },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.slack_notifications.arn }
    ]
  })
}

resource "aws_lambda_function" "health_reporter" {
  count            = var.enable_scheduled_health_reports ? 1 : 0
  filename         = data.archive_file.remediation_lambda_zip.output_path
  function_name    = "${var.env_prefix}-health-reporter"
  role             = aws_iam_role.health_reporter_role.arn
  handler          = "health_reporter.lambda_handler"
  source_code_hash = data.archive_file.remediation_lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30
  environment {
    variables = {
      ENV_PREFIX             = var.env_prefix
      ASG_NAME               = var.asg_name
      TARGET_GROUP_ARN       = var.target_group_arn
      NOTIFICATION_QUEUE_URL = aws_sqs_queue.slack_notifications.url
    }
  }
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "scheduled_health_report" {
  count               = var.enable_scheduled_health_reports ? 1 : 0
  name                = "${var.env_prefix}-scheduled-infrastructure-health"
  description         = "Periodic proactive infrastructure health summary to Slack"
  schedule_expression = var.health_report_schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "scheduled_health_report" {
  count     = var.enable_scheduled_health_reports ? 1 : 0
  rule      = aws_cloudwatch_event_rule.scheduled_health_report[0].name
  target_id = "health-reporter"
  arn       = aws_lambda_function.health_reporter[0].arn
}

resource "aws_lambda_permission" "allow_eventbridge_health_report" {
  count         = var.enable_scheduled_health_reports ? 1 : 0
  statement_id  = "AllowEventBridgeHealthReport"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_reporter[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scheduled_health_report[0].arn
}

resource "aws_cloudwatch_metric_alarm" "notification_dlq_nonempty" {
  alarm_name          = "${var.env_prefix}-Slack-Notification-DLQ-Not-Empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.slack_notifications_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Slack notification messages exhausted retry attempts and require operator review."
  alarm_actions       = [aws_sns_topic.cloudwatch_alarms_topic.arn]
  tags                = var.tags
}
