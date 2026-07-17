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
sdb connect "$TV_IP:26101" >/dev/null 2>&1 || true
tizen uninstall -p "$APPID" -t "$TV_IP:26101" >/dev/null 2>&1 || true
tizen install -n "$(basename "$WGT")" -- "$REPO/app" 2>&1 | tail -6
tizen run -p "$APPID" 2>&1 | tail -1 || true
echo "== Done. If the TV rejects it: certificate expired or Developer Mode / Host PC IP not set. =="
