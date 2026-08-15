$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$cmdPath = Join-Path $repoRoot "Start-CodexHistoryMigration.cmd"
$vbsPath = Join-Path $repoRoot "Start-CodexHistoryMigration.vbs"

Assert-True (Test-Path -LiteralPath $vbsPath -PathType Leaf) `
    "The GUI must provide a Windows Script Host launcher so it can start without a console."

$cmdContent = Get-Content -LiteralPath $cmdPath -Raw
$vbsContent = Get-Content -LiteralPath $vbsPath -Raw

Assert-True ($cmdContent -match '(?i)wscript\.exe') `
    "The compatibility CMD entry point must delegate to wscript.exe."
Assert-True ($cmdContent -notmatch '(?i)powershell(?:\.exe)?') `
    "The compatibility CMD entry point must not host the PowerShell GUI directly."
Assert-True ($vbsContent -match '(?i)CodexHistoryMigration\.UI\.ps1') `
    "The hidden launcher must start CodexHistoryMigration.UI.ps1."
Assert-True ($vbsContent -match '(?i)\.Run\s+command\s*,\s*0\s*,\s*False') `
    "The hidden launcher must use window style 0 and must not wait for the GUI process."

Write-Host "Launcher regression test passed."
