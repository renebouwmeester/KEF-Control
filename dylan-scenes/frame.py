#!/usr/bin/python3
# NB: pinned to Apple's /usr/bin/python3 (3.9) — that's where samsungtvws lives.
# Homebrew's python3 (3.14) does NOT have it.
"""Direct local control of The Frame over the Samsung WebSocket API — no pyatv/CEC.

The FIRST WebSocket command pops an "Allow" dialog on the TV. Approve it with the
Samsung remote; the token is saved to ~/Documents/Scripts/.frame-token and reused
silently afterwards.

  frame.py info        REST device info (no token, no popup)
  frame.py state       PowerState + Art Mode
  frame.py on          ensure the TV shows its input (power on if it's in Art Mode)
  frame.py off         ensure the TV is off (Art Mode, per the TV's power-off setting)
  frame.py power       raw KEY_POWER toggle
  frame.py art on|off  raw set_artmode  (NB: `art on` while already in Art Mode can hang)

`on`/`off` press the native power button (KEY_POWER) gated on the current Art-Mode
state, so "off" follows whatever the TV is configured to do on power-off — we never
force Art Mode. Only get_artmode() is read (fast); set_artmode() is avoided (hangs).
"""
import json
import os
import sys

from samsungtvws import SamsungTVWS

IP = "192.168.1.204"
TOKEN = os.path.expanduser("~/Documents/Scripts/.frame-token")


def tv():
    return SamsungTVWS(host=IP, port=8002, token_file=TOKEN, name="Dylan (webhook)", timeout=15)


def in_art_mode(t):
    return str(t.art().get_artmode()).lower() in ("true", "on")


cmd = sys.argv[1] if len(sys.argv) > 1 else "info"

if cmd == "info":
    print(json.dumps(tv().rest_device_info().get("device", {}), indent=2))

elif cmd == "state":
    d = tv().rest_device_info().get("device", {})
    print("PowerState:", d.get("PowerState"))
    try:
        print("ArtMode:", tv().art().get_artmode())
    except Exception as e:
        print("ArtMode query failed:", e)

elif cmd == "on":
    t = tv()
    if in_art_mode(t):
        t.send_key("KEY_POWER")
        print("power: on (was Art Mode)")
    else:
        print("power: already on")

elif cmd == "off":
    t = tv()
    if not in_art_mode(t):
        t.send_key("KEY_POWER")
        print("power: off -> Art Mode")
    else:
        print("power: already off (Art Mode)")

elif cmd == "power":
    tv().send_key("KEY_POWER")
    print("KEY_POWER sent")

elif cmd == "key":
    key = sys.argv[2]
    tv().send_key(key)
    print("sent", key)

elif cmd == "art":
    on = len(sys.argv) > 2 and sys.argv[2] == "on"
    tv().art().set_artmode(on)
    print("Art Mode", "ON" if on else "OFF")

else:
    print("usage: frame.py [info | state | on | off | power | art on | art off]")
