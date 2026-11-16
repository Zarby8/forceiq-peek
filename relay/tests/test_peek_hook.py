#!/usr/bin/env python3
"""Relay tests for peek-hook.py (spec §9 step 2/3): content stripping, the §7 summary derivation,
and the held-path protocol against a fake Peek socket — allow / deny / answer / never (the never
case must print nothing and still exit 0). Run: python3 -m unittest discover -s relay/tests -v"""

import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("peek_hook", os.path.join(HERE, "..", "peek-hook.py"))
relay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(relay)


class FakePeek(threading.Thread):
    """A one-connection socket server playing Peek: records the wire line, replies as scripted."""

    def __init__(self, path, reply_line=None, hold_open=False):
        super().__init__(daemon=True)
        self.path = path
        self.reply_line = reply_line
        self.hold_open = hold_open
        self.received = None
        self.ready = threading.Event()

    def run(self):
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.path)
        srv.listen(1)
        self.ready.set()
        conn, _ = srv.accept()
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
        self.received = buf.decode()
        if self.reply_line is not None:
            conn.sendall((self.reply_line + "\n").encode())
        if not self.hold_open:
            conn.close()
        srv.close()


def run_relay(payload, argv=(), server=None, deadline=None):
    old_in, old_out, old_sock = sys.stdin, sys.stdout, relay.SOCKET_PATH
    old_deadline = os.environ.get("PEEK_HOOK_DEADLINE")
    sys.stdin = io.StringIO(json.dumps(payload))
    sys.stdout = io.StringIO()
    if server is not None:
        relay.SOCKET_PATH = server.path
    if deadline is not None:
        os.environ["PEEK_HOOK_DEADLINE"] = str(deadline)
    try:
        code = relay.run(list(argv))
        return code, sys.stdout.getvalue()
    finally:
        sys.stdin, sys.stdout, relay.SOCKET_PATH = old_in, old_out, old_sock
        if old_deadline is None:
            os.environ.pop("PEEK_HOOK_DEADLINE", None)
        else:
            os.environ["PEEK_HOOK_DEADLINE"] = old_deadline


BASE = {"session_id": "s1", "cwd": "/Users/x/Projects/ghost", "transcript_path": "/secret/t.jsonl"}


class StrippingTests(unittest.TestCase):
    def wire(self, payload, argv=()):
        with tempfile.TemporaryDirectory() as d:
            server = FakePeek(os.path.join(d, "peek.sock"))
            server.start()
            server.ready.wait(2)
            run_relay(payload, argv, server)
            server.join(2)
            return json.loads(server.received)

    def test_prompt_and_tool_payloads_never_cross(self):
        w = self.wire({**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "SECRET PROMPT"})
        self.assertNotIn("prompt", w)
        self.assertEqual(w["event"], "UserPromptSubmit")
        w = self.wire({**BASE, "hook_event_name": "PostToolUse", "tool_name": "Bash",
                       "tool_input": {"command": "rm -rf /"}, "tool_response": {"stdout": "SECRET"}})
        self.assertEqual(w["tool"], "Bash")
        self.assertNotIn("tool_input", w)
        self.assertNotIn("tool_response", w)
        self.assertNotIn("SECRET", json.dumps(w))
        self.assertNotIn("transcript", json.dumps(w))

    def test_rate_limit_flag_without_text(self):
        w = self.wire({**BASE, "hook_event_name": "Notification",
                       "message": "You have hit your rate limit, SECRET"})
        self.assertTrue(w["rate_limit"])
        self.assertNotIn("SECRET", json.dumps(w))


class SummaryTests(unittest.TestCase):
    def test_bash_truncated(self):
        s = relay.permission_summary({"tool_name": "Bash", "tool_input": {"command": "x" * 300}, "cwd": "/p"})
        self.assertEqual(len(s), 120)

    def test_edit_relative_path_and_counts(self):
        s = relay.permission_summary({"tool_name": "Edit", "cwd": "/p",
                                      "tool_input": {"file_path": "/p/src/a.ts",
                                                     "old_string": "a\nb\n", "new_string": "a\nb\nc\n"}})
        self.assertEqual(s, "Edit src/a.ts (+3 −2)")

    def test_other_tool_no_summary(self):
        self.assertIsNone(relay.permission_summary({"tool_name": "Read", "tool_input": {"file_path": "/p/x"}}))

    def test_ask_parts(self):
        q, labels = relay.ask_parts({"tool_input": {"questions": [
            {"question": "Tabs or spaces?", "options": [{"label": "Tabs"}, {"label": "Spaces"}]}]}})
        self.assertEqual(q, "Tabs or spaces?")
        self.assertEqual(labels, ["Tabs", "Spaces"])


class HeldProtocolTests(unittest.TestCase):
    PAYLOAD = {**BASE, "hook_event_name": "PermissionRequest", "tool_name": "Bash",
               "tool_input": {"command": "ls"}}

    def held(self, reply_line, payload=None, argv=(), deadline=5):
        with tempfile.TemporaryDirectory() as d:
            server = FakePeek(os.path.join(d, "peek.sock"), reply_line=reply_line)
            server.start()
            server.ready.wait(2)
            code, out = run_relay(payload or self.PAYLOAD, argv, server, deadline=deadline)
            server.join(2)
            return code, out, json.loads(server.received)

    def test_allow(self):
        code, out, wire = self.held('{"decision":"allow"}')
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"]["behavior"], "allow")
        self.assertTrue(wire["held"])
        self.assertEqual(wire["summary"], "ls")

    def test_deny(self):
        _, out, _ = self.held('{"decision":"deny"}')
        self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_never_answered_prints_nothing(self):
        # Server accepts, sends nothing, closes: EOF -> silence, exit 0.
        code, out, _ = self.held(None)
        self.assertEqual((code, out), (0, ""))

    def test_no_peek_at_all_prints_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            relay_path = relay.SOCKET_PATH
            relay.SOCKET_PATH = os.path.join(d, "absent.sock")
            try:
                code, out = run_relay(self.PAYLOAD, deadline=1)
            finally:
                relay.SOCKET_PATH = relay_path
        self.assertEqual((code, out), (0, ""))

    def test_ask_answer_builds_updated_input(self):
        payload = {**BASE, "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                   "tool_input": {"questions": [{"question": "Tabs or spaces?",
                                                 "options": [{"label": "Tabs"}, {"label": "Spaces"}]}]}}
        code, out, wire = self.held('{"decision":"answer","label":"Tabs"}', payload=payload, argv=("--ask",))
        self.assertEqual(code, 0)
        got = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(got["permissionDecision"], "allow")
        self.assertEqual(got["updatedInput"]["answers"], {"Tabs or spaces?": "Tabs"})
        self.assertEqual(wire["question"], "Tabs or spaces?")
        self.assertNotIn("tool_input", wire)

    def test_ask_terminal_choice_prints_nothing(self):
        payload = {**BASE, "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                   "tool_input": {"questions": [{"question": "Q?", "options": [{"label": "A"}]}]}}
        _, out, _ = self.held('{"decision":"terminal"}', payload=payload, argv=("--ask",))
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
