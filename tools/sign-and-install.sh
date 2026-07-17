#!/usr/bin/env bash
# Generate a Samsung TV certificate (headless), sign the app, and install it to your TV.
#
# This does the whole thing the (often-broken) Certificate Manager GUI would do, via
# Samsung's cert API. Run tools/capture-token.py FIRST to get token.json.
#
# Usage:
#   ./sign-and-install.sh <TV_IP>
# Env overrides (optional):
#   TIZEN_HOME=~/tizen-studio   PROFILE=camtv   CERT_PW=<password for the generated .p12s>
set -euo pipefail

TV_IP="${1:-}"
[ -z "$TV_IP" ] && { echo "usage: $0 <TV_IP>   (Developer Mode must be on, Host PC IP = this machine)"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TIZEN_HOME="${TIZEN_HOME:-$HOME/tizen-studio}"
PROFILE="${PROFILE:-camtv}"
CERT_PW="${CERT_PW:-camtvpass}"
CERTS="$HERE/certs"
export PATH="$TIZEN_HOME/tools/ide/bin:$TIZEN_HOME/tools:$PATH"
API="https://svdca.samsungqbe.com/apis/v3"
# real OpenSSL 3 (needs -legacy for pkcs12); macOS system LibreSSL lacks it
OPENSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"

command -v tizen >/dev/null || { echo "Tizen CLI not found. Install Tizen Studio CLI and set TIZEN_HOME."; exit 1; }
command -v sdb   >/dev/null || { echo "sdb not found (part of Tizen Studio)."; exit 1; }
[ -f "$HERE/token.json" ] || { echo "Missing token.json — run: python3 tools/capture-token.py"; exit 1; }

ACCESS_TOKEN="$(python3 -c "import json;print(json.load(open('$HERE/token.json'))['access_token'])")"
USER_ID="$(python3 -c "import json;print(json.load(open('$HERE/token.json'))['user_id'])")"

echo "== Connect to TV and read its DUID =="
sdb connect "$TV_IP:26101" >/dev/null 2>&1 || true
DUID="$(sdb -s "$TV_IP:26101" shell 0 getduid 2>/dev/null | tr -d '\r' | tail -1)"
[ -n "$DUID" ] || { echo "Could not read DUID. Is Developer Mode on and Host PC IP set to this machine?"; exit 1; }
echo "   DUID: $DUID"

echo "== Extract Samsung VD CA certs from the Tizen SDK =="
mkdir -p "$CERTS"; cd "$CERTS"
JAR="$(find "$TIZEN_HOME" -name 'org.tizen.common.cert_*.jar' 2>/dev/null | head -1)"
[ -n "$JAR" ] || { echo "Samsung cert plugin not found. Install the 'Samsung Certificate Extension' (cert-add-on)."; exit 1; }
unzip -o -j "$JAR" "res/ca/vd_tizen_dev_author_ca.cer" "res/ca/vd_tizen_dev_public2.crt" >/dev/null

echo "== Author certificate (Samsung API) =="
"$OPENSSL" genrsa -out author.key.pem 2048 2>/dev/null
"$OPENSSL" req -new -key author.key.pem -out author.csr -subj "/CN=$USER_ID" 2>/dev/null
curl -s -X POST "$API/authors" -F access_token="$ACCESS_TOKEN" -F user_id="$USER_ID" \
     -F platform=VD -F csr=@author.csr --output author.crt
grep -q "BEGIN\|-----" author.crt || { echo "Author API error:"; cat author.crt; exit 2; }
cat author.crt vd_tizen_dev_author_ca.cer > author-and-ca.crt
"$OPENSSL" pkcs12 -export -out author.p12 -inkey author.key.pem -in author-and-ca.crt \
     -name usercertificate -passout pass:"$CERT_PW" -legacy 2>/dev/null

echo "== Distributor certificate (locked to DUID $DUID) =="
"$OPENSSL" genrsa -out distributor.key.pem 2048 2>/dev/null
"$OPENSSL" req -new -key distributor.key.pem -out distributor.csr -subj "/CN=TizenSDK" \
     -addext "subjectAltName=URI:URN:tizen:packageid=,URI:URN:tizen:deviceid=$DUID" 2>/dev/null
curl -s -X POST "$API/distributors" -F access_token="$ACCESS_TOKEN" -F user_id="$USER_ID" \
     -F platform=VD -F privilege_level=Public -F developer_type=Individual \
     -F csr=@distributor.csr --output distributor.crt
grep -q "BEGIN\|-----" distributor.crt || { echo "Distributor API error:"; cat distributor.crt; exit 3; }
cat distributor.crt vd_tizen_dev_public2.crt > distributor-and-ca.crt
"$OPENSSL" pkcs12 -export -out distributor.p12 -inkey distributor.key.pem -in distributor-and-ca.crt \
     -name usercertificate -passout pass:"$CERT_PW" -legacy 2>/dev/null

echo "== Register signing profile '$PROFILE' =="
tizen security-profiles add -n "$PROFILE" -a "$CERTS/author.p12" -p "$CERT_PW" \
     -d "$CERTS/distributor.p12" -dp "$CERT_PW" >/dev/null
tizen cli-config "profiles.path=$TIZEN_HOME-data/profile/profiles.xml" >/dev/null 2>&1 || true

echo "== Build, sign, install =="
exec "$HERE/build-install.sh" "$TV_IP"
