#!/usr/bin/env bash
# 设置窗口自检：可编辑性 / 地址归一 / 测试连接（成功、404、拒连、401、隐私拦截）/ 不落盘
# 用法：./scripts/settings-check.sh
set -uo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --show-sdk-path --sdk macosx)"
PY="$(command -v python3 || echo /usr/bin/python3)"

echo "==> 启动模拟 LLM 服务 (127.0.0.1:11500)"
"$PY" scripts/settings-check/mock_llm.py &
MOCK_PID=$!
cleanup() { kill "$MOCK_PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

echo "==> 编译（带 -D DEBUG，只为打开自检入口）"
# shellcheck disable=SC2046
swiftc -swift-version 5 -D DEBUG \
  -target "$(uname -m)-apple-macosx10.15" \
  -sdk "$SDK" \
  -framework Cocoa -framework Carbon -framework ApplicationServices \
  -framework AVFoundation -framework Speech -framework Security \
  -o /tmp/pt-settings-check \
  $(ls Sources/*.swift | grep -v 'main.swift') \
  scripts/settings-check/main.swift || exit 1

echo "==> 运行"
/tmp/pt-settings-check
