# Compress context before changing Provider

Compression reduces the **active context sent to the model**, not the size of the history file. The complete original transcript stays in place; a new compaction checkpoint supplies a summary and recent conversation for subsequent turns. A separate byte-for-byte backup is created in `CODEX_HOME/history-compaction-backups/` before publishing that checkpoint.

This is semantic, lossy summarization. It aims to preserve goals, constraints, decisions, file locations, changes, verification evidence, unresolved questions, and next actions. It does not increase a provider's context limit or fix authentication/model access.

## Windows interface

1. Install Python 3.9 or newer if necessary. Existing export/restore/Provider operations still need only Windows PowerShell 5.1.
2. Configure an API key in an environment variable available to the application. The dialog asks for the **variable name**, never the key, and does not read Codex authentication files.
3. Fully close Codex, ChatGPT Desktop and Codex CLI. Open **Manage**, select exactly one conversation, and choose **Compress context…** in the Set Provider view.
4. Fill in the service fields, set a conservative context budget and recent-turn count, then run the offline preview. Changing a field requires a fresh preview.
5. Confirm the notice that readable conversation content will be sent to that service and may incur usage charges. The original transcript is treated as material to summarize, not instructions for the summarizer.
6. After successful compression, use the existing **Set Provider** action. Restart Codex and verify that the original conversation can continue.

Compression and Provider changes remain separate operations. A compression failure does not proceed to Provider conversion. Preview never contacts an API or writes a checkpoint.

## Command line (Windows, macOS, Linux)

Use `py -3` on Windows or `python3` on macOS/Linux. The Python companion uses only the standard library. Replace the placeholders; do not put an API key in the command line.

```sh
python3 codex_history_compact.py preview \
  --codex-home /path/to/.codex \
  --session-id SESSION_UUID --budget 32000 --recent-turns 4

python3 codex_history_compact.py compact \
  --codex-home /path/to/.codex \
  --session-id SESSION_UUID --budget 32000 --recent-turns 4 \
  --base-url https://YOUR-PROVIDER.example/v1 \
  --model YOUR_MODEL --api-key-env OPENAI_API_KEY
```

You can select a transcript with `--session /path/to/rollout.jsonl` instead of `--session-id`. Use `--help` for the current supported arguments and bounds. The provider used to summarize need not be the provider used for subsequent Codex turns. It must support non-streaming Responses API requests at `BASE_URL/responses`; Chat Completions-only gateways are not supported.

Budget estimates are deliberately conservative, based on UTF-8 bytes rather than an exact model tokenizer. Leave room for Codex instructions, tools, the next prompt and model output. The estimate cannot account for every server-side wrapper or your project's future file reads. A huge recent turn may need to be summarized instead of retained verbatim.

## Compatibility and recovery

- This feature targets legacy JSONL rollouts with a recognizable `session_meta`. Unsupported storage/checkpoint shapes are rejected rather than guessed. Native paginated thread storage is not a JSONL file and is not edited by this tool.
- Images/multimodal items, unknown tool item types, rollback events and complex attributed checkpoints are currently rejected. Simple messages and function/custom-tool call/output pairs are supported.
- Summaries are readable text. The tool does not manufacture encrypted native compaction or reasoning items.
- Original history remains on disk. The next request uses the replacement context, so old details are no longer all in active memory. They can be recovered from the original transcript or backup when needed.
- Changing Provider still uses the existing Windows manager, including its SQLite index update. The Python companion does not alter Provider configuration or desktop indexes.
- Before restoring a backup, close all Codex clients. Keep any turns created after compression separately, then restore the original transcript from the reported backup path. Restoring the file also discards later turns from that live file.
- Native CLI context replay has an isolated local mock-server test. Windows GUI rendering, arbitrary third-party services and desktop version combinations require separate real-world validation; passing the mock test is not a guarantee of service compatibility.

## Implementation evidence

The checkpoint uses `type: compacted` with `payload.message` and flat `payload.replacement_history` response items. Official Codex source was checked at commit `e8e6a922c0008bc08bacc69dd2ce9b6c3c12944c`:

- [rollout_payload.rs](https://github.com/openai/codex/blob/e8e6a922c0008bc08bacc69dd2ce9b6c3c12944c/codex-rs/history/src/rollout_payload.rs): serialized checkpoint shape.
- [rollout_reconstruction.rs](https://github.com/openai/codex/blob/e8e6a922c0008bc08bacc69dd2ce9b6c3c12944c/codex-rs/core/src/session/rollout_reconstruction.rs): latest surviving checkpoint replaces the earlier model context.

## 中文使用说明

这项功能压缩的是模型实际读取的上下文，完整聊天文件不会缩小。工具分段生成摘要，保留预算内的最近对话，再给原会话追加压缩检查点；原文与独立备份都保留。摘要会损失部分细节，不等于无损迁移。

Windows：管理 → 选择一个会话 → 压缩上下文 → 离线预览 → 填写摘要服务地址、模型、Key 环境变量名 → 确认并压缩 → 回到设置 Provider。API Key 不填进界面，不会自动读取 Codex 登录凭据。新增压缩功能需要 Python 3.9+，旧有功能不新增依赖。

macOS/Linux 可运行上面的 Python 命令；原 Windows GUI 和 Provider 索引管理没有因此变成跨平台版本。遇到不支持的分页历史格式会拒绝操作。真实中转的额度、上下文限制、模型和协议兼容性仍需验证。

## Development checks

```sh
python3 -m unittest discover -s tests -p 'test_compact*.py' -v
```

The native replay test skips if Codex is unavailable. It uses only a temporary home, synthetic history and a loopback mock API; it does not use a real account, real transcript or paid inference. Existing PowerShell validation commands remain in [REFERENCE.md](REFERENCE.md).
