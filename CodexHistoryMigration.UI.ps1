#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$script:CoreScriptPath = Join-Path $PSScriptRoot "CodexHistoryMigration.ps1"
$script:ThemePath = Join-Path $PSScriptRoot "CodexHistoryMigration.UI.Theme.psd1"
$script:SelectedMode = "Export"
$script:SelectedManagementAction = "SetProvider"
$script:Language = "en"
$script:AdvancedExpanded = $false
$script:DetailsExpanded = $false
$script:ActiveProcess = $null
$script:OutputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:SelectionFile = ""
$script:AvailableSessions = @()
$script:SelectedSessionIds = $null
$script:ArchiveIsPartial = $false
$script:SuppressSelectionReset = $false
$script:ForceExportOverwrite = $false
$script:CurrentStatusKey = "readyExport"
$script:ProgressValue = 0
$script:ProgressFill = $null
$script:ProgressTrack = $null
$script:ModeValues = @{
    Export = @{ Source = ""; Destination = "" }
    Import = @{ Source = ""; Destination = "" }
    Manage = @{ Source = ""; Destination = "" }
}

$script:Strings = @{
    zh = @{
        appTitle = "Codex 会话管理器"
        export = "导出"
        import = "恢复"
        manage = "管理"
        exportTitle = "导出会话备份"
        importTitle = "恢复会话备份"
        manageTitle = "管理本机会话"
        chinese = "中"
        english = "EN"
        exportSource = "Codex 数据目录"
        importSource = "备份 ZIP"
        exportDestination = "备份 ZIP 保存位置"
        importDestination = "Codex 数据目录"
        manageSource = "Codex 数据目录"
        managementAction = "管理操作"
        setProvider = "设置 Provider"
        deleteSessions = "删除会话"
        sessions = "会话范围"
        selectedSessions = "已选择 {0} / {1} 个会话"
        sessionsNotLoaded = "全部会话（可按需选择）"
        manageSessionsNotSelected = "尚未选择会话（管理操作必须明确选择）"
        chooseSessions = "选择会话"
        advanced = "高级选项"
        details = "详细信息"
        historyOnly = "仅备份聊天历史"
        includeArtifacts = "包含生成图片与可视化"
        overwriteState = "使用备份覆盖本机桌面状态"
        rewriteProvider = "适配为本机 Provider"
        targetProvider = "目标 Provider"
        createProjectPlaceholders = "为缺失项目创建占位文件夹"
        projectRoot = "项目根目录"
        createBackup = "创建备份"
        restoreSessions = "恢复会话"
        updateProvider = "更新 Provider"
        removeSessions = "删除会话"
        safety = "操作前请彻底退出 Codex / ChatGPT"
        readyExport = "准备导出"
        readyImport = "准备恢复"
        readyManage = "请选择会话并设置管理操作"
        loadingSessions = "正在读取会话..."
        starting = "正在启动..."
        completed = "操作完成"
        failed = "操作失败"
        startFailed = "启动失败"
        PreparingExport = "正在准备备份"
        ScanningSessions = "正在扫描会话"
        CreatingManifest = "正在生成清单"
        CompressingArchive = "正在压缩备份"
        PreparingRestore = "正在准备恢复"
        ValidatingArchive = "正在校验备份"
        PreparingSessions = "正在整理会话"
        CreatingRollbackBackup = "正在创建回滚备份"
        CreatingProjectFolders = "正在创建项目占位文件夹"
        RestoringFiles = "正在恢复会话"
        MergingIndexes = "正在更新会话索引"
        PreparingProviderUpdate = "正在准备 Provider 更新"
        UpdatingProviders = "正在更新 Provider"
        PreparingDelete = "正在准备删除"
        RemovingSessions = "正在删除会话"
        Complete = "操作完成"
        browseCodex = "选择 Codex 数据目录"
        browseSaveZip = "保存 Codex 历史备份"
        browseOpenZip = "选择 Codex 历史备份"
        browseProjectRoot = "选择用于创建占位项目的根目录"
        zipFilter = "ZIP 归档 (*.zip)|*.zip"
        missingPath = "缺少路径"
        invalidPath = "路径无效"
        chooseZip = "请选择 ZIP 文件。"
        zipExtension = "文件必须使用 .zip 扩展名。"
        chooseCodex = "请选择 Codex 数据目录。"
        codexMissing = "Codex 数据目录不存在。"
        zipMissing = "ZIP 文件不存在。"
        chooseProjectRoot = "请选择项目根目录。"
        projectRootMissing = "项目根目录不存在。请先选择一个已有文件夹。"
        overwriteTitle = "确认覆盖"
        overwriteZip = "目标 ZIP 已存在，是否覆盖？"
        confirmRestore = "确认恢复"
        confirmProviderUpdate = "确认更新 Provider"
        confirmDelete = "确认删除会话"
        restoreMerge = "将恢复 {0}。本机已有会话默认保留。{1}"
        restoreOverwrite = "将恢复 {0}，并使用备份覆盖本机桌面状态。{1}`r`n工具会先创建回滚 ZIP。"
        providerAuto = "迁入会话将自动适配本机 Provider。"
        providerNamed = "迁入会话将改为 Provider '{0}'。"
        providerKeep = "迁入会话将保留原 Provider。"
        projectPlaceholders = "缺失的项目目录将在 {0} 下创建为空文件夹。不会恢复项目文件或 Git 历史。"
        projectPathsKeep = "缺失的项目目录将保留原路径，不创建本机文件夹。"
        providerUpdateMessage = "将把选中的 {0} 个会话设置为 Provider '{1}'。`r`n工具会先创建完整回滚 ZIP。"
        deleteMessage = "将从本机删除选中的 {0} 个会话、标题和桌面线程索引。`r`n工具会先创建完整回滚 ZIP，但删除操作本身不可直接撤销。"
        continueQuestion = "是否继续？"
        operationRunning = "操作仍在进行，完成后才能关闭窗口。"
        sessionPickerTitle = "选择会话"
        search = "搜索"
        selectAll = "全选"
        clearAll = "清空"
        selectedCount = "已选择 {0} / {1}"
        titleColumn = "标题"
        updatedColumn = "更新时间"
        typeColumn = "类型"
        providerColumn = "Provider"
        activeType = "活动"
        archivedType = "归档"
        confirm = "确定"
        cancel = "取消"
        noSessions = "没有找到可迁移的会话。"
        selectAtLeastOne = "请至少选择一个会话。"
        chooseManageSessions = "请先明确选择要管理的会话。"
        enterProvider = "请输入目标 Provider。"
        loadSessionsFailed = "读取会话失败"
        partialOverwriteTip = "选择部分会话时不能覆盖完整的本机桌面状态。"
        stateTip = "用备份中的桌面状态数据库替换本机对应文件，可能改变本机界面状态和会话索引。"
        providerTip = "只调整迁入会话，不修改本机原有会话。留空时读取本机 config.toml。"
        projectPlaceholderTip = "只创建空文件夹并重连会话路径，不会恢复项目文件、Git 历史或未提交改动。"
        historyOnlyTip = "不备份桌面状态数据库；恢复后的桌面可见性可能受影响。"
        partialArtifactsTip = "部分会话备份不会包含无法可靠归属到单个会话的生成文件。"
        allSessionsPhrase = "全部会话"
        selectedPhrase = "选中的 {0} 个会话"
    }
    en = @{
        appTitle = "Codex Session Manager"
        export = "Export"
        import = "Restore"
        manage = "Manage"
        exportTitle = "Export session backup"
        importTitle = "Restore session backup"
        manageTitle = "Manage local sessions"
        chinese = "中"
        english = "EN"
        exportSource = "Codex data folder"
        importSource = "Backup ZIP"
        exportDestination = "Backup ZIP destination"
        importDestination = "Codex data folder"
        manageSource = "Codex data folder"
        managementAction = "Management action"
        setProvider = "Set Provider"
        deleteSessions = "Delete sessions"
        sessions = "Sessions"
        selectedSessions = "{0} of {1} sessions selected"
        sessionsNotLoaded = "All sessions (select if needed)"
        manageSessionsNotSelected = "No sessions selected (management requires an explicit selection)"
        chooseSessions = "Choose sessions"
        advanced = "Advanced options"
        details = "Details"
        historyOnly = "Back up chat history only"
        includeArtifacts = "Include generated images and visualizations"
        overwriteState = "Overwrite local desktop state with backup"
        rewriteProvider = "Adapt sessions to this computer's Provider"
        targetProvider = "Target Provider"
        createProjectPlaceholders = "Create placeholder folders for missing projects"
        projectRoot = "Project root"
        createBackup = "Create backup"
        restoreSessions = "Restore sessions"
        updateProvider = "Update Provider"
        removeSessions = "Delete sessions"
        safety = "Close Codex / ChatGPT completely before running"
        readyExport = "Ready to export"
        readyImport = "Ready to restore"
        readyManage = "Choose sessions and a management action"
        loadingSessions = "Loading sessions..."
        starting = "Starting..."
        completed = "Completed"
        failed = "Failed"
        startFailed = "Could not start"
        PreparingExport = "Preparing backup"
        ScanningSessions = "Scanning sessions"
        CreatingManifest = "Creating manifest"
        CompressingArchive = "Compressing backup"
        PreparingRestore = "Preparing restore"
        ValidatingArchive = "Validating backup"
        PreparingSessions = "Preparing sessions"
        CreatingRollbackBackup = "Creating rollback backup"
        CreatingProjectFolders = "Creating project placeholders"
        RestoringFiles = "Restoring sessions"
        MergingIndexes = "Updating session indexes"
        PreparingProviderUpdate = "Preparing Provider update"
        UpdatingProviders = "Updating Provider"
        PreparingDelete = "Preparing deletion"
        RemovingSessions = "Deleting sessions"
        Complete = "Completed"
        browseCodex = "Choose Codex data folder"
        browseSaveZip = "Save Codex history backup"
        browseOpenZip = "Choose Codex history backup"
        browseProjectRoot = "Choose the root folder for placeholder projects"
        zipFilter = "ZIP archives (*.zip)|*.zip"
        missingPath = "Missing path"
        invalidPath = "Invalid path"
        chooseZip = "Choose a ZIP file."
        zipExtension = "The file must use the .zip extension."
        chooseCodex = "Choose a Codex data folder."
        codexMissing = "The Codex data folder does not exist."
        zipMissing = "The ZIP file does not exist."
        chooseProjectRoot = "Choose a project root folder."
        projectRootMissing = "The project root does not exist. Choose an existing folder."
        overwriteTitle = "Confirm overwrite"
        overwriteZip = "The destination ZIP already exists. Overwrite it?"
        confirmRestore = "Confirm restore"
        confirmProviderUpdate = "Confirm Provider update"
        confirmDelete = "Confirm session deletion"
        restoreMerge = "Restore {0}. Existing local sessions will be kept. {1}"
        restoreOverwrite = "Restore {0} and overwrite local desktop state with the backup. {1}`r`nA rollback ZIP will be created first."
        providerAuto = "Imported sessions will use this computer's configured Provider."
        providerNamed = "Imported sessions will use Provider '{0}'."
        providerKeep = "Imported sessions will keep their original Provider."
        projectPlaceholders = "Missing project folders will be created as empty folders under '{0}'. Project files and Git history are not restored."
        projectPathsKeep = "Missing project folders will keep their original paths; no local folders will be created."
        providerUpdateMessage = "Set the selected {0} sessions to Provider '{1}'.`r`nA complete rollback ZIP will be created first."
        deleteMessage = "Delete the selected {0} sessions, titles, and desktop thread indexes from this computer.`r`nA complete rollback ZIP will be created first, but the deletion itself cannot be directly undone."
        continueQuestion = "Continue?"
        operationRunning = "The operation is still running. Wait for it to finish before closing."
        sessionPickerTitle = "Choose sessions"
        search = "Search"
        selectAll = "Select all"
        clearAll = "Clear"
        selectedCount = "{0} of {1} selected"
        titleColumn = "Title"
        updatedColumn = "Updated"
        typeColumn = "Type"
        providerColumn = "Provider"
        activeType = "Active"
        archivedType = "Archived"
        confirm = "OK"
        cancel = "Cancel"
        noSessions = "No migratable sessions were found."
        selectAtLeastOne = "Select at least one session."
        chooseManageSessions = "Choose the sessions to manage first."
        enterProvider = "Enter a target Provider."
        loadSessionsFailed = "Could not load sessions"
        partialOverwriteTip = "A partial session restore cannot overwrite the complete local desktop state."
        stateTip = "Replaces matching local desktop-state files with the backup and may change UI state and session indexes."
        providerTip = "Only affects imported sessions. Leave blank to read this computer's config.toml."
        projectPlaceholderTip = "Creates empty folders and reconnects session paths only. Project files, Git history, and uncommitted changes are not restored."
        historyOnlyTip = "Excludes desktop-state databases; restored sessions may not appear in every Desktop version."
        partialArtifactsTip = "Partial backups exclude generated files that cannot be reliably assigned to one session."
        allSessionsPhrase = "all sessions"
        selectedPhrase = "the selected {0} sessions"
    }
}

if (-not (Test-Path -LiteralPath $script:ThemePath -PathType Leaf)) {
    throw "Missing UI theme: $script:ThemePath"
}
$script:Theme = Import-PowerShellDataFile -LiteralPath $script:ThemePath
$script:Palette = @{}
foreach ($entry in $script:Theme.Colors.GetEnumerator()) {
    $channels = [int[]]$entry.Value
    $script:Palette[$entry.Key] = [System.Drawing.Color]::FromArgb($channels[0], $channels[1], $channels[2])
}
$script:Palette["Background"] = $script:Palette.Canvas
$script:Metrics = $script:Theme.Metrics

$installedFontNames = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
function Resolve-FontFamily {
    param([string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if ($installedFontNames -contains $candidate) { return $candidate }
    }
    return "Microsoft Sans Serif"
}

$script:UiFontFamily = Resolve-FontFamily ([string[]]$script:Theme.Fonts.UI)
$script:IconFontFamily = Resolve-FontFamily ([string[]]$script:Theme.Fonts.Icon)
$script:MonoFontFamily = Resolve-FontFamily ([string[]]$script:Theme.Fonts.Monospace)
$script:NavigationFont = [System.Drawing.Font]::new($script:UiFontFamily, 9.5)
$script:NavigationActiveFont = [System.Drawing.Font]::new($script:UiFontFamily, 9.5, [System.Drawing.FontStyle]::Bold)

$script:Strings["zh"]["compactTitle"] = "压缩上下文…"
$script:Strings["en"]["compactTitle"] = "Compress context…"
$script:Strings["zh"]["compactSelectOne"] = "请明确选择且仅选择一个会话。"
$script:Strings["en"]["compactSelectOne"] = "Explicitly select exactly one conversation."
$script:Strings["zh"]["compactIntro"] = "关闭 Codex 后操作。先离线预览，再发送旧上下文生成有损摘要。完整历史将备份，原始记录保留；不会自动更改 Provider。"
$script:Strings["en"]["compactIntro"] = "Close Codex first. Preview offline, then send older context for a lossy summary. Full history is backed up and the original records are preserved. Provider is not changed automatically."
$script:Strings["zh"]["compactDetecting"] = "正在检测 Python 3.9+…"
$script:Strings["en"]["compactDetecting"] = "Detecting Python 3.9+…"
$script:Strings["zh"]["compactNoPython"] = "需要 Python 3.9+（py -3、python3 或 python）。安装后重新打开窗口。"
$script:Strings["en"]["compactNoPython"] = "Python 3.9+ required (py -3, python3 or python). Install it, then reopen this dialog."
$script:Strings["zh"]["compactBase"] = "API 基础地址（HTTPS）"
$script:Strings["en"]["compactBase"] = "API base URL (HTTPS)"
$script:Strings["zh"]["compactModel"] = "摘要模型名称"
$script:Strings["en"]["compactModel"] = "Summary model name"
$script:Strings["zh"]["compactEnv"] = "API 密钥环境变量名（非密钥）"
$script:Strings["en"]["compactEnv"] = "API key variable NAME (not the key)"
$script:Strings["zh"]["compactBudget"] = "目标上下文预算（估算 token）"
$script:Strings["en"]["compactBudget"] = "Context budget (estimated tokens)"
$script:Strings["zh"]["compactRecent"] = "保留最近的用户轮次"
$script:Strings["en"]["compactRecent"] = "Recent user turns to retain"
$script:Strings["zh"]["compactPreview"] = "离线预览"
$script:Strings["en"]["compactPreview"] = "Preview offline"
$script:Strings["zh"]["compactRun"] = "确认并压缩…"
$script:Strings["en"]["compactRun"] = "Confirm and compress…"
$script:Strings["zh"]["compactNeedsPreview"] = "设置已变更，请重新离线预览。"
$script:Strings["en"]["compactNeedsPreview"] = "Settings changed. Run an offline preview again."
$script:Strings["zh"]["compactNumbers"] = "预算须为 4096–2000000 的整数，最近轮次须为 0–100 的整数。"
$script:Strings["en"]["compactNumbers"] = "Budget must be 4096–2000000; recent turns must be 0–100 (integers)."
$script:Strings["zh"]["compactMissing"] = "缺少 codex_history_compact.py。"
$script:Strings["en"]["compactMissing"] = "Missing codex_history_compact.py."
$script:Strings["zh"]["compactUrl"] = "请输入不含凭据、查询或片段的 HTTPS API 基础地址。"
$script:Strings["en"]["compactUrl"] = "Enter an HTTPS API base URL without credentials, query or fragment."
$script:Strings["zh"]["compactCredentials"] = "请填写模型及有效的环境变量名。不要粘贴密钥。"
$script:Strings["en"]["compactCredentials"] = "Enter a model and a valid environment variable name. Do not paste a key."
$script:Strings["zh"]["compactConfirm"] = "旧会话文本将发送到：{0}`n模型：{1}`n`n摘要是有损的，可能遗漏细节。完整历史将备份，原始记录保留，并在同一会话追加压缩检查点。备份包含敏感内容且未加密。不会自动更改 Provider。`n`n是否继续？"
$script:Strings["en"]["compactConfirm"] = "Older conversation text will be sent to: {0}`nModel: {1}`n`nThe summary is lossy and may omit details. Full history will be backed up, original records preserved, and a compacted checkpoint appended to the same conversation. Backups contain sensitive text and are not encrypted. Provider will not change automatically.`n`nContinue?"
$script:Strings["zh"]["compactWorking"] = "处理中，请等待。网络摘要可能需要几分钟。"
$script:Strings["en"]["compactWorking"] = "Working. Network summarization may take several minutes."
$script:Strings["zh"]["compactWait"] = "操作进行中。请等待完成后关闭，避免中断备份或写入。"
$script:Strings["en"]["compactWait"] = "Operation in progress. Wait for completion before closing to avoid interrupting backup or writes."
$script:Strings["zh"]["compactExitError"] = "压缩助手退出，代码 {0}。"
$script:Strings["en"]["compactExitError"] = "Compaction helper exited with code {0}."
$script:Strings["zh"]["compactInvalidResult"] = "压缩助手未返回有效结果。"
$script:Strings["en"]["compactInvalidResult"] = "Compaction helper did not return a valid result."
$script:Strings["zh"]["compactDone"] = "上下文已压缩。请重新选择该会话，再使用现有的设置 Provider 操作。"
$script:Strings["en"]["compactDone"] = "Context compressed. Select this conversation again, then use the existing Set Provider action."

function T {
    param([Parameter(Mandatory = $true)][string]$Key)
    if ($script:Strings[$script:Language].ContainsKey($Key)) { return [string]$script:Strings[$script:Language][$Key] }
    return $Key
}

function Format-T {
    param([string]$Key, [object[]]$Values)
    return [string]::Format((T $Key), $Values)
}

function Get-DefaultCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { return [System.IO.Path]::GetFullPath($env:CODEX_HOME) }
    return [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex"))
}

function ConvertTo-QuotedProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = [System.Text.StringBuilder]::new()
    $builder.Append('"') | Out-Null
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            $builder.Append(('\' * ($slashes * 2 + 1))).Append('"') | Out-Null
        }
        else {
            if ($slashes -gt 0) { $builder.Append(('\' * $slashes)) | Out-Null }
            $builder.Append($character) | Out-Null
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { $builder.Append(('\' * ($slashes * 2))) | Out-Null }
    $builder.Append('"') | Out-Null
    return $builder.ToString()
}

function New-UiLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 24)
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($Width, $Height)
    $label.ForeColor = $script:Palette.Text
    $label.TextAlign = "MiddleLeft"
    return $label
}

function New-RoundedRectanglePath {
    param([System.Drawing.Rectangle]$Rectangle, [int]$Radius)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = [Math]::Max(1, $Radius * 2)
    $right = $Rectangle.Right - $diameter
    $bottom = $Rectangle.Bottom - $diameter
    $path.AddArc($Rectangle.Left, $Rectangle.Top, $diameter, $diameter, 180, 90)
    $path.AddArc($right, $Rectangle.Top, $diameter, $diameter, 270, 90)
    $path.AddArc($right, $bottom, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.Left, $bottom, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedRegion {
    param([System.Windows.Forms.Control]$Control, [int]$Radius)
    if ($Control.Width -lt 2 -or $Control.Height -lt 2) { return }
    $effectiveRadius = [Math]::Max(1, [Math]::Min($Radius, [int]([Math]::Floor([Math]::Min($Control.Width, $Control.Height) / 2))))
    $path = New-RoundedRectanglePath ([System.Drawing.Rectangle]::new(0, 0, $Control.Width, $Control.Height)) $effectiveRadius
    $region = [System.Drawing.Region]::new($path)
    $previousRegion = $Control.Region
    $Control.Region = $region
    if ($null -ne $previousRegion) { $previousRegion.Dispose() }
    $path.Dispose()
}

function Enable-RoundedCorners {
    param([System.Windows.Forms.Control]$Control, [int]$Radius)
    $target = $Control
    $cornerRadius = $Radius
    $Control.Add_Resize(({ Set-RoundedRegion $target $cornerRadius }).GetNewClosure())
    Set-RoundedRegion $Control $Radius
}

function New-InputFrame {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height = 38)
    $frame = [System.Windows.Forms.Panel]::new()
    $frame.Location = [System.Drawing.Point]::new($X, $Y)
    $frame.Size = [System.Drawing.Size]::new($Width, $Height)
    $frame.BackColor = $script:Palette.Field
    $frame.Tag = $false
    Enable-RoundedCorners $frame ([int]$script:Metrics.RadiusMedium)
    $target = $frame
    $focusBorderColor = $script:Palette.Accent
    $restingBorderColor = $script:Palette.Border
    $frameRadius = [int]$script:Metrics.RadiusMedium
    $frame.Add_Paint(({
        $graphics = $_.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $rectangle = [System.Drawing.Rectangle]::new(0, 0, $target.Width - 1, $target.Height - 1)
        $path = New-RoundedRectanglePath $rectangle $frameRadius
        $borderColor = if ([bool]$target.Tag) { $focusBorderColor } else { $restingBorderColor }
        $borderWidth = if ([bool]$target.Tag) { 2 } else { 1 }
        $pen = [System.Drawing.Pen]::new($borderColor, $borderWidth)
        $graphics.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
    }).GetNewClosure())
    return $frame
}

function Connect-InputFrame {
    param([System.Windows.Forms.Panel]$Frame, [System.Windows.Forms.TextBox]$TextBox)
    $target = $Frame
    $TextBox.Add_Enter(({ $target.Tag = $true; $target.Invalidate() }).GetNewClosure())
    $TextBox.Add_Leave(({ $target.Tag = $false; $target.Invalidate() }).GetNewClosure())
}

function Set-ProgressValue {
    param([int]$Value)
    $script:ProgressValue = [Math]::Max(0, [Math]::Min(100, $Value))
    if ($null -eq $script:ProgressFill -or $null -eq $script:ProgressTrack) { return }
    $script:ProgressFill.Width = [int][Math]::Round($script:ProgressTrack.ClientSize.Width * ($script:ProgressValue / 100.0))
    $script:ProgressFill.Visible = $script:ProgressValue -gt 0
    if ($script:ProgressFill.Width -gt 0) { Set-RoundedRegion $script:ProgressFill ([int]$script:Metrics.RadiusSmall) }
}

function New-SegmentButton {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height = 36)
    $button = [System.Windows.Forms.Button]::new()
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Width, $Height)
    $button.FlatStyle = "Flat"
    $button.FlatAppearance.BorderSize = 1
    $button.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25)
    $button.Cursor = "Hand"
    $button.UseVisualStyleBackColor = $false
    Enable-RoundedCorners $button ([int]$script:Metrics.RadiusMedium)
    return $button
}

function Set-SegmentState {
    param([System.Windows.Forms.Button]$Button, [bool]$Active, [bool]$Danger = $false)
    $accent = if ($Danger) { $script:Palette.Danger } else { $script:Palette.Accent }
    if ($Active) {
        $Button.BackColor = $accent
        $Button.ForeColor = [System.Drawing.Color]::White
        $Button.FlatAppearance.BorderColor = $accent
        $Button.FlatAppearance.MouseOverBackColor = $(if ($Danger) { $script:Palette.DangerHover } else { $script:Palette.AccentHover })
        $Button.FlatAppearance.MouseDownBackColor = $(if ($Danger) { $script:Palette.DangerHover } else { $script:Palette.AccentPressed })
    }
    else {
        $Button.BackColor = $(if ($Danger) { $script:Palette.DangerSoft } else { $script:Palette.Background })
        $Button.ForeColor = $(if ($Danger) { $script:Palette.Danger } else { $script:Palette.Text })
        $Button.FlatAppearance.BorderColor = $(if ($Danger) { [System.Drawing.Color]::FromArgb(225, 178, 178) } else { $script:Palette.Border })
        $Button.FlatAppearance.MouseOverBackColor = $(if ($Danger) { [System.Drawing.Color]::FromArgb(248, 224, 224) } else { $script:Palette.Surface })
        $Button.FlatAppearance.MouseDownBackColor = $(if ($Danger) { [System.Drawing.Color]::FromArgb(244, 212, 209) } else { $script:Palette.AccentSoft })
    }
}

function New-NavigationButton {
    param([int]$Y)
    $button = [System.Windows.Forms.Button]::new()
    $button.Location = [System.Drawing.Point]::new(20, $Y)
    $button.Size = [System.Drawing.Size]::new(176, ([int]$script:Metrics.NavigationHeight))
    $button.FlatStyle = "Flat"
    $button.FlatAppearance.BorderSize = 0
    $button.TextAlign = "MiddleLeft"
    $button.Padding = [System.Windows.Forms.Padding]::new(46, 0, 0, 0)
    $button.Cursor = "Hand"
    $button.UseVisualStyleBackColor = $false
    Enable-RoundedCorners $button ([int]$script:Metrics.RadiusMedium)
    return $button
}

function Add-NavigationIcon {
    param([System.Windows.Forms.Button]$Button, [string]$Glyph)
    $icon = [System.Windows.Forms.Label]::new()
    $icon.Text = $Glyph
    $icon.Location = [System.Drawing.Point]::new(14, 11)
    $icon.Size = [System.Drawing.Size]::new(24, 24)
    $icon.Font = [System.Drawing.Font]::new($script:IconFontFamily, 11)
    $icon.TextAlign = "MiddleCenter"
    $icon.BackColor = [System.Drawing.Color]::Transparent
    $icon.Enabled = $false
    $Button.Controls.Add($icon)
    return $icon
}

function Set-NavigationState {
    param([System.Windows.Forms.Button]$Button, [bool]$Active)
    if ($Active) {
        $Button.BackColor = $script:Palette.SidebarActive
        $Button.ForeColor = $script:Palette.SidebarText
        $Button.Font = $script:NavigationActiveFont
        $Button.FlatAppearance.MouseOverBackColor = $script:Palette.SidebarActive
        $Button.FlatAppearance.MouseDownBackColor = $script:Palette.SidebarActive
    }
    else {
        $Button.BackColor = $script:Palette.Sidebar
        $Button.ForeColor = $script:Palette.SidebarMuted
        $Button.Font = $script:NavigationFont
        $Button.FlatAppearance.MouseOverBackColor = $script:Palette.SidebarHover
        $Button.FlatAppearance.MouseDownBackColor = $script:Palette.SidebarActive
    }
    foreach ($child in $Button.Controls) {
        if ($child -is [System.Windows.Forms.Label]) { $child.ForeColor = $Button.ForeColor }
    }
}

function Write-UiLog {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $script:LogTextBox.AppendText($Text.TrimEnd([char[]]@([char]13, [char]10)) + [Environment]::NewLine)
    $script:LogTextBox.SelectionStart = $script:LogTextBox.TextLength
    $script:LogTextBox.ScrollToCaret()
}

function Update-SessionSummary {
    if ($script:AvailableSessions.Count -eq 0) {
        $script:SessionSummaryLabel.Text = T $(if ($script:SelectedMode -eq "Manage") { "manageSessionsNotSelected" } else { "sessionsNotLoaded" })
    }
    elseif ($null -eq $script:SelectedSessionIds) {
        $script:SessionSummaryLabel.Text = Format-T "selectedSessions" @($script:AvailableSessions.Count, $script:AvailableSessions.Count)
    }
    else {
        $script:SessionSummaryLabel.Text = Format-T "selectedSessions" @($script:SelectedSessionIds.Count, $script:AvailableSessions.Count)
    }
    $partial = $null -ne $script:SelectedSessionIds -or ($script:SelectedMode -eq "Import" -and $script:ArchiveIsPartial)
    if ($partial) { $script:RestoreAppStateCheckBox.Checked = $false }
    $script:RestoreAppStateCheckBox.Enabled = -not $partial -and $null -eq $script:ActiveProcess
    $script:ToolTip.SetToolTip($script:RestoreAppStateCheckBox, $(if ($partial) { T "partialOverwriteTip" } else { T "stateTip" }))
}

function Reset-SessionSelection {
    if ($script:SuppressSelectionReset) { return }
    $script:AvailableSessions = @()
    $script:SelectedSessionIds = $null
    $script:ArchiveIsPartial = $false
    Update-SessionSummary
}

function Save-ModeValues {
    $script:ModeValues[$script:SelectedMode].Source = $script:SourceTextBox.Text
    $script:ModeValues[$script:SelectedMode].Destination = $script:DestinationTextBox.Text
}

function Update-Layout {
    $isManage = $script:SelectedMode -eq "Manage"
    $advancedHeight = if ($script:SelectedMode -eq "Import") { 178 } else { 104 }
    $script:AdvancedPanel.Height = $advancedHeight
    $script:BodyPanel.AutoScrollMinSize = [System.Drawing.Size]::new(0, $(if (-not $isManage -and $script:AdvancedExpanded) { 336 + $advancedHeight } else { 430 }))
    $script:AdvancedButton.Visible = -not $isManage
    $script:AdvancedPanel.Visible = -not $isManage -and $script:AdvancedExpanded
    $script:ManagementActionLabel.Visible = $isManage
    $script:SetProviderActionButton.Visible = $isManage
    $script:DeleteActionButton.Visible = $isManage
    $script:CompactButton.Visible = $isManage -and $script:SelectedManagementAction -eq "SetProvider"
    $script:DestinationLabel.Location = [System.Drawing.Point]::new(36, $(if ($isManage) { 300 } else { 204 }))
    $script:DestinationInputFrame.Location = [System.Drawing.Point]::new(36, $(if ($isManage) { 328 } else { 232 }))
    $script:DestinationLabel.Visible = -not $isManage -or $script:SelectedManagementAction -eq "SetProvider"
    $script:DestinationInputFrame.Visible = -not $isManage -or $script:SelectedManagementAction -eq "SetProvider"
    $script:DestinationBrowseButton.Visible = -not $isManage
    $script:FooterPanel.Height = if ($script:DetailsExpanded) { 326 } else { 154 }
    $script:LogPanel.Visible = $script:DetailsExpanded
    $script:AdvancedButton.Text = $(if ($script:AdvancedExpanded) { "⌄  " } else { "›  " }) + (T "advanced")
    $script:DetailsButton.Text = $(if ($script:DetailsExpanded) { "⌄  " } else { "›  " }) + (T "details")
    $script:ExportIndicator.Visible = $script:SelectedMode -eq "Export"
    $script:ImportIndicator.Visible = $script:SelectedMode -eq "Import"
    $script:ManageIndicator.Visible = $script:SelectedMode -eq "Manage"
}

function Update-Language {
    $script:MainForm.Text = T "appTitle"
    $script:TitleLabel.Text = T "appTitle"
    $script:TaskTitleLabel.Text = T $(switch ($script:SelectedMode) { "Export" { "exportTitle" }; "Import" { "importTitle" }; default { "manageTitle" } })
    $script:ExportModeButton.Text = T "export"
    $script:ImportModeButton.Text = T "import"
    $script:ManageModeButton.Text = T "manage"
    $script:ChineseButton.Text = T "chinese"
    $script:EnglishButton.Text = T "english"
    $script:SourceLabel.Text = T $(switch ($script:SelectedMode) { "Export" { "exportSource" }; "Import" { "importSource" }; default { "manageSource" } })
    $script:DestinationLabel.Text = T $(switch ($script:SelectedMode) { "Export" { "exportDestination" }; "Import" { "importDestination" }; default { "targetProvider" } })
    $script:ManagementActionLabel.Text = T "managementAction"
    $script:SetProviderActionButton.Text = T "setProvider"
    $script:DeleteActionButton.Text = T "deleteSessions"
    $script:CompactButton.Text = T "compactTitle"
    $script:SessionsLabel.Text = T "sessions"
    $script:ChooseSessionsButton.Text = T "chooseSessions"
    $script:HistoryOnlyCheckBox.Text = T "historyOnly"
    $script:IncludeArtifactsCheckBox.Text = T "includeArtifacts"
    $script:RestoreAppStateCheckBox.Text = T "overwriteState"
    $script:RewriteProviderCheckBox.Text = T "rewriteProvider"
    $script:TargetProviderLabel.Text = T "targetProvider"
    $script:CreateProjectPlaceholdersCheckBox.Text = T "createProjectPlaceholders"
    $script:ProjectRootLabel.Text = T "projectRoot"
    $runTextKey = switch ($script:SelectedMode) {
        "Export" { "createBackup" }
        "Import" { "restoreSessions" }
        default { if ($script:SelectedManagementAction -eq "Delete") { "removeSessions" } else { "updateProvider" } }
    }
    $script:RunButton.Text = T $runTextKey
    $script:RunButton.BackColor = if ($script:SelectedMode -eq "Manage" -and $script:SelectedManagementAction -eq "Delete") {
        $script:Palette.Danger
    }
    else { $script:Palette.Accent }
    $script:RunButton.FlatAppearance.MouseOverBackColor = if ($script:SelectedMode -eq "Manage" -and $script:SelectedManagementAction -eq "Delete") {
        $script:Palette.DangerHover
    }
    else { $script:Palette.AccentHover }
    $script:SafetyLabel.Text = T "safety"
    if ($null -eq $script:ActiveProcess) {
        $script:StatusLabel.Text = T $script:CurrentStatusKey
        $script:StatusLabel.ForeColor = $script:Palette.Text
    }
    Set-SegmentState $script:ChineseButton ($script:Language -eq "zh")
    Set-SegmentState $script:EnglishButton ($script:Language -eq "en")
    $script:ToolTip.SetToolTip($script:SourceBrowseButton, (T $(if ($script:SelectedMode -eq "Import") { "browseOpenZip" } else { "browseCodex" })))
    $script:ToolTip.SetToolTip($script:DestinationBrowseButton, (T $(if ($script:SelectedMode -eq "Export") { "browseSaveZip" } else { "browseCodex" })))
    $script:ToolTip.SetToolTip($script:HistoryOnlyCheckBox, (T "historyOnlyTip"))
    $script:ToolTip.SetToolTip($script:IncludeArtifactsCheckBox, (T "partialArtifactsTip"))
    $script:ToolTip.SetToolTip($script:RewriteProviderCheckBox, (T "providerTip"))
    $script:ToolTip.SetToolTip($script:TargetProviderTextBox, (T "providerTip"))
    $script:ToolTip.SetToolTip($script:CreateProjectPlaceholdersCheckBox, (T "projectPlaceholderTip"))
    $script:ToolTip.SetToolTip($script:ProjectRootTextBox, (T "projectPlaceholderTip"))
    $script:ToolTip.SetToolTip($script:ProjectRootBrowseButton, (T "browseProjectRoot"))
    Update-SessionSummary
    Update-Layout
}

function Set-SelectedMode {
    param([ValidateSet("Export", "Import", "Manage")][string]$Mode)
    if ($script:SelectedMode -ne $Mode) { Save-ModeValues }
    $script:SelectedMode = $Mode
    $script:SuppressSelectionReset = $true
    $script:SourceTextBox.Text = [string]$script:ModeValues[$Mode].Source
    if ($Mode -eq "Manage") { $script:DestinationTextBox.Clear() }
    else { $script:DestinationTextBox.Text = [string]$script:ModeValues[$Mode].Destination }
    $script:SuppressSelectionReset = $false
    $script:AvailableSessions = @()
    $script:SelectedSessionIds = $null
    $script:ArchiveIsPartial = $false
    $script:CurrentStatusKey = switch ($Mode) { "Export" { "readyExport" }; "Import" { "readyImport" }; default { "readyManage" } }
    $script:ExportOptionsPanel.Visible = $Mode -eq "Export"
    $script:ImportOptionsPanel.Visible = $Mode -eq "Import"
    Set-NavigationState $script:ExportModeButton ($Mode -eq "Export")
    Set-NavigationState $script:ImportModeButton ($Mode -eq "Import")
    Set-NavigationState $script:ManageModeButton ($Mode -eq "Manage")
    $script:BodyPanel.AutoScrollPosition = [System.Drawing.Point]::new(0, 0)
    Set-ProgressValue 0
    $script:PercentLabel.Text = "0%"
    Update-Language
}

function Set-ManagementAction {
    param([ValidateSet("SetProvider", "Delete")][string]$Action)

    $script:SelectedManagementAction = $Action
    Set-SegmentState $script:SetProviderActionButton ($Action -eq "SetProvider")
    Set-SegmentState $script:DeleteActionButton ($Action -eq "Delete") $true
    Update-Language
}

function Show-Message {
    param([string]$Message, [string]$TitleKey, [System.Windows.Forms.MessageBoxIcon]$Icon = "Warning")
    [System.Windows.Forms.MessageBox]::Show($script:MainForm, $Message, (T $TitleKey), "OK", $Icon) | Out-Null
}

function Invoke-SessionList {
    $source = $script:SourceTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($source)) {
        Show-Message (T $(if ($script:SelectedMode -eq "Import") { "chooseZip" } else { "chooseCodex" })) "missingPath"
        return $null
    }
    if ($script:SelectedMode -ne "Import" -and -not (Test-Path -LiteralPath $source -PathType Container)) {
        Show-Message (T "codexMissing") "invalidPath"
        return $null
    }
    if ($script:SelectedMode -eq "Import" -and -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Show-Message (T "zipMissing") "invalidPath"
        return $null
    }

    $script:StatusLabel.Text = T "loadingSessions"
    $script:MainForm.UseWaitCursor = $true
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:CoreScriptPath, "-Mode", "List")
        if ($script:SelectedMode -ne "Import") { $arguments += @("-CodexHome", $source) }
        else { $arguments += @("-ArchivePath", $source) }
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = ($arguments | ForEach-Object { ConvertTo-QuotedProcessArgument $_ }) -join " "
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $output = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $process.Dispose()
        if ($exitCode -ne 0) { throw $errorText.Trim() }
        $sessions = @()
        $script:ArchiveIsPartial = $false
        foreach ($line in $output -split "`r?`n") {
            if ($line.StartsWith("catalog`t")) {
                $catalogMetadata = $line.Substring(8) | ConvertFrom-Json
                $script:ArchiveIsPartial = [bool]$catalogMetadata.isPartialHistory
            }
            if ($line.StartsWith("session`t")) { $sessions += ($line.Substring(8) | ConvertFrom-Json) }
        }
        return @($sessions)
    }
    catch {
        Show-Message $_.Exception.Message "loadSessionsFailed" "Error"
        return $null
    }
    finally {
        $script:MainForm.UseWaitCursor = $false
        $script:StatusLabel.Text = T $script:CurrentStatusKey
    }
}

# The dialog owns its child process and drains both pipes asynchronously. It never
# edits history itself or includes a credential value in arguments or settings.
function Show-CompactionDialog {
    if ($null -ne $script:ActiveProcess) { return }
    if ($null -eq $script:SelectedSessionIds -or @($script:SelectedSessionIds).Count -ne 1 -or [string]::IsNullOrWhiteSpace($script:SelectedSessionIds[0])) {
        Show-Message (T 'compactSelectOne') 'compactTitle' 'Information'
        return
    }
    $homePath = $script:SourceTextBox.Text.Trim()
    $sessionId = [string]$script:SelectedSessionIds[0]
    $companion = Join-Path $PSScriptRoot 'codex_history_compact.py'
    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = T 'compactTitle'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [System.Drawing.Size]::new(720, 650)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowIcon = $false
    $dialog.AutoScaleMode = 'Dpi'
    $dialog.Font = $script:MainForm.Font
    $dialog.BackColor = $script:Palette.Canvas
    $intro = New-UiLabel (T 'compactIntro') 24 16 672 72
    $runtimeLabel = New-UiLabel (T 'compactDetecting') 24 88 672 28
    $dialog.Controls.AddRange(@($intro, $runtimeLabel))
    $fields = @{}
    $row = 0
    foreach ($spec in @(
        @('base', 'compactBase', 'https://api.openai.com/v1'),
        @('model', 'compactModel', ''),
        @('env', 'compactEnv', 'OPENAI_API_KEY'),
        @('budget', 'compactBudget', '16000'),
        @('recent', 'compactRecent', '2')
    )) {
        $label = New-UiLabel (T $spec[1]) 24 (128 + $row * 40) 244 30
        $field = [System.Windows.Forms.TextBox]::new()
        $field.Location = [System.Drawing.Point]::new(272, (128 + $row * 40))
        $field.Size = [System.Drawing.Size]::new(424, 28)
        $field.BackColor = $script:Palette.Field
        $field.ForeColor = $script:Palette.Text
        $field.Text = $spec[2]
        $fields[$spec[0]] = $field
        $dialog.Controls.AddRange(@($label, $field))
        $row++
    }
    $resultBox = [System.Windows.Forms.TextBox]::new()
    $resultBox.Location = [System.Drawing.Point]::new(24, 340)
    $resultBox.Size = [System.Drawing.Size]::new(672, 236)
    $resultBox.Multiline = $true
    $resultBox.ReadOnly = $true
    $resultBox.ScrollBars = 'Vertical'
    $resultBox.BackColor = $script:Palette.Surface
    $resultBox.ForeColor = $script:Palette.Text
    $previewButton = New-SegmentButton 24 594 200 36
    $previewButton.Text = T 'compactPreview'
    $compactButton = New-SegmentButton 236 594 240 36
    $compactButton.Text = T 'compactRun'
    $closeButton = New-SegmentButton 568 594 128 36
    $closeButton.Text = T 'cancel'
    Set-SegmentState $previewButton $false
    Set-SegmentState $compactButton $true
    Set-SegmentState $closeButton $false
    $dialog.Controls.AddRange(@($resultBox, $previewButton, $compactButton, $closeButton))
    $state = @{ Process = $null; Out = $null; Err = $null; Mode = ''; Runtime = $null; Prefix = @(); Candidate = 0; Preview = $false; Completed = $false; Started = [DateTime]::UtcNow }
    $candidates = @(@('py', '-3'), @('python3'), @('python'))
    $refresh = {
        $busy = $null -ne $state.Process
        foreach ($field in $fields.Values) { $field.Enabled = -not $busy -and -not $state.Completed }
        $previewButton.Enabled = -not $busy -and $null -ne $state.Runtime -and -not $state.Completed
        $compactButton.Enabled = $previewButton.Enabled -and $state.Preview
        $closeButton.Enabled = -not $busy
    }
    $startChild = {
        param([string]$Executable, [string[]]$Arguments, [string]$Mode)
        $info = [System.Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $Executable
        $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-QuotedProcessArgument $_ }) -join ' '
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $info
        try {
            if (-not $process.Start()) { throw 'Could not start Python.' }
            $state.Process = $process
            $state.Out = $process.StandardOutput.ReadToEndAsync()
            $state.Err = $process.StandardError.ReadToEndAsync()
            $state.Mode = $Mode
            $state.Started = [DateTime]::UtcNow
            & $refresh
        }
        catch { $process.Dispose(); throw }
    }
    $detect = {
        $state.Runtime = $null
        while ($state.Candidate -lt $candidates.Count) {
            $candidate = $candidates[$state.Candidate]
            $state.Candidate++
            $command = Get-Command $candidate[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $command) { continue }
            $prefix = @($candidate | Select-Object -Skip 1)
            try {
                & $startChild $command.Source ($prefix + @('-c', 'import sys; print(sys.version.split()[0]); sys.exit(0 if sys.version_info >= (3,9) else 1)')) 'detect'
                $state.Runtime = $command.Source
                $state.Prefix = $prefix
                return
            }
            catch { $state.Runtime = $null }
        }
        $runtimeLabel.Text = T 'compactNoPython'
        & $refresh
    }
    $invalidate = { $state.Preview = $false; $resultBox.Text = T 'compactNeedsPreview'; & $refresh }
    foreach ($field in $fields.Values) { $field.Add_TextChanged($invalidate) }
    $launch = {
        param([string]$Mode)
        try {
            $budget = 0
            $recent = 0
            if (-not [int]::TryParse($fields.budget.Text, [ref]$budget) -or $budget -lt 4096 -or $budget -gt 2000000 -or
                -not [int]::TryParse($fields.recent.Text, [ref]$recent) -or $recent -lt 0 -or $recent -gt 100) { throw (T 'compactNumbers') }
            if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) { throw (T 'compactMissing') }
            $arguments = $state.Prefix + @($companion, $Mode, '--codex-home', $homePath, '--session-id', $sessionId, '--budget', [string]$budget, '--recent-turns', [string]$recent)
            if ($Mode -eq 'compact') {
                if (-not $state.Preview) { throw (T 'compactNeedsPreview') }
                $base = $fields.base.Text.Trim()
                $model = $fields.model.Text.Trim()
                $envName = $fields.env.Text.Trim()
                $uri = $null
                if (-not [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw (T 'compactUrl') }
                if ([string]::IsNullOrWhiteSpace($model) -or $envName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw (T 'compactCredentials') }
                $confirmation = (T 'compactConfirm') -f $base, $model
                if ([System.Windows.Forms.MessageBox]::Show($dialog, $confirmation, (T 'compactTitle'), 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
                $arguments += @('--base-url', $base, '--model', $model, '--api-key-env', $envName)
            }
            $state.Preview = $false
            $resultBox.Text = T 'compactWorking'
            & $startChild $state.Runtime $arguments $Mode
        }
        catch { $resultBox.Text = $_.Exception.Message; Write-UiLog $_.Exception.Message; & $refresh }
    }
    $previewButton.Add_Click({ & $launch 'preview' })
    $compactButton.Add_Click({ & $launch 'compact' })
    $closeButton.Add_Click({ $dialog.Close() })
    $dialog.Add_FormClosing({
        param($sender, $eventArgs)
        if ($null -ne $state.Process) { $eventArgs.Cancel = $true; $resultBox.Text = T 'compactWait' }
    })
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 150
    $timer.Add_Tick({
        if ($null -eq $state.Process) { return }
        if (-not $state.Process.HasExited) {
            if ($state.Mode -eq 'detect' -and ([DateTime]::UtcNow - $state.Started).TotalSeconds -gt 5) {
                try { $state.Process.Kill() } catch { }
            }
            return
        }
        if (-not $state.Out.IsCompleted -or -not $state.Err.IsCompleted) { return }
        $exitCode = $state.Process.ExitCode
        $output = $state.Out.Result
        $errorOutput = $state.Err.Result
        $state.Process.Dispose()
        $state.Process = $null
        if ($state.Mode -eq 'detect') {
            if ($exitCode -eq 0) { $runtimeLabel.Text = 'Python ' + $output.Trim(); & $refresh }
            else { & $detect }
            return
        }
        try {
            if ($exitCode -ne 0) {
                if ([string]::IsNullOrWhiteSpace($errorOutput)) { throw ((T 'compactExitError') -f $exitCode) }
                throw $errorOutput.Trim()
            }
            $result = $output | ConvertFrom-Json
            if ($null -eq $result) { throw (T 'compactInvalidResult') }
            $resultBox.Text = ($result | ConvertTo-Json -Depth 12)
            if ($state.Mode -eq 'preview') { $state.Preview = $true }
            else {
                $state.Completed = $true
                $resultBox.Text = (T 'compactDone') + "`r`n`r`n" + $resultBox.Text
                Write-UiLog (T 'compactDone')
                Reset-SessionSelection
            }
        }
        catch { $state.Preview = $false; $resultBox.Text = $_.Exception.Message; Write-UiLog $_.Exception.Message }
        & $refresh
    })
    & $refresh
    $dialog.Add_Shown({ & $detect; $timer.Start() })
    try { $dialog.ShowDialog($script:MainForm) | Out-Null }
    finally { $timer.Stop(); $timer.Dispose(); $dialog.Dispose() }
}

function Show-SessionPicker {
    $sessions = Invoke-SessionList
    if ($null -eq $sessions) { return }
    if ($sessions.Count -eq 0) { Show-Message (T "noSessions") "sessionPickerTitle" "Information"; return }
    Update-SessionSummary

    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = T "sessionPickerTitle"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = [System.Drawing.Size]::new(920, 600)
    $dialog.MinimumSize = [System.Drawing.Size]::new(880, 560)
    $dialog.Font = $script:MainForm.Font
    $dialog.BackColor = $script:Palette.Canvas
    $dialog.AutoScaleMode = "Dpi"
    $dialog.ShowIcon = $false

    $dialogHeader = [System.Windows.Forms.Panel]::new()
    $dialogHeader.Dock = "Top"
    $dialogHeader.Height = 84
    $dialogHeader.BackColor = $script:Palette.Surface
    $dialogHeaderBorder = [System.Windows.Forms.Panel]::new()
    $dialogHeaderBorder.Dock = "Bottom"
    $dialogHeaderBorder.Height = 1
    $dialogHeaderBorder.BackColor = $script:Palette.Border
    $dialogAccent = [System.Windows.Forms.Panel]::new()
    $dialogAccent.Location = [System.Drawing.Point]::new(32, 28)
    $dialogAccent.Size = [System.Drawing.Size]::new(4, 30)
    $dialogAccent.BackColor = $script:Palette.BrandWarm
    Enable-RoundedCorners $dialogAccent 2
    $dialogTitle = New-UiLabel (T "sessionPickerTitle") 52 20 500 48
    $dialogTitle.Font = [System.Drawing.Font]::new($script:UiFontFamily, 17, [System.Drawing.FontStyle]::Bold)
    $dialogHeader.Controls.AddRange(@($dialogHeaderBorder, $dialogAccent, $dialogTitle))

    $searchLabel = New-UiLabel (T "search") 32 98 100
    $searchLabel.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25, [System.Drawing.FontStyle]::Bold)
    $searchFrame = New-InputFrame 32 124 584 ([int]$script:Metrics.InputHeight)
    $searchFrame.Anchor = "Top, Left, Right"
    $searchIcon = New-UiLabel ([char]0xE721) 12 7 26 24
    $searchIcon.Font = [System.Drawing.Font]::new($script:IconFontFamily, 11)
    $searchIcon.ForeColor = $script:Palette.MutedText
    $searchIcon.BackColor = $script:Palette.Field
    $searchBox = [System.Windows.Forms.TextBox]::new()
    $searchBox.Location = [System.Drawing.Point]::new(42, 8)
    $searchBox.Size = [System.Drawing.Size]::new(526, 24)
    $searchBox.Anchor = "Top, Left, Right"
    $searchBox.BorderStyle = "None"
    $searchBox.BackColor = $script:Palette.Field
    $searchBox.ForeColor = $script:Palette.Text
    $searchBox.AccessibleName = T "search"
    Connect-InputFrame $searchFrame $searchBox
    $searchFrame.Controls.AddRange(@($searchIcon, $searchBox))

    $listFrame = New-InputFrame 32 178 856 344
    $listFrame.Anchor = "Top, Bottom, Left, Right"
    $listFrame.BackColor = $script:Palette.Surface
    $list = [System.Windows.Forms.ListView]::new()
    $list.Location = [System.Drawing.Point]::new(1, 1)
    $list.Size = [System.Drawing.Size]::new(854, 342)
    $list.Anchor = "Top, Bottom, Left, Right"
    $list.View = "Details"
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.HeaderStyle = "Nonclickable"
    $list.BorderStyle = "None"
    $list.BackColor = $script:Palette.Surface
    $list.ForeColor = $script:Palette.Text
    $list.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25)
    $list.Columns.Add((T "titleColumn"), 320) | Out-Null
    $list.Columns.Add((T "updatedColumn"), 150) | Out-Null
    $list.Columns.Add((T "providerColumn"), 210) | Out-Null
    $list.Columns.Add((T "typeColumn"), 90) | Out-Null
    $listFrame.Controls.Add($list)

    $selectedMap = @{}
    foreach ($session in $sessions) {
        $selectedMap[[string]$session.id] = if ($null -eq $script:SelectedSessionIds) {
            $script:SelectedMode -ne "Manage"
        }
        else { $script:SelectedSessionIds.Contains([string]$session.id) }
    }

    $countLabel = New-UiLabel "" 632 126 256 34
    $countLabel.Anchor = "Top, Right"
    $countLabel.TextAlign = "MiddleRight"
    $countLabel.ForeColor = $script:Palette.MutedText
    $dialogFooter = [System.Windows.Forms.Panel]::new()
    $dialogFooter.Dock = "Bottom"
    $dialogFooter.Height = 62
    $dialogFooter.BackColor = $script:Palette.Surface
    $dialogFooterBorder = [System.Windows.Forms.Panel]::new()
    $dialogFooterBorder.Dock = "Top"
    $dialogFooterBorder.Height = 1
    $dialogFooterBorder.BackColor = $script:Palette.Border
    $allButton = New-SegmentButton 32 13 96 36
    $allButton.Text = T "selectAll"
    $clearButton = New-SegmentButton 136 13 88 36
    $clearButton.Text = T "clearAll"
    $cancelButton = New-SegmentButton 678 13 98 36
    $cancelButton.Text = T "cancel"
    $cancelButton.DialogResult = "Cancel"
    $cancelButton.Anchor = "Top, Right"
    $okButton = New-SegmentButton 786 13 102 36
    $okButton.Text = T "confirm"
    $okButton.Anchor = "Top, Right"
    Set-SegmentState $allButton $false
    Set-SegmentState $clearButton $false
    Set-SegmentState $cancelButton $false
    Set-SegmentState $okButton $true
    $dialogFooter.Controls.AddRange(@($dialogFooterBorder, $allButton, $clearButton, $cancelButton, $okButton))

    $updateCount = {
        $selectedCount = @($selectedMap.Values | Where-Object { $_ }).Count
        $countLabel.Text = Format-T "selectedCount" @($selectedCount, $sessions.Count)
        $okButton.Enabled = $selectedCount -gt 0
        $okButton.BackColor = if ($okButton.Enabled) { $script:Palette.Accent } else { $script:Palette.DisabledSurface }
        $okButton.ForeColor = if ($okButton.Enabled) { [System.Drawing.Color]::White } else { $script:Palette.DisabledText }
    }
    $rebuild = {
        $filter = $searchBox.Text.Trim()
        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($session in $sessions) {
            $provider = if ($null -ne $session.PSObject.Properties["provider"]) { [string]$session.provider } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($filter) -and
                ([string]$session.title).IndexOf($filter, [System.StringComparison]::CurrentCultureIgnoreCase) -lt 0 -and
                $provider.IndexOf($filter, [System.StringComparison]::CurrentCultureIgnoreCase) -lt 0) { continue }
            $item = [System.Windows.Forms.ListViewItem]::new([string]$session.title)
            $item.Tag = [string]$session.id
            try { $updated = ([DateTime]::Parse([string]$session.updatedAt)).ToLocalTime().ToString("yyyy-MM-dd HH:mm") }
            catch { $updated = [string]$session.updatedAt }
            $item.SubItems.Add($updated) | Out-Null
            $item.SubItems.Add($provider) | Out-Null
            $item.SubItems.Add($(if ([bool]$session.archived) { T "archivedType" } else { T "activeType" })) | Out-Null
            $item.Checked = [bool]$selectedMap[[string]$session.id]
            $list.Items.Add($item) | Out-Null
        }
        $list.EndUpdate()
        & $updateCount
    }
    $list.Add_ItemChecked({
        $eventData = $_
        if ($null -ne $eventData -and $null -ne $eventData.PSObject.Properties["NewValue"]) {
            $selectedMap[[string]$eventData.Item.Tag] = ($eventData.NewValue -eq "Checked")
            & $updateCount
        }
    })
    $searchBox.Add_TextChanged({ & $rebuild })
    $allButton.Add_Click({ foreach ($id in @($selectedMap.Keys)) { $selectedMap[$id] = $true }; & $rebuild })
    $clearButton.Add_Click({ foreach ($id in @($selectedMap.Keys)) { $selectedMap[$id] = $false }; & $rebuild })
    $okButton.Add_Click({
        $chosen = @($selectedMap.Keys | Where-Object { $selectedMap[$_] })
        if ($chosen.Count -eq 0) { Show-Message (T "selectAtLeastOne") "sessionPickerTitle"; return }
        $dialog.Tag = $chosen
        $dialog.DialogResult = "OK"
        $dialog.Close()
    })

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    $dialog.Controls.AddRange(@($dialogHeader, $searchLabel, $searchFrame, $countLabel, $listFrame, $dialogFooter))
    & $rebuild
    if ($dialog.ShowDialog($script:MainForm) -eq "OK") {
        $chosen = @($dialog.Tag)
        $script:AvailableSessions = @($sessions)
        if ($chosen.Count -eq $sessions.Count -and $script:SelectedMode -ne "Manage") { $script:SelectedSessionIds = $null }
        else {
            $script:SelectedSessionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($id in $chosen) { $script:SelectedSessionIds.Add([string]$id) | Out-Null }
        }
        Update-SessionSummary
    }
    $dialog.Dispose()
}

function Test-UiInput {
    $source = $script:SourceTextBox.Text.Trim()
    $destination = $script:DestinationTextBox.Text.Trim()
    if ($script:SelectedMode -eq "Manage") {
        if ([string]::IsNullOrWhiteSpace($source)) { Show-Message (T "chooseCodex") "missingPath"; return $false }
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { Show-Message (T "codexMissing") "invalidPath"; return $false }
        if ($null -eq $script:SelectedSessionIds -or $script:SelectedSessionIds.Count -eq 0) {
            Show-Message (T "chooseManageSessions") "missingPath"
            return $false
        }
        if ($script:SelectedManagementAction -eq "SetProvider" -and [string]::IsNullOrWhiteSpace($destination)) {
            Show-Message (T "enterProvider") "missingPath"
            return $false
        }

        $message = if ($script:SelectedManagementAction -eq "Delete") {
            Format-T "deleteMessage" @($script:SelectedSessionIds.Count)
        }
        else {
            Format-T "providerUpdateMessage" @($script:SelectedSessionIds.Count, $destination)
        }
        $message += "`r`n" + (T "continueQuestion")
        $title = if ($script:SelectedManagementAction -eq "Delete") { T "confirmDelete" } else { T "confirmProviderUpdate" }
        if ([System.Windows.Forms.MessageBox]::Show($script:MainForm, $message, $title, "YesNo", "Warning") -ne "Yes") { return $false }
        return $true
    }

    $zip = if ($script:SelectedMode -eq "Export") { $destination } else { $source }
    $codexHome = if ($script:SelectedMode -eq "Export") { $source } else { $destination }
    if ([string]::IsNullOrWhiteSpace($zip)) { Show-Message (T "chooseZip") "missingPath"; return $false }
    if ([System.IO.Path]::GetExtension($zip) -ine ".zip") { Show-Message (T "zipExtension") "invalidPath"; return $false }
    if ([string]::IsNullOrWhiteSpace($codexHome)) { Show-Message (T "chooseCodex") "missingPath"; return $false }
    if ($script:SelectedMode -eq "Export" -and -not (Test-Path -LiteralPath $codexHome -PathType Container)) { Show-Message (T "codexMissing") "invalidPath"; return $false }
    if ($script:SelectedMode -eq "Import" -and -not (Test-Path -LiteralPath $zip -PathType Leaf)) { Show-Message (T "zipMissing") "invalidPath"; return $false }
    if ($script:SelectedMode -eq "Import" -and $script:CreateProjectPlaceholdersCheckBox.Checked) {
        $projectRoot = $script:ProjectRootTextBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($projectRoot)) { Show-Message (T "chooseProjectRoot") "missingPath"; return $false }
        if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) { Show-Message (T "projectRootMissing") "invalidPath"; return $false }
    }
    $script:ForceExportOverwrite = $false
    if ($script:SelectedMode -eq "Export" -and (Test-Path -LiteralPath $zip -PathType Leaf)) {
        if ([System.Windows.Forms.MessageBox]::Show($script:MainForm, (T "overwriteZip"), (T "overwriteTitle"), "YesNo", "Warning") -ne "Yes") { return $false }
        $script:ForceExportOverwrite = $true
    }
    if ($script:SelectedMode -eq "Import") {
        $scope = if ($null -eq $script:SelectedSessionIds) { T "allSessionsPhrase" } else { Format-T "selectedPhrase" @($script:SelectedSessionIds.Count) }
        $provider = if ($script:RewriteProviderCheckBox.Checked) {
            if ([string]::IsNullOrWhiteSpace($script:TargetProviderTextBox.Text)) { T "providerAuto" }
            else { Format-T "providerNamed" @($script:TargetProviderTextBox.Text.Trim()) }
        }
        else { T "providerKeep" }
        $projectHandling = if ($script:CreateProjectPlaceholdersCheckBox.Checked) {
            Format-T "projectPlaceholders" @($script:ProjectRootTextBox.Text.Trim())
        }
        else { T "projectPathsKeep" }
        $message = if ($script:RestoreAppStateCheckBox.Checked) { Format-T "restoreOverwrite" @($scope, $provider) }
        else { Format-T "restoreMerge" @($scope, $provider) }
        $message += "`r`n" + $projectHandling
        $message += "`r`n" + (T "continueQuestion")
        if ([System.Windows.Forms.MessageBox]::Show($script:MainForm, $message, (T "confirmRestore"), "YesNo", "Warning") -ne "Yes") { return $false }
    }
    return $true
}

function New-SelectionFile {
    if ($null -eq $script:SelectedSessionIds) { return "" }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-history-selection-{0}.txt" -f [Guid]::NewGuid().ToString("N"))
    [System.IO.File]::WriteAllLines($path, @($script:SelectedSessionIds | Sort-Object), [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Remove-SelectionFile {
    if (-not [string]::IsNullOrWhiteSpace($script:SelectionFile) -and (Test-Path -LiteralPath $script:SelectionFile -PathType Leaf)) {
        [System.IO.File]::Delete($script:SelectionFile)
    }
    $script:SelectionFile = ""
}

function Get-CoreProcessArguments {
    $source = $script:SourceTextBox.Text.Trim()
    $destination = $script:DestinationTextBox.Text.Trim()
    if ($script:SelectedMode -eq "Manage") {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:CoreScriptPath,
            "-Mode", $script:SelectedManagementAction, "-CodexHome", $source)
        if ($script:SelectedManagementAction -eq "SetProvider") {
            $arguments += @("-TargetModelProvider", $destination)
        }
    }
    else {
        $archive = if ($script:SelectedMode -eq "Export") { $destination } else { $source }
        $codexHome = if ($script:SelectedMode -eq "Export") { $source } else { $destination }
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:CoreScriptPath, "-Mode", $script:SelectedMode, "-ArchivePath", $archive, "-CodexHome", $codexHome)
    }
    if ($script:SelectedMode -eq "Export" -and $script:HistoryOnlyCheckBox.Checked) { $arguments += "-HistoryOnly" }
    if ($script:SelectedMode -eq "Export" -and $script:IncludeArtifactsCheckBox.Checked) { $arguments += "-IncludeArtifacts" }
    if ($script:SelectedMode -eq "Export" -and $script:ForceExportOverwrite) { $arguments += "-Force" }
    if ($script:SelectedMode -eq "Import" -and $script:RestoreAppStateCheckBox.Checked) { $arguments += "-RestoreAppState" }
    if ($script:SelectedMode -eq "Import" -and $script:RewriteProviderCheckBox.Checked) {
        $arguments += "-RewriteModelProvider"
        if (-not [string]::IsNullOrWhiteSpace($script:TargetProviderTextBox.Text)) { $arguments += @("-TargetModelProvider", $script:TargetProviderTextBox.Text.Trim()) }
    }
    if ($script:SelectedMode -eq "Import" -and $script:CreateProjectPlaceholdersCheckBox.Checked) {
        $arguments += @("-ProjectRoot", $script:ProjectRootTextBox.Text.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SelectionFile)) { $arguments += @("-SessionSelectionFile", $script:SelectionFile) }
    return ($arguments | ForEach-Object { ConvertTo-QuotedProcessArgument $_ }) -join " "
}

function Set-UiBusy {
    param([bool]$Busy)
    foreach ($control in @($script:RunButton, $script:ExportModeButton, $script:ImportModeButton, $script:ManageModeButton, $script:ChineseButton, $script:EnglishButton,
        $script:SourceTextBox, $script:DestinationTextBox, $script:SourceBrowseButton, $script:DestinationBrowseButton, $script:ChooseSessionsButton,
        $script:AdvancedButton, $script:HistoryOnlyCheckBox, $script:IncludeArtifactsCheckBox, $script:RewriteProviderCheckBox,
        $script:CreateProjectPlaceholdersCheckBox, $script:ProjectRootBrowseButton, $script:SetProviderActionButton, $script:DeleteActionButton, $script:CompactButton)) {
        $control.Enabled = -not $Busy
    }
    $partial = $null -ne $script:SelectedSessionIds -or ($script:SelectedMode -eq "Import" -and $script:ArchiveIsPartial)
    $script:RestoreAppStateCheckBox.Enabled = -not $Busy -and -not $partial
    $script:TargetProviderTextBox.Enabled = -not $Busy -and $script:RewriteProviderCheckBox.Checked
    $script:ProjectRootTextBox.Enabled = -not $Busy -and $script:CreateProjectPlaceholdersCheckBox.Checked
    $script:ProjectRootBrowseButton.Enabled = -not $Busy -and $script:CreateProjectPlaceholdersCheckBox.Checked
}

function Handle-CoreLine {
    param([string]$Line)
    if ($Line -match '^progress\tpercent=(?<percent>\d+)\tstage=(?<stage>.+)$') {
        $percent = [Math]::Max(0, [Math]::Min(100, [int]$Matches.percent))
        Set-ProgressValue $percent
        $script:PercentLabel.Text = "$percent%"
        $script:StatusLabel.Text = T $Matches.stage
        $script:StatusLabel.ForeColor = $script:Palette.Accent
    }
    else { Write-UiLog $Line }
}

function Complete-MigrationOperation {
    $line = ""
    while ($script:OutputQueue.TryDequeue([ref]$line)) { Handle-CoreLine $line }
    if ($null -eq $script:ActiveProcess -or -not $script:ActiveProcess.HasExited) { return }
    $script:ActiveProcess.WaitForExit()
    while ($script:OutputQueue.TryDequeue([ref]$line)) { Handle-CoreLine $line }
    $exitCode = $script:ActiveProcess.ExitCode
    $script:ActiveProcess.Dispose()
    $script:ActiveProcess = $null
    $script:ProcessTimer.Stop()
    Remove-SelectionFile
    Set-UiBusy $false
    if ($exitCode -eq 0) {
        Set-ProgressValue 100
        $script:PercentLabel.Text = "100%"
        $script:StatusLabel.Text = T "completed"
        $script:StatusLabel.ForeColor = $script:Palette.Success
        if ($script:SelectedMode -eq "Manage") { Reset-SessionSelection }
    }
    else {
        $script:StatusLabel.Text = T "failed"
        $script:StatusLabel.ForeColor = $script:Palette.Danger
        if (-not $script:DetailsExpanded) { $script:DetailsExpanded = $true; Update-Layout }
    }
}

function Start-MigrationOperation {
    if ($null -ne $script:ActiveProcess -or -not (Test-UiInput)) { return }
    $script:LogTextBox.Clear()
    Set-ProgressValue 0
    $script:PercentLabel.Text = "0%"
    $script:StatusLabel.Text = T "starting"
    $script:StatusLabel.ForeColor = $script:Palette.Accent
    try {
        $script:SelectionFile = New-SelectionFile
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = Get-CoreProcessArguments
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $script:ActiveProcess = [System.Diagnostics.Process]::new()
        $script:ActiveProcess.StartInfo = $startInfo
        $script:ActiveProcess.add_OutputDataReceived({ $eventData = $_; if ($null -ne $eventData -and $null -ne $eventData.Data) { $script:OutputQueue.Enqueue([string]$eventData.Data) } })
        $script:ActiveProcess.add_ErrorDataReceived({ $eventData = $_; if ($null -ne $eventData -and $null -ne $eventData.Data) { $script:OutputQueue.Enqueue([string]$eventData.Data) } })
        if (-not $script:ActiveProcess.Start()) { throw "Could not start the migration process." }
        $script:ActiveProcess.BeginOutputReadLine()
        $script:ActiveProcess.BeginErrorReadLine()
        Set-UiBusy $true
        $script:ProcessTimer.Start()
    }
    catch {
        if ($null -ne $script:ActiveProcess) { $script:ActiveProcess.Dispose(); $script:ActiveProcess = $null }
        Remove-SelectionFile
        Set-UiBusy $false
        $script:StatusLabel.Text = T "startFailed"
        $script:StatusLabel.ForeColor = $script:Palette.Danger
        Write-UiLog $_.Exception.Message
        if (-not $script:DetailsExpanded) { $script:DetailsExpanded = $true; Update-Layout }
    }
}

if (-not (Test-Path -LiteralPath $script:CoreScriptPath -PathType Leaf)) {
    [System.Windows.Forms.MessageBox]::Show("Missing core script: $script:CoreScriptPath", "Codex Session Manager", "OK", "Error") | Out-Null
    exit 1
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:MainForm = [System.Windows.Forms.Form]::new()
$script:MainForm.StartPosition = "CenterScreen"
$script:MainForm.ClientSize = [System.Drawing.Size]::new(980, 680)
$script:MainForm.MinimumSize = [System.Drawing.Size]::new(900, 640)
$script:MainForm.BackColor = $script:Palette.Canvas
$script:MainForm.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25)
$script:MainForm.AutoScaleMode = "Dpi"
$script:MainForm.ShowIcon = $false

$script:SidebarPanel = [System.Windows.Forms.Panel]::new()
$script:SidebarPanel.Dock = "Left"
$script:SidebarPanel.Size = [System.Drawing.Size]::new(([int]$script:Metrics.SidebarWidth), 680)
$script:SidebarPanel.BackColor = $script:Palette.Sidebar
$script:SidebarBorder = [System.Windows.Forms.Panel]::new()
$script:SidebarBorder.Dock = "Right"
$script:SidebarBorder.Width = 1
$script:SidebarBorder.BackColor = $script:Palette.SidebarHover

$script:BrandMark = [System.Windows.Forms.Panel]::new()
$script:BrandMark.Location = [System.Drawing.Point]::new(24, 22)
$script:BrandMark.Size = [System.Drawing.Size]::new(36, 36)
$script:BrandMark.BackColor = $script:Palette.Accent
Enable-RoundedCorners $script:BrandMark ([int]$script:Metrics.RadiusMedium)
$script:BrandLetter = New-UiLabel "C" 0 0 36 36
$script:BrandLetter.Font = [System.Drawing.Font]::new($script:UiFontFamily, 16, [System.Drawing.FontStyle]::Bold)
$script:BrandLetter.ForeColor = $script:Palette.Surface
$script:BrandLetter.TextAlign = "MiddleCenter"
$script:BrandLetter.BackColor = [System.Drawing.Color]::Transparent
$script:BrandDot = [System.Windows.Forms.Panel]::new()
$script:BrandDot.Location = [System.Drawing.Point]::new(27, 27)
$script:BrandDot.Size = [System.Drawing.Size]::new(7, 7)
$script:BrandDot.BackColor = $script:Palette.BrandWarm
Enable-RoundedCorners $script:BrandDot 4
$script:BrandMark.Controls.AddRange(@($script:BrandLetter, $script:BrandDot))
$script:BrandDot.BringToFront()

$script:TitleLabel = New-UiLabel "" 72 16 124 54
$script:TitleLabel.Font = [System.Drawing.Font]::new($script:UiFontFamily, 11.5, [System.Drawing.FontStyle]::Bold)
$script:TitleLabel.ForeColor = $script:Palette.SidebarText
$script:TitleLabel.AutoEllipsis = $true
$script:ExportModeButton = New-NavigationButton 104
$script:ImportModeButton = New-NavigationButton 158
$script:ManageModeButton = New-NavigationButton 212
$script:ExportNavIcon = Add-NavigationIcon $script:ExportModeButton ([string][char]0xE74E)
$script:ImportNavIcon = Add-NavigationIcon $script:ImportModeButton ([string][char]0xE896)
$script:ManageNavIcon = Add-NavigationIcon $script:ManageModeButton ([string][char]0xE713)
$script:ExportIndicator = [System.Windows.Forms.Panel]::new()
$script:ExportIndicator.Location = [System.Drawing.Point]::new(12, 113)
$script:ExportIndicator.Size = [System.Drawing.Size]::new(3, 28)
$script:ExportIndicator.BackColor = $script:Palette.Accent
$script:ImportIndicator = [System.Windows.Forms.Panel]::new()
$script:ImportIndicator.Location = [System.Drawing.Point]::new(12, 167)
$script:ImportIndicator.Size = [System.Drawing.Size]::new(3, 28)
$script:ImportIndicator.BackColor = $script:Palette.Accent
$script:ManageIndicator = [System.Windows.Forms.Panel]::new()
$script:ManageIndicator.Location = [System.Drawing.Point]::new(12, 221)
$script:ManageIndicator.Size = [System.Drawing.Size]::new(3, 28)
$script:ManageIndicator.BackColor = $script:Palette.Accent
$script:ChineseButton = New-SegmentButton 24 624 54 32
$script:ChineseButton.Anchor = "Bottom, Left"
$script:EnglishButton = New-SegmentButton 86 624 62 32
$script:EnglishButton.Anchor = "Bottom, Left"
$script:SidebarPanel.Controls.AddRange(@(
    $script:SidebarBorder, $script:BrandMark, $script:TitleLabel, $script:ExportModeButton, $script:ImportModeButton, $script:ManageModeButton,
    $script:ExportIndicator, $script:ImportIndicator, $script:ManageIndicator, $script:ChineseButton, $script:EnglishButton
))
$script:ExportIndicator.BringToFront()
$script:ImportIndicator.BringToFront()
$script:ManageIndicator.BringToFront()

$script:WorkspacePanel = [System.Windows.Forms.Panel]::new()
$script:WorkspacePanel.Dock = "Fill"
$script:WorkspacePanel.Size = [System.Drawing.Size]::new(764, 680)
$script:WorkspacePanel.BackColor = $script:Palette.Canvas

$script:HeaderPanel = [System.Windows.Forms.Panel]::new()
$script:HeaderPanel.Dock = "Top"
$script:HeaderPanel.Size = [System.Drawing.Size]::new(764, 92)
$script:HeaderPanel.BackColor = $script:Palette.Canvas
$script:HeaderBorder = [System.Windows.Forms.Panel]::new()
$script:HeaderBorder.Dock = "Bottom"
$script:HeaderBorder.Height = 1
$script:HeaderBorder.BackColor = $script:Palette.Border
$script:TaskAccent = [System.Windows.Forms.Panel]::new()
$script:TaskAccent.Location = [System.Drawing.Point]::new(24, 30)
$script:TaskAccent.Size = [System.Drawing.Size]::new(4, 32)
$script:TaskAccent.BackColor = $script:Palette.BrandWarm
Enable-RoundedCorners $script:TaskAccent 2
$script:TaskTitleLabel = New-UiLabel "" 40 20 680 52
$script:TaskTitleLabel.Font = [System.Drawing.Font]::new($script:UiFontFamily, 18.5, [System.Drawing.FontStyle]::Bold)
$script:TaskTitleLabel.Anchor = "Top, Left, Right"
$script:HeaderPanel.Controls.AddRange(@($script:HeaderBorder, $script:TaskAccent, $script:TaskTitleLabel))

$script:BodyPanel = [System.Windows.Forms.Panel]::new()
$script:BodyPanel.Dock = "Fill"
$script:BodyPanel.Size = [System.Drawing.Size]::new(764, 434)
$script:BodyPanel.BackColor = $script:Palette.Canvas
$script:BodyPanel.AutoScroll = $true
$script:BodyPanel.AutoScrollMinSize = [System.Drawing.Size]::new(0, 430)

$script:SourceLabel = New-UiLabel "" 36 12 260
$script:SourceLabel.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25, [System.Drawing.FontStyle]::Bold)
$script:SourceInputFrame = New-InputFrame 36 40 692 ([int]$script:Metrics.InputHeight)
$script:SourceInputFrame.Anchor = "Top, Left, Right"
$script:SourceTextBox = [System.Windows.Forms.TextBox]::new()
$script:SourceTextBox.Location = [System.Drawing.Point]::new(12, 9)
$script:SourceTextBox.Size = [System.Drawing.Size]::new(624, 22)
$script:SourceTextBox.Anchor = "Top, Left, Right"
$script:SourceTextBox.BorderStyle = "None"
$script:SourceTextBox.BackColor = $script:Palette.Field
$script:SourceBrowseButton = New-SegmentButton 644 2 46 34
$script:SourceBrowseButton.Text = "⋯"
$script:SourceBrowseButton.Font = [System.Drawing.Font]::new($script:UiFontFamily, 13, [System.Drawing.FontStyle]::Bold)
$script:SourceBrowseButton.FlatAppearance.BorderSize = 0
$script:SourceBrowseButton.BackColor = $script:Palette.Field
$script:SourceBrowseButton.ForeColor = $script:Palette.MutedText
$script:SourceBrowseButton.FlatAppearance.MouseOverBackColor = $script:Palette.AccentSoft
$script:SourceBrowseButton.FlatAppearance.MouseDownBackColor = $script:Palette.AccentSoft
$script:SourceBrowseButton.Anchor = "Top, Right"
$script:SourceInputFrame.Controls.AddRange(@($script:SourceTextBox, $script:SourceBrowseButton))
Connect-InputFrame $script:SourceInputFrame $script:SourceTextBox

$script:SessionsLabel = New-UiLabel "" 36 98 180
$script:SessionsLabel.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25, [System.Drawing.FontStyle]::Bold)
$script:SessionScopePanel = New-InputFrame 36 126 692 54
$script:SessionScopePanel.Anchor = "Top, Left, Right"
$script:SessionSummaryLabel = New-UiLabel "" 14 10 470 34
$script:SessionSummaryLabel.ForeColor = $script:Palette.MutedText
$script:SessionSummaryLabel.Anchor = "Top, Left, Right"
$script:ChooseSessionsButton = New-SegmentButton 500 9 180 36
$script:ChooseSessionsButton.Anchor = "Top, Right"
$script:SessionScopePanel.Controls.AddRange(@($script:SessionSummaryLabel, $script:ChooseSessionsButton))

$script:ManagementActionLabel = New-UiLabel "" 36 204 260
$script:ManagementActionLabel.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25, [System.Drawing.FontStyle]::Bold)
$script:SetProviderActionButton = New-SegmentButton 36 232 180 38
$script:DeleteActionButton = New-SegmentButton 224 232 180 38
$script:CompactButton = New-SegmentButton 416 232 248 38
Set-SegmentState $script:CompactButton $false

$script:DestinationLabel = New-UiLabel "" 36 204 280
$script:DestinationLabel.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.25, [System.Drawing.FontStyle]::Bold)
$script:DestinationInputFrame = New-InputFrame 36 232 692 ([int]$script:Metrics.InputHeight)
$script:DestinationInputFrame.Anchor = "Top, Left, Right"
$script:DestinationTextBox = [System.Windows.Forms.TextBox]::new()
$script:DestinationTextBox.Location = [System.Drawing.Point]::new(12, 9)
$script:DestinationTextBox.Size = [System.Drawing.Size]::new(624, 22)
$script:DestinationTextBox.Anchor = "Top, Left, Right"
$script:DestinationTextBox.BorderStyle = "None"
$script:DestinationTextBox.BackColor = $script:Palette.Field
$script:DestinationBrowseButton = New-SegmentButton 644 2 46 34
$script:DestinationBrowseButton.Text = "⋯"
$script:DestinationBrowseButton.Font = [System.Drawing.Font]::new($script:UiFontFamily, 13, [System.Drawing.FontStyle]::Bold)
$script:DestinationBrowseButton.FlatAppearance.BorderSize = 0
$script:DestinationBrowseButton.BackColor = $script:Palette.Field
$script:DestinationBrowseButton.ForeColor = $script:Palette.MutedText
$script:DestinationBrowseButton.FlatAppearance.MouseOverBackColor = $script:Palette.AccentSoft
$script:DestinationBrowseButton.FlatAppearance.MouseDownBackColor = $script:Palette.AccentSoft
$script:DestinationBrowseButton.Anchor = "Top, Right"
$script:DestinationInputFrame.Controls.AddRange(@($script:DestinationTextBox, $script:DestinationBrowseButton))
Connect-InputFrame $script:DestinationInputFrame $script:DestinationTextBox

$script:AdvancedButton = [System.Windows.Forms.Button]::new()
$script:AdvancedButton.Location = [System.Drawing.Point]::new(32, 282)
$script:AdvancedButton.Size = [System.Drawing.Size]::new(220, 34)
$script:AdvancedButton.FlatStyle = "Flat"
$script:AdvancedButton.FlatAppearance.BorderSize = 0
$script:AdvancedButton.FlatAppearance.MouseOverBackColor = $script:Palette.AccentSoft
$script:AdvancedButton.FlatAppearance.MouseDownBackColor = $script:Palette.AccentSoft
$script:AdvancedButton.TextAlign = "MiddleLeft"
$script:AdvancedButton.Cursor = "Hand"
$script:AdvancedButton.ForeColor = $script:Palette.MutedText
$script:AdvancedButton.BackColor = $script:Palette.Canvas

$script:AdvancedPanel = New-InputFrame 36 324 692 178
$script:AdvancedPanel.Anchor = "Top, Left, Right"
$script:AdvancedPanel.BackColor = $script:Palette.Surface
$script:ExportOptionsPanel = [System.Windows.Forms.Panel]::new()
$script:ExportOptionsPanel.Location = [System.Drawing.Point]::new(10, 8)
$script:ExportOptionsPanel.Size = [System.Drawing.Size]::new(672, 88)
$script:ExportOptionsPanel.Anchor = "Top, Bottom, Left, Right"
$script:ExportOptionsPanel.BackColor = $script:Palette.Surface
$script:HistoryOnlyCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:HistoryOnlyCheckBox.Location = [System.Drawing.Point]::new(16, 14)
$script:HistoryOnlyCheckBox.Size = [System.Drawing.Size]::new(620, 24)
$script:HistoryOnlyCheckBox.BackColor = $script:Palette.Surface
$script:IncludeArtifactsCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:IncludeArtifactsCheckBox.Location = [System.Drawing.Point]::new(16, 50)
$script:IncludeArtifactsCheckBox.Size = [System.Drawing.Size]::new(620, 24)
$script:IncludeArtifactsCheckBox.BackColor = $script:Palette.Surface
$script:ExportOptionsPanel.Controls.AddRange(@($script:HistoryOnlyCheckBox, $script:IncludeArtifactsCheckBox))

$script:ImportOptionsPanel = [System.Windows.Forms.Panel]::new()
$script:ImportOptionsPanel.Location = [System.Drawing.Point]::new(10, 8)
$script:ImportOptionsPanel.Size = [System.Drawing.Size]::new(672, 162)
$script:ImportOptionsPanel.Anchor = "Top, Bottom, Left, Right"
$script:ImportOptionsPanel.BackColor = $script:Palette.Surface
$script:RestoreAppStateCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:RestoreAppStateCheckBox.Location = [System.Drawing.Point]::new(16, 8)
$script:RestoreAppStateCheckBox.Size = [System.Drawing.Size]::new(620, 26)
$script:RestoreAppStateCheckBox.BackColor = $script:Palette.Surface
$script:RewriteProviderCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:RewriteProviderCheckBox.Location = [System.Drawing.Point]::new(16, 42)
$script:RewriteProviderCheckBox.Size = [System.Drawing.Size]::new(300, 26)
$script:RewriteProviderCheckBox.Checked = $true
$script:RewriteProviderCheckBox.BackColor = $script:Palette.Surface
$script:TargetProviderLabel = New-UiLabel "" 330 42 130
$script:TargetProviderTextBox = [System.Windows.Forms.TextBox]::new()
$script:TargetProviderTextBox.Location = [System.Drawing.Point]::new(462, 40)
$script:TargetProviderTextBox.Size = [System.Drawing.Size]::new(184, 28)
$script:TargetProviderTextBox.Anchor = "Top, Left, Right"
$script:TargetProviderTextBox.BackColor = $script:Palette.Field
$script:CreateProjectPlaceholdersCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:CreateProjectPlaceholdersCheckBox.Location = [System.Drawing.Point]::new(16, 76)
$script:CreateProjectPlaceholdersCheckBox.Size = [System.Drawing.Size]::new(630, 26)
$script:CreateProjectPlaceholdersCheckBox.Checked = $false
$script:CreateProjectPlaceholdersCheckBox.BackColor = $script:Palette.Surface
$script:ProjectRootLabel = New-UiLabel "" 16 116 122
$script:ProjectRootInputFrame = New-InputFrame 146 108 500 ([int]$script:Metrics.InputHeight)
$script:ProjectRootInputFrame.Anchor = "Top, Left, Right"
$script:ProjectRootTextBox = [System.Windows.Forms.TextBox]::new()
$script:ProjectRootTextBox.Location = [System.Drawing.Point]::new(12, 9)
$script:ProjectRootTextBox.Size = [System.Drawing.Size]::new(430, 22)
$script:ProjectRootTextBox.Anchor = "Top, Left, Right"
$script:ProjectRootTextBox.BorderStyle = "None"
$script:ProjectRootTextBox.BackColor = $script:Palette.Field
$script:ProjectRootTextBox.Enabled = $false
$script:ProjectRootBrowseButton = New-SegmentButton 452 2 46 34
$script:ProjectRootBrowseButton.Text = "⋯"
$script:ProjectRootBrowseButton.Font = [System.Drawing.Font]::new($script:UiFontFamily, 13, [System.Drawing.FontStyle]::Bold)
$script:ProjectRootBrowseButton.FlatAppearance.BorderSize = 0
$script:ProjectRootBrowseButton.BackColor = $script:Palette.Field
$script:ProjectRootBrowseButton.ForeColor = $script:Palette.MutedText
$script:ProjectRootBrowseButton.FlatAppearance.MouseOverBackColor = $script:Palette.AccentSoft
$script:ProjectRootBrowseButton.FlatAppearance.MouseDownBackColor = $script:Palette.AccentSoft
$script:ProjectRootBrowseButton.Anchor = "Top, Right"
$script:ProjectRootBrowseButton.Enabled = $false
$script:ProjectRootInputFrame.Controls.AddRange(@($script:ProjectRootTextBox, $script:ProjectRootBrowseButton))
Connect-InputFrame $script:ProjectRootInputFrame $script:ProjectRootTextBox
$script:ImportOptionsPanel.Controls.AddRange(@($script:RestoreAppStateCheckBox, $script:RewriteProviderCheckBox, $script:TargetProviderLabel, $script:TargetProviderTextBox, $script:CreateProjectPlaceholdersCheckBox, $script:ProjectRootLabel, $script:ProjectRootInputFrame))
$script:AdvancedPanel.Controls.AddRange(@($script:ExportOptionsPanel, $script:ImportOptionsPanel))

$script:BodyPanel.Controls.AddRange(@(
    $script:SourceLabel, $script:SourceInputFrame, $script:SessionsLabel, $script:SessionScopePanel,
    $script:ManagementActionLabel, $script:SetProviderActionButton, $script:DeleteActionButton, $script:CompactButton,
    $script:DestinationLabel, $script:DestinationInputFrame, $script:AdvancedButton, $script:AdvancedPanel
))

$script:FooterPanel = [System.Windows.Forms.Panel]::new()
$script:FooterPanel.Dock = "Bottom"
$script:FooterPanel.Size = [System.Drawing.Size]::new(764, 154)
$script:FooterPanel.BackColor = $script:Palette.Surface
$script:FooterBorder = [System.Windows.Forms.Panel]::new()
$script:FooterBorder.Dock = "Top"
$script:FooterBorder.Height = 1
$script:FooterBorder.BackColor = $script:Palette.Border
$script:SafetyLabel = New-UiLabel "" 36 14 478 42
$script:SafetyLabel.ForeColor = $script:Palette.Warning
$script:RunButton = [System.Windows.Forms.Button]::new()
$script:RunButton.Location = [System.Drawing.Point]::new(548, 14)
$script:RunButton.Size = [System.Drawing.Size]::new(180, 42)
$script:RunButton.Anchor = "Top, Right"
$script:RunButton.BackColor = $script:Palette.Accent
$script:RunButton.ForeColor = [System.Drawing.Color]::White
$script:RunButton.Font = [System.Drawing.Font]::new($script:UiFontFamily, 9.5, [System.Drawing.FontStyle]::Bold)
$script:RunButton.FlatStyle = "Flat"
$script:RunButton.FlatAppearance.BorderSize = 0
$script:RunButton.FlatAppearance.MouseDownBackColor = $script:Palette.AccentPressed
$script:RunButton.Cursor = "Hand"
$script:RunButton.UseVisualStyleBackColor = $false
Enable-RoundedCorners $script:RunButton ([int]$script:Metrics.RadiusMedium)

$script:StatusLabel = New-UiLabel "" 36 64 604
$script:StatusLabel.Anchor = "Top, Left, Right"
$script:PercentLabel = New-UiLabel "0%" 664 64 64
$script:PercentLabel.Font = [System.Drawing.Font]::new($script:MonoFontFamily, 9)
$script:PercentLabel.TextAlign = "MiddleRight"
$script:PercentLabel.Anchor = "Top, Right"
$script:ProgressTrack = [System.Windows.Forms.Panel]::new()
$script:ProgressTrack.Location = [System.Drawing.Point]::new(36, 94)
$script:ProgressTrack.Size = [System.Drawing.Size]::new(692, 6)
$script:ProgressTrack.Anchor = "Top, Left, Right"
$script:ProgressTrack.BackColor = $script:Palette.DisabledSurface
Enable-RoundedCorners $script:ProgressTrack ([int]$script:Metrics.RadiusSmall)
$script:ProgressFill = [System.Windows.Forms.Panel]::new()
$script:ProgressFill.Location = [System.Drawing.Point]::new(0, 0)
$script:ProgressFill.Size = [System.Drawing.Size]::new(0, 6)
$script:ProgressFill.BackColor = $script:Palette.Accent
$script:ProgressFill.Visible = $false
$script:ProgressTrack.Controls.Add($script:ProgressFill)
$script:ProgressTrack.Add_Resize({ Set-ProgressValue $script:ProgressValue })
$script:DetailsButton = [System.Windows.Forms.Button]::new()
$script:DetailsButton.Location = [System.Drawing.Point]::new(32, 108)
$script:DetailsButton.Size = [System.Drawing.Size]::new(180, 34)
$script:DetailsButton.FlatStyle = "Flat"
$script:DetailsButton.FlatAppearance.BorderSize = 0
$script:DetailsButton.FlatAppearance.MouseOverBackColor = $script:Palette.AccentSoft
$script:DetailsButton.FlatAppearance.MouseDownBackColor = $script:Palette.AccentSoft
$script:DetailsButton.TextAlign = "MiddleLeft"
$script:DetailsButton.Cursor = "Hand"
$script:DetailsButton.ForeColor = $script:Palette.MutedText
$script:DetailsButton.BackColor = $script:Palette.Surface
$script:LogPanel = [System.Windows.Forms.Panel]::new()
$script:LogPanel.Location = [System.Drawing.Point]::new(36, 150)
$script:LogPanel.Size = [System.Drawing.Size]::new(692, 154)
$script:LogPanel.Anchor = "Top, Bottom, Left, Right"
$script:LogPanel.BackColor = $script:Palette.LogSurface
Enable-RoundedCorners $script:LogPanel ([int]$script:Metrics.RadiusMedium)
$script:LogTextBox = [System.Windows.Forms.TextBox]::new()
$script:LogTextBox.Location = [System.Drawing.Point]::new(12, 10)
$script:LogTextBox.Size = [System.Drawing.Size]::new(668, 134)
$script:LogTextBox.Multiline = $true
$script:LogTextBox.ReadOnly = $true
$script:LogTextBox.ScrollBars = "Vertical"
$script:LogTextBox.BackColor = $script:Palette.LogSurface
$script:LogTextBox.ForeColor = $script:Palette.LogText
$script:LogTextBox.BorderStyle = "None"
$script:LogTextBox.Font = [System.Drawing.Font]::new($script:MonoFontFamily, 9)
$script:LogTextBox.Anchor = "Top, Bottom, Left, Right"
$script:LogPanel.Controls.Add($script:LogTextBox)
$script:FooterPanel.Controls.AddRange(@(
    $script:FooterBorder, $script:SafetyLabel, $script:RunButton, $script:StatusLabel, $script:PercentLabel,
    $script:ProgressTrack, $script:DetailsButton, $script:LogPanel
))

$script:WorkspacePanel.Controls.Add($script:BodyPanel)
$script:WorkspacePanel.Controls.Add($script:FooterPanel)
$script:WorkspacePanel.Controls.Add($script:HeaderPanel)
$script:MainForm.Controls.Add($script:WorkspacePanel)
$script:MainForm.Controls.Add($script:SidebarPanel)

Set-SegmentState $script:ChooseSessionsButton $false

$script:ExportModeButton.TabIndex = 0
$script:ImportModeButton.TabIndex = 1
$script:ManageModeButton.TabIndex = 2
$script:ChineseButton.TabIndex = 3
$script:EnglishButton.TabIndex = 4
$script:SourceTextBox.TabIndex = 10
$script:SourceBrowseButton.TabIndex = 11
$script:ChooseSessionsButton.TabIndex = 12
$script:SetProviderActionButton.TabIndex = 13
$script:DeleteActionButton.TabIndex = 14
$script:DestinationTextBox.TabIndex = 15
$script:DestinationBrowseButton.TabIndex = 16
$script:AdvancedButton.TabIndex = 17
$script:RestoreAppStateCheckBox.TabIndex = 18
$script:RewriteProviderCheckBox.TabIndex = 19
$script:TargetProviderTextBox.TabIndex = 20
$script:CreateProjectPlaceholdersCheckBox.TabIndex = 21
$script:ProjectRootTextBox.TabIndex = 22
$script:ProjectRootBrowseButton.TabIndex = 23
$script:RunButton.TabIndex = 30
$script:DetailsButton.TabIndex = 31

$script:ToolTip = [System.Windows.Forms.ToolTip]::new()
$script:ProcessTimer = [System.Windows.Forms.Timer]::new()
$script:ProcessTimer.Interval = 120
$script:ProcessTimer.Add_Tick({ Complete-MigrationOperation })

$desktop = [Environment]::GetFolderPath("DesktopDirectory")
if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = (Get-Location).Path }
$script:ModeValues.Export.Source = Get-DefaultCodexHome
$script:ModeValues.Export.Destination = Join-Path $desktop ("codex-history-{0}.zip" -f [DateTime]::Now.ToString("yyyyMMdd-HHmmss"))
$script:ModeValues.Import.Source = ""
$script:ModeValues.Import.Destination = Get-DefaultCodexHome
$script:ModeValues.Manage.Source = Get-DefaultCodexHome
$script:ModeValues.Manage.Destination = ""

$script:ExportModeButton.Add_Click({ Set-SelectedMode "Export" })
$script:ImportModeButton.Add_Click({ Set-SelectedMode "Import" })
$script:ManageModeButton.Add_Click({ Set-SelectedMode "Manage" })
$script:SetProviderActionButton.Add_Click({ Set-ManagementAction "SetProvider" })
$script:DeleteActionButton.Add_Click({ Set-ManagementAction "Delete" })
$script:CompactButton.Add_Click({ Show-CompactionDialog })
$script:ChineseButton.Add_Click({ $script:Language = "zh"; Update-Language })
$script:EnglishButton.Add_Click({ $script:Language = "en"; Update-Language })
$script:AdvancedButton.Add_Click({
    $script:AdvancedExpanded = -not $script:AdvancedExpanded
    Update-Layout
    if ($script:AdvancedExpanded) { $script:BodyPanel.ScrollControlIntoView($script:AdvancedPanel) }
    else { $script:BodyPanel.AutoScrollPosition = [System.Drawing.Point]::new(0, 0) }
})
$script:DetailsButton.Add_Click({ $script:DetailsExpanded = -not $script:DetailsExpanded; Update-Layout })
$script:ChooseSessionsButton.Add_Click({ Show-SessionPicker })
$script:RunButton.Add_Click({ Start-MigrationOperation })
$script:SourceTextBox.Add_TextChanged({ Reset-SessionSelection })
$script:RewriteProviderCheckBox.Add_CheckedChanged({ $script:TargetProviderTextBox.Enabled = $script:RewriteProviderCheckBox.Checked -and $null -eq $script:ActiveProcess })
$script:CreateProjectPlaceholdersCheckBox.Add_CheckedChanged({
    $enabled = $script:CreateProjectPlaceholdersCheckBox.Checked -and $null -eq $script:ActiveProcess
    $script:ProjectRootTextBox.Enabled = $enabled
    $script:ProjectRootBrowseButton.Enabled = $enabled
})

$script:ProjectRootBrowseButton.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = T "browseProjectRoot"
    if (Test-Path -LiteralPath $script:ProjectRootTextBox.Text -PathType Container) { $dialog.SelectedPath = $script:ProjectRootTextBox.Text }
    if ($dialog.ShowDialog($script:MainForm) -eq "OK") { $script:ProjectRootTextBox.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})

$script:SourceBrowseButton.Add_Click({
    if ($script:SelectedMode -ne "Import") {
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = T "browseCodex"
        if (Test-Path -LiteralPath $script:SourceTextBox.Text -PathType Container) { $dialog.SelectedPath = $script:SourceTextBox.Text }
    }
    else {
        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = T "browseOpenZip"
        $dialog.Filter = T "zipFilter"
        $dialog.CheckFileExists = $true
    }
    if ($dialog.ShowDialog($script:MainForm) -eq "OK") {
        $script:SourceTextBox.Text = if ($script:SelectedMode -ne "Import") { $dialog.SelectedPath } else { $dialog.FileName }
    }
    $dialog.Dispose()
})

$script:DestinationBrowseButton.Add_Click({
    if ($script:SelectedMode -eq "Export") {
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        $dialog.Title = T "browseSaveZip"
        $dialog.Filter = T "zipFilter"
        $dialog.DefaultExt = "zip"
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $false
        if (-not [string]::IsNullOrWhiteSpace($script:DestinationTextBox.Text)) { $dialog.FileName = [System.IO.Path]::GetFileName($script:DestinationTextBox.Text) }
    }
    else {
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = T "browseCodex"
        if (Test-Path -LiteralPath $script:DestinationTextBox.Text -PathType Container) { $dialog.SelectedPath = $script:DestinationTextBox.Text }
    }
    if ($dialog.ShowDialog($script:MainForm) -eq "OK") {
        $script:DestinationTextBox.Text = if ($script:SelectedMode -eq "Export") { $dialog.FileName } else { $dialog.SelectedPath }
    }
    $dialog.Dispose()
})

$script:MainForm.Add_FormClosing({
    $eventData = $_
    if ($null -ne $script:ActiveProcess) {
        [System.Windows.Forms.MessageBox]::Show($script:MainForm, (T "operationRunning"), (T "appTitle"), "OK", "Information") | Out-Null
        $eventData.Cancel = $true
    }
})

Set-SelectedMode "Export"
Set-ManagementAction "SetProvider"
[System.Windows.Forms.Application]::Run($script:MainForm)

Remove-SelectionFile
$script:ProcessTimer.Dispose()
$script:ToolTip.Dispose()
$script:MainForm.Dispose()
$script:NavigationFont.Dispose()
$script:NavigationActiveFont.Dispose()
