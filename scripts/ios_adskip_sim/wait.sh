#!/bin/bash
# usage: wait.sh <name> [seconds]: stop the run after its second ad skip, or after [seconds] (125) of recording.
HERE="$(cd "$(dirname "$0")" && pwd)"; L="$HERE/runs/$1.log"; t0=$(cat "$HERE/runs/$1.start")
lim=${2:-125}
while :; do
  grep -q "skip from=10[0-9][0-9][0-9][0-9]ms" "$L" && { sleep 3; break; }
  [ "$(python3 -c "import time; print(int(time.time()-$t0))")" -ge "$lim" ] && break
  sleep 1
done
bash "$HERE/record.sh" "$1" stop >/dev/null
sleep 1
python3 "$HERE/analyze.py" "$HERE/runs/$1.mp4" 0:971:1206:678 ${FPS:-25}
