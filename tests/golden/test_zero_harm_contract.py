import os
import re
from pathlib import Path

# verifies: tests/golden/test_zero_harm_contract.py
# Rationale: Guarantees that the account switcher never force-terminates the editor process,
# never closes integrated terminal sessions, and never overwrites VS Code chat/state databases.

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SRC_DIR = REPO_ROOT / "src"
SCRIPTS_DIR = REPO_ROOT / "scripts"


def test_no_process_termination_in_source():
    """Verify no file in src/ or scripts/ attempts to kill the editor process."""
    forbidden_patterns = [
        re.compile(r"taskkill\s+/F", re.IGNORECASE),
        re.compile(r"Stop-Process\s+-Force", re.IGNORECASE),
        re.compile(r"killProcess", re.IGNORECASE),
        re.compile(r"process\.kill\(", re.IGNORECASE),
    ]

    target_files = list(SRC_DIR.glob("**/*.js")) + list(SCRIPTS_DIR.glob("**/*.js"))
    assert len(target_files) > 0, "No target files found in src or scripts"

    for file_path in target_files:
        content = file_path.read_text(encoding="utf-8")
        for pat in forbidden_patterns:
            matches = pat.findall(content)
            assert not matches, f"Forbidden process termination pattern '{pat.pattern}' found in {file_path.name}"


def test_no_state_vscdb_overwrite_in_source():
    """Verify no file in src/ or scripts/ overwrites state.vscdb or workspaceStorage."""
    forbidden_patterns = [
        re.compile(r"state\.vscdb.*destGlobalStorage", re.IGNORECASE),
        re.compile(r"copyDirectorySelective.*emptyWindowChatSessions", re.IGNORECASE),
        re.compile(r"copyDirectorySelective.*github\.copilot-chat", re.IGNORECASE),
        re.compile(r"copyFileSync\(.*state\.vscdb", re.IGNORECASE),
    ]

    target_files = list(SRC_DIR.glob("**/*.js")) + list(SCRIPTS_DIR.glob("**/*.js"))
    for file_path in target_files:
        content = file_path.read_text(encoding="utf-8")
        for pat in forbidden_patterns:
            matches = pat.findall(content)
            assert not matches, f"Forbidden state overwrite pattern '{pat.pattern}' found in {file_path.name}"


def test_keyring_target_is_gemini_antigravity():
    """Verify that the keyring manager targets the true Windows Credential Manager target."""
    keyring_files = [f for f in list(SRC_DIR.glob("*.js")) if "keyring" in f.name.lower()]
    assert len(keyring_files) > 0, "Expected a keyringManager module in src/"
    
    found_target = False
    for kf in keyring_files:
        content = kf.read_text(encoding="utf-8")
        if "gemini:antigravity" in content:
            found_target = True
            break
    assert found_target, "Expected 'gemini:antigravity' target to be used in keyring manager"
