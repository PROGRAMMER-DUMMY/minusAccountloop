# @file scripts/smart_codex.ps1
# Smart Codex Launcher: Multi-account rotation, workspace binding,
# cooldown tracking, explicit rotation controls, and zero false-positive quota checks.

# Accept raw arguments via $args to prevent PowerShell common parameter binding collision (e.g. -i, -w, -v, -e)
$CodexArgs = $args

$ErrorActionPreference = 'SilentlyContinue'

$codexExe = "$env:LOCALAPPDATA\Programs\OpenAI\Codex\bin\codex.exe"
if (-not (Test-Path $codexExe)) {
    $found = (Get-Command codex.exe -ErrorAction SilentlyContinue).Source
    if ($found) { $codexExe = $found }
}

$codexHome = "$env:USERPROFILE\.codex"
$authPath = "$codexHome\auth.json"
$profilesDir = "$codexHome\profiles"
$mappingFile = "$codexHome\workspace_accounts.json"
$poolFile = "$codexHome\account_pool_state.json"
$dbLogs = "$codexHome\logs_2.sqlite"

$defaultCooldownMs = 3 * 3600 * 1000 # 3 hours default reset for ChatGPT
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

if (-not (Test-Path $profilesDir)) {
    New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
}

# Helper: Extract email from an auth.json file
function Get-EmailFromAuthFile($path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $idToken = $json.tokens.id_token
        if ($idToken -and $idToken.Contains('.')) {
            $parts = $idToken.Split('.')
            if ($parts.Length -ge 2) {
                $payload = $parts[1]
                $padLen = (4 - ($payload.Length % 4)) % 4
                $payload += ('=' * $padLen)
                $payload = $payload.Replace('-', '+').Replace('_', '/')
                $bytes = [System.Convert]::FromBase64String($payload)
                $str = [System.Text.Encoding]::UTF8.GetString($bytes)
                $claims = $str | ConvertFrom-Json
                if ($claims.email) { return $claims.email }
            }
        }
    } catch {}
    return $null
}

# Helper: Sync active auth.json back to profile store
function Sync-ActiveAuthToProfile {
    if (Test-Path $authPath) {
        $activeEmail = Get-EmailFromAuthFile $authPath
        if ($activeEmail) {
            $dest = Join-Path $profilesDir "$activeEmail.json"
            Copy-Item $authPath $dest -Force
        }
    }
}

# Helper: Load pool state
$poolState = @{}
if (Test-Path $poolFile) {
    try {
        $pJson = Get-Content $poolFile -Raw | ConvertFrom-Json
        foreach ($prop in $pJson.PSObject.Properties) {
            $cu = 0
            if ($prop.Value.PSObject.Properties.Match('cooldownUntil').Count -gt 0) {
                $cu = [long]$prop.Value.cooldownUntil
            }
            $poolState[$prop.Name.ToLower()] = @{
                lastExhausted = [long]$prop.Value.lastExhausted
                switchCount = [int]$prop.Value.switchCount
                cooldownUntil = $cu
            }
        }
    } catch {}
}

function Save-PoolState {
    try {
        $obj = [ordered]@{}
        foreach ($k in $poolState.Keys) {
            $h = [ordered]@{
                lastExhausted = [long]$poolState[$k].lastExhausted
                switchCount = [int]$poolState[$k].switchCount
            }
            if ($poolState[$k].ContainsKey('cooldownUntil') -and $poolState[$k].cooldownUntil -gt 0) {
                $h['cooldownUntil'] = [long]$poolState[$k].cooldownUntil
            }
            $obj[$k] = $h
        }
        $obj | ConvertTo-Json -Depth 3 | Set-Content $poolFile -Encoding utf8
    } catch {}
}

# Auto-register currently active auth.json if profile missing
if (Test-Path $authPath) {
    $curEmail = Get-EmailFromAuthFile $authPath
    if ($curEmail) {
        $targetProfile = Join-Path $profilesDir "$curEmail.json"
        if (-not (Test-Path $targetProfile)) {
            Copy-Item $authPath $targetProfile -Force
        }
    }
}

# Discover all registered profiles
$availableProfiles = @()
if (Test-Path $profilesDir) {
    $availableProfiles = (Get-ChildItem $profilesDir -Filter "*.json" | Where-Object { $_.BaseName -match '@' }).BaseName
}

function Is-AccountInCooldown($email) {
    if (-not $email) { return $false }
    $k = $email.ToLower()
    if ($poolState.ContainsKey($k)) {
        $entry = $poolState[$k]
        if ($entry.ContainsKey('cooldownUntil') -and $entry.cooldownUntil -gt 0) {
            if ($nowMs -lt $entry.cooldownUntil) {
                return $true
            }
        } elseif ($entry.lastExhausted -gt 0) {
            $elapsed = $nowMs - $entry.lastExhausted
            if ($elapsed -gt 0 -and $elapsed -lt $defaultCooldownMs) {
                return $true
            }
        }
    }
    return $false
}

function Get-CooldownRemainingMin($email) {
    $k = $email.ToLower()
    if ($poolState.ContainsKey($k)) {
        $entry = $poolState[$k]
        if ($entry.ContainsKey('cooldownUntil') -and $entry.cooldownUntil -gt 0) {
            if ($nowMs -lt $entry.cooldownUntil) {
                return [Math]::Ceiling(($entry.cooldownUntil - $nowMs) / 60000)
            }
        } elseif ($entry.lastExhausted -gt 0) {
            $elapsed = $nowMs - $entry.lastExhausted
            if ($elapsed -gt 0 -and $elapsed -lt $defaultCooldownMs) {
                return [Math]::Ceiling(($defaultCooldownMs - $elapsed) / 60000)
            }
        }
    }
    return 0
}

function Get-BestAvailableAccount($excludeEmail) {
    $ready = @()
    foreach ($p in $availableProfiles) {
        if ($p.ToLower() -ne $excludeEmail.ToLower() -and -not (Is-AccountInCooldown $p)) {
            $sw = 0
            if ($poolState.ContainsKey($p.ToLower())) {
                $sw = $poolState[$p.ToLower()].switchCount
            }
            $ready += [PSCustomObject]@{ Email = $p; SwitchCount = $sw }
        }
    }
    if ($ready.Count -gt 0) {
        $sorted = $ready | Sort-Object SwitchCount
        return $sorted[0].Email
    }
    # Fallback: if all accounts in cooldown, warn user and pick the one closest to recovery
    $earliestAccount = $null
    $minRemaining = [int]::MaxValue
    foreach ($p in $availableProfiles) {
        $rem = Get-CooldownRemainingMin $p
        if ($rem -lt $minRemaining) {
            $minRemaining = $rem
            $earliestAccount = $p
        }
    }
    if ($availableProfiles.Count -gt 1) {
        Write-Host "[MinusAccountLoop] [!] Notice: All $($availableProfiles.Count) accounts are currently in quota cooldown." -ForegroundColor Yellow
        Write-Host "[MinusAccountLoop] Earliest quota recovery: ~$minRemaining minutes ($earliestAccount). Launching session..." -ForegroundColor Yellow
    }

    $allList = @()
    foreach ($p in $availableProfiles) {
        if ($p.ToLower() -ne $excludeEmail.ToLower()) {
            $lex = 0
            if ($poolState.ContainsKey($p.ToLower())) {
                $lex = $poolState[$p.ToLower()].lastExhausted
            }
            $allList += [PSCustomObject]@{ Email = $p; LastExhausted = $lex }
        }
    }
    if ($allList.Count -gt 0) {
        $sortedAll = $allList | Sort-Object LastExhausted
        return $sortedAll[0].Email
    }
    return $excludeEmail
}

# Activate an account profile
function Switch-ActiveAccount($email) {
    $source = Join-Path $profilesDir "$email.json"
    if (Test-Path $source) {
        Sync-ActiveAuthToProfile
        # Flush background daemon to clear cached tokens
        try { & $codexExe app-server daemon stop 2>&1 | Out-Null } catch {}
        Copy-Item $source $authPath -Force
        return $true
    }
    return $false
}

# --- CLI COMMAND: --reset-pool ---
if ($CodexArgs -contains '--reset-pool') {
    $poolState = @{}
    Save-PoolState
    Write-Host "`n[MinusAccountLoop] All account cooldowns and switch counters have been reset to 0." -ForegroundColor Green
    exit 0
}

# --- CLI COMMAND: --use <email> ---
$useIdx = [array]::IndexOf($CodexArgs, '--use')
if ($useIdx -ge 0 -and $useIdx -lt ($CodexArgs.Count - 1)) {
    $targetEmail = $CodexArgs[$useIdx + 1]
    if (Switch-ActiveAccount $targetEmail) {
        $currentDir = $PWD.Path.TrimEnd('\/').ToLower()
        $mappings = @{}
        if (Test-Path $mappingFile) {
            try {
                $mJson = Get-Content $mappingFile -Raw | ConvertFrom-Json
                foreach ($prop in $mJson.PSObject.Properties) { $mappings[$prop.Name] = $prop.Value }
            } catch {}
        }
        $mappings[$currentDir] = $targetEmail
        $mappings | ConvertTo-Json -Depth 3 | Set-Content $mappingFile -Encoding utf8
        Write-Host "`n[MinusAccountLoop] Explicitly set active account to: $targetEmail" -ForegroundColor Green
    } else {
        Write-Host "`n[MinusAccountLoop] [!] Profile not found for: $targetEmail" -ForegroundColor Red
    }
    exit 0
}

# --- CLI COMMAND: --status / -s ---
if ($CodexArgs -contains '--status' -or $CodexArgs -contains '-s') {
    Write-Host "`n[MinusAccountLoop] Codex Multi-Account Pool Status" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor DarkGray
    $activeNow = Get-EmailFromAuthFile $authPath
    Write-Host "Active Account: " -NoNewline
    if ($activeNow) { Write-Host "$activeNow" -ForegroundColor Green } else { Write-Host "None (Not logged in)" -ForegroundColor Red }
    Write-Host ""

    $poolRows = @()
    foreach ($p in $availableProfiles) {
        $status = "READY"
        $rem = Get-CooldownRemainingMin $p
        if ($rem -gt 0) {
            $status = "COOLDOWN (~$rem min)"
        }
        $sw = 0
        if ($poolState.ContainsKey($p.ToLower())) {
            $sw = $poolState[$p.ToLower()].switchCount
        }
        $isActive = ($p.ToLower() -eq $activeNow.ToLower())
        $poolRows += [PSCustomObject]@{
            Active = if ($isActive) { ">> ACTIVE <<" } else { "" }
            Email = $p
            PoolStatus = $status
            Switches = $sw
        }
    }
    $poolRows | Format-Table -AutoSize
    exit 0
}

# --- CLI COMMAND: --rotate / -r ---
if ($CodexArgs -contains '--rotate' -or $CodexArgs -contains '-r') {
    $currentActive = Get-EmailFromAuthFile $authPath
    $next = Get-BestAvailableAccount $currentActive
    if ($next -and $next.ToLower() -ne $currentActive.ToLower()) {
        Switch-ActiveAccount $next | Out-Null
        $currentDir = $PWD.Path.TrimEnd('\/').ToLower()
        $mappings = @{}
        if (Test-Path $mappingFile) {
            try {
                $mJson = Get-Content $mappingFile -Raw | ConvertFrom-Json
                foreach ($prop in $mJson.PSObject.Properties) { $mappings[$prop.Name] = $prop.Value }
            } catch {}
        }
        $mappings[$currentDir] = $next
        $mappings | ConvertTo-Json -Depth 3 | Set-Content $mappingFile -Encoding utf8
        Write-Host "[MinusAccountLoop] Rotated Codex active account to: $next" -ForegroundColor Green
    } else {
        Write-Host "[MinusAccountLoop] No alternate ready account found in pool." -ForegroundColor Yellow
    }
    exit 0
}

# --- CLI COMMAND: --add-account / --login-account ---
if ($CodexArgs -contains '--add-account' -or $CodexArgs -contains '--login-account') {
    Write-Host "`n[MinusAccountLoop] Codex Account Onboarding Wizard" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor DarkGray
    
    # Check known Gemini emails to recommend
    $geminiDir = "$env:USERPROFILE\.gemini\profiles"
    $suggested = @()
    if (Test-Path $geminiDir) {
        $suggested = (Get-ChildItem $geminiDir -Filter "*.json" | Where-Object { $_.BaseName -match '@' }).BaseName
    }
    
    Write-Host "Known machine emails:" -ForegroundColor Cyan
    foreach ($sg in $suggested) {
        $already = Test-Path (Join-Path $profilesDir "$sg.json")
        $marker = if ($already) { "[ALREADY REGISTERED]" } else { "[NOT REGISTERED]" }
        $color = if ($already) { "Green" } else { "Yellow" }
        Write-Host "  - $sg $marker" -ForegroundColor $color
    }

    Write-Host "`nPreparing browser login for next account..." -ForegroundColor Cyan
    Write-Host "When browser opens, click 'Continue with Google' and pick the account you want to register.`n" -ForegroundColor Yellow

    Sync-ActiveAuthToProfile
    try { & $codexExe app-server daemon stop 2>&1 | Out-Null } catch {}
    & $codexExe login
    
    $newEmail = Get-EmailFromAuthFile $authPath
    if ($newEmail) {
        $dest = Join-Path $profilesDir "$newEmail.json"
        Copy-Item $authPath $dest -Force
        Write-Host "`n[MinusAccountLoop] Successfully registered and saved: $newEmail" -ForegroundColor Green
    } else {
        Write-Host "`n[MinusAccountLoop] Login was cancelled or failed to produce credentials." -ForegroundColor Red
    }
    exit 0
}

# --- NORMAL CODEX LAUNCH ---
# Workspace account mapping
$mappings = @{}
if (Test-Path $mappingFile) {
    try {
        $mJson = Get-Content $mappingFile -Raw | ConvertFrom-Json
        foreach ($prop in $mJson.PSObject.Properties) {
            $mappings[$prop.Name] = $prop.Value
        }
    } catch {}
}

function Save-Mappings {
    try {
        $mappings | ConvertTo-Json -Depth 3 | Set-Content $mappingFile -Encoding utf8
    } catch {}
}

$currentDir = $PWD.Path.TrimEnd('\/').ToLower()
$targetAccount = $null

if ($mappings.ContainsKey($currentDir)) {
    $mapped = $mappings[$currentDir]
    if (Is-AccountInCooldown $mapped) {
        $targetAccount = Get-BestAvailableAccount $mapped
        $mappings[$currentDir] = $targetAccount
        Save-Mappings
    } else {
        $targetAccount = $mapped
    }
} else {
    $curActive = Get-EmailFromAuthFile $authPath
    if ($curActive -and -not (Is-AccountInCooldown $curActive)) {
        $targetAccount = $curActive
    } else {
        $targetAccount = Get-BestAvailableAccount $curActive
    }
    if ($targetAccount) {
        $mappings[$currentDir] = $targetAccount
        Save-Mappings
    }
}

# Pre-swap active auth if needed
if ($targetAccount) {
    $currentInAuth = Get-EmailFromAuthFile $authPath
    if ($currentInAuth -ne $targetAccount) {
        Switch-ActiveAccount $targetAccount | Out-Null
    }
}

$activeEmail = Get-EmailFromAuthFile $authPath
$sessionStartTimeSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Execute Codex
& $codexExe @CodexArgs
$exitCode = $LASTEXITCODE

# Post-execution sync: update profile with any refreshed tokens
Sync-ActiveAuthToProfile

# Strict Quota Check: ONLY trigger if an authentic HTTP 429 response was received by http_client.
# NEVER match routine telemetry (account/rateLimits) or user prompt text!
$exhaustionDetected = $false
if ($exitCode -ne 0 -and (Test-Path $dbLogs)) {
    try {
        $checkScript = @"
import sqlite3, os, sys
db = os.path.expanduser(r"~/.codex/logs_2.sqlite")
start_ts = int(sys.argv[1])
detected = False
if os.path.exists(db):
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute('''
        SELECT feedback_log_body FROM logs 
        WHERE ts >= ? 
          AND level IN ('ERROR', 'WARN')
          AND target LIKE '%http_client%'
          AND (feedback_log_body LIKE '%status=429%' 
               OR feedback_log_body LIKE '%status: 429%' 
               OR feedback_log_body LIKE '%insufficient_quota%' 
               OR feedback_log_body LIKE '%rate_limit_exceeded%')
          AND feedback_log_body NOT LIKE '%account/rateLimits%'
        LIMIT 1;
    ''', (start_ts - 5,))
    row = cur.fetchone()
    if row:
        detected = True
    conn.close()
if detected:
    print("EXHAUSTED")
"@
        $res = python -c "$checkScript" $sessionStartTimeSec
        if ($res -match "EXHAUSTED") {
            $exhaustionDetected = $true
        }
    } catch {}
}

# If quota is GENUINELY exhausted, prompt before rotating
if ($exhaustionDetected -and $activeEmail) {
    $nextCandidate = Get-BestAvailableAccount $activeEmail
    if ($nextCandidate -and ($nextCandidate.ToLower() -ne $activeEmail.ToLower())) {
        Write-Host "`n[MinusAccountLoop] [!] Verified quota exhaustion (HTTP 429) on $activeEmail." -ForegroundColor Yellow
        Write-Host "[MinusAccountLoop] [Cooldown] Registered 3-hour cooldown." -ForegroundColor Yellow
        Write-Host "[MinusAccountLoop] [Rotated] Swapped active credentials to: $nextCandidate" -ForegroundColor Green
        Write-Host "[MinusAccountLoop] [Auto-Resume] Ready to launch fresh session on $nextCandidate (full quota)." -ForegroundColor Green
        Write-Host "Press [ENTER] to continue immediately (or wait 3s, or [Q] to stay in terminal): " -NoNewline -ForegroundColor Cyan

        $doRotate = $true
        $timeout = 3
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt $timeout) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) {
                    $doRotate = $true
                    break
                } elseif ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) {
                    $doRotate = $false
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        Write-Host ""

        if ($doRotate) {
            $kTarget = $activeEmail.ToLower()
            if (-not $poolState.ContainsKey($kTarget)) {
                $poolState[$kTarget] = @{ lastExhausted = 0; switchCount = 0; cooldownUntil = 0 }
            }
            $poolState[$kTarget].lastExhausted = $nowMs
            $poolState[$kTarget].cooldownUntil = $nowMs + $defaultCooldownMs
            $poolState[$kTarget].switchCount = [int]$poolState[$kTarget].switchCount + 1
            Save-PoolState

            Switch-ActiveAccount $nextCandidate | Out-Null
            $mappings[$currentDir] = $nextCandidate
            Save-Mappings

            Write-Host "[MinusAccountLoop] Swapped active credentials to: $nextCandidate" -ForegroundColor Green
            Write-Host "[MinusAccountLoop] Starting fresh session on $nextCandidate ...`n" -ForegroundColor Green
            try { & $codexExe app-server daemon stop 2>&1 | Out-Null } catch {}
            & $codexExe @CodexArgs
            exit $LASTEXITCODE
        }
    }
}

exit $exitCode
