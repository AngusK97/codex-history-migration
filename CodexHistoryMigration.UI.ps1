#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$script:CoreScriptPath = Join-Path $PSScriptRoot "CodexHistoryMigration.ps1"
$script:SelectedMode = "Export"
$script:Language = "zh"
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
$script:ModeValues = @{
    Export = @{ Source = ""; Destination = "" }
    Import = @{ Source = ""; Destination = "" }
}

$script:Strings = @{
    zh = @{
        appTitle = "Codex 历史迁移"
        export = "导出"
        import = "恢复"
        chinese = "中"
        english = "EN"
        exportSource = "Codex 数据目录"
        importSource = "备份 ZIP"
        exportDestination = "备份 ZIP 保存位置"
        importDestination = "Codex 数据目录"
        sessions = "会话范围"
        selectedSessions = "已选择 {0} / {1} 个会话"
        sessionsNotLoaded = "全部会话（可按需选择）"
        chooseSessions = "选择会话"
        advanced = "高级选项"
        details = "详细信息"
        historyOnly = "仅备份聊天历史"
        includeArtifacts = "包含生成图片与可视化"
        overwriteState = "使用备份覆盖本机桌面状态"
        rewriteProvider = "适配为本机 Provider"
        targetProvider = "目标 Provider"
        createBackup = "创建备份"
        restoreSessions = "恢复会话"
        safety = "操作前请彻底退出 Codex / ChatGPT"
        readyExport = "准备导出"
        readyImport = "准备恢复"
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
        RestoringFiles = "正在恢复会话"
        MergingIndexes = "正在更新会话索引"
        Complete = "操作完成"
        browseCodex = "选择 Codex 数据目录"
        browseSaveZip = "保存 Codex 历史备份"
        browseOpenZip = "选择 Codex 历史备份"
        zipFilter = "ZIP 归档 (*.zip)|*.zip"
        missingPath = "缺少路径"
        invalidPath = "路径无效"
        chooseZip = "请选择 ZIP 文件。"
        zipExtension = "文件必须使用 .zip 扩展名。"
        chooseCodex = "请选择 Codex 数据目录。"
        codexMissing = "Codex 数据目录不存在。"
        zipMissing = "ZIP 文件不存在。"
        overwriteTitle = "确认覆盖"
        overwriteZip = "目标 ZIP 已存在，是否覆盖？"
        confirmRestore = "确认恢复"
        restoreMerge = "将恢复 {0}。本机已有会话默认保留。{1}"
        restoreOverwrite = "将恢复 {0}，并使用备份覆盖本机桌面状态。{1}`r`n工具会先创建回滚 ZIP。"
        providerAuto = "迁入会话将自动适配本机 Provider。"
        providerNamed = "迁入会话将改为 Provider '{0}'。"
        providerKeep = "迁入会话将保留原 Provider。"
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
        activeType = "活动"
        archivedType = "归档"
        confirm = "确定"
        cancel = "取消"
        noSessions = "没有找到可迁移的会话。"
        selectAtLeastOne = "请至少选择一个会话。"
        loadSessionsFailed = "读取会话失败"
        partialOverwriteTip = "选择部分会话时不能覆盖完整的本机桌面状态。"
        stateTip = "用备份中的桌面状态数据库替换本机对应文件，可能改变本机界面状态和会话索引。"
        providerTip = "只调整迁入会话，不修改本机原有会话。留空时读取本机 config.toml。"
        historyOnlyTip = "不备份桌面状态数据库；恢复后的桌面可见性可能受影响。"
        partialArtifactsTip = "部分会话备份不会包含无法可靠归属到单个会话的生成文件。"
        allSessionsPhrase = "全部会话"
        selectedPhrase = "选中的 {0} 个会话"
    }
    en = @{
        appTitle = "Codex History Migrator"
        export = "Export"
        import = "Restore"
        chinese = "中"
        english = "EN"
        exportSource = "Codex data folder"
        importSource = "Backup ZIP"
        exportDestination = "Backup ZIP destination"
        importDestination = "Codex data folder"
        sessions = "Sessions"
        selectedSessions = "{0} of {1} sessions selected"
        sessionsNotLoaded = "All sessions (select if needed)"
        chooseSessions = "Choose sessions"
        advanced = "Advanced options"
        details = "Details"
        historyOnly = "Back up chat history only"
        includeArtifacts = "Include generated images and visualizations"
        overwriteState = "Overwrite local desktop state with backup"
        rewriteProvider = "Adapt sessions to this computer's Provider"
        targetProvider = "Target Provider"
        createBackup = "Create backup"
        restoreSessions = "Restore sessions"
        safety = "Close Codex / ChatGPT completely before running"
        readyExport = "Ready to export"
        readyImport = "Ready to restore"
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
        RestoringFiles = "Restoring sessions"
        MergingIndexes = "Updating session indexes"
        Complete = "Completed"
        browseCodex = "Choose Codex data folder"
        browseSaveZip = "Save Codex history backup"
        browseOpenZip = "Choose Codex history backup"
        zipFilter = "ZIP archives (*.zip)|*.zip"
        missingPath = "Missing path"
        invalidPath = "Invalid path"
        chooseZip = "Choose a ZIP file."
        zipExtension = "The file must use the .zip extension."
        chooseCodex = "Choose a Codex data folder."
        codexMissing = "The Codex data folder does not exist."
        zipMissing = "The ZIP file does not exist."
        overwriteTitle = "Confirm overwrite"
        overwriteZip = "The destination ZIP already exists. Overwrite it?"
        confirmRestore = "Confirm restore"
        restoreMerge = "Restore {0}. Existing local sessions will be kept. {1}"
        restoreOverwrite = "Restore {0} and overwrite local desktop state with the backup. {1}`r`nA rollback ZIP will be created first."
        providerAuto = "Imported sessions will use this computer's configured Provider."
        providerNamed = "Imported sessions will use Provider '{0}'."
        providerKeep = "Imported sessions will keep their original Provider."
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
        activeType = "Active"
        archivedType = "Archived"
        confirm = "OK"
        cancel = "Cancel"
        noSessions = "No migratable sessions were found."
        selectAtLeastOne = "Select at least one session."
        loadSessionsFailed = "Could not load sessions"
        partialOverwriteTip = "A partial session restore cannot overwrite the complete local desktop state."
        stateTip = "Replaces matching local desktop-state files with the backup and may change UI state and session indexes."
        providerTip = "Only affects imported sessions. Leave blank to read this computer's config.toml."
        historyOnlyTip = "Excludes desktop-state databases; restored sessions may not appear in every Desktop version."
        partialArtifactsTip = "Partial backups exclude generated files that cannot be reliably assigned to one session."
        allSessionsPhrase = "all sessions"
        selectedPhrase = "the selected {0} sessions"
    }
}

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
    $label.ForeColor = [System.Drawing.Color]::FromArgb(42, 45, 51)
    $label.TextAlign = "MiddleLeft"
    return $label
}

function New-SegmentButton {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height = 36)
    $button = [System.Windows.Forms.Button]::new()
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Width, $Height)
    $button.FlatStyle = "Flat"
    $button.FlatAppearance.BorderSize = 1
    $button.Cursor = "Hand"
    return $button
}

function Set-SegmentState {
    param([System.Windows.Forms.Button]$Button, [bool]$Active)
    $accent = [System.Drawing.Color]::FromArgb(20, 103, 184)
    if ($Active) {
        $Button.BackColor = $accent
        $Button.ForeColor = [System.Drawing.Color]::White
        $Button.FlatAppearance.BorderColor = $accent
    }
    else {
        $Button.BackColor = [System.Drawing.Color]::FromArgb(238, 240, 243)
        $Button.ForeColor = [System.Drawing.Color]::FromArgb(56, 60, 67)
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(207, 211, 217)
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
        $script:SessionSummaryLabel.Text = T "sessionsNotLoaded"
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
    $advancedHeight = if ($script:AdvancedExpanded) { 92 } else { 0 }
    $script:AdvancedPanel.Visible = $script:AdvancedExpanded
    $script:AdvancedPanel.Location = [System.Drawing.Point]::new(28, 372)
    $script:AdvancedPanel.Size = [System.Drawing.Size]::new(744, $advancedHeight)
    $actionY = 388 + $advancedHeight
    $script:SafetyLabel.Location = [System.Drawing.Point]::new(28, ($actionY + 2))
    $script:RunButton.Location = [System.Drawing.Point]::new(606, $actionY)
    $script:StatusLabel.Location = [System.Drawing.Point]::new(28, ($actionY + 54))
    $script:PercentLabel.Location = [System.Drawing.Point]::new(708, ($actionY + 54))
    $script:ProgressBar.Location = [System.Drawing.Point]::new(28, ($actionY + 82))
    $script:DetailsButton.Location = [System.Drawing.Point]::new(28, ($actionY + 102))
    $script:LogTextBox.Location = [System.Drawing.Point]::new(28, ($actionY + 136))
    $script:LogTextBox.Visible = $script:DetailsExpanded
    $script:LogTextBox.Size = [System.Drawing.Size]::new(744, 160)
    $script:AdvancedButton.Text = $(if ($script:AdvancedExpanded) { "- " } else { "+ " }) + (T "advanced")
    $script:DetailsButton.Text = $(if ($script:DetailsExpanded) { "- " } else { "+ " }) + (T "details")
    $height = if ($script:DetailsExpanded) { $actionY + 320 } else { $actionY + 146 }
    $script:MainForm.ClientSize = [System.Drawing.Size]::new($script:MainForm.ClientSize.Width, $height)
}

function Update-Language {
    $script:MainForm.Text = T "appTitle"
    $script:TitleLabel.Text = T "appTitle"
    $script:ExportModeButton.Text = T "export"
    $script:ImportModeButton.Text = T "import"
    $script:ChineseButton.Text = T "chinese"
    $script:EnglishButton.Text = T "english"
    $script:SourceLabel.Text = T $(if ($script:SelectedMode -eq "Export") { "exportSource" } else { "importSource" })
    $script:DestinationLabel.Text = T $(if ($script:SelectedMode -eq "Export") { "exportDestination" } else { "importDestination" })
    $script:SessionsLabel.Text = T "sessions"
    $script:ChooseSessionsButton.Text = T "chooseSessions"
    $script:HistoryOnlyCheckBox.Text = T "historyOnly"
    $script:IncludeArtifactsCheckBox.Text = T "includeArtifacts"
    $script:RestoreAppStateCheckBox.Text = T "overwriteState"
    $script:RewriteProviderCheckBox.Text = T "rewriteProvider"
    $script:TargetProviderLabel.Text = T "targetProvider"
    $script:RunButton.Text = T $(if ($script:SelectedMode -eq "Export") { "createBackup" } else { "restoreSessions" })
    $script:SafetyLabel.Text = T "safety"
    if ($null -eq $script:ActiveProcess) { $script:StatusLabel.Text = T $script:CurrentStatusKey }
    Set-SegmentState $script:ChineseButton ($script:Language -eq "zh")
    Set-SegmentState $script:EnglishButton ($script:Language -eq "en")
    $script:ToolTip.SetToolTip($script:SourceBrowseButton, (T $(if ($script:SelectedMode -eq "Export") { "browseCodex" } else { "browseOpenZip" })))
    $script:ToolTip.SetToolTip($script:DestinationBrowseButton, (T $(if ($script:SelectedMode -eq "Export") { "browseSaveZip" } else { "browseCodex" })))
    $script:ToolTip.SetToolTip($script:HistoryOnlyCheckBox, (T "historyOnlyTip"))
    $script:ToolTip.SetToolTip($script:IncludeArtifactsCheckBox, (T "partialArtifactsTip"))
    $script:ToolTip.SetToolTip($script:RewriteProviderCheckBox, (T "providerTip"))
    $script:ToolTip.SetToolTip($script:TargetProviderTextBox, (T "providerTip"))
    Update-SessionSummary
    Update-Layout
}

function Set-SelectedMode {
    param([ValidateSet("Export", "Import")][string]$Mode)
    if ($script:SelectedMode -ne $Mode) { Save-ModeValues }
    $script:SelectedMode = $Mode
    $script:SuppressSelectionReset = $true
    $script:SourceTextBox.Text = [string]$script:ModeValues[$Mode].Source
    $script:DestinationTextBox.Text = [string]$script:ModeValues[$Mode].Destination
    $script:SuppressSelectionReset = $false
    $script:AvailableSessions = @()
    $script:SelectedSessionIds = $null
    $script:ArchiveIsPartial = $false
    $script:CurrentStatusKey = if ($Mode -eq "Export") { "readyExport" } else { "readyImport" }
    $script:ExportOptionsPanel.Visible = $Mode -eq "Export"
    $script:ImportOptionsPanel.Visible = $Mode -eq "Import"
    Set-SegmentState $script:ExportModeButton ($Mode -eq "Export")
    Set-SegmentState $script:ImportModeButton ($Mode -eq "Import")
    $script:ProgressBar.Value = 0
    $script:PercentLabel.Text = "0%"
    Update-Language
}

function Show-Message {
    param([string]$Message, [string]$TitleKey, [System.Windows.Forms.MessageBoxIcon]$Icon = "Warning")
    [System.Windows.Forms.MessageBox]::Show($script:MainForm, $Message, (T $TitleKey), "OK", $Icon) | Out-Null
}

function Invoke-SessionList {
    $source = $script:SourceTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($source)) {
        Show-Message (T $(if ($script:SelectedMode -eq "Export") { "chooseCodex" } else { "chooseZip" })) "missingPath"
        return $null
    }
    if ($script:SelectedMode -eq "Export" -and -not (Test-Path -LiteralPath $source -PathType Container)) {
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
        if ($script:SelectedMode -eq "Export") { $arguments += @("-CodexHome", $source) }
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

function Show-SessionPicker {
    $sessions = Invoke-SessionList
    if ($null -eq $sessions) { return }
    if ($sessions.Count -eq 0) { Show-Message (T "noSessions") "sessionPickerTitle" "Information"; return }
    Update-SessionSummary

    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = T "sessionPickerTitle"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = [System.Drawing.Size]::new(720, 500)
    $dialog.MinimumSize = [System.Drawing.Size]::new(680, 480)
    $dialog.Font = $script:MainForm.Font
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)

    $searchLabel = New-UiLabel (T "search") 20 16 80
    $searchBox = [System.Windows.Forms.TextBox]::new()
    $searchBox.Location = [System.Drawing.Point]::new(20, 42)
    $searchBox.Size = [System.Drawing.Size]::new(680, 28)
    $searchBox.Anchor = "Top, Left, Right"
    $list = [System.Windows.Forms.ListView]::new()
    $list.Location = [System.Drawing.Point]::new(20, 82)
    $list.Size = [System.Drawing.Size]::new(680, 342)
    $list.Anchor = "Top, Bottom, Left, Right"
    $list.View = "Details"
    $list.CheckBoxes = $true
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.Columns.Add((T "titleColumn"), 390) | Out-Null
    $list.Columns.Add((T "updatedColumn"), 170) | Out-Null
    $list.Columns.Add((T "typeColumn"), 90) | Out-Null

    $selectedMap = @{}
    foreach ($session in $sessions) {
        $selectedMap[[string]$session.id] = ($null -eq $script:SelectedSessionIds -or $script:SelectedSessionIds.Contains([string]$session.id))
    }

    $countLabel = New-UiLabel "" 20 438 230
    $countLabel.Anchor = "Bottom, Left"
    $allButton = [System.Windows.Forms.Button]::new()
    $allButton.Text = T "selectAll"
    $allButton.Location = [System.Drawing.Point]::new(258, 434)
    $allButton.Size = [System.Drawing.Size]::new(88, 32)
    $allButton.Anchor = "Bottom, Left"
    $clearButton = [System.Windows.Forms.Button]::new()
    $clearButton.Text = T "clearAll"
    $clearButton.Location = [System.Drawing.Point]::new(352, 434)
    $clearButton.Size = [System.Drawing.Size]::new(78, 32)
    $clearButton.Anchor = "Bottom, Left"
    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Text = T "cancel"
    $cancelButton.DialogResult = "Cancel"
    $cancelButton.Location = [System.Drawing.Point]::new(506, 434)
    $cancelButton.Size = [System.Drawing.Size]::new(92, 32)
    $cancelButton.Anchor = "Bottom, Right"
    $okButton = [System.Windows.Forms.Button]::new()
    $okButton.Text = T "confirm"
    $okButton.Location = [System.Drawing.Point]::new(608, 434)
    $okButton.Size = [System.Drawing.Size]::new(92, 32)
    $okButton.Anchor = "Bottom, Right"
    $okButton.BackColor = [System.Drawing.Color]::FromArgb(20, 103, 184)
    $okButton.ForeColor = [System.Drawing.Color]::White
    $okButton.FlatStyle = "Flat"
    $okButton.FlatAppearance.BorderSize = 0

    $updateCount = {
        $selectedCount = @($selectedMap.Values | Where-Object { $_ }).Count
        $countLabel.Text = Format-T "selectedCount" @($selectedCount, $sessions.Count)
    }
    $rebuild = {
        $filter = $searchBox.Text.Trim()
        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($session in $sessions) {
            if (-not [string]::IsNullOrWhiteSpace($filter) -and
                ([string]$session.title).IndexOf($filter, [System.StringComparison]::CurrentCultureIgnoreCase) -lt 0) { continue }
            $item = [System.Windows.Forms.ListViewItem]::new([string]$session.title)
            $item.Tag = [string]$session.id
            try { $updated = ([DateTime]::Parse([string]$session.updatedAt)).ToLocalTime().ToString("yyyy-MM-dd HH:mm") }
            catch { $updated = [string]$session.updatedAt }
            $item.SubItems.Add($updated) | Out-Null
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
    $dialog.Controls.AddRange(@($searchLabel, $searchBox, $list, $countLabel, $allButton, $clearButton, $cancelButton, $okButton))
    & $rebuild
    if ($dialog.ShowDialog($script:MainForm) -eq "OK") {
        $chosen = @($dialog.Tag)
        $script:AvailableSessions = @($sessions)
        if ($chosen.Count -eq $sessions.Count) { $script:SelectedSessionIds = $null }
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
    $zip = if ($script:SelectedMode -eq "Export") { $destination } else { $source }
    $codexHome = if ($script:SelectedMode -eq "Export") { $source } else { $destination }
    if ([string]::IsNullOrWhiteSpace($zip)) { Show-Message (T "chooseZip") "missingPath"; return $false }
    if ([System.IO.Path]::GetExtension($zip) -ine ".zip") { Show-Message (T "zipExtension") "invalidPath"; return $false }
    if ([string]::IsNullOrWhiteSpace($codexHome)) { Show-Message (T "chooseCodex") "missingPath"; return $false }
    if ($script:SelectedMode -eq "Export" -and -not (Test-Path -LiteralPath $codexHome -PathType Container)) { Show-Message (T "codexMissing") "invalidPath"; return $false }
    if ($script:SelectedMode -eq "Import" -and -not (Test-Path -LiteralPath $zip -PathType Leaf)) { Show-Message (T "zipMissing") "invalidPath"; return $false }
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
        $message = if ($script:RestoreAppStateCheckBox.Checked) { Format-T "restoreOverwrite" @($scope, $provider) }
        else { Format-T "restoreMerge" @($scope, $provider) }
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
    $archive = if ($script:SelectedMode -eq "Export") { $destination } else { $source }
    $codexHome = if ($script:SelectedMode -eq "Export") { $source } else { $destination }
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:CoreScriptPath, "-Mode", $script:SelectedMode, "-ArchivePath", $archive, "-CodexHome", $codexHome)
    if ($script:SelectedMode -eq "Export" -and $script:HistoryOnlyCheckBox.Checked) { $arguments += "-HistoryOnly" }
    if ($script:SelectedMode -eq "Export" -and $script:IncludeArtifactsCheckBox.Checked) { $arguments += "-IncludeArtifacts" }
    if ($script:SelectedMode -eq "Export" -and $script:ForceExportOverwrite) { $arguments += "-Force" }
    if ($script:SelectedMode -eq "Import" -and $script:RestoreAppStateCheckBox.Checked) { $arguments += "-RestoreAppState" }
    if ($script:SelectedMode -eq "Import" -and $script:RewriteProviderCheckBox.Checked) {
        $arguments += "-RewriteModelProvider"
        if (-not [string]::IsNullOrWhiteSpace($script:TargetProviderTextBox.Text)) { $arguments += @("-TargetModelProvider", $script:TargetProviderTextBox.Text.Trim()) }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SelectionFile)) { $arguments += @("-SessionSelectionFile", $script:SelectionFile) }
    return ($arguments | ForEach-Object { ConvertTo-QuotedProcessArgument $_ }) -join " "
}

function Set-UiBusy {
    param([bool]$Busy)
    foreach ($control in @($script:RunButton, $script:ExportModeButton, $script:ImportModeButton, $script:ChineseButton, $script:EnglishButton,
        $script:SourceTextBox, $script:DestinationTextBox, $script:SourceBrowseButton, $script:DestinationBrowseButton, $script:ChooseSessionsButton,
        $script:AdvancedButton, $script:HistoryOnlyCheckBox, $script:IncludeArtifactsCheckBox, $script:RewriteProviderCheckBox)) {
        $control.Enabled = -not $Busy
    }
    $partial = $null -ne $script:SelectedSessionIds -or ($script:SelectedMode -eq "Import" -and $script:ArchiveIsPartial)
    $script:RestoreAppStateCheckBox.Enabled = -not $Busy -and -not $partial
    $script:TargetProviderTextBox.Enabled = -not $Busy -and $script:RewriteProviderCheckBox.Checked
}

function Handle-CoreLine {
    param([string]$Line)
    if ($Line -match '^progress\tpercent=(?<percent>\d+)\tstage=(?<stage>.+)$') {
        $percent = [Math]::Max(0, [Math]::Min(100, [int]$Matches.percent))
        $script:ProgressBar.Value = $percent
        $script:PercentLabel.Text = "$percent%"
        $script:StatusLabel.Text = T $Matches.stage
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 103, 184)
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
        $script:ProgressBar.Value = 100
        $script:PercentLabel.Text = "100%"
        $script:StatusLabel.Text = T "completed"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 128, 82)
    }
    else {
        $script:StatusLabel.Text = T "failed"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 46, 46)
        if (-not $script:DetailsExpanded) { $script:DetailsExpanded = $true; Update-Layout }
    }
}

function Start-MigrationOperation {
    if ($null -ne $script:ActiveProcess -or -not (Test-UiInput)) { return }
    $script:LogTextBox.Clear()
    $script:ProgressBar.Value = 0
    $script:PercentLabel.Text = "0%"
    $script:StatusLabel.Text = T "starting"
    $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 103, 184)
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
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 46, 46)
        Write-UiLog $_.Exception.Message
        if (-not $script:DetailsExpanded) { $script:DetailsExpanded = $true; Update-Layout }
    }
}

if (-not (Test-Path -LiteralPath $script:CoreScriptPath -PathType Leaf)) {
    [System.Windows.Forms.MessageBox]::Show("Missing core script: $script:CoreScriptPath", "Codex History Migrator", "OK", "Error") | Out-Null
    exit 1
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:MainForm = [System.Windows.Forms.Form]::new()
$script:MainForm.StartPosition = "CenterScreen"
$script:MainForm.ClientSize = [System.Drawing.Size]::new(800, 534)
$script:MainForm.MinimumSize = [System.Drawing.Size]::new(760, 560)
$script:MainForm.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
$script:MainForm.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 9)
$script:MainForm.AutoScaleMode = "None"

$script:TitleLabel = New-UiLabel "" 28 18 500 40
$script:TitleLabel.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 17, [System.Drawing.FontStyle]::Bold)
$script:ChineseButton = New-SegmentButton 676 22 48 30
$script:EnglishButton = New-SegmentButton 724 22 48 30
$script:ExportModeButton = New-SegmentButton 28 76 184
$script:ImportModeButton = New-SegmentButton 212 76 184

$script:SourceLabel = New-UiLabel "" 28 130 240
$script:SourceTextBox = [System.Windows.Forms.TextBox]::new()
$script:SourceTextBox.Location = [System.Drawing.Point]::new(28, 156)
$script:SourceTextBox.Size = [System.Drawing.Size]::new(680, 28)
$script:SourceTextBox.Anchor = "Top, Left, Right"
$script:SourceBrowseButton = New-SegmentButton 718 154 54 30
$script:SourceBrowseButton.Text = "..."
$script:SourceBrowseButton.Anchor = "Top, Right"

$script:SessionsLabel = New-UiLabel "" 28 202 180
$script:SessionSummaryLabel = New-UiLabel "" 28 228 520 32
$script:SessionSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(76, 80, 86)
$script:ChooseSessionsButton = New-SegmentButton 606 224 166 34
$script:ChooseSessionsButton.Anchor = "Top, Right"

$script:DestinationLabel = New-UiLabel "" 28 274 240
$script:DestinationTextBox = [System.Windows.Forms.TextBox]::new()
$script:DestinationTextBox.Location = [System.Drawing.Point]::new(28, 300)
$script:DestinationTextBox.Size = [System.Drawing.Size]::new(680, 28)
$script:DestinationTextBox.Anchor = "Top, Left, Right"
$script:DestinationBrowseButton = New-SegmentButton 718 298 54 30
$script:DestinationBrowseButton.Text = "..."
$script:DestinationBrowseButton.Anchor = "Top, Right"

$script:AdvancedButton = [System.Windows.Forms.Button]::new()
$script:AdvancedButton.Location = [System.Drawing.Point]::new(24, 340)
$script:AdvancedButton.Size = [System.Drawing.Size]::new(220, 30)
$script:AdvancedButton.FlatStyle = "Flat"
$script:AdvancedButton.FlatAppearance.BorderSize = 0
$script:AdvancedButton.TextAlign = "MiddleLeft"
$script:AdvancedButton.Cursor = "Hand"

$script:AdvancedPanel = [System.Windows.Forms.Panel]::new()
$script:AdvancedPanel.BackColor = [System.Drawing.Color]::FromArgb(242, 244, 247)
$script:ExportOptionsPanel = [System.Windows.Forms.Panel]::new()
$script:ExportOptionsPanel.Dock = "Fill"
$script:HistoryOnlyCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:HistoryOnlyCheckBox.Location = [System.Drawing.Point]::new(14, 14)
$script:HistoryOnlyCheckBox.Size = [System.Drawing.Size]::new(300, 24)
$script:IncludeArtifactsCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:IncludeArtifactsCheckBox.Location = [System.Drawing.Point]::new(330, 14)
$script:IncludeArtifactsCheckBox.Size = [System.Drawing.Size]::new(390, 24)
$script:ExportOptionsPanel.Controls.AddRange(@($script:HistoryOnlyCheckBox, $script:IncludeArtifactsCheckBox))

$script:ImportOptionsPanel = [System.Windows.Forms.Panel]::new()
$script:ImportOptionsPanel.Dock = "Fill"
$script:RestoreAppStateCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:RestoreAppStateCheckBox.Location = [System.Drawing.Point]::new(14, 10)
$script:RestoreAppStateCheckBox.Size = [System.Drawing.Size]::new(340, 26)
$script:RewriteProviderCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:RewriteProviderCheckBox.Location = [System.Drawing.Point]::new(370, 10)
$script:RewriteProviderCheckBox.Size = [System.Drawing.Size]::new(350, 26)
$script:RewriteProviderCheckBox.Checked = $true
$script:TargetProviderLabel = New-UiLabel "" 14 48 150
$script:TargetProviderTextBox = [System.Windows.Forms.TextBox]::new()
$script:TargetProviderTextBox.Location = [System.Drawing.Point]::new(170, 46)
$script:TargetProviderTextBox.Size = [System.Drawing.Size]::new(330, 28)
$script:ImportOptionsPanel.Controls.AddRange(@($script:RestoreAppStateCheckBox, $script:RewriteProviderCheckBox, $script:TargetProviderLabel, $script:TargetProviderTextBox))
$script:AdvancedPanel.Controls.AddRange(@($script:ExportOptionsPanel, $script:ImportOptionsPanel))

$script:SafetyLabel = New-UiLabel "" 28 390 450 36
$script:SafetyLabel.ForeColor = [System.Drawing.Color]::FromArgb(157, 79, 18)
$script:RunButton = [System.Windows.Forms.Button]::new()
$script:RunButton.Size = [System.Drawing.Size]::new(166, 40)
$script:RunButton.Anchor = "Top, Right"
$script:RunButton.BackColor = [System.Drawing.Color]::FromArgb(20, 103, 184)
$script:RunButton.ForeColor = [System.Drawing.Color]::White
$script:RunButton.FlatStyle = "Flat"
$script:RunButton.FlatAppearance.BorderSize = 0
$script:RunButton.Cursor = "Hand"

$script:StatusLabel = New-UiLabel "" 28 440 620
$script:PercentLabel = New-UiLabel "0%" 708 440 64
$script:PercentLabel.TextAlign = "MiddleRight"
$script:ProgressBar = [System.Windows.Forms.ProgressBar]::new()
$script:ProgressBar.Size = [System.Drawing.Size]::new(744, 8)
$script:ProgressBar.Anchor = "Top, Left, Right"
$script:ProgressBar.Style = "Blocks"
$script:DetailsButton = [System.Windows.Forms.Button]::new()
$script:DetailsButton.Size = [System.Drawing.Size]::new(180, 30)
$script:DetailsButton.FlatStyle = "Flat"
$script:DetailsButton.FlatAppearance.BorderSize = 0
$script:DetailsButton.TextAlign = "MiddleLeft"
$script:DetailsButton.Cursor = "Hand"
$script:LogTextBox = [System.Windows.Forms.TextBox]::new()
$script:LogTextBox.Multiline = $true
$script:LogTextBox.ReadOnly = $true
$script:LogTextBox.ScrollBars = "Vertical"
$script:LogTextBox.BackColor = [System.Drawing.Color]::White
$script:LogTextBox.Font = [System.Drawing.Font]::new("Consolas", 9)
$script:LogTextBox.Anchor = "Top, Bottom, Left, Right"

$script:MainForm.Controls.AddRange(@(
    $script:TitleLabel, $script:ChineseButton, $script:EnglishButton, $script:ExportModeButton, $script:ImportModeButton,
    $script:SourceLabel, $script:SourceTextBox, $script:SourceBrowseButton, $script:SessionsLabel, $script:SessionSummaryLabel,
    $script:ChooseSessionsButton, $script:DestinationLabel, $script:DestinationTextBox, $script:DestinationBrowseButton,
    $script:AdvancedButton, $script:AdvancedPanel, $script:SafetyLabel, $script:RunButton, $script:StatusLabel,
    $script:PercentLabel, $script:ProgressBar, $script:DetailsButton, $script:LogTextBox
))

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

$script:ExportModeButton.Add_Click({ Set-SelectedMode "Export" })
$script:ImportModeButton.Add_Click({ Set-SelectedMode "Import" })
$script:ChineseButton.Add_Click({ $script:Language = "zh"; Update-Language })
$script:EnglishButton.Add_Click({ $script:Language = "en"; Update-Language })
$script:AdvancedButton.Add_Click({ $script:AdvancedExpanded = -not $script:AdvancedExpanded; Update-Layout })
$script:DetailsButton.Add_Click({ $script:DetailsExpanded = -not $script:DetailsExpanded; Update-Layout })
$script:ChooseSessionsButton.Add_Click({ Show-SessionPicker })
$script:RunButton.Add_Click({ Start-MigrationOperation })
$script:SourceTextBox.Add_TextChanged({ Reset-SessionSelection })
$script:RewriteProviderCheckBox.Add_CheckedChanged({ $script:TargetProviderTextBox.Enabled = $script:RewriteProviderCheckBox.Checked -and $null -eq $script:ActiveProcess })

$script:SourceBrowseButton.Add_Click({
    if ($script:SelectedMode -eq "Export") {
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
        $script:SourceTextBox.Text = if ($script:SelectedMode -eq "Export") { $dialog.SelectedPath } else { $dialog.FileName }
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
[System.Windows.Forms.Application]::Run($script:MainForm)

Remove-SelectionFile
$script:ProcessTimer.Dispose()
$script:ToolTip.Dispose()
$script:MainForm.Dispose()
