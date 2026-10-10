"""Log checker for quota exhaustion (429) and auth revocation (401)."""

import os
import shutil
import sqlite3
import sys


def check_logs(db_path: str, start_ts: int) -> list[str]:
    results = []
    if not os.path.exists(db_path):
        return results

    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()

        # Check authentic 429 quota exhaustion
        cur.execute(
            """
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
        """,
            (start_ts - 5,),
        )
        if cur.fetchone():
            results.append("EXHAUSTED")

        # Check authentic 401 token revocation
        cur.execute(
            """
            SELECT feedback_log_body FROM logs 
            WHERE ts >= ? 
              AND (feedback_log_body LIKE '%token_revoked%'
                   OR feedback_log_body LIKE '%workspace routing discovery unauthorized%'
                   OR feedback_log_body LIKE '%Encountered invalidated oauth token%')
            LIMIT 1;
        """,
            (start_ts - 5,),
        )
        if cur.fetchone():
            results.append("REVOKED")

        conn.close()
    except Exception:
        pass

    return results


def check_auth_token(auth_path: str) -> str:
    """Pre-flight check for auth.json token validity. Returns 'VALID', 'REVOKED', 'EXHAUSTED', or 'UNKNOWN'."""
    if not os.path.exists(auth_path):
        return "UNKNOWN"
    try:
        import json
        import urllib.error
        import urllib.request

        with open(auth_path, "r", encoding="utf-8") as f:
            d = json.load(f)
        token = d.get("tokens", {}).get("access_token", "")
        if not token:
            return "REVOKED"
        req = urllib.request.Request(
            "https://chatgpt.com/backend-api/codex/models?client_version=0.162.1",
            headers={"Authorization": f"Bearer {token}", "User-Agent": "codex-cli"},
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            if resp.status == 200:
                return "VALID"
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return "REVOKED"
        if e.code == 429:
            return "EXHAUSTED"
    except Exception:
        pass
    return "UNKNOWN"


def setup_account_home(email: str, workspace_dir: str | None = None) -> str:
    """Configures an isolated CODEX_HOME directory for the specified workspace and account."""
    base = os.path.normpath(os.path.expanduser("~/.codex"))
    if workspace_dir:
        ws_name = os.path.basename(os.path.normpath(workspace_dir)).lower()
        acct_dir = os.path.normpath(os.path.join(base, "workspaces", ws_name))
    else:
        acct_dir = os.path.normpath(os.path.join(base, "accounts", email.lower()))
    os.makedirs(acct_dir, exist_ok=True)

    # 1. Place dedicated auth.json
    profile = os.path.normpath(os.path.join(base, "profiles", f"{email}.json"))
    dst_auth = os.path.normpath(os.path.join(acct_dir, "auth.json"))
    if os.path.exists(profile):
        shutil.copy2(profile, dst_auth)
    elif os.path.exists(os.path.normpath(os.path.join(base, "auth.json"))):
        shutil.copy2(os.path.normpath(os.path.join(base, "auth.json")), dst_auth)

    # 2. Config files
    for cfg in ["config.toml", "auto.config.toml", "models_cache.json", "version.json"]:
        src = os.path.normpath(os.path.join(base, cfg))
        dst = os.path.normpath(os.path.join(acct_dir, cfg))
        if os.path.exists(src) and not os.path.exists(dst):
            try:
                shutil.copy2(src, dst)
            except Exception:
                pass

    # Ensure config.toml in account home has sandbox_mode = "danger-full-access"
    acct_cfg = os.path.normpath(os.path.join(acct_dir, "config.toml"))
    if os.path.exists(acct_cfg):
        try:
            with open(acct_cfg, "r", encoding="utf-8") as f:
                cfg_text = f.read()
            changed = False
            if 'sandbox_mode' not in cfg_text:
                cfg_text = 'sandbox_mode = "danger-full-access"\n' + cfg_text
                changed = True
            if 'sandbox = "elevated"' in cfg_text:
                cfg_text = cfg_text.replace('sandbox = "elevated"', 'sandbox = "unelevated"')
                changed = True
            if changed:
                with open(acct_cfg, "w", encoding="utf-8") as f:
                    f.write(cfg_text)
        except Exception:
            pass

    # 3. Session history indexes (copy only, never hard link)
    for idx_file in ["session_index.jsonl", "history.jsonl"]:
        dst = os.path.normpath(os.path.join(acct_dir, idx_file))
        if not os.path.exists(dst):
            src_acct = os.path.normpath(os.path.join(base, "accounts", email.lower(), idx_file))
            src_base = os.path.normpath(os.path.join(base, idx_file))
            if os.path.exists(src_acct):
                try:
                    shutil.copy2(src_acct, dst)
                except Exception:
                    pass
            elif os.path.exists(src_base):
                try:
                    shutil.copy2(src_base, dst)
                except Exception:
                    pass

    # 4. Junctions for skills, rules, plugins, sessions, and sandbox components
    for d in ["skills", "rules", "plugins", "sessions", ".sandbox", ".sandbox-bin", ".sandbox-secrets", ".tmp"]:
        src = os.path.normpath(os.path.join(base, d))
        dst = os.path.normpath(os.path.join(acct_dir, d))
        if os.path.exists(src) and not os.path.exists(dst):
            try:
                import subprocess

                subprocess.run(["cmd", "/c", "mklink", "/J", dst, src], capture_output=True)
            except Exception:
                pass

    # 5. Global state and sandbox guard files
    try:
        for item in os.listdir(base):
            if item.startswith(".codex-") or item.startswith(".sandbox"):
                src = os.path.normpath(os.path.join(base, item))
                dst = os.path.normpath(os.path.join(acct_dir, item))
                if os.path.isfile(src) and not os.path.exists(dst):
                    try:
                        shutil.copy2(src, dst)
                    except Exception:
                        pass
    except Exception:
        pass

    # 6. Purge stale setup_error.json
    for sdir in [base, acct_dir]:
        err_path = os.path.normpath(os.path.join(sdir, ".sandbox", "setup_error.json"))
        if os.path.exists(err_path):
            try:
                os.remove(err_path)
            except Exception:
                pass

    return acct_dir


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--check-token":
        print(check_auth_token(sys.argv[2]))
        sys.exit(0)

    if len(sys.argv) >= 3 and sys.argv[1] == "--setup-home":
        ws = sys.argv[3] if len(sys.argv) >= 4 else None
        print(setup_account_home(sys.argv[2], ws))
        sys.exit(0)

    if len(sys.argv) < 3:
        sys.exit(0)

    db = sys.argv[1]
    ts = int(sys.argv[2])
    outcomes = check_logs(db, ts)
    for outcome in outcomes:
        print(outcome)


