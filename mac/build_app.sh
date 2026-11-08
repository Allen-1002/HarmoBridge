#!/bin/bash
# 构建 HarmoBridge.app（ad-hoc 签名，仅本机自用）。
# UserNotifications 与登录项都要求以 .app 包运行，不能直接运行 swift run 的可执行文件。
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
# 去掉编译产物里的本机绝对路径
SWIFT_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$(pwd)=.")
swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}" --show-bin-path)/HarmoBridgeMac"
APP="build/HarmoBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HarmoBridgeMac"
# 去掉调试符号（其中含有编译机器上的绝对路径）
[ "$CONFIG" = "release" ] && strip -S -x "$APP/Contents/MacOS/HarmoBridgeMac"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 新版 macOS 的通知中心从资源目录 Assets.car（CFBundleIconName）取图标
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist build/actool-partial.plist Support/icon/Assets.xcassets >/dev/null
# 默认 ad-hoc 签名（适合公开发布，不会把个人证书信息签进 App）。
# 本机自用时可指定固定证书，避免重新打包后钥匙串再次询问：
#   SIGN_ID="Apple Development: ..." ./build_app.sh release install
codesign --force --sign "${SIGN_ID:--}" "$APP"
codesign --verify --verbose "$APP"
echo "已生成 $(pwd)/$APP"

# ./build_app.sh release install：安装到 /Applications（开机启动应使用这个位置）并重新启动
if [ "${2:-}" = "install" ]; then
  pkill -f "HarmoBridge.app/Contents/MacOS/HarmoBridgeMac" || true
  rm -rf /Applications/HarmoBridge.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/HarmoBridge.app
  sleep 1
  open /Applications/HarmoBridge.app
  echo "已安装到 /Applications/HarmoBridge.app"
fi
