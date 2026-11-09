#!/usr/bin/env bash
# 生成 dist/SHA256SUMS.txt 并用发布私钥签名 → dist/SHA256SUMS.txt.sig（Ed25519 原始 64 字节签名，Base64）。
# 用法：scripts/sign_release.sh 1.1.0
# 私钥：~/.config/notibridge/release-signing-ed25519.pem（只在发布者电脑上，务必备份；丢失后已安装的电脑端/安卓端无法再自动更新）。
# 公钥必须与 Mac/Windows/Android 更新器内置的 RELEASE_PUBLIC_KEY 一致，脚本最后会核对并验证签名。
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?用法：$0 <版本号，例如 1.1.0>}"
KEY="${NOTIBRIDGE_SIGNING_KEY:-$HOME/.config/notibridge/release-signing-ed25519.pem}"
PINNED="+wkZaT1HzXMHhcMF6xz67byo2x0iNeXMoL4PSO1ApQo="
OPENSSL="${OPENSSL:-$(command -v /opt/homebrew/bin/openssl || command -v openssl)}"

ASSETS=(
  "NotiBridge-$VER-macOS.dmg"
  "NotiBridge-$VER-Windows-x64.zip"
  "NotiBridge-$VER-HarmonyOS-unsigned.hap"
  "NotiBridge-$VER-Android.apk"
)
cd dist
for a in "${ASSETS[@]}"; do [[ -f "$a" ]] || { echo "缺少 dist/$a" >&2; exit 1; }; done
[[ -f "$KEY" ]] || { echo "找不到签名私钥 $KEY" >&2; exit 1; }

shasum -a 256 "${ASSETS[@]}" > SHA256SUMS.txt

# 核对私钥对应的公钥就是更新器内置的那一把
PUB=$("$OPENSSL" pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)
[[ "$PUB" == "$PINNED" ]] || { echo "私钥对应的公钥 $PUB 与内置公钥不一致" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"$OPENSSL" pkeyutl -sign -inkey "$KEY" -rawin -in SHA256SUMS.txt -out "$TMP/sig.bin"
[[ $(wc -c < "$TMP/sig.bin") -eq 64 ]] || { echo "签名长度不对" >&2; exit 1; }
base64 < "$TMP/sig.bin" | tr -d '\n' > SHA256SUMS.txt.sig
echo >> SHA256SUMS.txt.sig

# 用公钥独立验证一次
"$OPENSSL" pkey -in "$KEY" -pubout -out "$TMP/pub.pem"
base64 -D < SHA256SUMS.txt.sig > "$TMP/check.bin" 2>/dev/null || base64 -d < SHA256SUMS.txt.sig > "$TMP/check.bin"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in SHA256SUMS.txt -sigfile "$TMP/check.bin" >/dev/null
echo "已签名：dist/SHA256SUMS.txt.sig"
cat SHA256SUMS.txt
