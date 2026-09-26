# 📦 Installation & Setup Guide — Minus Account Loop (v2.0.0)

This comprehensive guide will walk you through installing, configuring, and adding multiple Google accounts to **Minus Account Loop**.

---

## 📋 System Requirements

* **Operating System:** Windows 10 or Windows 11 (64-bit)
* **PowerShell:** Windows PowerShell 5.1 or PowerShell 7+ (`pwsh`)
* **Node.js:** v18.0.0 or higher ([Download Node.js](https://nodejs.org/))
* **Editor/CLI:** Google Antigravity IDE, VS Code, or Antigravity CLI (`agy`)

---

## ⚡ Option 1: Automated 1-Click Install (Recommended)

1. Open PowerShell and navigate to where you want to clone the repository:
   ```powershell
   git clone https://github.com/PROGRAMMER-DUMMY/minusAccountloop.git
   cd minusAccountloop
   ```

2. Run the automated installer:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\install.ps1
   ```

**What the installer does automatically:**
* ✅ Verifies Node.js and editor CLI (`code` or `antigravity`) prerequisites.
* ✅ Packages the native VSIX extension (`minus-account-loop-2.0.0.vsix`).
* ✅ Installs the extension into your editor with `--force`.
* ✅ Binds the smart `agy` function into your PowerShell `$PROFILE`.

3. Restart your PowerShell terminal (or run `. $PROFILE`).

---

## 🛠️ Option 2: Manual Installation

If you prefer building and installing manually step-by-step:

### 1. Build and Package Extension
```powershell
cd minusAccountloop

# Install packaging CLI
npm install -g @vscode/vsce

# Package VSIX
npx @vscode/vsce package --no-dependencies
```

### 2. Install into VS Code or Antigravity IDE
```powershell
# If using standard VS Code:
code --install-extension minus-account-loop-2.0.0.vsix --force

# If using Antigravity IDE:
antigravity --install-extension minus-account-loop-2.0.0.vsix --force
```

### 3. Bind Smart AGY to PowerShell Profile
Open your PowerShell profile file:
```powershell
notepad $PROFILE
```
Add the following lines at the bottom of the file (replace with your actual repository path):
```powershell
# MinusAccountLoop: Smart AGY launcher with per-workspace account binding & quota auto-rotation
function agy {
    & "C:\path\to\minusAccountloop\scripts\smart_agy.ps1" @args
}
```
Save and restart your terminal.

---

## 🔑 How to Add & Save Multiple Google Accounts (Onboarding)

To rotate across multiple Google accounts, you need to save each account profile once.

### Method A: Using the VS Code / Antigravity IDE Status Bar (Fastest)

1. **Log in to your 1st Google Account:**
   * In Antigravity IDE / VS Code, sign in with your primary Google account via the normal Google OAuth login flow.
2. **Save Account Profile:**
   * In the bottom status bar, locate the **`$(add) +`** button (or press `Ctrl+Shift+P` and search `Minus Account Loop: Save Current Profile`).
   * The extension reads the credential directly from Windows Credential Manager and saves it to `~/.gemini/profiles/<your-email>.json`.
3. **Log in to your 2nd Google Account:**
   * Sign out and log in with your second Google account.
   * Click **`$(add) +`** again.
4. **Repeat for all your Google Accounts:**
   * You can save an **unlimited** number of accounts (e.g. 3, 5, 7+).

---

### Method B: Using the Terminal (`agy`)

1. Open PowerShell and run:
   ```powershell
   agy
   ```
2. Select `1. Google OAuth` and log in via your browser.
3. Once logged in, open Antigravity IDE / VS Code and click **`$(add) +`** in the status bar to save the profile into the rotation pool.
4. Repeat for your other accounts.

---

## 🎯 Daily Usage & Command Reference

### 1. Auto-Binding Workspaces
Whenever you run `agy` inside any project directory, it automatically binds that workspace to a dedicated Google account:
```powershell
cd C:\Users\yourname\PycharmProjects\project-a
agy
# Output: [MinusAccountLoop] Pinned workspace to: account1@gmail.com

cd C:\Users\yourname\PycharmProjects\project-b
agy
# Output: [MinusAccountLoop] Pinned workspace to: account2@gmail.com
```
*Each project gets its own isolated quota pool!*

### 2. View Quota Pool Status
Check which accounts are ready vs. on cooldown at any time:
```powershell
agy status
```
Example Output:
```text
=== Google Antigravity Account Pool Status ===
Total Profiles: 3

  [READY]                        account1@gmail.com  (Rotated 2 times) -> [project-a]
  [COOLDOWN (142 m remaining)]  account2@gmail.com  (Rotated 5 times) -> [project-b]
  [READY]                        account3@gmail.com  (Rotated 1 times) -> [project-c]

Current workspace: project-a
Assigned account:  account1@gmail.com
```

### 3. Rotate Current Workspace on Demand
If an account runs out of quota, rotate to the next ready account instantly:
```powershell
agy -r
```
Or resume your conversation on a fresh account:
```powershell
agy -c -r
```

### 4. Explicitly Assign an Account
Force a specific workspace to use a particular account:
```powershell
agy --use developer@gmail.com
```

---

## ⚠️ Operational Safety & Warnings: What NOT to Do vs. What Is OK to Do

### 🚫 What NOT to Do (Pitfalls & Invariant Breakers)

1. **DO NOT attempt to alter credentials in Windows Keyring while an `agy` session is actively streaming:**
   * *Why:* `agy.exe` holds an open HTTP/2 SSE streaming socket tied to the identity used when the process booted. Mutating credentials externally while the process is running causes token/stream mismatch on Google's backend, producing `403 Forbidden`, `wsarecv` socket teardown, hanging block cursors (`█`), and DOM scroll locks.
   * *The Rule:* Process lifetime is credential lifetime. Always let the process restart (via `/exit` or `Ctrl+C`) to load new credentials.

2. **DO NOT force-kill with `taskkill /F /IM agy.exe` or kill PowerShell:**
   * *Why:* Hard aborts bypass PowerShell's `finally` block, preventing the post-execution quota detection from logging the cooldown to `account_pool_state.json`.
   * *The Rule:* Exit naturally by typing `/exit` inside `agy`, or press `Ctrl + C` inside the terminal.

3. **DO NOT edit or tamper with SQLite databases (`state.vscdb`):**
   * *Why:* Minus Account Loop operates exclusively at the credential layer via the Windows Credential Manager API (`advapi32.dll: CredWriteW`). Tampering with internal editor state databases risks chat history corruption.

4. **DO NOT modify files in `tests/golden/`:**
   * *Why:* Golden tests are strictly read-only acceptance contracts protecting the keyring contract and zero-harm boundaries.

---

### ✅ What Is 100% OK to Do (Safe & Supported Everyday Actions)

1. **Type `/exit` whenever quota runs out:**
   * Completely safe and recommended. The launcher detects quota exhaustion, enters the account into cooldown, rotates the workspace to the next healthy account, and starts the 3-second auto-resume timer.
2. **Press `Ctrl + C` if a prompt or output gets stuck:**
   * The PowerShell `finally` block safely catches the interrupt, updates pool state, and pre-swaps the keyring. Then simply run `agy -c` to continue.
3. **Run `agy status` at any time:**
   * View live recovery countdowns, switch counts, and workspace bindings across all accounts without interrupting any running work.
4. **Run `agy -r` (or `agy --rotate`) to manually force rotation:**
   * Instantly switch the current workspace to the next healthy account in the pool on demand.
5. **Add unlimited Google accounts:**
   * You can save 3, 7, 10, or more accounts into `~/.gemini/profiles/`. The round-robin and cooldown engine scales seamlessly across any number of accounts.
6. **Work across multiple terminal tabs or project folders simultaneously:**
   * Each folder maintains its own isolated account binding in `workspace_accounts.json`.

---

## 🧪 Verifying the Installation

To verify that the Windows Keyring contract and zero-harm invariants are working properly:
```powershell
# Install test runner
pip install pytest

# Run tests
pytest
```
Expected output:
```text
tests\golden\test_keyring_contract.py .             [ 14%]
tests\golden\test_zero_harm_contract.py ...         [ 57%]
tests\unit\test_keyring_manager.py ...              [100%]
============================== 7 passed in 1.20s ==============================
```

---

## ❓ Frequently Asked Questions & Troubleshooting

#### Q: Where are my saved account credentials stored?
* Verified profile snapshots are saved in:
  `%USERPROFILE%\.gemini\profiles\<email>.json`
* Workspace directory assignments are saved in:
  `%USERPROFILE%\.gemini\workspace_accounts.json`
* Live cooldown timestamps are tracked in:
  `%USERPROFILE%\.gemini\account_pool_state.json`
* Active credentials live in Windows Credential Manager under the target: `gemini:antigravity`.

#### Q: Why doesn't `/usage` update or switch accounts dynamically mid-session?
* **Architecture Invariant:** When `agy.exe` (the compiled Go binary) boots, it initializes its internal authentication provider (`b.codeAssistClient.AuthProvider = b.cliAuth`) into process heap memory **once** from Windows Credential Manager.
* During an active interactive session, `agy.exe` holds an open HTTP/2 SSE streaming socket tied to that specific session ID and Google OAuth identity. It never re-reads the Windows Keyring mid-flight.
* Querying `/usage` checks Google's API using that active in-memory token.
* Attempting to mutate credentials mid-stream from an external process would cause HTTP/2 socket desynchronization, 403 authorization rejects, hanging block cursors (`█`), and DOM scroll locks. The Go process boundary **is** the safe credential boundary.

#### Q: How do I seamlessly continue when quota runs out? (1-Key Auto-Resume)
* If your quota exhausts during an active session, simply type `/exit` (or press `Ctrl+C`).
* Minus Account Loop's launcher catches the quota event via `try...finally`, parses the exact reset duration, marks the exhausted account in cooldown, selects the next fresh account, and pre-emptively updates Windows Credential Manager in `<50ms`.
* **If you exited via `/exit`:** The launcher automatically detects the session and prompts:
  `[MinusAccountLoop] 🚀 Auto-resume ready for conversation <id> on <new-account>. Press [ENTER] to resume immediately (or wait 3s)...`
  It launches straight back into your conversation with 100% fresh quota!
* **If you exited via `Ctrl+C`:** Simply type `agy -c` (or Up Arrow + Enter) to immediately resume on the rotated account.

---

## ⚖️ Terms of Service & Fair Use Disclaimer

**Minus Account Loop** is an independent, open-source client-side developer utility designed to assist software engineers in managing multiple authorized identities across local project directories.

* **Standard OS Keyring Switching:** Operates analogously to `aws-vault`, `gcloud config configurations`, or `git config user.email` by interacting with the official Windows Credential Manager API (`advapi32.dll: CredReadW / CredWriteW`).
* **Zero Binary Modification:** Does not decompile, alter, reverse-engineer, or inject code into Google's `agy.exe` binary.
* **No Account Creation Automation:** Does not automate account generation, bypass Google verification, or generate fictitious identities. All profiles are authentic, verified Google accounts explicitly signed in by the user via standard Google OAuth.
* **Strict Quota Compliance:** Does not circumvent Google's server-side rate limits. When Google issues an HTTP 429 (`RESOURCE_EXHAUSTED`), the tool honors the backoff, records the cooldown window, and skips the depleted account until recovery.
* **Independent Tooling:** This project is not affiliated with, endorsed by, or sponsored by Google LLC or Alphabet Inc. All product names, logos, and brands are property of their respective owners.

