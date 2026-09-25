// @ts-check
'use strict';

/**
 * Minus Account Loop — Non-destructive Account Switcher (v2.0.0)
 *
 * Switches credentials directly in Windows Credential Manager.
 * Invariant: ZERO process kills (Code.exe is NEVER terminated).
 *
 * Usage:
 *   node swapper.js --account <email>
 */

const keyringManager = require('../src/keyringManager');

function parseArgs() {
    const args = process.argv.slice(2);
    /** @type {Record<string, string>} */
    const params = {};
    for (let i = 0; i < args.length; i += 2) {
        const key = args[i].replace(/^--/, '');
        if (args[i + 1]) {
            params[key] = args[i + 1];
        }
    }
    return params;
}

const params = parseArgs();
const targetAccount = params.account || params.profile || process.argv[2];

if (!targetAccount) {
    console.error('[AccountSwitcher] Usage: node swapper.js --account <email>');
    process.exit(1);
}

const result = keyringManager.switchProfile(targetAccount);
console.log(`[AccountSwitcher] ${result.message}`);
process.exit(result.success ? 0 : 1);
