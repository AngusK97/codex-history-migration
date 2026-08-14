#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# 核心脚本路径始终相对当前 GUI 脚本解析，避免依赖个人目录。
$script:CoreScriptPath = Join-Path $PSScriptRoot "CodexHistoryMigration.ps1"
$script:SelectedMode = "Export"
$script:ActiveProcess = $null
$script:ProcessTimer = $null
$script:ForceExportOverwrite = $false

if (-not (Test-Path -LiteralPath $script:CoreScriptPath -PathType Leaf)) {
    [System.Windows.Forms.MessageBox]::Show(
        "缺少核心脚本：$script:CoreScriptPath",
        "Codex 历史迁移",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

# 返回默认 Codex 数据目录，不要求该目录当前已经存在。
function Get-DefaultCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return [System.IO.Path]::GetFullPath((Join-Path $userProfile ".codex"))
}

# 按 Windows 命令行规则引用单个进程参数。
function ConvertTo-QuotedProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    $builder.Append('"') | Out-Null
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }

        if ($character -eq [char]34) {
            $builder.Append(('\' * ($backslashCount * 2 + 1))) | Out-Null
            $builder.Append('"') | Out-Null
        }
        else {
            if ($backslashCount -gt 0) {
                $builder.Append(('\' * $backslashCount)) | Out-Null
            }
            $builder.Append($character) | Out-Null
        }
        $backslashCount = 0
    }

    if ($backslashCount -gt 0) {
        $builder.Append(('\' * ($backslashCount * 2))) | Out-Null
    }
    $builder.Append('"') | Out-Null
    return $builder.ToString()
}

# 为标签应用统一的字号、颜色和位置。
function New-UiLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][int]$Width,
        [int]$Height = 24
    )

    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($Width, $Height)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(42, 45, 51)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

# 创建紧凑的操作模式按钮。
function New-ModeButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$X
    )

    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Location = [System.Drawing.Point]::new($X, 78)
    $button.Size = [System.Drawing.Size]::new(148, 36)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $button
}

# 将一段文本追加到只读日志区域。
function Write-UiLog {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $normalized = $Text.TrimEnd([char[]]@([char]13, [char]10))
    $script:LogTextBox.AppendText($normalized + [Environment]::NewLine)
    $script:LogTextBox.SelectionStart = $script:LogTextBox.TextLength
    $script:LogTextBox.ScrollToCaret()
}

# 切换运行中状态并锁定会改变参数的控件。
function Set-UiBusy {
    param([Parameter(Mandatory = $true)][bool]$Busy)

    $script:RunButton.Enabled = -not $Busy
    $script:ExportModeButton.Enabled = -not $Busy
    $script:InspectModeButton.Enabled = -not $Busy
    $script:ImportModeButton.Enabled = -not $Busy
    $script:ArchiveTextBox.Enabled = -not $Busy
    $script:CodexHomeTextBox.Enabled = -not $Busy
    $script:ArchiveBrowseButton.Enabled = -not $Busy
    $script:CodexHomeBrowseButton.Enabled = -not $Busy
    $script:HistoryOnlyCheckBox.Enabled = -not $Busy
    $script:IncludeArtifactsCheckBox.Enabled = -not $Busy
    $script:RestoreAppStateCheckBox.Enabled = -not $Busy
    $script:RewriteProviderCheckBox.Enabled = -not $Busy
    $script:TargetProviderTextBox.Enabled = -not $Busy -and $script:RewriteProviderCheckBox.Checked
    $script:ProgressBar.Style = if ($Busy) {
        [System.Windows.Forms.ProgressBarStyle]::Marquee
    }
    else {
        [System.Windows.Forms.ProgressBarStyle]::Blocks
    }
    $script:ProgressBar.MarqueeAnimationSpeed = if ($Busy) { 28 } else { 0 }
}

# 根据当前模式更新控件文案、选项可见性和强调色。
function Set-SelectedMode {
    param([Parameter(Mandatory = $true)][ValidateSet("Export", "Inspect", "Import")][string]$Mode)

    $script:SelectedMode = $Mode
    $accent = [System.Drawing.Color]::FromArgb(20, 103, 184)
    $inactive = [System.Drawing.Color]::FromArgb(238, 240, 243)
    $inactiveText = [System.Drawing.Color]::FromArgb(56, 60, 67)

    foreach ($button in @($script:ExportModeButton, $script:InspectModeButton, $script:ImportModeButton)) {
        $button.BackColor = $inactive
        $button.ForeColor = $inactiveText
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(207, 211, 217)
    }

    $activeButton = switch ($Mode) {
        "Export" { $script:ExportModeButton }
        "Inspect" { $script:InspectModeButton }
        "Import" { $script:ImportModeButton }
    }
    $activeButton.BackColor = $accent
    $activeButton.ForeColor = [System.Drawing.Color]::White
    $activeButton.FlatAppearance.BorderColor = $accent

    $isInspectMode = $Mode -eq "Inspect"
    $script:HistoryOnlyCheckBox.Visible = $Mode -eq "Export"
    $script:IncludeArtifactsCheckBox.Visible = $Mode -eq "Export"
    $script:RestoreAppStateCheckBox.Visible = $Mode -eq "Import"
    $script:RewriteProviderCheckBox.Visible = $Mode -eq "Import"
    $script:TargetProviderLabel.Visible = $Mode -eq "Import"
    $script:TargetProviderTextBox.Visible = $Mode -eq "Import"
    $script:CodexHomeLabel.Visible = -not $isInspectMode
    $script:CodexHomeTextBox.Visible = -not $isInspectMode
    $script:CodexHomeBrowseButton.Visible = -not $isInspectMode
    $script:OptionsGroup.Visible = -not $isInspectMode
    $script:SafetyLabel.Visible = -not $isInspectMode

    if ($isInspectMode) {
        $script:ArchiveLabel.Location = [System.Drawing.Point]::new(28, 132)
        $script:ArchiveTextBox.Location = [System.Drawing.Point]::new(28, 158)
        $script:ArchiveBrowseButton.Location = [System.Drawing.Point]::new(674, 156)
        $script:RunButton.Location = [System.Drawing.Point]::new(578, 208)
        $script:StatusLabel.Location = [System.Drawing.Point]::new(28, 258)
        $script:ProgressBar.Location = [System.Drawing.Point]::new(28, 288)
        $script:LogTextBox.Location = [System.Drawing.Point]::new(28, 310)
        $script:LogTextBox.Size = [System.Drawing.Size]::new(700, [Math]::Max(120, $script:MainForm.ClientSize.Height - 340))
    }
    else {
        $script:ArchiveLabel.Location = [System.Drawing.Point]::new(28, 200)
        $script:ArchiveTextBox.Location = [System.Drawing.Point]::new(28, 226)
        $script:ArchiveBrowseButton.Location = [System.Drawing.Point]::new(674, 224)
        $isImportMode = $Mode -eq "Import"
        $script:OptionsGroup.Size = [System.Drawing.Size]::new(700, $(if ($isImportMode) { 102 } else { 72 }))
        $actionY = if ($isImportMode) { 382 } else { 352 }
        $script:SafetyLabel.Location = [System.Drawing.Point]::new(28, ($actionY + 4))
        $script:RunButton.Location = [System.Drawing.Point]::new(578, $actionY)
        $script:StatusLabel.Location = [System.Drawing.Point]::new(28, ($actionY + 48))
        $script:ProgressBar.Location = [System.Drawing.Point]::new(28, ($actionY + 78))
        $script:LogTextBox.Location = [System.Drawing.Point]::new(28, ($actionY + 100))
        $script:LogTextBox.Size = [System.Drawing.Size]::new(700, [Math]::Max(80, $script:MainForm.ClientSize.Height - ($actionY + 130)))
    }

    switch ($Mode) {
        "Export" {
            $script:RunButton.Text = "导出 ZIP"
            $script:ArchiveLabel.Text = "ZIP 保存位置"
            $script:StatusLabel.Text = "准备导出"
        }
        "Inspect" {
            $script:RunButton.Text = "校验 ZIP"
            $script:ArchiveLabel.Text = "待校验 ZIP"
            $script:StatusLabel.Text = "准备校验"
        }
        "Import" {
            $script:RunButton.Text = "恢复历史"
            $script:ArchiveLabel.Text = "待恢复 ZIP"
            $script:StatusLabel.Text = "准备恢复"
        }
    }
    $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(76, 80, 86)
}

# 校验界面输入，并决定导出覆盖或恢复确认行为。
function Test-UiInput {
    $archivePath = $script:ArchiveTextBox.Text.Trim()
    $codexHome = $script:CodexHomeTextBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        [System.Windows.Forms.MessageBox]::Show("请选择 ZIP 文件。", "缺少路径", "OK", "Warning") | Out-Null
        return $false
    }
    if ([System.IO.Path]::GetExtension($archivePath) -ine ".zip") {
        [System.Windows.Forms.MessageBox]::Show("文件必须使用 .zip 扩展名。", "路径无效", "OK", "Warning") | Out-Null
        return $false
    }

    if ($script:SelectedMode -ne "Inspect" -and [string]::IsNullOrWhiteSpace($codexHome)) {
        [System.Windows.Forms.MessageBox]::Show("请选择 Codex 数据目录。", "缺少路径", "OK", "Warning") | Out-Null
        return $false
    }
    if ($script:SelectedMode -eq "Export" -and -not (Test-Path -LiteralPath $codexHome -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Codex 数据目录不存在。", "路径无效", "OK", "Warning") | Out-Null
        return $false
    }
    if ($script:SelectedMode -ne "Export" -and -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("ZIP 文件不存在。", "路径无效", "OK", "Warning") | Out-Null
        return $false
    }

    $script:ForceExportOverwrite = $false
    if ($script:SelectedMode -eq "Export" -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "目标 ZIP 已存在，是否覆盖？",
            "确认覆盖",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return $false
        }
        $script:ForceExportOverwrite = $true
    }

    if ($script:SelectedMode -eq "Import") {
        $providerDescription = if ($script:RewriteProviderCheckBox.Checked) {
            if ([string]::IsNullOrWhiteSpace($script:TargetProviderTextBox.Text)) {
                "历史 provider 将自动改为新电脑当前配置。"
            }
            else {
                "历史 provider 将改为 '$($script:TargetProviderTextBox.Text.Trim())'。"
            }
        }
        else {
            "历史 provider 将保持原值。"
        }
        $message = if ($script:RestoreAppStateCheckBox.Checked) {
            "将恢复聊天并替换桌面端状态。$providerDescription`r`n工具会先创建回滚 ZIP。是否继续？"
        }
        else {
            "将把 ZIP 中的聊天合并到所选 Codex 数据目录。$providerDescription`r`n是否继续？"
        }
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $message,
            "确认恢复",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return $false
        }
    }

    return $true
}

# 组装核心脚本参数，所有外部输入都作为独立参数传递。
function Get-CoreProcessArguments {
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:CoreScriptPath,
        "-Mode", $script:SelectedMode,
        "-ArchivePath", $script:ArchiveTextBox.Text.Trim()
    )) {
        $arguments.Add($argument)
    }

    if ($script:SelectedMode -ne "Inspect") {
        $arguments.Add("-CodexHome")
        $arguments.Add($script:CodexHomeTextBox.Text.Trim())
    }
    if ($script:SelectedMode -eq "Export" -and $script:HistoryOnlyCheckBox.Checked) {
        $arguments.Add("-HistoryOnly")
    }
    if ($script:SelectedMode -eq "Export" -and $script:IncludeArtifactsCheckBox.Checked) {
        $arguments.Add("-IncludeArtifacts")
    }
    if ($script:SelectedMode -eq "Export" -and $script:ForceExportOverwrite) {
        $arguments.Add("-Force")
    }
    if ($script:SelectedMode -eq "Import" -and $script:RestoreAppStateCheckBox.Checked) {
        $arguments.Add("-RestoreAppState")
    }
    if ($script:SelectedMode -eq "Import" -and $script:RewriteProviderCheckBox.Checked) {
        $arguments.Add("-RewriteModelProvider")
        if (-not [string]::IsNullOrWhiteSpace($script:TargetProviderTextBox.Text)) {
            $arguments.Add("-TargetModelProvider")
            $arguments.Add($script:TargetProviderTextBox.Text.Trim())
        }
    }

    return ($arguments | ForEach-Object { ConvertTo-QuotedProcessArgument -Value $_ }) -join " "
}

# 启动核心脚本；计时器在进程退出后回收输出并刷新界面。
function Start-MigrationOperation {
    if ($null -ne $script:ActiveProcess) {
        return
    }
    if (-not (Test-UiInput)) {
        return
    }

    $script:LogTextBox.Clear()
    Write-UiLog -Text ("[{0}] {1} started" -f [DateTime]::Now.ToString("HH:mm:ss"), $script:SelectedMode)
    $script:StatusLabel.Text = "正在处理..."
    $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 103, 184)
    Set-UiBusy -Busy $true

    try {
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
        if (-not $script:ActiveProcess.Start()) {
            throw "无法启动核心迁移进程。"
        }
        $script:ProcessTimer.Start()
    }
    catch {
        if ($null -ne $script:ActiveProcess) {
            $script:ActiveProcess.Dispose()
            $script:ActiveProcess = $null
        }
        Set-UiBusy -Busy $false
        $script:StatusLabel.Text = "启动失败"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 46, 46)
        Write-UiLog -Text $_.Exception.Message
    }
}

# 核心进程结束后读取标准输出和错误流，避免 GUI 阻塞。
function Complete-MigrationOperation {
    if ($null -eq $script:ActiveProcess -or -not $script:ActiveProcess.HasExited) {
        return
    }

    $script:ProcessTimer.Stop()
    $standardOutput = $script:ActiveProcess.StandardOutput.ReadToEnd()
    $standardError = $script:ActiveProcess.StandardError.ReadToEnd()
    $exitCode = $script:ActiveProcess.ExitCode
    $script:ActiveProcess.Dispose()
    $script:ActiveProcess = $null

    Write-UiLog -Text $standardOutput
    Write-UiLog -Text $standardError
    Set-UiBusy -Busy $false
    if ($exitCode -eq 0) {
        $script:StatusLabel.Text = "操作完成"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 128, 82)
        Write-UiLog -Text ("[{0}] completed" -f [DateTime]::Now.ToString("HH:mm:ss"))
    }
    else {
        $script:StatusLabel.Text = "操作失败"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 46, 46)
        Write-UiLog -Text ("[{0}] failed with exit code {1}" -f [DateTime]::Now.ToString("HH:mm:ss"), $exitCode)
    }
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# 主窗口使用固定工具布局，并允许日志区域随窗口缩放。
$script:MainForm = [System.Windows.Forms.Form]::new()
$script:MainForm.Text = "Codex 历史迁移"
$script:MainForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$script:MainForm.ClientSize = [System.Drawing.Size]::new(760, 600)
$script:MainForm.MinimumSize = [System.Drawing.Size]::new(720, 560)
$script:MainForm.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
$script:MainForm.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 9)
$script:MainForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$titleLabel = New-UiLabel -Text "Codex 历史迁移" -X 28 -Y 20 -Width 420 -Height 38
$titleLabel.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 17, [System.Drawing.FontStyle]::Bold)
$script:MainForm.Controls.Add($titleLabel)

$script:ExportModeButton = New-ModeButton -Text "导出" -X 28
$script:InspectModeButton = New-ModeButton -Text "校验" -X 176
$script:ImportModeButton = New-ModeButton -Text "恢复" -X 324
$script:MainForm.Controls.AddRange(@($script:ExportModeButton, $script:InspectModeButton, $script:ImportModeButton))

$script:CodexHomeLabel = New-UiLabel -Text "Codex 数据目录" -X 28 -Y 132 -Width 150
$script:CodexHomeTextBox = [System.Windows.Forms.TextBox]::new()
$script:CodexHomeTextBox.Location = [System.Drawing.Point]::new(28, 158)
$script:CodexHomeTextBox.Size = [System.Drawing.Size]::new(636, 28)
$script:CodexHomeTextBox.Anchor = "Top, Left, Right"
$script:CodexHomeTextBox.Text = Get-DefaultCodexHome
$script:CodexHomeBrowseButton = [System.Windows.Forms.Button]::new()
$script:CodexHomeBrowseButton.Text = "..."
$script:CodexHomeBrowseButton.Location = [System.Drawing.Point]::new(674, 156)
$script:CodexHomeBrowseButton.Size = [System.Drawing.Size]::new(54, 30)
$script:CodexHomeBrowseButton.Anchor = "Top, Right"
$script:CodexHomeBrowseButton.FlatStyle = "Flat"
$script:MainForm.Controls.AddRange(@($script:CodexHomeLabel, $script:CodexHomeTextBox, $script:CodexHomeBrowseButton))

$script:ArchiveLabel = New-UiLabel -Text "ZIP 保存位置" -X 28 -Y 200 -Width 150
$script:ArchiveTextBox = [System.Windows.Forms.TextBox]::new()
$script:ArchiveTextBox.Location = [System.Drawing.Point]::new(28, 226)
$script:ArchiveTextBox.Size = [System.Drawing.Size]::new(636, 28)
$script:ArchiveTextBox.Anchor = "Top, Left, Right"
$desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = (Get-Location).Path }
$script:ArchiveTextBox.Text = Join-Path $desktop ("codex-history-{0}.zip" -f [DateTime]::Now.ToString("yyyyMMdd-HHmmss"))
$script:ArchiveBrowseButton = [System.Windows.Forms.Button]::new()
$script:ArchiveBrowseButton.Text = "..."
$script:ArchiveBrowseButton.Location = [System.Drawing.Point]::new(674, 224)
$script:ArchiveBrowseButton.Size = [System.Drawing.Size]::new(54, 30)
$script:ArchiveBrowseButton.Anchor = "Top, Right"
$script:ArchiveBrowseButton.FlatStyle = "Flat"
$script:MainForm.Controls.AddRange(@($script:ArchiveLabel, $script:ArchiveTextBox, $script:ArchiveBrowseButton))

$script:OptionsGroup = [System.Windows.Forms.GroupBox]::new()
$script:OptionsGroup.Text = "选项"
$script:OptionsGroup.Location = [System.Drawing.Point]::new(28, 274)
$script:OptionsGroup.Size = [System.Drawing.Size]::new(700, 72)
$script:OptionsGroup.Anchor = "Top, Left, Right"
$script:HistoryOnlyCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:HistoryOnlyCheckBox.Text = "仅聊天历史"
$script:HistoryOnlyCheckBox.Location = [System.Drawing.Point]::new(18, 30)
$script:HistoryOnlyCheckBox.AutoSize = $true
$script:IncludeArtifactsCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:IncludeArtifactsCheckBox.Text = "包含生成图片与可视化"
$script:IncludeArtifactsCheckBox.Location = [System.Drawing.Point]::new(160, 30)
$script:IncludeArtifactsCheckBox.AutoSize = $true
$script:RestoreAppStateCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:RestoreAppStateCheckBox.Text = "替换已有桌面端状态"
$script:RestoreAppStateCheckBox.Location = [System.Drawing.Point]::new(18, 30)
$script:RestoreAppStateCheckBox.AutoSize = $true
$script:RewriteProviderCheckBox = [System.Windows.Forms.CheckBox]::new()
$script:RewriteProviderCheckBox.Text = "改为新电脑 Provider"
$script:RewriteProviderCheckBox.Location = [System.Drawing.Point]::new(220, 30)
$script:RewriteProviderCheckBox.AutoSize = $true
$script:RewriteProviderCheckBox.Checked = $true
$script:TargetProviderLabel = New-UiLabel -Text "目标 Provider" -X 18 -Y 60 -Width 112 -Height 24
$script:TargetProviderTextBox = [System.Windows.Forms.TextBox]::new()
$script:TargetProviderTextBox.Location = [System.Drawing.Point]::new(136, 58)
$script:TargetProviderTextBox.Size = [System.Drawing.Size]::new(300, 28)
$script:OptionsGroup.Controls.AddRange(@(
    $script:HistoryOnlyCheckBox,
    $script:IncludeArtifactsCheckBox,
    $script:RestoreAppStateCheckBox,
    $script:RewriteProviderCheckBox,
    $script:TargetProviderLabel,
    $script:TargetProviderTextBox
))
$script:MainForm.Controls.Add($script:OptionsGroup)

$script:SafetyLabel = New-UiLabel -Text "Codex / ChatGPT 需处于关闭状态" -X 28 -Y 356 -Width 360
$script:SafetyLabel.ForeColor = [System.Drawing.Color]::FromArgb(157, 79, 18)
$script:MainForm.Controls.Add($script:SafetyLabel)

$script:RunButton = [System.Windows.Forms.Button]::new()
$script:RunButton.Text = "导出 ZIP"
$script:RunButton.Location = [System.Drawing.Point]::new(578, 352)
$script:RunButton.Size = [System.Drawing.Size]::new(150, 36)
$script:RunButton.Anchor = "Top, Right"
$script:RunButton.BackColor = [System.Drawing.Color]::FromArgb(20, 103, 184)
$script:RunButton.ForeColor = [System.Drawing.Color]::White
$script:RunButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:RunButton.FlatAppearance.BorderSize = 0
$script:RunButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:MainForm.Controls.Add($script:RunButton)

$script:StatusLabel = New-UiLabel -Text "准备导出" -X 28 -Y 400 -Width 300
$script:ProgressBar = [System.Windows.Forms.ProgressBar]::new()
$script:ProgressBar.Location = [System.Drawing.Point]::new(28, 430)
$script:ProgressBar.Size = [System.Drawing.Size]::new(700, 6)
$script:ProgressBar.Anchor = "Top, Left, Right"
$script:ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
$script:MainForm.Controls.AddRange(@($script:StatusLabel, $script:ProgressBar))

$script:LogTextBox = [System.Windows.Forms.TextBox]::new()
$script:LogTextBox.Location = [System.Drawing.Point]::new(28, 452)
$script:LogTextBox.Size = [System.Drawing.Size]::new(700, 118)
$script:LogTextBox.Anchor = "Top, Bottom, Left, Right"
$script:LogTextBox.Multiline = $true
$script:LogTextBox.ReadOnly = $true
$script:LogTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:LogTextBox.BackColor = [System.Drawing.Color]::White
$script:LogTextBox.Font = [System.Drawing.Font]::new("Consolas", 9)
$script:MainForm.Controls.Add($script:LogTextBox)

$toolTip = [System.Windows.Forms.ToolTip]::new()
$toolTip.SetToolTip($script:CodexHomeBrowseButton, "选择 Codex 数据目录")
$toolTip.SetToolTip($script:ArchiveBrowseButton, "选择 ZIP 文件")
$toolTip.SetToolTip($script:HistoryOnlyCheckBox, "不包含桌面端状态数据库")
$toolTip.SetToolTip($script:RestoreAppStateCheckBox, "目标端已有历史时也替换桌面端状态")
$toolTip.SetToolTip($script:RewriteProviderCheckBox, "只重写迁入会话，不修改新电脑原有历史")
$toolTip.SetToolTip($script:TargetProviderTextBox, "留空时读取新电脑 config.toml；未配置则使用 openai")

$script:ProcessTimer = [System.Windows.Forms.Timer]::new()
$script:ProcessTimer.Interval = 250
$script:ProcessTimer.Add_Tick({ Complete-MigrationOperation })

$script:ExportModeButton.Add_Click({ Set-SelectedMode -Mode "Export" })
$script:InspectModeButton.Add_Click({ Set-SelectedMode -Mode "Inspect" })
$script:ImportModeButton.Add_Click({ Set-SelectedMode -Mode "Import" })
$script:RunButton.Add_Click({ Start-MigrationOperation })
$script:RewriteProviderCheckBox.Add_CheckedChanged({
    $script:TargetProviderTextBox.Enabled = $script:RewriteProviderCheckBox.Checked -and $null -eq $script:ActiveProcess
})

$script:CodexHomeBrowseButton.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "选择 Codex 数据目录"
    if (Test-Path -LiteralPath $script:CodexHomeTextBox.Text -PathType Container) {
        $dialog.SelectedPath = $script:CodexHomeTextBox.Text
    }
    if ($dialog.ShowDialog($script:MainForm) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:CodexHomeTextBox.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
})

$script:ArchiveBrowseButton.Add_Click({
    if ($script:SelectedMode -eq "Export") {
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        $dialog.Title = "保存 Codex 历史迁移包"
        $dialog.Filter = "ZIP 归档 (*.zip)|*.zip"
        $dialog.DefaultExt = "zip"
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $false
        if (-not [string]::IsNullOrWhiteSpace($script:ArchiveTextBox.Text)) {
            $dialog.FileName = [System.IO.Path]::GetFileName($script:ArchiveTextBox.Text)
            $parent = Split-Path -Parent $script:ArchiveTextBox.Text
            if (Test-Path -LiteralPath $parent -PathType Container) { $dialog.InitialDirectory = $parent }
        }
    }
    else {
        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = if ($script:SelectedMode -eq "Inspect") { "选择待校验 ZIP" } else { "选择待恢复 ZIP" }
        $dialog.Filter = "ZIP 归档 (*.zip)|*.zip"
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
    }

    if ($dialog.ShowDialog($script:MainForm) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:ArchiveTextBox.Text = $dialog.FileName
    }
    $dialog.Dispose()
})

$script:MainForm.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:ActiveProcess) {
        [System.Windows.Forms.MessageBox]::Show(
            "操作仍在进行，完成后才能关闭窗口。",
            "Codex 历史迁移",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        $eventArgs.Cancel = $true
    }
})

Set-SelectedMode -Mode "Export"
[System.Windows.Forms.Application]::Run($script:MainForm)

$script:ProcessTimer.Dispose()
$toolTip.Dispose()
$script:MainForm.Dispose()
