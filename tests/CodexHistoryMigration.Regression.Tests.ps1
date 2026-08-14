#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexHistoryTestSqlite
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

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_errmsg16")]
    private static extern IntPtr ErrorMessage(IntPtr database);

    public static void Execute(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), IntPtr.Zero, "open database");
        try
        {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), database, "prepare statement");
            try
            {
                int result = sqlite3_step(statement);
                if (result != SqliteDone)
                {
                    throw new InvalidOperationException("execute statement failed: " + GetError(database));
                }
            }
            finally
            {
                sqlite3_finalize(statement);
            }
        }
        finally
        {
            sqlite3_close(database);
        }
    }

    public static int ScalarInt(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), IntPtr.Zero, "open database");
        try
        {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), database, "prepare query");
            try
            {
                int result = sqlite3_step(statement);
                if (result != SqliteRow)
                {
                    throw new InvalidOperationException("query returned no row: " + GetError(database));
                }
                return sqlite3_column_int(statement, 0);
            }
            finally
            {
                sqlite3_finalize(statement);
            }
        }
        finally
        {
            sqlite3_close(database);
        }
    }

    public static string ScalarText(string databasePath, string sql)
    {
        IntPtr database;
        Ensure(Open(databasePath, out database), IntPtr.Zero, "open database");
        try
        {
            IntPtr statement;
            Ensure(Prepare(database, sql, -1, out statement, IntPtr.Zero), database, "prepare query");
            try
            {
                int result = sqlite3_step(statement);
                if (result != SqliteRow)
                {
                    throw new InvalidOperationException("query returned no row: " + GetError(database));
                }
                IntPtr value = ColumnText(statement, 0);
                return value == IntPtr.Zero ? null : Marshal.PtrToStringUni(value);
            }
            finally
            {
                sqlite3_finalize(statement);
            }
        }
        finally
        {
            sqlite3_close(database);
        }
    }

    private static void Ensure(int result, IntPtr database, string operation)
    {
        if (result != SqliteOk)
        {
            throw new InvalidOperationException(operation + " failed: " + GetError(database));
        }
    }

    private static string GetError(IntPtr database)
    {
        if (database == IntPtr.Zero)
        {
            return "unknown SQLite error";
        }
        IntPtr message = ErrorMessage(database);
        return message == IntPtr.Zero ? "unknown SQLite error" : Marshal.PtrToStringUni(message);
    }
}
'@

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Invoke-Migrator {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "CodexHistoryMigration.ps1"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Migrator failed:`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-history-regression-{0}" -f [Guid]::NewGuid().ToString("N"))
$sourceHome = Join-Path $temporaryRoot "source-home"
$targetHome = Join-Path $temporaryRoot "target-home"
$archivePath = Join-Path $temporaryRoot "history.zip"
$sourceId = "11111111-1111-4111-8111-111111111111"
$targetId = "22222222-2222-4222-8222-222222222222"
$relativeSession = "sessions\2026\08\14\rollout-2026-08-14T12-00-00-$sourceId.jsonl"
$sourceSession = Join-Path $sourceHome $relativeSession
$targetSession = Join-Path $targetHome $relativeSession
$sourceDatabase = Join-Path $sourceHome "state_5.sqlite"
$targetDatabase = Join-Path $targetHome "state_5.sqlite"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

try {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $sourceSession)) | Out-Null
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $targetSession)) | Out-Null

    $sessionLine = [ordered]@{
        timestamp = "2026-08-14T12:00:00Z"
        type = "session_meta"
        payload = [ordered]@{
            id = $sourceId
            cwd = "Z:\OldComputer\Project"
            model_provider = "old-provider"
        }
    } | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText($sourceSession, $sessionLine + [Environment]::NewLine, $utf8NoBom)
    [System.IO.File]::WriteAllText(
        $targetSession,
        $sessionLine.Replace('"old-provider"', '"new-provider"') + [Environment]::NewLine,
        $utf8NoBom
    )

    $sourceIndexLine = [ordered]@{ id = $sourceId; title = "Imported thread"; updated_at = "2026-08-14T12:00:00Z" } | ConvertTo-Json -Compress
    $targetIndexLine = [ordered]@{ id = $targetId; title = "Target thread"; updated_at = "2026-08-14T13:00:00Z" } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllLines((Join-Path $sourceHome "session_index.jsonl"), @($sourceIndexLine), $utf8NoBom)
    [System.IO.File]::WriteAllLines((Join-Path $targetHome "session_index.jsonl"), @($targetIndexLine, $sourceIndexLine), $utf8NoBom)

    $schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, model_provider TEXT, title TEXT, archived INTEGER NOT NULL DEFAULT 0)"
    [CodexHistoryTestSqlite]::Execute($sourceDatabase, $schema)
    [CodexHistoryTestSqlite]::Execute($targetDatabase, $schema)
    $escapedSourcePath = $sourceSession.Replace("'", "''")
    [CodexHistoryTestSqlite]::Execute($sourceDatabase, "INSERT INTO threads (id, rollout_path, model_provider, title, archived) VALUES ('$sourceId', '$escapedSourcePath', 'old-provider', 'Imported thread', 0)")
    [CodexHistoryTestSqlite]::Execute($targetDatabase, "INSERT INTO threads (id, rollout_path, model_provider, title, archived) VALUES ('$targetId', 'target-existing.jsonl', 'target-provider', 'Target thread', 0)")

    Invoke-Migrator -Arguments @("-Mode", "Export", "-CodexHome", $sourceHome, "-ArchivePath", $archivePath, "-AllowRunningCodex") | Out-Null
    $importOutput = Invoke-Migrator -Arguments @(
        "-Mode", "Import",
        "-CodexHome", $targetHome,
        "-ArchivePath", $archivePath,
        "-RewriteModelProvider",
        "-TargetModelProvider", "new-provider",
        "-AllowRunningCodex"
    )
    $importOutput | ForEach-Object { Write-Host $_ }

    Assert-Equal -Expected 2 -Actual ([CodexHistoryTestSqlite]::ScalarInt($targetDatabase, "SELECT COUNT(*) FROM threads")) `
        -Message "Import should preserve the target row and add the source row."
    Assert-Equal -Expected $targetSession -Actual ([CodexHistoryTestSqlite]::ScalarText($targetDatabase, "SELECT rollout_path FROM threads WHERE id = '$sourceId'")) `
        -Message "Imported rollout_path should point to the target computer."
    Assert-Equal -Expected "new-provider" -Actual ([CodexHistoryTestSqlite]::ScalarText($targetDatabase, "SELECT model_provider FROM threads WHERE id = '$sourceId'")) `
        -Message "Imported provider should use the requested target provider."
    Assert-Equal -Expected "target-provider" -Actual ([CodexHistoryTestSqlite]::ScalarText($targetDatabase, "SELECT model_provider FROM threads WHERE id = '$targetId'")) `
        -Message "The existing target row should not be modified."

    Write-Host "PASS: imports missing SQLite thread rows for transcripts already present at the target."

    $mismatchSourceHome = Join-Path $temporaryRoot "mismatch-source-home"
    $mismatchTargetHome = Join-Path $temporaryRoot "mismatch-target-home"
    $mismatchArchive = Join-Path $temporaryRoot "mismatch-history.zip"
    $mismatchSourceId = "33333333-3333-4333-8333-333333333333"
    $mismatchTargetId = "44444444-4444-4444-8444-444444444444"
    $mismatchRelativeSession = "sessions\2026\08\14\rollout-2026-08-14T14-00-00-$mismatchSourceId.jsonl"
    $mismatchSourceSession = Join-Path $mismatchSourceHome $mismatchRelativeSession
    $mismatchTargetSession = Join-Path $mismatchTargetHome $mismatchRelativeSession
    $mismatchSourceDatabase = Join-Path $mismatchSourceHome "state_5.sqlite"
    $mismatchTargetDatabase = Join-Path $mismatchTargetHome "state_5.sqlite"

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $mismatchSourceSession)) | Out-Null
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $mismatchTargetSession)) | Out-Null
    $mismatchSessionLine = [ordered]@{
        timestamp = "2026-08-14T14:00:00Z"
        type = "session_meta"
        payload = [ordered]@{
            id = $mismatchSourceId
            cwd = "Z:\OldComputer\Mismatch"
            model_provider = "old-provider"
        }
    } | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText($mismatchSourceSession, $mismatchSessionLine + [Environment]::NewLine, $utf8NoBom)
    [System.IO.File]::WriteAllText(
        $mismatchTargetSession,
        $mismatchSessionLine.Replace('"old-provider"', '"new-provider"') + [Environment]::NewLine,
        $utf8NoBom
    )
    $mismatchIndexLine = [ordered]@{ id = $mismatchSourceId; title = "Mismatch source"; updated_at = "2026-08-14T14:00:00Z" } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllLines((Join-Path $mismatchSourceHome "session_index.jsonl"), @($mismatchIndexLine), $utf8NoBom)
    [System.IO.File]::WriteAllLines((Join-Path $mismatchTargetHome "session_index.jsonl"), @($mismatchIndexLine), $utf8NoBom)

    $reorderedSchema = "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT, rollout_path TEXT NOT NULL, title TEXT, archived INTEGER NOT NULL DEFAULT 0)"
    [CodexHistoryTestSqlite]::Execute($mismatchSourceDatabase, $reorderedSchema)
    [CodexHistoryTestSqlite]::Execute($mismatchTargetDatabase, $schema)
    $escapedMismatchSourcePath = $mismatchSourceSession.Replace("'", "''")
    [CodexHistoryTestSqlite]::Execute($mismatchSourceDatabase, "INSERT INTO threads (id, rollout_path, model_provider, title, archived) VALUES ('$mismatchSourceId', '$escapedMismatchSourcePath', 'old-provider', 'Mismatch source', 0)")
    [CodexHistoryTestSqlite]::Execute($mismatchTargetDatabase, "INSERT INTO threads (id, rollout_path, model_provider, title, archived) VALUES ('$mismatchTargetId', 'target-existing.jsonl', 'target-provider', 'Mismatch target', 0)")

    Invoke-Migrator -Arguments @("-Mode", "Export", "-CodexHome", $mismatchSourceHome, "-ArchivePath", $mismatchArchive, "-AllowRunningCodex") | Out-Null
    $mismatchOutput = Invoke-Migrator -Arguments @(
        "-Mode", "Import",
        "-CodexHome", $mismatchTargetHome,
        "-ArchivePath", $mismatchArchive,
        "-RewriteModelProvider",
        "-TargetModelProvider", "new-provider",
        "-AllowRunningCodex"
    )
    $mismatchOutput | ForEach-Object { Write-Host $_ }

    Assert-Equal -Expected 1 -Actual ([CodexHistoryTestSqlite]::ScalarInt($mismatchTargetDatabase, "SELECT COUNT(*) FROM threads")) `
        -Message "A mismatched source schema must not be merged."
    if (($mismatchOutput -join [Environment]::NewLine) -notmatch "different\s+column layouts") {
        throw "A mismatched source schema should emit a diagnostic warning."
    }
    Write-Host "PASS: skips SQLite thread merge when source and target column layouts differ."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $expectedParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
        if ((Split-Path -Parent $resolvedTemporaryRoot).TrimEnd('\') -ne $expectedParent) {
            throw "Refusing to remove unexpected test path: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
