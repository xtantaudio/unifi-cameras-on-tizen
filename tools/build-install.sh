#!/usr/bin/env bash
# Package (sign with the 'camtv' profile), install, and launch the app on your TV.
# Assumes the signing profile already exists (run sign-and-install.sh once first).
#
# Usage: ./build-install.sh <TV_IP>
set -euo pipefail

TV_IP="${1:-}"
[ -z "$TV_IP" ] && { echo "usage: $0 <TV_IP>"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TIZEN_HOME="${TIZEN_HOME:-$HOME/tizen-studio}"
PROFILE="${PROFILE:-camtv}"
CERT_PW="${CERT_PW:-camtvpass}"
APPID="camgrid001.CameraGrid"
export PATH="$TIZEN_HOME/tools/ide/bin:$TIZEN_HOME/tools:$PATH"

command -v expect >/dev/null || { echo "'expect' is required (brew install expect / apt install expect)."; exit 1; }

cd "$REPO/app"

# config.js is gitignored (it holds YOUR host), so a fresh clone won't have it. Fail here
# with instructions rather than packaging an app that installs fine and then sits on
# "Set your restreamer host…" with no clue why.
if [ ! -f js/config.js ]; then
  echo "ERROR: app/js/config.js is missing (it's gitignored — every clone must create it)."
  echo "  cp app/js/config.example.js app/js/config.js"
  echo "  then edit it and set host to your restreamer, e.g. http://192.168.1.50:8099"
  exit 1
fi
if grep -q 'CHANGE_ME' js/config.js; then
  echo "ERROR: app/js/config.js still contains CHANGE_ME — set it to your restreamer's host first."
  exit 1
fi

rm -f *.wgt

# The Tizen CLI prompts for the profile password on stdin; drive it with expect.
# Pass profile/password via env (mixing argv with a stdin heredoc makes expect treat
# the first arg as a script filename).
export CAMTV_PROFILE="$PROFILE" CAMTV_PW="$CERT_PW"
expect << 'EXP'
set profile $env(CAMTV_PROFILE)
set pw $env(CAMTV_PW)
set timeout 90
spawn tizen package -t wgt -s $profile -- .
expect {
  -re "(A|a)uthor password:" { send "$pw\r"; exp_continue }
  -re "(S|s)ave author.*\\?" { send "no\r"; exp_continue }
  -re "(D|d)istributor.? password:" { send "$pw\r"; exp_continue }
  -re "(S|s)ave distributor.*\\?" { send "no\r"; exp_continue }
  "Package File Location" {}
  eof
}
expect eof
EXP

WGT_ORIG="$(ls -t "$REPO"/app/*.wgt | head -1)"
WGT="$REPO/app/app.wgt"
mv -f "$WGT_ORIG" "$WGT"   # tizen names the .wgt after the app name; a space breaks install
echo "== Installing $(basename "$WGT") to $TV_IP =="

# Time-box each step. A wedged sdb server makes `tizen install` hang indefinitely
# rather than fail, so without this the script can sit for hours with no output.
# run <seconds> <label> <cmd...>
run() {
  local secs="$1" label="$2"; shift 2
  echo "-- $label"
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
    sleep 2; waited=$((waited + 2))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "   TIMEOUT after ${secs}s — killed"
    return 124
  fi
  wait "$pid"
}

# A stale sdb server is the most common cause of a hung install: `sdb devices` still
# lists the TV, but every transfer blocks forever. Restarting it first is cheap.
run 30 "reset sdb server" sdb kill-server || true
run 60 "connect $TV_IP" sdb connect "$TV_IP:26101" || true
# NOTE: no `-t <ip:port>` here. That flag takes a device NAME, not host:port — passing
# an address makes every call fail with "There is no ... target", which `|| true` then
# swallows, so the uninstall silently never happens. With one device attached the
# default target is correct.
run 60 "uninstall $APPID (ok if not installed)" tizen uninstall -p "$APPID" || true
run 180 "install $(basename "$WGT")" tizen install -n "$(basename "$WGT")" -- "$REPO/app"
run 60 "launch $APPID" tizen run -p "$APPID" || true
echo "== Done. If the TV rejects it: certificate expired or Developer Mode / Host PC IP not set. =="
