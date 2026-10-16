#!/usr/bin/env python3
"""Print the Codex weekly-balance band: `<band> <used_pct> <time_left_pct>`.

Codex writes a `rate_limits` block into every session rollout. The newest
reading of the `codex` pool's weekly (10080-minute) window says how much is used
and when it resets. Other pools (per-model limits such as `codex_other`) and
other windows (5-hour) are ignored, and a reading older than MAX_AGE_H counts as
no reading, because usage from elsewhere only makes an old reading look better. The band is the
balance left minus the time left, in points:

  high     >= +20 pts ahead of pace
  pace     within 20 pts
  low      >= 20 pts behind, or under 15% of the balance left
  unknown  no reading found (callers treat it like pace)

Usage: codex-budget.py <sessions-dir>   (CODEX_BUDGET_NOW overrides the clock, for tests)
"""
import calendar
import json
import os
import sys
import time

AHEAD_PTS = 20
FLOOR_LEFT_PCT = 15
SCAN_DAYS = 8
SCAN_FILES = 5
WEEK_MINUTES = 10080
MAX_AGE_H = 12


def newest_rollouts(root, now):
    files = []
    for days_back in range(SCAN_DAYS + 1):
        day = time.strftime("%Y/%m/%d", time.localtime(now - days_back * 86400))
        d = os.path.join(root, day)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if n.startswith("rollout-") and n.endswith(".jsonl"):
                p = os.path.join(d, n)
                try:
                    files.append((os.path.getmtime(p), p))
                except OSError:
                    pass
    files.sort(reverse=True)
    return [p for _, p in files[:SCAN_FILES]]


def weekly_window(rl):
    if rl.get("limit_id") not in (None, "codex"):
        return None
    for key in ("primary", "secondary"):
        w = rl.get(key)
        if isinstance(w, dict) and w.get("window_minutes") == WEEK_MINUTES:
            return w
    return None


def parse_ts(value):
    try:
        return calendar.timegm(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S"))  # rollout timestamps are UTC
    except (TypeError, ValueError):
        return None


def last_reading(path):
    found = None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"rate_limits"' not in line:
                    continue
                try:
                    d = json.loads(line)
                    w = weekly_window(d["payload"]["rate_limits"])
                except (ValueError, KeyError, TypeError, AttributeError):
                    continue
                if w:
                    found = (w, parse_ts(d.get("timestamp")))
    except OSError:
        return None
    return found


def band(primary, now):
    try:
        used = float(primary["used_percent"])
        window_s = float(primary["window_minutes"]) * 60
        resets_at = float(primary["resets_at"])
    except (KeyError, TypeError, ValueError):
        return None  # a malformed reading is no reading; older files may still hold one
    if window_s <= 0:
        return None
    if resets_at <= now:  # the window rolled over since this reading
        return "pace", 0.0, 100.0
    time_left = max(0.0, min(100.0, (resets_at - now) / window_s * 100))
    left = 100 - used
    margin = left - time_left
    if left < FLOOR_LEFT_PCT or margin <= -AHEAD_PTS:
        name = "low"
    elif margin >= AHEAD_PTS:
        name = "high"
    else:
        name = "pace"
    return name, used, time_left


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.codex/sessions")
    now = float(os.environ.get("CODEX_BUDGET_NOW") or time.time())
    for path in newest_rollouts(root, now):
        reading = last_reading(path)
        if reading:
            primary, taken_at = reading
            if taken_at is not None and now - taken_at > MAX_AGE_H * 3600:
                break  # the newest reading is too old to trust; older files are older still
            result = band(primary, now)
            if result:
                name, used, time_left = result
                print(f"{name} {used:.0f} {time_left:.0f}")
                return
    print("unknown - -")


if __name__ == "__main__":
    main()
