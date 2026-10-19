"""Unit tests for bounded remediation and recovery verification."""
import os
import sys
import unittest
from unittest.mock import patch

# Unit tests must not inherit AWS credentials from the runner or developer.
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

os.environ.setdefault(
    "TARGET_GROUP_ARN",
    "arn:aws:elasticloadbalancing:us-east-1:111111111111:"
    "targetgroup/test/abc",
)
os.environ.setdefault("ASG_NAME", "test-asg")
os.environ.setdefault("INCIDENT_TABLE_NAME", "test-incidents")
os.environ.setdefault("SLACK_WEBHOOK_URL", "")

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__), "..", "modules", "monitoring", "lambda"
    ),
)

import worker  # noqa: E402


class SignalClassificationTests(unittest.TestCase):
    def test_classifies_all_supported_alarm_families(self):
        cases = {
            "prod-ASG-High-CPU-Utilization": "cpu",
            "prod-ASG-CPU-Anomaly-Warning": "cpu_anomaly",
            "prod-ASG-High-Memory-Utilization": "memory",
            "prod-ASG-High-Disk-Utilization": "disk",
            "prod-ALB-Unhealthy-Targets": "alb_unhealthy_targets",
            "prod-App-Log-Errors-Spike": "application_errors",
            "unexpected": "unknown",
        }

        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(
                    worker.classify_signal({
                        "alarm": {"AlarmName": name}
                    }),
                    expected,
                )

    @patch.object(worker, "asg_state")
    @patch.object(worker.autoscaling, "set_desired_capacity")
    def test_scale_out_obeys_remediation_ceiling(self, set_capacity, state):
        state.return_value = (
            {"DesiredCapacity": 4, "MaxSize": 8, "MinSize": 1},
            ["i-1"],
        )

        result = worker.scale_out("CPU alarm")

        self.assertFalse(result["changed"])
        set_capacity.assert_not_called()

    def test_anomaly_detection_is_observe_only(self):
        result = worker.remediate({
            "incident_id": "INC-ANOM",
            "signal": "cpu_anomaly",
            "alarm": {
                "AlarmName": "prod-ASG-CPU-Anomaly-Warning"
            },
        })

        self.assertEqual(
            result["action"], "observe_only_anomaly_warning"
        )
        self.assertFalse(result["changed"])

    def test_disk_and_application_errors_are_observe_only(self):
        cases = (
            ("disk", "INC-D", "High-Disk"),
            ("application_errors", "INC-A", "App-Log-Errors"),
        )

        for signal, incident_id, alarm_name in cases:
            with self.subTest(signal=signal):
                result = worker.remediate({
                    "incident_id": incident_id,
                    "signal": signal,
                    "alarm": {"AlarmName": alarm_name},
                })

                self.assertEqual(result["action"], "observe_only")
                self.assertFalse(result["changed"])

    @patch.object(worker, "_recent_metric_values", return_value=[85, 86])
    @patch.object(
        worker,
        "asg_state",
        return_value=(
            {"MinSize": 1, "DesiredCapacity": 2},
            ["i-1", "i-2"],
        ),
    )
    @patch.object(worker, "_alarm_is_ok", return_value=(False, "ALARM"))
    def test_alarm_still_breaching_is_not_success(
        self, _alarm, _asg, _metrics
    ):
        result = worker.verify_signal(
            "memory", {"alarm": {"AlarmName": "memory-alarm"}}
        )
        self.assertFalse(result["success"])

    @patch.object(worker, "_recent_metric_values")
    @patch.object(
        worker,
        "asg_state",
        return_value=(
            {"MinSize": 1, "DesiredCapacity": 2},
            ["i-1", "i-2"],
        ),
    )
    @patch.object(worker, "_alarm_is_ok", return_value=(True, "OK"))
    def test_source_alarm_ok_requires_recent_metrics_and_capacity(
        self, _alarm, _asg, metrics
    ):
        def values(namespace, metric_name, dimensions, period):
            if namespace == "CustomAppMetrics":
                return [0, 1]
            return [20, 25]

        metrics.side_effect = values

        for signal in ("cpu", "memory", "disk", "application_errors"):
            with self.subTest(signal=signal):
                result = worker.verify_signal(
                    signal, {"alarm": {"AlarmName": "test"}}
                )
                self.assertTrue(result["success"])

    @patch.object(
        worker,
        "unhealthy_targets",
        return_value=[{
            "Target": {"Id": "10.0.0.9"},
            "TargetHealth": {"State": "unhealthy"},
        }],
    )
    @patch.object(
        worker,
        "asg_state",
        return_value=(
            {
                "Instances": [{
                    "InstanceId": "i-1",
                    "LifecycleState": "InService",
                }],
                "DesiredCapacity": 1,
                "MaxSize": 4,
                "MinSize": 1,
            },
            ["i-1"],
        ),
    )
    def test_non_asg_target_is_not_replaced(self, _state, _targets):
        result = worker.replace_unhealthy_target("INC-TEST")

        self.assertFalse(result["changed"])
        self.assertIn(
            "could not be safely mapped", result["summary"]
        )


if __name__ == "__main__":
    unittest.main()