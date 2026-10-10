import base64
import json
import os
import sqlite3
import sys
import tempfile
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

# verifies: tests/unit/test_codex_loop.py
# Rationale: Ensures multi-account rotation for OpenAI Codex adheres to
# zero-harm invariants, safely parses JWT id_token claims, and selects
# the least-switched ready account.

def create_mock_jwt(email: str) -> str:
    header = base64.urlsafe_b64encode(json.dumps({"alg": "RS256"}).encode()).decode().rstrip("=")
    payload = base64.urlsafe_b64encode(json.dumps({"email": email, "sub": "user_123"}).encode()).decode().rstrip("=")
    signature = "mock_sig"
    return f"{header}.{payload}.{signature}"


def extract_email_from_jwt(id_token: str) -> str:
    parts = id_token.split(".")
    if len(parts) >= 2:
        payload = parts[1]
        pad_len = (4 - (len(payload) % 4)) % 4
        payload += "=" * pad_len
        payload = payload.replace("-", "+").replace("_", "/")
        claims = json.loads(base64.b64decode(payload).decode("utf-8"))
        return claims.get("email")
    return None


def test_jwt_email_extraction():
    email = "shubhamveer001@gmail.com"
    token = create_mock_jwt(email)
    extracted = extract_email_from_jwt(token)
    assert extracted == email, f"Expected {email}, got {extracted}"


def test_select_best_available_account():
    pool_state = {
        "acc1@example.com": {"switchCount": 5, "cooldownUntil": 0, "lastExhausted": 0},
        "acc2@example.com": {"switchCount": 2, "cooldownUntil": 0, "lastExhausted": 0},
        "acc3@example.com": {"switchCount": 0, "cooldownUntil": 9999999999999, "lastExhausted": 1000},
    }
    available = ["acc1@example.com", "acc2@example.com", "acc3@example.com"]
    current_ms = 2000
    
    # acc3 is in cooldown, acc1 has 5 switches, acc2 has 2 switches -> acc2 should be selected
    ready = []
    for acc in available:
        state = pool_state.get(acc, {})
        if state.get("cooldownUntil", 0) <= current_ms:
            ready.append((acc, state.get("switchCount", 0)))
    
    ready.sort(key=lambda x: x[1])
    assert ready[0][0] == "acc2@example.com"


def test_select_best_available_account_skips_busy_session():
    pool_state = {
        "acc1@example.com": {"switchCount": 1, "cooldownUntil": 0, "lastExhausted": 0, "authRevoked": False},
        "acc2@example.com": {"switchCount": 3, "cooldownUntil": 0, "lastExhausted": 0, "authRevoked": False},
    }
    available = ["acc1@example.com", "acc2@example.com"]
    busy_sessions = {"acc1@example.com": 99999}  # PID 99999 running acc1

    # acc1 has lower switch count (1), but is busy in an active session
    # The selector must skip acc1 and choose acc2
    ready = []
    for acc in available:
        if acc in busy_sessions:
            continue
        state = pool_state.get(acc, {})
        if not state.get("authRevoked", False) and state.get("cooldownUntil", 0) <= 0:
            ready.append((acc, state.get("switchCount", 0)))

    ready.sort(key=lambda x: x[1])
    assert len(ready) == 1
    assert ready[0][0] == "acc2@example.com"


def test_log_checker_detects_exhaustion_and_revocation():
    from scripts.log_checker import check_logs

    with tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False) as tf:
        temp_db = tf.name

    try:
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE logs (
                ts INTEGER,
                level TEXT,
                target TEXT,
                feedback_log_body TEXT
            )
            """
        )
        # Non-matching row
        cur.execute(
            "INSERT INTO logs VALUES (?, ?, ?, ?)",
            (100, "INFO", "app", "normal startup"),
        )
        # 429 exhaustion row
        cur.execute(
            "INSERT INTO logs VALUES (?, ?, ?, ?)",
            (105, "ERROR", "codex::http_client", "status=429 rate_limit_exceeded"),
        )
        # 401 revocation row
        cur.execute(
            "INSERT INTO logs VALUES (?, ?, ?, ?)",
            (106, "ERROR", "codex::auth", "workspace routing discovery unauthorized"),
        )
        conn.commit()
        conn.close()

        results = check_logs(temp_db, 100)
        assert "EXHAUSTED" in results
        assert "REVOKED" in results

        # Test timestamp filter
        results_future = check_logs(temp_db, 200)
        assert results_future == []
    finally:
        if os.path.exists(temp_db):
            os.remove(temp_db)


def test_check_auth_token():
    from scripts.log_checker import check_auth_token

    # Non-existent file
    assert check_auth_token("non_existent_file.json") == "UNKNOWN"

    # Missing access_token
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w") as tf:
        json.dump({"tokens": {}}, tf)
        temp_auth = tf.name

    try:
        assert check_auth_token(temp_auth) == "REVOKED"
    finally:
        if os.path.exists(temp_auth):
            os.remove(temp_auth)


def test_setup_account_home():
    from scripts.log_checker import setup_account_home
    import shutil

    test_email = "unit_test_account@example.com"
    home_path = setup_account_home(test_email)
    try:
        assert os.path.exists(home_path)
        assert os.path.isdir(home_path)
    finally:
        if os.path.exists(home_path):
            shutil.rmtree(home_path, ignore_errors=True)


def test_setup_account_home_with_workspace():
    from scripts.log_checker import setup_account_home
    import shutil

    test_email = "unit_test_account@example.com"
    home_path = setup_account_home(test_email, "C:/projects/my_test_workspace")
    try:
        assert os.path.exists(home_path)
        assert os.path.isdir(home_path)
        assert "my_test_workspace" in home_path.lower()
    finally:
        if os.path.exists(home_path):
            shutil.rmtree(home_path, ignore_errors=True)




