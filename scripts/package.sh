#!/bin/bash
# 把已构建好的 build/PointTell.app 打成可分发的 dmg + zip + SHA256SUMS
#
# 用法：./scripts/package.sh [后缀]
#   后缀用于区分架构：universal / arm64 / x86_64，留空则不带
#   产物：dist/PointTell-<版本>[-<后缀>]-macOS.dmg
#         dist/PointTell-<版本>[-<后缀>]-macOS.zip
#         dist/SHA256SUMS.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PointTell.app"
SUFFIX="${1:-}"

[ -d "$APP" ] || { echo "!! 找不到 ${APP}，先跑 ./build.sh" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="PointTell-${VERSION}${SUFFIX:+-$SUFFIX}-macOS"
OUT="$ROOT/dist"
mkdir -p "$OUT"
# dist/ 只保留「这一次」的产物，避免旧版本的包混进 Release 附件
rm -f "$OUT"/*.dmg "$OUT"/*.zip "$OUT"/SHA256SUMS.txt

ARCH_INFO=$(lipo -archs "$APP/Contents/MacOS/PointTell" 2>/dev/null || echo "unknown")
echo "==> 打包 ${NAME}（架构: ${ARCH_INFO}）"

# ---- zip：保留可执行位与包内符号链接，解压即可用 ----
echo "==> 生成 zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"

# ---- dmg：拖拽安装的常规形态，里面放一个 /Applications 快捷方式 ----
echo "==> 生成 dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# UDZO = 压缩只读，体积最小，挂载后拖拽即装
if hdiutil create -quiet -volname "PointTell" -srcfolder "$STAGE" -ov -format UDZO \
     "$OUT/$NAME.dmg" 2>/dev/null; then
  echo "    dmg 已生成"
else
  echo "    ! hdiutil 失败（沙箱 / 磁盘权限），只保留 zip"
  rm -f "$OUT/$NAME.dmg"
fi

# ---- 校验和：发布页上让用户能自己核对 ----
echo "==> 计算校验和"
( cd "$OUT" && shasum -a 256 $(ls *.dmg *.zip 2>/dev/null) > SHA256SUMS.txt )

echo "==> 产物"
ls -lh "$OUT" | tail -n +2
echo
echo "安装包："
echo "  $OUT/$NAME.dmg"
echo "  $OUT/$NAME.zip"
