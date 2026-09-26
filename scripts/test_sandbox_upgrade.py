"""Offline checks for the opt-in upgrade acceptance gate."""
import tempfile
import unittest
from pathlib import Path
from sandbox_upgrade import Evidence, AcceptanceFailure, Blocked


class EvidenceTests(unittest.TestCase):
    def test_missing_assertion_cannot_pass(self):
        with tempfile.TemporaryDirectory() as root:
            run = Evidence(Path(root), {"fixture": {"rows", "disk"}})
            run.scenario("fixture", lambda: run.check("rows", True))
            self.assertEqual(run.results["fixture"]["status"], "failed")

    def test_swallowed_assertion_cannot_pass(self):
        with tempfile.TemporaryDirectory() as root:
            run = Evidence(Path(root), {"fixture": {"rows"}})
            def swallowed():
                try:
                    run.check("rows", False)
                except AcceptanceFailure:
                    pass
            run.scenario("fixture", swallowed)
            self.assertEqual(run.results["fixture"]["status"], "failed")

    def test_blocked_is_unverified(self):
        with tempfile.TemporaryDirectory() as root:
            run = Evidence(Path(root), {"fixture": {"rows"}})
            def missing():
                raise Blocked("reader unavailable")
            run.scenario("fixture", missing)
            self.assertEqual(run.results["fixture"]["status"], "unverified")
            self.assertFalse(run.demonstrated())

    def test_retry_keeps_first_failure(self):
        with tempfile.TemporaryDirectory() as root:
            run = Evidence(Path(root), {"fixture": {"rows"}})
            run.scenario("fixture", lambda: run.check("rows", False))
            run.scenario("fixture", lambda: run.check("rows", True))
            self.assertEqual(len(run.results["fixture"]["attempts"]), 2)
            self.assertEqual(run.results["fixture"]["status"], "failed")
            self.assertFalse(run.demonstrated())

    def test_empty_scenario_discovery_fails(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(AcceptanceFailure):
                Evidence(Path(root), {})

    def test_dirty_or_cleanup_failure_cannot_pass(self):
        with tempfile.TemporaryDirectory() as root:
            run = Evidence(Path(root), {"fixture": {"rows"}})
            run.scenario("fixture", lambda: run.check("rows", True))
            run.metadata["dirty"] = [" M main.lua"]
            self.assertFalse(run.demonstrated())
            run.metadata["dirty"] = []
            run.metadata["reader_cleanup_error"] = "TimeoutError"
            self.assertFalse(run.demonstrated())

    def test_complete_assertions_pass(self):
        with tempfile.TemporaryDirectory() as root:
            run = Evidence(Path(root), {"fixture": {"rows", "disk"}})
            def verify():
                run.check("rows", True)
                run.check("disk", True)
            run.scenario("fixture", verify)
            self.assertTrue(run.demonstrated())


if __name__ == "__main__":
    unittest.main()
