#!/usr/bin/env bash
# Baton scene: Cinema ON — runs on Dylan via the `webhook` tool (/hooks/cinema-on).
#   1. atvremote turn_on wakes the Apple TV; ATV→TV CEC pulls the Frame on and
#      switches it to the ATV input. No Samsung/HDMI commands needed — the ATV
#      drives the TV both ways.
#   2. kef.sh source tv + kef_set_volume.py → KEF to TV, hold 48 through the jump.
set -uo pipefail
S="/Users/rene/Documents/Scripts"
PY="/usr/bin/python3"
ATVREMOTE="$HOME/Library/Python/3.9/bin/atvremote"
ATV="--scan-hosts 192.168.1.84 --id D41F3135-5489-44B5-8FEB-8ABE67109DFB"

echo "[cinema-on] wake Apple TV (drives the Frame via CEC)"
"$ATVREMOTE" $ATV turn_on || echo "[cinema-on] warn: atv turn_on failed"

echo "[cinema-on] KEF → tv, hold 48"
"$S/kef.sh" source tv || echo "[cinema-on] warn: kef source switch failed"
"$PY" "$S/kef_set_volume.py" --ip 192.168.1.69 -v 48 --quiet
echo "[cinema-on] done"
