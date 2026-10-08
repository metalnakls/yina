#!/usr/bin/env python3
"""Validate, stage, and optionally publish YINA's managed defaults JSON."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
CONFIG = REPO / "yina" / "ManagedDefaults.json"
PLIST = REPO / "yina" / "DefaultPreferences.plist"
MAX_BYTES = 64 * 1024
def run(*args: str, **kwargs: object) -> str:
    result = subprocess.run(
        args, cwd=REPO, check=True, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, **kwargs
    )
    return result.stdout.strip()


def allowed_minute(value: dt.datetime) -> bool:
    minute, hour = value.minute, value.hour
    return minute % 2 == 0 and minute not in (30, 50) and (minute != 0 or hour % 2 == 0 or hour == 1)


def commit_time() -> dt.datetime:
    while not allowed_minute(dt.datetime.now().astimezone()):
        time.sleep(5)
    value = dt.datetime.now().astimezone().replace(second=0, microsecond=0)
    while not allowed_minute(value):
        value -= dt.timedelta(minutes=1)
    return value


def validate(path: Path) -> bytes:
    raw = path.read_bytes()
    if len(raw) > MAX_BYTES:
        raise ValueError("The defaults file is larger than 64 KiB.")
    payload = json.loads(raw)
    if not isinstance(payload, dict) or set(payload) != {"schemaVersion", "defaults"}:
        raise ValueError("Expected only schemaVersion and defaults at the top level.")
    if type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 1:
        raise ValueError("Unsupported defaults schema version.")
    values = payload["defaults"]
    if not isinstance(values, dict) or not values:
        raise ValueError("The defaults object is empty or invalid.")

    plist_values = plistlib.loads(PLIST.read_bytes())
    template = json.loads(CONFIG.read_text()) if CONFIG.exists() else None
    if template is not None:
        if (not isinstance(template, dict) or set(template) != {"schemaVersion", "defaults"}
                or type(template["schemaVersion"]) is not int or template["schemaVersion"] != 1):
            raise ValueError("The checked-in defaults template is invalid.")
        if not isinstance(template["defaults"], dict) or not template["defaults"]:
            raise ValueError("The checked-in defaults list is empty or invalid.")
        allowed = set(template["defaults"])
        if not allowed.issubset(plist_values):
            raise ValueError("The checked-in defaults contain a key missing from DefaultPreferences.plist.")
    else:
        raise ValueError("The checked-in defaults template is missing.")

    if set(values) != allowed:
        missing = sorted(allowed - set(values))
        extra = sorted(set(values) - allowed)
        details = []
        if missing:
            details.append("missing: " + ", ".join(missing))
        if extra:
            details.append("unexpected: " + ", ".join(extra))
        raise ValueError("The defaults keys do not match the checked-in managed list (" + "; ".join(details) + ").")

    for key, value in values.items():
        expected = plist_values[key]
        if isinstance(expected, bool):
            valid = type(value) is bool
        elif isinstance(expected, int):
            valid = type(value) is int and abs(value) <= 1_000_000_000
        elif isinstance(expected, float):
            valid = type(value) in (int, float) and math.isfinite(value) and abs(value) <= 1_000_000_000
        elif isinstance(expected, str):
            valid = isinstance(value, str) and len(value.encode("utf-8")) <= 2_048 and not any(ord(c) < 32 for c in value)
        else:
            valid = False
        if not valid:
            raise ValueError(f"Unsupported value for managed setting {key}.")

    normalized = {"schemaVersion": 1, "defaults": dict(sorted(values.items()))}
    return (json.dumps(normalized, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def publish() -> None:
    branch = run("git", "branch", "--show-current")
    if branch != "meh":
        raise ValueError("Defaults can only be published from the meh branch.")

    run("git", "fetch", "yina", "meh")
    head = run("git", "rev-parse", "HEAD")
    remote_head = run("git", "rev-parse", "yina/meh")
    if head != remote_head:
        raise ValueError("Local meh must match yina/meh before publishing defaults.")

    changed = run("git", "diff", "--name-only", "--", "yina/ManagedDefaults.json")
    staged = run("git", "diff", "--cached", "--name-only", "--", "yina/ManagedDefaults.json")
    if not changed and not staged:
        raise ValueError("The managed defaults file has no changes to publish.")

    when = commit_time().strftime("%Y-%m-%dT%H:%M:%S%z")
    env = os.environ.copy()
    env.update({"GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when})
    run("git", "-c", "user.useConfigOnly=true", "commit", "--only", "-m", "defaults", "--", "yina/ManagedDefaults.json", env=env)
    run("git", "push", "yina", "HEAD:refs/heads/meh")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", nargs="?", type=Path, help="JSON exported by the debug settings tuner")
    parser.add_argument("--publish", action="store_true", help="commit and push the validated defaults file to yina/meh")
    args = parser.parse_args()

    source = args.export or CONFIG
    normalized = validate(source)
    if source.resolve() != CONFIG.resolve():
        CONFIG.write_bytes(normalized)
    elif CONFIG.read_bytes() != normalized:
        CONFIG.write_bytes(normalized)

    if args.publish:
        publish()
        print("Published managed defaults to yina/meh.")
    else:
        print(f"Validated {CONFIG.relative_to(REPO)}. Review it, then rerun with --publish to push the defaults update.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"publish_defaults: {error}", file=sys.stderr)
        raise SystemExit(1)
