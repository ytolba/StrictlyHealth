#!/usr/bin/env python3
"""Install or remove Youra's private Oura-to-Photon background bridge on macOS."""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path


LABEL = "com.youra.morning-brief"
HOME = Path.home()
AGENT = HOME / "Library/LaunchAgents" / f"{LABEL}.plist"
SCRIPT = Path(__file__).with_name("server.py").resolve()


def launchctl(*args):
    return subprocess.run(["/bin/launchctl", *args], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true", help="stop and remove the local LaunchAgent")
    args = parser.parse_args()
    domain = f"gui/{os.getuid()}"
    if args.uninstall:
        if AGENT.exists():
            with AGENT.open("rb") as f:
                existing = plistlib.load(f)
            if existing.get("Label") != LABEL:
                raise SystemExit("The LaunchAgent path is owned by another service; left it unchanged.")
            launchctl("bootout", domain, str(AGENT))
            AGENT.unlink()
        print("Youra morning-brief service removed. The Hermes gateway and Tailscale routes were not changed.")
        return

    profile = HOME / ".hermes/profiles/youra"
    env_file = profile / ".env"
    if not SCRIPT.is_file() or not env_file.is_file():
        raise SystemExit("Youra Hermes profile is missing. Keep the feature off until Hermes is configured.")
    if not any(line.startswith("API_SERVER_KEY=") for line in env_file.read_text().splitlines()):
        raise SystemExit("Youra profile has no API_SERVER_KEY. No service was installed.")
    send = shutil.which("hermes")
    if not send:
        raise SystemExit("The Hermes command is not available in PATH. No service was installed.")
    if AGENT.exists():
        try:
            with AGENT.open("rb") as f:
                existing = plistlib.load(f)
        except (OSError, plistlib.InvalidFileException):
            raise SystemExit("An unreadable LaunchAgent already exists at the Youra bridge path; left it unchanged.")
        if existing.get("Label") != LABEL:
            raise SystemExit("The LaunchAgent path is owned by another service; left it unchanged.")

    logs = HOME / "Library/Logs/Youra"
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(logs, 0o700)
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    path = os.pathsep.join([str(Path(send).parent), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    config = {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, str(SCRIPT)],
        "WorkingDirectory": str(SCRIPT.parent),
        "EnvironmentVariables": {
            "PATH": path,
            "YOURA_HERMES_PROFILE": str(profile),
            "YOURA_HERMES_API": "http://127.0.0.1:8642/p/youra/v1",
            "YOURA_HERMES_MODEL": "youra",
            "YOURA_BRIEF_PORT": "8643",
            "YOURA_BRIEF_STATE": str(HOME / "Library/Application Support/Youra/MorningBrief"),
            "HERMES_SEND": str(send),
        },
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "StandardOutPath": str(logs / "morning-brief.log"),
        "StandardErrorPath": str(logs / "morning-brief-error.log"),
    }
    temporary = AGENT.with_suffix(".tmp")
    with temporary.open("wb") as f:
        plistlib.dump(config, f, sort_keys=False)
    os.chmod(temporary, 0o600)
    temporary.replace(AGENT)
    os.chmod(AGENT, 0o600)
    launchctl("bootout", domain, str(AGENT))
    result = launchctl("bootstrap", domain, str(AGENT))
    if result.returncode != 0:
        AGENT.unlink(missing_ok=True)
        raise SystemExit("LaunchAgent could not start. No files containing sleep data were created.")
    print("Youra morning-brief bridge is installed for this Mac user. It listens on 127.0.0.1:8643.")


if __name__ == "__main__":
    main()
