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


def get_full_pool_status() -> list[dict]:
    """Retrieves live authentication status, session locks, workspace mappings, and 5h/weekly quota for all accounts."""
    import glob
    import json
    import re
    import time

    base = os.path.normpath(os.path.expanduser("~/.codex"))
    profiles_dir = os.path.join(base, "profiles")
    mapping_file = os.path.join(base, "workspace_accounts.json")
    sessions_dir = os.path.join(base, "active_sessions")

    ws_mappings = {}
    if os.path.exists(mapping_file):
        try:
            with open(mapping_file, "r", encoding="utf-8") as f:
                ws_mappings = json.load(f)
        except Exception:
            pass

    email_to_ws = {}
    for ws_path, acct in ws_mappings.items():
        em = acct.lower().strip()
        email_to_ws.setdefault(em, []).append(os.path.basename(ws_path))

    active_locks = {}
    if os.path.exists(sessions_dir):
        for f in glob.glob(os.path.join(sessions_dir, "*.lock")):
            try:
                with open(f, "r", encoding="utf-8") as lf:
                    data = json.load(lf)
                pid = int(data.get("pid", 0))
                em = os.path.basename(f).split("_")[0].lower()
                active_locks[em] = pid
            except Exception:
                pass

    now = int(time.time())
    results = []

    profile_files = sorted(glob.glob(os.path.join(profiles_dir, "*.json")))
    for ppath in profile_files:
        email = os.path.basename(ppath).replace(".json", "").lower()
        token_health = check_auth_token(ppath)
        pid = active_locks.get(email, 0)

        ws_list = email_to_ws.get(email, [])
        db_candidates = [
            os.path.join(base, "accounts", email, "logs_2.sqlite")
        ] + [
            os.path.join(base, "workspaces", ws, "logs_2.sqlite")
            for ws in ws_list
        ]

        best_row = None
        for db in db_candidates:
            if not os.path.exists(db):
                continue
            try:
                conn = sqlite3.connect(db)
                cur = conn.cursor()
                cur.execute(
                    """
                    SELECT ts, feedback_log_body 
                    FROM logs 
                    WHERE feedback_log_body LIKE '%headers=%' 
                      AND feedback_log_body LIKE '%x-codex-primary-used-percent%'
                    ORDER BY ts DESC 
                    LIMIT 1
                    """
                )
                r = cur.fetchone()
                if r and (not best_row or r[0] > best_row[0]):
                    best_row = r
                conn.close()
            except Exception:
                pass

        p_used = "0%"
        p_reset = "Ready"
        s_used = "0%"
        s_reset = "Full"

        if best_row:
            m = re.search(r"headers=(\{.*?\}) version=", best_row[1])
            if m:
                try:
                    hdrs = json.loads(m.group(1))
                    raw_p = int(hdrs.get("x-codex-primary-used-percent", "0"))
                    raw_s = int(hdrs.get("x-codex-secondary-used-percent", "0"))
                    p_reset_at = int(hdrs.get("x-codex-primary-reset-at", "0"))
                    s_reset_at = int(hdrs.get("x-codex-secondary-reset-at", "0"))

                    if p_reset_at > 0 and now < p_reset_at:
                        p_used = f"{raw_p}%"
                        rem_m = max(1, (p_reset_at - now) // 60)
                        p_reset = f"in {rem_m}m"
                    else:
                        p_used = "0%"
                        p_reset = "Ready"

                    if s_reset_at > 0 and now < s_reset_at:
                        s_used = f"{raw_s}%"
                        rem_h = max(1, (s_reset_at - now) // 3600)
                        s_reset = f"in {rem_h}h"
                    else:
                        s_used = "0%"
                        s_reset = "Full"
                except Exception:
                    pass

        results.append(
            {
                "email": email,
                "token_health": token_health,
                "pid": pid,
                "workspaces": ws_list,
                "quota_5h_used": p_used,
                "quota_5h_reset": p_reset,
                "quota_weekly_used": s_used,
                "quota_weekly_reset": s_reset,
            }
        )

    return results


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--pool-status-json":
        import json
        print(json.dumps(get_full_pool_status()))
        sys.exit(0)

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


