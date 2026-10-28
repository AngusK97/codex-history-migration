# Codex Session Manager

[English](README.md) | **简体中文**

![Windows 10 和 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows11&logoColor=white)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
[![MIT 许可证](https://img.shields.io/badge/License-MIT-22C55E.svg)](LICENSE)

通过专注的 Windows 桌面界面，备份、恢复和管理 Codex 本地会话历史。你可以精确选择要迁移的会话、修复缺失的桌面索引、适配 Provider 引用，或在自动回滚保护下移除本地历史。

> [!IMPORTANT]
> 这是社区维护的非官方工具，不隶属于 OpenAI。Codex 本地数据格式可能随版本变化。

## 它能做什么

| 任务 | 结果 |
| --- | --- |
| **导出** | 将全部或指定 Codex 会话打包为经过校验的 ZIP。 |
| **恢复** | 合并缺失会话、修复桌面索引，并可用空占位文件夹重连缺失的项目路径。 |
| **管理** | 设置指定会话的 Provider，或移除指定本地会话历史。 |

界面默认显示英文，可即时切换中文和英文。技术输出收纳在“详细信息”中，启动时不会附带终端窗口。

## 快速开始

### 1. 获取工具

[下载最新源码 ZIP](https://github.com/AngusK97/codex-history-migration/archive/refs/heads/main.zip)并解压，或者克隆仓库：

```powershell
git clone https://github.com/AngusK97/codex-history-migration.git
cd codex-history-migration
```

不需要安装，也不依赖第三方 PowerShell 模块。

### 2. 关闭 Codex

导出、恢复或管理历史前，请彻底退出 Codex、ChatGPT 桌面端和正在运行的 Codex CLI，避免工具复制或修改正在使用的 SQLite 状态。

### 3. 启动界面

双击：

```text
Start-CodexHistoryMigration.vbs
```

启动器只会打开图形界面。旧的 `.cmd` 启动器仍然兼容，并会转交给同一个隐藏入口。

## 常用流程

### 把历史迁移到新电脑

1. 在旧电脑打开“导出”，确认 Codex 数据目录，并按需选择指定会话。
2. 创建备份，通过受保护的介质传输 ZIP。
3. 在新电脑打开“恢复”，选择 ZIP，并按需选择指定会话。
4. 除非原 Provider 已经在新电脑配置完成，否则保持“适配为本机 Provider”启用。
5. 如果旧项目目录在新电脑上不存在，展开“高级选项”，启用“为缺失项目创建占位文件夹”，并选择一个已有的项目根目录。
6. 执行恢复，然后启动 Codex 并搜索迁入会话。

占位项目只是为迁入会话提供有效本机工作目录的空文件夹，不包含旧源码、Git 历史或未提交改动。需要项目内容时，仍应单独恢复或克隆真实项目。

目标电脑应使用相同或更新版本的 Codex，并且需要在恢复前至少启动过一次 Codex。

### 管理本机会话

打开“管理”，明确选择一个或多个会话，然后选择“设置 Provider”或“删除会话”。管理操作不会默认选中全部会话，并且在写入前始终创建完整回滚 ZIP。

## 默认安全策略

- 恢复前校验归档结构、文件大小和每个文件的 SHA-256。
- 修改已有数据前，在 `.codex` 同级的 `codex-history-backups/` 创建回滚包。
- 保留目标端同 ID 会话并报告冲突，不直接覆盖。
- 导出时排除认证状态、OAuth 锁、沙箱密钥和 `config.toml`。
- 拒绝不安全归档路径、未登记文件、链接、junction 和其他 reparse-point 越界。
- Codex 或 ChatGPT 桌面端运行时阻止写入。
- 删除会话前必须明确选择，并进行二次确认。

> [!WARNING]
> 迁移 ZIP 没有加密，并包含完整聊天内容。请把它当作敏感文件：不要提交到 Git、附加到公开 Issue，或通过公开链接分享。

## 系统要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1
- 已安装并至少启动过一次 Codex
- 有足够空间同时容纳来源数据、临时暂存副本和最终 ZIP

## 高级用法

PowerShell CLI 支持自动导出、校验、恢复、会话选择、Provider 更新和删除。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexHistoryMigration.ps1 `
  -Mode Inspect `
  -ArchivePath "E:\codex-history.zip"
```

CLI 示例、归档内容、恢复规则、参数、故障处理和项目验证命令，请参阅[完整参考文档](docs/REFERENCE.zh-CN.md)。

## 范围和限制

- 工具迁移 Codex 本地历史，不会复制 Git 仓库、项目文件、登录状态、API Key、MCP 凭据、模型权限或 `config.toml`。
- Provider 适配只更新本地引用。目标电脑必须已经能够使用对应 Provider。
- 默认情况下，会话记录的工作目录仍是旧电脑路径。可选的占位项目功能会创建空本机目录，并改写成功迁入会话的路径；它不会恢复项目内容。
- 生成图片和可视化默认不导出。删除会话时，也不会移除无法可靠归属到单个会话的共享产物。
- 桌面端兼容性取决于已安装的 Codex 版本和本地数据格式。这不是官方 Codex 到 Codex 迁移接口。

相关资料：

- [Projects and chats](https://learn.chatgpt.com/docs/projects)
- [Codex configuration reference](https://developers.openai.com/codex/config-reference/)
- [Import from another agent](https://learn.chatgpt.com/docs/import)

## 安全和许可证

请按照 [SECURITY.md](SECURITY.md) 私下报告安全问题。本项目使用 [MIT License](LICENSE)。

## 压缩过长的会话

在切换 Provider 前，通过“管理 → 压缩上下文”处理一个选中的旧 JSONL 会话。新增功能需要 Python 3.9+；先离线预览，再调用你明确配置的 API 服务生成摘要，保留预算内的最近对话、完整原文及恢复备份。压缩完成后再设置 Provider。详见 [COMPACTION.md](docs/COMPACTION.md) 中的中文说明与命令。
