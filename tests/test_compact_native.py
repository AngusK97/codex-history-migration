"""Offline integration smoke: native Codex replays a replacement checkpoint.

No OpenAI request or real Codex home is used. The only model endpoint is a
loopback HTTP fixture. Run with ``python3 -m unittest discover -s tests -p
'test_compact_native.py' -v``. Codex CLI is optional.
"""

import http.server
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
import uuid
from unittest import mock


CODEX = shutil.which("codex")
CORE_PATH = Path(__file__).resolve().parents[1] / "codex_history_compact.py"
SPEC = importlib.util.spec_from_file_location("codex_history_compact_native", CORE_PATH)
CORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CORE)


def message(role, text):
    return {
        "type": "message",
        "role": role,
        "content": [{"type": "input_text" if role == "user" else "output_text", "text": text}],
    }


@unittest.skipUnless(CODEX, "optional native smoke requires the Codex CLI")
class NativeReplayTests(unittest.TestCase):
    def test_replacement_history_is_model_input(self):
        with tempfile.TemporaryDirectory(prefix="codex-compact-native-") as folder:
            root = Path(folder).resolve()
            codex_home = root / "codex"
            work = root / "work"
            work.mkdir()
            sessions = codex_home / "sessions" / "2026" / "10" / "27"
            sessions.mkdir(parents=True)
            session_id = str(uuid.uuid4())
            timestamp = "2026-10-27T12:00:00Z"
            records = [
                {"timestamp": timestamp, "type": "session_meta", "payload": {
                    "id": session_id, "timestamp": timestamp, "cwd": str(work),
                    "originator": "codex_cli_rs", "cli_version": "0.164.0",
                    "source": "cli", "model_provider": "mock",
                    "base_instructions": {"text": "Synthetic offline test."},
                }},
                {"timestamp": timestamp, "type": "response_item", "payload": message("user", "OLD_REMOVED_MARKER")},
                {"timestamp": timestamp, "type": "response_item", "payload": {
                    "type": "function_call", "name": "exec_command", "call_id": "old_call_marker",
                    "arguments": '{"cmd":"echo OLD_TOOL_ARGUMENT_MARKER"}',
                }},
                {"timestamp": timestamp, "type": "response_item", "payload": {
                    "type": "function_call_output", "call_id": "old_call_marker", "output": "OLD_TOOL_OUTPUT_MARKER",
                }},
                {"timestamp": timestamp, "type": "response_item", "payload": message("assistant", "OLD_ASSISTANT_MARKER")},
                {"timestamp": timestamp, "type": "response_item", "payload": message("user", "RECENT_MARKER")},
                {"timestamp": timestamp, "type": "response_item", "payload": {
                    "type": "function_call", "name": "exec_command", "call_id": "recent_call_marker",
                    "arguments": '{"cmd":"echo RECENT_TOOL_ARGUMENT_MARKER"}',
                }},
                {"timestamp": timestamp, "type": "response_item", "payload": {
                    "type": "function_call_output", "call_id": "recent_call_marker", "output": "RECENT_TOOL_OUTPUT_MARKER",
                }},
                {"timestamp": timestamp, "type": "response_item", "payload": message("assistant", "RECENT_REPLY_MARKER")},
            ]
            rollout = sessions / f"rollout-2026-10-27T12-00-00-{session_id}.jsonl"
            rollout.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
            original = rollout.read_bytes()

            class Summarizer:
                def summarize(self, data, byte_limit):
                    return "SUMMARY_MARKER"

            args = argparse.Namespace(command="compact", codex_home=str(codex_home),
                                      session=str(rollout), session_id=None, budget=16000, recent_turns=1)
            # This synthetic home has no running session; the desktop hosting the
            # test may itself run Codex, so bypass only its global process check.
            with mock.patch.object(CORE, "assert_idle"):
                report = CORE.run(args, client=Summarizer())
            self.assertTrue(rollout.read_bytes().startswith(original))
            self.assertEqual(Path(report["backup_path"]).read_bytes(), original)
            captured = []

            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def do_POST(self):
                    body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                    captured.append((self.path, json.loads(body)))
                    events = [
                        {"type": "response.created", "response": {"id": "resp_mock"}},
                        {"type": "response.output_item.done", "item": {
                            "type": "message", "role": "assistant", "id": "msg_mock",
                            "content": [{"type": "output_text", "text": "OK"}],
                        }},
                        {"type": "response.completed", "response": {
                            "id": "resp_mock", "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
                        }},
                    ]
                    payload = "".join("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n" for event in events).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            # An allowlist prevents inherited API keys, provider endpoints, proxy
            # settings, and daemon routing from entering the child process.
            env = {"PATH": os.environ.get("PATH", ""), "CODEX_HOME": str(codex_home),
                   "HOME": str(root), "USERPROFILE": str(root), "TMPDIR": str(root),
                   "TEMP": str(root), "TMP": str(root)}
            for name in ("SYSTEMROOT", "WINDIR"):
                if name in os.environ:
                    env[name] = os.environ[name]
            provider = ('model_providers.mock={name="mock",base_url="http://127.0.0.1:'
                        + str(server.server_port) + '/v1",wire_api="responses",requires_openai_auth=false}')
            try:
                result = subprocess.run(
                    [CODEX, "--no-daemon", "exec", "--skip-git-repo-check", "-c", 'model_provider="mock"',
                     "-c", provider, "-m", "gpt-5.4", "resume", session_id, "CONTINUE_MARKER"],
                    cwd=work, env=env, capture_output=True, text=True, timeout=45,
                )
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(captured, result.stderr)
            self.assertTrue(all(path == "/v1/responses" for path, _ in captured))
            prompt = json.dumps(captured[0][1]["input"])
            for marker in ("SUMMARY_MARKER", "RECENT_MARKER", "RECENT_REPLY_MARKER", "CONTINUE_MARKER"):
                self.assertIn(marker, prompt)
            self.assertNotIn("OLD_REMOVED_MARKER", prompt)
            self.assertNotIn("OLD_ASSISTANT_MARKER", prompt)
            for marker in ("old_call_marker", "OLD_TOOL_ARGUMENT_MARKER", "OLD_TOOL_OUTPUT_MARKER"):
                self.assertNotIn(marker, prompt)
            tool_pair = [item for item in captured[0][1]["input"] if item.get("call_id") == "recent_call_marker"]
            self.assertEqual([item["type"] for item in tool_pair], ["function_call", "function_call_output"])
            self.assertEqual(tool_pair[0]["name"], "exec_command")
            self.assertEqual(json.loads(tool_pair[0]["arguments"]), {"cmd": "echo RECENT_TOOL_ARGUMENT_MARKER"})
            self.assertEqual(tool_pair[1]["output"], "RECENT_TOOL_OUTPUT_MARKER")


if __name__ == "__main__":
    unittest.main()
