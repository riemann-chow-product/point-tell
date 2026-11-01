#!/bin/bash
# 一条命令发版：改版本号 → 构建 → 打 dmg/zip → 提交 → 打 tag → 推送
#
# 用法：
#   ./scripts/release.sh 0.2.0                 # 构建 + 打包 + commit + tag + push
#   ./scripts/release.sh 0.2.0 --no-push       # 只在本地产出，不动远端
#   ./scripts/release.sh 0.2.0 --publish       # 本地包用 gh 直接发 Release（没装 gh 会提示）
#   ./scripts/release.sh 0.2.0 --archs "arm64 x86_64"   # 出通用包（需要完整 Xcode）
#
# 推送 tag 之后，GitHub Actions（.github/workflows/release.yml）会在 arm64 runner 上
# 重新构建通用包并自动发布 Release —— 本机是 Intel，出不了 arm64，这一步只能交给 CI。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
shift || true
[ -n "$VERSION" ] || { sed -n '2,12p' "$0"; exit 1; }

PUSH=1
PUBLISH=0
ARCHS="${POINTTELL_ARCHS:-$(uname -m)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-push) PUSH=0; shift ;;
    --publish) PUBLISH=1; shift ;;
    --archs)   ARCHS="${2:-$ARCHS}"; shift 2 ;;
    *) echo "!! 不认识的参数：$1" >&2; exit 1 ;;
  esac
done

# ---- 前置检查 ----
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "!! 版本号要写成 x.y.z，比如 0.2.0" >&2; exit 1 ;;
esac

TAG="v$VERSION"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "!! tag $TAG 已存在。发新版请换版本号；要重发请先 git tag -d $TAG && git push origin :$TAG" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "!! 工作区不干净，先提交或 stash：" >&2
  git status --short >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> 发版 ${TAG}（分支 ${BRANCH}，架构 ${ARCHS}）"

# ---- 1. 版本号写进源码（唯一来源），Info.plist 由 build.sh 注入 ----
echo "==> 写入版本号"
/usr/bin/sed -i '' -E "s/(static let version = \")[^\"]*(\")/\1$VERSION\2/" Sources/AppInfo.swift
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
grep -n "static let version" Sources/AppInfo.swift

# ---- 2. 构建 + 打包 ----
POINTTELL_VERSION="$VERSION" POINTTELL_ARCHS="$ARCHS" ./build.sh

ARCH_COUNT=$(echo "$ARCHS" | wc -w | tr -d ' ')
if [ "$ARCH_COUNT" -gt 1 ]; then SUFFIX="universal"; else SUFFIX="$ARCHS"; fi
./scripts/package.sh "$SUFFIX"

# ---- 3. 提交 + 打 tag ----
echo "==> 提交版本号"
git add Sources/AppInfo.swift Resources/Info.plist
git commit -m "chore(release): $TAG" >/dev/null
git tag -a "$TAG" -m "PointTell $VERSION"
echo "    $(git log --oneline -1)"

# ---- 4. 推送 ----
if [ "$PUSH" = "1" ]; then
  echo "==> 推送 $BRANCH 与 $TAG"
  # 需要代理时：POINTTELL_GIT_PROXY=http://127.0.0.1:9090 ./scripts/release.sh ...
  GIT_PROXY=()
  [ -n "${POINTTELL_GIT_PROXY:-}" ] && GIT_PROXY=(-c "http.proxy=$POINTTELL_GIT_PROXY")
  git ${GIT_PROXY[@]+"${GIT_PROXY[@]}"} push origin "$BRANCH"
  git ${GIT_PROXY[@]+"${GIT_PROXY[@]}"} push origin "$TAG"
else
  echo "==> 已跳过推送（--no-push）"
fi

# ---- 5. 可选：本地直接发 Release ----
if [ "$PUBLISH" = "1" ]; then
  if command -v gh >/dev/null 2>&1; then
    echo "==> gh release create $TAG"
    gh release create "$TAG" dist/* \
      --title "PointTell $VERSION" \
      --generate-notes
  else
    echo "!! 没装 gh。装一个：brew install gh && gh auth login"
    echo "   或者把 dist/ 里的文件手动拖到 https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]([^/]+/[^/.]+).*#\1#')/releases/new?tag=$TAG"
  fi
fi

echo
echo "==> 完成"
echo "    本地包：dist/PointTell-${VERSION}-${SUFFIX}-macOS.dmg"
echo "            dist/PointTell-${VERSION}-${SUFFIX}-macOS.zip"
[ "$PUSH" = "1" ] && echo "    Actions：https://github.com/$(git remote get-url origin | sed -E 's#.*github.com[:/]([^/]+/[^/.]+).*#\1#')/actions"
echo
echo "    注意：本机是 $(uname -m)，产物只含这一种架构。"
echo "    要出 arm64 / 通用包，让 CI 构建（推 tag 即触发），或换一台 Apple Silicon 机器跑。"
