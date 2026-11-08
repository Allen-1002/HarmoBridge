#!/bin/bash
# 构建签名 HAP 并安装到手机（USB 或已连接的无线调试），然后启动。
# 用法：scripts/install_phone.sh            # 构建 + 安装 + 启动
#       scripts/install_phone.sh --check    # 只查看签名 Profile 剩余天数
# 签名 Profile 过期后，先在 DevEco Studio 中重新自动签名（见 docs/renew-signing.md），再运行本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."
DEVECO=/Applications/DevEco-Studio.app/Contents
HDC=$DEVECO/sdk/default/openharmony/toolchains/hdc
export DEVECO_SDK_HOME=$DEVECO/sdk
export PATH=$DEVECO/tools/node/bin:$PATH

PROFILE=$(python3 -I -c "
import re,sys
s=open('build-profile.json5').read()
m=re.search(r'\"profile\"\s*:\s*\"([^\"]+)\"', s)
print(m.group(1) if m else '')
")
if [ -z "$PROFILE" ] || [ ! -f "$PROFILE" ]; then
  echo "未找到签名 Profile，请先在 DevEco Studio 中开启自动签名。"; exit 1
fi
openssl cms -verify -noverify -inform DER -in "$PROFILE" 2>/dev/null | python3 -I -c "
import json,sys,time
d=json.loads(sys.stdin.read())
end=d['validity']['not-after']; left=(end-time.time())/86400
acl=d.get('acls',{}).get('allowed-acls',[])
print('签名 Profile 到期：%s（剩余 %.1f 天）' % (time.strftime('%Y-%m-%d %H:%M', time.localtime(end)), left))
print('ACL：', ', '.join(acl) if acl else '无')
if left <= 0:
    print('已过期：请先在 DevEco Studio 重新自动签名'); sys.exit(2)
if 'ohos.permission.SUBSCRIBE_NOTIFICATION' not in acl:
    print('警告：Profile 不含 SUBSCRIBE_NOTIFICATION')
"
[ "${1:-}" = "--check" ] && exit 0

"$DEVECO/tools/hvigor/bin/hvigorw" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon \
  | grep -E "ERROR|BUILD" || true
HAP=entry/build/default/outputs/default/entry-default-signed.hap
[ -f "$HAP" ] || { echo "未生成签名 HAP"; exit 1; }

TARGET=$("$HDC" list targets | awk '$1!="[Empty]" && NF{print $1}' | head -1)
[ -n "$TARGET" ] || { echo "没有检测到手机：插上 USB，或在 DevEco 中连接无线调试"; exit 1; }
"$HDC" -t "$TARGET" install -r "$HAP"
"$HDC" -t "$TARGET" shell aa start -a EntryAbility -b com.xsh.harmobridge
echo "已安装并启动。"
