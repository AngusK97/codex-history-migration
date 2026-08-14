#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("Export", "Import", "Inspect", "List")]
    [string]$Mode,

    [string]$ArchivePath = "",

    [string]$CodexHome = "",

    [switch]$HistoryOnly,

    [switch]$IncludeArtifacts,

    [switch]$RestoreAppState,

    [switch]$RewriteModelProvider,

    [string]$TargetModelProvider = "",

    [string]$SessionSelectionFile = "",

    [switch]$AllowRunningCodex,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# 工具和归档格式版本用于拒绝不兼容的迁移包。
$script:ToolName = "CodexHistoryMigration"
$script:ToolVersion = "1.1.0"
$script:SchemaVersion = 1
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:SensitiveTopLevelNames = @(
    "auth.json",
    "auth.json.bak",
    ".sandbox-secrets",
    "mcp-oauth-locks",
    "cap_sid"
)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# 向 GUI 输出稳定、可解析的确定型进度事件。
function Write-ProgressEvent {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$Percent,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    Write-Host ("progress`tpercent={0}`tstage={1}" -f $Percent, $Stage)
}

# 从 UTF-8 文本读取会话 ID；每行一个 ID，并拒绝空选择与重复之外的异常内容。
function Read-SessionSelection {
    param([AllowEmptyString()][string]$SelectionFile)

    if ([string]::IsNullOrWhiteSpace($SelectionFile)) {
        return $null
    }

    $resolved = Resolve-FullPath -PathValue $SelectionFile
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Session selection file does not exist: $resolved"
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [System.IO.File]::ReadAllLines($resolved, [System.Text.Encoding]::UTF8)) {
        $id = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($id.Length -gt 128 -or $id -match '[\x00-\x1f\x7f]') {
            throw "Session selection contains an invalid id."
        }
        $ids.Add($id) | Out-Null
    }
    if ($ids.Count -eq 0) {
        throw "Select at least one session."
    }

    return $ids
}

# 返回不要求目标已经存在的绝对路径。
function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
}

# 按 CODEX_HOME 或当前用户目录确定默认 Codex 数据目录。
function Get-DefaultCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return Resolve-FullPath -PathValue $env:CODEX_HOME
    }

    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw "Cannot resolve the current user profile directory. Pass -CodexHome explicitly."
    }

    return [System.IO.Path]::GetFullPath((Join-Path $userProfile ".codex"))
}

# 读取 TOML 中用于 provider/profile 的简单字符串值。
function ConvertFrom-TomlStringValue {
    param([Parameter(Mandatory = $true)][string]$RawValue)

    $trimmed = $RawValue.Trim()
    $match = [regex]::Match($trimmed, '^(?<quote>["''])(?<value>.*)\k<quote>\s*(?:#.*)?$')
    if (-not $match.Success) {
        return ""
    }

    return $match.Groups["value"].Value
}

# 从目标电脑的用户级配置解析当前 provider，未配置时遵循 Codex 的 openai 默认值。
function Get-ConfiguredModelProvider {
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $configPath = Join-Path $TargetRoot "config.toml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return "openai"
    }
    Assert-PathWithinRootWithoutReparsePoint -Root $TargetRoot -PathValue $configPath -Operation "Provider config"

    $section = ""
    $rootProvider = ""
    $activeProfile = ""
    $profileProviders = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($configPath, [System.Text.Encoding]::UTF8)) {
        $sectionMatch = [regex]::Match($line, '^\s*\[(?<section>[^\]]+)\]\s*(?:#.*)?$')
        if ($sectionMatch.Success) {
            $section = $sectionMatch.Groups["section"].Value.Trim()
            continue
        }

        $settingMatch = [regex]::Match($line, '^\s*(?<key>model_provider|profile)\s*=\s*(?<value>.+)$')
        if (-not $settingMatch.Success) {
            continue
        }

        $value = ConvertFrom-TomlStringValue -RawValue $settingMatch.Groups["value"].Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $key = $settingMatch.Groups["key"].Value
        if ([string]::IsNullOrWhiteSpace($section)) {
            if ($key -eq "model_provider") { $rootProvider = $value }
            if ($key -eq "profile") { $activeProfile = $value }
            continue
        }

        if ($key -eq "model_provider" -and $section -match '^profiles\.(?<name>.+)$') {
            $profileName = $Matches["name"].Trim('"', "'")
            $profileProviders[$profileName] = $value
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($activeProfile) -and $profileProviders.ContainsKey($activeProfile)) {
        return [string]$profileProviders[$activeProfile]
    }
    if (-not [string]::IsNullOrWhiteSpace($rootProvider)) {
        return $rootProvider
    }

    return "openai"
}

# 校验并返回导入时应写入历史记录的目标 provider。
function Resolve-TargetModelProvider {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [AllowEmptyString()][string]$RequestedProvider
    )

    $provider = if ([string]::IsNullOrWhiteSpace($RequestedProvider)) {
        Get-ConfiguredModelProvider -TargetRoot $TargetRoot
    }
    else {
        $RequestedProvider.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($provider) -or $provider.Length -gt 128 -or $provider -match '[\x00-\x1f\x7f]') {
        throw "Invalid target model provider id. Use 1-128 visible characters."
    }

    return $provider
}

# 生成兼容 Windows PowerShell 5.1 的相对路径。
function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $baseUri = [System.Uri]::new($BasePath.TrimEnd([char[]]@([char]92, [char]47)) + $separator)
    $targetUri = [System.Uri]::new($TargetPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', $separator)
}

# 创建可验证边界的临时目录。
function New-SafeTemporaryDirectory {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $directory = Join-Path $tempRoot ("codex-history-migration-{0}" -f [Guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    return $directory
}

# 只允许删除本工具在系统临时目录下创建的目录。
function Remove-SafeTemporaryDirectory {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
        return
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($PathValue)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@([char]92, [char]47))
    $requiredPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar + "codex-history-migration-"
    if (-not $resolvedPath.StartsWith($requiredPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a directory outside the tool temporary boundary: $resolvedPath"
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

# 导出或恢复时要求 Codex 与 ChatGPT 桌面端不再写入数据库。
function Assert-CodexStopped {
    param([bool]$AllowRunning)

    if ($AllowRunning) {
        return
    }

    $processNames = @("Codex", "codex-app-server", "ChatGPT")
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $processNames -contains $_.ProcessName })
    if ($running.Count -gt 0) {
        $description = ($running | ForEach-Object { "{0}(PID={1})" -f $_.ProcessName, $_.Id }) -join ", "
        throw "Codex-related processes are still running: $description. Close them and retry, or use -AllowRunningCodex only when you accept an inconsistent snapshot risk."
    }
}

# 拒绝绝对路径、设备名、ADS 和不可移植的相对路径片段。
function Assert-SafePortableRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized.StartsWith('/') -or $normalized.Contains(':')) {
        throw "Unsafe or non-portable relative path: $RelativePath"
    }

    $reservedNames = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$'
    foreach ($segment in $normalized -split '/') {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
            $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match $reservedNames) {
            throw "Unsafe or non-portable relative path: $RelativePath"
        }
    }
}

# 拒绝把认证、沙箱密钥或 OAuth 状态放入迁移包。
function Assert-NonSensitiveRelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    Assert-SafePortableRelativePath -RelativePath $RelativePath
    $normalized = $RelativePath.Replace('\', '/').TrimStart('/')
    $topLevel = ($normalized -split '/')[0]
    if ($script:SensitiveTopLevelNames -contains $topLevel) {
        throw "Sensitive Codex data must not be included in a history archive: $RelativePath"
    }
}

# 确认文件系统路径留在指定根目录内，并拒绝路径链上的 junction 或符号链接。
function Assert-PathWithinRootWithoutReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $rootPath = [System.IO.Path]::GetPathRoot($rootFull)
    if ($rootFull.Length -gt $rootPath.Length) {
        $rootFull = $rootFull.TrimEnd([char[]]@([char]92, [char]47))
    }
    $pathFull = [System.IO.Path]::GetFullPath($PathValue)
    $rootPrefix = $rootFull.TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Operation path escapes its allowed root: $pathFull"
    }

    $current = $pathFull
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Operation path contains a reparse point: $current"
            }
        }

        if ($current.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            throw "$Operation path cannot be traced back to its allowed root: $pathFull"
        }
        $parentRoot = [System.IO.Path]::GetPathRoot($parent)
        $current = if ($parent.Length -gt $parentRoot.Length) {
            $parent.TrimEnd([char[]]@([char]92, [char]47))
        }
        else {
            $parent
        }
    }
}

# 将单个来源文件复制到暂存区并记录分类。
function Copy-SourceFileToStage {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SeenPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Entries
    )

    Assert-PathWithinRootWithoutReparsePoint -Root $SourceRoot -PathValue $SourceFile -Operation "Export source"
    $relativePath = (Get-RelativePath -BasePath $SourceRoot -TargetPath $SourceFile).Replace('\', '/')
    Assert-NonSensitiveRelativePath -RelativePath $relativePath
    if (-not $SeenPaths.Add($relativePath)) {
        return
    }

    $destination = Join-Path $DataRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    }

    Copy-Item -LiteralPath $SourceFile -Destination $destination
    $copiedFile = Get-Item -LiteralPath $destination
    $Entries.Add([PSCustomObject]@{
        path = $relativePath
        category = $Category
        size = [Int64]$copiedFile.Length
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

# 将目录中的普通文件递归加入暂存区。
function Copy-SourceDirectoryToStage {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SeenPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Entries,
        [AllowNull()][System.Collections.Generic.HashSet[string]]$SelectedSessionIds
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        return
    }

    foreach ($item in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force) {
        Assert-PathWithinRootWithoutReparsePoint -Root $SourceRoot -PathValue $item.FullName -Operation "Export source"
        if (-not $item.PSIsContainer) {
            if ($null -ne $SelectedSessionIds) {
                $sessionId = Get-HistorySessionId -SourceFile $item.FullName
                if ([string]::IsNullOrWhiteSpace($sessionId) -or -not $SelectedSessionIds.Contains($sessionId)) {
                    continue
                }
            }
            Copy-SourceFileToStage -SourceFile $item.FullName -SourceRoot $SourceRoot -DataRoot $DataRoot `
                -Category $Category -SeenPaths $SeenPaths -Entries $Entries
        }
    }
}

# 写入只包含指定会话的标题索引。
function Copy-FilteredSessionIndexToStage {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$SelectedSessionIds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SeenPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Entries
    )

    $sourceIndex = Join-Path $SourceRoot "session_index.jsonl"
    if (-not (Test-Path -LiteralPath $sourceIndex -PathType Leaf)) { return }

    $destination = Join-Path $DataRoot "session_index.jsonl"
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($sourceIndex, [System.Text.Encoding]::UTF8)) {
        try { $id = [string](($line | ConvertFrom-Json).id) } catch { $id = "" }
        if (-not [string]::IsNullOrWhiteSpace($id) -and $SelectedSessionIds.Contains($id)) {
            $lines.Add($line)
        }
    }
    Write-LinesAtomically -Destination $destination -Lines @($lines)
    $file = Get-Item -LiteralPath $destination
    $SeenPaths.Add("session_index.jsonl") | Out-Null
    $Entries.Add([PSCustomObject]@{
        path = "session_index.jsonl"
        category = "historyIndex"
        size = [Int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

# 收集受支持的历史、界面状态与可选聊天产物。
function Copy-CodexDataToStage {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][bool]$IncludeAppState,
        [Parameter(Mandatory = $true)][bool]$IncludeChatArtifacts,
        [AllowNull()][System.Collections.Generic.HashSet[string]]$SelectedSessionIds
    )

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($directoryName in @("sessions", "archived_sessions")) {
        Copy-SourceDirectoryToStage -SourceDirectory (Join-Path $SourceRoot $directoryName) -SourceRoot $SourceRoot `
            -DataRoot $DataRoot -Category "history" -SeenPaths $seenPaths -Entries $entries `
            -SelectedSessionIds $SelectedSessionIds
    }

    $sessionIndex = Join-Path $SourceRoot "session_index.jsonl"
    if ($null -ne $SelectedSessionIds) {
        Copy-FilteredSessionIndexToStage -SourceRoot $SourceRoot -DataRoot $DataRoot `
            -SelectedSessionIds $SelectedSessionIds -SeenPaths $seenPaths -Entries $entries
    }
    elseif (Test-Path -LiteralPath $sessionIndex -PathType Leaf) {
        Copy-SourceFileToStage -SourceFile $sessionIndex -SourceRoot $SourceRoot -DataRoot $DataRoot `
            -Category "historyIndex" -SeenPaths $seenPaths -Entries $entries
    }

    if ($IncludeAppState) {
        $globalState = Join-Path $SourceRoot ".codex-global-state.json"
        if ($null -eq $SelectedSessionIds -and (Test-Path -LiteralPath $globalState -PathType Leaf)) {
            Copy-SourceFileToStage -SourceFile $globalState -SourceRoot $SourceRoot -DataRoot $DataRoot `
                -Category "appState" -SeenPaths $seenPaths -Entries $entries
        }

        foreach ($stateFile in Get-ChildItem -LiteralPath $SourceRoot -File -Filter "state_*.sqlite*" -ErrorAction SilentlyContinue) {
            Copy-SourceFileToStage -SourceFile $stateFile.FullName -SourceRoot $SourceRoot -DataRoot $DataRoot `
                -Category "appState" -SeenPaths $seenPaths -Entries $entries
        }

        $sqliteRoot = Join-Path $SourceRoot "sqlite"
        if (Test-Path -LiteralPath $sqliteRoot -PathType Container) {
            foreach ($stateFile in Get-ChildItem -LiteralPath $sqliteRoot -File -Filter "state_*.sqlite*" -ErrorAction SilentlyContinue) {
                Copy-SourceFileToStage -SourceFile $stateFile.FullName -SourceRoot $SourceRoot -DataRoot $DataRoot `
                    -Category "appState" -SeenPaths $seenPaths -Entries $entries
            }
        }
    }

    if ($IncludeChatArtifacts -and $null -eq $SelectedSessionIds) {
        foreach ($directoryName in @("generated_images", "visualizations")) {
            Copy-SourceDirectoryToStage -SourceDirectory (Join-Path $SourceRoot $directoryName) -SourceRoot $SourceRoot `
                -DataRoot $DataRoot -Category "artifact" -SeenPaths $seenPaths -Entries $entries -SelectedSessionIds $null
        }
    }

    if ($null -ne $SelectedSessionIds -and $IncludeAppState) {
        Filter-StagedThreadIndexes -DataRoot $DataRoot -SelectedSessionIds $SelectedSessionIds -Entries $entries
    }

    return @($entries)
}

# 创建带清单和逐文件 SHA-256 的 ZIP 迁移包。
function New-HistoryArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationArchive,
        [Parameter(Mandatory = $true)][bool]$IncludeAppState,
        [Parameter(Mandatory = $true)][bool]$IncludeChatArtifacts,
        [Parameter(Mandatory = $true)][bool]$AllowOverwrite,
        [AllowNull()][System.Collections.Generic.HashSet[string]]$SelectedSessionIds,
        [bool]$EmitProgress = $true
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Codex home does not exist: $SourceRoot"
    }
    Assert-PathWithinRootWithoutReparsePoint -Root $SourceRoot -PathValue $SourceRoot -Operation "Export source"

    if ([System.IO.Path]::GetExtension($DestinationArchive) -ine ".zip") {
        throw "Archive path must end with .zip: $DestinationArchive"
    }

    $archiveParent = Split-Path -Parent $DestinationArchive
    if (-not (Test-Path -LiteralPath $archiveParent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($archiveParent) | Out-Null
    }

    if (Test-Path -LiteralPath $DestinationArchive -PathType Leaf) {
        if (-not $AllowOverwrite) {
            throw "Archive already exists. Add -Force to overwrite it: $DestinationArchive"
        }

        [System.IO.File]::Delete($DestinationArchive)
    }

    $temporaryRoot = New-SafeTemporaryDirectory
    try {
        $packageRoot = Join-Path $temporaryRoot "package"
        $dataRoot = Join-Path $packageRoot "data"
        [System.IO.Directory]::CreateDirectory($dataRoot) | Out-Null

        if ($EmitProgress) { Write-ProgressEvent -Percent 12 -Stage "ScanningSessions" }
        $entries = @(Copy-CodexDataToStage -SourceRoot $SourceRoot -DataRoot $dataRoot `
            -IncludeAppState $IncludeAppState -IncludeChatArtifacts $IncludeChatArtifacts `
            -SelectedSessionIds $SelectedSessionIds)
        if ($entries.Count -eq 0) {
            throw "No supported Codex history files were found in: $SourceRoot"
        }

        if ($null -ne $SelectedSessionIds) {
            $exportedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in @($entries | Where-Object { $_.category -eq "history" })) {
                $sessionFile = Join-Path $dataRoot ([string]$entry.path).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $sessionId = Get-HistorySessionId -SourceFile $sessionFile
                if (-not [string]::IsNullOrWhiteSpace($sessionId)) { $exportedIds.Add($sessionId) | Out-Null }
            }
            foreach ($selectedId in $SelectedSessionIds) {
                if (-not $exportedIds.Contains($selectedId)) {
                    throw "Selected session was not found in the Codex data folder: $selectedId"
                }
            }
        }

        $sessionCount = @($entries | Where-Object { $_.path -like "sessions/*.jsonl" }).Count
        $archivedSessionCount = @($entries | Where-Object { $_.path -like "archived_sessions/*.jsonl" }).Count
        if ($EmitProgress) { Write-ProgressEvent -Percent 70 -Stage "CreatingManifest" }
        $manifest = [ordered]@{
            schemaVersion = $script:SchemaVersion
            tool = $script:ToolName
            toolVersion = $script:ToolVersion
            createdAtUtc = [DateTime]::UtcNow.ToString("o")
            sourcePlatform = [Environment]::OSVersion.Platform.ToString()
            includesAppState = $IncludeAppState
            includesArtifacts = ($IncludeChatArtifacts -and $null -eq $SelectedSessionIds)
            isPartialHistory = ($null -ne $SelectedSessionIds)
            sessionCount = $sessionCount
            archivedSessionCount = $archivedSessionCount
            fileCount = $entries.Count
            files = @($entries | Sort-Object path)
        }

        $manifestPath = Join-Path $packageRoot "manifest.json"
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
        if ($EmitProgress) { Write-ProgressEvent -Percent 84 -Stage "CompressingArchive" }
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $packageRoot,
            $DestinationArchive,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false
        )

        if (-not (Test-Path -LiteralPath $DestinationArchive -PathType Leaf)) {
            throw "Archive creation did not produce the expected file: $DestinationArchive"
        }

        return [PSCustomObject]@{
            ArchivePath = $DestinationArchive
            ArchiveBytes = (Get-Item -LiteralPath $DestinationArchive).Length
            SessionCount = $sessionCount
            ArchivedSessionCount = $archivedSessionCount
            FileCount = $entries.Count
        }
    }
    finally {
        Remove-SafeTemporaryDirectory -PathValue $temporaryRoot
    }
}

# 验证 ZIP 条目不会写出解压目录，并限制异常超大迁移包。
function Assert-SafeArchiveEntries {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$ExtractionRoot
    )

    $root = [System.IO.Path]::GetFullPath($ExtractionRoot).TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
    $totalBytes = [Int64]0
    if ($Archive.Entries.Count -gt 2000000) {
        throw "Archive contains too many entries: $($Archive.Entries.Count)"
    }

    foreach ($entry in $Archive.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        Assert-SafePortableRelativePath -RelativePath $name
        $unixFileType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        $windowsAttributes = $entry.ExternalAttributes -band 0xFFFF
        if ($unixFileType -eq 0xA000 -or ($windowsAttributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Archive contains a link or reparse-point entry: $name"
        }

        $destination = [System.IO.Path]::GetFullPath((Join-Path $ExtractionRoot $name.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
        if (-not $destination.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Archive entry escapes the extraction directory: $name"
        }

        $totalBytes += [Int64]$entry.Length
        if ($totalBytes -gt 100GB) {
            throw "Archive expands beyond the 100 GiB safety limit."
        }
    }
}

# 解压并核对格式、文件清单、大小、哈希和敏感路径。
function Expand-AndValidateArchive {
    param([Parameter(Mandatory = $true)][string]$SourceArchive)

    if (-not (Test-Path -LiteralPath $SourceArchive -PathType Leaf)) {
        throw "Archive does not exist: $SourceArchive"
    }

    $temporaryRoot = New-SafeTemporaryDirectory
    $extractionRoot = Join-Path $temporaryRoot "extracted"
    [System.IO.Directory]::CreateDirectory($extractionRoot) | Out-Null

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($SourceArchive)
        try {
            Assert-SafeArchiveEntries -Archive $zip -ExtractionRoot $extractionRoot
            $manifestEntries = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq "manifest.json" })
            if ($manifestEntries.Count -ne 1) {
                throw "Archive must contain exactly one manifest.json at its root."
            }
        }
        finally {
            $zip.Dispose()
        }

        [System.IO.Compression.ZipFile]::ExtractToDirectory($SourceArchive, $extractionRoot)
        $manifestPath = Join-Path $extractionRoot "manifest.json"
        $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne $script:SchemaVersion) {
            throw "Unsupported archive schema version: $($manifest.schemaVersion)"
        }
        if ([string]$manifest.tool -ne $script:ToolName) {
            throw "Archive was not created by $($script:ToolName)."
        }

        $dataRoot = Join-Path $extractionRoot "data"
        $expectedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($manifest.files)) {
            $relativePath = ([string]$entry.path).Replace('\', '/').TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($relativePath) -or ($relativePath -split '/') -contains '..') {
                throw "Manifest contains an invalid data path: $relativePath"
            }

            Assert-NonSensitiveRelativePath -RelativePath $relativePath
            if (-not $expectedPaths.Add($relativePath)) {
                throw "Manifest contains a duplicate data path: $relativePath"
            }

            $dataFile = Join-Path $dataRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $dataFile -PathType Leaf)) {
                throw "Manifest data file is missing: $relativePath"
            }

            $actualFile = Get-Item -LiteralPath $dataFile
            if ([Int64]$actualFile.Length -ne [Int64]$entry.size) {
                throw "File size mismatch: $relativePath"
            }

            $actualHash = (Get-FileHash -LiteralPath $dataFile -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
                throw "SHA-256 mismatch: $relativePath"
            }
        }

        if (Test-Path -LiteralPath $dataRoot -PathType Container) {
            foreach ($dataFile in Get-ChildItem -LiteralPath $dataRoot -Recurse -File) {
                $relativePath = (Get-RelativePath -BasePath $dataRoot -TargetPath $dataFile.FullName).Replace('\', '/')
                if (-not $expectedPaths.Contains($relativePath)) {
                    throw "Archive contains an unlisted data file: $relativePath"
                }
            }
        }

        if ($expectedPaths.Count -ne [int]$manifest.fileCount) {
            throw "Manifest file count does not match its file list."
        }

        return [PSCustomObject]@{
            TemporaryRoot = $temporaryRoot
            DataRoot = $dataRoot
            Manifest = $manifest
        }
    }
    catch {
        Remove-SafeTemporaryDirectory -PathValue $temporaryRoot
        throw
    }
}

# 判断目标端是否已经包含会话，以决定是否自动恢复机器相关界面状态。
function Test-HasExistingHistory {
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    foreach ($directoryName in @("sessions", "archived_sessions")) {
        $directory = Join-Path $TargetRoot $directoryName
        if (Test-Path -LiteralPath $directory -PathType Container) {
            $firstSession = Get-ChildItem -LiteralPath $directory -Recurse -File -Filter "*.jsonl" | Select-Object -First 1
            if ($null -ne $firstSession) {
                return $true
            }
        }
    }

    return Test-Path -LiteralPath (Join-Path $TargetRoot "session_index.jsonl") -PathType Leaf
}

# 判断目标端是否存在需要在恢复前备份的受支持数据。
function Test-HasMigratableData {
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    if (Test-HasExistingHistory -TargetRoot $TargetRoot) {
        return $true
    }

    if (Test-Path -LiteralPath (Join-Path $TargetRoot ".codex-global-state.json") -PathType Leaf) {
        return $true
    }

    if (@(Get-ChildItem -LiteralPath $TargetRoot -File -Filter "state_*.sqlite*" -ErrorAction SilentlyContinue).Count -gt 0) {
        return $true
    }

    return $false
}

# 原子写入 UTF-8 无 BOM 文本，避免索引更新中途留下半文件。
function Write-LinesAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    $temporaryFile = Join-Path $parent (".{0}.{1}.tmp" -f [System.IO.Path]::GetFileName($Destination), [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllLines($temporaryFile, $Lines, $script:Utf8NoBom)
        Move-Item -LiteralPath $temporaryFile -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
}

# 在临时区重写单个会话的结构化元数据，并保留其他 JSONL 记录。
function New-ProviderRewrittenSessionFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$DestinationFile,
        [Parameter(Mandatory = $true)][string]$Provider
    )

    $lines = @([System.IO.File]::ReadAllLines($SourceFile, [System.Text.Encoding]::UTF8))
    $sessionId = ""
    $metadataFound = $false
    $changed = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        try {
            $record = $lines[$index] | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ([string]$record.type -ne "session_meta" -or $null -eq $record.payload) {
            continue
        }

        $sessionId = [string]$record.payload.id
        $providerProperty = $record.payload.PSObject.Properties["model_provider"]
        if ($null -eq $providerProperty) {
            break
        }

        $metadataFound = $true
        if ([string]$providerProperty.Value -cne $Provider) {
            $record.payload.model_provider = $Provider
            $lines[$index] = $record | ConvertTo-Json -Depth 100 -Compress
            $changed = $true
        }
        break
    }

    if (-not $metadataFound) {
        return [PSCustomObject]@{
            SourceFile = $SourceFile
            SessionId = ""
            MetadataFound = $false
            Changed = $false
        }
    }

    Write-LinesAtomically -Destination $DestinationFile -Lines $lines
    return [PSCustomObject]@{
        SourceFile = $DestinationFile
        SessionId = $sessionId
        MetadataFound = $true
        Changed = $changed
    }
}

# 读取 transcript 的稳定会话 ID，不依赖 provider 字段是否存在。
function Get-HistorySessionId {
    param([Parameter(Mandatory = $true)][string]$SourceFile)

    $stream = [System.IO.FileStream]::new(
        $SourceFile,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    )
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
    try {
        while (-not $reader.EndOfStream) {
            try {
                $record = $reader.ReadLine() | ConvertFrom-Json
            }
            catch {
                continue
            }

            if ([string]$record.type -eq "session_meta" -and $null -ne $record.payload) {
                return [string]$record.payload.id
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    return ""
}

# 生成 GUI 会话选择器需要的轻量目录，标题优先来自 session_index.jsonl。
function Get-SessionCatalog {
    param([Parameter(Mandatory = $true)][string]$DataRoot)

    $indexById = @{}
    $indexPath = Join-Path $DataRoot "session_index.jsonl"
    if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadAllLines($indexPath, [System.Text.Encoding]::UTF8)) {
            try {
                $record = $line | ConvertFrom-Json
                $id = [string]$record.id
                if (-not [string]::IsNullOrWhiteSpace($id)) { $indexById[$id] = $record }
            }
            catch { }
        }
    }

    $sessions = [System.Collections.Generic.List[object]]::new()
    foreach ($directoryName in @("sessions", "archived_sessions")) {
        $directory = Join-Path $DataRoot $directoryName
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File -Filter "*.jsonl") {
            $id = Get-HistorySessionId -SourceFile $file.FullName
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $indexRecord = if ($indexById.ContainsKey($id)) { $indexById[$id] } else { $null }
            $titleProperty = if ($null -ne $indexRecord) { $indexRecord.PSObject.Properties["title"] } else { $null }
            if ($null -eq $titleProperty -and $null -ne $indexRecord) {
                $titleProperty = $indexRecord.PSObject.Properties["thread_name"]
            }
            $updatedProperty = if ($null -ne $indexRecord) { $indexRecord.PSObject.Properties["updated_at"] } else { $null }
            $title = if ($null -ne $titleProperty -and -not [string]::IsNullOrWhiteSpace([string]$titleProperty.Value)) {
                [string]$titleProperty.Value
            }
            else { $id }
            $updatedAt = if ($null -ne $updatedProperty -and -not [string]::IsNullOrWhiteSpace([string]$updatedProperty.Value)) {
                [string]$updatedProperty.Value
            }
            else { $file.LastWriteTimeUtc.ToString("o") }
            $sessions.Add([PSCustomObject]@{
                id = $id
                title = $title
                updatedAt = $updatedAt
                archived = ($directoryName -eq "archived_sessions")
                path = (Get-RelativePath -BasePath $DataRoot -TargetPath $file.FullName).Replace('\', '/')
            })
        }
    }
    return @($sessions | Sort-Object updatedAt -Descending)
}

function Get-ArchiveSessionCatalog {
    param([Parameter(Mandatory = $true)][string]$SourceArchive)

    $validation = Expand-AndValidateArchive -SourceArchive $SourceArchive
    try {
        $partialProperty = $validation.Manifest.PSObject.Properties["isPartialHistory"]
        return [PSCustomObject]@{
            Sessions = @(Get-SessionCatalog -DataRoot $validation.DataRoot)
            IsPartialHistory = ($null -ne $partialProperty -and [bool]$partialProperty.Value)
        }
    }
    finally { Remove-SafeTemporaryDirectory -PathValue $validation.TemporaryRoot }
}

# 加载 Windows 自带 SQLite 接口，用于同步桌面端线程索引中的 provider。
function Initialize-SqliteProviderUpdater {
    if ($null -ne ("CodexHistorySqlite" -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// 通过 Windows 自带 winsqlite3 更新 Codex 本地线程索引。
public static class CodexHistorySqlite
{
    private const int SqliteOk = 0;
    private const int SqliteRow = 100;
    private const int SqliteDone = 101;
    private static readonly IntPtr SqliteTransient = new IntPtr(-1);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode, EntryPoint = "sqlite3_open16")]
    private static extern int Open(string filename, out IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode, EntryPoint = "sqlite3_prepare16_v2")]
    private static extern int Prepare(IntPtr database, string sql, int byteCount, out IntPtr statement, IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_reset(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_clear_bindings(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode, EntryPoint = "sqlite3_bind_text16")]
    private static extern int BindText(IntPtr statement, int index, string value, int byteCount, IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_changes(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_column_text16")]
    private static extern IntPtr ColumnText(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr database, int milliseconds);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_errmsg16")]
    private static extern IntPtr ErrorMessage(IntPtr database);

    // 仅更新指定会话 ID，避免修改目标电脑已有的其他历史。
    public static int UpdateProviders(string databasePath, string provider, string[] sessionIds)
    {
        IntPtr database;
        int result = Open(databasePath, out database);
        if (result != SqliteOk)
        {
            throw new InvalidOperationException("Cannot open SQLite database: " + databasePath);
        }

        bool transactionStarted = false;
        IntPtr statement = IntPtr.Zero;
        try
        {
            sqlite3_busy_timeout(database, 5000);
            Execute(database, "BEGIN IMMEDIATE");
            transactionStarted = true;

            result = Prepare(database, "UPDATE threads SET model_provider = ?1 WHERE id = ?2", -1, out statement, IntPtr.Zero);
            EnsureSuccess(database, result, "prepare provider update");

            int updatedRows = 0;
            foreach (string sessionId in sessionIds)
            {
                EnsureSuccess(database, BindText(statement, 1, provider, -1, SqliteTransient), "bind provider");
                EnsureSuccess(database, BindText(statement, 2, sessionId, -1, SqliteTransient), "bind session id");
                result = sqlite3_step(statement);
                if (result != SqliteDone)
                {
                    throw new InvalidOperationException("SQLite provider update failed: " + GetError(database));
                }
                updatedRows += sqlite3_changes(database);
                sqlite3_reset(statement);
                sqlite3_clear_bindings(statement);
            }

            sqlite3_finalize(statement);
            statement = IntPtr.Zero;
            Execute(database, "COMMIT");
            transactionStarted = false;
            Execute(database, "PRAGMA wal_checkpoint(TRUNCATE)");
            return updatedRows;
        }
        catch
        {
            if (statement != IntPtr.Zero)
            {
                sqlite3_finalize(statement);
            }
            if (transactionStarted)
            {
                try { Execute(database, "ROLLBACK"); } catch { }
            }
            throw;
        }
        finally
        {
            sqlite3_close(database);
        }
    }

    // 将暂存数据库裁剪为指定会话，避免部分备份泄露其他线程标题和路径。
    public static int FilterThreads(string databasePath, string[] sessionIds)
    {
        IntPtr database;
        int result = Open(databasePath, out database);
        if (result != SqliteOk)
        {
            throw new InvalidOperationException("Cannot open SQLite database: " + databasePath);
        }

        bool transactionStarted = false;
        IntPtr statement = IntPtr.Zero;
        try
        {
            sqlite3_busy_timeout(database, 5000);
            Execute(database, "BEGIN IMMEDIATE");
            transactionStarted = true;
            Execute(database, "CREATE TEMP TABLE codex_history_selected_ids (id TEXT PRIMARY KEY)");
            result = Prepare(database, "INSERT OR IGNORE INTO temp.codex_history_selected_ids (id) VALUES (?1)", -1, out statement, IntPtr.Zero);
            EnsureSuccess(database, result, "prepare selected session insert");
            foreach (string sessionId in sessionIds)
            {
                EnsureSuccess(database, BindText(statement, 1, sessionId, -1, SqliteTransient), "bind selected session id");
                result = sqlite3_step(statement);
                if (result != SqliteDone)
                {
                    throw new InvalidOperationException("SQLite selected session insert failed: " + GetError(database));
                }
                sqlite3_reset(statement);
                sqlite3_clear_bindings(statement);
            }
            sqlite3_finalize(statement);
            statement = IntPtr.Zero;
            Execute(database, "DELETE FROM main.threads WHERE id NOT IN (SELECT id FROM temp.codex_history_selected_ids)");
            int deletedRows = sqlite3_changes(database);
            if (TableExists(database, "thread_dynamic_tools"))
            {
                Execute(database, "DELETE FROM main.thread_dynamic_tools WHERE thread_id NOT IN (SELECT id FROM temp.codex_history_selected_ids)");
            }
            if (TableExists(database, "thread_spawn_edges"))
            {
                Execute(database, "DELETE FROM main.thread_spawn_edges WHERE parent_thread_id NOT IN " +
                    "(SELECT id FROM temp.codex_history_selected_ids) OR child_thread_id NOT IN " +
                    "(SELECT id FROM temp.codex_history_selected_ids)");
            }
            Execute(database, "COMMIT");
            transactionStarted = false;
            Execute(database, "PRAGMA wal_checkpoint(TRUNCATE)");
            return deletedRows;
        }
        catch
        {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            if (transactionStarted)
            {
                try { Execute(database, "ROLLBACK"); } catch { }
            }
            throw;
        }
        finally { sqlite3_close(database); }
    }

    // 合并来源线程索引；只有整体恢复来源状态时才允许更新已存在的映射行。
    public static int MergeThreads(
        string targetDatabasePath,
        string sourceDatabasePath,
        string provider,
        string[] sessionIds,
        string[] rolloutPaths,
        bool updateExistingMappings)
    {
        if (sessionIds.Length != rolloutPaths.Length)
        {
            throw new ArgumentException("Session IDs and rollout paths must have the same length.");
        }
        if (sessionIds.Length == 0)
        {
            return 0;
        }

        IntPtr database;
        int result = Open(targetDatabasePath, out database);
        if (result != SqliteOk)
        {
            throw new InvalidOperationException("Cannot open SQLite database: " + targetDatabasePath);
        }

        bool sourceAttached = false;
        bool transactionStarted = false;
        IntPtr statement = IntPtr.Zero;
        try
        {
            sqlite3_busy_timeout(database, 5000);
            ExecuteBoundText(database, "ATTACH DATABASE ?1 AS codex_history_source", sourceDatabasePath);
            sourceAttached = true;
            string targetSchema = ReadThreadColumnSignature(database, "main");
            string sourceSchema = ReadThreadColumnSignature(database, "codex_history_source");
            if (!String.Equals(targetSchema, sourceSchema, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Source and target threads tables have different column layouts.");
            }
            Execute(database, "BEGIN IMMEDIATE");
            transactionStarted = true;
            Execute(database, "CREATE TEMP TABLE codex_history_imports (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL)");

            result = Prepare(database, "INSERT INTO temp.codex_history_imports (id, rollout_path) VALUES (?1, ?2)", -1, out statement, IntPtr.Zero);
            EnsureSuccess(database, result, "prepare thread mapping insert");
            for (int index = 0; index < sessionIds.Length; index++)
            {
                EnsureSuccess(database, BindText(statement, 1, sessionIds[index], -1, SqliteTransient), "bind session id");
                EnsureSuccess(database, BindText(statement, 2, rolloutPaths[index], -1, SqliteTransient), "bind rollout path");
                result = sqlite3_step(statement);
                if (result != SqliteDone)
                {
                    throw new InvalidOperationException("SQLite thread mapping insert failed: " + GetError(database));
                }
                sqlite3_reset(statement);
                sqlite3_clear_bindings(statement);
            }
            sqlite3_finalize(statement);
            statement = IntPtr.Zero;

            Execute(database, "CREATE TEMP TABLE codex_history_added_ids AS " +
                "SELECT mapping.id FROM temp.codex_history_imports AS mapping " +
                "INNER JOIN codex_history_source.threads AS source ON source.id = mapping.id " +
                "LEFT JOIN main.threads AS target ON target.id = mapping.id WHERE target.id IS NULL");
            Execute(database, "INSERT OR IGNORE INTO main.threads " +
                "SELECT source.* FROM codex_history_source.threads AS source " +
                "INNER JOIN temp.codex_history_added_ids AS added ON added.id = source.id");
            int addedRows = sqlite3_changes(database);

            string mappedIds = updateExistingMappings ? "temp.codex_history_imports" : "temp.codex_history_added_ids";
            Execute(database, "UPDATE main.threads SET rollout_path = " +
                "(SELECT mapping.rollout_path FROM temp.codex_history_imports AS mapping WHERE mapping.id = main.threads.id) " +
                "WHERE id IN (SELECT id FROM " + mappedIds + ")");
            if (!String.IsNullOrWhiteSpace(provider))
            {
                ExecuteBoundText(database, "UPDATE main.threads SET model_provider = ?1 WHERE id IN (SELECT id FROM " + mappedIds + ")", provider);
            }

            Execute(database, "COMMIT");
            transactionStarted = false;
            Execute(database, "PRAGMA wal_checkpoint(TRUNCATE)");
            return addedRows;
        }
        catch
        {
            if (statement != IntPtr.Zero)
            {
                sqlite3_finalize(statement);
            }
            if (transactionStarted)
            {
                try { Execute(database, "ROLLBACK"); } catch { }
            }
            throw;
        }
        finally
        {
            if (sourceAttached)
            {
                try { Execute(database, "DETACH DATABASE codex_history_source"); } catch { }
            }
            sqlite3_close(database);
        }
    }

    // 执行不需要绑定参数的 SQLite 语句。
    private static void Execute(IntPtr database, string sql)
    {
        IntPtr statement;
        int result = Prepare(database, sql, -1, out statement, IntPtr.Zero);
        EnsureSuccess(database, result, "prepare SQL");
        try
        {
            do
            {
                result = sqlite3_step(statement);
            }
            while (result == SqliteRow);
            if (result != SqliteDone)
            {
                throw new InvalidOperationException("SQLite statement failed: " + GetError(database));
            }
        }
        finally
        {
            sqlite3_finalize(statement);
        }
    }

    private static void ExecuteBoundText(IntPtr database, string sql, string value)
    {
        IntPtr statement;
        int result = Prepare(database, sql, -1, out statement, IntPtr.Zero);
        EnsureSuccess(database, result, "prepare bound SQL");
        try
        {
            EnsureSuccess(database, BindText(statement, 1, value, -1, SqliteTransient), "bind SQL value");
            result = sqlite3_step(statement);
            if (result != SqliteDone)
            {
                throw new InvalidOperationException("SQLite statement failed: " + GetError(database));
            }
        }
        finally
        {
            sqlite3_finalize(statement);
        }
    }

    private static bool TableExists(IntPtr database, string tableName)
    {
        IntPtr statement;
        int result = Prepare(database, "SELECT 1 FROM main.sqlite_master WHERE type = 'table' AND name = ?1", -1, out statement, IntPtr.Zero);
        EnsureSuccess(database, result, "prepare table lookup");
        try
        {
            EnsureSuccess(database, BindText(statement, 1, tableName, -1, SqliteTransient), "bind table name");
            return sqlite3_step(statement) == SqliteRow;
        }
        finally { sqlite3_finalize(statement); }
    }

    private static string ReadThreadColumnSignature(IntPtr database, string schema)
    {
        IntPtr statement;
        int result = Prepare(database, "PRAGMA " + schema + ".table_info(threads)", -1, out statement, IntPtr.Zero);
        EnsureSuccess(database, result, "read threads schema");
        try
        {
            System.Collections.Generic.List<string> columns = new System.Collections.Generic.List<string>();
            while ((result = sqlite3_step(statement)) == SqliteRow)
            {
                IntPtr value = ColumnText(statement, 1);
                columns.Add(value == IntPtr.Zero ? "" : Marshal.PtrToStringUni(value));
            }
            if (result != SqliteDone)
            {
                throw new InvalidOperationException("Could not read threads schema: " + GetError(database));
            }
            if (columns.Count == 0)
            {
                throw new InvalidOperationException("The threads table is missing.");
            }
            return String.Join("\u001f", columns.ToArray());
        }
        finally
        {
            sqlite3_finalize(statement);
        }
    }

    // 把 SQLite 返回码转换为可诊断异常。
    private static void EnsureSuccess(IntPtr database, int result, string operation)
    {
        if (result != SqliteOk)
        {
            throw new InvalidOperationException(operation + " failed: " + GetError(database));
        }
    }

    // 读取 SQLite 的 Unicode 错误文本。
    private static string GetError(IntPtr database)
    {
        IntPtr message = ErrorMessage(database);
        return message == IntPtr.Zero ? "unknown SQLite error" : Marshal.PtrToStringUni(message);
    }
}
'@
}

# 裁剪暂存的 SQLite 线程索引，并刷新清单中的哈希和大小。
function Filter-StagedThreadIndexes {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$SelectedSessionIds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Entries
    )

    Initialize-SqliteProviderUpdater
    $sessionIds = @($SelectedSessionIds | Sort-Object)
    foreach ($entry in @($Entries | Where-Object { $_.category -eq "appState" -and $_.path -like "*.sqlite" })) {
        $databasePath = Join-Path $DataRoot ([string]$entry.path).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        try {
            [CodexHistorySqlite]::FilterThreads($databasePath, $sessionIds) | Out-Null
            foreach ($suffix in @("-wal", "-shm")) {
                $sidecar = $databasePath + $suffix
                if (Test-Path -LiteralPath $sidecar -PathType Leaf) { [System.IO.File]::Delete($sidecar) }
            }
            $file = Get-Item -LiteralPath $databasePath
            $entry.size = [Int64]$file.Length
            $entry.sha256 = (Get-FileHash -LiteralPath $databasePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        catch {
            throw "Could not filter desktop thread index $($entry.path): $($_.Exception.Message)"
        }
    }

    for ($index = $Entries.Count - 1; $index -ge 0; $index--) {
        if ($Entries[$index].category -eq "appState" -and (
            ([string]$Entries[$index].path).EndsWith("-wal", [System.StringComparison]::OrdinalIgnoreCase) -or
            ([string]$Entries[$index].path).EndsWith("-shm", [System.StringComparison]::OrdinalIgnoreCase))) {
            $Entries.RemoveAt($index)
        }
    }
}

# 同步目标端现有 SQLite 索引中已经存在的迁入会话。
function Update-ImportedProviderIndexes {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SessionIds
    )

    if ($SessionIds.Count -eq 0) {
        return 0
    }

    Initialize-SqliteProviderUpdater
    $databaseFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($directory in @($TargetRoot, (Join-Path $TargetRoot "sqlite"))) {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $directory -File -Filter "state_*.sqlite" -ErrorAction SilentlyContinue) {
                $databaseFiles.Add($file)
            }
        }
    }

    $updatedRows = 0
    foreach ($databaseFile in $databaseFiles) {
        try {
            Assert-PathWithinRootWithoutReparsePoint -Root $TargetRoot -PathValue $databaseFile.FullName `
                -Operation "SQLite provider update"
            $updatedRows += [CodexHistorySqlite]::UpdateProviders($databaseFile.FullName, $Provider, $SessionIds)
        }
        catch {
            Write-Warning "Could not update provider references in $($databaseFile.FullName): $($_.Exception.Message)"
        }
    }

    return $updatedRows
}

# 将来源 state 数据库中的缺失线程合并到目标，并绑定到目标电脑的 transcript 路径。
function Merge-ImportedThreadIndexes {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][hashtable]$SessionPaths,
        [AllowEmptyString()][string]$Provider,
        [Parameter(Mandatory = $true)][bool]$UpdateExistingMappings
    )

    if ($SessionPaths.Count -eq 0) {
        return 0
    }

    Initialize-SqliteProviderUpdater
    $sessionIds = @($SessionPaths.Keys | Sort-Object)
    $rolloutPaths = @($sessionIds | ForEach-Object { [string]$SessionPaths[$_] })
    $addedRows = 0

    foreach ($relativeDirectory in @("", "sqlite")) {
        $sourceDirectory = if ([string]::IsNullOrWhiteSpace($relativeDirectory)) {
            $SourceRoot
        }
        else {
            Join-Path $SourceRoot $relativeDirectory
        }
        $targetDirectory = if ([string]::IsNullOrWhiteSpace($relativeDirectory)) {
            $TargetRoot
        }
        else {
            Join-Path $TargetRoot $relativeDirectory
        }

        if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container) -or
            -not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            continue
        }

        foreach ($targetDatabase in Get-ChildItem -LiteralPath $targetDirectory -File -Filter "state_*.sqlite" -ErrorAction SilentlyContinue) {
            $sourceDatabase = Join-Path $sourceDirectory $targetDatabase.Name
            if (-not (Test-Path -LiteralPath $sourceDatabase -PathType Leaf)) {
                continue
            }

            try {
                Assert-PathWithinRootWithoutReparsePoint -Root $SourceRoot -PathValue $sourceDatabase `
                    -Operation "Source SQLite thread merge"
                Assert-PathWithinRootWithoutReparsePoint -Root $TargetRoot -PathValue $targetDatabase.FullName `
                    -Operation "Target SQLite thread merge"
                $addedRows += [CodexHistorySqlite]::MergeThreads(
                    $targetDatabase.FullName,
                    $sourceDatabase,
                    $Provider,
                    $sessionIds,
                    $rolloutPaths,
                    $UpdateExistingMappings
                )
            }
            catch {
                Write-Warning "Could not merge thread indexes into $($targetDatabase.FullName): $($_.Exception.Message)"
            }
        }
    }

    return $addedRows
}

# 合并标题索引；保留目标端已有记录，仅追加此前不存在的会话 ID。
function Merge-SessionIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SourceIndex,
        [Parameter(Mandatory = $true)][string]$DestinationIndex,
        [AllowNull()][System.Collections.Generic.HashSet[string]]$SelectedSessionIds
    )

    if (-not (Test-Path -LiteralPath $SourceIndex -PathType Leaf)) {
        return 0
    }

    $destinationLines = if (Test-Path -LiteralPath $DestinationIndex -PathType Leaf) {
        @([System.IO.File]::ReadAllLines($DestinationIndex, [System.Text.Encoding]::UTF8))
    }
    else {
        @()
    }

    $knownIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $destinationLines) {
        try {
            $id = [string](($line | ConvertFrom-Json).id)
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $knownIds.Add($id) | Out-Null
            }
        }
        catch {
            # 保留目标端无法解析的行，避免迁移工具造成数据丢失。
        }
    }

    $mergedLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $destinationLines) {
        $mergedLines.Add($line)
    }

    $added = 0
    foreach ($line in [System.IO.File]::ReadAllLines($SourceIndex, [System.Text.Encoding]::UTF8)) {
        $id = ""
        try {
            $id = [string](($line | ConvertFrom-Json).id)
        }
        catch {
            # 无法解析的来源行仍会保留，但不能参与 ID 去重。
        }

        if ($null -ne $SelectedSessionIds -and
            ([string]::IsNullOrWhiteSpace($id) -or -not $SelectedSessionIds.Contains($id))) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($id) -or $knownIds.Add($id)) {
            $mergedLines.Add($line)
            $added++
        }
    }

    Write-LinesAtomically -Destination $DestinationIndex -Lines @($mergedLines)
    return $added
}

# 复制单个归档文件，目标冲突时默认保留目标端版本。
function Copy-ImportedFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$DestinationFile,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][bool]$Overwrite
    )

    Assert-PathWithinRootWithoutReparsePoint -Root $TargetRoot -PathValue $DestinationFile -Operation "Import destination"
    $destinationDirectory = Split-Path -Parent $DestinationFile
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    }

    if ((Test-Path -LiteralPath $DestinationFile -PathType Leaf) -and -not $Overwrite) {
        $sourceHash = (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $DestinationFile -Algorithm SHA256).Hash
        if ($sourceHash -eq $destinationHash) {
            return "unchanged"
        }

        return "conflict"
    }

    Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force
    $sourceVerificationHash = (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash
    $destinationVerificationHash = (Get-FileHash -LiteralPath $DestinationFile -Algorithm SHA256).Hash
    if ($sourceVerificationHash -ne $destinationVerificationHash) {
        throw "Post-copy verification failed: $DestinationFile"
    }

    return "copied"
}

# 恢复已验证的迁移包，并在有旧数据时先创建回滚包。
function Import-HistoryArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceArchive,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][bool]$ForceAppStateRestore,
        [Parameter(Mandatory = $true)][bool]$RemapModelProvider,
        [AllowEmptyString()][string]$RequestedModelProvider,
        [AllowNull()][System.Collections.Generic.HashSet[string]]$SelectedSessionIds
    )

    if ($ForceAppStateRestore -and $null -ne $SelectedSessionIds) {
        throw "A partial session restore cannot overwrite the complete local desktop state. Select all sessions or turn off -RestoreAppState."
    }

    Write-ProgressEvent -Percent 5 -Stage "ValidatingArchive"
    $validation = Expand-AndValidateArchive -SourceArchive $SourceArchive
    try {
        $partialProperty = $validation.Manifest.PSObject.Properties["isPartialHistory"]
        $archiveIsPartial = $null -ne $partialProperty -and [bool]$partialProperty.Value
        if ($ForceAppStateRestore -and $archiveIsPartial) {
            throw "A partial history archive cannot overwrite the complete local desktop state. Use merge restore instead."
        }
        Write-ProgressEvent -Percent 32 -Stage "PreparingSessions"
        $resolvedModelProvider = ""
        $providerRecordsRewritten = 0
        $providerRecordsSkipped = 0
        $providerRewriteFiles = @{}
        $sessionIdsByRelativePath = @{}
        if ($RemapModelProvider) {
            $resolvedModelProvider = Resolve-TargetModelProvider -TargetRoot $TargetRoot -RequestedProvider $RequestedModelProvider
            $rewriteRoot = Join-Path $validation.TemporaryRoot "provider-rewritten"
            foreach ($entry in @($validation.Manifest.files)) {
                $relativePath = ([string]$entry.path).Replace('\', '/')
                if ([string]$entry.category -ne "history" -or [System.IO.Path]::GetExtension($relativePath) -ine ".jsonl") {
                    continue
                }

                $sourceFile = Join-Path $validation.DataRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $rewrittenFile = Join-Path $rewriteRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $rewrite = New-ProviderRewrittenSessionFile -SourceFile $sourceFile -DestinationFile $rewrittenFile `
                    -Provider $resolvedModelProvider
                if ($null -ne $SelectedSessionIds -and
                    ([string]::IsNullOrWhiteSpace($rewrite.SessionId) -or -not $SelectedSessionIds.Contains([string]$rewrite.SessionId))) {
                    continue
                }
                if (-not [string]::IsNullOrWhiteSpace($rewrite.SessionId)) {
                    $sessionIdsByRelativePath[$relativePath] = [string]$rewrite.SessionId
                }
                if ($rewrite.MetadataFound) {
                    $providerRewriteFiles[$relativePath] = $rewrite
                }
                else {
                    $providerRecordsSkipped++
                }
            }
        }
        else {
            foreach ($entry in @($validation.Manifest.files)) {
                $relativePath = ([string]$entry.path).Replace('\', '/')
                if ([string]$entry.category -ne "history" -or [System.IO.Path]::GetExtension($relativePath) -ine ".jsonl") {
                    continue
                }

                $sourceFile = Join-Path $validation.DataRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $sessionId = Get-HistorySessionId -SourceFile $sourceFile
                if ($null -ne $SelectedSessionIds -and
                    ([string]::IsNullOrWhiteSpace($sessionId) -or -not $SelectedSessionIds.Contains($sessionId))) {
                    continue
                }
                if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
                    $sessionIdsByRelativePath[$relativePath] = $sessionId
                }
            }
        }

        if ($null -ne $SelectedSessionIds) {
            foreach ($selectedId in $SelectedSessionIds) {
                if (-not ($sessionIdsByRelativePath.Values -contains $selectedId)) {
                    throw "Selected session was not found in the archive: $selectedId"
                }
            }
        }

        if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($TargetRoot) | Out-Null
        }
        Assert-PathWithinRootWithoutReparsePoint -Root $TargetRoot -PathValue $TargetRoot -Operation "Import destination"

        $hadHistory = Test-HasExistingHistory -TargetRoot $TargetRoot
        $backupPath = ""
        if (Test-HasMigratableData -TargetRoot $TargetRoot) {
            Write-ProgressEvent -Percent 40 -Stage "CreatingRollbackBackup"
            $backupDirectory = Join-Path (Split-Path -Parent $TargetRoot) "codex-history-backups"
            [System.IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
            $backupRoot = Split-Path -Parent $TargetRoot
            Assert-PathWithinRootWithoutReparsePoint -Root $backupRoot -PathValue $backupDirectory -Operation "Backup destination"
            $backupName = "codex-history-before-import-{0}-{1}.zip" -f [DateTime]::Now.ToString("yyyyMMdd-HHmmss"), [Guid]::NewGuid().ToString("N").Substring(0, 8)
            $backupPath = Join-Path $backupDirectory $backupName
            New-HistoryArchive -SourceRoot $TargetRoot -DestinationArchive $backupPath -IncludeAppState $true `
                -IncludeChatArtifacts $false -AllowOverwrite $false -EmitProgress $false | Out-Null
        }

        $copied = 0
        $unchanged = 0
        $conflicts = 0
        $appStateRestored = 0
        $restoreAppStateNow = ($ForceAppStateRestore -or (-not $hadHistory)) -and $null -eq $SelectedSessionIds
        $importedSessionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $importedSessionPaths = @{}

        $manifestEntries = @($validation.Manifest.files)
        $processedEntries = 0
        foreach ($entry in $manifestEntries) {
            $relativePath = ([string]$entry.path).Replace('\', '/')
            $category = [string]$entry.category
            $processedEntries++
            $copyPercent = 48 + [Math]::Floor(($processedEntries / [Math]::Max(1, $manifestEntries.Count)) * 34)
            Write-ProgressEvent -Percent ([int]$copyPercent) -Stage "RestoringFiles"
            if ($category -eq "historyIndex") {
                continue
            }
            if ($null -ne $SelectedSessionIds -and $category -eq "artifact") {
                continue
            }
            if ($category -eq "history" -and
                (-not $sessionIdsByRelativePath.ContainsKey($relativePath))) {
                continue
            }
            if ($category -eq "appState" -and -not $restoreAppStateNow) {
                continue
            }

            $sourceFile = Join-Path $validation.DataRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $rewrite = $null
            if ($RemapModelProvider -and $providerRewriteFiles.ContainsKey($relativePath)) {
                $rewrite = $providerRewriteFiles[$relativePath]
                $sourceFile = $rewrite.SourceFile
            }
            $destinationFile = Join-Path $TargetRoot $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $overwrite = $category -eq "appState"
            $result = Copy-ImportedFile -SourceFile $sourceFile -DestinationFile $destinationFile `
                -TargetRoot $TargetRoot -Overwrite $overwrite
            switch ($result) {
                "copied" {
                    $copied++
                    if ($category -eq "appState") { $appStateRestored++ }
                }
                "unchanged" { $unchanged++ }
                "conflict" { $conflicts++ }
            }
            if ($null -ne $rewrite -and $result -ne "conflict" -and -not [string]::IsNullOrWhiteSpace($rewrite.SessionId)) {
                $importedSessionIds.Add([string]$rewrite.SessionId) | Out-Null
                if ($rewrite.Changed) { $providerRecordsRewritten++ }
            }
            if ($category -eq "history" -and $result -ne "conflict" -and $sessionIdsByRelativePath.ContainsKey($relativePath)) {
                $sessionId = [string]$sessionIdsByRelativePath[$relativePath]
                $importedSessionIds.Add($sessionId) | Out-Null
                $importedSessionPaths[$sessionId] = $destinationFile
            }
        }

        $sourceIndex = Join-Path $validation.DataRoot "session_index.jsonl"
        $destinationIndex = Join-Path $TargetRoot "session_index.jsonl"
        Assert-PathWithinRootWithoutReparsePoint -Root $TargetRoot -PathValue $destinationIndex -Operation "Import destination"
        Write-ProgressEvent -Percent 86 -Stage "MergingIndexes"
        $indexEntriesAdded = Merge-SessionIndex -SourceIndex $sourceIndex -DestinationIndex $destinationIndex `
            -SelectedSessionIds $SelectedSessionIds
        $threadIndexRowsAdded = Merge-ImportedThreadIndexes -SourceRoot $validation.DataRoot -TargetRoot $TargetRoot `
            -SessionPaths $importedSessionPaths -Provider $resolvedModelProvider `
            -UpdateExistingMappings:$restoreAppStateNow
        $providerIndexRowsUpdated = if ($RemapModelProvider) {
            Update-ImportedProviderIndexes -TargetRoot $TargetRoot -Provider $resolvedModelProvider `
                -SessionIds @($importedSessionIds)
        }
        else {
            0
        }

        return [PSCustomObject]@{
            CodexHome = $TargetRoot
            CopiedFiles = $copied
            UnchangedFiles = $unchanged
            ConflictingFilesKeptAtDestination = $conflicts
            IndexEntriesAdded = $indexEntriesAdded
            ThreadIndexRowsAdded = $threadIndexRowsAdded
            AppStateFilesRestored = $appStateRestored
            BackupArchive = $backupPath
            ModelProvider = $resolvedModelProvider
            ProviderRecordsRewritten = $providerRecordsRewritten
            ProviderRecordsSkipped = $providerRecordsSkipped
            ProviderIndexRowsUpdated = $providerIndexRowsUpdated
        }
    }
    finally {
        Remove-SafeTemporaryDirectory -PathValue $validation.TemporaryRoot
    }
}

# 只校验迁移包并返回摘要，不修改 Codex 数据。
function Inspect-HistoryArchive {
    param([Parameter(Mandatory = $true)][string]$SourceArchive)

    $validation = Expand-AndValidateArchive -SourceArchive $SourceArchive
    try {
        return [PSCustomObject]@{
            ArchivePath = $SourceArchive
            SchemaVersion = [int]$validation.Manifest.schemaVersion
            CreatedAtUtc = [string]$validation.Manifest.createdAtUtc
            SessionCount = [int]$validation.Manifest.sessionCount
            ArchivedSessionCount = [int]$validation.Manifest.archivedSessionCount
            FileCount = [int]$validation.Manifest.fileCount
            IncludesAppState = [bool]$validation.Manifest.includesAppState
            IncludesArtifacts = [bool]$validation.Manifest.includesArtifacts
            Validation = "passed"
        }
    }
    finally {
        Remove-SafeTemporaryDirectory -PathValue $validation.TemporaryRoot
    }
}

try {
    $selectedSessionIds = Read-SessionSelection -SelectionFile $SessionSelectionFile
    $resolvedCodexHome = if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        Get-DefaultCodexHome
    }
    else {
        Resolve-FullPath -PathValue $CodexHome
    }

    switch ($Mode) {
        "Export" {
            Write-ProgressEvent -Percent 0 -Stage "PreparingExport"
            Assert-CodexStopped -AllowRunning:$AllowRunningCodex
            if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
                $ArchivePath = Join-Path (Get-Location).Path ("codex-history-{0}.zip" -f [DateTime]::Now.ToString("yyyyMMdd-HHmmss"))
            }

            $resolvedArchive = Resolve-FullPath -PathValue $ArchivePath
            $result = New-HistoryArchive -SourceRoot $resolvedCodexHome -DestinationArchive $resolvedArchive `
                -IncludeAppState:(-not $HistoryOnly) -IncludeChatArtifacts:$IncludeArtifacts -AllowOverwrite:$Force `
                -SelectedSessionIds $selectedSessionIds
            Write-ProgressEvent -Percent 100 -Stage "Complete"
            Write-Host ("export complete`tarchive={0}`tfiles={1}`tsessions={2}`tarchived={3}`tbytes={4}" -f `
                $result.ArchivePath, $result.FileCount, $result.SessionCount, $result.ArchivedSessionCount, $result.ArchiveBytes)
        }
        "Import" {
            Write-ProgressEvent -Percent 0 -Stage "PreparingRestore"
            Assert-CodexStopped -AllowRunning:$AllowRunningCodex
            if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
                throw "Import mode requires -ArchivePath."
            }

            $resolvedArchive = Resolve-FullPath -PathValue $ArchivePath
            $result = Import-HistoryArchive -SourceArchive $resolvedArchive -TargetRoot $resolvedCodexHome `
                -ForceAppStateRestore:$RestoreAppState -RemapModelProvider:$RewriteModelProvider `
                -RequestedModelProvider $TargetModelProvider -SelectedSessionIds $selectedSessionIds
            Write-ProgressEvent -Percent 100 -Stage "Complete"
            Write-Host ("import complete`tcodexHome={0}`tcopied={1}`tunchanged={2}`tconflicts={3}`tindexAdded={4}`tthreadIndexAdded={5}`tappState={6}`tprovider={7}`tproviderFiles={8}`tproviderIndexRows={9}`tproviderSkipped={10}" -f `
                $result.CodexHome, $result.CopiedFiles, $result.UnchangedFiles, `
                $result.ConflictingFilesKeptAtDestination, $result.IndexEntriesAdded, $result.ThreadIndexRowsAdded, $result.AppStateFilesRestored, `
                $result.ModelProvider, $result.ProviderRecordsRewritten, $result.ProviderIndexRowsUpdated, $result.ProviderRecordsSkipped)
            if (-not [string]::IsNullOrWhiteSpace($result.BackupArchive)) {
                Write-Host ("backup created`tarchive={0}" -f $result.BackupArchive)
            }
            if ($result.ConflictingFilesKeptAtDestination -gt 0) {
                Write-Warning "$($result.ConflictingFilesKeptAtDestination) conflicting session files were kept at the destination. The source versions remain in the migration ZIP."
            }
        }
        "Inspect" {
            if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
                throw "Inspect mode requires -ArchivePath."
            }

            $resolvedArchive = Resolve-FullPath -PathValue $ArchivePath
            $result = Inspect-HistoryArchive -SourceArchive $resolvedArchive
            Write-Host ("archive valid`tpath={0}`tschema={1}`tfiles={2}`tsessions={3}`tarchived={4}`tappState={5}`tartifacts={6}" -f `
                $result.ArchivePath, $result.SchemaVersion, $result.FileCount, $result.SessionCount, `
                $result.ArchivedSessionCount, $result.IncludesAppState, $result.IncludesArtifacts)
        }
        "List" {
            $catalogResult = if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
                Get-ArchiveSessionCatalog -SourceArchive (Resolve-FullPath -PathValue $ArchivePath)
            }
            else {
                if (-not (Test-Path -LiteralPath $resolvedCodexHome -PathType Container)) {
                    throw "Codex home does not exist: $resolvedCodexHome"
                }
                [PSCustomObject]@{
                    Sessions = @(Get-SessionCatalog -DataRoot $resolvedCodexHome)
                    IsPartialHistory = $false
                }
            }
            Write-Host ("catalog`t" + ([PSCustomObject]@{ isPartialHistory = [bool]$catalogResult.IsPartialHistory } | ConvertTo-Json -Compress))
            foreach ($session in @($catalogResult.Sessions)) {
                Write-Host ("session`t" + ($session | ConvertTo-Json -Compress))
            }
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
