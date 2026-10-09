"""Log checker for quota exhaustion (429) and auth revocation (401)."""

import os
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


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--check-token":
        print(check_auth_token(sys.argv[2]))
        sys.exit(0)

    if len(sys.argv) < 3:
        sys.exit(0)

    db = sys.argv[1]
    ts = int(sys.argv[2])
    outcomes = check_logs(db, ts)
    for outcome in outcomes:
        print(outcome)

