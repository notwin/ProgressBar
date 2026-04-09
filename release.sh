#!/bin/bash
# 发布新版本
# 用法: ./release.sh 4.6

set -e

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "用法: ./release.sh <版本号>"
  echo "示例: ./release.sh 4.6"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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

# 更新版本号
sed -i '' "s|<string>[0-9.]*</string><!-- CFBundleShortVersionString -->|<string>$VERSION</string><!-- CFBundleShortVersionString -->|" AppBundle/Contents/Info.plist
# 兼容无注释的格式
sed -i '' "s|<key>CFBundleShortVersionString</key>|<key>CFBundleShortVersionString</key>|" AppBundle/Contents/Info.plist

# 用 python 精确替换版本号
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

echo "✅ 版本号更新为 $VERSION"

# 提交并打 tag
git add AppBundle/Contents/Info.plist
git commit -m "chore: bump version to $VERSION"
git push origin main

git tag "v$VERSION"
git push origin "v$VERSION"

echo ""
echo "🚀 已推送 v$VERSION，GitHub Actions 将自动编译发布"
echo "   查看进度: gh run list --limit 1"
echo "   发布页面: https://github.com/notwin/ProgressBar/releases/tag/v$VERSION"
