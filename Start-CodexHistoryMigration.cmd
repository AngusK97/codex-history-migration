@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CodexHistoryMigration.UI.ps1"
