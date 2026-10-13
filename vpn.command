#!/bin/bash
# Double-click in Finder: installs OpenVPN if missing, (re)builds "VPN Gate.app"
# when the sources changed, then opens it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/VPN Gate.app"
BIN="$APP/Contents/MacOS/VPNGate"

fail() {
  echo
  echo "오류: $1"
  read -r -p "엔터를 누르면 창이 닫힙니다…" _
  exit 1
}

if [[ ! -x /opt/homebrew/sbin/openvpn && ! -x /usr/local/sbin/openvpn ]]; then
  BREW=$(command -v brew || echo /opt/homebrew/bin/brew)
  [[ -x "$BREW" ]] || fail "Homebrew가 없습니다. https://brew.sh 에서 설치한 뒤 다시 실행하세요."
  echo "OpenVPN 설치 중 (brew install openvpn)…"
  "$BREW" install openvpn || fail "OpenVPN 설치에 실패했습니다."
fi

if [[ ! -x "$BIN" || -n "$(find Sources build.sh -newer "$BIN" 2>/dev/null)" ]]; then
  command -v swiftc >/dev/null || fail "Swift 컴파일러가 없습니다. 터미널에서 'xcode-select --install' 을 실행하세요."
  echo "앱 빌드 중…"
  ./build.sh || fail "빌드에 실패했습니다."
fi

open "$APP"
echo "VPN Gate 앱을 열었습니다. 이 창은 닫아도 됩니다."
