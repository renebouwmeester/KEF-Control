#!/usr/bin/env bash
# Baton scene: Cinema OFF — runs on Dylan via the `webhook` tool (/hooks/cinema-off).
#   1. kef.sh off → KEF to standby.
#   2. atvremote turn_off → sleep the Apple TV; ATV→TV CEC pulls the Frame to its
#      power-off state (Art Mode). No Samsung command needed.
set -uo pipefail
S="/Users/rene/Documents/Scripts"
ATVREMOTE="$HOME/Library/Python/3.9/bin/atvremote"
ATV="--scan-hosts 192.168.1.84 --id D41F3135-5489-44B5-8FEB-8ABE67109DFB"

"$S/kef.sh" off || echo "[cinema-off] warn: kef standby failed"

echo "[cinema-off] sleep Apple TV (Frame → Art Mode via CEC)"
"$ATVREMOTE" $ATV turn_off || echo "[cinema-off] warn: atv turn_off failed"
echo "[cinema-off] done"
