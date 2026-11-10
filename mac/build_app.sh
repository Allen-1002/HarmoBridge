#!/bin/bash
# 构建 NotiBridge.app（固定自签名证书签名，没有证书时退回 ad-hoc）。
# UserNotifications 与登录项都要求以 .app 包运行，不能直接运行 swift run 的可执行文件。
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
# 去掉编译产物里的本机绝对路径
SWIFT_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$(pwd)=.")
swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}" --show-bin-path)/NotiBridgeMac"
APP="build/NotiBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotiBridgeMac"
# 去掉调试符号（其中含有编译机器上的绝对路径）
[ "$CONFIG" = "release" ] && strip -S -x "$APP/Contents/MacOS/NotiBridgeMac"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# ESP32 固件（firmware/esp32/build_firmware.sh 生成），App 里一键刷写
FW=../firmware/esp32/prebuilt/notibridge-esp32.bin
if [ -f "$FW" ]; then cp "$FW" "$APP/Contents/Resources/notibridge-esp32.bin"; else echo "警告：没有 $FW，App 将无法刷写 ESP32" >&2; fi
# 新版 macOS 的通知中心从资源目录 Assets.car（CFBundleIconName）取图标
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist build/actool-partial.plist Support/icon/Assets.xcassets >/dev/null
# 签名：优先用本机固定的自签名证书“NotiBridge Self-Signed”（由 ./make_signing_cert.sh 创建）。
# 固定证书让 App 的指定要求不随每次构建变化，钥匙串里配对密钥的授权在更新后继续有效。
# 也可以用 SIGN_ID 指定其他证书；都没有时退回 ad-hoc（每次重新打包后钥匙串都会再询问）。
CERT_NAME="NotiBridge Self-Signed"
if [ -z "${SIGN_ID:-}" ]; then
  if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    SIGN_ID="$CERT_NAME"
  else
    SIGN_ID="-"
    echo "警告：钥匙串里没有“${CERT_NAME}”，使用 ad-hoc 签名（更新后钥匙串会再次询问）。运行 ./make_signing_cert.sh 创建。" >&2
  fi
fi
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --verbose "$APP"
echo "已生成 $(pwd)/$APP"

# ./build_app.sh release install：安装到 /Applications（开机启动应使用这个位置）并重新启动
if [ "${2:-}" = "install" ]; then
  pkill -f "NotiBridge.app/Contents/MacOS/NotiBridgeMac" || true
  rm -rf /Applications/NotiBridge.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/NotiBridge.app
  sleep 1
  open /Applications/NotiBridge.app
  echo "已安装到 /Applications/NotiBridge.app"
fi
