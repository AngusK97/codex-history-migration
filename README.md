# Codex History Migration

在 Windows 电脑之间导出、校验和恢复 Codex 本地聊天历史。提供图形界面与命令行两种入口，仅依赖 Windows PowerShell 5.1，不需要安装第三方模块。

这是社区维护的非官方工具，不隶属于 OpenAI。Codex 本地数据格式可能随版本变化；正式恢复前请先使用“校验”功能，并保留工具生成的回滚包。

## 系统要求

- Windows 10 或 Windows 11。
- Windows PowerShell 5.1。
- 新电脑已经安装并至少启动过一次 Codex。

## 获取工具

```powershell
git clone https://github.com/AngusK97/codex-history-migration.git
cd codex-history-migration
```

## 能力

- `Export`：将活动会话、归档会话、标题索引和桌面端状态打包为 `.zip`。
- `Inspect`：在不修改本机数据的情况下校验归档格式、文件大小和逐文件 SHA-256。
- `Import`：校验后恢复历史；目标端已有历史时合并会话文件、标题索引和兼容的桌面端线程索引，并先自动创建回滚包。
- 恢复时可把迁入会话的 `model_provider` 重映射到新电脑当前 provider，并同步桌面端线程索引。
- 默认排除 `auth.json`、`.sandbox-secrets/`、OAuth 锁和其他认证状态。
- 默认拒绝在 Codex、Codex app server 或 ChatGPT 桌面端运行时导出或恢复，避免复制不一致的 SQLite 状态。

迁移包没有加密，里面包含完整聊天内容。请把 ZIP 当作敏感文件保存和传输。

导出时会先在系统临时目录创建一份受支持数据的暂存副本，再生成 ZIP。请预留至少“待导出数据大小 + ZIP 大小”的可用磁盘空间。

## 最短使用流程

两台电脑都应安装相同版本或更新版本的 Codex。执行导出或恢复前，先彻底退出 Codex、ChatGPT 桌面端以及正在运行的 Codex CLI。

### 图形界面（推荐）

双击：

```text
Start-CodexHistoryMigration.cmd
```

在旧电脑选择“导出”，确认 Codex 数据目录，选择 ZIP 保存位置，然后点击“导出 ZIP”。把 ZIP 和整个工具目录复制到新电脑。

在新电脑先选择“校验”，加载 ZIP 并点击“校验 ZIP”；通过后切换到“恢复”，选择相同 ZIP 和目标 Codex 数据目录，点击“恢复历史”。“改为新电脑 Provider”默认启用；目标 Provider 留空时自动读取新电脑的用户级 `config.toml`，也可以手动填写 provider ID。

界面下方会显示执行结果。恢复已有历史时会弹出确认，并沿用核心脚本的合并、冲突保护与自动备份机制。

### 命令行

在旧电脑导出：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history.zip"
```

把 `codex-history.zip` 移动到新电脑，先校验：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Inspect `
  -ArchivePath "E:\codex-history.zip"
```

在新电脑恢复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Import `
  -ArchivePath "E:\codex-history.zip" `
  -RewriteModelProvider
```

脚本默认使用 `$env:CODEX_HOME`；未设置时使用当前 Windows 用户目录下的 `.codex`。可以通过 `-CodexHome` 指定其他目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Import `
  -ArchivePath "E:\codex-history.zip" `
  -CodexHome "D:\CodexData"
```

恢复后启动 Codex，在桌面端搜索历史聊天，或使用 CLI 检查：

```powershell
codex resume --all
```

如果旧版本工具已经显示 `copied` 大于零、但 Codex Desktop 中没有出现历史，可以升级工具后关闭 Codex，再对同一个 ZIP 重复执行恢复。文件合并是幂等的，新版本会补齐此前缺失的 `threads` 索引行。

## 导出内容

默认包含：

```text
sessions/**
archived_sessions/**
session_index.jsonl
.codex-global-state.json
state_*.sqlite*
sqlite/state_*.sqlite*
```

不会包含：

```text
auth.json
auth.json.bak
.sandbox-secrets/**
mcp-oauth-locks/**
cap_sid
logs_*.sqlite
config.toml
```

只导出会话和标题索引、不包含桌面端状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history-only.zip" `
  -HistoryOnly
```

聊天引用的本地生成图片和可视化默认不打包。需要时增加 `-IncludeArtifacts`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Export `
  -ArchivePath "E:\codex-history-with-artifacts.zip" `
  -IncludeArtifacts
```

## 恢复语义

- 所有文件在写入前必须通过清单和 SHA-256 校验。
- ZIP 内存在绝对路径、`..` 路径穿越、Windows ADS/设备名、链接条目、未登记文件或敏感顶层路径时，恢复会直接失败。
- 导出来源和恢复目标的路径链中存在 junction、符号链接或其他 reparse point 时，工具会拒绝操作，避免读写越出 Codex 数据目录。
- 目标端没有历史时，自动恢复迁移包中的桌面端状态。
- 目标端已有历史时，保留目标端同名会话，只复制缺失会话，并按会话 ID 合并 `session_index.jsonl`。
- 若来源与目标存在同名且表结构兼容的 `state_*.sqlite`，工具会把来源 `threads` 表中目标缺失的会话行合并到目标数据库；已有目标行不覆盖。
- 合并或恢复桌面端状态后，迁入线程的 `rollout_path` 会改为新电脑上实际写入的 transcript 路径，避免继续引用旧电脑绝对路径。
- 目标端已有历史时默认不覆盖桌面端状态；确实需要用来源状态替换时增加 `-RestoreAppState`。
- 目标端存在受支持的数据时，恢复前会在 `.codex` 的同级目录 `codex-history-backups/` 创建回滚 ZIP。
- 同名会话文件内容不同时，目标端版本会保留，来源版本仍完整保存在导入 ZIP 中，并在结果中报告冲突数。
- `-RewriteModelProvider` 只改写成功迁入会话的 `session_meta.payload.model_provider`，并按会话 ID 同步新合并的 `state_*.sqlite` 线程行；不会覆盖目标端原有的不同会话。
- 若来源与目标线程表结构不兼容，SQLite 合并会安全跳过并显示警告，transcript 和标题索引仍按原有规则恢复。
- 未指定 `-TargetModelProvider` 时，按活动 profile、根级 `model_provider`、`openai` 默认值的顺序解析新电脑 provider。

## 参数

- `-Mode`：必填，`Export`、`Import` 或 `Inspect`。
- `-ArchivePath`：ZIP 路径。`Import` 和 `Inspect` 必填；`Export` 不指定时写入当前目录。
- `-CodexHome`：可选，覆盖默认 Codex 数据目录。
- `-HistoryOnly`：导出时不包含桌面端状态数据库。
- `-IncludeArtifacts`：导出 `generated_images/` 和 `visualizations/`。
- `-RestoreAppState`：导入到已有历史的目标端时也替换桌面端状态；执行前仍会自动备份。
- `-RewriteModelProvider`：把迁入历史指向新电脑的 provider；GUI 恢复模式默认启用。
- `-TargetModelProvider`：显式指定目标 provider ID；省略时从目标 `config.toml` 自动解析。
- `-AllowRunningCodex`：跳过进程检查。只适合隔离测试；真实迁移不建议使用。
- `-Force`：导出时允许覆盖已存在的 ZIP，不影响导入冲突策略。

## 验证

运行 PowerShell 语法检查和回归测试：

```powershell
$files = 'CodexHistoryMigration.ps1', 'CodexHistoryMigration.UI.ps1', 'tests\CodexHistoryMigration.Regression.Tests.ps1'
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { $errors; throw "PowerShell syntax check failed: $file" }
}
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\CodexHistoryMigration.Regression.Tests.ps1
```

## 边界

- 工具迁移的是 Codex 本地历史，不会复制 Git 仓库、项目文件、登录状态、MCP 凭据或 `config.toml`。
- provider 重映射只解决本地 provider 引用，不会迁移 API Key、登录授权、账号权限、模型可用性或服务端任务所有权；新电脑必须已经能正常使用目标 provider。
- 聊天记录中的旧工作目录仍然是原电脑路径。项目需要另行克隆或复制，并在新电脑重新关联目录。
- 官方 OpenAI 文档说明保存的 Codex 聊天保留 transcript 和记录的工作目录，并可以通过 `/resume` 或 `codex resume` 继续；官方导入功能目前面向 Claude Code、Claude Cowork 和 Cursor，不提供 Codex 到 Codex 的本地历史迁移，因此本工具采用本地归档方式。

参考：

- [Projects and chats](https://learn.chatgpt.com/docs/projects)
- [Codex configuration reference](https://developers.openai.com/codex/config-reference/)
- [Import from another agent](https://learn.chatgpt.com/docs/import)

## 安全问题

ZIP 中包含完整聊天内容且没有加密。不要把真实迁移包提交到 Git 仓库，也不要通过公开链接分享。安全问题请按照 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

[MIT License](LICENSE)
