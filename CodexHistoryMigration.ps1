#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("Export", "Import", "Inspect")]
    [string]$Mode,

    [string]$ArchivePath = "",

    [string]$CodexHome = "",

    [switch]$HistoryOnly,

    [switch]$IncludeArtifacts,

    [switch]$RestoreAppState,

    [switch]$RewriteModelProvider,

    [string]$TargetModelProvider = "",

    [switch]$AllowRunningCodex,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# 工具和归档格式版本用于拒绝不兼容的迁移包。
$script:ToolName = "CodexHistoryMigration"
$script:ToolVersion = "1.0.0"
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
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Entries
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        return
    }

    foreach ($item in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force) {
        Assert-PathWithinRootWithoutReparsePoint -Root $SourceRoot -PathValue $item.FullName -Operation "Export source"
        if (-not $item.PSIsContainer) {
            Copy-SourceFileToStage -SourceFile $item.FullName -SourceRoot $SourceRoot -DataRoot $DataRoot `
                -Category $Category -SeenPaths $SeenPaths -Entries $Entries
        }
    }
}

# 收集受支持的历史、界面状态与可选聊天产物。
function Copy-CodexDataToStage {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][bool]$IncludeAppState,
        [Parameter(Mandatory = $true)][bool]$IncludeChatArtifacts
    )

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($directoryName in @("sessions", "archived_sessions")) {
        Copy-SourceDirectoryToStage -SourceDirectory (Join-Path $SourceRoot $directoryName) -SourceRoot $SourceRoot `
            -DataRoot $DataRoot -Category "history" -SeenPaths $seenPaths -Entries $entries
    }

    $sessionIndex = Join-Path $SourceRoot "session_index.jsonl"
    if (Test-Path -LiteralPath $sessionIndex -PathType Leaf) {
        Copy-SourceFileToStage -SourceFile $sessionIndex -SourceRoot $SourceRoot -DataRoot $DataRoot `
            -Category "historyIndex" -SeenPaths $seenPaths -Entries $entries
    }

    if ($IncludeAppState) {
        $globalState = Join-Path $SourceRoot ".codex-global-state.json"
        if (Test-Path -LiteralPath $globalState -PathType Leaf) {
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

    if ($IncludeChatArtifacts) {
        foreach ($directoryName in @("generated_images", "visualizations")) {
            Copy-SourceDirectoryToStage -SourceDirectory (Join-Path $SourceRoot $directoryName) -SourceRoot $SourceRoot `
                -DataRoot $DataRoot -Category "artifact" -SeenPaths $seenPaths -Entries $entries
        }
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
        [Parameter(Mandatory = $true)][bool]$AllowOverwrite
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

        $entries = @(Copy-CodexDataToStage -SourceRoot $SourceRoot -DataRoot $dataRoot `
            -IncludeAppState $IncludeAppState -IncludeChatArtifacts $IncludeChatArtifacts)
        if ($entries.Count -eq 0) {
            throw "No supported Codex history files were found in: $SourceRoot"
        }

        $sessionCount = @($entries | Where-Object { $_.path -like "sessions/*.jsonl" }).Count
        $archivedSessionCount = @($entries | Where-Object { $_.path -like "archived_sessions/*.jsonl" }).Count
        $manifest = [ordered]@{
            schemaVersion = $script:SchemaVersion
            tool = $script:ToolName
            toolVersion = $script:ToolVersion
            createdAtUtc = [DateTime]::UtcNow.ToString("o")
            sourcePlatform = [Environment]::OSVersion.Platform.ToString()
            includesAppState = $IncludeAppState
            includesArtifacts = $IncludeChatArtifacts
            sessionCount = $sessionCount
            archivedSessionCount = $archivedSessionCount
            fileCount = $entries.Count
            files = @($entries | Sort-Object path)
        }

        $manifestPath = Join-Path $packageRoot "manifest.json"
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
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

        $providerProperty = $record.payload.PSObject.Properties["model_provider"]
        if ($null -eq $providerProperty) {
            continue
        }

        $metadataFound = $true
        $sessionId = [string]$record.payload.id
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

# 合并标题索引；保留目标端已有记录，仅追加此前不存在的会话 ID。
function Merge-SessionIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SourceIndex,
        [Parameter(Mandatory = $true)][string]$DestinationIndex
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
        [AllowEmptyString()][string]$RequestedModelProvider
    )

    $validation = Expand-AndValidateArchive -SourceArchive $SourceArchive
    try {
        $resolvedModelProvider = ""
        $providerRecordsRewritten = 0
        $providerRecordsSkipped = 0
        $providerRewriteFiles = @{}
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
                if ($rewrite.MetadataFound) {
                    $providerRewriteFiles[$relativePath] = $rewrite
                }
                else {
                    $providerRecordsSkipped++
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
            $backupDirectory = Join-Path (Split-Path -Parent $TargetRoot) "codex-history-backups"
            [System.IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
            $backupRoot = Split-Path -Parent $TargetRoot
            Assert-PathWithinRootWithoutReparsePoint -Root $backupRoot -PathValue $backupDirectory -Operation "Backup destination"
            $backupName = "codex-history-before-import-{0}-{1}.zip" -f [DateTime]::Now.ToString("yyyyMMdd-HHmmss"), [Guid]::NewGuid().ToString("N").Substring(0, 8)
            $backupPath = Join-Path $backupDirectory $backupName
            New-HistoryArchive -SourceRoot $TargetRoot -DestinationArchive $backupPath -IncludeAppState $true `
                -IncludeChatArtifacts $false -AllowOverwrite $false | Out-Null
        }

        $copied = 0
        $unchanged = 0
        $conflicts = 0
        $appStateRestored = 0
        $restoreAppStateNow = $ForceAppStateRestore -or (-not $hadHistory)
        $importedSessionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($entry in @($validation.Manifest.files)) {
            $relativePath = ([string]$entry.path).Replace('\', '/')
            $category = [string]$entry.category
            if ($category -eq "historyIndex") {
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
        }

        $sourceIndex = Join-Path $validation.DataRoot "session_index.jsonl"
        $destinationIndex = Join-Path $TargetRoot "session_index.jsonl"
        Assert-PathWithinRootWithoutReparsePoint -Root $TargetRoot -PathValue $destinationIndex -Operation "Import destination"
        $indexEntriesAdded = Merge-SessionIndex -SourceIndex $sourceIndex -DestinationIndex $destinationIndex
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
    $resolvedCodexHome = if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        Get-DefaultCodexHome
    }
    else {
        Resolve-FullPath -PathValue $CodexHome
    }

    switch ($Mode) {
        "Export" {
            Assert-CodexStopped -AllowRunning:$AllowRunningCodex
            if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
                $ArchivePath = Join-Path (Get-Location).Path ("codex-history-{0}.zip" -f [DateTime]::Now.ToString("yyyyMMdd-HHmmss"))
            }

            $resolvedArchive = Resolve-FullPath -PathValue $ArchivePath
            $result = New-HistoryArchive -SourceRoot $resolvedCodexHome -DestinationArchive $resolvedArchive `
                -IncludeAppState:(-not $HistoryOnly) -IncludeChatArtifacts:$IncludeArtifacts -AllowOverwrite:$Force
            Write-Host ("export complete`tarchive={0}`tfiles={1}`tsessions={2}`tarchived={3}`tbytes={4}" -f `
                $result.ArchivePath, $result.FileCount, $result.SessionCount, $result.ArchivedSessionCount, $result.ArchiveBytes)
        }
        "Import" {
            Assert-CodexStopped -AllowRunning:$AllowRunningCodex
            if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
                throw "Import mode requires -ArchivePath."
            }

            $resolvedArchive = Resolve-FullPath -PathValue $ArchivePath
            $result = Import-HistoryArchive -SourceArchive $resolvedArchive -TargetRoot $resolvedCodexHome `
                -ForceAppStateRestore:$RestoreAppState -RemapModelProvider:$RewriteModelProvider `
                -RequestedModelProvider $TargetModelProvider
            Write-Host ("import complete`tcodexHome={0}`tcopied={1}`tunchanged={2}`tconflicts={3}`tindexAdded={4}`tappState={5}`tprovider={6}`tproviderFiles={7}`tproviderIndexRows={8}`tproviderSkipped={9}" -f `
                $result.CodexHome, $result.CopiedFiles, $result.UnchangedFiles, `
                $result.ConflictingFilesKeptAtDestination, $result.IndexEntriesAdded, $result.AppStateFilesRestored, `
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
    }
}
catch {
    Write-Error $_
    exit 1
}
