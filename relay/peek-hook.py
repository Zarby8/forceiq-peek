#!/usr/bin/env python3
"""Peek's Claude Code hook relay (peek-agent-watcher-spec-2026-11-16, §3/§3.1/§7).

Registered in ~/.claude/settings.json for SessionStart, SessionEnd, UserPromptSubmit, PreToolUse,
PostToolUse, PostToolUseFailure, Notification, Stop, StopFailure and PermissionRequest, plus a
PreToolUse matcher for AskUserQuestion (run with --ask). It reads the hook payload on stdin and
forwards ONE stripped JSON line to Peek's Unix socket
(~/Library/Application Support/ForceIQPeek/peek.sock):

  forwarded:  session_id, event, tool NAME, cwd, ts, tmux pane/session/window labels, a rate-limit
              flag (Notification), and — held events only — the derived display summary (§7).
  never sent: prompt, tool_input / tool_response payloads, last_assistant_message, the transcript
              (never read), file contents, environment.

Ordinary events are fire-and-forget (0.3 s): if Peek isn't running the event is simply missed and
Claude Code never notices. Held events (PermissionRequest, AskUserQuestion) keep the socket open
until Peek replies or the deadline passes (118 s / 125 s, inside Claude Code's 120 s / 130 s hook
timeouts); a reply is printed as hookSpecificOutput. No reply, a dead Peek, or any error at all:
print nothing, exit 0, and Claude Code asks in the terminal as usual. This script never exits
non-zero and never writes to stderr.
"""

import json
import os
import socket
import subprocess
import sys
import time

SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/ForceIQPeek")
SOCKET_PATH = os.environ.get("PEEK_HOOK_SOCK") or os.path.join(SUPPORT_DIR, "peek.sock")
FIRE_FORGET_TIMEOUT = 0.3
SUMMARY_BASH_CHARS = 120
SUMMARY_QUESTION_CHARS = 200


def tmux_labels():
    """(pane, session, window) from the hook process's own environment; empty outside tmux."""
    pane = os.environ.get("TMUX_PANE") or ""
    if not pane:
        return "", "", ""
    try:
        out = subprocess.run(
            ["tmux", "display-message", "-p", "-t", pane, "#{session_name}\t#{window_index}"],
            capture_output=True, text=True, timeout=1,
        ).stdout.strip()
        parts = out.split("\t")
        return pane, parts[0] if parts else "", parts[1] if len(parts) > 1 else ""
    except Exception:
        return pane, "", ""


def line_counts(text):
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def permission_summary(payload):
    """The §7 carve-out: a display summary derived from tool_input, never the payload itself.
    Bash: the command, truncated. Edit/Write: project-relative path + line-change counts.
    Anything else: None (the card shows the tool name alone)."""
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    if not isinstance(ti, dict):
        return None
    cwd = payload.get("cwd") or ""
    if tool == "Bash":
        cmd = str(ti.get("command") or "").strip()
        return cmd[:SUMMARY_BASH_CHARS] or None
    if tool in ("Edit", "Write", "MultiEdit"):
        path = str(ti.get("file_path") or "")
        if not path:
            return None
        if cwd and path.startswith(cwd.rstrip("/") + "/"):
            path = path[len(cwd.rstrip("/")) + 1:]
        if tool == "Edit":
            return "Edit %s (+%d −%d)" % (path, line_counts(str(ti.get("new_string") or "")),
                                          line_counts(str(ti.get("old_string") or "")))
        if tool == "MultiEdit":
            adds = sum(line_counts(str(e.get("new_string") or "")) for e in ti.get("edits") or [] if isinstance(e, dict))
            dels = sum(line_counts(str(e.get("old_string") or "")) for e in ti.get("edits") or [] if isinstance(e, dict))
            return "Edit %s (+%d −%d)" % (path, adds, dels)
        return "Write %s (+%d)" % (path, line_counts(str(ti.get("content") or "")))
    return None


def ask_parts(payload):
    """AskUserQuestion's first question: (question ≤ 200 chars, [option labels]). The rest of the
    payload stays here; Peek only ever sees these."""
    ti = payload.get("tool_input") or {}
    questions = ti.get("questions") if isinstance(ti, dict) else None
    if not questions or not isinstance(questions, list) or not isinstance(questions[0], dict):
        return None, []
    q = questions[0]
    text = str(q.get("question") or "")[:SUMMARY_QUESTION_CHARS] or None
    labels = [str(o.get("label")) for o in q.get("options") or [] if isinstance(o, dict) and o.get("label")]
    return text, labels


def wire_event(payload, ask):
    event = payload.get("hook_event_name") or ""
    pane, session, window = tmux_labels()
    wire = {
        "session_id": payload.get("session_id") or "",
        "event": event,
        "tool": payload.get("tool_name") or "",
        "cwd": payload.get("cwd") or "",
        "ts": time.time(),
        "tmux_pane": pane,
        "tmux_session": session,
        "tmux_window": window,
    }
    if event == "Notification":
        wire["rate_limit"] = "rate limit" in str(payload.get("message") or "").lower()
    if ask:
        question, labels = ask_parts(payload)
        wire["held"] = True
        wire["question"] = question or ""
        wire["options"] = labels
    elif event == "PermissionRequest":
        wire["held"] = True
        summary = permission_summary(payload)
        if summary:
            wire["summary"] = summary
    return wire


def print_permission_output(reply):
    behavior = reply.get("decision")
    if behavior not in ("allow", "deny"):
        return
    out = {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                  "decision": {"behavior": behavior}}}
    sys.stdout.write(json.dumps(out) + "\n")


def print_ask_output(reply, payload):
    if reply.get("decision") != "answer":
        return
    label = reply.get("label")
    question, labels = ask_parts(payload)
    if not label or not question or label not in labels:
        return
    ti = payload.get("tool_input") or {}
    updated = dict(ti) if isinstance(ti, dict) else {}
    answers = dict(updated.get("answers") or {})
    answers[question] = label
    updated["answers"] = answers
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                  "permissionDecision": "allow",
                                  "updatedInput": updated}}
    sys.stdout.write(json.dumps(out) + "\n")


def run(argv):
    ask = "--ask" in argv
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0
    event = payload.get("hook_event_name") or ""
    held = ask or event == "PermissionRequest"
    line = json.dumps(wire_event(payload, ask)) + "\n"
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if not held:
            sock.settimeout(FIRE_FORGET_TIMEOUT)
            sock.connect(SOCKET_PATH)
            sock.sendall(line.encode())
            sock.close()
            return 0
        deadline = float(os.environ.get("PEEK_HOOK_DEADLINE") or ("125" if ask else "118"))
        sock.settimeout(deadline)
        sock.connect(SOCKET_PATH)
        sock.sendall(line.encode())
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                return 0            # Peek closed without a reply: the terminal asks
            buf += chunk
        sock.close()
        reply = json.loads(buf.split(b"\n", 1)[0].decode() or "{}")
    except Exception:
        return 0                    # no Peek, a timeout, a garbled reply: the terminal asks
    if ask:
        print_ask_output(reply, payload)
    else:
        print_permission_output(reply)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except Exception:
        sys.exit(0)
