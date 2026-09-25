# @file scripts/resume.ps1
# Clean helper script to resume the AGY conversation matching the current terminal's directory ($PWD)
# Automatically detects and kills orphaned zombie sessions to prevent "Conversation already open" errors.

param(
    [string]$HistoryPath = "$env:USERPROFILE\.gemini\antigravity-cli\history.jsonl",
    [switch]$SkipPermissions = $true
)

$ErrorActionPreference = 'SilentlyContinue'

$agyArgs = @()
if ($SkipPermissions) {
    $agyArgs += '--dangerously-skip-permissions'
}

if (Test-Path $HistoryPath) {
    $targetPath = $PWD.Path.TrimEnd('\/').ToLower()
    # Find the most recent entry for this workspace that HAS a valid conversationId
    $entry = Get-Content $HistoryPath | ForEach-Object {
        try { ConvertFrom-Json $_ } catch {}
    } | Where-Object {
        $_.workspace -and $_.conversationId -and ($_.workspace.TrimEnd('\/').ToLower() -eq $targetPath)
    } | Select-Object -Last 1

    if ($entry -and $entry.conversationId) {
        $convId = $entry.conversationId

        # Auto-clean any zombie agy processes on this same conversation whose parent shell has died
        Get-CimInstance Win32_Process -Filter "Name = 'agy.exe'" | Where-Object {
            $_.CommandLine -match $convId -and $_.ProcessId -ne $PID
        } | ForEach-Object {
            $procId = $_.ProcessId
            $parent = Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue
            if (-not $parent) {
                Write-Host "[MinusAccountLoop] Cleaning up stale session lock (PID $procId)..." -ForegroundColor Yellow
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host "`n[MinusAccountLoop] Resuming conversation: $convId in $($PWD.Path)" -ForegroundColor Cyan
        $agyArgs += "--conversation=$convId"
        & "$env:LOCALAPPDATA\agy\bin\agy.exe" @agyArgs
        exit $LASTEXITCODE
    }
}

Write-Host "`n[MinusAccountLoop] Starting AGY session in $($PWD.Path)..." -ForegroundColor Cyan
& "$env:LOCALAPPDATA\agy\bin\agy.exe" @agyArgs
