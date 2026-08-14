#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexHistoryManagementTestSqlite
{
    private const int SqliteOk = 0;
    private const int SqliteRow = 100;
    private const int SqliteDone = 101;

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
    private static extern int sqlite3_column_int(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_column_text16")]
    private static extern IntPtr ColumnText(IntPtr statement, int column);

    public static void Execute(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), "open");
        try {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), "prepare");
            try {
                if (sqlite3_step(statement) != SqliteDone) throw new InvalidOperationException("execute failed");
            }
            finally { sqlite3_finalize(statement); }
        }
        finally { sqlite3_close(database); }
    }

    public static int ScalarInt(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), "open");
        try {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), "prepare");
            try {
                if (sqlite3_step(statement) != SqliteRow) throw new InvalidOperationException("query returned no row");
                return sqlite3_column_int(statement, 0);
            }
            finally { sqlite3_finalize(statement); }
        }
        finally { sqlite3_close(database); }
    }

    public static string ScalarText(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), "open");
        try {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), "prepare");
            try {
                if (sqlite3_step(statement) != SqliteRow) throw new InvalidOperationException("query returned no row");
                IntPtr value = ColumnText(statement, 0);
                return value == IntPtr.Zero ? null : Marshal.PtrToStringUni(value);
            }
            finally { sqlite3_finalize(statement); }
        }
        finally { sqlite3_close(database); }
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

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-history-management-{0}" -f [Guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $temporaryRoot "home"
$selectionFile = Join-Path $temporaryRoot "selection.txt"
$firstId = "11111111-aaaa-4111-8111-111111111111"
$secondId = "22222222-bbbb-4222-8222-222222222222"
$firstSession = Join-Path $codexHome "sessions\2026\08\15\rollout-first.jsonl"
$secondSession = Join-Path $codexHome "archived_sessions\rollout-second.jsonl"
$databasePath = Join-Path $codexHome "state_5.sqlite"
$legacyDatabasePath = Join-Path $codexHome "state_4.sqlite"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

try {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $firstSession)) | Out-Null
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $secondSession)) | Out-Null

    foreach ($item in @(
        @{ Id = $firstId; Path = $firstSession; Provider = "old-provider"; Hour = "10" },
        @{ Id = $secondId; Path = $secondSession; Provider = "keep-provider"; Hour = "11" }
    )) {
        $line = [ordered]@{
            timestamp = "2026-08-15T$($item.Hour):00:00Z"
            type = "session_meta"
            payload = [ordered]@{ id = $item.Id; cwd = "D:\Projects\Test"; model_provider = $item.Provider }
        } | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::WriteAllText($item.Path, $line + [Environment]::NewLine, $utf8NoBom)
    }

    $indexLines = @(
        ([ordered]@{ id = $firstId; title = "Change provider"; updated_at = "2026-08-15T10:00:00Z" } | ConvertTo-Json -Compress),
        ([ordered]@{ id = $secondId; thread_name = "Keep session"; updated_at = "2026-08-15T11:00:00Z" } | ConvertTo-Json -Compress)
    )
    [System.IO.File]::WriteAllLines((Join-Path $codexHome "session_index.jsonl"), $indexLines, $utf8NoBom)
    [System.IO.File]::WriteAllText($selectionFile, $firstId + [Environment]::NewLine, $utf8NoBom)

    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, model_provider TEXT, title TEXT, archived INTEGER NOT NULL DEFAULT 0)")
    [CodexHistoryManagementTestSqlite]::Execute($legacyDatabasePath, "CREATE TABLE legacy_state (name TEXT PRIMARY KEY)")
    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "CREATE TABLE thread_dynamic_tools (thread_id TEXT NOT NULL, position INTEGER NOT NULL, name TEXT NOT NULL)")
    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL, status TEXT NOT NULL)")
    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "INSERT INTO threads VALUES ('$firstId', 'first.jsonl', 'old-provider', 'Change provider', 0)")
    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "INSERT INTO threads VALUES ('$secondId', 'second.jsonl', 'keep-provider', 'Keep session', 1)")
    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "INSERT INTO thread_dynamic_tools VALUES ('$firstId', 0, 'first-tool')")
    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "INSERT INTO thread_dynamic_tools VALUES ('$secondId', 0, 'second-tool')")
    [CodexHistoryManagementTestSqlite]::Execute($databasePath, "INSERT INTO thread_spawn_edges VALUES ('$firstId', '$secondId', 'closed')")

    $listOutput = Invoke-Migrator -Arguments @("-Mode", "List", "-CodexHome", $codexHome)
    Assert-True (($listOutput -join "`n") -match '"provider":"old-provider"') "List mode should expose each session's current provider."

    $missingSelection = Invoke-Migrator -ExpectFailure -Arguments @(
        "-Mode", "SetProvider", "-CodexHome", $codexHome,
        "-TargetModelProvider", "new-provider", "-AllowRunningCodex"
    )
    Assert-True (($missingSelection -join "`n") -match "Session selection is required") "Provider updates must require explicit session selection."

    $providerOutput = Invoke-Migrator -Arguments @(
        "-Mode", "SetProvider", "-CodexHome", $codexHome,
        "-SessionSelectionFile", $selectionFile,
        "-TargetModelProvider", "new-provider", "-AllowRunningCodex"
    )
    Assert-True (($providerOutput -join "`n") -match 'progress\tpercent=100') "Provider updates should report 100 percent."
    Assert-True (($providerOutput -join "`n") -match 'backup created\tarchive=') "Provider updates should create a rollback ZIP."
    Assert-True ((Get-Content -Raw -Encoding UTF8 $firstSession) -match '"model_provider":"new-provider"') "The selected transcript provider should be updated."
    Assert-True ((Get-Content -Raw -Encoding UTF8 $secondSession) -match '"model_provider":"keep-provider"') "Unselected transcripts must remain unchanged."
    Assert-True ([CodexHistoryManagementTestSqlite]::ScalarText($databasePath, "SELECT model_provider FROM threads WHERE id = '$firstId'") -eq "new-provider") "The selected SQLite thread provider should be updated."
    Assert-True ([CodexHistoryManagementTestSqlite]::ScalarText($databasePath, "SELECT model_provider FROM threads WHERE id = '$secondId'") -eq "keep-provider") "Unselected SQLite threads must remain unchanged."
    $providerBackup = Get-ChildItem (Join-Path $temporaryRoot "codex-history-backups") -File -Filter "codex-history-before-set-provider-*.zip" | Select-Object -First 1
    $providerBackupExtract = Join-Path $temporaryRoot "provider-backup"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($providerBackup.FullName, $providerBackupExtract)
    $backedUpFirstSession = Get-ChildItem (Join-Path $providerBackupExtract "data\sessions") -Recurse -File -Filter "*.jsonl" | Select-Object -First 1
    Assert-True ((Get-Content -Raw -Encoding UTF8 $backedUpFirstSession.FullName) -match '"model_provider":"old-provider"') "The pre-update backup should preserve the original provider."

    $missingDeleteSelection = Invoke-Migrator -ExpectFailure -Arguments @(
        "-Mode", "Delete", "-CodexHome", $codexHome, "-AllowRunningCodex"
    )
    Assert-True (($missingDeleteSelection -join "`n") -match "Session selection is required") "Deletion must require explicit session selection."

    $deleteOutput = Invoke-Migrator -Arguments @(
        "-Mode", "Delete", "-CodexHome", $codexHome,
        "-SessionSelectionFile", $selectionFile, "-AllowRunningCodex"
    )
    Assert-True (($deleteOutput -join "`n") -match 'progress\tpercent=100') "Deletion should report 100 percent."
    Assert-True (($deleteOutput -join "`n") -match 'backup created\tarchive=') "Deletion should create a rollback ZIP."
    Assert-True (-not (Test-Path -LiteralPath $firstSession -PathType Leaf)) "The selected transcript should be deleted."
    Assert-True (Test-Path -LiteralPath $secondSession -PathType Leaf) "Unselected transcripts must remain."
    $remainingIndex = Get-Content -Raw -Encoding UTF8 (Join-Path $codexHome "session_index.jsonl")
    Assert-True (-not $remainingIndex.Contains($firstId) -and $remainingIndex.Contains($secondId)) "Only selected title-index rows should be removed."
    Assert-True ([CodexHistoryManagementTestSqlite]::ScalarInt($databasePath, "SELECT COUNT(*) FROM threads WHERE id = '$firstId'") -eq 0) "The selected thread row should be deleted."
    Assert-True ([CodexHistoryManagementTestSqlite]::ScalarInt($databasePath, "SELECT COUNT(*) FROM thread_dynamic_tools WHERE thread_id = '$firstId'") -eq 0) "Selected dynamic-tool rows should be deleted."
    Assert-True ([CodexHistoryManagementTestSqlite]::ScalarInt($databasePath, "SELECT COUNT(*) FROM thread_spawn_edges WHERE parent_thread_id = '$firstId' OR child_thread_id = '$firstId'") -eq 0) "Spawn edges involving selected sessions should be deleted."
    Assert-True ([CodexHistoryManagementTestSqlite]::ScalarInt($databasePath, "SELECT COUNT(*) FROM threads WHERE id = '$secondId'") -eq 1) "Unselected thread rows must remain."
    Assert-True (@(Get-ChildItem (Join-Path $temporaryRoot "codex-history-backups") -File -Filter "*.zip").Count -eq 2) "Each management operation should create its own rollback ZIP."

    Write-Host "PASS: session management updates providers and removes only explicitly selected history."
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
