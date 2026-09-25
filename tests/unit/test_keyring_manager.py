import json
import base64
import subprocess
from pathlib import Path

# verifies: tests/unit/test_keyring_manager.py
# Rationale: Developer unit tests validating JWT decoding, profile discovery, and Windows Keyring integration.

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def test_decode_jwt_in_node():
    """Test that decodeJwt correctly decodes a JWT payload in node."""
    payload = {"email": "developer@example.com", "exp": 1790000000}
    payload_json = json.dumps(payload)
    b64_payload = base64.urlsafe_b64encode(payload_json.encode("utf-8")).decode("utf-8").rstrip("=")
    fake_jwt = f"header.{b64_payload}.signature"

    node_script = f"""
    const km = require('./src/keyringManager');
    const res = km.decodeJwt('{fake_jwt}');
    if (!res || res.email !== 'developer@example.com') {{
        process.exit(1);
    }}
    console.log('OK');
    """

    res = subprocess.run(["node", "-e", node_script], cwd=REPO_ROOT, capture_output=True, text=True)
    assert res.returncode == 0
    assert "OK" in res.stdout


def test_discover_accounts_in_node():
    """Test that discoverAccounts discovers the active account and profile list."""
    node_script = """
    const tp = require('./src/tokenPool');
    const accounts = tp.discoverAccounts();
    if (!accounts || !Array.isArray(accounts.allAccounts)) {
        process.exit(1);
    }
    console.log(JSON.stringify(accounts));
    """

    res = subprocess.run(["node", "-e", node_script], cwd=REPO_ROOT, capture_output=True, text=True)
    assert res.returncode == 0
    data = json.loads(res.stdout.strip())
    assert "active" in data
    assert len(data["allAccounts"]) > 0


def test_rate_limit_detection_no_false_positives():
    """Test that containsRateLimitError ignores timestamps, ports, and thread IDs with '429', but catches real quota exhaustion."""
    node_script = """
    const { containsRateLimitError } = require('./src/tokenPool');

    // False positive cases (should NOT trigger)
    const falsePositives = [
        'I0923 15:48:00.804708 26 server.go:3429] [RemoteControl] Resolved proxyServerURL: ""',
        'I0923 15:48:13.429505 361 model_config_manager.go:327] Propagating selected model override',
        'I0923 15:49:56.137539 1429 http_helpers.go:305] URL: https://daily-cloudcode-pa.googleapis.com',
        'checking storage capacity for buffer size 4290 bytes',
        'request completed normally in 429ms'
    ];

    for (const fp of falsePositives) {
        if (containsRateLimitError(fp)) {
            console.error('False positive detected on:', fp);
            process.exit(1);
        }
    }

    // True positive cases (MUST trigger)
    const truePositives = [
        'Run: attempt 1 failed (RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 2h54m28s.)',
        'Post "https://daily-cloudcode-pa.googleapis.com": RESOURCE_EXHAUSTED',
        'error: { code: 429, message: "Resource has been exhausted" }',
        'error: status: 429, quota exceeded for project',
        'individual quota reached. Please upgrade your subscription.'
    ];

    for (const tp of truePositives) {
        if (!containsRateLimitError(tp)) {
            console.error('Failed to detect genuine rate limit on:', tp);
            process.exit(2);
        }
    }

    console.log('OK');
    """

    res = subprocess.run(["node", "-e", node_script], cwd=REPO_ROOT, capture_output=True, text=True)
    assert res.returncode == 0, f"Error: {res.stderr}"
    assert "OK" in res.stdout

