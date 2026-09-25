// @ts-check
'use strict';

/**
 * Minus Account Loop — Windows Keyring & Profile Manager (v2.0.0)
 *
 * Direct integration with Windows Credential Manager for Google Antigravity.
 * Target: gemini:antigravity
 *
 * Invariants:
 * - ZERO process terminations (Code.exe is NEVER killed).
 * - ZERO database overwrites (state.vscdb and chat sessions are NEVER touched).
 * - Switches accounts directly in Windows Credential Manager in < 100ms.
 *
 * @module keyringManager
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const CREDENTIAL_TARGET = 'gemini:antigravity';
const CREDENTIAL_USER = 'antigravity';
const PROFILES_DIR = path.join(os.homedir(), '.gemini', 'profiles');
const WINCRED_SCRIPT = path.join(__dirname, '..', 'scripts', 'wincred.ps1');

/**
 * Ensure directory exists.
 * @param {string} dirPath
 */
function ensureDir(dirPath) {
    if (!fs.existsSync(dirPath)) {
        fs.mkdirSync(dirPath, { recursive: true });
    }
}

/**
 * Read the raw JSON credential blob from Windows Credential Manager.
 * @returns {string | null}
 */
function readKeyringBlob() {
    try {
        const output = execFileSync('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', WINCRED_SCRIPT,
            '-Action', 'read',
            '-Target', CREDENTIAL_TARGET
        ], {
            encoding: 'utf8',
            stdio: ['pipe', 'pipe', 'ignore'],
            timeout: 8000
        });
        const trimmed = output.trim();
        return trimmed.length > 0 ? trimmed : null;
    } catch (e) {
        console.error('[KeyringManager] Failed to read credential:', e);
        return null;
    }
}

/**
 * Write a JSON credential blob into Windows Credential Manager.
 * @param {string} secretBlob
 * @returns {boolean}
 */
function writeKeyringBlob(secretBlob) {
    try {
        ensureDir(PROFILES_DIR);
        const tempFile = path.join(PROFILES_DIR, `_temp_write_${Date.now()}.json`);
        fs.writeFileSync(tempFile, secretBlob, 'utf8');

        const output = execFileSync('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', WINCRED_SCRIPT,
            '-Action', 'write',
            '-Target', CREDENTIAL_TARGET,
            '-UserName', CREDENTIAL_USER,
            '-SecretFile', tempFile
        ], {
            encoding: 'utf8',
            stdio: ['pipe', 'pipe', 'ignore'],
            timeout: 8000
        });

        try { fs.unlinkSync(tempFile); } catch { /* ignore */ }
        return output.trim() === 'SUCCESS';
    } catch (e) {
        console.error('[KeyringManager] Failed to write credential:', e);
        return false;
    }
}

/**
 * Decode JWT token without external libraries.
 * @param {string} jwt
 * @returns {Record<string, any> | null}
 */
function decodeJwt(jwt) {
    try {
        const parts = jwt.split('.');
        if (parts.length !== 3) return null;
        let b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
        while (b64.length % 4 !== 0) {
            b64 += '=';
        }
        const jsonStr = Buffer.from(b64, 'base64').toString('utf8');
        return JSON.parse(jsonStr);
    } catch {
        return null;
    }
}

/**
 * Get active Antigravity account info directly from Windows Credential Manager.
 * @returns {{ email: string | null, expiry: number | null, raw: string | null }}
 */
function getActiveAccount() {
    const raw = readKeyringBlob();
    if (!raw) {
        return { email: null, expiry: null, raw: null };
    }

    try {
        const data = JSON.parse(raw);
        if (data.id_token) {
            const payload = decodeJwt(data.id_token);
            if (payload && payload.email) {
                return {
                    email: payload.email.trim(),
                    expiry: payload.exp ? payload.exp * 1000 : null,
                    raw
                };
            }
        }
    } catch (e) {
        console.error('[KeyringManager] Parse error:', e);
    }

    return { email: null, expiry: null, raw };
}

/**
 * Save current active credential as a named profile in ~/.gemini/profiles/<email>.json
 * @param {string} [customName]
 * @returns {{ success: boolean, email: string, profilePath: string, message: string }}
 */
function saveCurrentProfile(customName) {
    ensureDir(PROFILES_DIR);
    const active = getActiveAccount();
    if (!active.raw || !active.email) {
        return {
            success: false,
            email: '',
            profilePath: '',
            message: 'No active Google Antigravity credential found in Windows Credential Manager.'
        };
    }

    const profileName = (customName || active.email).trim().toLowerCase();
    const fileName = `${profileName}.json`;
    const targetPath = path.join(PROFILES_DIR, fileName);

    const profileData = {
        name: profileName,
        email: active.email,
        savedAt: new Date().toISOString(),
        expiry: active.expiry,
        credentialBlob: active.raw
    };

    fs.writeFileSync(targetPath, JSON.stringify(profileData, null, 2), 'utf8');
    return {
        success: true,
        email: active.email,
        profilePath: targetPath,
        message: `Profile for "${active.email}" saved successfully.`
    };
}

/**
 * List all saved profiles in ~/.gemini/profiles/
 * @returns {Array<{ name: string, email: string, savedAt: string, expiry: number | null }>}
 */
function listProfiles() {
    ensureDir(PROFILES_DIR);
    /** @type {Array<{ name: string, email: string, savedAt: string, expiry: number | null }>} */
    const profiles = [];

    if (!fs.existsSync(PROFILES_DIR)) return profiles;

    const files = fs.readdirSync(PROFILES_DIR).filter(f => f.endsWith('.json') && !f.startsWith('_'));
    for (const file of files) {
        try {
            const fullPath = path.join(PROFILES_DIR, file);
            const content = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
            if (content.credentialBlob && (content.email || content.name)) {
                profiles.push({
                    name: content.name || path.basename(file, '.json'),
                    email: content.email || content.name,
                    savedAt: content.savedAt || '',
                    expiry: content.expiry || null
                });
            }
        } catch { /* ignore corrupted profile file */ }
    }

    return profiles;
}

/**
 * Switch active credential in Windows Credential Manager to target profile.
 * ZERO editor restart, ZERO terminal loss, ZERO chat database mutation.
 *
 * @param {string} targetEmailOrName
 * @returns {{ success: boolean, email: string, message: string }}
 */
function switchProfile(targetEmailOrName) {
    ensureDir(PROFILES_DIR);
    const cleanTarget = targetEmailOrName.trim().toLowerCase();
    const targetFile = path.join(PROFILES_DIR, `${cleanTarget}.json`);

    let profileData = null;

    if (fs.existsSync(targetFile)) {
        try {
            profileData = JSON.parse(fs.readFileSync(targetFile, 'utf8'));
        } catch { /* parse failed */ }
    }

    if (!profileData) {
        const all = listProfiles();
        const found = all.find(p => p.email.toLowerCase() === cleanTarget || p.name.toLowerCase() === cleanTarget);
        if (found) {
            const altFile = path.join(PROFILES_DIR, `${found.name}.json`);
            if (fs.existsSync(altFile)) {
                profileData = JSON.parse(fs.readFileSync(altFile, 'utf8'));
            }
        }
    }

    if (!profileData || !profileData.credentialBlob) {
        return {
            success: false,
            email: cleanTarget,
            message: `Profile "${targetEmailOrName}" not found in ${PROFILES_DIR}.`
        };
    }

    const ok = writeKeyringBlob(profileData.credentialBlob);
    if (ok) {
        return {
            success: true,
            email: profileData.email || cleanTarget,
            message: `Switched active Antigravity account to "${profileData.email || cleanTarget}". No restart needed!`
        };
    } else {
        return {
            success: false,
            email: profileData.email || cleanTarget,
            message: `Failed to write credential to Windows Credential Manager.`
        };
    }
}

module.exports = {
    CREDENTIAL_TARGET,
    CREDENTIAL_USER,
    PROFILES_DIR,
    getActiveAccount,
    saveCurrentProfile,
    listProfiles,
    switchProfile,
    readKeyringBlob,
    writeKeyringBlob,
    decodeJwt
};
