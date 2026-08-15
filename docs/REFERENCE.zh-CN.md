# Codex Session Manager 高级参考

[English](REFERENCE.md) | **简体中文** | [返回 README](../README.zh-CN.md)

本文档包含 PowerShell 接口、归档内容、恢复行为和项目验证方法。推荐的图形界面流程请先阅读[项目首页](../README.zh-CN.md)。

## 命令行

在仓库根目录使用 Windows PowerShell 5.1 执行命令。

### 导出

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history.zip"
```

### 校验

`Inspect` 只校验归档，不修改本机数据。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Inspect `
  -ArchivePath "E:\codex-history.zip"
```

### 恢复

恢复会话，并将迁入会话适配到新电脑配置的 Provider：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Import `
  -ArchivePath "E:\codex-history.zip" `
  -RewriteModelProvider `
  -ProjectRoot "E:\Projects"
```

`-ProjectRoot` 是可选参数。它只为工作目录在本机不存在的迁入会话创建空文件夹，然后把这些会话及兼容 SQLite 线程行改写到新路径。

### 设置 Provider

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode SetProvider `
  -SessionSelectionFile "E:\selected-session-ids.txt" `
  -TargetModelProvider "custom"
```

### 删除会话

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Delete `
  -SessionSelectionFile "E:\selected-session-ids.txt"
```

`SetProvider` 和 `Delete` 必须显式提供会话选择文件。执行前需要关闭 Codex 和 ChatGPT 桌面端，并且工具会在写入前创建完整回滚 ZIP。

### 使用其他 Codex 数据目录

脚本优先使用 `$env:CODEX_HOME`；未设置时使用当前 Windows 用户目录下的 `.codex`。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Import `
  -ArchivePath "E:\codex-history.zip" `
  -CodexHome "D:\CodexData"
```

## 选择会话

创建一个 UTF-8 文本文件，每行填写一个会话 ID，然后通过 `-SessionSelectionFile` 传入。

```text
0198d542-3b87-7db2-a387-11aa22bb33cc
0198d550-851a-73a2-a30c-44dd55ee66ff
```

`List` 模式可输出图形界面会话选择器使用的目录。提供 `-ArchivePath` 时列出 ZIP，否则列出本机 `-CodexHome`。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode List `
  -ArchivePath "E:\codex-history.zip"
```

部分导出不会包含 `.codex-global-state.json`，会移除受支持 SQLite 元数据中未选会话的记录，也不会包含无法可靠归属到单个会话的生成产物。

## 归档内容

默认包含：

```text
sessions/**
archived_sessions/**
session_index.jsonl
.codex-global-state.json
state_*.sqlite*
sqlite/state_*.sqlite*
```

始终排除：

```text
auth.json
auth.json.bak
.sandbox-secrets/**
mcp-oauth-locks/**
cap_sid
logs_*.sqlite
config.toml
```

只导出会话和标题索引，不包含桌面端状态数据库：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history-only.zip" `
  -HistoryOnly
```

生成图片和可视化默认不导出。完整备份时可通过 `-IncludeArtifacts` 加入：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history-with-artifacts.zip" `
  -IncludeArtifacts
```

归档没有加密并包含完整聊天内容。导出时还会创建临时暂存副本，因此请为暂存数据和最终 ZIP 同时预留空间。

## 恢复规则

- 所有文件在写入前必须通过清单、大小和 SHA-256 校验。
- 包含绝对路径、`..` 路径穿越、Windows ADS 或设备名、链接条目、未登记文件或敏感顶层路径的归档会被拒绝。
- 来源或目标路径链中存在 junction、符号链接或其他 reparse point 时，工具会拒绝操作。
- 目标端没有受支持历史时，会恢复归档中的受支持桌面状态。
- 目标端已有历史时，保留同 ID 的本机会话，只复制缺失会话，并按会话 ID 合并 `session_index.jsonl`。
- 来源 `threads` 表中缺失的行会合并到结构兼容的目标 `state_*.sqlite`，但不会覆盖已有行。
- 迁入线程的 `rollout_path` 会改为新电脑实际写入的 transcript 路径。
- 默认不覆盖已有桌面状态。`-RestoreAppState` 用于有意替换，并会先创建回滚备份。
- 部分会话恢复始终采用合并策略，不能与 `-RestoreAppState` 同时使用。
- 目标已有受支持数据时，任何写入前都会创建回滚 ZIP。
- 同名但内容不同的会话文件保留目标版本，并计入冲突数。
- `-RewriteModelProvider` 只修改成功迁入的会话及其新合并的 SQLite 线程行。
- `-ProjectRoot` 为缺失的旧工作目录创建确定性的空占位文件夹，并只改写成功迁入的会话。已有工作目录保持不变；同名目录使用 `Project-2` 等稳定后缀，重复恢复会复用相同文件夹。
- 占位文件夹不会恢复源码、Git 历史、忽略文件或未提交改动。项目内容仍需单独恢复或克隆。
- SQLite 线程表结构不兼容时会显示警告并跳过，transcript 和标题索引仍继续恢复。
- 未指定 `-TargetModelProvider` 时，按活动 profile、根级 `model_provider`、`openai` 默认值的顺序解析 Provider。

## 参数

| 参数 | 用途 |
| --- | --- |
| `-Mode` | 必填。`Export`、`Import`、`Inspect`、`List`、`SetProvider` 或 `Delete`。 |
| `-ArchivePath` | ZIP 路径。`Import` 和 `Inspect` 必填；`Export` 可选。 |
| `-CodexHome` | 覆盖默认 Codex 数据目录。 |
| `-HistoryOnly` | 导出时排除桌面状态数据库。 |
| `-IncludeArtifacts` | 在完整导出中加入 `generated_images/` 和 `visualizations/`。 |
| `-RestoreAppState` | 创建回滚备份后，替换目标端对应桌面状态文件。 |
| `-RewriteModelProvider` | 把迁入历史适配到目标 Provider；图形界面默认启用。 |
| `-TargetModelProvider` | 显式指定目标 Provider ID；否则从 `config.toml` 解析。 |
| `-ProjectRoot` | 已有的项目根目录；在其下为缺失的迁入项目路径创建空占位文件夹。图形界面中为可选项。 |
| `-SessionSelectionFile` | UTF-8 文件，每行一个会话 ID；管理操作中为必填。 |
| `-AllowRunningCodex` | 跳过进程检查，仅用于隔离测试。 |
| `-Force` | 允许替换已有导出 ZIP，不改变导入冲突策略。 |

## 恢复之后

启动 Codex 并搜索恢复的会话，或通过 CLI 查看可继续的会话：

```powershell
codex resume --all
```

如果旧版工具显示 `copied` 大于零，但 Codex Desktop 中没有出现迁入历史，请更新工具、关闭 Codex，然后对同一个 ZIP 再次恢复。文件合并具有幂等性，新版本可以补齐旧版本遗漏的兼容 `threads` 索引行。

## 项目验证

在仓库根目录执行语法检查和完整回归测试：

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
