#!/bin/bash
# PointTell 构建脚本：把 Sources/*.swift 编译成一个 .app
#
# 可调环境变量：
#   POINTTELL_VERSION   覆盖版本号（默认取 Sources/AppInfo.swift 里的 version）
#   POINTTELL_BUILD     覆盖 CFBundleVersion（默认取 git 提交数）
#   POINTTELL_ARCHS     目标架构，空格分隔，默认本机架构；CI 上写 "arm64 x86_64" 出通用包
#   POINTTELL_MIN_MACOS 最低系统版本，默认 10.15
#   POINTTELL_SIGN_ID   签名身份，默认 "PointTell Dev"（自签名证书）
#   POINTTELL_KEYCHAIN  签名证书所在钥匙串，默认 ~/Library/Keychains/pointtell-signing.keychain-db
#   POINTTELL_HARDENED  设为 1 时开启 Hardened Runtime（走 Developer ID 公证时才需要）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/PointTell.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

# ---- 版本号：单一来源是 Sources/AppInfo.swift，Info.plist 由它注入 ----
# 以前版本号要改两个地方（AppInfo.swift + Resources/Info.plist），漏改就会出现
# 「关于窗口 0.1.4、dmg 名字 0.1.3」这种对不上的情况。
VERSION="${POINTTELL_VERSION:-$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/AppInfo.swift" | head -1)}"
if [ -z "$VERSION" ]; then
  echo "!! 读不到版本号（Sources/AppInfo.swift 里的 static let version）" >&2
  exit 1
fi
BUILD_NUMBER="${POINTTELL_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
MIN_MACOS="${POINTTELL_MIN_MACOS:-10.15}"

# ---- 架构 ----
# 本机是 Intel 时 uname -m = x86_64；Command Line Tools 只带 x86_64 的 Swift 标准库，
# 所以本机出不了 arm64。要出通用包请在有完整 Xcode 的机器 / GitHub Actions 上跑。
ARCHS="${POINTTELL_ARCHS:-$(uname -m)}"
ARCH_COUNT=$(echo "$ARCHS" | wc -w | tr -d ' ')

# ---- 签名配置 ----
# 用 ad-hoc 签名（codesign -s -）时，「指定需求」是一条裸 cdhash：
#     designated => cdhash H"f8e8fd43..."
# 每次重新编译哈希都变，系统就把它当成另一个程序，辅助功能授权随即失效，
# 表现为「设置里明明是开的，应用却报未授权」。
# 换成固定证书后需求变成「bundle id + 证书指纹」，重建不再影响授权。
SIGN_ID="${POINTTELL_SIGN_ID:-PointTell Dev}"
KEYCHAIN="${POINTTELL_KEYCHAIN:-$HOME/Library/Keychains/pointtell-signing.keychain-db}"
KEYCHAIN_PASS="${POINTTELL_KEYCHAIN_PASS:-pointtell}"

echo "==> 版本 $VERSION ($BUILD_NUMBER) · 架构 $ARCHS · 最低 macOS $MIN_MACOS"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 写入 Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

for ARCH in $ARCHS; do
  echo "==> 编译 $ARCH (SDK $SDK)"
  swiftc \
    -O \
    -swift-version 5 \
    -target "${ARCH}-apple-macosx${MIN_MACOS}" \
    -sdk "$SDK" \
    -framework Cocoa \
    -framework Carbon \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework Speech \
    -framework Security \
    -o "$TMPD/PointTell-$ARCH" \
    "$ROOT"/Sources/*.swift
done

BIN="$APP/Contents/MacOS/PointTell"
if [ "$ARCH_COUNT" -gt 1 ]; then
  echo "==> 合并为通用二进制"
  lipo -create -output "$BIN" "$TMPD"/PointTell-*
else
  cp "$TMPD/PointTell-$ARCHS" "$BIN"
fi
chmod +x "$BIN"

echo "==> 签名 ($SIGN_ID)"
sign_stable() {
  # 独立钥匙串必须先解锁，否则 codesign 会卡在系统授权框上无限等待
  [ -f "$KEYCHAIN" ] || return 1
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || return 1
  # 确保它还在搜索列表里（重装系统 / 手动清理后可能丢）
  if ! security list-keychains -d user | grep -q "$(basename "$KEYCHAIN" .keychain-db)"; then
    security list-keychains -d user -s $(security list-keychains -d user | tr -d ' "') "$KEYCHAIN" >/dev/null 2>&1
  fi
  # Hardened Runtime 会拦掉 Apple Events，只有走公证（Developer ID）时才开
  # 注意 bash 3.2 + set -u 下空数组直接展开会报 unbound，用 +"${arr[@]}" 形式
  local extra=()
  [ "${POINTTELL_HARDENED:-0}" = "1" ] && extra=(--options runtime)
  codesign --force --deep ${extra[@]+"${extra[@]}"} --keychain "$KEYCHAIN" --sign "$SIGN_ID" "$APP" 2>&1 | head -5
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
lipo -info "$BIN" 2>/dev/null | tail -1

echo "==> 完成: $APP"
echo "    运行: open \"$APP\""
