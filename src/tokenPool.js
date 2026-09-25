// @ts-check
'use strict';

/**
 * Minus Account Loop — Token & Account Pool Manager (v2.0.0)
 *
 * Manages the rotation pool across multiple Google AI Pro accounts:
 * - Detects accounts from Windows Credential Manager, ~/.gemini/profiles/, and ~/.gemini/google_accounts.json
 * - Strict case-insensitive and whitespace-trimmed deduplication
 * - Extracts active Google account identity from Windows Credential Manager
 * - Implements intelligent round-robin rotation
 * - Tracks 5-hour quota exhaustion cooldowns so depleted accounts are skipped
 *
 * @module tokenPool
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const keyringManager = require('./keyringManager');

// Standard Gemini / Google AI Pro model quota reset cooldown (5 hours in ms)
const QUOTA_COOLDOWN_MS = 5 * 60 * 60 * 1000;

/** Rate limit error patterns to monitor in Antigravity cli.log */
const RATE_LIMIT_REGEX = /\b(RESOURCE_EXHAUSTED|quota exceeded|individual quota reached|rate_limit|rate limit exceeded)\b|\b(code|status)\s*[:=]?\s*429\b/i;

/**
 * Check if text contains any genuine rate limit error pattern.
 * Uses strict boundaries to prevent false positives on timestamps (e.g. .429505),
 * line numbers (e.g. server.go:3429), or thread IDs.
 * @param {string} text
 * @returns {boolean}
 */
function containsRateLimitError(text) {
    return RATE_LIMIT_REGEX.test(text);
}

/**
 * Path to Google Gemini CLI accounts registry if present.
 */
function getGeminiAccountsPath() {
    return path.join(os.homedir(), '.gemini', 'google_accounts.json');
}

/**
 * Path to our account pool state cache file.
 */
function getPoolStatePath(baseDataPath) {
    const dir = baseDataPath || path.join(os.homedir(), '.gemini');
    return path.join(dir, 'account_pool_state.json');
}

/**
 * Get the currently logged-in active Google account email.
 *
 * Priority order:
 * 1. Windows Credential Manager (gemini:antigravity) — ground truth
 * 2. AGY cli.log — parses most recent applyAuthResult line
 * 3. ~/.gemini/google_accounts.json — legacy Gemini CLI source
 *
 * @returns {string | null}
 */
function getActiveGoogleAccount() {
    // Source 1: Windows Credential Manager (absolute ground truth for Antigravity)
    try {
        const active = keyringManager.getActiveAccount();
        if (active && active.email) {
            return active.email.trim();
        }
    } catch { /* fall through */ }

    // Source 2: AGY cli.log
    try {
        const cliLogPath = path.join(os.homedir(), '.gemini', 'antigravity-cli', 'cli.log');
        if (fs.existsSync(cliLogPath)) {
            const stats = fs.statSync(cliLogPath);
            const readSize = Math.min(stats.size, 102400);
            const buf = Buffer.alloc(readSize);
            const fd = fs.openSync(cliLogPath, 'r');
            fs.readSync(fd, buf, 0, readSize, Math.max(0, stats.size - readSize));
            fs.closeSync(fd);

            const content = buf.toString('utf8');
            const matches = content.match(/applyAuthResult:\s*email=([^\s,]+@[^\s,]+)/g);
            if (matches && matches.length > 0) {
                const lastMatch = matches[matches.length - 1];
                const emailMatch = lastMatch.match(/email=([^\s,]+@[^\s,]+)/);
                if (emailMatch && emailMatch[1]) {
                    return emailMatch[1].trim();
                }
            }
        }
    } catch { /* fall through */ }

    // Source 3: Legacy ~/.gemini/google_accounts.json
    try {
        const geminiPath = getGeminiAccountsPath();
        if (fs.existsSync(geminiPath)) {
            const raw = fs.readFileSync(geminiPath, 'utf8');
            const data = JSON.parse(raw);
            return data.active ? data.active.trim() : null;
        }
    } catch { /* ignore */ }
    return null;
}

/**
 * Load persisted pool state (cooldowns, usage counts).
 * @param {string} [baseDataPath]
 * @returns {Record<string, { lastExhausted: number, switchCount: number }>}
 */
function loadPoolState(baseDataPath) {
    try {
        const filePath = getPoolStatePath(baseDataPath);
        if (fs.existsSync(filePath)) {
            const raw = fs.readFileSync(filePath, 'utf8');
            return JSON.parse(raw);
        }
    } catch { /* ignore corrupted state */ }
    return {};
}

/**
 * Save persisted pool state.
 * @param {string} [baseDataPath]
 * @param {Record<string, { lastExhausted: number, switchCount: number }>} state
 */
function savePoolState(baseDataPath, state) {
    try {
        const filePath = getPoolStatePath(baseDataPath);
        const dir = path.dirname(filePath);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(filePath, JSON.stringify(state, null, 2), 'utf8');
    } catch (e) {
        console.error('[TokenPool] Failed to save state:', e);
    }
}

/**
 * Discover all available Google accounts on the system with strict deduplication.
 * Aggregates from ~/.gemini/profiles/, Windows Keyring, and ~/.gemini/google_accounts.json
 *
 * @param {string[]} [savedProfileNames]
 * @returns {{
 *   active: string | null,
 *   allAccounts: string[],
 *   source: 'keyring' | 'gemini_config' | 'saved_profiles' | 'none'
 * }}
 */
function discoverAccounts(savedProfileNames = []) {
    /** @type {Map<string, string>} */
    const normalizedMap = new Map();
    const active = getActiveGoogleAccount();

    if (active) {
        normalizedMap.set(active.toLowerCase(), active);
    }

    // Load from ~/.gemini/profiles/
    try {
        const savedProfiles = keyringManager.listProfiles();
        for (const p of savedProfiles) {
            const email = p.email || p.name;
            if (email && typeof email === 'string') {
                const clean = email.trim();
                const key = clean.toLowerCase();
                if (!normalizedMap.has(key)) {
                    normalizedMap.set(key, clean);
                }
            }
        }
    } catch { /* ignore */ }

    // Load from gemini_accounts.json
    const geminiPath = getGeminiAccountsPath();
    if (fs.existsSync(geminiPath)) {
        try {
            const raw = fs.readFileSync(geminiPath, 'utf8');
            const data = JSON.parse(raw);
            const old = Array.isArray(data.old) ? data.old : [];
            for (const acc of old) {
                if (typeof acc === 'string' && acc.trim()) {
                    const clean = acc.trim();
                    const key = clean.toLowerCase();
                    if (!normalizedMap.has(key)) {
                        normalizedMap.set(key, clean);
                    }
                }
            }
        } catch { /* fallback */ }
    }

    // Additional names
    for (const name of savedProfileNames) {
        if (typeof name === 'string' && name.trim()) {
            const clean = name.trim();
            const key = clean.toLowerCase();
            if (!normalizedMap.has(key)) {
                normalizedMap.set(key, clean);
            }
        }
    }

    return {
        active,
        allAccounts: Array.from(normalizedMap.values()),
        source: active ? 'keyring' : 'saved_profiles'
    };
}

/**
 * Get detailed health status for all accounts in the pool (strictly deduplicated).
 *
 * @param {string} [baseDataPath]
 * @param {string[]} [savedProfileNames]
 * @returns {Array<{
 *   account: string,
 *   isReady: boolean,
 *   cooldownRemainingMin: number,
 *   switchCount: number,
 *   hasSavedProfile: boolean
 * }>}
 */
function getAccountPoolStatus(baseDataPath, savedProfileNames = []) {
    const { allAccounts } = discoverAccounts(savedProfileNames);
    const poolState = loadPoolState(baseDataPath);
    const now = Date.now();

    const savedList = keyringManager.listProfiles();
    const savedSet = new Set(savedList.map(p => (p.email || p.name).trim().toLowerCase()));
    for (const name of savedProfileNames) {
        savedSet.add(name.trim().toLowerCase());
    }

    return allAccounts.map(account => {
        const key = account.trim().toLowerCase();
        const entry = poolState[key] || poolState[account] || { lastExhausted: 0, switchCount: 0, cooldownUntil: 0 };
        const elapsed = now - entry.lastExhausted;
        
        let inCooldown = false;
        let remainingMin = 0;
        if (entry.cooldownUntil && entry.cooldownUntil > 0) {
            inCooldown = now < entry.cooldownUntil;
            remainingMin = inCooldown ? Math.ceil((entry.cooldownUntil - now) / 60000) : 0;
        } else if (entry.lastExhausted > 0 && elapsed < QUOTA_COOLDOWN_MS) {
            inCooldown = true;
            remainingMin = Math.ceil((QUOTA_COOLDOWN_MS - elapsed) / 60000);
        }

        return {
            account,
            isReady: !inCooldown,
            cooldownRemainingMin: remainingMin,
            switchCount: entry.switchCount || 0,
            hasSavedProfile: savedSet.has(key)
        };
    });
}

/**
 * Record a quota exhaustion event for an account.
 *
 * @param {string} [baseDataPath]
 * @param {string} [accountName]
 * @param {number} [cooldownMs]
 */
function recordExhaustion(baseDataPath, accountName, cooldownMs = null) {
    if (!accountName) return;
    const poolState = loadPoolState(baseDataPath);
    const key = accountName.trim().toLowerCase();
    const current = poolState[key] || poolState[accountName] || { lastExhausted: 0, switchCount: 0, cooldownUntil: 0 };
    const now = Date.now();
    current.lastExhausted = now;
    if (cooldownMs && typeof cooldownMs === 'number' && cooldownMs > 0) {
        current.cooldownUntil = now + cooldownMs;
    }
    current.switchCount = (current.switchCount || 0) + 1;
    poolState[key] = current;
    savePoolState(baseDataPath, poolState);
}

/**
 * Pick the best next available account using round-robin and cooldown awareness.
 *
 * @param {string} [baseDataPath]
 * @param {string[]} [savedProfileNames]
 * @param {string | null} [currentAccount]
 * @returns {string | null}
 */
function getNextAvailableProfile(baseDataPath, savedProfileNames = [], currentAccount = null) {
    const allSaved = keyringManager.listProfiles().map(p => p.email || p.name);
    const combined = Array.from(new Set([...allSaved, ...savedProfileNames]));

    if (combined.length <= 1) {
        return null;
    }

    const currentKey = currentAccount ? currentAccount.trim().toLowerCase() : '';
    const statuses = getAccountPoolStatus(baseDataPath, combined);
    const readyProfiles = statuses.filter(s => s.hasSavedProfile && s.isReady && s.account.trim().toLowerCase() !== currentKey);

    if (readyProfiles.length > 0) {
        readyProfiles.sort((a, b) => a.switchCount - b.switchCount);
        return readyProfiles[0].account;
    }

    // Fallback to standard round-robin
    const currentIndex = combined.findIndex(p => p.trim().toLowerCase() === currentKey);
    const nextIndex = (currentIndex + 1) % combined.length;
    return combined[nextIndex];
}

module.exports = {
    getActiveGoogleAccount,
    discoverAccounts,
    getAccountPoolStatus,
    recordExhaustion,
    getNextAvailableProfile,
    QUOTA_COOLDOWN_MS,
    RATE_LIMIT_REGEX,
    containsRateLimitError
};
