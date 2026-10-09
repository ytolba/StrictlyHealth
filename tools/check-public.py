#!/usr/bin/env python3
"""Conservative source-bundle guardrail. Never prints matched secret contents."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
bad = []
for path in root.rglob("*"):
    if path.is_symlink():
        bad.append((path, "symlink"))
        continue
    if not path.is_file():
        continue
    relative = path.relative_to(root)
    if (any(part in {"target", ".git", "local", "captures", "exports", "xcuserdata"} for part in relative.parts)
            or "Signing.local" in path.name
            or path.suffix.lower() in {".db", ".sqlite", ".hex", ".key", ".p12", ".cer", ".mobileprovision", ".log", ".zip"}
            or path.name in {"oura-history.json", "profile.json", "feature_modes.json"}):
        bad.append((path, "private/build artifact"))
        continue
    if path.suffix.lower() in {".swift", ".toml", ".yml", ".xcconfig", ".md", ".sh", ".py", ".plist", ".json", ".c", ".h"}:
        text = path.read_text(errors="replace")
        # Identity checks do not catch every kind of secret. The manifest is the main boundary.
        if relative.as_posix() != "tools/check-public.py" and re.search(r"/Users/[^/\s]+/|DEVELOPMENT_TEAM\s*[=:]\s*[A-Z0-9]{10}\b", text):
            bad.append((path, "machine identity"))
        if re.search(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", text):
            bad.append((path, "private key"))
        if re.search(r"(?:pairing_key|key_hex)\s*[:=]\s*[\"'][0-9a-f]{32}[\"']", text, re.I):
            bad.append((path, "possible ring key"))
if bad:
    for path, reason in bad:
        print(f"BLOCK: {path.relative_to(root)} ({reason})")
    sys.exit(1)
print("Public bundle guardrail passed. Review content and licenses before publishing.")
