# Codex Session Manager Reference

**English** | [简体中文](REFERENCE.zh-CN.md) | [Back to README](../README.md)

This reference covers the PowerShell interface, archive contents, restore behavior, and project verification. For the recommended graphical workflow, start with the [README](../README.md).

## Command Line

Run commands from the repository root with Windows PowerShell 5.1.

### Export

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history.zip"
```

### Inspect

Inspect validates the archive without modifying local data.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Inspect `
  -ArchivePath "E:\codex-history.zip"
```

### Restore

Restore and adapt imported conversations to the provider configured on the destination computer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Import `
  -ArchivePath "E:\codex-history.zip" `
  -RewriteModelProvider `
  -ProjectRoot "E:\Projects"
```

`-ProjectRoot` is optional. It creates empty folders only for imported conversations whose recorded working directory is missing on this computer, then rewrites those conversations and compatible SQLite thread rows to the new paths.

### Set a Provider

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode SetProvider `
  -SessionSelectionFile "E:\selected-session-ids.txt" `
  -TargetModelProvider "custom"
```

### Delete Conversations

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Delete `
  -SessionSelectionFile "E:\selected-session-ids.txt"
```

`SetProvider` and `Delete` require an explicit session-selection file. They also require Codex and ChatGPT Desktop to be closed and create a complete rollback ZIP before writing.

### Use a Different Codex Data Folder

The script uses `$env:CODEX_HOME` when available and otherwise defaults to `.codex` under the current Windows user profile.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Import `
  -ArchivePath "E:\codex-history.zip" `
  -CodexHome "D:\CodexData"
```

## Selecting Conversations

Create a UTF-8 text file containing one conversation ID per line, then pass it with `-SessionSelectionFile`.

```text
0198d542-3b87-7db2-a387-11aa22bb33cc
0198d550-851a-73a2-a30c-44dd55ee66ff
```

Use `List` to print the catalog used by the graphical session picker. Supply `-ArchivePath` to list a ZIP, or omit it to list the local `-CodexHome`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode List `
  -ArchivePath "E:\codex-history.zip"
```

Partial exports exclude `.codex-global-state.json`, remove unselected rows from supported SQLite thread metadata, and omit generated artifacts that cannot be reliably attributed to one conversation.

## Archive Contents

Included by default:

```text
sessions/**
archived_sessions/**
session_index.jsonl
.codex-global-state.json
state_*.sqlite*
sqlite/state_*.sqlite*
```

Always excluded:

```text
auth.json
auth.json.bak
.sandbox-secrets/**
mcp-oauth-locks/**
cap_sid
logs_*.sqlite
config.toml
```

Export only conversations and the title index, without desktop-state databases:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history-only.zip" `
  -HistoryOnly
```

Generated images and visualizations are excluded by default. Include them in a full export with `-IncludeArtifacts`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history-with-artifacts.zip" `
  -IncludeArtifacts
```

Archives are not encrypted and contain complete conversation content. Export also creates a temporary staging copy, so keep enough free space for both the staged data and the resulting ZIP.

## Restore Semantics

- Every file must pass manifest, size, and SHA-256 validation before any write.
- Archives containing absolute paths, `..` traversal, Windows alternate data streams or device names, link entries, undeclared members, or sensitive top-level paths are rejected.
- Export sources and restore destinations containing junctions, symbolic links, or other reparse points in their path chain are rejected.
- When the destination has no supported history, supported desktop state is restored from the archive.
- When the destination already has history, same-ID destination conversations are preserved, missing conversations are copied, and `session_index.jsonl` is merged by conversation ID.
- Missing source `threads` rows are merged into compatible destination `state_*.sqlite` databases without overwriting existing rows.
- Imported thread `rollout_path` values are rewritten to the actual transcript paths on the destination computer.
- Existing desktop state is not overwritten by default. `-RestoreAppState` enables intentional replacement after a rollback backup is created.
- Partial restores always use merge semantics and cannot be combined with `-RestoreAppState`.
- A rollback ZIP is created before writing whenever the destination already contains supported data.
- Conflicting same-name conversation files remain unchanged at the destination and are reported as conflicts.
- `-RewriteModelProvider` updates only successfully imported conversations and corresponding newly merged SQLite thread rows.
- `-ProjectRoot` creates deterministic empty placeholder folders for missing recorded working directories and rewrites only successfully imported conversations. Existing working directories are kept. Name collisions use stable suffixes such as `Project-2`, and repeated restores reuse the same folders.
- Placeholder folders do not restore source code, Git history, ignored files, or uncommitted changes. Restore or clone project contents separately.
- Incompatible SQLite thread layouts are skipped with a warning while transcript and title-index restoration continues.
- Without `-TargetModelProvider`, the provider is resolved from the active profile, root-level `model_provider`, and finally the `openai` default.

## Parameters

| Parameter | Purpose |
| --- | --- |
| `-Mode` | Required. `Export`, `Import`, `Inspect`, `List`, `SetProvider`, or `Delete`. |
| `-ArchivePath` | ZIP path. Required for `Import` and `Inspect`; optional for `Export`. |
| `-CodexHome` | Override the default Codex data folder. |
| `-HistoryOnly` | Exclude desktop-state databases from an export. |
| `-IncludeArtifacts` | Include `generated_images/` and `visualizations/` in a full export. |
| `-RestoreAppState` | Replace matching destination desktop-state files after creating a rollback backup. |
| `-RewriteModelProvider` | Adapt imported history to the destination provider. Enabled by default in the GUI. |
| `-TargetModelProvider` | Explicit destination provider ID. Otherwise resolve it from `config.toml`. |
| `-ProjectRoot` | Existing root folder under which empty placeholders are created for missing imported project paths. Opt-in in the GUI. |
| `-SessionSelectionFile` | UTF-8 file with one conversation ID per line. Required for management operations. |
| `-AllowRunningCodex` | Bypass the process check. Intended only for isolated tests. |
| `-Force` | Permit replacing an existing export ZIP. Does not change import conflict handling. |

## After Restoring

Start Codex and search for the restored conversations, or inspect resumable sessions from the CLI:

```powershell
codex resume --all
```

If an older version reported `copied` greater than zero but Codex Desktop did not display the imported history, update the tool, close Codex, and restore the same ZIP again. File merging is idempotent, and the current version can add compatible `threads` rows omitted by older releases.

## Project Verification

Run the syntax checks and complete regression suite from the repository root:

```powershell
$files = 'CodexHistoryMigration.ps1', 'CodexHistoryMigration.UI.ps1', 'tests\CodexHistoryMigration.Regression.Tests.ps1', 'tests\CodexHistoryMigration.Selection.Tests.ps1', 'tests\CodexHistoryMigration.Management.Tests.ps1', 'tests\CodexHistoryMigration.Launcher.Tests.ps1', 'tests\CodexHistoryMigration.Visual.Tests.ps1'
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { $errors; throw "PowerShell syntax check failed: $file" }
}
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\CodexHistoryMigration.Regression.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\CodexHistoryMigration.Selection.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\CodexHistoryMigration.Management.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\CodexHistoryMigration.Launcher.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\CodexHistoryMigration.Visual.Tests.ps1
```
