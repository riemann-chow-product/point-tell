#!/bin/bash
# PointTell 构建脚本：把 Sources/*.swift 编译成一个 .app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/PointTell.app"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx10.15"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

# ---- 签名配置 ----
# 用 ad-hoc 签名（codesign -s -）时，「指定需求」是一条裸 cdhash：
#     designated => cdhash H"f8e8fd43..."
# 每次重新编译哈希都变，系统就把它当成另一个程序，辅助功能授权随即失效，
# 表现为「设置里明明是开的，应用却报未授权」。
# 换成固定证书后需求变成「bundle id + 证书指纹」，重建不再影响授权。
SIGN_ID="${POINTTELL_SIGN_ID:-PointTell Dev}"
KEYCHAIN="$HOME/Library/Keychains/pointtell-signing.keychain-db"
KEYCHAIN_PASS="${POINTTELL_KEYCHAIN_PASS:-pointtell}"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 写入 Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 编译 ($TARGET, SDK $SDK)"
swiftc \
  -O \
  -swift-version 5 \
  -target "$TARGET" \
  -sdk "$SDK" \
  -framework Cocoa \
  -framework Carbon \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework Speech \
  -framework Security \
  -o "$APP/Contents/MacOS/PointTell" \
  "$ROOT"/Sources/*.swift

echo "==> 签名 ($SIGN_ID)"
sign_stable() {
  # 独立钥匙串必须先解锁，否则 codesign 会卡在系统授权框上无限等待
  [ -f "$KEYCHAIN" ] || return 1
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || return 1
  # 确保它还在搜索列表里（重装系统 / 手动清理后可能丢）
  if ! security list-keychains -d user | grep -q "pointtell-signing"; then
    security list-keychains -d user -s $(security list-keychains -d user | tr -d ' "') "$KEYCHAIN" >/dev/null 2>&1
  fi
  codesign --force --deep --keychain "$KEYCHAIN" --sign "$SIGN_ID" "$APP" 2>&1 | head -5
  return ${PIPESTATUS[0]}
}

if sign_stable && codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf"; then
  :
else
  echo "   ! 稳定签名不可用，回退到 ad-hoc"
  echo "   ! 注意：ad-hoc 下每次重建都会让辅助功能授权失效，需要在系统设置里重新勾选"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   签名跳过"
fi

echo "==> 校验"
codesign --verify --deep --strict "$APP" 2>&1 | head -3 || true
codesign -d -r- "$APP" 2>&1 | tail -1

echo "==> 完成: $APP"
echo "    运行: open \"$APP\""
