#!/bin/bash
# 把 API Key 从「应用读不到的钥匙串条目」抢救到应用能读的位置。
#
# 背景：钥匙串条目的 ACL 绑定在创建它的那份签名上。项目早期用 ad-hoc 签名
# （codesign -s -），cdhash 每次编译都变；后来换成固定证书，签名身份变了，
# 旧条目就读不出来（SecItemCopyMatching 返回 -25293 errSecAuthFailed）。
# 表现为：设置里明明存过 key，一用就 401 / 「没有读到 API Key」。
#
# 但 `security` 命令行走的是另一个身份，通常还能读到旧条目 —— 本脚本就用它
# 把 key 取出来，写进 ~/Library/Application Support/PointTell/api-key.json（0600），
# 应用读不到钥匙串时会自动用这个文件。
#
# 用法：
#   ./scripts/fix-api-key.sh              # 修复（默认账号 anthropic）
#   ./scripts/fix-api-key.sh openai       # 指定服务商
#   ./scripts/fix-api-key.sh --check      # 只看状态，不写任何东西

set -uo pipefail

SERVICE="com.pointtell.apikey"
ACCOUNT="${1:-anthropic}"
CHECK_ONLY=0
if [ "$ACCOUNT" = "--check" ]; then CHECK_ONLY=1; ACCOUNT="anthropic"; fi

APP_DIR="$HOME/Library/Application Support/PointTell"
KEY_FILE="$APP_DIR/api-key.json"

echo "==> 服务商：$ACCOUNT"

# 1. 应用实际会读到的值（钥匙串优先，读不到才看文件）
KC_VALUE="$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null)"
FILE_VALUE=""
if [ -f "$KEY_FILE" ]; then
  FILE_VALUE="$(/usr/bin/python3 - "$KEY_FILE" "$ACCOUNT" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v=d.get(sys.argv[2],"")
if v: sys.stdout.write(v)
PY
)"
fi

mask() { if [ -z "$1" ]; then echo "<空>"; else echo "${1:0:6}…${1: -4}（${#1} 字符）"; fi; }

echo "    钥匙串（security 视角）: $(mask "$KC_VALUE")"
echo "    本地文件兜底          : $(mask "$FILE_VALUE")"

if [ $CHECK_ONLY -eq 1 ]; then
  echo
  echo "    提示：这里看到的不等于应用能读到。应用进程读钥匙串可能被 ACL 拒绝，"
  echo "    以 /tmp/pointtell.log 里的「keychain: SecItemCopyMatching」为准。"
  exit 0
fi

if [ -z "$KC_VALUE" ]; then
  echo
  echo "!! 钥匙串里也没有这条 key，无法自动抢救。"
  echo "   请打开应用 → 设置 → 模型，把 Key 重新粘贴一次并保存。"
  exit 1
fi

if [ "$KC_VALUE" = "$FILE_VALUE" ]; then
  echo
  echo "==> 已经一致，无需修复。"
  exit 0
fi

# 2. 写文件（0600）。用 python 写是为了正确合并已有其它服务商的条目
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"
/usr/bin/python3 - "$KEY_FILE" "$ACCOUNT" "$KC_VALUE" <<'PY'
import json,os,sys
path,account,value=sys.argv[1],sys.argv[2],sys.argv[3]
d={}
if os.path.exists(path):
    try: d=json.load(open(path))
    except Exception: d={}
if not isinstance(d,dict): d={}
d[account]=value
fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
with os.fdopen(fd,"w") as f:
    json.dump(d,f,indent=2)
os.chmod(path,0o600)
PY

if [ $? -ne 0 ]; then
  echo "!! 写入失败：$KEY_FILE"
  exit 1
fi

echo
echo "==> 已写入：$KEY_FILE"
ls -l "$KEY_FILE"
echo
echo "下一步：重启应用（菜单栏图标 → 退出，再 open build/PointTell.app），"
echo "然后点一次「保存」把钥匙串条目按当前签名重建，以后就不会再丢。"
