# Minus Account Loop — Antigravity Multi-Account Switcher

[![CI](https://github.com/PROGRAMMER-DUMMY/minusAccountloop/actions/workflows/ci.yml/badge.svg)](https://github.com/PROGRAMMER-DUMMY/minusAccountloop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Version 2.0.0** — High-Performance, Zero-Disruption Keyring Architecture

A developer-native multi-account switcher and quota-aware auto-rotation engine for **Google Antigravity IDE** and **Antigravity CLI (`agy`)**.

---

## 🌟 Core Systemic Invariants (v2.0.0)

* 🛡️ **Zero Editor Restarts:** Never terminates `Code.exe` or `Antigravity.exe`.
* 🛡️ **Zero Terminal Disruption:** Never terminates open integrated terminal sessions or injects destructive keystrokes.
* 🛡️ **Zero Chat State Loss:** Never tampers with `state.vscdb`, `storage.json`, or active chat SQLite databases.
* ⚡ **Native Windows Credential Manager:** Directly reads and writes the atomic `gemini:antigravity` credential target via Win32 API (`advapi32.dll`) in **<50ms**.
* 🔄 **Per-Workspace Account Isolation:** Automatically assigns and pins each project directory to a dedicated Google AI Pro account, isolating quota pools across multiple workspaces.
* ⏱️ **Dynamic Quota Cooldown Awareness:** Tracks Google AI Pro quota exhaustion cooldowns and parses exact recovery windows (e.g. 2h, 24h, 65h) directly from Google's runtime error responses. Depleted accounts are automatically skipped until their quota recovers.

---

## 🚀 Features

### 1. Smart AGY Terminal Launcher (`scripts/smart_agy.ps1`)
Wraps the `agy` command with intelligent workspace binding and quota monitoring:
* **Directory Pinning:** Automatically binds your current directory (e.g. `~/PycharmProjects/my-app`) to a dedicated account in `~/.gemini/workspace_accounts.json`.
* **Auto-Cooldown Rotation:** If an account hits quota exhaustion, the next `agy` launch automatically rotates the workspace to a healthy, ready account.
* **1-Key Auto-Resume:** When quota exhausts, typing `/exit` triggers an automated 3-second auto-resume countdown that seamlessly continues your exact conversation on the next account with full quota.
* **On-Demand Rotation:** Rotate an account on demand at any time:
  ```powershell
  agy -r           # Rotate current workspace to next ready account
  agy -c -r        # Rotate and resume conversation
  ```
* **Real-Time Quota Pool Status:**
  ```powershell
  agy status       # Displays READY vs COOLDOWN timer for all accounts
  ```
* **Post-Execution Watcher:** Automatically detects `RESOURCE_EXHAUSTED (code 429)` in `cli.log` upon session completion (even on `Ctrl+C`) and tags cooldown immediately.

### 2. VS Code / Antigravity IDE Extension
* Status bar buttons for 1-click account switching.
* Silent, non-intrusive rate-limit auto-rotation.
* Strict regex rate-limit parsing to eliminate false positives.

---

## ⚠️ Operational Safety: Do's & Don'ts

| 🚫 What NOT to Do | Why |
| :--- | :--- |
| **DO NOT edit Windows Keyring during an active `agy` session** | The Go binary holds an open HTTP/2 SSE streaming socket tied to the process boot identity. Mutating tokens externally mid-stream causes token/stream mismatch on Google's backend, producing 403 Forbidden, `wsarecv` socket drops, hanging cursors (`█`), and DOM scroll locks. |
| **DO NOT force-kill with `taskkill /F /IM agy.exe`** | Hard process aborts bypass PowerShell's `finally` block, skipping post-run quota logging and leaving orphaned network sockets. |
| **DO NOT edit or tamper with SQLite databases (`state.vscdb`)** | Minus Account Loop operates exclusively at the credential layer via Win32 CredWriteW. Tampering with SQLite risks corrupting chat histories. |
| **DO NOT modify files in `tests/golden/`** | Protected acceptance contracts enforcing the keyring security boundary. |

| ✅ What Is 100% OK to Do | Benefit |
| :--- | :--- |
| **Type `/exit` whenever quota runs out** | Launcher detects exhaustion, triggers cooldown, pre-swaps credentials in `<50ms`, and auto-resumes in 3 seconds. |
| **Press `Ctrl + C` if an output hangs** | PowerShell `finally` safely catches the interrupt, updates pool state, and pre-swaps the keyring. Then run `agy -c` to continue. |
| **Run `agy status` at any time** | View minute-by-minute cooldown recovery timers across all accounts without affecting any running session. |
| **Run `agy -r` (or `agy --rotate`)** | Force-rotate current workspace to the next healthy account on demand. |
| **Add unlimited Google accounts** | Save 3, 7, 10, or more accounts into `~/.gemini/profiles/`. The scheduler balances all of them. |

---

## 🔒 Security & Privacy

* **Zero External Telemetry:** 100% offline local operations. Zero outbound network requests.
* **No Hardcoded Credentials:** Actual OAuth tokens and JWT payloads are stored exclusively in your local Windows Credential Manager and `~/.gemini/profiles/` directory.
* **Safe CLI Execution:** Uses strict argument arrays and PowerShell parameter validation to prevent shell injection.
* **Strict Name Sanitization:** Profile names are strictly validated against `^[a-zA-Z0-9 _.\-@]+$`.

---

## 🛠️ Quick Installation (One-Click)

> For full setup details, account onboarding instructions, and troubleshooting, read the **[Comprehensive Installation Guide (INSTALL.md)](INSTALL.md)**.

Clone the repository and run the automated Windows installer:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```
This automatically:
1. Verifies Node.js and editor CLI prerequisites.
2. Packages and installs the VSIX extension into your editor (`code` or `antigravity`).
3. Binds the `agy` command into your PowerShell `$PROFILE`.

### Manual Setup (Alternative)
```powershell
# 1. Package and install extension
npx @vscode/vsce package --no-dependencies
code --install-extension minus-account-loop-2.0.0.vsix --force

# 2. Add to your PowerShell $PROFILE:
function agy {
    & "C:\path\to\minusAccountloop\scripts\smart_agy.ps1" @args
}
```

---

## 🧪 Testing

Run the full golden and unit test suite:
```powershell
pytest
```
* `tests/golden/test_keyring_contract.py`: Verifies Win32 CredRead/CredWrite contract with `gemini:antigravity`.
* `tests/golden/test_zero_harm_contract.py`: Enforces zero process kills and zero `state.vscdb` tampering.
* `tests/unit/test_keyring_manager.py`: Verifies JWT parsing, account discovery, and rate-limit detection regex.

---

## 📄 License

[MIT](LICENSE)
