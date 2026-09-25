# @file scripts/install.ps1
# MinusAccountLoop: One-Click Automated Installer for Windows
# Builds VSIX, installs into editor, and binds smart_agy to PowerShell profile.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Write-Host "`n🚀 [MinusAccountLoop] Starting Automated Installation...`n" -ForegroundColor Cyan

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$smartAgyPath = Join-Path $PSScriptRoot "smart_agy.ps1"

# 1. Verify Prerequisites
Write-Host "🔍 [1/4] Checking prerequisites..." -ForegroundColor Gray
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Host "❌ Error: Node.js is required but was not found on PATH." -ForegroundColor Red
    Write-Host "   Please install Node.js from https://nodejs.org/" -ForegroundColor Yellow
    exit 1
}
Write-Host "   ✅ Node.js detected: $(node --version)" -ForegroundColor Green

$codeCmd = Get-Command code, antigravity -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $codeCmd) {
    Write-Host "⚠️ Warning: 'code' or 'antigravity' command not found on PATH." -ForegroundColor Yellow
    Write-Host "   Extension packaging will continue, but manual VSIX install may be needed." -ForegroundColor Gray
} else {
    Write-Host "   ✅ Editor CLI detected: $($codeCmd.Name)" -ForegroundColor Green
}

# 2. Package VSIX
Write-Host "`n📦 [2/4] Packaging extension VSIX..." -ForegroundColor Gray
Set-Location $repoRoot
try {
    npx --yes @vscode/vsce package --no-dependencies
    $vsixFile = Get-ChildItem -Path $repoRoot -Filter "minus-account-loop-*.vsix" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $vsixFile) {
        throw "Failed to locate generated .vsix file."
    }
    Write-Host "   ✅ Packaged: $($vsixFile.Name)" -ForegroundColor Green
} catch {
    Write-Host "❌ Error during VSIX packaging: $_" -ForegroundColor Red
    exit 1
}

# 3. Install Extension into Editor
Write-Host "`n🧩 [3/4] Installing extension into editor..." -ForegroundColor Gray
if ($codeCmd) {
    try {
        & $codeCmd.Source --install-extension $vsixFile.FullName --force
        Write-Host "   ✅ Extension installed successfully into $($codeCmd.Name)!" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ Automatic install encountered an issue: $_" -ForegroundColor Yellow
        Write-Host "   You can install manually: $($codeCmd.Name) --install-extension '$($vsixFile.FullName)'" -ForegroundColor Gray
    }
} else {
    Write-Host "   ℹ️ Install manually by running: code --install-extension '$($vsixFile.FullName)'" -ForegroundColor Gray
}

# 4. Configure PowerShell Profile ($PROFILE)
Write-Host "`n⚡ [4/4] Configuring PowerShell profile for 'agy' command..." -ForegroundColor Gray

# Determine user profile locations (PowerShell 7 and Windows PowerShell 5.1)
$profileCandidates = @(
    $PROFILE.CurrentUserCurrentHost,
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PowerShell\Microsoft.PowerShell_profile.ps1"),
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) "WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
) | Where-Object { $_ } | Select-Object -Unique

$configuredAny = $false

foreach ($profPath in $profileCandidates) {
    try {
        $profDir = Split-Path $profPath -Parent
        if (-not (Test-Path $profDir)) {
            New-Item -ItemType Directory -Path $profDir -Force | Out-Null
        }
        
        $alreadyConfigured = $false
        if (Test-Path $profPath) {
            $content = Get-Content $profPath -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match 'smart_agy\.ps1') {
                $alreadyConfigured = $true
            }
        }

        if (-not $alreadyConfigured) {
            $profileBlock = @"

# MinusAccountLoop: Smart AGY launcher with per-workspace account binding & quota auto-rotation
function agy {
    & "$smartAgyPath" @args
}
"@
            Add-Content -Path $profPath -Value $profileBlock -Encoding utf8
            Write-Host "   ✅ Bound 'agy' function in: $profPath" -ForegroundColor Green
            $configuredAny = $true
        } else {
            Write-Host "   ℹ️ 'agy' function already present in: $profPath" -ForegroundColor Gray
            $configuredAny = $true
        }
    } catch {
        Write-Host "   ⚠️ Could not update $profPath: $_" -ForegroundColor Yellow
    }
}

Write-Host "`n🎉 [MinusAccountLoop] Installation Complete!" -ForegroundColor Green
Write-Host "──────────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "Try these commands in any project terminal:" -ForegroundColor Cyan
Write-Host "   agy                # Auto-binds workspace to dedicated Google account"
Write-Host "   agy -r             # Rotate current workspace to next ready account"
Write-Host "   agy status         # View real-time quota pool and cooldowns"
Write-Host "──────────────────────────────────────────────────────────────────`n" -ForegroundColor Gray
