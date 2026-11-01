#!/bin/bash
# 修复「辅助功能里明明勾了，应用还是显示未授权」
#
# 原因：ad-hoc 签名（codesign -s -）的「指定需求」是一条裸 cdhash。
# 每次重新编译哈希都变，系统就把它当成另一个程序，旧的授权记录对不上，
# 开关看着是开的，实际不生效。
#
# 现在 build.sh 已改用固定证书签名，需求变成「bundle id + 证书指纹」，重建不再失效。
# 但系统里那条绑定旧哈希的陈旧记录需要手动清一次，这个脚本负责引导。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PointTell.app"

if [ ! -d "$APP" ]; then
  echo "找不到 $APP，先跑 ./build.sh"
  exit 1
fi

echo "==> 当前签名"
codesign -d -r- "$APP" 2>&1 | tail -1
echo "    cdhash: $(codesign -dvvv "$APP" 2>&1 | grep '^CDHash' | cut -d= -f2)"

echo
echo "==> 尝试重置 TCC 记录"
if tccutil reset Accessibility com.pointtell.app 2>/dev/null; then
  echo "    已重置，重新打开应用会重新请求授权"
else
  echo "    重置失败（沙箱限制），需要手动操作："
  echo "    1. 打开「系统设置 → 隐私与安全性 → 辅助功能」"
  echo "    2. 在列表里选中 PointTell，点「−」移除"
  echo "    3. 点「+」，选择：$APP"
  echo "    4. 打开新出现的 PointTell 开关"
fi

echo
echo "==> 打开辅助功能设置面板 + 在 Finder 中定位应用"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
open -R "$APP" 2>/dev/null || true

echo
echo "改完之后："
echo "  pkill -f 'PointTell.app/Contents/MacOS' ; open '$APP'"
echo "  然后看菜单栏 → 应显示「辅助功能权限：已授权」"
