#!/bin/bash
# 离屏渲染面板预览图（不需要录屏权限）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="$(uname -m)-apple-macosx10.15"
OUT="$ROOT/build/preview"

FILES=$(ls Sources/*.swift | grep -v 'main.swift')
swiftc -swift-version 5 -target "$TARGET" -sdk "$SDK" \
  -framework Cocoa -framework Carbon -framework ApplicationServices \
  -framework AVFoundation -framework Speech -framework Security \
  -o "$OUT" $FILES scripts/preview/main.swift
"$OUT"
