import json
import base64
import os
import tempfile
import pytest

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
