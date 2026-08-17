#!/usr/bin/env python3
"""
kef_set_volume.py — set a KEF LS60's volume and KEEP it there until it sticks.

Why the loop: on wake / source-switch the speaker fires its OWN volume command
(restores last, then jumps to the per-source default). A single setVolume can
land *before* that jump and get clobbered. So we assert the target, then require
N consecutive reads that already show the target on their own (we only re-assert
when we observe drift). That way we win regardless of when the firmware's jump
lands — no need to know its timing.

player:volume is writable on plain HTTP :80, so no HMAC channel is needed.

  python3 kef_set_volume.py --ip 192.168.1.69 --volume 48
  python3 kef_set_volume.py --ip 192.168.1.69 -v 48 --stable 3 --interval 0.4 --timeout 20

Exit 0 when it holds, 1 on timeout — so it drops straight into a webhook/script.
"""

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request

PATH = "player:volume"


def get_volume(ip):
    """Current volume as int, or None if unreachable/unparseable (e.g. asleep)."""
    q = urllib.parse.urlencode({"path": PATH, "roles": "@all"})
    try:
        with urllib.request.urlopen(f"http://{ip}/api/getData?{q}", timeout=3) as r:
            doc = json.load(r)
    except Exception:
        return None
    v = doc.get("value") if isinstance(doc, dict) else None
    return v.get("i32_") if isinstance(v, dict) else None


def set_volume(ip, n):
    """Assert the volume (best-effort; ignored silently while asleep)."""
    body = json.dumps({
        "path": PATH, "roles": "value",
        "value": {"type": "i32_", "i32_": n},
    }).encode()
    req = urllib.request.Request(f"http://{ip}/api/setData", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=3):
            pass
    except Exception:
        pass


def hold_volume(ip, target, stable=3, interval=0.4, timeout=20.0, verbose=True):
    """Return True once `target` holds for `stable` consecutive reads on its own."""
    deadline = time.monotonic() + timeout
    confirmed = 0
    while time.monotonic() < deadline:
        cur = get_volume(ip)
        if cur == target:
            confirmed += 1
            if verbose:
                print(f"  {cur}  ✓ {confirmed}/{stable}")
            if confirmed >= stable:
                return True
        else:
            confirmed = 0
            set_volume(ip, target)          # (re)assert only when it has drifted
            if verbose:
                print(f"  {cur} → set {target}")
        time.sleep(interval)
    return False


def main():
    ap = argparse.ArgumentParser(description="Set a KEF volume and hold it until it sticks.")
    ap.add_argument("--ip", required=True, help="LS60 IP or hostname")
    ap.add_argument("--volume", "-v", type=int, required=True, help="target volume")
    ap.add_argument("--stable", type=int, default=3, help="consecutive on-target reads to declare success")
    ap.add_argument("--interval", type=float, default=0.4, help="seconds between reads")
    ap.add_argument("--timeout", type=float, default=20.0, help="give up after this many seconds")
    ap.add_argument("--quiet", action="store_true", help="no per-read logging")
    args = ap.parse_args()

    ok = hold_volume(args.ip, args.volume, args.stable, args.interval,
                     args.timeout, verbose=not args.quiet)
    if ok:
        print(f"✅ held at {args.volume}")
        sys.exit(0)
    print(f"⚠️  gave up after {args.timeout:.0f}s — last read {get_volume(args.ip)}")
    sys.exit(1)


if __name__ == "__main__":
    main()
