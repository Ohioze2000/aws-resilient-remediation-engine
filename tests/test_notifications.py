"""Unit tests for notification rendering and safe reporting."""
import json
import os
import sys
import unittest
from unittest.mock import patch

# Ensure unit tests do not inherit AWS credentials from the environment.
for key in (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_PROFILE",
    "AWS_DEFAULT_PROFILE",
):
    os.environ.pop(key, None)

os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
os.environ["AWS_EC2_METADATA_DISABLED"] = "true"
os.environ["AWS_SHARED_CREDENTIALS_FILE"] = os.devnull
os.environ["AWS_CONFIG_FILE"] = os.devnull

# Non-secret application configuration required at import time.
os.environ.setdefault(
    "SLACK_WEBHOOK_URL", "https://hooks.slack.test/example"
)
os.environ.setdefault("INCIDENT_TABLE_NAME", "test-incidents")
os.environ.setdefault("WORKER_FUNCTION_NAME", "test-worker")
os.environ.setdefault(
    "NOTIFICATION_QUEUE_URL",
    "https://sqs.us-east-1.amazonaws.com/111111111111/test",
)
os.environ.setdefault("ASG_NAME", "test-asg")
os.environ.setdefault(
    "TARGET_GROUP_ARN",
    "arn:aws:elasticloadbalancing:us-east-1:111111111111:"
    "targetgroup/test/abc",
)

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__), "..", "modules", "monitoring", "lambda"
    ),
)

import notifier  # noqa: E402
import dispatcher  # noqa: E402


class NotificationRenderingTests(unittest.TestCase):
    def test_incident_detected_message_contains_operational_context(self):
        text = notifier.render({
            "type": "incident_detected",
            "incident_id": "INC-123",
            "environment": "staging",
            "signal": "cpu",
            "alarm_name": "staging-cpu",
        })
        self.assertIn("INCIDENT DETECTED", text)
        self.assertIn("INC-123", text)
        self.assertIn("staging-cpu", text)

    def test_recovery_message_is_distinct(self):
        text = notifier.render({
            "type": "alarm_recovered",
            "environment": "dev",
            "alarm_name": "cpu-alarm",
            "signal": "cpu",
        })
        self.assertIn("ALARM RECOVERED", text)
        self.assertIn("cpu-alarm", text)

    @patch.object(notifier, "_post")
    @patch.object(notifier, "_mark")
    def test_queue_handler_delivers_and_marks_sent(self, mark, post):
        event = {
            "Records": [{
                "messageId": "m-1",
                "body": json.dumps({
                    "type": "remediation_result",
                    "incident_id": "INC-1",
                    "message": "recovered",
                    "success": True,
                }),
            }]
        }

        result = notifier.lambda_handler(event, None)

        self.assertEqual(result, {"batchItemFailures": []})
        post.assert_called_once_with("recovered")
        mark.assert_called_once_with(
            "INC-1", "SENT",
            notification_type="remediation_result",
        )

    @patch.object(notifier.logger, "exception")
    @patch.object(notifier, "_post", side_effect=RuntimeError("Slack down"))
    @patch.object(notifier, "_mark")
    def test_failed_delivery_is_returned_for_sqs_retry(
        self, mark, _post, _log_exception
    ):
        event = {
            "Records": [{
                "messageId": "m-2",
                "body": json.dumps({
                    "type": "incident_detected",
                    "incident_id": "INC-2",
                }),
            }]
        }

        result = notifier.lambda_handler(event, None)

        self.assertEqual(
            result["batchItemFailures"],
            [{"itemIdentifier": "m-2"}],
        )
        mark.assert_called_once()
        self.assertEqual(mark.call_args.args[:2], ("INC-2", "RETRYING"))
        self.assertEqual(
            mark.call_args.kwargs["notification_type"],
            "incident_detected",
        )


class DispatcherClassificationTests(unittest.TestCase):
    def test_signal_classification_covers_supported_types(self):
        cases = {
            "prod-ASG-High-CPU": "cpu",
            "prod-ASG-CPU-Anomaly-Warning": "cpu_anomaly",
            "prod-ASG-High-Memory": "memory",
            "prod-ASG-High-Disk": "disk",
            "prod-ALB-Unhealthy-Targets": "alb_unhealthy_targets",
            "prod-App-Log-Errors-Spike": "application_errors",
        }

        for alarm_name, expected in cases.items():
            with self.subTest(alarm_name=alarm_name):
                self.assertEqual(
                    dispatcher._signal_for_alarm(alarm_name),
                    expected,
                )


if __name__ == "__main__":
    unittest.main()