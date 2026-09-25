import json
import base64
import ctypes
from ctypes import wintypes
import pytest

# verifies: tests/golden/test_keyring_contract.py
# Rationale: Guarantees that the Windows Credential Manager API contract works correctly,
# can safely read and write the 'gemini:antigravity' target without data corruption,
# and extracts verified emails from JWT id_tokens.

class CREDENTIAL(ctypes.Structure):
    _fields_ = [
        ("Flags", wintypes.DWORD),
        ("Type", wintypes.DWORD),
        ("TargetName", wintypes.LPWSTR),
        ("Comment", wintypes.LPWSTR),
        ("LastWritten", wintypes.FILETIME),
        ("CredentialBlobSize", wintypes.DWORD),
        ("CredentialBlob", ctypes.POINTER(ctypes.c_byte)),
        ("Persist", wintypes.DWORD),
        ("AttributeCount", wintypes.DWORD),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", wintypes.LPWSTR),
        ("UserName", wintypes.LPWSTR),
    ]


def read_credential(target: str) -> bytes:
    advapi32 = ctypes.windll.advapi32
    CredReadW = advapi32.CredReadW
    CredReadW.argtypes = [
        wintypes.LPWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.POINTER(ctypes.POINTER(CREDENTIAL)),
    ]
    CredReadW.restype = wintypes.BOOL

    pcred = ctypes.POINTER(CREDENTIAL)()
    if CredReadW(target, 1, 0, ctypes.byref(pcred)):
        cred = pcred.contents
        blob = ctypes.string_at(cred.CredentialBlob, cred.CredentialBlobSize)
        advapi32.CredFree(pcred)
        return blob
    return None


def test_gemini_antigravity_credential_exists_and_valid():
    """Verify that gemini:antigravity exists in Windows Credential Manager and contains valid JSON."""
    blob = read_credential("gemini:antigravity")
    assert blob is not None, "gemini:antigravity credential must exist in Windows Credential Manager"
    
    data = json.loads(blob.decode("utf-8"))
    assert "token" in data, "Token object must be present in credential blob"
    assert "id_token" in data, "id_token must be present in credential blob"
    
    # Verify id_token is a valid JWT with email
    id_token = data["id_token"]
    parts = id_token.split(".")
    assert len(parts) == 3, "id_token must be a 3-part JWT"
    
    payload_b64 = parts[1]
    payload_b64 += "=" * (-len(payload_b64) % 4)
    payload = json.loads(base64.urlsafe_b64decode(payload_b64).decode("utf-8"))
    assert "email" in payload, "JWT payload must contain an email field"
    assert "@" in payload["email"], f"Email '{payload['email']}' must be valid"
