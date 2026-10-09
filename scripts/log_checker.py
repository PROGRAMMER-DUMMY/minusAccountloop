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


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(0)

    db = sys.argv[1]
    ts = int(sys.argv[2])
    outcomes = check_logs(db, ts)
    for outcome in outcomes:
        print(outcome)
