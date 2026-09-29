#!/bin/bash
# usage: run.sh <name> <native|mpv> [adskip on|off]
# Relaunches the app fresh for one measured run: no watch history (so the episode starts at 0),
# the chosen default engine, 智慧去廣 on or off; then starts the recording and log stream.
# The episode is tapped by hand afterwards; `wait.sh <name>` (or `record.sh <name> stop`) ends it.
# It points the app at server.py's config: back up the app's Library first and restore it after.
U=${SIM_UDID:-E0A41D48-2210-46B8-B18C-9432B77DECC4}
HERE="$(cd "$(dirname "$0")" && pwd)"
xcrun simctl terminate $U com.webhtv.ios.poc 2>/dev/null
D=$(xcrun simctl get_app_container $U com.webhtv.ios.poc data)
P="$D/Library/Preferences/com.webhtv.ios.poc.plist"
rm -f "$D/Library/Application Support/WatchHistory/history.json"
if [ "${3:-on}" = off ]; then v=false; else v=true; fi
KEY=webhtv.playback.hlsAdSkip
DW="xcrun simctl spawn $U defaults write ${P%.plist}"
$DW configSourceURL -string http://127.0.0.1:8765/config.json
$DW webhtv.playback.defaultEngine -string "$2"
$DW "$KEY" -bool $v
xcrun simctl spawn $U defaults read "${P%.plist}" | grep -E "defaultEngine|hlsAdSkip"
bash "$HERE/record.sh" "$1" start
n0=$(wc -l < "$HERE/server.log")
xcrun simctl launch $U com.webhtv.ios.poc >/dev/null
echo "launched $1 engine=$2 adskip=${3:-on} ($KEY)"
# Wait for the home page to ask the test site for its list.
for _ in $(seq 60); do [ "$(grep -c "GET /api" <(tail -n +$((n0+1)) "$HERE/server.log"))" -ge 1 ] && break; sleep 0.25; done; sleep 1.5
