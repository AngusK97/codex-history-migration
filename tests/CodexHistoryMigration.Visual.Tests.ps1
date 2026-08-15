$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-RelativeLuminance {
    param([int[]]$Rgb)
    $channels = foreach ($value in $Rgb) {
        $normalized = $value / 255.0
        if ($normalized -le 0.04045) { $normalized / 12.92 }
        else { [Math]::Pow((($normalized + 0.055) / 1.055), 2.4) }
    }
    return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
}

function Get-ContrastRatio {
    param([int[]]$Foreground, [int[]]$Background)
    $first = Get-RelativeLuminance $Foreground
    $second = Get-RelativeLuminance $Background
    $lighter = [Math]::Max($first, $second)
    $darker = [Math]::Min($first, $second)
    return ($lighter + 0.05) / ($darker + 0.05)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$themePath = Join-Path $repoRoot "CodexHistoryMigration.UI.Theme.psd1"
$uiPath = Join-Path $repoRoot "CodexHistoryMigration.UI.ps1"

Assert-True (Test-Path -LiteralPath $themePath -PathType Leaf) "The GUI must define a standalone semantic theme."
$theme = Import-PowerShellDataFile -LiteralPath $themePath

foreach ($name in @("Canvas", "Surface", "Field", "Sidebar", "SidebarText", "Text", "MutedText", "Accent", "Danger", "Warning", "Success", "LogSurface", "LogText")) {
    Assert-True $theme.Colors.ContainsKey($name) "Missing semantic color token: $name"
    Assert-True ($theme.Colors[$name].Count -eq 3) "Color token $name must contain three RGB channels."
}

foreach ($pair in @(
    @("Text", "Surface"),
    @("MutedText", "Surface"),
    @("SidebarText", "Sidebar"),
    @("Surface", "Accent"),
    @("Surface", "Danger"),
    @("LogText", "LogSurface")
)) {
    $ratio = Get-ContrastRatio $theme.Colors[$pair[0]] $theme.Colors[$pair[1]]
    Assert-True ($ratio -ge 4.5) "Color pair $($pair[0])/$($pair[1]) has insufficient contrast: $ratio"
}

Assert-True ($theme.Metrics.SpacingBase -eq 8) "The visual system must use an 8px base spacing unit."
Assert-True ($theme.Metrics.RadiusSmall -ge 3 -and $theme.Metrics.RadiusSmall -le 6) "Small radius must stay restrained."
Assert-True ($theme.Metrics.RadiusMedium -ge 4 -and $theme.Metrics.RadiusMedium -le 8) "Medium radius must stay restrained."

$uiContent = Get-Content -LiteralPath $uiPath -Raw
Assert-True ($uiContent -match 'Import-PowerShellDataFile') "The GUI must load the semantic theme file."
Assert-True ($uiContent -match '(?m)^\$script:Language\s*=\s*"en"\s*$') "The GUI must start in English by default."
Assert-True ($uiContent -match 'New-InputFrame') "The GUI must provide a shared focused input frame."
Assert-True ($uiContent -match 'ProgressFill') "The GUI must use the themed deterministic progress fill."
Assert-True ($uiContent -match '\$focusBorderColor\s*=\s*\$script:Palette\.Accent') "Paint callbacks must capture their colors before entering a closure."
foreach ($component in @('searchFrame', 'listFrame', 'dialogFooter')) {
    Assert-True ($uiContent -match ('\$' + $component)) "The session picker must include its modern $component component."
}

Write-Host "Visual design contract test passed."
