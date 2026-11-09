#!/bin/bash
# 在本机创建一张固定的自签名代码签名证书“NotiBridge Self-Signed”（只用于给 NotiBridge.app 签名）。
# 用固定证书签名后，App 的“指定要求”基于证书而不是每次构建都会变的 cdhash，
# 钥匙串里配对密钥的访问授权在以后的更新中继续有效，不会再反复询问。
# 证书不需要被系统信任，也不会用于其他用途。备份保存在 ~/.config/notibridge/（丢失后换新证书，用户更新时会再被询问一次）。
set -euo pipefail
NAME="NotiBridge Self-Signed"
DIR="$HOME/.config/notibridge"
P12="$DIR/notibridge-macos-signing.p12"
PROPS="$DIR/notibridge-macos-signing.properties"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "钥匙串里已有“${NAME}”，不需要重新创建。"
  exit 0
fi

mkdir -p "$DIR"
if [ -f "$P12" ] && [ -f "$PROPS" ]; then
  echo "从备份 $P12 导入"
  PASS=$(sed -n 's/^password=//p' "$PROPS")
else
  OPENSSL=$(command -v /opt/homebrew/bin/openssl || command -v openssl)
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  PASS=$("$OPENSSL" rand -hex 16)
  cat > "$WORK/cfg.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=NotiBridge Self-Signed
O=NotiBridge
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 7300 -config "$WORK/cfg.cnf" 2>/dev/null
  LEGACY=""
  "$OPENSSL" version | grep -q "^OpenSSL 3" && LEGACY="-legacy"
  "$OPENSSL" pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$P12" -passout "pass:$PASS"
  printf 'p12=%s\npassword=%s\nname=%s\n' "$(basename "$P12")" "$PASS" "$NAME" > "$PROPS"
  chmod 600 "$P12" "$PROPS"
  echo "已生成证书并备份到 $P12（密码在 $PROPS）"
fi

# -T 允许 codesign 直接使用私钥，打包时不再询问
security import "$P12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security
security find-certificate -c "$NAME" -Z "$KEYCHAIN" | grep SHA-1
echo "完成：之后运行 ./build_app.sh 会自动用“${NAME}”签名。"
