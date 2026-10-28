"""Synthetic, offline compaction tests. Never touch the real Codex home."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid

SPEC = importlib.util.spec_from_file_location("compact", Path(__file__).resolve().parents[1] / "codex_history_compact.py")
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)


def message(role, text):
    return {"type": "message", "role": role, "content": [{"type": "output_text" if role == "assistant" else "input_text", "text": text}]}


def event(kind, payload):
    return {"timestamp": "2026-01-01T00:00:00Z", "type": kind, "payload": payload}


class FakeClient:
    def __init__(self, response="Goal: preserve task. Tests passed. Next: finish migration.", fail_at=None):
        self.response, self.fail_at, self.calls = response, fail_at, []

    def summarize(self, data, limit):
        self.calls.append((data, limit))
        if len(self.calls) == self.fail_at:
            raise C.CompactError("Synthetic API failure")
        return self.response


class CompactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve() / "home"
        self.sessions = self.home / "sessions" / "2026" / "01" / "01"
        self.sessions.mkdir(parents=True)
        self.session_id = str(uuid.uuid4())
        self.path = self.sessions / ("rollout-2026-01-01-" + self.session_id + ".jsonl")
        self.rows = [event("session_meta", {"id": self.session_id, "model_provider": "old"})]
        self.rows += [event("response_item", message("user", "Old goal")),
                      event("response_item", message("assistant", "Old answer")),
                      event("response_item", message("user", "Recent task")),
                      event("response_item", message("assistant", "Recent answer"))]
        self.write()
        self.args = argparse.Namespace(command="compact", codex_home=str(self.home),
                                       session=str(self.path), session_id=None, budget=16000,
                                       recent_turns=1, base_url="https://example.test/v1",
                                       model="test-model", api_key_env="UNSET_TEST_KEY")
        self.idle = mock.patch.object(C, "assert_idle")
        self.idle.start()
        self.addCleanup(self.idle.stop)

    def write(self):
        self.path.write_bytes(b"\n".join(C.encode(row) for row in self.rows) + b"\n")

    def test_append_checkpoint_preserves_full_history_and_backup(self):
        original = self.path.read_bytes()
        result = C.run(self.args, FakeClient())
        self.assertTrue(self.path.read_bytes().startswith(original))
        self.assertEqual(Path(result["backup_path"]).read_bytes(), original)
        checkpoint = C.parse_records(self.path.read_bytes())[-1]
        self.assertEqual(checkpoint["type"], "compacted")
        replacement = checkpoint["payload"]["replacement_history"]
        self.assertEqual(replacement[-2:], [message("user", "Recent task"), message("assistant", "Recent answer")])
        self.assertLessEqual(result["replacement_estimated_tokens"] + result["reserve_estimated_tokens"], self.args.budget)
        self.assertEqual(C.parse_records(self.path.read_bytes())[0]["payload"]["model_provider"], "old")

    def test_preview_offline_no_changes_and_no_process_requirement(self):
        self.args.command = "preview"
        original = self.path.read_bytes()
        with mock.patch.object(C, "ResponsesClient", side_effect=AssertionError("network")), mock.patch.object(C, "assert_idle", side_effect=AssertionError("process")):
            result = C.run(self.args)
        self.assertEqual(result["retained_turns"], 1)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse((self.home / "history-compaction-backups").exists())

    def test_session_id_resolution(self):
        self.args.command, self.args.session, self.args.session_id = "preview", None, self.session_id
        self.assertEqual(C.run(self.args)["session_id"], self.session_id)
        duplicate = self.sessions / ("duplicate-" + self.session_id + ".jsonl")
        duplicate.write_bytes(self.path.read_bytes())
        with self.assertRaises(C.CompactError):
            C.run(self.args)

    def test_overflow_recursively_chunks(self):
        self.rows.insert(1, event("response_item", message("user", "大型上下文" * 15000)))
        self.write()
        self.args.budget = 4096
        client = FakeClient()
        result = C.run(self.args, client)
        self.assertGreater(len(client.calls), 3)
        self.assertLessEqual(result["replacement_estimated_tokens"] + result["reserve_estimated_tokens"], 4096)
        for text, limit in client.calls:
            self.assertLess(len(text.encode("utf-8")), 2200)

    def test_failed_chunk_never_writes(self):
        self.rows.insert(1, event("response_item", message("user", "history " * 10000)))
        self.write()
        original = self.path.read_bytes()
        with self.assertRaises(C.CompactError):
            C.run(self.args, FakeClient(fail_at=2))
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse((self.home / "history-compaction-backups").exists())

    def test_repeated_compaction_uses_active_context_only(self):
        C.run(self.args, FakeClient("Previous summary unique marker"))
        client = FakeClient()
        C.run(self.args, client)
        sent = "\n".join(text for text, _ in client.calls)
        self.assertIn("Previous summary unique marker", sent)
        self.assertNotIn("Old goal", sent)
        self.assertIn("Recent task", sent)

    def test_tool_pairing_retained_and_orphans_only_summarized(self):
        call = {"type": "function_call", "name": "shell", "arguments": "{}", "call_id": "call1", "id": "provider_id"}
        output = {"type": "function_call_output", "call_id": "call1", "output": "Tests passed"}
        self.rows[-1:-1] = [event("response_item", call), event("response_item", output)]
        self.write()
        C.run(self.args, FakeClient())
        replacement = C.parse_records(self.path.read_bytes())[-1]["payload"]["replacement_history"]
        self.assertTrue(C.complete_turn(replacement[1:]))
        self.assertNotIn("id", replacement[2])
        self.rows[-3] = event("response_item", {**call, "call_id": "mismatch"})
        self.write()
        self.assertEqual(C.plan(self.rows, recent_turns=1)[3]["retained_turns"], 0)

    def test_commentary_does_not_count_as_complete_turn(self):
        self.rows[-1]["payload"]["phase"] = "commentary"
        self.assertEqual(C.plan(self.rows, recent_turns=1)[3]["retained_turns"], 0)

    def test_system_instructions_pinned_and_overflow_refused(self):
        self.rows.insert(1, event("response_item", message("developer", "Never modify production")))
        self.write()
        C.run(self.args, FakeClient())
        replacement = C.parse_records(self.path.read_bytes())[-1]["payload"]["replacement_history"]
        self.assertEqual(replacement[0], message("developer", "Never modify production"))
        self.rows[1] = event("response_item", message("system", "S" * 20000))
        with self.assertRaises(C.CompactError):
            C.plan(self.rows)

    def test_provider_reasoning_not_sent_or_retained(self):
        self.rows.insert(2, event("response_item", {"type": "reasoning", "encrypted_content": "SECRET_ENCRYPTED",
                         "content": [{"text": "PRIVATE_REASONING"}], "summary": [{"type": "summary_text", "text": "Readable result"}]}))
        self.write()
        client = FakeClient()
        C.run(self.args, client)
        sent = "\n".join(text for text, _ in client.calls)
        self.assertNotIn("SECRET_ENCRYPTED", sent)
        self.assertNotIn("PRIVATE_REASONING", sent)
        self.assertIn("Readable result", sent)
        replacement = C.parse_records(self.path.read_bytes())[-1]["payload"]["replacement_history"]
        self.assertNotIn("reasoning", C.encode(replacement).decode())

    def test_recognizable_secrets_redacted_before_summary(self):
        self.rows.insert(1, event("response_item", message("user", "api_key=abcdefghijk123456 sk-abcdefghijklmnop")))
        self.write()
        client = FakeClient()
        C.run(self.args, client)
        sent = "\n".join(text for text, _ in client.calls)
        self.assertNotIn("abcdefghijk123456", sent)
        self.assertNotIn("sk-abcdefghijklmnop", sent)

    def test_bad_summary_fails_before_backup(self):
        for answer in ("", "X" * 20000):
            with self.subTest(answer_length=len(answer)), self.assertRaises(C.CompactError):
                C.run(self.args, FakeClient(answer))
        self.assertFalse((self.home / "history-compaction-backups").exists())

    def test_changed_session_is_not_overwritten(self):
        original = self.path.read_bytes()
        owner = self
        class ChangingClient(FakeClient):
            def summarize(self, data, limit):
                owner.path.write_bytes(original + b"\n")
                return super().summarize(data, limit)
        with self.assertRaises(C.CompactError):
            C.run(self.args, ChangingClient())
        self.assertEqual(self.path.read_bytes(), original + b"\n")

    def test_symlink_and_backup_symlink_refused(self):
        target = self.sessions / "linked.jsonl"
        try:
            target.symlink_to(self.path)
        except OSError:
            self.skipTest("symlink unavailable")
        self.args.session = str(target)
        with self.assertRaises(C.CompactError):
            C.run(self.args, FakeClient())
        self.args.session = str(self.path)
        (self.home / "history-compaction-backups").symlink_to(self.sessions, target_is_directory=True)
        original = self.path.read_bytes()
        with self.assertRaises(C.CompactError):
            C.run(self.args, FakeClient())
        self.assertEqual(self.path.read_bytes(), original)

    def test_malformed_and_unsupported_formats(self):
        for data in (b"not-json", b'{"type":"event_msg","payload":{}}\n'):
            self.path.write_bytes(data)
            with self.assertRaises(C.CompactError):
                C.run(self.args, FakeClient())
        unsupported = [event("unknown", {}), event("event_msg", {"type": "thread_rolled_back", "num_turns": 1}),
                       event("response_item", {"type": "unknown"}),
                       event("response_item", {"type": "message", "role": "user", "content": [{"type": "input_image", "image_url": "x"}]}),
                       event("compacted", {"message": "old compact"}),
                       event("compacted", {"message": "x", "replacement_history": [], "window_number": 1})]
        for row in unsupported:
            with self.subTest(kind=row["type"]), self.assertRaises(C.CompactError):
                C.active_history(self.rows + [row])

    def test_paginated_and_attributed_histories_refused(self):
        self.rows[0]["payload"]["history_mode"] = "paginated"
        self.write()
        with self.assertRaises(C.CompactError):
            C.run(self.args, FakeClient())
        self.rows[0]["payload"]["history_mode"] = "legacy"
        self.rows[1]["metadata"] = {"inherited_user_message": True}
        self.write()
        with self.assertRaises(C.CompactError):
            C.run(self.args, FakeClient())

    def test_api_url_and_redirect_security(self):
        for url in ("http://example.com/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp"):
            with self.assertRaises(C.CompactError):
                C.ResponsesClient(url, "model", "key")
        client = C.ResponsesClient("http://127.0.0.1:1234/v1", "model", "key")
        self.assertEqual(client.url, "http://127.0.0.1:1234/v1/responses")
        with self.assertRaises(C.CompactError):
            C.NoRedirect().redirect_request(None, None, 302, "", None, "https://elsewhere.test")

    def test_mock_responses_validation(self):
        client = C.ResponsesClient("https://example.test/v1", "model", "secret-key")
        valid = {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Summary"}]}]}
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = C.encode(valid)
        client.opener.open = mock.Mock(return_value=response)
        self.assertEqual(client.summarize("data", 1000), "Summary")
        request = client.opener.open.call_args.args[0]
        self.assertFalse(json.loads(request.data)["store"])
        response.read.return_value = C.encode({**valid, "status": "incomplete"})
        with self.assertRaises(C.CompactError):
            client.summarize("data", 1000)

    def test_running_codex_refused(self):
        self.idle.stop()
        fake = mock.Mock(stdout="/Applications/Codex.app/Contents/MacOS/Codex\n")
        with mock.patch.object(C.subprocess, "run", return_value=fake), self.assertRaises(C.CompactError):
            C.assert_idle()
        self.idle.start()


if __name__ == "__main__":
    unittest.main()
