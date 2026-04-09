#!/bin/bash
# 一键发布新版本（自动递增版本号）
# 用法: ./release.sh        → 自动 +0.1（如 4.5 → 4.6）
#       ./release.sh 5.0    → 指定版本号

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# 读取当前版本号
CURRENT=$(grep -A1 CFBundleShortVersionString AppBundle/Contents/Info.plist | grep string | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
echo "当前版本: $CURRENT"

# 计算新版本号
if [ -n "$1" ]; then
  VERSION="$1"
else
  MAJOR=$(echo "$CURRENT" | cut -d. -f1)
  MINOR=$(echo "$CURRENT" | cut -d. -f2)
  VERSION="$MAJOR.$((MINOR + 1))"
fi

echo "新版本:   $VERSION"

# 检查工作区是否干净
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作区有未提交的改动，请先提交"
  exit 1
fi

# 检查 tag 是否已存在
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "❌ Tag v$VERSION 已存在"
  exit 1
fi

# 更新 Info.plist 版本号
python3 -c "
import re
with open('AppBundle/Contents/Info.plist', 'r') as f:
    content = f.read()
content = re.sub(
    r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>$VERSION\g<2>', content)
content = re.sub(
    r'(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>$VERSION\g<2>', content)
with open('AppBundle/Contents/Info.plist', 'w') as f:
    f.write(content)
"

# 提交并打 tag
git add AppBundle/Contents/Info.plist
git commit -m "chore: bump version to $VERSION"
git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"

echo ""
echo "🚀 v$VERSION 已推送，GitHub Actions 自动编译发布中"
echo "   查看进度: gh run list --limit 1"
echo "   发布页面: https://github.com/notwin/ProgressBar/releases/tag/v$VERSION"
