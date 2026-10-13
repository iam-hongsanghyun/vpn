# VPN Gate for Mac

Mac(Apple Silicon) 앱. [VPN Gate](https://www.vpngate.net/) 공개 서버 목록을 표로 보여 주고, 행을 더블클릭하면 그 서버에 연결합니다.

## 실행

Finder에서 `vpn.command` 를 더블클릭합니다. 처음 한 번은 OpenVPN 설치(`brew install openvpn`)와 앱 빌드가 자동으로 진행되고, 이후에는 바로 앱이 열립니다. 만들어진 `build/VPN Gate.app` 을 응용 프로그램 폴더로 옮겨 써도 됩니다.

## 사용

- 행 더블클릭 → 연결 (연결할 때마다 macOS 관리자 암호를 묻습니다)
- 위쪽 상태 줄: 연결 단계, 터널 IP, 공인 IP, `연결 끊기`
- 툴바: 국가 필터, 검색, 목록 새로고침. 열 머리글을 누르면 정렬됩니다.
- 앱을 종료하면 VPN도 끊깁니다.

## 동작 방식

SoftEther 공식 macOS 클라이언트는 TAP 커널 확장이 필요해서 Apple Silicon에서 쓰기 어렵습니다([SoftEtherVPN#1097](https://github.com/SoftEtherVPN/SoftEtherVPN/issues/1097)). VPN Gate 서버(SoftEther)는 OpenVPN 프로토콜도 열어 두므로, 이 앱은 목록 API(`https://www.vpngate.net/api/iphone/`)가 주는 OpenVPN 설정으로 Homebrew `openvpn` 을 실행합니다. OpenVPN은 macOS 내장 `utun` 을 쓰고, 서버가 보내는 기본 경로와 DNS를 적용합니다.

- 앱 → openvpn: 관리자 권한으로 한 번 실행(`osascript … with administrator privileges`)
- 상태 확인·연결 끊기: 127.0.0.1:7505 관리 인터페이스(연결마다 새 비밀번호)
- 파일: `~/Library/Application Support/VPNGateMac/` (`openvpn.log` 에 연결 로그)

VPN Gate는 쓰쿠바대의 학술 실험 서비스입니다. 서버 운영자는 접속 기록을 남깁니다.

## 소스

`Sources/` 의 Swift 파일 5개, `build.sh` 가 `swiftc` 로 `.app` 을 만듭니다(Xcode 불필요, Command Line Tools만 필요).
