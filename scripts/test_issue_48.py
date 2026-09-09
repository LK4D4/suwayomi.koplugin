"""Offline regression coverage for the composed reader readiness boundary (#48)."""

import ctypes.util
import errno
import io
import json
from contextlib import ExitStack
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error

import sandbox
import sandbox_ui


class Response(io.BytesIO):
    status = 200


class ReaderReadinessTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        (self.root / "logs").mkdir()
        (self.root / "profile").mkdir()
        (self.root / "sandbox.json").write_text(json.dumps({
            "format": 1, "server_port": 4567, "inspector_port": 8081,
        }), encoding="utf-8")
        (self.root / "secrets.json").write_text(json.dumps({
            "username": "fixture-user", "password": "fixture-password",
        }), encoding="utf-8")
        (self.root / "profile/inspector.token").write_text("a" * 64, encoding="ascii")
        self.now = 0.0
        self.ready_at = 0.0
        self.exit_at = None
        self.probes = []
        self.transport_error = lambda: urllib.error.URLError(
            ConnectionRefusedError(errno.ECONNREFUSED, "private transport detail"))
        self.child = Mock(pid=12345, returncode=None)
        self.child.poll.side_effect = self.poll
        self.child.wait.side_effect = self.wait
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        patches = [
            patch.object(sandbox.time, "monotonic", side_effect=lambda: self.now),
            patch.object(sandbox.time, "sleep", side_effect=self.sleep),
            patch.object(sandbox, "live_process", return_value=None),
            patch.object(sandbox, "available_port"),
            patch.object(sandbox, "verify_deployment"),
            patch.object(sandbox, "unique_path", return_value=self.root / "koreader.sh"),
            patch.object(sandbox, "process_identity", return_value="fixture-start"),
            patch.object(sandbox.subprocess, "Popen", return_value=self.child),
            patch.dict(sandbox.os.environ, {"DISPLAY": ":fixture"}),
            patch.object(ctypes.util, "find_library", return_value="fixture-library"),
            patch.object(sandbox_ui.urllib.request, "build_opener", return_value=Mock(open=self.open)),
            patch("sys.stdout", self.stdout),
            patch("sys.stderr", self.stderr),
        ]
        for context in patches:
            self.stack.enter_context(context)
        self.quit = self.stack.enter_context(patch.object(
            sandbox_ui.Inspector, "quit", side_effect=sandbox_ui.SandboxUIError("Quit unavailable")))

    def sleep(self, duration):
        self.now += duration

    def poll(self):
        if self.exit_at is not None and self.now >= self.exit_at:
            self.child.returncode = 1
        return self.child.returncode

    def wait(self, timeout=None):
        if timeout is not None and self.poll() is None:
            raise subprocess.TimeoutExpired("fixture reader", timeout)
        self.child.returncode = 0 if self.child.returncode is None else self.child.returncode
        return self.child.returncode

    def open(self, request, timeout):
        self.probes.append((self.now, request, timeout))
        if self.now < self.ready_at:
            raise self.transport_error()
        return Response(b'[{"title":"Suwayomi"}]')

    def test_immediate_authenticated_readiness(self):
        sandbox.launch(self.root, "reader")
        self.assertIn("reader ready", self.stdout.getvalue())
        self.assertEqual(self.now, 0)
        self.assertEqual(len(self.probes), 1)
        self.assertEqual(self.probes[0][1].get_header("Authorization"), "Bearer " + "a" * 64)
        self.quit.assert_not_called()

    def test_delayed_inspector_becomes_ready_after_transition_window(self):
        self.ready_at = 20
        sandbox.launch(self.root, "reader")
        self.assertIn("reader ready", self.stdout.getvalue())
        self.assertGreaterEqual(self.now, 20)
        self.assertLess(self.now, 90)
        self.quit.assert_not_called()
        self.assertFalse((self.root / "reader.pid.json").exists())
        self.assertTrue(all(request.full_url.endswith("/observe/") for _, request, _ in self.probes))

    def test_never_ready_stops_at_deadline_and_retains_live_process(self):
        self.ready_at = float("inf")
        with self.assertRaisesRegex(RuntimeError, "did not become ready"):
            sandbox.launch(self.root, "reader")
        self.assertEqual(self.now, 90)
        self.assertLess(self.probes[-1][0], 90)
        self.assertTrue(all(timeout <= 90 - started for started, _, timeout in self.probes))
        self.quit.assert_called_once_with()
        self.assertEqual(json.loads((self.root / "reader.pid.json").read_text())["pid"], self.child.pid)
        self.assertIn("retained its owned process record", self.stderr.getvalue())
        self.assertNotIn("reader ready", self.stdout.getvalue())

    def test_deadline_allows_graceful_exit_and_removes_only_owned_record(self):
        self.ready_at = float("inf")
        self.quit.side_effect = lambda: setattr(self.child, "returncode", 0)
        with self.assertRaisesRegex(RuntimeError, "did not become ready"):
            sandbox.launch(self.root, "reader")
        self.quit.assert_called_once_with()
        self.assertFalse((self.root / "reader.pid.json").exists())
        self.assertTrue((self.root / "profile/inspector.token").is_file())

    def test_exited_reader_is_detected_between_startup_probes(self):
        self.ready_at = float("inf")
        self.exit_at = 1
        with self.assertRaisesRegex(RuntimeError, "exited before readiness"):
            sandbox.launch(self.root, "reader")
        self.assertEqual(self.now, 1)
        self.quit.assert_not_called()
        self.assertFalse((self.root / "reader.pid.json").exists())

    def test_reader_exit_during_observation_does_not_publish_readiness(self):
        self.exit_at = 1

        def transport(request, timeout):
            self.now = 1
            return Response(b'[{"title":"Suwayomi"}]')

        with patch.object(sandbox_ui.urllib.request, "build_opener", return_value=Mock(open=transport)):
            with self.assertRaisesRegex(RuntimeError, "exited before readiness"):
                sandbox.launch(self.root, "reader")
        self.assertNotIn("reader ready", self.stdout.getvalue())
        self.quit.assert_not_called()
        self.assertFalse((self.root / "reader.pid.json").exists())

    def test_observation_after_deadline_does_not_publish_readiness(self):
        def transport(request, timeout):
            self.now = 90
            return Response(b'[{"title":"Suwayomi"}]')

        with patch.object(sandbox_ui.urllib.request, "build_opener", return_value=Mock(open=transport)):
            with self.assertRaisesRegex(RuntimeError, "did not become ready"):
                sandbox.launch(self.root, "reader")
        self.assertNotIn("reader ready", self.stdout.getvalue())
        self.quit.assert_called_once_with()
        self.assertTrue((self.root / "reader.pid.json").exists())

    def test_authentication_rejection_is_immediate_and_private(self):
        self.ready_at = float("inf")
        self.transport_error = lambda: urllib.error.HTTPError(
            "http://private.invalid", 401, "private credentials", {}, None)
        with self.assertRaises(sandbox_ui.SandboxUIError) as raised:
            sandbox.launch(self.root, "reader")
        self.assertEqual(str(raised.exception), "Inspector HTTP 401")
        self.assertNotIsInstance(raised.exception, sandbox_ui.InspectorConnectionError)
        self.assertEqual(self.now, 0)
        self.assertEqual(len(self.probes), 1)

    def test_invalid_configuration_does_not_attempt_connection(self):
        (self.root / "profile/inspector.token").write_text("invalid", encoding="ascii")
        with self.assertRaises(sandbox_ui.SandboxUIError) as raised:
            sandbox.launch(self.root, "reader")
        self.assertNotIsInstance(raised.exception, sandbox_ui.InspectorConnectionError)
        self.assertEqual(self.now, 0)
        self.assertEqual(self.probes, [])

    def test_unrecognized_transport_failure_is_not_retried(self):
        self.ready_at = float("inf")
        self.transport_error = lambda: urllib.error.URLError(OSError("private DNS failure"))
        with self.assertRaises(sandbox_ui.SandboxUIError) as raised:
            sandbox.launch(self.root, "reader")
        self.assertNotIsInstance(raised.exception, sandbox_ui.InspectorConnectionError)
        self.assertNotIn("private DNS failure", str(raised.exception))
        self.assertEqual(self.now, 0)
        self.assertEqual(len(self.probes), 1)

    def test_transition_expiry_preserves_safe_transient_error(self):
        self.ready_at = float("inf")
        for error in (
            lambda: urllib.error.URLError(ConnectionRefusedError(errno.ECONNREFUSED, "private")),
            lambda: urllib.error.URLError(ConnectionResetError("private")),
            lambda: ConnectionResetError("private"),
        ):
            with self.subTest(error=error):
                self.now = 0
                self.transport_error = error
                with self.assertRaises(sandbox_ui.InspectorConnectionError) as raised:
                    sandbox_ui.Inspector(self.root).observe()
                self.assertGreaterEqual(self.now, 15)
                self.assertLess(self.now, 15.01)
                self.assertIsInstance(raised.exception, sandbox_ui.SandboxUIError)
                self.assertNotIn("private", str(raised.exception))

    def test_reset_action_is_not_replayed_or_classified_as_readiness(self):
        control = {"label": "Action", "enabled": True, "ready": True,
                   "activate": "/koreader/ui/httpinspector/action/1"}
        actions = []

        def transport(request, timeout):
            if request.full_url.endswith("/observe/"):
                return Response(json.dumps([{"controls": [control]}]).encode())
            actions.append(request.full_url)
            raise ConnectionResetError("possibly executed")

        with patch.object(sandbox_ui.urllib.request, "build_opener", return_value=Mock(open=transport)):
            with self.assertRaises(sandbox_ui.SandboxUIError) as raised:
                sandbox_ui.Inspector(self.root).tap("Action")
        self.assertNotIsInstance(raised.exception, sandbox_ui.InspectorConnectionError)
        self.assertEqual(len(actions), 1)
        self.assertEqual(self.now, 0)


if __name__ == "__main__":
    unittest.main()
