#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

WHAM_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Read the latest Codex rate limit snapshot from the local logs database."
    )
    parser.add_argument(
        "--codex-root",
        default=str(Path.home() / ".codex"),
        help="Path to the local Codex state directory. Default: ~/.codex",
    )
    return parser


def iso_local(epoch_seconds: int | None) -> str | None:
    if epoch_seconds is None:
        return None
    return (
        datetime.fromtimestamp(epoch_seconds, tz=timezone.utc)
        .astimezone()
        .isoformat(timespec="seconds")
    )


def normalize_percent(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return max(0, min(100, int(round(float(value)))))
    except (TypeError, ValueError):
        return None


def normalize_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def serialize_window(name: str, raw: dict[str, Any] | None, now_ts: int) -> dict[str, Any]:
    raw = raw or {}
    used_percent = normalize_percent(raw.get("used_percent"))
    reset_at = normalize_int(raw.get("reset_at"))
    reset_after_seconds = normalize_int(raw.get("reset_after_seconds"))

    if reset_at is None and reset_after_seconds is not None:
        reset_at = now_ts + max(0, reset_after_seconds)

    window_minutes = normalize_int(raw.get("window_minutes"))
    if window_minutes is None:
        limit_window_seconds = normalize_int(raw.get("limit_window_seconds"))
        if limit_window_seconds is not None:
            window_minutes = max(1, limit_window_seconds // 60)

    reset_in_seconds = None
    if reset_at is not None:
        reset_in_seconds = max(0, reset_at - now_ts)
        if now_ts >= reset_at:
            used_percent = 0

    remaining_percent = None if used_percent is None else max(0, 100 - used_percent)

    return {
        "name": name,
        "windowMinutes": window_minutes,
        "usedPercent": used_percent,
        "remainingPercent": remaining_percent,
        "resetAt": reset_at,
        "resetAtLocal": iso_local(reset_at),
        "resetInSeconds": reset_in_seconds,
    }


def extract_payload(message: str) -> dict[str, Any]:
    prefix = "websocket event: "
    if message.startswith(prefix):
        message = message[len(prefix) :]
    payload = json.loads(message)
    if payload.get("type") != "codex.rate_limits":
        raise ValueError("Latest matching log row was not a codex.rate_limits event.")
    return payload


def get_access_token(codex_root: Path) -> tuple[Path, str]:
    auth_path = codex_root / "auth.json"
    if not auth_path.exists():
        raise RuntimeError(f"Auth file not found: {auth_path}")

    try:
        auth_payload = json.loads(auth_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError(f"Failed to parse auth file: {auth_path}") from exc

    access_token = ((auth_payload.get("tokens") or {}).get("access_token") or "").strip()
    if not access_token:
        raise RuntimeError(f"Access token not found in auth file: {auth_path}")

    return auth_path, access_token


def query_wham_usage(codex_root: Path) -> dict[str, Any]:
    auth_path, access_token = get_access_token(codex_root)
    request = Request(
        WHAM_USAGE_URL,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Accept": "application/json",
            "User-Agent": "CodexTokenTaskbar/1.0",
        },
    )

    try:
        with urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace").strip()
        message = f"HTTP {exc.code} while calling {WHAM_USAGE_URL}"
        if detail:
            message = f"{message}: {detail}"
        raise RuntimeError(message) from exc
    except URLError as exc:
        raise RuntimeError(f"Failed to reach {WHAM_USAGE_URL}: {exc.reason}") from exc

    rate_limit = payload.get("rate_limit") or {}
    if not rate_limit:
        raise RuntimeError(f"Missing rate_limit payload from {WHAM_USAGE_URL}")

    now_ts = int(datetime.now(tz=timezone.utc).timestamp())

    return {
        "ok": True,
        "source": "backend-api/wham/usage",
        "authPath": str(auth_path),
        "planType": payload.get("plan_type"),
        "allowed": bool(rate_limit.get("allowed", True)),
        "limitReached": bool(rate_limit.get("limit_reached", False)),
        "observedAt": now_ts,
        "observedAtLocal": iso_local(now_ts),
        "ageSeconds": 0,
        "fiveHour": serialize_window("fiveHour", rate_limit.get("primary_window"), now_ts),
        "weekly": serialize_window("weekly", rate_limit.get("secondary_window"), now_ts),
    }


def query_latest_snapshot(db_path: Path) -> dict[str, Any]:
    query = """
        SELECT ts, message
        FROM logs
        WHERE target = 'codex_api::endpoint::responses_websocket'
          AND message LIKE 'websocket event: {"type":"codex.rate_limits"%'
        ORDER BY ts DESC
        LIMIT 1
    """

    connection = sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True, timeout=2)
    try:
        row = connection.execute(query).fetchone()
    finally:
        connection.close()

    if row is None:
        raise RuntimeError("No codex.rate_limits event was found in the local logs database.")

    observed_ts = int(row[0])
    payload = extract_payload(row[1])
    rate_limits = payload.get("rate_limits") or {}
    now_ts = int(datetime.now(tz=timezone.utc).timestamp())

    return {
        "ok": True,
        "source": "logs_1.sqlite",
        "dbPath": str(db_path),
        "planType": payload.get("plan_type"),
        "allowed": bool(rate_limits.get("allowed", True)),
        "limitReached": bool(rate_limits.get("limit_reached", False)),
        "observedAt": observed_ts,
        "observedAtLocal": iso_local(observed_ts),
        "ageSeconds": max(0, now_ts - observed_ts),
        "fiveHour": serialize_window("fiveHour", rate_limits.get("primary"), now_ts),
        "weekly": serialize_window("weekly", rate_limits.get("secondary"), now_ts),
    }


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    codex_root = Path(args.codex_root).expanduser()
    db_path = codex_root / "logs_1.sqlite"

    errors: list[str] = []

    try:
        snapshot = query_wham_usage(codex_root)
    except Exception as exc:  # pragma: no cover - defensive fallback for local runtime use
        errors.append(f"Official usage request failed: {exc}")
    else:
        print(json.dumps(snapshot, ensure_ascii=True))
        return 0

    try:
        snapshot = query_latest_snapshot(db_path)
    except Exception as exc:  # pragma: no cover - defensive fallback for local runtime use
        errors.append(f"Local log fallback failed: {exc}")
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": " | ".join(errors),
                    "dbPath": str(db_path),
                }
            )
        )
        return 0

    print(json.dumps(snapshot, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
