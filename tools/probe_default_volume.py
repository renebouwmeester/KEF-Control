#!/usr/bin/env python3
"""
probe_default_volume.py — read (and optionally write) the KEF LS60 per-source
wake-up volumes at settings:/kef/host/defaultVolume/<source>.

Hypothesis: the "increments of 5" is a KEF Connect *app* constraint, not an API
one (the API runs on volumeStep=1, maximumVolume=59). So a direct write of 48
via the HMAC channel should stick — giving custom, per-source wake volumes.

HMAC signing is ported verbatim from KEFAuthChannel in Sources/Core/KEFAPI.swift.
Reads go over plain HTTP :80; the write goes over the TLS :4430 HMAC channel.

Usage:
  Read-only (safe, does nothing but look):
    python3 tools/probe_default_volume.py --ip 192.168.1.XX

  Test-write TV=48 and read it back:
    python3 tools/probe_default_volume.py --ip 192.168.1.XX --source TV --set 48

Nothing is written unless you pass --set.
"""

import argparse
import base64
import hashlib
import hmac
import json
import secrets
import ssl
import time
import urllib.parse
import urllib.request

SOURCES = ["TV", "Wifi", "Optical", "Coaxial", "USB", "Analogue", "Bluetooth", "Global"]
BASE = "settings:/kef/host/defaultVolume"

USERNAME = "7f3c2a91-4d0b-4f65-9b3a-8e2f1c6d4a13"
PASSWORD = hashlib.md5(f"yek_{USERNAME}_user".encode()).hexdigest()

_TLS = ssl.create_default_context()
_TLS.check_hostname = False
_TLS.verify_mode = ssl.CERT_NONE


# ── plain HTTP :80 reads ────────────────────────────────────────────────────

def get_data(ip, path):
    """GET /api/getData → the `value` dict, or None."""
    q = urllib.parse.urlencode({"path": path, "roles": "@all"})
    url = f"http://{ip}/api/getData?{q}"
    try:
        with urllib.request.urlopen(url, timeout=4) as r:
            doc = json.load(r)
    except Exception as e:
        return {"__error__": str(e)}
    if isinstance(doc, dict) and isinstance(doc.get("value"), dict):
        return doc["value"]
    return doc if isinstance(doc, dict) else {"__raw__": doc}


def get_rows(ip, path):
    """GET /api/getRows → list of child rows (to discover the tree shape)."""
    q = urllib.parse.urlencode({"path": path, "roles": "@all", "from": 0, "to": 60})
    url = f"http://{ip}/api/getRows?{q}"
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            doc = json.load(r)
    except Exception as e:
        return {"__error__": str(e)}
    return doc


# ── HMAC-signed TLS :4430 write (ported from KEFAuthChannel) ────────────────

def _auth_header(full_url, body):
    nonce = base64.b64encode(secrets.token_bytes(6)).decode()      # b64 of 6 rand bytes
    nonce_b64 = base64.b64encode(nonce.encode()).decode()          # b64 of that string
    user_b64 = base64.b64encode(USERNAME.encode()).decode()
    ts = str(int(time.time() * 1000))
    key = hashlib.sha256(nonce.encode() + PASSWORD.encode()).digest()
    # canonical = username.nonceB64.timestamp.fullURL.<raw body bytes>
    message = f"{USERNAME}.{nonce_b64}.{ts}.{full_url}.".encode() + body
    sig = base64.b64encode(hmac.new(key, message, hashlib.sha256).digest()).decode()
    return f"HMAC_SHA256 {user_b64}.{nonce_b64}.{ts}.{sig}"


def _post_4430(ip, path, body, signed):
    url = f"https://{ip}:4430{path}"
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    if signed:
        req.add_header("Authorization", _auth_header(url, body))
    try:
        with urllib.request.urlopen(req, timeout=5, context=_TLS) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _provision(ip):
    """Register our user (unsigned, idempotent — 500/'exists' is fine)."""
    body = json.dumps({
        "path": "webserver:addUser", "role": "activate",
        "value": {"name": USERNAME, "password": PASSWORD, "title": ""},
    }).encode()
    _post_4430(ip, "/api/setData", body, signed=False)


def set_data_signed(ip, path, value, roles="value"):
    body = json.dumps({"path": path, "roles": roles, "value": value}).encode()
    status, resp = _post_4430(ip, "/api/setData", body, signed=True)
    if status == 401:                      # not provisioned yet → register, retry
        _provision(ip)
        status, resp = _post_4430(ip, "/api/setData", body, signed=True)
    return status, resp


# ── helpers ─────────────────────────────────────────────────────────────────

def num_field(value):
    """Find the numeric field in a KEF value dict, e.g. {'type':'i16_','i16_':50}."""
    for k, v in value.items():
        if k != "type" and isinstance(v, (int, float)):
            return k
    return None


def leaf(src):
    """The per-source wake-volume node, e.g. settings:/kef/host/defaultVolumeTV."""
    return f"{BASE}{src}"


def main():
    ap = argparse.ArgumentParser(description="Probe KEF per-source wake volumes.")
    ap.add_argument("--ip", required=True, help="LS60 IP or hostname")
    ap.add_argument("--source", default="TV", choices=SOURCES, help="source to write")
    ap.add_argument("--set", type=int, default=None, metavar="N",
                    help="write this value to <source> (omit = read-only)")
    ap.add_argument("--gates", choices=["on", "off"], default=None,
                    help="flip standbyDefaultVol + advancedStandbyDefaultVol (the wake-jump gates)")
    args = ap.parse_args()

    print(f"KEF @ {args.ip}\n")

    # Per-source wake volumes live at settings:/kef/host/defaultVolume<Source>
    # (concatenated, not a container). Each is a simple {"type":"i32_","i32_":N}.
    print("Per-source wake volumes:")
    for src in SOURCES:
        print(f"  {src:<10} {json.dumps(get_data(args.ip, leaf(src)))}")
    # The two gates that decide whether the speaker actually uses these on wake.
    for g in ("standbyDefaultVol", "advancedStandbyDefaultVol"):
        print(f"  [{g}] {json.dumps(get_data(args.ip, f'settings:/kef/host/{g}'))}")
    print()

    # Optionally flip the two wake-jump gates (bool_ nodes, HMAC-written).
    if args.gates is not None:
        want = args.gates == "on"
        print(f"Setting gates → {args.gates}:")
        for g in ("standbyDefaultVol", "advancedStandbyDefaultVol"):
            p = f"settings:/kef/host/{g}"
            status, _ = set_data_signed(args.ip, p, {"type": "bool_", "bool_": want})
            print(f"  {g} → {json.dumps(get_data(args.ip, p))} (HTTP {status})")
        print()

    if args.set is None:
        if args.gates is None:
            print("Read-only. To test a write:")
            print(f"  python3 {__file__.split('/')[-1]} --ip {args.ip} --source TV --set 48")
        return

    # Write test: read the leaf, keep its i32_ type, swap the number, write via the
    # HMAC channel, read back.
    path = leaf(args.source)
    cur = get_data(args.ip, path)
    field = num_field(cur) if isinstance(cur, dict) else None
    if not field:
        print(f"Could not read {args.source} cleanly: {json.dumps(cur)}")
        return
    new_value = dict(cur)
    new_value[field] = args.set
    print(f"Writing {args.source} = {args.set}  (was {cur[field]}) at {path}")
    status, resp = set_data_signed(args.ip, path, new_value)
    print(f"  HMAC setData → HTTP {status}  {resp[:160].decode(errors='replace')}")

    back = get_data(args.ip, path)
    got = back.get(field) if isinstance(back, dict) else None
    print(f"  read back → {json.dumps(back)}")
    if got == args.set:
        print(f"\n✅ Stuck at {args.set}. The ×5 is app-only — custom per-source wake volumes work.")
        print("   Next: standby the speaker, wake it on this source, confirm it comes up here.")
    else:
        print(f"\n⚠️  Read back {got}, not {args.set} — the firmware rounded/rejected it.")
        print("   Try a multiple of 5 to confirm the write path works, then narrow down.")


if __name__ == "__main__":
    main()
