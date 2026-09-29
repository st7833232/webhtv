#!/bin/bash
# usage: record.sh <name> start|stop
# start: begins the app log stream and the simulator screen recording for runs/<name>.
# stop:  ends both (SIGINT so the mp4 is finalised).
U=${SIM_UDID:-E0A41D48-2210-46B8-B18C-9432B77DECC4}
DIR="$(cd "$(dirname "$0")" && pwd)/runs"
mkdir -p "$DIR"
case "$2" in
start)
  xcrun simctl spawn $U log stream --style ndjson --level info \
    --predicate 'eventMessage CONTAINS "[adskip]" OR eventMessage CONTAINS "[playback]"' \
    > "$DIR/$1.log" 2>/dev/null &
  echo $! > "$DIR/$1.logpid"
  xcrun simctl io $U recordVideo --codec=h264 --force "$DIR/$1.mp4" > "$DIR/$1.rec" 2>&1 &
  echo $! > "$DIR/$1.recpid"
  # The recording's first frame is taken when it reports it has started.
  for _ in $(seq 100); do grep -q "Recording started" "$DIR/$1.rec" && break; sleep 0.05; done
  python3 -c 'import time; print(time.time())' > "$DIR/$1.start"
  echo "recording $1"
  ;;
stop)
  kill -INT "$(cat "$DIR/$1.recpid")" 2>/dev/null
  sleep 2
  kill "$(cat "$DIR/$1.logpid")" 2>/dev/null
  echo "stopped $1"
  ;;
esac
