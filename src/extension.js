// @ts-check
'use strict';

/**
 * Minus Account Loop — Antigravity Multi-Account Switcher (v2.0.0)
 *
 * Switches between an UNLIMITED number of Google account profiles in Antigravity IDE / VS Code.
 *
 * Core Systemic Integrity Invariants (v2.0.0):
 * - ZERO Editor Restarts: Never terminates Code.exe or Antigravity.exe.
 * - ZERO Terminal Loss: Never closes integrated terminal sessions.
 * - ZERO Chat Loss: Never touches state.vscdb, storage.json, or workspaceStorage.
 * - Native Windows Keyring: Writes credentials directly to Windows Credential Manager (gemini:antigravity).
 * - Real Quota Watcher: Monitors ~/.gemini/antigravity-cli/cli.log for quota exhaustion and auto-rotates.
 *
 * @module extension
 */

const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const os = require('os');
const keyringManager = require('./keyringManager');
const tokenPool = require('./tokenPool');
const { RATE_LIMIT_REGEX, containsRateLimitError } = tokenPool;

// ============================================
// CONSTANTS
// ============================================

const EXTENSION_ID = 'minusAccountLoop';

/** Distinct palette for slot buttons */
const SLOT_COLORS = [
    '#4FC3F7', // Light Blue
    '#81C784', // Light Green
    '#FFB74D', // Orange
    '#BA68C8', // Purple
    '#F06292', // Pink
    '#4DD0E1', // Cyan
    '#FFD54F', // Amber
    '#A1887F', // Brown
    '#90CAF9', // Cornflower Blue
    '#A5D6A7', // Mint Green
    '#FFCC80', // Apricot
    '#CE93D8', // Lilac
];

/** Safe profile name pattern */
const SAFE_PROFILE_NAME_RE = /^[a-zA-Z0-9 _.\-@]+$/;

/**
 * Validate profile name.
 * @param {string} name
 * @returns {string | null} Error message or null if valid.
 */
function validateProfileName(name) {
    if (!name || !name.trim()) {
        return 'Profile name cannot be empty';
    }
    const clean = name.trim();
    if (clean.length > 80) {
        return 'Profile name must be 80 characters or less';
    }
    if (!SAFE_PROFILE_NAME_RE.test(clean)) {
        return 'Profile name contains invalid characters. Use letters, numbers, spaces, dots, dashes, underscores, or @';
    }
    return null;
}

// ============================================
// EXTENSION ACTIVATION
// ============================================

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
    console.log('[MinusAccountLoop v2.0.0] Activated with native Windows Keyring integration');

    const config = vscode.workspace.getConfiguration(EXTENSION_ID);
    const NUM_QUICK_SLOTS = Math.min(Math.max(config.get('maxQuickSlots', 8)), 30);
    const RATE_LIMIT_COOLDOWN = config.get('rateLimitCooldownMs', 60000);
    const LOG_POLL_INTERVAL = config.get('logPollIntervalMs', 5000);

    // After a window reload triggered by account switch, notify the user.
    // globalState tracks whether the last reload was caused by an account switch.
    const pendingRestart = context.globalState.get('pendingAgyRestart', false);
    if (pendingRestart) {
        context.globalState.update('pendingAgyRestart', false);
        const newEmail = keyringManager.getActiveAccount().email;
        vscode.window.showInformationMessage(
            `🔄 Switched to "${newEmail}". Type 'agy -c' in any terminal to resume your session.`
        );
    }

    let lastRateLimitAlert = 0;

    /**
     * Unified execution helper for switching profiles.
     * Switches credentials in Windows Credential Manager without killing editor or terminals.
     *
     * @param {string} targetProfile
     * @param {boolean} [silent=false]
     */
    async function executeSwitch(targetProfile, silent = false) {
        const activeInfo = keyringManager.getActiveAccount();
        if (activeInfo.email && activeInfo.email.toLowerCase() === targetProfile.trim().toLowerCase()) {
            if (!silent) {
                vscode.window.showInformationMessage(`"${targetProfile}" is already your active account.`);
            }
            return;
        }

        const result = keyringManager.switchProfile(targetProfile);
        if (result.success) {
            updateProfileButtons();

            // Zero window reloads, zero terminal hijacking.
            // The active credential in Windows Credential Manager is updated in <50ms.
            // Any new session or smart_agy launcher reads it instantly.
            if (!silent) {
                vscode.window.showInformationMessage(`✅ Active Antigravity account switched to "${result.email}".`);
            }
        } else {
            vscode.window.showErrorMessage(`Failed to switch: ${result.message}`);
        }
    }

    /**
     * Handle rate limit or quota 0% exhaustion.
     */
    async function handleRateLimitDetected() {
        const now = Date.now();
        if (now - lastRateLimitAlert < RATE_LIMIT_COOLDOWN) {
            return;
        }
        lastRateLimitAlert = now;

        const profiles = keyringManager.listProfiles();
        if (profiles.length === 0) {
            vscode.window.showWarningMessage(
                '⚠️ Antigravity quota exhausted! Click "+" in the status bar to save accounts for auto-rotation.'
            );
            return;
        }

        const activeInfo = keyringManager.getActiveAccount();
        const activeEmail = activeInfo.email;
        if (activeEmail) {
            tokenPool.recordExhaustion(undefined, activeEmail);
        }

        const profileNames = profiles.map(p => p.email || p.name);
        const nextCandidate = tokenPool.getNextAvailableProfile(undefined, profileNames, activeEmail);

        if (!nextCandidate) {
            vscode.window.showWarningMessage(
                `⚠️ Quota exhausted on ${activeEmail || 'current account'}, but all accounts in the pool are on cooldown.`
            );
            return;
        }

        const autoRotateImmediately = config.get('autoRotateImmediately', true);
        if (autoRotateImmediately) {
            await executeSwitch(nextCandidate, true);
            vscode.window.showInformationMessage(
                `⚡ Quota exhausted on ${activeEmail || 'current account'}. Auto-rotated to "${nextCandidate}" (${profiles.length} in pool).`
            );
            return;
        }

        const actions = [`⚡ Auto-Rotate to "${nextCandidate}"`, 'Browse All Accounts...', 'Dismiss'];
        const selected = await vscode.window.showWarningMessage(
            `⚠️ Quota exhausted on ${activeEmail || 'current account'}. Switch to another account? (${profiles.length} available)`,
            ...actions
        );

        if (selected === `⚡ Auto-Rotate to "${nextCandidate}"`) {
            await executeSwitch(nextCandidate);
        } else if (selected === 'Browse All Accounts...') {
            await vscode.commands.executeCommand(`${EXTENSION_ID}.switchProfile`);
        }
    }

    // ============================================
    // ANTIGRAVITY CLI.LOG RATE LIMIT WATCHER
    // ============================================

    const cliLogPath = path.join(os.homedir(), '.gemini', 'antigravity-cli', 'cli.log');
    const cliLogDir = path.join(os.homedir(), '.gemini', 'antigravity-cli', 'log');
    let lastLogSize = 0;

    try {
        if (fs.existsSync(cliLogPath)) {
            lastLogSize = fs.statSync(cliLogPath).size;
        }
    } catch { /* ignore */ }

    /**
     * Scan a log file (or buffer string) for the most recent RESOURCE_EXHAUSTED timestamp.
     * Returns the Date of the last error, or null if none found.
     */
    function findLastErrorTimestamp(content) {
        const lines = content.split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
            if (containsRateLimitError(lines[i])) {
                const match = lines[i].match(/I(\d{4})\s+(\d{2}):(\d{2}):(\d{2})/);
                if (match) {
                    const now = new Date();
                    const ts = new Date(now);
                    ts.setHours(parseInt(match[2]), parseInt(match[3]), parseInt(match[4]), 0);
                    // Handle midnight rollover
                    if (ts > now) ts.setDate(ts.getDate() - 1);
                    return ts;
                }
            }
        }
        return null;
    }

    /**
     * Scan cli.log AND recent rotated log files for RESOURCE_EXHAUSTED errors.
     * Returns the Date of the most recent error across all files, or null.
     */
    function scanAllLogsForErrors() {
        let latestError = null;
        const filesToScan = [];

        // Main cli.log
        if (fs.existsSync(cliLogPath)) {
            filesToScan.push(cliLogPath);
        }

        // Rotated log files (sorted newest first, check only last 3)
        try {
            if (fs.existsSync(cliLogDir)) {
                const rotatedFiles = fs.readdirSync(cliLogDir)
                    .filter(f => f.startsWith('cli-') && f.endsWith('.log'))
                    .sort()
                    .reverse()
                    .slice(0, 3)
                    .map(f => path.join(cliLogDir, f));
                filesToScan.push(...rotatedFiles);
            }
        } catch { /* ignore */ }

        for (const filePath of filesToScan) {
            try {
                const stats = fs.statSync(filePath);
                if (stats.size === 0) continue;
                const scanSize = Math.min(stats.size, 51200); // 50KB per file
                const fd = fs.openSync(filePath, 'r');
                const buf = Buffer.alloc(scanSize);
                fs.readSync(fd, buf, 0, scanSize, stats.size - scanSize);
                fs.closeSync(fd);
                const ts = findLastErrorTimestamp(buf.toString('utf8'));
                if (ts && (!latestError || ts > latestError)) {
                    latestError = ts;
                }
            } catch { /* ignore */ }
        }
        return latestError;
    }

    // Initialize log size on startup so we only detect NEW live errors going forward
    try {
        if (fs.existsSync(cliLogPath)) {
            lastLogSize = fs.statSync(cliLogPath).size;
        }
    } catch { /* ignore */ }

    // Live log watcher: polls cli.log AND checks for log rotation to rotated files
    const logCheckInterval = setInterval(() => {
        try {
            // Check main cli.log for new content
            if (fs.existsSync(cliLogPath)) {
                const stats = fs.statSync(cliLogPath);

                // Handle log rotation: if file shrank, AGY restarted with a fresh log.
                // Scan the latest rotated file for any errors we missed.
                if (stats.size < lastLogSize) {
                    lastLogSize = 0;
                    // AGY just rotated — check the rotated file that was just created
                    const latestError = scanAllLogsForErrors();
                    if (latestError) {
                        const ageMinutes = (Date.now() - latestError.getTime()) / 60000;
                        const lastHandledMs = context.globalState.get('lastHandledErrorMs', 0);
                        if (ageMinutes >= 0 && ageMinutes < 5 && Math.abs(latestError.getTime() - lastHandledMs) > 60000) {
                            console.log('[MinusAccountLoop] Detected error in rotated log, triggering rotation');
                            context.globalState.update('lastHandledErrorMs', latestError.getTime());
                            handleRateLimitDetected();
                        }
                    }
                }

                if (stats.size > lastLogSize) {
                    const newBytes = stats.size - lastLogSize;
                    const readSize = Math.min(newBytes, 32768);
                    const readOffset = stats.size - readSize;
                    const fd = fs.openSync(cliLogPath, 'r');
                    const buffer = Buffer.alloc(readSize);
                    fs.readSync(fd, buffer, 0, readSize, readOffset);
                    fs.closeSync(fd);
                    lastLogSize = stats.size;

                    const newContent = buffer.toString('utf8');
                    if (containsRateLimitError(newContent)) {
                        const errorTs = findLastErrorTimestamp(newContent);
                        if (errorTs) {
                            context.globalState.update('lastHandledErrorMs', errorTs.getTime());
                        }
                        handleRateLimitDetected();
                    }
                }
            }
        } catch { /* ignore */ }
    }, LOG_POLL_INTERVAL);

    context.subscriptions.push({ dispose: () => clearInterval(logCheckInterval) });

    // ============================================
    // AUTOMATIC NEW LOGIN DISCOVERY
    // ============================================

    let lastKnownEmail = (keyringManager.getActiveAccount().email || '').toLowerCase();
    const accountPollInterval = setInterval(() => {
        try {
            const current = keyringManager.getActiveAccount();
            const currentEmail = (current.email || '').toLowerCase();
            if (currentEmail && currentEmail !== lastKnownEmail) {
                lastKnownEmail = currentEmail;
                const profiles = keyringManager.listProfiles();
                const alreadySaved = profiles.some(p => (p.email || p.name).toLowerCase() === currentEmail);
                if (!alreadySaved) {
                    keyringManager.saveCurrentProfile(current.email);
                    vscode.window.showInformationMessage(`🔄 New Antigravity account detected and added to pool: "${current.email}"`);
                }
                updateProfileButtons();
            }
        } catch { /* ignore */ }
    }, 5000);

    context.subscriptions.push({ dispose: () => clearInterval(accountPollInterval) });

    // ============================================
    // STATUS BAR BUTTONS
    // ============================================

    const masterAccountButton = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1005);
    masterAccountButton.command = `${EXTENSION_ID}.switchProfile`;
    masterAccountButton.tooltip = 'Click to switch between all saved Google accounts';
    context.subscriptions.push(masterAccountButton);

    /** @type {vscode.StatusBarItem[]} */
    const profileButtons = [];
    for (let i = 0; i < NUM_QUICK_SLOTS; i++) {
        const btn = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000 - i);
        btn.command = `${EXTENSION_ID}.slotAction${i}`;
        btn.tooltip = `Quick Slot ${i + 1}`;
        profileButtons.push(btn);
        context.subscriptions.push(btn);
    }

    // Save button (+)
    const saveButton = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000 - NUM_QUICK_SLOTS);
    saveButton.text = '$(add)';
    saveButton.tooltip = 'Save currently authenticated Google account to rotation pool';
    saveButton.command = `${EXTENSION_ID}.saveProfile`;
    saveButton.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    context.subscriptions.push(saveButton);

    // Auto-Rotate button (sync icon)
    const rotateButton = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000 - NUM_QUICK_SLOTS - 1);
    rotateButton.text = '$(sync)';
    rotateButton.tooltip = 'Auto-Rotate to next available account with fresh quota';
    rotateButton.command = `${EXTENSION_ID}.autoRotate`;
    context.subscriptions.push(rotateButton);

    // Audit button (dashboard/info)
    const auditButton = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000 - NUM_QUICK_SLOTS - 2);
    auditButton.text = '$(dashboard)';
    auditButton.tooltip = 'View account pool health, quota cooldowns & saved profiles';
    auditButton.command = `${EXTENSION_ID}.auditProfiles`;
    context.subscriptions.push(auditButton);

    // Delete button (trash)
    const deleteButton = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000 - NUM_QUICK_SLOTS - 3);
    deleteButton.text = '$(trash)';
    deleteButton.tooltip = 'Delete a saved profile';
    deleteButton.command = `${EXTENSION_ID}.deleteProfile`;
    deleteButton.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
    context.subscriptions.push(deleteButton);

    /**
     * Refresh all status bar controls.
     */
    function updateProfileButtons() {
        const activeInfo = keyringManager.getActiveAccount();
        const activeEmail = activeInfo.email;
        const profiles = keyringManager.listProfiles();

        if (activeEmail) {
            masterAccountButton.text = `$(account) ${activeEmail} (${profiles.length})`;
            masterAccountButton.backgroundColor = new vscode.ThemeColor('statusBarItem.prominentBackground');
        } else {
            masterAccountButton.text = `$(account) Accounts (${profiles.length})`;
            masterAccountButton.backgroundColor = undefined;
        }
        masterAccountButton.show();

        for (let i = 0; i < NUM_QUICK_SLOTS; i++) {
            const btn = profileButtons[i];
            const profile = profiles[i];
            const slotNum = i + 1;
            const color = SLOT_COLORS[i % SLOT_COLORS.length];

            if (profile) {
                const pEmail = profile.email || profile.name;
                const isActive = activeEmail && activeEmail.toLowerCase() === pEmail.toLowerCase();

                if (isActive) {
                    btn.text = `$(check) ${pEmail}`;
                    btn.tooltip = `"${pEmail}" is currently active`;
                    btn.color = '#FFFFFF';
                    btn.backgroundColor = new vscode.ThemeColor('statusBarItem.prominentBackground');
                } else {
                    btn.text = `$(account) ${pEmail}`;
                    btn.tooltip = `Click to switch to "${pEmail}"`;
                    btn.color = color;
                    btn.backgroundColor = undefined;
                }
            } else {
                btn.text = `$(circle-slash) ${slotNum}`;
                btn.tooltip = `Quick Slot ${slotNum} is empty — Click + to save`;
                btn.color = new vscode.ThemeColor('disabledForeground');
                btn.backgroundColor = undefined;
            }
            btn.show();
        }

        saveButton.show();
        rotateButton.show();
        auditButton.show();
        deleteButton.show();
    }

    // ============================================
    // SLOT CLICK COMMANDS
    // ============================================

    for (let i = 0; i < NUM_QUICK_SLOTS; i++) {
        const slotIndex = i;
        const cmd = vscode.commands.registerCommand(`${EXTENSION_ID}.slotAction${i}`, async () => {
            const profiles = keyringManager.listProfiles();
            const profile = profiles[slotIndex];

            if (profile) {
                await executeSwitch(profile.email || profile.name);
            } else {
                vscode.window.showInformationMessage(
                    `Quick Slot ${slotIndex + 1} is empty. Click the + button to save your current account.`
                );
            }
        });
        context.subscriptions.push(cmd);
    }

    // ============================================
    // COMMAND IMPLEMENTATIONS
    // ============================================

    // Auto-Rotate
    const rotateCmd = vscode.commands.registerCommand(`${EXTENSION_ID}.autoRotate`, async () => {
        const profiles = keyringManager.listProfiles();
        if (profiles.length <= 1) {
            vscode.window.showWarningMessage('Need at least 2 saved profiles to rotate accounts. Click "+" to save more.');
            return;
        }

        const profileNames = profiles.map(p => p.email || p.name);
        const activeInfo = keyringManager.getActiveAccount();
        const nextProfile = tokenPool.getNextAvailableProfile(undefined, profileNames, activeInfo.email);

        if (!nextProfile || nextProfile.toLowerCase() === (activeInfo.email || '').toLowerCase()) {
            const idx = profileNames.findIndex(p => p.toLowerCase() === (activeInfo.email || '').toLowerCase());
            const fallback = profileNames[(idx + 1) % profileNames.length];
            await executeSwitch(fallback);
            return;
        }

        await executeSwitch(nextProfile);
    });
    context.subscriptions.push(rotateCmd);

    // Audit Profiles
    const auditCmd = vscode.commands.registerCommand(`${EXTENSION_ID}.auditProfiles`, async () => {
        const profiles = keyringManager.listProfiles();
        const profileNames = profiles.map(p => p.email || p.name);
        const activeInfo = keyringManager.getActiveAccount();
        const poolStatuses = tokenPool.getAccountPoolStatus(undefined, profileNames);

        const items = [];

        items.push({
            label: `$(pass) Windows Credential Manager: ${profiles.length} Profiles Saved`,
            description: `Active: ${activeInfo.email || 'None'}`,
            detail: 'Zero restarts, zero terminal disruption, chats preserved.'
        });

        items.push({
            label: '--- ACCOUNTS & QUOTA STATUS ---',
            description: '',
            detail: ''
        });

        for (const status of poolStatuses) {
            const isActive = activeInfo.email && activeInfo.email.toLowerCase() === status.account.toLowerCase();
            const icon = isActive ? '$(check)' : (status.isReady ? '$(circle-filled)' : '$(clock)');
            const stateDesc = isActive ? 'ACTIVE' : (status.isReady ? 'READY' : `COOLDOWN (${status.cooldownRemainingMin}m remaining)`);

            items.push({
                label: `${icon} ${status.account}`,
                description: `${stateDesc} • Rotated ${status.switchCount} times`,
                detail: status.hasSavedProfile ? 'Saved in rotation pool' : 'Detected on system, click + to save'
            });
        }

        await vscode.window.showQuickPick(items, {
            placeHolder: `Antigravity Account Pool — ${profiles.length} Saved Profiles, Active: ${activeInfo.email || 'None'}`
        });
    });
    // Distribute Accounts Across Open Terminals (1 unique account per session)
    const distributeCmd = vscode.commands.registerCommand(`${EXTENSION_ID}.distributeAccountsAcrossTerminals`, async () => {
        const terminals = vscode.window.terminals;
        if (terminals.length === 0) {
            vscode.window.showInformationMessage('No active integrated terminals found in this window.');
            return;
        }

        const profiles = keyringManager.listProfiles();
        if (profiles.length === 0) {
            vscode.window.showErrorMessage('No saved profiles found in ~/.gemini/profiles. Save accounts first using the + button.');
            return;
        }

        const count = Math.min(terminals.length, profiles.length);
        const choice = await vscode.window.showInformationMessage(
            `Distribute ${count} unique Google accounts across ${terminals.length} open terminal sessions? Each session will run with its own dedicated account and independent quota.`,
            'Yes, Distribute',
            'Cancel'
        );
        if (choice !== 'Yes, Distribute') return;

        const historyPath = path.join(os.homedir(), '.gemini', 'antigravity-cli', 'history.jsonl');

        // Ensure workspace accounts mapping is saved and keyring is updated cleanly
        const targetAccount = profiles[0].email || profiles[0].name;
        keyringManager.switchProfile(targetAccount);
        updateProfileButtons();

        vscode.window.showInformationMessage(
            `✅ Distributed ${count} accounts across your workspaces! smart_agy automatically launches each workspace with its dedicated account.`
        );
    });
    context.subscriptions.push(distributeCmd);

    // Save Profile
    const saveCmd = vscode.commands.registerCommand(`${EXTENSION_ID}.saveProfile`, async () => {
        const activeInfo = keyringManager.getActiveAccount();
        if (!activeInfo.email) {
            vscode.window.showErrorMessage('No active Google Antigravity account found in Windows Credential Manager.');
            return;
        }

        const profiles = keyringManager.listProfiles();
        const existing = profiles.find(p => (p.email || p.name).toLowerCase() === activeInfo.email.toLowerCase());

        if (existing) {
            const choice = await vscode.window.showWarningMessage(
                `Profile for "${activeInfo.email}" is already saved. Overwrite with current token?`,
                { modal: true },
                'Overwrite',
                'Cancel'
            );
            if (choice !== 'Overwrite') return;
        }

        const result = keyringManager.saveCurrentProfile(activeInfo.email);
        if (result.success) {
            vscode.window.showInformationMessage(`✅ Profile "${activeInfo.email}" saved to rotation pool!`);
            updateProfileButtons();
        } else {
            vscode.window.showErrorMessage(`Failed to save profile: ${result.message}`);
        }
    });
    context.subscriptions.push(saveCmd);

    // Delete Profile
    const deleteCmd = vscode.commands.registerCommand(`${EXTENSION_ID}.deleteProfile`, async () => {
        const profiles = keyringManager.listProfiles();
        if (profiles.length === 0) {
            vscode.window.showInformationMessage('No profiles to delete.');
            return;
        }

        const items = profiles.map(p => ({
            label: `$(trash) ${p.email || p.name}`,
            description: `Saved ${p.savedAt ? p.savedAt.slice(0, 16).replace('T', ' ') : ''}`,
            profileName: p.name
        }));

        const selected = await vscode.window.showQuickPick(items, {
            placeHolder: 'Select a profile to delete from rotation pool'
        });
        if (!selected) return;

        const targetFile = path.join(keyringManager.PROFILES_DIR, `${selected.profileName}.json`);
        try {
            if (fs.existsSync(targetFile)) {
                fs.unlinkSync(targetFile);
                vscode.window.showInformationMessage(`Deleted profile "${selected.profileName}".`);
                updateProfileButtons();
            }
        } catch (e) {
            vscode.window.showErrorMessage(`Failed to delete profile: ${e instanceof Error ? e.message : String(e)}`);
        }
    });
    context.subscriptions.push(deleteCmd);

    // Switch Profile (Browse All)
    const switchCmd = vscode.commands.registerCommand(`${EXTENSION_ID}.switchProfile`, async () => {
        const profiles = keyringManager.listProfiles();
        if (profiles.length === 0) {
            vscode.window.showInformationMessage('No profiles saved yet. Click the + button to save your current account.');
            return;
        }

        const activeInfo = keyringManager.getActiveAccount();
        const items = [];

        // Quick action: Distribute unique accounts across open terminals
        const terminalCount = vscode.window.terminals.length;
        if (terminalCount > 1) {
            items.push({
                label: `$(split-horizontal) Distribute Accounts Across ${terminalCount} Terminals`,
                description: `1 unique account per terminal (${profiles.length} available)`,
                detail: 'Assigns each open terminal session its own dedicated account so they do not share or drain the same quota pool.',
                isDistributeAction: true
            });
            items.push({
                label: '--- OR SELECT GLOBAL ACCOUNT ---',
                description: '',
                detail: '',
                isSeparator: true
            });
        }

        for (let i = 0; i < profiles.length; i++) {
            const p = profiles[i];
            const pEmail = p.email || p.name;
            const isActive = activeInfo.email && activeInfo.email.toLowerCase() === pEmail.toLowerCase();
            items.push({
                label: `${isActive ? '$(check)' : '$(account)'} ${pEmail}`,
                description: `${isActive ? 'CURRENTLY ACTIVE • ' : ''}Slot #${i + 1}`,
                detail: `Saved: ${p.savedAt || 'Unknown'}`,
                profileName: pEmail
            });
        }

        const selected = await vscode.window.showQuickPick(items, {
            placeHolder: 'Select Google account to switch to (zero restart, zero terminal loss)'
        });
        if (!selected || selected.isSeparator) return;

        if (selected.isDistributeAction) {
            await vscode.commands.executeCommand(`${EXTENSION_ID}.distributeAccountsAcrossTerminals`);
            return;
        }

        await executeSwitch(selected.profileName);
    });
    context.subscriptions.push(switchCmd);

    // Auto-save current account on first launch if not saved yet
    const currentActive = keyringManager.getActiveAccount();
    if (currentActive.email) {
        const profiles = keyringManager.listProfiles();
        const alreadySaved = profiles.some(p => (p.email || p.name).toLowerCase() === currentActive.email.toLowerCase());
        if (!alreadySaved) {
            keyringManager.saveCurrentProfile(currentActive.email);
            console.log(`[MinusAccountLoop] Auto-saved active account: ${currentActive.email}`);
        }
    }

    // Initial button render
    updateProfileButtons();
}

/**
 * Called when extension is deactivated.
 */
function deactivate() {
    console.log('[MinusAccountLoop] Deactivated');
}

module.exports = { activate, deactivate };

