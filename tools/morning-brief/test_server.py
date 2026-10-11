import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("youra_brief_server", Path(__file__).with_name("server.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ScheduleValidationTests(unittest.TestCase):
    def setUp(self):
        self.wake = datetime(2026, 10, 10, 15, 0, tzinfo=timezone.utc)
        self.payload = {
            "source": "direct-oura-bluetooth", "valid": True, "nightDate": "2026-10-10",
            "onsetAt": (self.wake - timedelta(hours=8)).isoformat(), "wakeAt": self.wake.isoformat(),
            "values": {"totalSleepMinutes": 450, "timeInBedMinutes": 480, "efficiencyPercent": 94,
                       "latencyMinutes": 12, "deepMinutes": 80, "remMinutes": 95,
                       "lightMinutes": 275, "awakeMinutes": 20, "awakenings": 3},
        }

    def test_direct_oura_data_schedules_at_recorded_wake_plus_ten(self):
        received = self.wake + timedelta(minutes=9)
        result = bridge.validate(self.payload, received)
        self.assertEqual(result["deliverAt"], (self.wake + timedelta(minutes=10)).timestamp())
        self.assertEqual(result["values"]["deepMinutes"], 80)

    def test_non_ai_fallback_uses_only_supplied_facts(self):
        value = bridge.validate(self.payload, self.wake + timedelta(minutes=9))
        message = bridge.factual_fallback(value)
        self.assertIn("Sleep 7h 30m", message)
        self.assertIn("deep 1h 20m", message)
        self.assertIn("3 awakenings", message)
        self.assertNotIn("Apple Health", message)

    def test_late_sync_is_rejected_instead_of_sending_stale_sleep(self):
        with self.assertRaises(ValueError):
            bridge.validate(self.payload, self.wake + timedelta(minutes=10, seconds=1))

    def test_apple_health_and_archive_payloads_are_rejected(self):
        for source in ("apple-health", "oura-account-export", "direct-oura-bluetooth "):
            value = dict(self.payload, source=source)
            with self.subTest(source=source), self.assertRaises(ValueError):
                bridge.validate(value, self.wake)

    def test_incomplete_or_malformed_sleep_is_rejected(self):
        with self.assertRaises(ValueError):
            bridge.validate(dict(self.payload, valid=False), self.wake)
        missing = dict(self.payload, onsetAt=self.wake.isoformat())
        with self.assertRaises(ValueError):
            bridge.validate(missing, self.wake)
        invalid = dict(self.payload, values={"totalSleepMinutes": 2_000})
        with self.assertRaises(ValueError):
            bridge.validate(invalid, self.wake)


if __name__ == "__main__":
    unittest.main()
