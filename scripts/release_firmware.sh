#!/usr/bin/env bash
# 单独发布 ESP32 固件：编译 → dist/firmware-<版本>/ 里生成 NotiBridge-ESP32-<版本>.bin、SHA256SUMS.txt、.sig
# → 创建 GitHub Release firmware-v<版本>（不标记为 Latest，App 的自动更新只看 Latest）。
# 用法：scripts/release_firmware.sh 1.2.2 <说明文件.md> [--target <分支或提交>]
# 版本号必须和 firmware/esp32/CMakeLists.txt 的 PROJECT_VER 一致。电脑端从这里下载固件刷写，安装包里不带固件。
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?用法：$0 <固件版本> <说明文件.md> [--target <分支>]}"
NOTES="${2:?需要说明文件}"
TARGET="$(git rev-parse --abbrev-ref HEAD)"
[[ "${3:-}" == "--target" ]] && TARGET="${4:?}"
KEY="${NOTIBRIDGE_SIGNING_KEY:-$HOME/.config/notibridge/release-signing-ed25519.pem}"
PINNED="+wkZaT1HzXMHhcMF6xz67byo2x0iNeXMoL4PSO1ApQo="
OPENSSL="${OPENSSL:-$(command -v /opt/homebrew/bin/openssl || command -v openssl)}"

grep -q "set(PROJECT_VER \"$VER\")" firmware/esp32/CMakeLists.txt || { echo "CMakeLists.txt 的 PROJECT_VER 不是 $VER" >&2; exit 1; }
firmware/esp32/build_firmware.sh
OUT="dist/firmware-$VER"
rm -rf "$OUT" && mkdir -p "$OUT"
ASSET="NotiBridge-ESP32-$VER.bin"
cp firmware/esp32/prebuilt/notibridge-esp32.bin "$OUT/$ASSET"
cd "$OUT"
shasum -a 256 "$ASSET" > SHA256SUMS.txt
PUB=$("$OPENSSL" pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)
[[ "$PUB" == "$PINNED" ]] || { echo "私钥对应的公钥与内置公钥不一致" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
"$OPENSSL" pkeyutl -sign -inkey "$KEY" -rawin -in SHA256SUMS.txt -out "$TMP/sig.bin"
base64 < "$TMP/sig.bin" | tr -d '\n' > SHA256SUMS.txt.sig
echo >> SHA256SUMS.txt.sig
"$OPENSSL" pkey -in "$KEY" -pubout -out "$TMP/pub.pem"
base64 -D < SHA256SUMS.txt.sig > "$TMP/check.bin" 2>/dev/null || base64 -d < SHA256SUMS.txt.sig > "$TMP/check.bin"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in SHA256SUMS.txt -sigfile "$TMP/check.bin" >/dev/null
cd - >/dev/null
gh release create "firmware-v$VER" --target "$TARGET" --latest=false --title "ESP32 固件 $VER" --notes-file "$NOTES" \
  "$OUT/$ASSET" "$OUT/SHA256SUMS.txt" "$OUT/SHA256SUMS.txt.sig"
