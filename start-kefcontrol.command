#!/bin/bash
# Launch KEF Control from a shell. On this macOS 27 beta Mac the Local Network
# grant is keyed to the binary's LC_UUID, and rebuilding the app costs it that
# grant — an icon launch then leaves the speaker "unreachable". Starting from a
# Terminal passes the process through the gate. build.sh pins the UUID too, so
# a rebuild can't make things worse than this.
pkill -f "KEF Control.app/Contents/MacOS" 2>/dev/null
sleep 2
nohup "$HOME/Applications/KEF Control.app/Contents/MacOS/KEFMenuBar" >/tmp/kefcontrol.out 2>&1 & disown
sleep 10
if lsof -nP -a -p "$(pgrep -f 'KEF Control.app/Contents/MacOS')" -iTCP 2>/dev/null | grep -q 192.168.1.69; then
  echo "✅ KEF Control verbonden met de speaker."
else
  echo "⚠️ Speaker nog niet verbonden — probeer nogmaals."
fi
sleep 2

# Sluit dit Terminal-venster zelf. De app is met nohup + disown losgekoppeld,
# dus die blijft gewoon draaien.
TTY=$(tty)
osascript >/dev/null 2>&1 <<APPLESCRIPT &
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$TTY" then close w saving no
    end repeat
  end repeat
end tell
APPLESCRIPT
