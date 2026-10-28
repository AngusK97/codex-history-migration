# Codex Session Manager

**English** | [简体中文](README.zh-CN.md)

![Windows 10 and 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows11&logoColor=white)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
[![MIT License](https://img.shields.io/badge/License-MIT-22C55E.svg)](LICENSE)

Back up, restore, and manage local Codex conversation history through a focused Windows desktop interface. Choose exactly which conversations to move, repair missing desktop indexes, adapt Provider references, or remove local history with automatic rollback protection.

> [!IMPORTANT]
> This is an unofficial, community-maintained tool and is not affiliated with OpenAI. Codex local data formats may change between releases.

## What It Does

| Task | Result |
| --- | --- |
| **Export** | Create a validated ZIP containing all or selected Codex conversations. |
| **Restore** | Merge missing conversations, repair desktop indexes, and optionally reconnect missing project paths with empty placeholder folders. |
| **Manage** | Set the Provider for selected conversations or remove selected local history. |

The interface starts in English, switches between English and Chinese instantly, and keeps technical output available under **Details** instead of opening a terminal window.

## Quick Start

### 1. Get the Tool

[Download the latest source ZIP](https://github.com/AngusK97/codex-history-migration/archive/refs/heads/main.zip) and extract it, or clone the repository:

```powershell
git clone https://github.com/AngusK97/codex-history-migration.git
cd codex-history-migration
```

No installation or third-party PowerShell module is required.

### 2. Close Codex

Fully quit Codex, ChatGPT Desktop, and any running Codex CLI process before exporting, restoring, or managing history. This prevents the tool from copying or modifying live SQLite state.

### 3. Launch the Interface

Double-click:

```text
Start-CodexHistoryMigration.vbs
```

The launcher opens only the graphical interface. The legacy `.cmd` launcher remains compatible and forwards to the same hidden entry point.

## Common Workflows

### Move History to a New Computer

1. On the old computer, open **Export**, confirm the Codex data folder, and optionally choose specific conversations.
2. Create the backup and transfer the ZIP using a protected medium.
3. On the new computer, open **Restore**, choose the ZIP, and optionally choose specific conversations.
4. Keep **Adapt sessions to this computer's Provider** enabled unless the original Provider is already configured.
5. If the old project folders do not exist on the new computer, open **Advanced options**, enable **Create placeholder folders for missing projects**, and choose an existing project root.
6. Restore, then start Codex and search for the imported conversations.

Placeholder projects are empty folders that give imported conversations a valid local working directory. They do not contain the old source code, Git history, or uncommitted changes. Restore or clone the real projects separately when you need their contents.

Use the same or a newer Codex version on the destination computer, and launch Codex at least once before restoring.

### Manage Local Conversations

Open **Manage**, explicitly select one or more conversations, then choose **Set Provider** or **Delete sessions**. Management actions never select every conversation by default and always create a complete rollback ZIP before writing.

## Compress long conversations

Before switching Provider, use **Manage → Compress context…** for one selected legacy JSONL conversation. The optional Python 3.9+ companion creates a semantic summary and retains recent context while preserving the original transcript and a recovery backup. Preview is offline; summarization uses your explicitly configured API service. See [COMPACTION.md](docs/COMPACTION.md) for setup, commands and compatibility limits.

## Safe by Default

- Validates archive structure, file sizes, and every SHA-256 hash before restoring.
- Creates rollback archives in the sibling `codex-history-backups/` directory before modifying existing data.
- Preserves same-ID destination conversations and reports conflicts instead of overwriting them.
- Excludes authentication, OAuth locks, sandbox secrets, and `config.toml` from exports.
- Rejects unsafe archive paths, undeclared files, links, junctions, and other reparse-point escapes.
- Blocks writes while Codex or ChatGPT Desktop is running.
- Requires an explicit selection and second confirmation before deleting conversations.

> [!WARNING]
> Migration ZIPs are not encrypted and contain complete conversation text. Treat them as sensitive files: do not commit them to Git, attach them to public issues, or share them through public links.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Codex installed and launched at least once
- Enough free space for the source data, a temporary staging copy, and the resulting ZIP

## Advanced Use

The PowerShell CLI supports automated export, inspection, restore, session selection, Provider updates, and deletion.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Inspect `
  -ArchivePath "E:\codex-history.zip"
```

See the [complete reference](docs/REFERENCE.md) for CLI examples, archive contents, restore semantics, parameters, troubleshooting, and project verification commands.

## Scope and Limitations

- The tool migrates local Codex history, not Git repositories, project files, login state, API keys, MCP credentials, model permissions, or `config.toml`.
- Provider adaptation updates local references only. The destination computer must already be able to use the target Provider.
- By default, recorded working directories remain paths from the old computer. The optional placeholder-project feature can create empty local folders and rewrite successfully imported session paths; it does not restore project contents.
- Generated images and visualizations are excluded by default. Shared artifacts that cannot be reliably attributed to one conversation are not removed by session deletion.
- Desktop compatibility depends on the installed Codex version and local data format. This is not an official Codex-to-Codex migration interface.

Useful background:

- [Projects and chats](https://learn.chatgpt.com/docs/projects)
- [Codex configuration reference](https://developers.openai.com/codex/config-reference/)
- [Import from another agent](https://learn.chatgpt.com/docs/import)

## Security and License

Report vulnerabilities privately by following [SECURITY.md](SECURITY.md). This project is available under the [MIT License](LICENSE).
