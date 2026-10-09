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
$activeSessionsDir = "$codexHome\active_sessions"

$defaultCooldownMs = 3 * 3600 * 1000 # 3 hours default reset for ChatGPT
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

if (-not (Test-Path $activeSessionsDir)) {
    New-Item -ItemType Directory -Path $activeSessionsDir -Force | Out-Null
}

# 1. Clean orphaned zombie codex processes across the machine (parent already exited)
Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" | ForEach-Object {
    $procId = $_.ProcessId
    $parentId = $_.ParentProcessId
    $parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
    if (-not $parent) {
        Stop-Process -Id $procId -ErrorAction SilentlyContinue
        # Clean any lock tied to this terminated process
        if (Test-Path $activeSessionsDir) {
            Get-ChildItem $activeSessionsDir -Filter "*.lock" | ForEach-Object {
                try {
                    $lContent = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    if ($lContent.pid -eq $procId) {
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
            }
        }
    }
}

# 2. Clear stale maintenance locks
$staleMaintLock = "$codexHome\.sqlite-maintenance.lock"
if (Test-Path $staleMaintLock) {
    Remove-Item $staleMaintLock -Force -ErrorAction SilentlyContinue
}

# 3. Helper: Auto-trust workspace in config.toml and auto.config.toml (eliminates trust prompts)
function Ensure-WorkspaceTrusted($dir) {
    if (-not $dir) { return }
    $cleanDir = $dir.TrimEnd('\/').ToLower()
    foreach ($cfgName in @("config.toml", "auto.config.toml")) {
        $cFile = Join-Path $codexHome $cfgName
        if (Test-Path $cFile) {
            try {
                $content = Get-Content $cFile -Raw
                $needle = "[projects.'$cleanDir']"
                if ($content -notmatch [regex]::Escape($needle)) {
                    $block = "`n[projects.'$cleanDir']`ntrust_level = `"trusted`"`n"
                    Add-Content -Path $cFile -Value $block -Encoding utf8
                }
            } catch {}
        }
    }
}

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
            $ar = $false
            if ($prop.Value.PSObject.Properties.Match('authRevoked').Count -gt 0) {
                $ar = [bool]$prop.Value.authRevoked
            }
            $poolState[$prop.Name.ToLower()] = @{
                lastExhausted = [long]$prop.Value.lastExhausted
                switchCount = [int]$prop.Value.switchCount
                cooldownUntil = $cu
                authRevoked = $ar
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
            if ($poolState[$k].ContainsKey('authRevoked') -and $poolState[$k].authRevoked) {
                $h['authRevoked'] = $true
            } else {
                $h['authRevoked'] = $false
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

function Is-AccountRevoked($email) {
    if (-not $email) { return $false }
    $k = $email.ToLower()
    if ($poolState.ContainsKey($k) -and $poolState[$k].authRevoked) {
        return $true
    }
    return $false
}

function Get-ActiveSessionPid($email) {
    if (-not $email) { return 0 }
    $lockPath = Join-Path $activeSessionsDir "$($email.ToLower()).lock"
    if (Test-Path $lockPath) {
        try {
            $lockContent = Get-Content $lockPath -Raw | ConvertFrom-Json
            $lockPid = [int]$lockContent.pid
            if ($lockPid -ne $PID) {
                $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                if ($proc -and -not $proc.HasExited) {
                    return $lockPid
                }
            }
        } catch {}
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
    }
    return 0
}

function Is-AccountInActiveSession($email) {
    return ((Get-ActiveSessionPid $email) -gt 0)
}

function Get-BestAvailableAccount($excludeEmail) {
    $ready = @()
    foreach ($p in $availableProfiles) {
        $isBusy = Is-AccountInActiveSession $p
        $inCd = Is-AccountInCooldown $p
        $isRev = Is-AccountRevoked $p
        if ($p.ToLower() -ne $excludeEmail.ToLower() -and -not $isRev -and -not $inCd -and -not $isBusy) {
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

    # If excludeEmail is not busy, not revoked, and not in cooldown, it is usable
    if (-not (Is-AccountInActiveSession $excludeEmail) -and -not (Is-AccountRevoked $excludeEmail) -and -not (Is-AccountInCooldown $excludeEmail)) {
        return $excludeEmail
    }

    # Fallback: if all valid accounts in cooldown, pick non-busy account closest to recovery
    $earliestAccount = $null
    $minRemaining = [int]::MaxValue
    foreach ($p in $availableProfiles) {
        if (-not (Is-AccountRevoked $p) -and -not (Is-AccountInActiveSession $p)) {
            $rem = Get-CooldownRemainingMin $p
            if ($rem -lt $minRemaining) {
                $minRemaining = $rem
                $earliestAccount = $p
            }
        }
    }
    if ($earliestAccount) {
        Write-Host "[MinusAccountLoop] [!] All idle accounts are in cooldown." -ForegroundColor Yellow
        Write-Host "[MinusAccountLoop] Earliest recovery: ~$minRemaining minutes ($earliestAccount). Launching session..." -ForegroundColor Yellow
        return $earliestAccount
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
        $activePid = Get-ActiveSessionPid $p
        $status = "READY"
        if ($activePid -gt 0) {
            $status = "IN USE (PID $activePid)"
        } elseif (Is-AccountRevoked $p) {
            $status = "REVOKED (codex --login-account)"
        } else {
            $rem = Get-CooldownRemainingMin $p
            if ($rem -gt 0) {
                $status = "COOLDOWN (~$rem min)"
            }
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
        $kNew = $newEmail.ToLower()
        if (-not $poolState.ContainsKey($kNew)) {
            $poolState[$kNew] = @{ lastExhausted = 0; switchCount = 0; cooldownUntil = 0; authRevoked = $false }
        } else {
            $poolState[$kNew].authRevoked = $false
        }
        Save-PoolState
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

# Parse and normalize arguments (translate -c or --continue to resume --last)
$isContinue = $false
$finalArgs = @()
$skipNext = $false

for ($idx = 0; $idx -lt $CodexArgs.Count; $idx++) {
    if ($skipNext) {
        $skipNext = $false
        continue
    }
    $curr = $CodexArgs[$idx]
    if ($curr -eq '--continue') {
        $isContinue = $true
        continue
    } elseif ($curr -eq '-c') {
        $next = if (($idx + 1) -lt $CodexArgs.Count) { $CodexArgs[$idx + 1] } else { $null }
        if (-not $next -or $next.StartsWith('-') -or ($next -notmatch '=')) {
            $isContinue = $true
            continue
        } else {
            $finalArgs += $curr
            $finalArgs += $next
            $skipNext = $true
            continue
        }
    }
    $finalArgs += $curr
}

if ($isContinue -and ($finalArgs -notcontains 'resume')) {
    $finalArgs = @('resume', '--last') + $finalArgs
}

if ($mappings.ContainsKey($currentDir)) {
    $mapped = $mappings[$currentDir]
    $isBusy = Is-AccountInActiveSession $mapped
    if (Is-AccountInCooldown $mapped -or (Is-AccountRevoked $mapped) -or $isBusy) {
        $targetAccount = Get-BestAvailableAccount $mapped
        if ($targetAccount -and ($targetAccount.ToLower() -ne $mapped.ToLower())) {
            if ($isBusy) {
                Write-Host "`n[MinusAccountLoop] [Active Session] $mapped is running in another terminal." -ForegroundColor Cyan
                Write-Host "[MinusAccountLoop] [Auto-Switch] Automatically assigned idle account: $targetAccount" -ForegroundColor Green
            } else {
                $mappings[$currentDir] = $targetAccount
                Save-Mappings
            }
        }
    } else {
        $targetAccount = $mapped
    }
} else {
    $assignedEmails = $mappings.Values
    $unassigned = $availableProfiles | Where-Object { $assignedEmails -notcontains $_ -and -not (Is-AccountRevoked $_) -and -not (Is-AccountInCooldown $_) -and -not (Is-AccountInActiveSession $_) }
    if ($unassigned -and $unassigned.Count -gt 0) {
        $targetAccount = $unassigned[0]
    } else {
        $curActive = Get-EmailFromAuthFile $authPath
        if ($curActive -and -not (Is-AccountInCooldown $curActive) -and -not (Is-AccountRevoked $curActive) -and -not (Is-AccountInActiveSession $curActive)) {
            $targetAccount = $curActive
        } else {
            $targetAccount = Get-BestAvailableAccount $curActive
        }
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

# Ensure directory is trusted so Codex never prompts with folder trust questions
Ensure-WorkspaceTrusted $PWD.Path

$activeEmail = Get-EmailFromAuthFile $authPath
$sessionStartTimeSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Register active session lock for this terminal
$myLockFile = Join-Path $activeSessionsDir "$($activeEmail.ToLower()).lock"
try {
    $lockData = @{ pid = $PID; workspace = $PWD.Path; startTime = $nowMs } | ConvertTo-Json -Compress
    Set-Content -Path $myLockFile -Value $lockData -Encoding utf8
} catch {}

# Execute Codex
try {
    & $codexExe @finalArgs
    $exitCode = $LASTEXITCODE
} finally {
    if (Test-Path $myLockFile) {
        Remove-Item $myLockFile -Force -ErrorAction SilentlyContinue
    }
}

# Post-execution sync: update profile with any refreshed tokens
Sync-ActiveAuthToProfile

# Post-execution check: 429 quota exhaustion or 401 token revocation
$exhaustionDetected = $false
$authRevokedDetected = $false
if ($exitCode -ne 0 -and (Test-Path $dbLogs)) {
    try {
        $checkScript = @"
import sqlite3, os, sys
db = os.path.expanduser(r"~/.codex/logs_2.sqlite")
start_ts = int(sys.argv[1])
exhausted = False
revoked = False
if os.path.exists(db):
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    # Check authentic 429
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
    if cur.fetchone():
        exhausted = True

    # Check authentic 401 token revocation
    cur.execute('''
        SELECT feedback_log_body FROM logs 
        WHERE ts >= ? 
          AND (feedback_log_body LIKE '%token_revoked%'
               OR feedback_log_body LIKE '%workspace routing discovery unauthorized%'
               OR feedback_log_body LIKE '%Encountered invalidated oauth token%')
        LIMIT 1;
    ''', (start_ts - 5,))
    if cur.fetchone():
        revoked = True
    conn.close()

if exhausted:
    print("EXHAUSTED")
if revoked:
    print("REVOKED")
"@
        $res = python -c "$checkScript" $sessionStartTimeSec
        if ($res -match "EXHAUSTED") {
            $exhaustionDetected = $true
        }
        if ($res -match "REVOKED") {
            $authRevokedDetected = $true
        }
    } catch {}
}

# Auto-recovery from revoked or invalidated credentials
if ($authRevokedDetected -and $activeEmail) {
    Write-Host "`n[MinusAccountLoop] [!] Credentials for $activeEmail were revoked or invalidated by OpenAI." -ForegroundColor Yellow
    $kTarget = $activeEmail.ToLower()
    if (-not $poolState.ContainsKey($kTarget)) {
        $poolState[$kTarget] = @{ lastExhausted = 0; switchCount = 0; cooldownUntil = 0; authRevoked = $true }
    } else {
        $poolState[$kTarget].authRevoked = $true
    }
    Save-PoolState

    $nextCandidate = Get-BestAvailableAccount $activeEmail
    if ($nextCandidate -and ($nextCandidate.ToLower() -ne $activeEmail.ToLower())) {
        Write-Host "[MinusAccountLoop] [Auto-Switch] Automatically switching to valid account: $nextCandidate" -ForegroundColor Green
        Switch-ActiveAccount $nextCandidate | Out-Null
        $mappings[$currentDir] = $nextCandidate
        Save-Mappings

        Write-Host "[MinusAccountLoop] Starting fresh session on $nextCandidate ...`n" -ForegroundColor Green
        try { & $codexExe app-server daemon stop 2>&1 | Out-Null } catch {}
        & $codexExe @finalArgs
        exit $LASTEXITCODE
    } else {
        Write-Host "[MinusAccountLoop] [!] No alternative valid accounts found in pool." -ForegroundColor Red
        Write-Host "[MinusAccountLoop] Please run 'codex --login-account' to re-authenticate." -ForegroundColor Yellow
        exit $exitCode
    }
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
                $poolState[$kTarget] = @{ lastExhausted = 0; switchCount = 0; cooldownUntil = 0; authRevoked = $false }
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
            & $codexExe @finalArgs
            exit $LASTEXITCODE
        }
    }
}

exit $exitCode
