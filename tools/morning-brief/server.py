#!/usr/bin/env python3
"""Private bridge: accept verified Oura sleep summaries and deliver one iMessage."""

from __future__ import annotations

import hmac
import json
import os
import secrets
import subprocess
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import RLock


HOME = Path.home()
PROFILE = Path(os.environ.get("YOURA_HERMES_PROFILE", HOME / ".hermes/profiles/youra"))
API_ENV = PROFILE / ".env"
API_BASE = os.environ.get("YOURA_HERMES_API", "http://127.0.0.1:8642/p/youra/v1")
MODEL = os.environ.get("YOURA_HERMES_MODEL", "youra")
STATE_DIR = Path(os.environ.get("YOURA_BRIEF_STATE", HOME / "Library/Application Support/Youra/MorningBrief"))
STATE_FILE = STATE_DIR / "queue.json"
STATE_LOCK = RLock()
PORT = int(os.environ.get("YOURA_BRIEF_PORT", "8643"))
ROUTE = "/youra-morning-brief/v1/schedule"
SEND_COMMAND = os.environ.get("HERMES_SEND", str(HOME / ".local/bin/hermes"))

SYSTEM_PROMPT = (
    "Write one short, kind morning iMessage for the user using only the supplied verified Oura sleep facts. "
    "Do not invent data, infer causes, diagnose, or provide medical advice. Mention unavailable fields as unavailable, "
    "not as zero. Keep it under 450 characters, plain text, no markdown, no greeting that assumes a name. "
    "The app—not you—calculated the values. Do not mention Apple Health."
)


def api_key() -> str:
    try:
        for line in API_ENV.read_text().splitlines():
            if line.startswith("API_SERVER_KEY="):
                return line.split("=", 1)[1].strip().strip("\"'")
    except OSError:
        pass
    return ""


def parse_time(value: object) -> datetime:
    if not isinstance(value, str) or len(value) > 40:
        raise ValueError("timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timezone")
    return result.astimezone(timezone.utc)


def validate(payload: object, received_at: datetime) -> dict:
    if not isinstance(payload, dict) or payload.get("source") != "direct-oura-bluetooth":
        raise ValueError("source")
    if payload.get("valid") is not True:
        raise ValueError("incomplete night")
    date = payload.get("nightDate")
    if not isinstance(date, str) or len(date) != 10:
        raise ValueError("night date")
    try:
        datetime.strptime(date, "%Y-%m-%d")
    except ValueError as exc:
        raise ValueError("night date") from exc
    wake = parse_time(payload.get("wakeAt"))
    onset = parse_time(payload.get("onsetAt"))
    if onset >= wake or wake - onset > timedelta(hours=24):
        raise ValueError("sleep times")
    if wake.timestamp() + 600 <= received_at.timestamp():
        raise ValueError("Oura sync arrived after the delivery time")
    due = wake.timestamp() + 600
    # The user asked for the message ten minutes after the ring-recorded wake.
    # Do not send stale summaries when sync reaches the Mac after that moment.
    values = payload.get("values")
    if not isinstance(values, dict):
        raise ValueError("values")
    permitted = {
        "totalSleepMinutes": (0, 1440), "timeInBedMinutes": (0, 1440),
        "efficiencyPercent": (0, 100), "latencyMinutes": (0, 1440),
        "deepMinutes": (0, 1440), "remMinutes": (0, 1440),
        "lightMinutes": (0, 1440), "awakeMinutes": (0, 1440),
        "awakenings": (0, 200),
    }
    clean = {}
    for key, (minimum, maximum) in permitted.items():
        value = values.get(key)
        if value is None:
            clean[key] = None
            continue
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not minimum <= value <= maximum:
            raise ValueError("metric")
        clean[key] = int(round(value))
    if clean["totalSleepMinutes"] is None or clean["totalSleepMinutes"] <= 0:
        raise ValueError("sleep duration")
    if clean["timeInBedMinutes"] is not None and clean["timeInBedMinutes"] < clean["totalSleepMinutes"]:
        raise ValueError("sleep duration")
    return {"nightDate": date, "onsetAt": onset.isoformat(), "wakeAt": wake.isoformat(), "deliverAt": due, "values": clean}


def read_state() -> dict:
    with STATE_LOCK:
        try:
            value = json.loads(STATE_FILE.read_text())
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}


def write_state(value: dict) -> None:
    with STATE_LOCK:
        STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(STATE_DIR, 0o700)
        temporary = STATE_FILE.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, separators=(",", ":")))
        os.chmod(temporary, 0o600)
        temporary.replace(STATE_FILE)
        os.chmod(STATE_FILE, 0o600)


def generate_message(summary: dict) -> str:
    body = json.dumps(summary, separators=(",", ":")).encode()
    request = urllib.request.Request(
        API_BASE.rstrip("/") + "/chat/completions",
        data=json.dumps({
            "model": MODEL,
            "stream": False,
            "max_tokens": 180,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": body.decode()},
            ],
        }).encode(),
        headers={"Authorization": "Bearer " + api_key(), "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        data = json.loads(response.read(1_000_001))
    text = data["choices"][0]["message"]["content"].strip()
    if not isinstance(text, str) or not text or len(text) > 450:
        raise ValueError("model reply")
    return text


def factual_fallback(summary: dict) -> str:
    values = summary["values"]

    def duration(key: str) -> str | None:
        value = values.get(key)
        return f"{value // 60}h {value % 60:02d}m" if isinstance(value, int) else None

    def local_time(key: str) -> str | None:
        value = summary.get(key)
        if not value:
            return None
        return datetime.fromisoformat(value).astimezone().strftime("%-I:%M %p")

    facts = [f"Sleep {duration('totalSleepMinutes')}"]
    for key, label in (("timeInBedMinutes", "in bed"), ("efficiencyPercent", "efficiency"),
                       ("latencyMinutes", "to fall asleep"), ("deepMinutes", "deep"),
                       ("remMinutes", "REM"), ("lightMinutes", "light"),
                       ("awakeMinutes", "awake")):
        value = values.get(key)
        if value is None:
            continue
        facts.append(f"{label} {value}%" if key == "efficiencyPercent" else (f"{label} {value}m" if key == "latencyMinutes" else f"{label} {duration(key)}"))
    if values.get("awakenings") is not None:
        facts.append(f"{values['awakenings']} awakenings")
    onset, wake = local_time("onsetAt"), local_time("wakeAt")
    timing = f" · {onset}–{wake}" if onset and wake else ""
    return f"Youra sleep · {summary['nightDate']}\n" + " · ".join(facts) + timing


def send_pending() -> None:
    state = read_state()
    pending = state.get("pending")
    if not isinstance(pending, dict):
        return
    if pending.get("status") in ("generating", "working", "generation-failed"):
        if not pending.get("message"):
            return
    if datetime.now(timezone.utc).timestamp() < float(pending["deliverAt"]):
        return
    if datetime.now(timezone.utc).timestamp() > float(pending["deliverAt"]) + 90:
        state.pop("pending", None)
        state["lastSkipped"] = pending.get("nightDate")
        write_state(state)
        return
    if int(pending.get("attempts", 0)) >= 3 or datetime.now(timezone.utc).timestamp() < float(pending.get("retryAfter", 0)):
        return
    message = pending.get("message")
    if not isinstance(message, str) or not message:
        return
    # Persist a sending marker before invoking the external messaging service.
    # If the process is interrupted mid-send, don't risk sending a duplicate.
    pending["status"] = "sending"
    write_state(state)
    try:
        subprocess.run([SEND_COMMAND, "send", "--to", "photon", message], check=True, timeout=60,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except (OSError, subprocess.SubprocessError):
        # Keep the item for one controlled retry; a later valid ring sync replaces it.
        pending["status"] = "send-failed"
        pending["attempts"] = int(pending.get("attempts", 0)) + 1
        pending["retryAfter"] = datetime.now(timezone.utc).timestamp() + 60
        write_state(state)
        return
    state["lastDelivery"] = pending["nightDate"]
    state.pop("pending", None)
    write_state(state)


def generate_pending() -> None:
    state = read_state()
    pending = state.get("pending")
    if not isinstance(pending, dict) or pending.get("status") != "generating":
        return
    pending["status"] = "working"
    write_state(state)
    try:
        summary = {"source": "Direct Oura ring · Bluetooth", **pending["summary"]}
        try:
            message = generate_message(summary)
        except (OSError, ValueError, KeyError, urllib.error.URLError):
            message = factual_fallback(summary)
        state = read_state()
        pending = state.get("pending")
        if not isinstance(pending, dict) or pending.get("requestId") != state.get("generatingRequest"):
            return
        pending["message"] = message
        pending["status"] = "ready"
        state.pop("generatingRequest", None)
        write_state(state)
    except (OSError, ValueError, KeyError, urllib.error.URLError):
        state = read_state()
        pending = state.get("pending")
        if isinstance(pending, dict):
            pending["status"] = "generation-failed"
            state.pop("generatingRequest", None)
            write_state(state)


class Handler(BaseHTTPRequestHandler):
    server_version = "YouraBrief/1"

    def log_message(self, _format: str, *_args) -> None:
        # Avoid writing health values, authorization headers, phone numbers, or IPs to logs.
        return

    def send_json(self, code: int, value: dict) -> None:
        payload = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        if self.path in ("/health", "/youra-morning-brief/health"):
            self.send_json(200, {"status": "ok"})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path not in (ROUTE, "/v1/schedule"):
            self.send_json(404, {"error": "not found"})
            return
        expected = api_key()
        supplied = self.headers.get("Authorization", "")
        if not expected or not hmac.compare_digest(supplied, "Bearer " + expected):
            self.send_json(401, {"error": "unauthorized"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 12_000:
                raise ValueError("body")
            payload = json.loads(self.rfile.read(length))
            summary = validate(payload, datetime.now(timezone.utc))
            current = read_state()
            if current.get("lastDelivery") == summary["nightDate"]:
                self.send_json(200, {"state": "already-sent", "deliverAt": summary["deliverAt"]})
                return
            existing = current.get("pending")
            if isinstance(existing, dict) and existing.get("nightDate") == summary["nightDate"]:
                if existing.get("status") not in ("generation-failed",):
                    self.send_json(200, {"state": "scheduled", "deliverAt": existing["deliverAt"]})
                    return
            current["pending"] = {
                "nightDate": summary["nightDate"], "deliverAt": summary["deliverAt"],
                "summary": summary, "status": "generating", "attempts": 0,
                "requestId": secrets.token_hex(12),
            }
            current["generatingRequest"] = current["pending"]["requestId"]
            write_state(current)
            threading.Thread(target=generate_pending, daemon=True).start()
            self.send_json(202, {"state": "scheduled", "deliverAt": summary["deliverAt"]})
        except (ValueError, TypeError, KeyError, json.JSONDecodeError):
            self.send_json(422, {"error": "summary rejected"})


def main() -> None:
    if not api_key():
        raise SystemExit("Youra Hermes API key is unavailable; bridge will not start")
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STATE_DIR, 0o700)
    state = read_state()
    if isinstance(state.get("pending"), dict) and state["pending"].get("status") == "working":
        state["pending"]["status"] = "generating"
        write_state(state)
        threading.Thread(target=generate_pending, daemon=True).start()
    if isinstance(state.get("pending"), dict) and state["pending"].get("status") == "sending":
        # Delivery outcome is uncertain after a crash; drop it to preserve at-most-once behavior.
        state["lastSkipped"] = state["pending"].get("nightDate")
        state.pop("pending", None)
        write_state(state)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    threading.Thread(target=lambda: _scheduler(), daemon=True).start()
    server.serve_forever(poll_interval=0.5)


def _scheduler() -> None:
    while True:
        send_pending()
        time.sleep(5)


if __name__ == "__main__":
    main()
