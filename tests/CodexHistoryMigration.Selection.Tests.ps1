#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexHistorySelectionTestSqlite
{
    private const int SqliteOk = 0;
    private const int SqliteRow = 100;
    private const int SqliteDone = 101;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_open16")]
    private static extern int Open([MarshalAs(UnmanagedType.LPWStr)] string filename, out IntPtr database);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_close")]
    private static extern int Close(IntPtr database);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_prepare16_v2")]
    private static extern int Prepare(IntPtr database, [MarshalAs(UnmanagedType.LPWStr)] string sql, int length, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_step")]
    private static extern int Step(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_finalize")]
    private static extern int Finalize(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_column_int")]
    private static extern int ColumnInt(IntPtr statement, int column);

    public static void Execute(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), "open");
        try {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), "prepare");
            try {
                if (Step(statement) != SqliteDone) throw new InvalidOperationException("execute failed");
            }
            finally { Finalize(statement); }
        }
        finally { Close(database); }
    }

    public static int ScalarInt(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), "open");
        try {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), "prepare");
            try {
                if (Step(statement) != SqliteRow) throw new InvalidOperationException("query returned no row");
                return ColumnInt(statement, 0);
            }
            finally { Finalize(statement); }
        }
        finally { Close(database); }
    }

    private static void Ensure(int result, string operation)
    {
        if (result != SqliteOk) throw new InvalidOperationException(operation + " failed: " + result);
    }
}
'@

function Invoke-Migrator {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$ExpectFailure
    )

    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "CodexHistoryMigration.ps1"
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorPreference }
    if ($ExpectFailure) {
        if ($exitCode -eq 0) { throw "Migrator was expected to fail but succeeded." }
        return @($output)
    }
    if ($exitCode -ne 0) {
        throw "Migrator failed:`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-history-selection-{0}" -f [Guid]::NewGuid().ToString("N"))
$sourceHome = Join-Path $temporaryRoot "source"
$targetHome = Join-Path $temporaryRoot "target"
$archivePath = Join-Path $temporaryRoot "selected.zip"
$selectionFile = Join-Path $temporaryRoot "selection.txt"
$firstId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
$secondId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $sourceHome "sessions\2026\08\15")) | Out-Null
    [System.IO.Directory]::CreateDirectory($targetHome) | Out-Null

    foreach ($item in @(
        @{ Id = $firstId; Hour = "10"; Title = "Selected session" },
        @{ Id = $secondId; Hour = "11"; Title = "Excluded session" }
    )) {
        $path = Join-Path $sourceHome ("sessions\2026\08\15\rollout-2026-08-15T{0}-00-00-{1}.jsonl" -f $item.Hour, $item.Id)
        $line = [ordered]@{
            timestamp = "2026-08-15T$($item.Hour):00:00Z"
            type = "session_meta"
            payload = [ordered]@{ id = $item.Id; cwd = "D:\Projects\Test"; model_provider = "openai" }
        } | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::WriteAllText($path, $line + [Environment]::NewLine, $utf8NoBom)
    }

    $indexLines = @(
        ([ordered]@{ id = $firstId; title = "Selected session"; updated_at = "2026-08-15T10:00:00Z" } | ConvertTo-Json -Compress),
        ([ordered]@{ id = $secondId; thread_name = "Excluded session"; updated_at = "2026-08-15T11:00:00Z" } | ConvertTo-Json -Compress)
    )
    [System.IO.File]::WriteAllLines((Join-Path $sourceHome "session_index.jsonl"), $indexLines, $utf8NoBom)
    [System.IO.File]::WriteAllText($selectionFile, $firstId + [Environment]::NewLine, $utf8NoBom)

    $sourceDatabase = Join-Path $sourceHome "state_5.sqlite"
    $targetDatabase = Join-Path $targetHome "state_5.sqlite"
    $schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, model_provider TEXT, title TEXT, archived INTEGER NOT NULL DEFAULT 0)"
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, $schema)
    [CodexHistorySelectionTestSqlite]::Execute($targetDatabase, $schema)
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, "CREATE TABLE thread_dynamic_tools (thread_id TEXT, position INTEGER, name TEXT, PRIMARY KEY(thread_id, position))")
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT)")
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, "INSERT INTO threads VALUES ('$firstId', 'first.jsonl', 'openai', 'Selected session', 0)")
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, "INSERT INTO threads VALUES ('$secondId', 'second.jsonl', 'openai', 'Excluded session', 0)")
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, "INSERT INTO thread_dynamic_tools VALUES ('$firstId', 0, 'selected-tool')")
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, "INSERT INTO thread_dynamic_tools VALUES ('$secondId', 0, 'excluded-tool')")
    [CodexHistorySelectionTestSqlite]::Execute($sourceDatabase, "INSERT INTO thread_spawn_edges VALUES ('$firstId', '$secondId', 'closed')")

    $listOutput = Invoke-Migrator -Arguments @("-Mode", "List", "-CodexHome", $sourceHome)
    Assert-True (($listOutput -join "`n") -match $firstId -and ($listOutput -join "`n") -match $secondId) "List mode should return both source sessions."
    Assert-True (($listOutput -join "`n") -match "Selected session" -and ($listOutput -join "`n") -match "Excluded session") "List mode should support title and thread_name indexes."

    $exportOutput = Invoke-Migrator -Arguments @(
        "-Mode", "Export", "-CodexHome", $sourceHome, "-ArchivePath", $archivePath,
        "-SessionSelectionFile", $selectionFile, "-AllowRunningCodex"
    )
    Assert-True (($exportOutput -join "`n") -match 'progress\tpercent=100') "Export should report 100 percent."

    $extractRoot = Join-Path $temporaryRoot "extract"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $extractRoot)
    $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $extractRoot "manifest.json") | ConvertFrom-Json
    Assert-True ([int]$manifest.sessionCount -eq 1) "A partial export should contain one active session."
    Assert-True ([bool]$manifest.isPartialHistory) "A partial export should be marked in the manifest."
    Assert-True (@(Get-ChildItem (Join-Path $extractRoot "data\sessions") -Recurse -File -Filter "*.jsonl").Count -eq 1) "Only the selected transcript should be exported."
    $exportedIndex = Get-Content -Raw -Encoding UTF8 (Join-Path $extractRoot "data\session_index.jsonl")
    Assert-True ($exportedIndex.Contains($firstId) -and -not $exportedIndex.Contains($secondId)) "The exported title index should be filtered."
    $exportedDatabase = Join-Path $extractRoot "data\state_5.sqlite"
    Assert-True ([CodexHistorySelectionTestSqlite]::ScalarInt($exportedDatabase, "SELECT COUNT(*) FROM threads") -eq 1) "The exported desktop thread index should be filtered."
    Assert-True ([CodexHistorySelectionTestSqlite]::ScalarInt($exportedDatabase, "SELECT COUNT(*) FROM thread_dynamic_tools") -eq 1) "Per-thread tool metadata should be filtered."
    Assert-True ([CodexHistorySelectionTestSqlite]::ScalarInt($exportedDatabase, "SELECT COUNT(*) FROM thread_spawn_edges") -eq 0) "Edges to excluded sessions should be filtered."

    $overwriteTarget = Join-Path $temporaryRoot "overwrite-target"
    [System.IO.Directory]::CreateDirectory($overwriteTarget) | Out-Null
    $overwriteOutput = Invoke-Migrator -ExpectFailure -Arguments @(
        "-Mode", "Import", "-CodexHome", $overwriteTarget, "-ArchivePath", $archivePath,
        "-RestoreAppState", "-AllowRunningCodex"
    )
    Assert-True (($overwriteOutput -join "`n") -match "partial history archive") "A partial archive must reject full desktop-state overwrite."

    $importOutput = Invoke-Migrator -Arguments @(
        "-Mode", "Import", "-CodexHome", $targetHome, "-ArchivePath", $archivePath,
        "-SessionSelectionFile", $selectionFile, "-AllowRunningCodex"
    )
    Assert-True (($importOutput -join "`n") -match 'progress\tpercent=100') "Import should report 100 percent."
    Assert-True (@(Get-ChildItem (Join-Path $targetHome "sessions") -Recurse -File -Filter "*.jsonl").Count -eq 1) "Only the selected transcript should be restored."
    Assert-True ([CodexHistorySelectionTestSqlite]::ScalarInt($targetDatabase, "SELECT COUNT(*) FROM threads") -eq 1) "Only the selected desktop thread row should be restored."
    Assert-True (-not (Test-Path (Join-Path $targetHome "archived_sessions") -PathType Container)) "No unrelated archived sessions should be restored."

    Write-Host "PASS: session selection filters export and restore data and reports deterministic progress."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolved = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $expectedParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
        if ((Split-Path -Parent $resolved).TrimEnd('\') -ne $expectedParent) {
            throw "Refusing to remove unexpected test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
