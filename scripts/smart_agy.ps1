# @file scripts/smart_agy.ps1
# Smart AGY Launcher: Quota-aware workspace account binding, auto-rotation on cooldown,
# interactive rotation (--rotate / -r), pool diagnostics (--status), and zombie cleanup.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AgyArgs
)

$ErrorActionPreference = 'SilentlyContinue'

$profilesDir = "$env:USERPROFILE\.gemini\profiles"
$mappingFile = "$env:USERPROFILE\.gemini\workspace_accounts.json"
$poolFile = "$env:USERPROFILE\.gemini\account_pool_state.json"
$logPath = "$env:USERPROFILE\.gemini\antigravity-cli\cli.log"
$wincredScript = Join-Path $PSScriptRoot "wincred.ps1"
$agyExe = "$env:LOCALAPPDATA\agy\bin\agy.exe"

$cooldownMs = 6 * 3600 * 1000  # Default 6 hours fallback
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# 1. Clean orphaned zombie agy processes across the machine
Get-CimInstance Win32_Process -Filter "Name = 'agy.exe'" | ForEach-Object {
    $procId = $_.ProcessId
    $parentId = $_.ParentProcessId
    $parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
    if (-not $parent) {
        Stop-Process -Id $procId -ErrorAction SilentlyContinue
    }
}

# 2. Get list of all verified profile emails from ~/.gemini/profiles
$availableProfiles = @()
if (Test-Path $profilesDir) {
    $availableProfiles = (Get-ChildItem $profilesDir -Filter "*.json" | Where-Object { $_.BaseName -notlike '_temp*' -and $_.BaseName -match '@' }).BaseName
}

if ($availableProfiles.Count -eq 0) {
    & $agyExe @AgyArgs
    exit $LASTEXITCODE
}

# 3. Load account pool state (lastExhausted, cooldownUntil, and switchCount)
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

# Save pool state helper
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

# Helper: check if an account is in cooldown
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
            if ($elapsed -gt 0 -and $elapsed -lt $cooldownMs) {
                return $true
            }
        }
    }
    return $false
}

# Helper: get cooldown remaining minutes
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
            if ($elapsed -gt 0 -and $elapsed -lt $cooldownMs) {
                return [Math]::Ceiling(($cooldownMs - $elapsed) / 60000)
            }
        }
    }
    return 0
}

# Helper: pick best available account
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
    Write-Host "[MinusAccountLoop] [!] Notice: All $($availableProfiles.Count) accounts are currently in quota cooldown." -ForegroundColor Yellow
    Write-Host "[MinusAccountLoop] Earliest quota recovery: ~$minRemaining minutes ($earliestAccount). Launching session..." -ForegroundColor Yellow

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
    return $availableProfiles[0]
}

# 4. Load or initialize workspace -> account mapping
$mappings = @{}
if (Test-Path $mappingFile) {
    try {
        $json = Get-Content $mappingFile -Raw | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) {
            $mappings[$prop.Name.TrimEnd('\/').ToLower()] = $prop.Value
        }
    } catch {}
}

# Save mappings helper
function Save-Mappings {
    try {
        $mappings | ConvertTo-Json -Depth 2 | Set-Content $mappingFile -Encoding utf8
    } catch {}
}

$currentDir = $PWD.Path.TrimEnd('\/').ToLower()

# 5. Parse command-line flags
$forceRotate = $false
$showStatus = $false
$explicitUseEmail = $null
$hasContinue = $false
$hasConv = $false
$filteredArgs = @()

$i = 0
while ($i -lt $AgyArgs.Count) {
    $arg = $AgyArgs[$i]
    if ($arg -eq '-r' -or $arg -eq '--rotate' -or $arg -eq 'rotate') {
        $forceRotate = $true
    } elseif ($arg -eq '--status' -or $arg -eq 'status' -or $arg -eq '--pool-status') {
        $showStatus = $true
    } elseif ($arg -eq '--use' -and ($i + 1) -lt $AgyArgs.Count) {
        $i++
        $explicitUseEmail = $AgyArgs[$i]
    } elseif ($arg -eq '-c' -or $arg -eq '--continue') {
        $hasContinue = $true
    } elseif ($arg -like '--conversation*') {
        $hasConv = $true
        $filteredArgs += $arg
    } else {
        $filteredArgs += $arg
    }
    $i++
}

# Handle --status
if ($showStatus) {
    Write-Host "`n=== Google Antigravity Account Pool Status ===" -ForegroundColor Cyan
    Write-Host "Total Profiles: $($availableProfiles.Count)" -ForegroundColor Gray
    Write-Host ""
    foreach ($p in $availableProfiles) {
        $inCd = Is-AccountInCooldown $p
        $rem = Get-CooldownRemainingMin $p
        $sw = if ($poolState.ContainsKey($p.ToLower())) { $poolState[$p.ToLower()].switchCount } else { 0 }
        
        # Find workspaces mapped to this account
        $wsList = @()
        foreach ($k in $mappings.Keys) {
            if ($mappings[$k].ToLower() -eq $p.ToLower()) {
                $wsList += Split-Path $k -Leaf
            }
        }
        $wsStr = if ($wsList.Count -gt 0) { "-> [" + ($wsList -join ", ") + "]" } else { "" }

        if ($inCd) {
            Write-Host "  [COOLDOWN ($rem m remaining)]  $p  (Rotated $sw times) $wsStr" -ForegroundColor Yellow
        } else {
            Write-Host "  [READY]                        $p  (Rotated $sw times) $wsStr" -ForegroundColor Green
        }
    }
    Write-Host "`nCurrent workspace: $(Split-Path $currentDir -Leaf)" -ForegroundColor Gray
    if ($mappings.ContainsKey($currentDir)) {
        Write-Host "Assigned account:  $($mappings[$currentDir])" -ForegroundColor Cyan
    }
    Write-Host ""
    exit 0
}

# 6. Resolve target account
$targetEmail = $null

if ($explicitUseEmail) {
    # Check if explicit email is valid profile
    $matched = $availableProfiles | Where-Object { $_.ToLower() -eq $explicitUseEmail.ToLower() } | Select-Object -First 1
    if ($matched) {
        $targetEmail = $matched
        $mappings[$currentDir] = $targetEmail
        Save-Mappings
        Write-Host "[MinusAccountLoop] Explicitly assigned workspace to: $targetEmail" -ForegroundColor Cyan
    } else {
        Write-Host "[MinusAccountLoop] Warning: '$explicitUseEmail' not found in profiles. Falling back." -ForegroundColor Red
    }
}

if (-not $targetEmail) {
    if ($mappings.ContainsKey($currentDir) -and ($availableProfiles -contains $mappings[$currentDir])) {
        $targetEmail = $mappings[$currentDir]
    } else {
        $assignedEmails = $mappings.Values
        $unassigned = $availableProfiles | Where-Object { $assignedEmails -notcontains $_ }
        if ($unassigned -and $unassigned.Count -gt 0) {
            $targetEmail = $unassigned[0]
        } else {
            $targetEmail = $availableProfiles[($mappings.Count % $availableProfiles.Count)]
        }
        $mappings[$currentDir] = $targetEmail
        Save-Mappings
    }
}

# 7. Check for rotation requirement (Explicit -r OR Cooldown on assigned account)
if ($forceRotate -or (Is-AccountInCooldown $targetEmail)) {
    $oldEmail = $targetEmail
    $reason = if ($forceRotate) { "Manual rotation requested" } else { "Account is on quota cooldown" }

    # Mark old account as exhausted
    $kOld = $oldEmail.ToLower()
    if (-not $poolState.ContainsKey($kOld)) {
        $poolState[$kOld] = @{ lastExhausted = 0; switchCount = 0 }
    }
    $poolState[$kOld].lastExhausted = $nowMs
    $poolState[$kOld].switchCount = [int]$poolState[$kOld].switchCount + 1
    Save-PoolState

    # Pick next healthy account
    $newTarget = Get-BestAvailableAccount $oldEmail
    $mappings[$currentDir] = $newTarget
    Save-Mappings
    $targetEmail = $newTarget

    Write-Host "[MinusAccountLoop] $reason. Rotated workspace: $oldEmail -> $targetEmail" -ForegroundColor Yellow
}

# 8. Check active account in Windows Credential Manager
$currentActive = $null
try {
    $rawCred = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wincredScript -Action read -Target "gemini:antigravity"
    if ($rawCred) {
        $parsed = $rawCred | ConvertFrom-Json
        if ($parsed.id_token) {
            $jwtParts = $parsed.id_token.Split('.')
            if ($jwtParts.Length -ge 2) {
                $padded = $jwtParts[1].PadRight([Math]::Ceiling($jwtParts[1].Length / 4) * 4, '=')
                $bytes = [Convert]::FromBase64String($padded.Replace('-', '+').Replace('_', '/'))
                $payload = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
                $currentActive = $payload.email
            }
        }
    }
} catch {}

# 9. If keyring doesn't match the workspace's assigned account, switch it now (<50ms)
if ($currentActive -ne $targetEmail) {
    $profilePath = Join-Path $profilesDir "$targetEmail.json"
    if (Test-Path $profilePath) {
        try {
            $pData = Get-Content $profilePath -Raw | ConvertFrom-Json
            $blobToWrite = $pData.credentialBlob
            if ($blobToWrite -isnot [string]) {
                $blobToWrite = $blobToWrite | ConvertTo-Json -Compress -Depth 10
            }
            $tempFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tempFile, $blobToWrite, [System.Text.Encoding]::UTF8)
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wincredScript -Action write -Target "gemini:antigravity" -UserName "antigravity" -SecretFile $tempFile | Out-Null
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            Write-Host "[MinusAccountLoop] Pinned workspace to: $targetEmail" -ForegroundColor Cyan
        } catch {}
    }
}

# 10. Handle continue (-c or --continue) directory-scoped resolution
if ($hasContinue -and -not $hasConv) {
    $histPath = "$env:USERPROFILE\.gemini\antigravity-cli\history.jsonl"
    if (Test-Path $histPath) {
        $targetPath = $PWD.Path.TrimEnd('\/').ToLower()
        $entry = Get-Content $histPath | ForEach-Object { try { ConvertFrom-Json $_ } catch {} } |
            Where-Object { $_.workspace -and $_.conversationId -and ($_.workspace.TrimEnd('\/').ToLower() -eq $targetPath) } |
            Select-Object -Last 1
        if ($entry -and $entry.conversationId) {
            $convId = $entry.conversationId
            Write-Host "[MinusAccountLoop] Resuming project session: $convId" -ForegroundColor Cyan
            $filteredArgs += "--conversation=$convId"
            $hasConv = $true
        }
    }
    if (-not $hasConv) {
        $filteredArgs += '-c'
    }
}

# 11. Record initial cli.log size to catch runtime quota exhaustion upon process termination
$initialLogSize = 0
if (Test-Path $logPath) {
    try {
        $initialLogSize = (Get-Item $logPath).Length
    } catch {}
}

$exhaustionDetected = $false
$rotatedToAccount = $null
$exitCode = 0

try {
    # 12. Execute genuine agy with all arguments
    & $agyExe @filteredArgs
    $exitCode = $LASTEXITCODE
} finally {
    # 13. Post-execution: Inspect newly appended log lines for genuine RESOURCE_EXHAUSTED
    if (Test-Path $logPath) {
        try {
            $finalItem = Get-Item $logPath
            if ($finalItem.Length -gt $initialLogSize) {
                $readBytes = [Math]::Min($finalItem.Length - $initialLogSize, 65536)
                $stream = [System.IO.File]::OpenRead($logPath)
                $stream.Seek($finalItem.Length - $readBytes, [System.IO.SeekOrigin]::Begin) | Out-Null
                $buffer = New-Object byte[] $readBytes
                $stream.Read($buffer, 0, $readBytes) | Out-Null
                $stream.Close()
                $newText = [System.Text.Encoding]::UTF8.GetString($buffer)

                # Strict quota check matching tokenPool.js
                if ($newText -match '\b(RESOURCE_EXHAUSTED|quota exceeded|individual quota reached|rate limit exceeded)\b|\b(code|status)\s*[:=]?\s*429\b') {
                    $exhaustionDetected = $true
                    $nowExMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $kTarget = $targetEmail.ToLower()
                    if (-not $poolState.ContainsKey($kTarget)) {
                        $poolState[$kTarget] = @{ lastExhausted = 0; switchCount = 0; cooldownUntil = 0 }
                    }

                    # Parse reset duration if provided by Google (e.g. "Resets in 65h41m56s" or "Resets in 2h")
                    $parsedCooldownMs = $cooldownMs
                    if ($newText -match 'Resets in\s+(\d+)h(?:(\d+)m)?') {
                        $rHours = [int]$Matches[1]
                        $rMins = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
                        $parsedCooldownMs = ($rHours * 3600 + $rMins * 60) * 1000
                    }

                    $poolState[$kTarget].lastExhausted = $nowExMs
                    $poolState[$kTarget].cooldownUntil = $nowExMs + $parsedCooldownMs
                    $poolState[$kTarget].switchCount = [int]$poolState[$kTarget].switchCount + 1
                    Save-PoolState

                    $nextAcc = Get-BestAvailableAccount $targetEmail
                    $mappings[$currentDir] = $nextAcc
                    Save-Mappings
                    $rotatedToAccount = $nextAcc

                    # Pre-emptively switch Windows Keyring so next invocation is INSTANT (<50ms)
                    $nextProfilePath = Join-Path $profilesDir "$nextAcc.json"
                    if (Test-Path $nextProfilePath) {
                        try {
                            $npData = Get-Content $nextProfilePath -Raw | ConvertFrom-Json
                            $blob = $npData.credentialBlob
                            if ($blob -isnot [string]) {
                                $blob = $blob | ConvertTo-Json -Compress -Depth 10
                            }
                            $tmpF = [System.IO.Path]::GetTempFileName()
                            [System.IO.File]::WriteAllText($tmpF, $blob, [System.Text.Encoding]::UTF8)
                            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wincredScript -Action write -Target "gemini:antigravity" -UserName "antigravity" -SecretFile $tmpF | Out-Null
                            Remove-Item $tmpF -Force -ErrorAction SilentlyContinue
                        } catch {}
                    }

                    $resetHoursDisplay = [Math]::Round($parsedCooldownMs / 3600000, 1)
                    Write-Host "`n[MinusAccountLoop] [!] Quota exhausted on $targetEmail during this session." -ForegroundColor Yellow
                    Write-Host "[MinusAccountLoop] [Cooldown] Quota cooldown registered for ~$resetHoursDisplay hours." -ForegroundColor Yellow
                    Write-Host "[MinusAccountLoop] [Rotated] Workspace auto-rotated to fresh account: $nextAcc" -ForegroundColor Green
                    Write-Host "[MinusAccountLoop] [Keyring] Windows Keyring updated to: $nextAcc" -ForegroundColor Cyan
                    Write-Host "[MinusAccountLoop] [Ready] Run 'agy -c' to resume this exact conversation with 100% quota!`n" -ForegroundColor Green
                }
            }
        } catch {}
    }
}

# 14. 1-Key Auto-Resume prompt if process exited cleanly after exhaustion
if ($exhaustionDetected -and $rotatedToAccount -and $exitCode -eq 0) {
    $resumeConvId = $null
    $histPath = "$env:USERPROFILE\.gemini\antigravity-cli\history.jsonl"
    if (Test-Path $histPath) {
        $targetPath = $PWD.Path.TrimEnd('\/').ToLower()
        $entry = Get-Content $histPath | ForEach-Object { try { ConvertFrom-Json $_ } catch {} } |
            Where-Object { $_.workspace -and $_.conversationId -and ($_.workspace.TrimEnd('\/').ToLower() -eq $targetPath) } |
            Select-Object -Last 1
        if ($entry -and $entry.conversationId) {
            $resumeConvId = $entry.conversationId
        }
    }

    if ($resumeConvId) {
        Write-Host "[MinusAccountLoop] [Auto-Resume] Ready for conversation $resumeConvId on $rotatedToAccount." -ForegroundColor Green
        Write-Host "Press [ENTER] to auto-resume immediately (or wait 3s, or [Q] to stay in terminal): " -NoNewline -ForegroundColor Cyan

        $autoResume = $true
        $timeout = 3 # seconds
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt $timeout) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) {
                    $autoResume = $true
                    break
                } elseif ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) {
                    $autoResume = $false
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        Write-Host ""

        if ($autoResume) {
            Write-Host "[MinusAccountLoop] Resuming session now with $rotatedToAccount ...`n" -ForegroundColor Green
            $resumeArgs = @("--conversation=$resumeConvId")
            foreach ($a in $filteredArgs) {
                if ($a -notlike '--conversation*' -and $a -ne '-c' -and $a -ne '--continue') {
                    $resumeArgs += $a
                }
            }
            & $agyExe @resumeArgs
            exit $LASTEXITCODE
        }
    }
}

exit $exitCode
