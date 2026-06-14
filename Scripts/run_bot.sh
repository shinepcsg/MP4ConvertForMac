#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BIN="$ROOT_DIR/.build/release/MP4MattermostBot"
SELF_SIGNED_NAME="MP4Convertor Bot Local"

# 1) 릴리스 빌드 (swift run 은 매번 ad-hoc 재서명을 덮어쓰므로 build 후 직접 실행한다)
swift build -c release --product MP4MattermostBot

# 2) 고정 코드사인 식별자 결정
#    - MP4BOT_SIGN_IDENTITY 환경변수가 있으면 우선 사용
#    - 없으면 키체인의 코드사인 식별자를 해시로 선택 (이름 중복 시 모호성 방지)
#      장기 유효한 "Developer ID Application" 을 우선, 없으면 첫 번째 식별자 사용
#    - 그래도 없으면 로컬 전용 자체 서명 인증서를 1회 생성
resolve_identity() {
    if [[ -n "${MP4BOT_SIGN_IDENTITY:-}" ]]; then
        print -r -- "$MP4BOT_SIGN_IDENTITY"
        return 0
    fi

    local list
    list="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    # "Developer ID Application" 식별자의 해시 우선 사용 (만료가 길어 TCC 권한 유지에 유리)
    local devid_hash
    devid_hash="$(print -r -- "$list" | grep "Developer ID Application" | grep -oE '[0-9A-F]{40}' | head -n1)"
    if [[ -n "$devid_hash" ]]; then
        print -r -- "$devid_hash"
        return 0
    fi

    # 이미 만든 자체 서명 인증서가 있으면 재사용
    local self_hash
    self_hash="$(print -r -- "$list" | grep "$SELF_SIGNED_NAME" | grep -oE '[0-9A-F]{40}' | head -n1)"
    if [[ -n "$self_hash" ]]; then
        print -r -- "$self_hash"
        return 0
    fi

    # 그 외 첫 번째 코드사인 식별자 해시
    local first_hash
    first_hash="$(print -r -- "$list" | grep -oE '[0-9A-F]{40}' | head -n1)"
    if [[ -n "$first_hash" ]]; then
        print -r -- "$first_hash"
        return 0
    fi

    create_self_signed_identity >&2
    self_hash="$(security find-identity -v -p codesigning 2>/dev/null | grep "$SELF_SIGNED_NAME" | grep -oE '[0-9A-F]{40}' | head -n1)"
    print -r -- "${self_hash:-$SELF_SIGNED_NAME}"
}

create_self_signed_identity() {
    echo "코드사인 식별자가 없어 로컬 전용 자체 서명 인증서('$SELF_SIGNED_NAME')를 생성합니다..."
    local tmp keychain
    tmp="$(mktemp -d)"
    keychain="$HOME/Library/Keychains/login.keychain-db"

    openssl genrsa -out "$tmp/key.pem" 2048 >/dev/null 2>&1
    openssl req -x509 -new -key "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 \
        -subj "/CN=$SELF_SIGNED_NAME" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    openssl pkcs12 -export -out "$tmp/identity.p12" \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout pass: >/dev/null 2>&1

    # -A: codesign 등 모든 도구가 키체인 접근 시 추가 확인창 없이 사용하도록 허용 (로컬 개발 편의)
    security import "$tmp/identity.p12" -k "$keychain" -P "" -T /usr/bin/codesign -A >/dev/null 2>&1

    rm -rf "$tmp"
    echo "자체 서명 인증서 생성 완료."
}

IDENTITY="$(resolve_identity)"
echo "코드사인 식별자: $IDENTITY"

# 3) 고정 식별자/번들 ID로 서명 → TCC 권한이 재빌드/재실행 후에도 유지됨
codesign --force --identifier "kr.trollgames.MP4MattermostBot" --sign "$IDENTITY" "$BIN"

# 4) 서명된 바이너리 실행
exec "$BIN"
